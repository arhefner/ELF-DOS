;
; src_file.asm - the FILE data source for lib/pager.asm.
;
; Implements the pager's SOURCE CONTRACT over an ordinary ELF-DOS file:
; text split into lines at LF, with a bounded backward scan to find the
; line before a given position. See lib/pager.asm's own header for the
; contract itself and for what a different source would have to provide.
;
; A POSITION here is a byte offset into the file, in the kernel's own
; 32-bit big-endian form. The pager never interprets one -- it only
; stores positions and hands them back -- so another source is free to
; mean something else entirely by the same 4 bytes.
;
; Register discipline throughout is this project's usual defensive
; style: nothing is trusted to survive a kernel call, so every routine
; reloads what it needs from memory immediately before use.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

LESS_CHUNK_LEN:  equ    128         ; K_FILE_READ chunk size -- large,
                                    ; deliberately, to minimize the
                                    ; number of kernel calls per page.
                                    ; MUST stay <= 255: get_next_byte
                                    ; loads it via a single-byte "ldi"
                                    ; immediate (into RC's low byte) --
                                    ; 256 silently truncates to 0 with
                                    ; no assembler warning, which is
                                    ; exactly what shipped here first
                                    ; and made every K_FILE_READ ask
                                    ; for 0 bytes (a real hardware bug,
                                    ; found 2026-09-01: the file looked
                                    ; empty -- "(END)" on the very
                                    ; first screen, nothing else).
SRC_LINE_MAX:      equ  128         ; longest line kept (incl NUL)
LESS_BACKSCAN_LEN: equ  128         ; look-back window for src_prev_start's
                                    ; bounded backward scan

;------------------------------------------------------------------
; src_rewind: reset the source to the very beginning -- src_pos = 0 and
; every internal read buffer invalidated. Part of the SOURCE CONTRACT:
; it exists so the pager can start a session without reaching into
; source-private state (it used to zero less_chunk_remaining itself).
; Args:    (none)
; Returns: nothing
;------------------------------------------------------------------
            proc    src_rewind
            extrn   src_pos
            extrn   less_chunk_remaining
            extrn   zero4bytes

            mov     rf, src_pos
            call    zero4bytes

            mov     rf, less_chunk_remaining
            ldi     0
            str     rf

            mov     rf, src_pos
            call    src_seek_to
            rtn

            extrn   src_seek_to
            endp

            proc    src_close
            extrn   less_fcb
;------------------------------------------------------------------
; src_close: releases whatever the source holds open. Part of the
; SOURCE CONTRACT (see the block at the top of this file): the pager
; calls this and never touches an FCB -- a source with nothing to
; release (a memory or sector-range source) would just rtn.
; Args:    (none)   Returns: nothing
;------------------------------------------------------------------
            mov     rd, less_fcb
            call    K_FILE_CLOSE
            rtn
            endp

            proc    src_seek_to
            extrn   less_fcb
            extrn   less_chunk_remaining
;------------------------------------------------------------------
; src_seek_to: seeks the FCB to the 4-byte big-endian position at
; [RF], and resets the chunk buffer so the next byte read is genuinely
; fresh, not stale pre-seek content.
; Args:    RF = pointer to a 4-byte position
; Returns: nothing meaningful (K_FILE_SEEK's DF is ignored -- see
;          this file's own header comment on the accepted error-
;          handling simplification)
;------------------------------------------------------------------
            lda     rf
            phi     ra
            lda     rf
            plo     ra                  ; RA = high word
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = low word

            mov     rd, less_fcb
            ldi     0
            plo     rc                  ; whence = SEEK_SET
            call    K_FILE_SEEK

            mov     rf, less_chunk_remaining
            ldi     0
            str     rf
            rtn
            endp

            proc    src_prev_start
            extrn   zero4bytes
            extrn   less_fcb
            extrn   less_chunk_buf
            extrn   less_chunk_ptr
            extrn   less_chunk_remaining
            extrn   src_prev_in
            extrn   src_prev_result
            extrn   less_backscan_buf
            extrn   less_backscan_start
            extrn   less_backscan_count
            extrn   less_backscan_idx
            extrn   copy4bytes
;------------------------------------------------------------------
; src_prev_start: computes the start offset of the line
; immediately BEFORE the one starting at less_top, via a bounded
; backward scan -- there's no way to know it without actually reading
; the content, since a text file's lines have no fixed width. Bounded
; to a single LESS_BACKSCAN_LEN-byte look-back window; if no earlier
; LF is found within it (a pathologically long line), this gives up
; and uses the window's own start as an approximation -- never
; crashes or loops either way, and ordinary text files never come
; close to this limit.
;
; Uses its OWN scratch buffer (less_backscan_buf) and raw
; K_FILE_SEEK/K_FILE_READ calls, deliberately not touching
; less_chunk_buf/less_chunk_remaining/less_chunk_ptr (the forward-
; reading chunk state) at all -- safe regardless, since the caller
; (cmd_line_up) always calls src_seek_to right after this returns,
; which resets that state correctly no matter where this leaves the
; FCB's real position.
;
; Precondition: the position passed in is > 0 (checked by the caller --
; there's no earlier line at all when it is already 0).
; Args:    RF = pointer to a 4-byte position (the SOURCE CONTRACT's own
;               convention, same as src_seek_to's) -- copied to a private
;               slot at entry, so the caller's variable is never touched
;               and this routine never reaches into pager state.
; Returns: src_prev_result = the previous line's start offset
; Verified against an independent Python reference (a naive unbounded
; backward scan for the common case, checked across 2000+ random
; files/positions; a separate bounds/no-crash check for the window-
; exceeded case) before being trusted here (2026-09-01).
;------------------------------------------------------------------
            mov     rd, src_prev_in
            call    copy4bytes          ; src_prev_in = *RF (the caller's
                                        ; position, taken by value)

            ; less_backscan_start = src_prev_in - (LESS_BACKSCAN_LEN+1),
            ; clamped to 0 if that would underflow (i.e. the position is
            ; already within the window of the true file start) --
            ; the standard 4-byte SM/SMB borrow chain, LSB first, this
            ; project already uses elsewhere for 32-bit subtraction
            ; (e.g. progs/chkdsk.asm's own chk_sub32).
            mov     r7, src_prev_in
            add16   r7, 3               ; r7 -> src_prev_in+3 (LSB)
            mov     r8, less_backscan_start
            add16   r8, 3               ; r8 -> dest+3 (LSB)

            ldi     LESS_BACKSCAN_LEN+1
            str     r2
            ldn     r7
            sm
            str     r8

            dec     r7
            dec     r8
            ldi     0
            str     r2
            ldn     r7
            smb
            str     r8

            dec     r7
            dec     r8
            ldi     0
            str     r2
            ldn     r7
            smb
            str     r8

            dec     r7
            dec     r8
            ldi     0
            str     r2
            ldn     r7
            smb
            str     r8
            lbdf    lfp_start_ok        ; DF=1: no borrow -- src_prev_in
                                        ; was >= LESS_BACKSCAN_LEN+1
            mov     rf, less_backscan_start
            call    zero4bytes
lfp_start_ok:

            ; diff = src_prev_in - less_backscan_start (4 bytes, but only
            ; the LOW byte matters -- guaranteed to be 1..
            ; LESS_BACKSCAN_LEN+1 by construction: either
            ; less_backscan_start was clamped to 0 and diff==src_prev_in
            ; (which was < LESS_BACKSCAN_LEN+1 in that exact case), or
            ; it wasn't clamped and diff==LESS_BACKSCAN_LEN+1 exactly)
            mov     r7, src_prev_in
            add16   r7, 3
            mov     r8, less_backscan_start
            add16   r8, 3

            ldn     r8
            str     r2
            ldn     r7
            sm
            plo     r9                  ; R9.0 = diff's LSB -- the
                                        ; only byte this routine needs

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb                         ; higher bytes of diff are
                                        ; discarded (guaranteed 0)

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb

            ; read_count = diff.lsb - 1 (safe: diff.lsb is always >= 1)
            glo     r9
            smi     1
            plo     r9                  ; stash (gotcha #4 -- the mov
                                        ; below clobbers D)
            mov     rf, less_backscan_count
            glo     r9
            str     rf

            ; seek to less_backscan_start
            mov     rf, less_backscan_start
            lda     rf
            phi     ra
            lda     rf
            plo     ra
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

            mov     rd, less_fcb
            ldi     0
            plo     rc                  ; whence = SEEK_SET
            call    K_FILE_SEEK

            ; read less_backscan_count bytes into less_backscan_buf
            mov     rd, less_fcb
            mov     rf, less_backscan_buf
            mov     rb, less_backscan_count
            ldn     rb
            plo     rc
            ldi     0
            phi     rc
            call    K_FILE_READ         ; RC = bytes actually read

            glo     rc
            lbnz    lfp_have_bytes
            ghi     rc
            lbnz    lfp_have_bytes
            mov     rf, less_backscan_start
            mov     rd, src_prev_result
            call    copy4bytes          ; nothing read at all: fall
                                        ; back to the window's own start
            rtn

lfp_have_bytes:
            ; scan index = RC's low byte, minus 1 (RC <= LESS_BACKSCAN_LEN,
            ; always fits in a byte for a real read against this
            ; routine's own request size)
            glo     rc
            smi     1
            plo     r9                  ; stash briefly (gotcha #4 --
                                        ; the mov below clobbers D)
            mov     rf, less_backscan_idx
            glo     r9
            str     rf

lfp_scan_loop:
            mov     rf, less_backscan_idx
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            mov     r8, less_backscan_buf
            add16   r8, r9
            ldn     r8
            xri     10                  ; LF?
            lbz     lfp_found

            mov     rf, less_backscan_idx
            ldn     rf
            lbz     lfp_not_found       ; just checked index 0, no
                                        ; match anywhere -- stop
                                        ; (post-test: avoids needing
                                        ; to represent index -1)

            mov     rf, less_backscan_idx
            ldn     rf
            smi     1
            str     rf
            lbr     lfp_scan_loop

lfp_found:
            ; src_prev_result = less_backscan_start + (less_backscan_idx+1)
            mov     rf, less_backscan_start
            mov     rd, src_prev_result
            call    copy4bytes

            mov     rf, less_backscan_idx
            ldn     rf
            adi     1
            plo     r9
            ldi     0
            phi     r9                  ; r9 = the small delta (1..
                                        ; LESS_BACKSCAN_LEN)

            mov     r7, src_prev_result
            add16   r7, 3               ; r7 -> src_prev_result+3 (LSB)

            glo     r9
            str     r2
            ldn     r7
            add
            str     r7

            dec     r7
            ghi     r9
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7
            rtn

lfp_not_found:
            mov     rf, less_backscan_start
            mov     rd, src_prev_result
            call    copy4bytes
            rtn
            endp

            proc    src_read_line
            extrn   less_fcb
            extrn   src_pos
            extrn   src_line_buf
            extrn   less_chunk_buf
            extrn   less_chunk_ptr
            extrn   less_chunk_remaining
            extrn   less_linelen
            extrn   less_consumed
;------------------------------------------------------------------
; src_read_line: reads one line starting at the current position
; into src_line_buf (NUL-terminated, capped at SRC_LINE_MAX-1
; chars -- excess bytes are still consumed so offset tracking stays
; correct, just not kept), consuming through the terminating LF if
; present. A final line with no trailing LF is still returned once
; (DF=0) before the following call reports true EOF (DF=1) -- same
; convention this project's own K_INPUTL/read_line_ex EOF signaling
; already established. Advances src_pos by the number of bytes
; actually consumed.
; Returns: DF=0 -- src_line_buf holds a real (possibly empty) line
;          DF=1 -- nothing left to read at all
;------------------------------------------------------------------
            mov     rf, less_consumed
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; less_consumed = 0
            mov     rf, less_linelen    ; (clobbers D -- gotcha #4)
            ldi     0
            str     rf                  ; less_linelen = 0

rlh_loop:
            call    get_next_byte       ; D = byte, DF=1 if none at all
            lbdf    rlh_eof_check

            plo     r7                  ; stash the byte (short-lived
                                        ; register hold -- no call
                                        ; happens before it's read
                                        ; back below)

            mov     rf, less_consumed
            ldn     rf
            adi     1
            str     rf
            lbnf    rlh_have_byte       ; no carry out of low byte
            inc     rf
            ldn     rf
            adi     1
            str     rf
rlh_have_byte:

            glo     r7                  ; D = the byte again
            xri     10                  ; LF?
            lbz     rlh_done            ; consumed count already
                                        ; includes the LF -- line done

            ; ordinary character -- store into src_line_buf if room
            mov     rf, less_linelen
            ldn     rf
            smi     SRC_LINE_MAX-1
            lbdf    rlh_loop            ; already full -- discard,
                                        ; keep consuming

            mov     rf, less_linelen
            ldn     rf                  ; D = linelen (write index)
            plo     r8
            ldi     0
            phi     r8
            mov     rf, src_line_buf
            add16   rf, r8              ; RF = &src_line_buf[linelen]
            glo     r7                  ; D = the byte
            str     rf

            mov     rf, less_linelen
            ldn     rf
            adi     1
            str     rf
            lbr     rlh_loop

rlh_eof_check:
            mov     rf, less_consumed
            ldn     rf
            lbnz    rlh_done            ; low byte nonzero: got some
                                        ; content -- a final partial
                                        ; line, not true EOF
            inc     rf
            ldn     rf
            lbnz    rlh_done
            stc                         ; truly nothing -- DF=1
            rtn

rlh_done:
            mov     rf, less_linelen
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, src_line_buf
            add16   rf, r8
            ldi     0
            str     rf                  ; NUL-terminate

            ; less_consumed is written LOW-byte-first (the increment
            ; loop above treats +0 as the low byte, carrying into +1
            ; only on overflow past 255) -- read it back in the SAME
            ; order. An earlier version of this read it +0=high/+1=low
            ; (the natural-looking order for a dw, but backwards from
            ; how this specific counter is actually incremented),
            ; which multiplied every real delta by 256 -- caught via a
            ; literal instruction-level simulation of a real multi-line
            ; page (2026-09-01), not by static review: the effect is
            ; silent-but-catastrophic (src_pos/less_top jump to a
            ; wild offset every single line), yet forward paging could
            ; still look superficially plausible whenever the garbage
            ; offset happened to land inside other real text.
            mov     r8, less_consumed
            lda     r8
            plo     rd
            ldn     r8
            phi     rd                  ; RD = the 16-bit delta
            call    src_pos_add16

            clc
            rtn

;------------------------------------------------------------------
; get_next_byte: pulls the next raw byte from the file via a small
; chunk buffer, refilling it from disk (K_FILE_READ) as needed.
; Returns: D = byte, DF=0 -- or DF=1 if the file is exhausted.
;------------------------------------------------------------------
get_next_byte:
            mov     rf, less_chunk_remaining
            ldn     rf
            lbnz    gnb_have

            mov     rd, less_fcb
            mov     rf, less_chunk_buf
            ldi     LESS_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
            call    K_FILE_READ         ; RC = bytes actually read

            glo     rc
            lbnz    gnb_got_some
            ghi     rc
            lbnz    gnb_got_some
            stc                         ; 0 bytes: exhausted
            rtn

gnb_got_some:
            mov     rf, less_chunk_remaining
            glo     rc
            str     rf                  ; RC <= LESS_CHUNK_LEN <= 255,
                                        ; so the low byte alone is enough
            mov     r8, less_chunk_buf
            mov     rf, less_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; less_chunk_ptr = less_chunk_buf

gnb_have:
            mov     rf, less_chunk_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = the pointer's value

            ldn     r8                  ; D = the actual byte
            plo     r7                  ; stash briefly

            inc     r8
            mov     rf, less_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; write the advanced pointer back

            mov     rf, less_chunk_remaining
            ldn     rf
            smi     1
            str     rf

            glo     r7
            clc
            rtn

;------------------------------------------------------------------
; src_pos_add16: src_pos (4 bytes, big-endian, at src_pos+0..+3)
; += RD (a 16-bit delta). Same proven "4 individual byte steps, LSB
; first, ADD then ADC x3, str r2 immediately consumed by the next
; add/adc with nothing in between" shape as progs/chkdsk.asm's own
; chk_add32 -- independently hand-verified here against a concrete
; example (0x0000FFFF + 0x0002 = 0x00010001) before being trusted.
; Modifies: R7 (and D). RD's bytes are consumed, not needed after.
;------------------------------------------------------------------
src_pos_add16:
            mov     r7, src_pos
            add16   r7, 3               ; R7 -> src_pos+3 (LSB byte)

            glo     rd
            str     r2
            ldn     r7
            add                         ; D = pos.b3 + rd.lo, DF=carry
            str     r7

            dec     r7
            ghi     rd
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7

            rtn
            endp

            proc    _src_file_data
            .link   .align  32          ; the FCB must not straddle a page
                                        ; (K_FILE_OPEN rejects one that
                                        ; does) -- ".link .align" moves the
                                        ; proc's own base, so it only works
                                        ; as the FIRST thing in the proc,
                                        ; with the FCB immediately after it.
                                        ; See docs/DEVELOPER_GUIDE.md.
less_fcb:               ds      FCB_LEN
less_iobuf:             ds      FCB_IOBUF_LEN

; --- shared with the pager (part of the source contract) ---
src_pos:                ds      4       ; current read position (MSB-first)
src_line_buf:           ds      SRC_LINE_MAX

; --- private: the forward-reading chunk buffer ---
less_chunk_buf:         ds      LESS_CHUNK_LEN
less_chunk_ptr:         dw      0
less_chunk_remaining:   db      0
less_linelen:           db      0
less_consumed:          dw      0

; --- private: src_prev_start's own by-value argument, its result, and
;     the bounded backward-scan window ---
src_prev_in:            ds      4
src_prev_result:        ds      4
less_backscan_buf:      ds      LESS_BACKSCAN_LEN
less_backscan_start:    ds      4
less_backscan_count:    db      0
less_backscan_idx:      db      0

                public  less_fcb
                public  less_iobuf
                public  src_pos
                public  src_line_buf
                public  less_chunk_buf
                public  less_chunk_ptr
                public  less_chunk_remaining
                public  less_linelen
                public  less_consumed
                public  src_prev_in
                public  src_prev_result
                public  less_backscan_buf
                public  less_backscan_start
                public  less_backscan_count
                public  less_backscan_idx
            endp
