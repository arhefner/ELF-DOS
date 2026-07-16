;
; ms.asm - send a file via the MAX protocol
;
; Usage: MS [-u|-b] <filename>
;
; Companion to the host-side max-xfr tool (Elf-xfer/max-xfr), run as
; "max-xfr -r" to receive. mr and ms are two directions of the same
; protocol; see progs/mr.asm's own header comment for the full
; reasoning behind this file's structure (library-extraction goal,
; why ms_send is a real proc/endp block placed on its own page via
; ".link .align page").
;
; IMPORTANT, hardware-confirmed 2026-07-11: this file's own first
; hardware round found that RA is NOT safe to hold the send buffer's
; address across the many intervening K_READ/K_TYPE calls in the per-
; block loop below -- something inside repeated calls to those two
; (f_read/f_type) clobbers it, contrary to the assumption this file
; originally made (copied from the original Elf/OS ms.asm, which used
; the identical "cache a pointer in a register for the whole transfer"
; pattern and was, per the user, "very reliable" there -- so this is
; most likely a genuine ELF-DOS f_read/f_type behavior difference
; under repeated calls, not a design mistake ported from the
; original). Symptom was a byte-exact repeating 512-byte block
; throughout the received file instead of the real, varying content
; -- RA silently reset to some fixed value early on, then every
; "mov rf, ra" for the rest of the transfer read/sent that same wrong
; address's (unchanging) content instead of advancing through the
; real file. Fixed by moving the buffer address and the running
; "address" header field (ms_addr_hi/ms_addr_lo) out of RA/RB
; entirely -- see ms_buf and ms_addr_hi/lo below, and progs/mr.asm's
; own header comment (mr_cnt_hi/mr_cnt_lo) for the identical fix
; applied to that file's own R7 usage. Only R9's survival across
; f_msg/f_inmsg/f_idewrite has ever been confirmed (gotcha #8 in
; CLAUDE.md) -- nothing about K_READ/K_TYPE specifically was tested
; before this. sendloop_uart/sendloop_bitbang's own use of RC across
; their direct f_utype/f_btype calls (in the one loop that has to stay
; fast) is NOT independently confirmed either, but is indirectly
; supported by this fix producing a correctly-sized transfer end-to-
; end (same register, same call shape, no observed size/count
; corruption) -- left as-is rather than fixed, since fixing it would
; cost real throughput in the one loop where that matters most.
;
; Direct-device send loop (2026-07-12, added alongside progs/mr.asm's
; own identical feature): an optional "-u" (UART, the default) or "-b"
; (bit-bang) flag before the filename selects which BIOS routine
; sendloop_uart/sendloop_bitbang below calls directly for each outgoing
; byte, bypassing K_TYPE entirely -- no kernel jump-table hop, no
; f_type's own RAM-vector indirection through whatever "type" is
; currently patched to (the device-abstraction layer that lets a BIOS
; trap console I/O to something else, e.g. a directly connected
; keyboard or an OLED terminal -- see progs/mr.asm's own header
; comment for the user's fuller account of why that indirection exists
; and its likely connection to intermittent Elf/OS transfer failures).
; f_utype/f_btype (bios.inc, EBIOS+09h/+03h) are stable, already-
; established BIOS entry points that reach the hardware UART/bit-bang
; driver directly, independent of RE.1 and the device-abstraction
; layer (same as f_utest/f_btest). Added here on the user's own
; request for symmetry with mr.asm -- redirecting console I/O
; elsewhere (keyboard/OLED) shouldn't silently redirect the serial
; transfer protocol's own wire traffic too, so ms should reach the
; real serial port directly the same way mr now does. Deferred, not
; yet implemented: auto-selecting UART vs. bit-bang via an environment
; variable or an f_getdev probe once either exists -- for now the
; caller states it explicitly, defaulting to UART.

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   ms_send
            extrn   ms_sendbytes

XFER_BUF_LEN:   equ     512

; ms_send I/O mode selector (ms_io_mode, set once in start, read once
; per block in ms_send -- see sendloop_uart/sendloop_bitbang below)
MS_IO_UART:         equ     0           ; call f_utype directly (default)
MS_IO_BITBANG:      equ     1           ; call f_btype directly

; ms_send result codes (returned in D; 0 = success)
MSERR_HANDSHAKE:    equ     1           ; host's initial sync byte
                                        ; wasn't $AA
MSERR_READ:         equ     2           ; K_FILE_READ failed
MSERR_SEND:         equ     3           ; a header/block echo mismatch
MSERR_COMMAND:      equ     4           ; host's post-EOF response
                                        ; wasn't 'x'

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc (RC.0 alone is enough).
            ; argv[0] is this program's own name. argv[1] may be an
            ; optional "-u"/"-b" flag -- now a clean, standalone token
            ; (the shell's own tokenizer already split on whitespace,
            ; so no per-character space-boundary check is needed
            ; anymore, just a direct 2-character-plus-NUL comparison);
            ; the filename is argv[2] if a flag was given, else
            ; argv[1]. ms_io_mode (memory) records the choice, since
            ; ms_send -- a separate proc -- needs to read it once at
            ; block-entry time, outside the tight loop itself. Defaults
            ; to MS_IO_UART when no flag is given. See progs/mr.asm's
            ; own start for the identical, already-verified parsing
            ; logic this mirrors.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    not_flag

            inc     rf
            ldn     rf                  ; D = argv[1][1]
            plo     r8                  ; R8.0 = the flag letter (temp)

            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
                                        ; for "-u"/"-b" to be exactly
                                        ; this whole token
            lbnz    not_flag

            glo     r8                  ; D = flag letter again
            xri     'u'
            lbz     flag_uart
            glo     r8
            xri     'b'
            lbz     flag_bitbang
            lbr     not_flag            ; unrecognized letter -- fall
                                        ; back to treating argv[1]
                                        ; itself as the (probably
                                        ; invalid) filename

flag_uart:
            glo     rc
            smi     3
            lbnf    usage               ; flag given but argc < 3: no
                                        ; filename after it
            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (filename)
            mov     rf, ms_io_mode
            ldi     MS_IO_UART
            str     rf
            lbr     have_name_ptr

flag_bitbang:
            glo     rc
            smi     3
            lbnf    usage
            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (filename)
            mov     rf, ms_io_mode
            ldi     MS_IO_BITBANG
            str     rf
            lbr     have_name_ptr

not_flag:
            ; RD already holds argv[1]'s pointer, untouched by the
            ; flag-character checks above -- that's the filename
            mov     rf, ms_io_mode
            ldi     MS_IO_UART          ; default
            str     rf
            lbr     have_name_ptr

usage:
            call    K_INMSG
            db      "Usage: MS [-u|-b] <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name_ptr:
            mov     rf, rd              ; RF = filename
            mov     rd, ms_fcb_struct   ; RD = our FCB struct
            mov     ra, ms_iobuf        ; RA = our I/O buffer (movs
                                        ; before the mode load below,
                                        ; since mov clobbers D)
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    open_error

            ; BUG-CLASS GUARD: stash the handle before "mov rf, ..."
            ; clobbers D -- saved_handle is what K_FILE_CLOSE uses below,
            ; after ms_send (a leaf worker that clobbers everything)
            ; has long since destroyed D's original value.
            plo     r8                  ; R8.0 = handle (temp)
            mov     rf, saved_handle
            glo     r8
            str     rf                  ; saved_handle = handle

            glo     r8                  ; D = handle again, for ms_send
            call    ms_send             ; D = result code (0 = success)
            ; BUG-CLASS GUARD (see progs/type.asm/wtest.asm): stash the
            ; result before "mov rf, ..." for K_FILE_CLOSE's own arg
            ; setup clobbers D.
            plo     r8                  ; R8.0 = ms_send's result

            mov     rd, saved_handle
            ldn     rd
            call    K_FILE_CLOSE        ; result/DF here intentionally
                                        ; ignored -- ms_send's own
                                        ; result is what we report

            glo     r8
            lbnz    xfer_failed

            call    K_INMSG
            db      "File sent.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

xfer_failed:
            ; D = ms_send's numeric result code (1-4); print it
            ; alongside a generic message rather than maintaining four
            ; separate strings in this file too -- see ms_send's own
            ; header comment for what each code means.
            adi     '0'
            plo     r8
            call    K_INMSG
            db      "Transfer failed (error ",0
            glo     r8
            call    K_TYPE
            call    K_INMSG
            db      ").",13,10,0
            ldi     1
            rtn

open_error:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

ms_fcb_struct:  ds      FCB_LEN
ms_iobuf:       ds      FCB_IOBUF_LEN
saved_handle:   db      0
ms_io_mode:     db      0

;==================================================================
; ms_send: send an already-open file's contents over the console/
; serial port, using ELF-DOS's own MAX-derived transfer protocol.
;
; Args:    D = handle of an already-open file (mode 0 -- read)
; Returns: D  = 0 on success, MSERR_* on failure (see equ's above)
;          DF = 0 on success, DF = 1 on failure (redundant with D,
;               kept for consistency with this project's other calls)
; Clobbers: everything except the FCB itself and whatever the caller
;          separately preserved -- this is a leaf worker, not a
;          register-preserving subroutine. Does not close the FCB;
;          the caller does that once, after this returns, regardless
;          of success or failure -- see start/have_name_ptr above for
;          the identical pattern progs/mr.asm's start/have_name_ptr
;          also uses.
;
; Protocol (matches max-xfr's "-r" / receive mode):
;   1. Wait for $AA (sync) from the host. Reply with $55.
;   2. Per block: send $01 (more data follows), wait for it to be
;      echoed back, then send a 2-byte big-endian byte count and a
;      2-byte running address (protocol fidelity only -- see mr.asm's
;      note on why the address field goes unused on the receiving
;      end), each verified against its own echo before continuing.
;      The data bytes themselves follow with no per-byte echo
;      (throughput); wait for a final $AA ACK once the whole block
;      has been sent.
;   3. At end of file, send $00 instead of $01, then send a final 'x'
;      and finish -- no reply expected to the 'x'.
;
; Page-aligned (see .link .align page below): ms_send's whole body is
; well under 256 bytes, so aligning its start to a page boundary
; guarantees every branch directly within it is on the same page as
; its target. The two hand-written short branches for the actual byte-
; send loop live in a *separate* proc, ms_sendbytes, with its own
; independent page alignment -- see that proc's own header comment for
; why ms_send's own alignment isn't enough to cover them too.
;==================================================================

            .link   .align  page
            proc    ms_send
            plo     rc                  ; RC.0 = handle (temp)
            mov     rf, ms_handle
            glo     rc
            str     rf                  ; ms_handle = handle

            ; ms_addr (memory, not a register) tracks the running
            ; "address" header field (protocol fidelity only, unused
            ; by mr) -- see this file's header comment for why this
            ; can't be a register held across the many intervening
            ; K_READ/K_TYPE calls below.
            mov     rf, ms_addr_hi
            ldi     0
            str     rf
            mov     rf, ms_addr_lo
            ldi     0
            str     rf

;------------------------------------------------------------------
; Handshake: wait for $AA (sync) from the host, reply with $55.
;------------------------------------------------------------------
            call    K_READ
            xri     $aa
            lbz     ms_shake

            ldi     MSERR_HANDSHAKE
            lbr     ms_exit

ms_shake:   ldi     $55
            call    K_TYPE

;------------------------------------------------------------------
; Per-block loop.
;
; ms_handle (not a register) holds the handle across K_FILE_READ
; calls: file_read uses R9 as its own internal scratch and leaves it
; holding unrelated data on return (see progs/type.asm's own note), so
; nothing kept in a register here would reliably survive the call.
;------------------------------------------------------------------
ms_next:    mov     rf, ms_buf          ; RF = send buffer
            mov     rc, XFER_BUF_LEN
            mov     rd, ms_handle
            ldn     rd                  ; D = handle, RF/RC untouched
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    ms_rderr

            glo     rc
            lbnz    sendblk
            ghi     rc
            lbnz    sendblk

            ; RC == 0: end of file. Send the EOF marker, then wait for
            ; the host's final 'x'.
            ldi     0
            call    K_TYPE

            call    K_READ
            xri     'x'
            lbz     ms_success

            ldi     MSERR_COMMAND
            lbr     ms_exit

ms_success: ldi     0
            lbr     ms_exit

ms_rderr:   ldi     MSERR_READ
            lbr     ms_exit

;------------------------------------------------------------------
; sendblk: send one data block (ms_buf = buffer, RC = byte count > 0).
;
; Each header field (command byte, count hi/lo, address hi/lo) is sent
; then verified against its own echo before the next one goes out --
; matches the original protocol's own lock-step per-field handshake.
; The count/address fields use the stack (stxd/irx) to hold the just-
; sent value across the K_TYPE/K_READ pair for comparison -- already
; safe regardless of whether K_TYPE preserves D across the call, since
; stxd stashes the original value in memory (on the stack) before the
; call runs, not in a register (same reasoning as mr.asm's own
; mr_cmdbyte fix, just via the hardware stack instead of a named
; byte).
;------------------------------------------------------------------
sendblk:    ldi     1                   ; 'more data follows'
            call    K_TYPE
            call    K_READ
            xri     1
            lbnz    ms_snderr

            ghi     rc                  ; count high byte
            stxd
            call    K_TYPE
            call    K_READ
            irx
            xor
            lbnz    ms_snderr

            glo     rc                  ; count low byte
            stxd
            call    K_TYPE
            call    K_READ
            irx
            xor
            lbnz    ms_snderr

            mov     rf, ms_addr_hi
            ldn     rf                  ; D = address high byte
            stxd
            call    K_TYPE
            call    K_READ
            irx
            xor
            lbnz    ms_snderr

            mov     rf, ms_addr_lo
            ldn     rf                  ; D = address low byte
            stxd
            call    K_TYPE
            call    K_READ
            irx
            xor
            lbnz    ms_snderr

            ; ms_addr += rc: pure computation, no call in between, so a
            ; register (R7) is safe to use transiently here -- unlike
            ; the buffer pointer/header fields above, which must
            ; survive real K_READ/K_TYPE calls and so live in memory.
            ; Two separate loads (not lda's auto-increment) since
            ; ms_addr_hi/ms_addr_lo's adjacency in memory isn't relied
            ; on anywhere else in this file.
            mov     rf, ms_addr_hi
            ldn     rf
            phi     r7
            mov     rf, ms_addr_lo
            ldn     rf
            plo     r7
            add16   r7, rc
            mov     rf, ms_addr_hi
            ghi     r7
            str     rf
            mov     rf, ms_addr_lo
            glo     r7
            str     rf

            mov     rf, ms_buf          ; RF = send buffer
            dec     rc                  ; ms_sendbytes runs COUNT times
                                        ; when seeded with COUNT-1 --
                                        ; matches mr.asm's own receive-
                                        ; side loop exactly
            call    ms_sendbytes        ; sends RC+1 bytes from RF, via
                                        ; whichever device ms_io_mode
                                        ; selects -- a separate proc
                                        ; (own page-alignment, see its
                                        ; own header comment) since by
                                        ; this point in ms_send the
                                        ; handshake+header-echo code
                                        ; already preceding it pushes
                                        ; past where a single .link
                                        ; .align page at ms_send's own
                                        ; start could still guarantee
                                        ; in-page short branches here

            call    K_READ              ; final block ACK
            xri     $aa
            lbz     ms_next

ms_snderr:  ldi     MSERR_SEND

ms_exit:    ; D = result code (0 = success); set DF to match
            lbz     ms_ok
            stc
            lbr     ms_ret
ms_ok:      clc
ms_ret:     rtn

ms_handle:      db      0
ms_addr_hi:     db      0
ms_addr_lo:     db      0
ms_buf:         ds      XFER_BUF_LEN
            endp

;==================================================================
; ms_sendbytes: send one data block, byte by byte, via whichever
; device ms_io_mode currently selects. Split out into its own proc
; (rather than living inline in ms_send's own sendblk) specifically so
; it can carry its own ".link .align page" -- ms_send's own copy of
; that directive only guarantees a page-aligned proc *start*, and by
; the time control reaches the send loop, the handshake and the five-
; field header-echo exchange (each with its own stxd/call/call/irx/xor
; sequence) ahead of it have already pushed too far into the page for
; that single guarantee to cover a hand-written short branch way down
; here too (confirmed the hard way: linking without this split hit
; Link/02's own out-of-page short-branch abort). A second, independent
; proc gets its own fresh page anchor, exactly like mr.asm's own
; readlp_uart/readlp_bitbang rely on mr_receive's.
;
; Args:    RF = buffer, RC = count-1 (pre-decremented, same convention
;          the caller already used for the old inline loop)
; Returns: nothing meaningful in D/DF
; Clobbers: everything -- a leaf worker, not register-preserving.
;==================================================================

            .link   .align  page
            proc    ms_sendbytes
            mov     rd, ms_io_mode
            ldn     rd
            xri     MS_IO_BITBANG
            lbz     sendloop_bitbang

;------------------------------------------------------------------
; sendloop_uart / sendloop_bitbang: the one loop in this whole file
; that has to be fast -- see progs/mr.asm's own readlp_uart/
; readlp_bitbang for the full reasoning (same throughput constraint,
; same hand-written short branches). Both variants call their BIOS
; routine (f_utype/f_btype) directly instead of going through K_TYPE,
; skipping K_TYPE's own two indirection hops -- see this file's
; top-of-file header comment for the motivation.
;------------------------------------------------------------------
sendloop_uart:
            lda     rf
            call    f_utype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     sendloop_uart

            rtn

sendloop_bitbang:
            lda     rf
            call    f_btype

            dec     rc
            ghi     rc
            xri     $ff
            bnz     sendloop_bitbang

            rtn
            endp

            end     start
