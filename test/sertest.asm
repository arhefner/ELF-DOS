;
; sertest.asm - minimal serial-port connectivity diagnostic
;
; Usage: SERTEST [-u|-b] -s <string>
;        SERTEST [-u|-b] -r
;
; A deliberately tiny tool for testing raw serial connectivity,
; completely independent of the MR/MS/YR/YS batch protocols -- just
; "does a byte survive the trip, on this specific port." No device
; flag uses whatever the console currently is (K_READ/K_TYPE's own
; self-modified vector); -u/-b target the hardware (disk-board) UART
; or the onboard bit-banged UART directly instead, bypassing the
; console entirely -- same device-selection convention as MR/MS/YR/YS
; (see progs/mr.asm's own header comment for the full design). This
; exists specifically to isolate "is the wiring/baud/port right" from
; "is the batch protocol's own asm correct" when troubleshooting a
; transfer that isn't working -- built at the user's own request while
; debugging exactly that.
;
; -s <string>: sends <string>'s raw bytes out the selected port,
; followed by CR LF, then exits. Quote the string if it needs to
; contain spaces -- the shell's own tokenizer handles that as usual.
;
; -r: reads bytes from the selected port into a buffer via
; st_readbytes (see its own header comment -- a real, minimal, page-
; aligned hot loop, matching progs/mr.asm's own mr_readbytes shape
; exactly), stopping at the first CR or LF, or after SERTEST_MAX bytes
; if neither ever arrives, THEN prints the whole captured buffer at
; once (raw if printable ASCII, "[XX]" hex otherwise, "<CR>"/"<LF>"/
; "<full>" for how the capture ended). This two-phase "capture
; everything first, print it after" split is deliberate -- see
; st_readbytes's own header comment for why the ORIGINAL version of
; this file (reading one byte, then immediately classifying and
; printing it, then reading the next) was flagged as unable to keep up
; at high baud, and why that's now been eliminated: nothing in the
; timing-critical capture loop does anything but read+store+check-
; terminator.
;
; Blocking reads only -- K_READ/f_uread/f_bread have no timeout
; capability in this project (see lib/ymodem.asm's own header comment
; for the standing reasoning) -- if nothing ever arrives, -r simply
; waits forever; a hardware reset is the only way out in that case.
;
; Register-liveness discipline matches MR/MS: nothing survives more
; than one call to st_getbyte/st_putbyte (or K_READ/K_TYPE directly)
; in a register outside of st_readbytes's own hot loop (which needs
; none of that -- see its own header). The one exception, matching
; this whole project's own established, hardware-confirmed precedent
; (ms.asm's own sendloop_uart/sendloop_bitbang/msb_console): RF DOES
; survive repeated calls through K_TYPE specifically (not K_READ), so
; st_send's own loop keeps it as the running string pointer across
; each st_putbyte call.
;
; FILE ORDERING NOTE (gotcha #20 in CLAUDE.md): every flat (non-proc)
; label in this file, code or data, is deliberately placed BEFORE
; st_readbytes -- the one and only proc/endp block, which is always
; the LAST thing before "end start". Flat content sitting AFTER a
; proc's own endp anchors the WHOLE linked image at a stray low
; address instead of PROG_BASE (confirmed the hard way while building
; this very file: Link/02 reported "Lowest address: 0078" instead of
; "4000" the first time st_print_hex_byte/st_buf/etc. were placed
; after st_readbytes's endp). Don't add anything after st_readbytes
; without moving it back above.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   st_readbytes

SERTEST_IO_CONSOLE:     equ     0
SERTEST_IO_UART:        equ     1
SERTEST_IO_BITBANG:     equ     2

SERTEST_MAX:    equ     127     ; -r's own read cap, in case neither
                                ; CR nor LF ever arrives

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. An optional leading -u/-b
            ; (device flag), then a required -s <string> or -r.
            mov     rf, st_io_mode
            ldi     SERTEST_IO_CONSOLE  ; default
            str     rf

            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: need at least -s/-r

            mov     rf, st_i
            ldi     1
            str     rf

            ; --- does argv[1] look like a device flag? ---
            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    st_no_devflag

            mov     rf, rd
            inc     rf
            ldn     rf                  ; D = argv[1][1]
            plo     r8                  ; R8.0 = letter (temp)

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
            lbnz    st_no_devflag       ; not exactly 2 chars: not a
                                        ; device flag

            glo     r8
            xri     'u'
            lbz     st_devflag_uart
            glo     r8
            xri     'b'
            lbz     st_devflag_bitbang
            lbr     st_no_devflag       ; unrecognized letter

st_devflag_uart:
            mov     rf, st_io_mode
            ldi     SERTEST_IO_UART
            str     rf
            lbr     st_devflag_done
st_devflag_bitbang:
            mov     rf, st_io_mode
            ldi     SERTEST_IO_BITBANG
            str     rf

st_devflag_done:
            mov     rf, st_i
            ldi     2
            str     rf

st_no_devflag:
            ; --- argv[st_i] must be exactly "-s" or "-r" ---
            mov     rf, st_i
            ldn     rf
            str     r2                  ; M(X) = st_i (subtrahend)
            glo     rc
            sm                          ; D = argc - st_i
            lbnf    usage               ; argc < st_i: missing -s/-r

            mov     rf, st_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = st_i (zero-extended)
            shl16   r8                  ; R8 = st_i * 2
            mov     rb, ra
            add16   rb, r8              ; RB = &argv[st_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[st_i]

            mov     rf, rd
            ldn     rf
            xri     '-'
            lbnz    usage

            mov     rf, rd
            inc     rf
            ldn     rf
            plo     r9                  ; R9.0 = mode letter

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf
            lbnz    usage

            glo     r9
            xri     's'
            lbz     st_mode_send
            glo     r9
            xri     'r'
            lbz     st_mode_recv
            lbr     usage

st_mode_send:
            ; one more argv entry required: the string to send
            mov     rf, st_i
            ldn     rf
            adi     1
            str     r2                  ; M(X) = st_i+1 (subtrahend)
            glo     rc
            sm                          ; D = argc - (st_i+1)
            lbnf    usage               ; no string argument given

            mov     rf, st_i
            ldn     rf
            adi     1
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = (st_i+1) * 2
            mov     rb, ra
            add16   rb, r8              ; RB = &argv[st_i+1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = the string to send

            call    st_send
            ldi     0
            rtn

st_mode_recv:
            call    st_recv
            ldi     0
            rtn

usage:
            call    K_INMSG
            db      "Usage: SERTEST [-u|-b] -s <string>",13,10
            db      "       SERTEST [-u|-b] -r",13,10,0
            ldi     1
            rtn

st_io_mode:     db      0
st_i:           db      0

;------------------------------------------------------------------
; st_getbyte / st_putbyte: mode-aware single-byte read/write -- same
; 3-way dispatch as MR/MS/YR/YS (see progs/mr.asm's own header
; comment for the full device-selection design). Used only for the
; infrequent, once-per-call bytes in st_send below -- NOT by
; st_readbytes, which has its own separate, minimal dispatch (mode
; selected once per whole read, not once per byte) for exactly the
; timing reasons described in this file's own header comment.
;------------------------------------------------------------------
st_getbyte:
            mov     rd, st_io_mode
            ldn     rd
            xri     SERTEST_IO_BITBANG
            lbz     stg_bitbang
            ldn     rd
            xri     SERTEST_IO_UART
            lbz     stg_uart
            call    K_READ
            rtn
stg_uart:
            call    f_uread
            rtn
stg_bitbang:
            call    f_bread
            rtn

st_putbyte:
            plo     rb                  ; stash the byte -- the mov
                                        ; below clobbers D (gotcha #4)
            mov     rd, st_io_mode
            ldn     rd
            xri     SERTEST_IO_BITBANG
            lbz     stp_bitbang
            ldn     rd
            xri     SERTEST_IO_UART
            lbz     stp_uart
            glo     rb
            call    K_TYPE
            rtn
stp_uart:
            glo     rb
            call    f_utype
            rtn
stp_bitbang:
            glo     rb
            call    f_btype
            rtn

;------------------------------------------------------------------
; st_send: send the NUL-terminated string at RD out the selected
; port, followed by CR LF.
; Args:    RD = string
; Modifies: everything
;------------------------------------------------------------------
st_send:
            mov     rf, rd
st_send_loop:
            ldn     rf
            lbz     st_send_crlf
            call    st_putbyte          ; RF proven safe across
                                        ; repeated K_TYPE-family calls
                                        ; (see this file's own header
                                        ; comment) -- no reload needed
            inc     rf
            lbr     st_send_loop

st_send_crlf:
            ldi     13
            call    st_putbyte
            ldi     10
            call    st_putbyte

            call    K_INMSG
            db      "Sent.",13,10,0
            rtn

;------------------------------------------------------------------
; st_recv: capture bytes from the selected port into st_buf via
; st_readbytes (the hot loop -- see its own header comment for why
; this two-phase "capture everything first, THEN print it" split
; exists at all: printing/escaping per byte, inline in the hot loop,
; is exactly what made the original version of this routine too slow
; to keep up at high baud), then print the whole captured buffer at
; once (raw if printable ASCII, "[XX]" hex otherwise), followed by
; "<CR>"/"<LF>"/"<full>" for however the capture ended. This second
; pass has no timing pressure at all -- it runs entirely after
; st_readbytes has already returned -- so it can afford to be as
; call/comparison-heavy as it likes, and does: every register it uses
; across a call is either reloaded fresh from memory afterward, or is
; R9 specifically (the one register this project has confirmed safe
; across K_MSG/K_INMSG -- gotcha #8), never trusted otherwise.
; Modifies: everything
;------------------------------------------------------------------
st_recv:
            call    K_INMSG
            db      "Waiting...",13,10,0

            mov     rf, st_buf
            ldi     low (SERTEST_MAX-1)
            plo     rc
            ldi     high (SERTEST_MAX-1)
            phi     rc                  ; RC = SERTEST_MAX-1 (the hot
                                        ; loop runs SERTEST_MAX times
                                        ; when seeded with COUNT-1,
                                        ; matching mr.asm's own
                                        ; established convention)

            call    st_readbytes        ; RF left at content-end (see
                                        ; st_readbytes's own header
                                        ; comment); st_recv_term set

            mov     rd, st_buf
            sub16   rf, rd              ; RF = content length (bytes
                                        ; captured before the
                                        ; terminator, or the full
                                        ; capture if none arrived --
                                        ; correct either way, see
                                        ; st_readbytes's own header)
            mov     rd, st_recv_len
            ghi     rf
            str     rd
            inc     rd
            glo     rf
            str     rd                  ; st_recv_len = content length

            mov     rf, st_recv_idx
            ldi     0
            str     rf

st_recv_print_loop:
            mov     rf, st_recv_idx
            ldn     rf
            str     r2                  ; M(X) = idx (subtrahend)
            mov     rf, st_recv_len
            inc     rf
            ldn     rf                  ; D = st_recv_len's low byte
                                        ; (the high byte is always 0 --
                                        ; content length can never
                                        ; exceed SERTEST_MAX-1 = 126)
            sm                          ; D = len.lo - idx
            lbz     st_recv_print_done  ; idx == len: printed
                                        ; everything

            ; RF = &st_buf[idx] -- recomputed fresh every iteration,
            ; never trusted in a register across the calls below
            mov     rf, st_recv_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, st_buf
            add16   rf, r8

            ldn     rf
            smi     $20
            lbnf    st_recv_print_escaped   ; < $20: not printable
            ldn     rf
            smi     $7F
            lbdf    st_recv_print_escaped   ; >= $7F: not printable

            ldn     rf
            call    K_TYPE
            lbr     st_recv_print_next

st_recv_print_escaped:
            ldn     rf
            call    st_print_hex_escaped   ; prints "[XX]" for the
                                        ; byte in D -- self-contained,
                                        ; needs nothing from RF/R8 to
                                        ; survive it

st_recv_print_next:
            mov     rf, st_recv_idx
            ldn     rf
            adi     1
            str     rf
            lbr     st_recv_print_loop

st_recv_print_done:
            mov     rf, st_recv_term
            ldn     rf
            lbz     st_recv_print_full  ; 0 = buffer full, no
                                        ; terminator was ever seen
            xri     13
            lbz     st_recv_print_cr

            call    K_INMSG             ; must be LF (the only other
            db      "<LF>",0            ; value st_readbytes ever
            lbr     st_recv_summary     ; stores into st_recv_term)

st_recv_print_cr:
            call    K_INMSG
            db      "<CR>",0
            lbr     st_recv_summary

st_recv_print_full:
            call    K_INMSG
            db      "<full>",0

st_recv_summary:
            call    K_INMSG
            db      13,10,"Done.",13,10,0
            rtn

;------------------------------------------------------------------
; st_print_hex_escaped: print "[XX]" for the byte in D. Entirely
; self-contained -- callers don't need anything to survive across
; this call.
; Args:    D = the byte to print
; Modifies: everything
;------------------------------------------------------------------
st_print_hex_escaped:
            plo     r9                  ; R9 is the one register this
                                        ; project has confirmed safe
                                        ; across K_MSG/K_INMSG (gotcha
                                        ; #8) -- the only reason this
                                        ; is safe to hold across the
                                        ; call right below
            call    K_INMSG
            db      "[",0
            glo     r9
            call    st_print_hex_byte
            call    K_INMSG
            db      "]",0
            rtn

;------------------------------------------------------------------
; st_print_hex_byte: print D as 2 uppercase hex digits.
; Args:    D = the byte to print
; Modifies: everything
;------------------------------------------------------------------
st_print_hex_byte:
            ; BUG-CLASS GUARD: stash D via PLO before the mov below
            ; clobbers it.
            plo     rb
            mov     rf, st_hexbyte
            glo     rb
            str     rf                  ; st_hexbyte = the byte --
                                        ; memory, not a register,
                                        ; since st_print_nibble below
                                        ; calls K_TYPE and this value
                                        ; must survive that call

            ldn     rf
            shr
            shr
            shr
            shr                         ; D = byte >> 4 (high nibble)
            call    st_print_nibble

            mov     rf, st_hexbyte
            ldn     rf
            ani     $0F                 ; D = byte & $0F (low nibble)
            call    st_print_nibble
            rtn

;------------------------------------------------------------------
; st_print_nibble: print D (0-15) as one hex digit.
; Args:    D = nibble value, 0-15
; Modifies: everything
;------------------------------------------------------------------
st_print_nibble:
            plo     r8                  ; stash the nibble -- no call
                                        ; happens before this is
                                        ; consumed below, so a register
                                        ; is fine here
            smi     10
            lbnf    stn_digit           ; nibble < 10

            adi     'A'                 ; D = (nibble-10) + 'A'
            call    K_TYPE
            rtn

stn_digit:
            glo     r8                  ; D = the original nibble
                                        ; (reloaded -- the smi above
                                        ; left D wrapped/useless)
            adi     '0'
            call    K_TYPE
            rtn

st_buf:         ds      SERTEST_MAX
st_recv_len:    dw      0
st_recv_idx:    db      0
st_recv_term:   db      0
st_hexbyte:     db      0

;==================================================================
; st_readbytes: the one loop in this whole file that has to be fast --
; runs once per incoming byte with no per-byte handshake from the
; sender, so at the top end of whichever transport is in use every
; extra instruction here is real risk of an overrun and a dropped
; byte. Matches progs/mr.asm's own mr_readbytes shape exactly: the I/O
; mode is selected ONCE, outside the loop (NOT once per byte, unlike
; the original version of this file, which called st_getbyte -- its
; own per-call mode dispatch -- for every single byte, on top of doing
; full character classification and console printing per byte too;
; that design is what the user correctly flagged as unable to keep up
; at high baud, and is the reason this whole routine now exists as a
; separate, minimal, page-aligned proc rather than living inline in
; st_recv). No console I/O of any kind happens in here -- st_recv
; prints the captured content afterward, entirely outside the timing-
; critical window.
;
; Each of the three variants is a genuine hand-written short branch
; (bnz, not lbnz left for -r to maybe shrink) for the loop-back, page-
; aligned via .link .align page so it's guaranteed to fit on one page
; regardless of where this proc lands in the final program -- same
; reasoning, verbatim, as mr.asm's own header comment on mr_readbytes.
; Every byte is stored via "str rf" BEFORE the CR/LF check, so on a
; terminator match RF is left pointing AT the terminator's own slot
; (not yet advanced past it); on the "ran out of buffer space with no
; terminator" exit, RF has already been advanced past the last stored
; byte. Both cases are deliberate: st_recv computes content length as
; a plain "RF - buffer start" afterward, and this leaves that
; subtraction correct in both cases without needing a separate byte
; counter at all.
;
; MUST be the last thing in this file before "end start" -- see the
; file-ordering note in this file's own top-of-file header comment
; (gotcha #20): any flat content placed after this proc's own endp
; breaks the whole linked image's base address.
;
; Args:    RF = buffer, RC = max bytes to capture MINUS 1 (pre-
;          decremented, matching mr.asm's own established convention)
; Returns: RF = one past the last real content byte (see above);
;          st_recv_term = 0 (buffer filled, no terminator seen), 13
;          (stopped on CR), or 10 (stopped on LF)
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            .link   .align  page
            proc    st_readbytes

            mov     rd, st_io_mode
            ldn     rd
            xri     SERTEST_IO_BITBANG
            lbz     strb_bitbang
            ldn     rd
            xri     SERTEST_IO_UART
            lbz     strb_uart

strb_console:
            call    K_READ
            str     rf
            xri     13
            lbz     strb_got_cr
            ldn     rf
            xri     10
            lbz     strb_got_lf

            inc     rf
            dec     rc
            ghi     rc
            xri     $ff
            bnz     strb_console
            lbr     strb_got_full

strb_uart:
            call    f_uread
            str     rf
            xri     13
            lbz     strb_got_cr
            ldn     rf
            xri     10
            lbz     strb_got_lf

            inc     rf
            dec     rc
            ghi     rc
            xri     $ff
            bnz     strb_uart
            lbr     strb_got_full

strb_bitbang:
            call    f_bread
            str     rf
            xri     13
            lbz     strb_got_cr
            ldn     rf
            xri     10
            lbz     strb_got_lf

            inc     rf
            dec     rc
            ghi     rc
            xri     $ff
            bnz     strb_bitbang

strb_got_full:
            mov     r8, st_recv_term
            ldi     0
            str     r8
            rtn

strb_got_cr:
            mov     r8, st_recv_term
            ldi     13
            str     r8
            rtn

strb_got_lf:
            mov     r8, st_recv_term
            ldi     10
            str     r8
            rtn

            endp

            end     start
