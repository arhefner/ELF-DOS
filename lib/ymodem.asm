;
; ymodem.asm - shared primitives for YR/YS (YMODEM-CRC batch transfer)
;
; NOT a standalone program -- no EDF header, no org PROG_BASE, no entry
; point of its own. Assembled separately (lib/ymodem.prg) and linked
; alongside progs/yr.asm/progs/ys.asm, the same way this project's other
; lib/ modules work.
;
; What lives here vs. what stays in yr.asm/ys.asm: pure protocol
; mechanics (CRC16, 32-bit decimal parse/format for the header block's
; size field, mode-aware byte I/O, the block-sized fast transfer loops)
; live here, shared by both directions. The actual protocol STATE
; MACHINES (handshake sequencing, header-block build/parse, EOT
; handling, the multi-file batch loop, retry/timeout policy) stay in
; each program -- YR's and YS's own sequencing differ enough (receiver-
; driven vs. sender-driven) that trying to share that part would cost
; more in indirection than it saves in code size.
;
; ym_io_mode (public, shared data) records which device the CALLING
; program's own argv parsing selected ("-u", the default, or "-b") --
; set once by yr.asm/ys.asm's own start:, read by every routine below
; that touches the wire. Same convention mr.asm/ms.asm already
; established (mr_io_mode/ms_io_mode), just shared here since both YR
; and YS need it and the device-selection logic itself is identical.
;
; Register-liveness discipline follows mr.asm/ms.asm's own hard-won,
; hardware-confirmed rule exactly (see either file's own header comment
; for the full evidence): nothing may be trusted in a register across
; more than one call to K_READ/K_TYPE (the kernel jump-table indirection
; -- something inside repeated calls to f_read/f_type clobbers at least
; one GP register). The DIRECT BIOS calls used in the fast block-
; transfer loops below (f_uread/f_bread/f_utype/f_btype, and now
; f_utest) are a DIFFERENT code path with no such confirmed problem --
; mr.asm's own readlp_uart/readlp_bitbang already trust RC across many
; repeated direct f_uread/f_bread calls, and that trust is reused here
; unchanged. f_utest itself is new to this project (never called
; anywhere before this file) -- its own polling loop below is written
; conservatively, keeping everything it needs in registers only across
; DIRECT BIOS calls (f_utest/f_uread), never across a K_* kernel call.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   ym_io_mode
            extrn   ym_raw_digits

YM_IO_UART:     equ     0           ; call f_uread/f_utype directly (default)
YM_IO_BITBANG:  equ     1           ; call f_bread/f_btype directly

;------------------------------------------------------------------
; ym_crc16: compute CRC16-CCITT (the "XMODEM" variant: poly $1021,
; init 0, no reflection -- the variant XMODEM-CRC/YMODEM-CRC actually
; use on the wire) over RC bytes at RF. Independently verified against
; a from-scratch mechanical instruction-level simulation of this exact
; sequence (not just the algorithm) across 2000+ randomized inputs plus
; the standard test vector (CRC16("123456789") = $31C3) before this was
; trusted -- see the project session notes for the full record.
; Args:    RF = buffer, RC = byte count
; Returns: RD = CRC16 (big-endian on the wire -- caller sends RD's
;          high byte first, then low byte)
; Modifies: R8, R9, RC, RD, RF (and D, DF)
;------------------------------------------------------------------
            proc    ym_crc16
            ldi     0
            phi     rd
            plo     rd                  ; RD = crc = 0

crc16_loop:
            ghi     rc
            lbnz    crc16_have_byte
            glo     rc
            lbz     crc16_done
crc16_have_byte:
            lda     rf                  ; D = next byte, RF++
            plo     r8                  ; R8.0 = byte (stash -- the
                                        ; ghi/str below need D free)
            ghi     rd
            str     r2
            glo     r8
            xor                         ; D = byte XOR crc.hi
            phi     rd                  ; crc.hi updated (crc.lo
                                        ; untouched -- byte only ever
                                        ; affects the top 8 bits)

            ldi     8
            plo     r9                  ; R9.0 = bit counter (8 shifts
                                        ; per byte)

crc16_bit:
            glo     rd
            shl                         ; D = crc.lo << 1, DF = crc.lo's
                                        ; old bit 7, crc.lo's bit0 -> 0
            plo     rd
            ghi     rd
            shlc                        ; D = (crc.hi<<1)|DF(from the
                                        ; low-byte shift); DF becomes
                                        ; crc.hi's OLD bit 7 -- i.e. the
                                        ; carry out of the whole 16-bit
                                        ; shift, exactly the "was bit 15
                                        ; set" test the algorithm needs
            phi     rd

            lbnf    crc16_no_poly       ; DF=0: bit 15 was 0, no XOR
            ghi     rd
            xri     $10
            phi     rd
            glo     rd
            xri     $21
            plo     rd

crc16_no_poly:
            glo     r9
            smi     1
            plo     r9
            lbnz    crc16_bit

            lbr     crc16_loop

crc16_done:
            rtn
            endp

;------------------------------------------------------------------
; ym_fmt_uint32: format a 32-bit unsigned value as a PLAIN decimal
; string (no comma grouping -- unlike lib/fmt32.asm's own fmt_size32,
; which is display-formatting-specific; a YMODEM header block's size
; field needs plain digits only). Reuses lib/fmt32.asm's own already-
; verified _div32_by10 (same restoring-division technique, no native
; divide on the 1802) rather than re-deriving it -- this routine keeps
; its own separate digit-extraction scratch (ym_raw_digits) instead of
; reusing fmt32.asm's raw_digits, for clean separation rather than any
; correctness concern (the two are never live at the same time in
; practice, but sharing state across unrelated library files is the
; kind of coupling this project avoids on principle).
; Args:    RD:R8 = 32-bit value (RD = high word, R8 = low word)
;          RF = destination buffer, at least 11 bytes (max
;          "4294967295" = 10 digits + null)
; Returns: buffer filled and null-terminated
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
            extrn   _div32_by10

            proc    ym_fmt_uint32
            mov     rb, rf              ; RB = caller's destination
                                        ; buffer (stashed -- RF is
                                        ; needed as scratch below;
                                        ; same real bug fmt_size32's
                                        ; own header already documents
                                        ; hitting once with R7 instead
                                        ; -- _div32_by10 clobbers R7,
                                        ; so RB, which it does NOT
                                        ; touch, is used here instead)
            mov     rf, ym_raw_digits
            ldi     0
            plo     rc                  ; RC.0 = digit count (K)

yfu_extract_loop:
            ghi     rd
            lbnz    yfu_extract_have_value
            glo     rd
            lbnz    yfu_extract_have_value
            ghi     r8
            lbnz    yfu_extract_have_value
            glo     r8
            lbnz    yfu_extract_have_value
            glo     rc
            lbnz    yfu_extract_done   ; already have digits, value now
                                        ; 0: stop (avoid leading zeros)

yfu_extract_have_value:
            call    _div32_by10        ; RD:R8 = quotient, R9.0 = remainder
            glo     r9
            adi     '0'
            str     rf
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     yfu_extract_loop

yfu_extract_done:
            ; RC.0 = K (1-10); ym_raw_digits[0..K-1] holds the digits,
            ; least-significant first

            mov     rf, rb              ; RF = caller's destination
                                        ; buffer (write cursor)
            glo     rc
            smi     1
            plo     r9                  ; R9.0 = i, starts at K-1
            ldi     0
            phi     r9                  ; R9.1 = 0 -- same fix
                                        ; fmt_size32's own header
                                        ; documents: R9's high byte is
                                        ; never written elsewhere here,
                                        ; and the add16 below uses R9
                                        ; as a full 16-bit index

yfu_build_loop:
            mov     r8, ym_raw_digits
            add16   r8, r9              ; safe: r9 is always 0-9 here
            ldn     r8
            str     rf
            inc     rf

            glo     r9
            lbz     yfu_build_done

            glo     r9
            smi     1
            plo     r9
            lbr     yfu_build_loop

yfu_build_done:
            ldi     0
            str     rf
            rtn
            endp

;------------------------------------------------------------------
; ym_parse_uint32: parse a decimal string into a 32-bit unsigned value,
; stopping at the first non-digit character (matching
; lib/env.asm's own env_parse_uint's contract, widened to 32 bits) --
; used to parse a YMODEM header block's own ASCII decimal size field.
; No native multiply on the 1802: value*10 is built as value*8+value*2
; (three 32-bit left-shifts into the accumulator itself, plus one more
; shift on a saved copy, then a 32-bit add), matching the same
; shift-and-add technique this project already uses for 16-bit
; decimal parsing (e.g. edlin's own ed_parse_uint) generalized to 32
; bits. Independently verified via a from-scratch mechanical
; instruction-level simulation of this exact sequence across 3000+
; randomized decimal strings (including the empty string, non-digit-
; first, and values exceeding 2^32) before being trusted.
; Args:    RF = string pointer
; Returns: RD:R8 = parsed value (0 if no leading digit), RF = pointer
;          to the first non-digit character (unchanged if there were
;          no digits at all)
; Modifies: R7, R8, R9, RB, RD, RF (and D, DF)
;------------------------------------------------------------------
            proc    ym_parse_uint32
            ldi     0
            phi     rd
            plo     rd
            phi     r8
            plo     r8                  ; RD:R8 = 0

ypu_loop:
            ldn     rf
            smi     '0'
            lbnf    ypu_done
            ldn     rf
            smi     '9'+1
            lbdf    ypu_done

            ldn     rf
            smi     '0'
            plo     rb                  ; RB.0 = digit (0-9) -- no call
                                        ; happens before this is used
                                        ; below, so a register is safe

            ; scratch (R7:R9) = accumulator (RD:R8), before the
            ; accumulator itself gets shifted in place
            ghi     rd
            phi     r7
            glo     rd
            plo     r7
            ghi     r8
            phi     r9
            glo     r8
            plo     r9

            ; accumulator <<= 3 (three 32-bit left shifts, low word
            ; first each time, carry chained low->high)
            glo     r8
            shl
            plo     r8
            ghi     r8
            shlc
            phi     r8
            glo     rd
            shlc
            plo     rd
            ghi     rd
            shlc
            phi     rd

            glo     r8
            shl
            plo     r8
            ghi     r8
            shlc
            phi     r8
            glo     rd
            shlc
            plo     rd
            ghi     rd
            shlc
            phi     rd

            glo     r8
            shl
            plo     r8
            ghi     r8
            shlc
            phi     r8
            glo     rd
            shlc
            plo     rd
            ghi     rd
            shlc
            phi     rd
            ; RD:R8 = original_value * 8

            ; scratch (R7:R9) <<= 1
            glo     r9
            shl
            plo     r9
            ghi     r9
            shlc
            phi     r9
            glo     r7
            shlc
            plo     r7
            ghi     r7
            shlc
            phi     r7
            ; R7:R9 = original_value * 2

            ; accumulator += scratch (32-bit add, low word first)
            glo     r9
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r9
            str     r2
            ghi     r8
            adc
            phi     r8
            glo     r7
            str     r2
            glo     rd
            adc
            plo     rd
            ghi     r7
            str     r2
            ghi     rd
            adc
            phi     rd
            ; RD:R8 = original_value*10

            ; accumulator += digit (RB.0, 0-9) -- carry propagated
            ; through all 4 bytes even though only the lowest one gets
            ; a nonzero addend
            glo     rb
            str     r2
            glo     r8
            add
            plo     r8
            ldi     0
            str     r2
            ghi     r8
            adc
            phi     r8
            ldi     0
            str     r2
            glo     rd
            adc
            plo     rd
            ldi     0
            str     r2
            ghi     rd
            adc
            phi     rd

            inc     rf
            lbr     ypu_loop

ypu_done:
            rtn
            endp

;------------------------------------------------------------------
; ym_getbyte: blocking, mode-aware single-byte read -- calls f_uread
; or f_bread directly (never K_READ's own kernel-jump-table/RAM-vector
; indirection), matching mr.asm's own established reasoning for why
; the direct BIOS entry points are used at all. For infrequent,
; once-per-block protocol bytes (handshake, header fields, ACK/NAK) --
; the fast per-byte DATA loop is ym_recv_block below, not this.
; Args:    none (reads ym_io_mode)
; Returns: D = byte read
; Modifies: RD (and D)
;------------------------------------------------------------------
            proc    ym_getbyte
            mov     rd, ym_io_mode
            ldn     rd
            xri     YM_IO_BITBANG
            lbz     ygb_bitbang
            call    f_uread
            rtn
ygb_bitbang:
            call    f_bread
            rtn
            endp

;------------------------------------------------------------------
; ym_putbyte: blocking, mode-aware single-byte write -- see ym_getbyte
; above for the same reasoning.
; Args:    D = byte to send
; Returns: nothing
; Modifies: RD (and D)
;------------------------------------------------------------------
            proc    ym_putbyte
            plo     rb                  ; stash the byte -- the mov
                                        ; below clobbers D (gotcha #4)
            mov     rd, ym_io_mode
            ldn     rd
            xri     YM_IO_BITBANG
            lbz     ypb_bitbang
            glo     rb
            call    f_utype
            rtn
ypb_bitbang:
            glo     rb
            call    f_btype
            rtn
            endp

;------------------------------------------------------------------
; ym_getbyte_timeout: wait for one byte, giving up after RD poll
; iterations if none arrives -- UART mode only; see this file's own
; header comment and the project session notes for why bit-bang mode
; has no non-blocking "is a byte waiting" primitive at all (f_btest
; is a BREAK-condition detector, not a data-ready test). In bit-bang
; mode this just blocks on f_bread unconditionally, same as
; ym_getbyte -- not a regression versus mr.asm/ms.asm, which have
; never had timeout protection in either mode.
; Args:    RD = poll budget (iterations, UART mode only -- ignored in
;          bit-bang mode)
; Returns: DF = 0 with D = byte on success; DF = 1 if the poll budget
;          was exhausted with nothing received (UART mode only -- bit-
;          bang mode always returns DF = 0 eventually)
; Modifies: RD (and D, DF)
;------------------------------------------------------------------
            proc    ym_getbyte_timeout
            mov     rb, ym_io_mode
            ldn     rb
            xri     YM_IO_BITBANG
            lbz     ygbt_bitbang

ygbt_poll:
            ghi     rd
            lbnz    ygbt_have_budget
            glo     rd
            lbnz    ygbt_have_budget
            stc                         ; budget exhausted: DF=1, timeout
            rtn

ygbt_have_budget:
            call    f_utest             ; DF = 1: a byte is waiting
            lbdf    ygbt_ready
            dec     rd
            lbr     ygbt_poll

ygbt_ready:
            call    f_uread
            clc
            rtn

ygbt_bitbang:
            call    f_bread
            clc
            rtn
            endp

;------------------------------------------------------------------
; ym_recv_block / ym_send_block: the fast, mode-aware per-byte block
; transfer loops -- receive/send RC+1 bytes between RF and the wire
; (RC pre-decremented by the caller, exactly mr.asm/ms.asm's own
; convention -- see below), no per-byte echo, no CRC computation
; inline (computed as a separate pass over the already-filled buffer
; -- see each caller's own sequencing). Structurally identical to
; mr.asm's readlp_uart/readlp_bitbang and ms.asm's sendloop_uart/
; sendloop_bitbang, DELIBERATELY down to the exact loop-termination
; idiom: a genuine hand-written SHORT branch (bnz, not lbnz left for
; -r to maybe shrink) is the entire reason -u/-b mode exists at all --
; every extra byte of branch overhead here is real risk of a dropped
; byte at high baud. The termination check itself (dec rc / ghi rc /
; xri $ff / bnz) relies on RC arriving PRE-DECREMENTED by 1: a real
; block is always exactly 128 or 1024 bytes (never 0) by protocol
; definition, so this needs no zero-count guard, matching mr.asm's own
; accepted convention exactly. Page-aligned via ".link .align page" so
; the short branch is guaranteed to fit on one page regardless of
; where this proc lands in the final linked program (see mr.asm's own
; header comment for the full reasoning -- confirmed necessary there
; via a real link failure, not just theoretical).
;
; Args:    RF = buffer, RC = byte count MINUS 1 (caller pre-decrements)
; Returns: nothing meaningful in D/DF
; Modifies: everything -- a leaf worker, not register-preserving.
;------------------------------------------------------------------

            .link   .align  page
            proc    ym_recv_block
            mov     rd, ym_io_mode
            ldn     rd
            xri     YM_IO_BITBANG
            lbz     yrb_bitbang

yrb_uart:
            call    f_uread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     yrb_uart

            rtn

yrb_bitbang:
            call    f_bread
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            bnz     yrb_bitbang

            rtn
            endp

            .link   .align  page
            proc    ym_send_block
            mov     rd, ym_io_mode
            ldn     rd
            xri     YM_IO_BITBANG
            lbz     ysb_bitbang

ysb_uart:
            lda     rf
            call    f_utype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     ysb_uart

            rtn

ysb_bitbang:
            lda     rf
            call    f_btype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     ysb_bitbang

            rtn
            endp

;------------------------------------------------------------------
; Shared data
;------------------------------------------------------------------
            proc    _ymodem_data
ym_io_mode:     db      0
ym_raw_digits:  ds      10

                public  ym_io_mode
                public  ym_raw_digits
            endp
