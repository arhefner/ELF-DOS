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
            extrn   get_next_byte
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

;------------------------------------------------------------------
; get_next_byte: pulls the next raw byte from the file via a small
; chunk buffer, refilling it from disk (K_FILE_READ) as needed.
; Its own proc (rather than a label inside src_read_line, where it
; started) because src_search reads the file as a plain byte stream
; too -- both callers go through this one buffered reader.
; Returns: D = byte, DF=0 -- or DF=1 if the file is exhausted.
; Modifies: R7, R8, RC, RD, RF
;------------------------------------------------------------------
            proc    get_next_byte
            extrn   less_fcb
            extrn   less_chunk_buf
            extrn   less_chunk_ptr
            extrn   less_chunk_remaining

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
            endp

;------------------------------------------------------------------
; src_search: find the pattern's bytes at or after a start position.
;
; The pattern is a COUNTED byte string, not a NUL-terminated one -- the
; pager parses escapes ("\n", "\x38", ...) before calling, so a pattern
; can contain any byte at all, $00 included. What those bytes MEAN is
; this source's business: here they are matched against the file's raw
; content, so a pattern may span a line boundary and may contain the
; line terminator itself.
;
; Scanning is a single forward pass over get_next_byte, with a re-seek
; only when a partial match fails (i.e. the first byte matched but a
; later one did not). A failed FIRST byte costs nothing -- the stream
; is already positioned on the next candidate -- so the common case is
; one sequential read of the file, not a seek per byte.
;
; Args:    RF   = pattern bytes (not NUL-terminated)
;          RC.0 = pattern length, 1..255
;          RD   = pointer to a 4-byte start position
; Returns: DF=0 -- found:
;            src_search_top    = start of the LINE containing the match
;                                (what the pager displays; a different
;                                source would round to its own row)
;            src_search_resume = start of the line AFTER the match,
;                                where a following search resumes
;          DF=1 -- no match at or after the start position.
; Leaves the source's own read position and src_pos unspecified: every
; caller follows a search with a seek of its own.
; Modifies: everything.
;------------------------------------------------------------------
            proc    src_search
            extrn   get_next_byte
            extrn   src_seek_to
            extrn   copy4bytes
            extrn   src_search_top
            extrn   src_search_resume
            extrn   ss_pat
            extrn   ss_len
            extrn   ss_i
            extrn   ss_last
            extrn   ss_cand
            extrn   ss_cur
            extrn   ss_line
            extrn   ss_cand_line

            ; --- stash every argument before anything can clobber it ---
            mov     r8, ss_pat
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8                  ; ss_pat = RF

            mov     r8, ss_len          ; (clobbers D -- gotcha #4)
            glo     rc
            str     r8                  ; ss_len = RC.0

            mov     rf, rd
            mov     rd, ss_cand
            call    copy4bytes          ; ss_cand = *RD

            mov     rf, ss_cand
            mov     rd, ss_cur
            call    copy4bytes
            mov     rf, ss_cand
            mov     rd, ss_line
            call    copy4bytes          ; ss_cur = ss_line = ss_cand

            mov     rf, ss_len
            ldn     rf
            lbz     ss_notfound         ; empty pattern never matches

            mov     rf, ss_cand
            call    src_seek_to

ss_scan:
            ; this position is the candidate: remember it and the line
            ; it sits on BEFORE consuming the byte
            mov     rf, ss_cur
            mov     rd, ss_cand
            call    copy4bytes
            mov     rf, ss_line
            mov     rd, ss_cand_line
            call    copy4bytes

            call    get_next_byte
            lbdf    ss_notfound
            plo     r9                  ; stash the byte (gotcha #4)

            mov     rf, ss_cur
            call    ss_bump             ; ss_cur++

            glo     r9
            str     r2
            ldn     r2
            xri     10
            lbnz    ss_scan_not_lf
            mov     rf, ss_cur          ; the byte WAS an LF: the next
            mov     rd, ss_line         ; position starts a new line
            call    copy4bytes

ss_scan_not_lf:
            ; remember it, in case the whole match turns out to be
            ; just this one byte (see ss_found's resume handling)
            mov     rf, ss_last
            glo     r9
            str     rf

            mov     rf, ss_pat
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = pattern
            ldn     r8                  ; D = pattern[0]
            str     r2
            glo     r9
            sm                          ; byte - pattern[0]
            lbnz    ss_scan             ; no: next candidate, no seek

            ; first byte matched -- verify the rest
            mov     rf, ss_i
            ldi     1
            str     rf

ss_verify:
            mov     rf, ss_i
            ldn     rf
            str     r2
            mov     rf, ss_len
            ldn     rf
            sm                          ; len - i
            lbz     ss_found            ; i == len: whole pattern matched

            call    get_next_byte
            lbdf    ss_notfound
            plo     r9

            mov     rf, ss_cur
            call    ss_bump

            ; deliberately do NOT advance ss_line here: on a mismatch
            ; we re-seek back to ss_cand+1, and ss_line must still
            ; describe THAT position, not wherever verification got to
            mov     rf, ss_last
            glo     r9
            str     rf

            mov     rf, ss_pat
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, ss_i
            ldn     rf
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r8
            adci    0
            phi     r8                  ; R8 = pattern + i
            ldn     r8
            str     r2
            glo     r9
            sm
            lbnz    ss_mismatch

            mov     rf, ss_i
            ldn     rf
            adi     1
            str     rf
            lbr     ss_verify

ss_mismatch:
            ; step past this candidate and resume the sequential scan
            ; from there. ss_line is still correct for ss_cand+1: it
            ; was advanced above only if the CANDIDATE byte was an LF,
            ; in which case ss_cand+1 is exactly the new line's start.
            mov     rf, ss_cand
            call    ss_bump
            mov     rf, ss_cand
            mov     rd, ss_cur
            call    copy4bytes
            mov     rf, ss_cand
            call    src_seek_to
            lbr     ss_scan

ss_found:
            mov     rf, ss_cand_line
            mov     rd, src_search_top
            call    copy4bytes

            ; resume at the start of the next line. If the match's own
            ; last byte was the LF, we are already there -- scanning on
            ; would skip a whole line.
            mov     rf, ss_last
            ldn     rf
            xri     10
            lbz     ss_resume_here

ss_resume_loop:
            call    get_next_byte
            lbdf    ss_resume_here      ; EOF: resume there, so a
                                        ; following search reports
                                        ; "not found" immediately
            plo     r9
            mov     rf, ss_cur
            call    ss_bump
            glo     r9
            xri     10
            lbnz    ss_resume_loop

ss_resume_here:
            mov     rf, ss_cur
            mov     rd, src_search_resume
            call    copy4bytes
            clc
            rtn

ss_notfound:
            stc
            rtn

;------------------------------------------------------------------
; ss_bump: the 4-byte big-endian value at [RF] += 1, LSB first with
; carry propagated -- the same shape as src_pos_add16's own chain.
; Args: RF = pointer to a 4-byte value.  Modifies: R7, D, DF
;------------------------------------------------------------------
ss_bump:
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7                  ; R7 -> byte 3 (LSB)
            ldn     r7
            adi     1
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

            dec     r7
            ldi     0
            str     r2
            ldn     r7
            adc
            str     r7
            rtn
            endp

;------------------------------------------------------------------
; src_open: open the named file and learn its size.
;
; Part of the SOURCE CONTRACT. Opening was deliberately left OUT of the
; contract when the pager was first split out (2026-09-08), on the
; reasoning that a memory or sector source has nothing to open -- but
; that was the wrong call twice over. It left progs/less.asm reaching
; directly into less_fcb/less_iobuf, which are source-private; and a
; sector source does have setup of its own (which drive), it just is
; not a file open. RF is therefore "whatever identifies the data" --
; a path here, a drive spec elsewhere.
;
; The size is captured here, once, via K_STAT. This is also what turned
; up the K_FILE_SEEK gap fixed the same day: its return used to carry
; only the low word of the resulting position, so a SEEK_END could not
; report the size of a file over 64K at all. That is fixed (RA:RD now
; carry the full 32 bits), so a SEEK_END would work here too -- K_STAT
; is kept because it answers exactly and without moving the file
; position, which a SEEK_END would.
;
; Args:    RF = pointer to a NUL-terminated path
; Returns: DF=0 opened, src_size holds the byte count;  DF=1 failed
; Modifies: everything
;------------------------------------------------------------------
            proc    src_open
            extrn   less_fcb
            extrn   less_iobuf
            extrn   src_size
            extrn   src_stat_buf
            extrn   src_open_path

            mov     r8, src_open_path   ; keep the path: K_FILE_OPEN
            ghi     rf                  ; clobbers RF
            str     r8
            inc     r8
            glo     rf
            str     r8

            mov     rd, less_fcb
            mov     ra, less_iobuf
            ldi     0                   ; mode 0 = read
            call    K_FILE_OPEN
            lbdf    sop_fail

            mov     rf, src_open_path
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            mov     rd, src_stat_buf
            call    K_STAT
            lbdf    sop_nosize

            mov     rf, src_stat_buf
            add16   rf, DIRENT_SIZE
            mov     rd, src_size
            call    copy4bytes
            clc
            rtn

sop_nosize:
            ; opened, but the size is unknown -- treat it as 0 so
            ; src_last_page just lands at the top rather than
            ; misbehaving. The file is still perfectly readable.
            mov     rf, src_size
            call    zero4bytes
            clc
            rtn

sop_fail:
            stc
            rtn

            extrn   copy4bytes
            extrn   zero4bytes
            endp

;------------------------------------------------------------------
; src_last_page: the position of the first of the LAST n lines --
; what the pager needs to display the end of the file.
;
; Walks BACKWARD n times from the end with src_prev_start, instead of
; the pager's previous approach of reading the whole file forward
; while keeping a sliding window of the last n line starts. That was
; O(file size); this is O(n) bounded backward scans, and n is one
; screen. Only the source can do it, since only the source knows what
; a "line" is -- a fixed-width source would just subtract.
;
; Stepping back n times is right for both shapes of file. When the
; file ends with a newline the end position is the start of a phantom
; empty line, so one step back lands on the last real line; when it
; does not, the end position is mid-line and one step back lands on
; that same last line's start (src_prev_start's window excludes the
; byte immediately before its argument, so a mid-line argument finds
; the start of its OWN line). Either way step 1 is the last line and
; step n is the (n-1)th line before it.
;
; Args:    D = n (number of display lines; 1..255)
; Returns: src_goto_result = the position to display from. Never
;          fails: it clamps at 0 for a file shorter than n lines.
; Modifies: everything
;------------------------------------------------------------------
            proc    src_last_page
            extrn   src_size
            extrn   src_goto_result
            extrn   src_prev_result
            extrn   src_prev_start
            extrn   copy4bytes
            extrn   slp_n

            plo     r7                  ; stash n (gotcha #4)
            mov     rf, slp_n
            glo     r7
            str     rf

            mov     rf, src_size
            mov     rd, src_goto_result
            call    copy4bytes          ; walk back from the end

slp_loop:
            mov     rf, slp_n
            ldn     rf
            lbz     slp_done            ; n steps taken

            ; stop at the very start of the file -- src_prev_start's
            ; own precondition is a position > 0
            mov     rf, src_goto_result
            ldn     rf
            lbnz    slp_step
            inc     rf
            ldn     rf
            lbnz    slp_step
            inc     rf
            ldn     rf
            lbnz    slp_step
            inc     rf
            ldn     rf
            lbz     slp_done            ; all four bytes zero

slp_step:
            mov     rf, src_goto_result
            call    src_prev_start
            mov     rf, src_prev_result
            mov     rd, src_goto_result
            call    copy4bytes

            mov     rf, slp_n
            ldn     rf
            smi     1
            str     rf
            lbr     slp_loop

slp_done:
            rtn
            endp

;------------------------------------------------------------------
; src_goto: turn a user-typed number into a position to display.
;
; Part of the SOURCE CONTRACT, and the point at which the number the
; pager collected stops being an abstraction: HERE it is a 1-based
; LINE NUMBER, because that is what a number means for a text file. A
; fixed-width source reads the same number as a byte offset and just
; masks it down to its row -- the pager never has to know which.
;
; Counts LFs forward from the start. There is no index to consult, so
; this is inherently O(position); that is the honest cost of a line
; number over a byte offset, and it is bounded by the file size.
;
; Args:    RF = pointer to a 4-byte count (1-based; 0 is treated as 1)
; Returns: DF=0 -- src_goto_result = the start of that line
;          DF=1 -- the count is past the end of the data. The pager
;                  decides what to do (it shows the last page, the
;                  same as 'G'), because that is a display policy, not
;                  a property of the data.
; Modifies: everything
;------------------------------------------------------------------
            proc    src_goto
            extrn   src_goto_result
            extrn   src_goto_want
            extrn   src_goto_line
            extrn   src_goto_pos
            extrn   get_next_byte
            extrn   src_seek_to
            extrn   copy4bytes
            extrn   zero4bytes

            mov     rd, src_goto_want
            call    copy4bytes          ; src_goto_want = *RF

            mov     rf, src_goto_result
            call    zero4bytes
            mov     rf, src_goto_pos
            call    zero4bytes
            mov     rf, src_goto_line
            call    zero4bytes
            mov     rf, src_goto_line
            inc     rf
            inc     rf
            inc     rf
            ldi     1
            str     rf                  ; we start on line 1, at 0

            ; line 0 or 1 is the top of the file -- already the answer
            mov     rf, src_goto_want
            call    sg_is_le_one
            lbdf    sg_done

            mov     rf, src_goto_result
            call    src_seek_to         ; result is still 0 here

sg_loop:
            call    get_next_byte
            lbdf    sg_past_end
            plo     r9

            mov     rf, src_goto_pos
            call    sg_bump             ; pos++

            glo     r9
            xri     10
            lbnz    sg_loop             ; not a line ending

            ; a new line starts at the current position
            mov     rf, src_goto_line
            call    sg_bump
            mov     rf, src_goto_pos
            mov     rd, src_goto_result
            call    copy4bytes

            ; reached the wanted line?
            mov     rf, src_goto_line
            mov     rd, src_goto_want
            call    sg_equal
            lbnf    sg_loop
sg_done:
            clc
            rtn

sg_past_end:
            stc
            rtn

;------------------------------------------------------------------
; sg_is_le_one: DF=1 iff the 4-byte value at [RF] is 0 or 1.
;------------------------------------------------------------------
sg_is_le_one:
            ldn     rf
            lbnz    sg_gt_one
            inc     rf
            ldn     rf
            lbnz    sg_gt_one
            inc     rf
            ldn     rf
            lbnz    sg_gt_one
            inc     rf
            ldn     rf
            smi     2
            lbnf    sg_le_one           ; < 2
sg_gt_one:
            clc
            rtn
sg_le_one:
            stc
            rtn

;------------------------------------------------------------------
; sg_equal: DF=1 iff the 4-byte values at [RF] and [RD] are equal.
;------------------------------------------------------------------
sg_equal:
            ldi     4
            plo     r7
sg_eq_loop:
            lda     rd
            str     r2
            lda     rf
            sm
            lbnz    sg_ne
            dec     r7
            glo     r7
            lbnz    sg_eq_loop
            stc
            rtn
sg_ne:
            clc
            rtn

;------------------------------------------------------------------
; sg_bump: the 4-byte big-endian value at [RF] += 1.
;------------------------------------------------------------------
sg_bump:
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7
            ldn     r7
            adi     1
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

; --- src_search's results (read by the pager) and its own scratch ---
src_search_top:         ds      4
src_search_resume:      ds      4
ss_pat:                 dw      0
ss_len:                 db      0
ss_i:                   db      0
ss_last:                db      0
ss_cand:                ds      4
ss_cur:                 ds      4
ss_line:                ds      4
ss_cand_line:           ds      4

; --- src_open / src_last_page ---
src_size:               ds      4       ; byte count, captured at open
src_goto_result:        ds      4       ; src_last_page's answer
src_open_path:          dw      0
slp_n:                  db      0
src_stat_buf:           ds      DIRENT_LEN
src_goto_want:          ds      4
src_goto_line:          ds      4
src_goto_pos:           ds      4

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
                public  src_search_top
                public  src_search_resume
                public  ss_pat
                public  ss_len
                public  ss_i
                public  ss_last
                public  ss_cand
                public  ss_cur
                public  ss_line
                public  ss_cand_line
                public  src_size
                public  src_goto_result
                public  src_open_path
                public  slp_n
                public  src_stat_buf
                public  src_goto_want
                public  src_goto_line
                public  src_goto_pos
            endp
