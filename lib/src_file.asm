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
SRC_LINE_MAX:      equ  256         ; src_line_buf size (incl NUL). Holds one
                                    ; wrap ROW, or the VISIBLE window of a
                                    ; nowrap (-S) line -- both at most one
                                    ; screen wide. less_width is COLUMNS-1,
                                    ; up to 255, so 256 covers the widest
                                    ; terminal without truncating a full-
                                    ; width row. In -S the horizontal skip
                                    ; happens in src_read_line (not the
                                    ; pager), so this need only hold the
                                    ; window, never a long line's prefix --
                                    ; that is what lets scroll reach
                                    ; arbitrarily far. linelen stays a byte
                                    ; (max 255).
LESS_BACKSCAN_LEN: equ  1024        ; look-back window for src_prev_start's
                                    ; backward scan. Big (2026-09-11):
                                    ; each window costs one K_FILE_SEEK,
                                    ; which walks the FAT chain from the
                                    ; start (O(offset)), so a bigger
                                    ; window is far fewer seeks for a long
                                    ; line. CLAUDE.md (mostly >128-char
                                    ; lines) drew G in 7.7M instructions
                                    ; with a 128-byte window. Must stay a
                                    ; power of two <= 32768.
SL_BUF_LEN:        equ  512         ; src_line_of's read size: large, so a
                                    ; long count spends its time counting
                                    ; rather than in per-call overhead

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
            extrn   zero4bytes
            extrn   sl_anchor_pos
            extrn   sl_anchor_line

            ; src_line_of's anchor: position 0 is line 1
            mov     rf, sl_anchor_pos
            call    zero4bytes
            mov     rf, sl_anchor_line
            call    zero4bytes
            mov     rf, sl_anchor_line
            inc     rf
            inc     rf
            inc     rf
            ldi     1
            str     rf

            mov     rf, src_pos
            call    zero4bytes

            mov     rf, src_pos
            call    src_seek_to         ; also invalidates the chunk buffer
            rtn

            extrn   src_seek_to
            endp

;------------------------------------------------------------------
; src_set_mode: tell the source the display mode. Part of the SOURCE
; CONTRACT (added for wrap / -S). In WRAP mode src_read_line returns one
; SCREEN ROW at a time (break at LF or at `room` display columns) and
; src_prev_start / src_last_page count rows, not lines; in NOWRAP (-S)
; mode it returns whole lines exactly as before. `room` is the per-row
; text width the pager will render -- COLUMNS-1, less the line-number
; column when -N is on -- so the source breaks rows to match. A no-op-
; safe default (wrap, width 79) is in place until this is called.
; Args:    D = 1 wrap / 0 nowrap;  RC.0 = per-row width (>= 1)
; Returns: nothing
; Modifies: R7, RF, D
;------------------------------------------------------------------
            proc    src_set_mode
            extrn   src_wrap
            extrn   src_room
            plo     r7                  ; stash the flag (gotcha #4)
            mov     rf, src_wrap
            glo     r7
            str     rf
            mov     rf, src_room
            glo     rc
            str     rf
            rtn
            endp

;------------------------------------------------------------------
; src_line_of: the 1-based line number of a position -- for LESS -N.
;
; Part of the SOURCE CONTRACT. A text file has no index, so the only way
; to number a line is to count the LFs before it. Counting from the start
; every time would make every jump cost the whole file, so this keeps an
; ANCHOR -- the last position whose number is known -- and counts only
; the bytes between the anchor and the target, forward or backward. When
; the target lies below the anchor but nearer the start of the file, it
; counts forward from position 0 (line 1) instead. The cost is therefore
; proportional to how far the view moved, not to the file's size; only a
; long jump (G on a big file) reads a lot, which is what real less does
; too. The pager tells the source about numbers it already knows through
; src_line_mark, so ordinary paging never re-reads anything.
;
; The number of a position is 1 + the LFs before it, so a position in
; the middle of a line gets that line's number.
;
; Args:    RF = pointer to a 4-byte position
; Returns: DF=0, RD:R8 = its line number (RD = high word). The anchor
;          moves to this position. The read position is left
;          UNSPECIFIED -- the caller must seek before reading again,
;          as after src_prev_start and src_search.
; Modifies: everything
;------------------------------------------------------------------
            proc    src_line_of
            extrn   less_fcb
            extrn   sl_buf
            extrn   src_seek_to
            extrn   copy4bytes
            extrn   zero4bytes
            extrn   add32
            extrn   sub32
            extrn   sl_anchor_pos
            extrn   sl_anchor_line
            extrn   sl_target
            extrn   sl_dist
            extrn   sl_tmp
            extrn   sl_start
            extrn   sl_base
            extrn   sl_count
            extrn   sl_dir

            mov     rd, sl_target
            call    copy4bytes          ; sl_target = *RF

            ; dist = target - anchor; no borrow means target >= anchor
            mov     rf, sl_target
            mov     rd, sl_dist
            call    copy4bytes
            mov     rf, sl_dist
            mov     rd, sl_anchor_pos
            call    sub32
            lbnf    slo_below

            ; target at or after the anchor: count forward from it
            mov     rf, sl_anchor_pos
            mov     rd, sl_start
            call    copy4bytes
            mov     rf, sl_anchor_line
            mov     rd, sl_base
            call    copy4bytes
            mov     rf, sl_dir
            ldi     0
            str     rf
            lbr     slo_count

slo_below:
            ; target before the anchor: dist = anchor - target
            mov     rf, sl_anchor_pos
            mov     rd, sl_dist
            call    copy4bytes
            mov     rf, sl_dist
            mov     rd, sl_target
            call    sub32

            ; nearer the start of the file than the anchor?
            mov     rf, sl_target
            mov     rd, sl_tmp
            call    copy4bytes
            mov     rf, sl_tmp
            mov     rd, sl_dist
            call    sub32               ; borrow: target < dist
            lbdf    slo_backward

            ; yes -- count forward from position 0, line 1
            mov     rf, sl_start
            call    zero4bytes
            mov     rf, sl_base
            call    zero4bytes
            mov     rf, sl_base
            inc     rf
            inc     rf
            inc     rf
            ldi     1
            str     rf
            mov     rf, sl_target
            mov     rd, sl_dist
            call    copy4bytes
            mov     rf, sl_dir
            ldi     0
            str     rf
            lbr     slo_count

slo_backward:
            ; count the LFs in [target, anchor) and subtract them
            mov     rf, sl_target
            mov     rd, sl_start
            call    copy4bytes
            mov     rf, sl_anchor_line
            mov     rd, sl_base
            call    copy4bytes
            mov     rf, sl_dir
            ldi     1
            str     rf

slo_count:
            mov     rf, sl_count
            call    zero4bytes

            call    slo_dist_zero
            lbdf    slo_finish          ; nothing between them: no seek

            mov     rf, sl_start
            call    src_seek_to

slo_read:
            call    slo_dist_zero
            lbdf    slo_finish

            ; n = min(dist, SL_BUF_LEN)
            mov     rf, sl_dist
            lda     rf
            lbnz    slo_full
            lda     rf
            lbnz    slo_full
            lda     rf                  ; D = byte 2
            smi     high SL_BUF_LEN
            lbdf    slo_full            ; 512 or more left
            dec     rf
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = what is left (< 512)
            lbr     slo_have_n
slo_full:
            ldi     high SL_BUF_LEN
            phi     rc
            ldi     low SL_BUF_LEN
            plo     rc
slo_have_n:
            mov     rd, less_fcb
            mov     rf, sl_buf
            call    K_FILE_READ         ; RC = bytes actually read
            lbdf    slo_finish          ; read error: stop counting
            ghi     rc
            lbnz    slo_got
            glo     rc
            lbz     slo_finish          ; nothing more
slo_got:
            ; count the LFs -- no calls in this loop, so it runs in
            ; registers: RF = byte, RB = bytes left, R9 = LFs found
            mov     rf, sl_buf
            ghi     rc
            phi     rb
            glo     rc
            plo     rb
            ldi     0
            phi     r9
            plo     r9
slo_scan:
            lda     rf
            xri     10
            lbnz    slo_scan_next
            inc     r9
slo_scan_next:
            dec     rb
            glo     rb
            lbnz    slo_scan
            ghi     rb
            lbnz    slo_scan

            ; count += R9, dist -= RC, both through a 4-byte scratch
            ; (add32/sub32 leave RC and R9 alone)
            mov     rf, sl_tmp
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, sl_count
            mov     rd, sl_tmp
            call    add32
            mov     rf, sl_tmp
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf
            mov     rf, sl_dist
            mov     rd, sl_tmp
            call    sub32
            lbr     slo_read

slo_finish:
            mov     rf, sl_base
            mov     rd, sl_count
            mov     r8, sl_dir          ; (mov clobbers D -- load after)
            ldn     r8
            lbnz    slo_minus
            call    add32               ; line = base + count
            lbr     slo_store
slo_minus:
            call    sub32               ; line = base - count

slo_store:
            mov     rf, sl_target
            mov     rd, sl_anchor_pos
            call    copy4bytes
            mov     rf, sl_base
            mov     rd, sl_anchor_line
            call    copy4bytes

            mov     rf, sl_base
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            clc
            rtn

;------------------------------------------------------------------
; slo_dist_zero: DF=1 iff the 4-byte sl_dist is zero.
;------------------------------------------------------------------
slo_dist_zero:
            mov     rf, sl_dist
            lda     rf
            lbnz    sdz_no
            lda     rf
            lbnz    sdz_no
            lda     rf
            lbnz    sdz_no
            ldn     rf
            lbnz    sdz_no
            stc
            rtn
sdz_no:
            clc
            rtn
            endp

;------------------------------------------------------------------
; src_line_mark: record that a position's line number is already known,
; so a later src_line_of counts from there. Part of the SOURCE CONTRACT.
; The pager knows the number of every row it reads sequentially; telling
; the source is what keeps paging forward from costing a re-read.
; Args:    RF = pointer to a 4-byte position,
;          RD = pointer to its 4-byte line number
; Returns: nothing. Does not move the read position.
; Modifies: R9, RD, RF, D
;------------------------------------------------------------------
            proc    src_line_mark
            extrn   copy4bytes
            extrn   sl_anchor_pos
            extrn   sl_anchor_line

            mov     r9, rd              ; copy4bytes leaves R9 alone
            mov     rd, sl_anchor_pos
            call    copy4bytes
            mov     rf, r9
            mov     rd, sl_anchor_line
            call    copy4bytes
            rtn
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
            extrn   src_pos
            extrn   src_fresh
            extrn   copy4bytes
;------------------------------------------------------------------
; src_seek_to: seeks the FCB to the 4-byte big-endian position at
; [RF], sets src_pos to match, and resets the chunk buffer so the next
; byte read is genuinely fresh, not stale pre-seek content.
;
; Setting src_pos here is new (2026-09-10). It used to be left to the
; caller, and every caller did it, one line after the seek -- so the
; asymmetry bought nothing and a second source would have had to copy
; it. [RF] may be src_pos itself; copying it onto itself is harmless.
; Args:    RF = pointer to a 4-byte position
; Returns: src_pos = that position. K_FILE_SEEK's DF is ignored (see
;          this file's own header comment on the accepted error-
;          handling simplification)
;------------------------------------------------------------------
            mov     rd, src_pos
            call    copy4bytes          ; src_pos = [RF]
            mov     rf, src_pos
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
            mov     rf, src_fresh       ; the next wrap read reseeds
            ldi     1                   ; src_at_line_start from byte[pos-1]
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
            extrn   subbyte32
            extrn   sub32
            extrn   src_wrap
            extrn   src_seek_to
            extrn   read_one_row
            extrn   row_endline
            extrn   less_consumed
            extrn   spr_p
            extrn   spr_l
            extrn   spr_prev
            extrn   spr_cur
            extrn   spr_tmp
;------------------------------------------------------------------
; src_prev_start: the start of the ROW immediately BEFORE the one at
; [RF] -- or of the row CONTAINING it, when [RF] is mid-row. In NOWRAP
; mode a "row" is a source line, so this is the last LF before the
; position (find_line_start below). In WRAP mode a row can also end at a
; width break, so it additionally walks the line containing the position
; forward, one src_room-wide row at a time (read_one_row -- the SAME row
; logic src_read_line uses forward), to land on the exact row boundary.
; Verified (2026-09-12) against brute-force enumeration of every row
; boundary across 243k (position, file, room) cases before being coded.
;
; find_line_start (the backward LF scan) uses its OWN scratch buffer
; (less_backscan_buf) and raw seeks, not the forward chunk state. The
; wrap forward walk DOES use the chunk state and src_seek_to -- safe,
; since every caller (cmd_line_up / src_last_page / cmd_back) re-seeks
; right after this returns.
;
; Precondition: the position passed in is > 0 (checked by the caller).
; Args:    RF = pointer to a 4-byte position (taken by value)
; Returns: src_prev_result = the previous row's start offset
; Modifies: everything
;------------------------------------------------------------------
            mov     rd, spr_p
            call    copy4bytes          ; spr_p = *RF (the position P)

            mov     rf, src_wrap
            ldn     rf
            lbnz    spr_wrap_entry

            ; --- NOWRAP: result = find_line_start(P - 1) (old behaviour:
            ; the last LF strictly before P). ---
            mov     rf, spr_p
            mov     rd, src_prev_in
            call    copy4bytes
            mov     rf, src_prev_in
            ldi     1
            call    subbyte32           ; hi = P - 1
            lbr     spr_window          ; scan; its rtn returns to our caller

;------------------------------------------------------------------
; find_line_start (entry point spr_window): the position just after the
; last LF at an index < the exclusive top `hi` in src_prev_in, or 0 if
; there is none. Scans backward a LESS_BACKSCAN_LEN-byte window at a time
; (works on a line of any length; the bound strictly decreases so it
; always terminates). Result -> src_prev_result. Callable (ends in rtn).
;------------------------------------------------------------------
spr_window:
            ; hi == 0? then there is no earlier LF -- the answer is 0
            mov     rf, src_prev_in
            ldn     rf
            lbnz    spr_have_hi
            inc     rf
            ldn     rf
            lbnz    spr_have_hi
            inc     rf
            ldn     rf
            lbnz    spr_have_hi
            inc     rf
            ldn     rf
            lbnz    spr_have_hi
            mov     rf, src_prev_result
            call    zero4bytes
            rtn

spr_have_hi:
            ; win_start = max(0, hi - LESS_BACKSCAN_LEN); count = hi -
            ; win_start (1..LESS_BACKSCAN_LEN, a full 16-bit value now).
            mov     rf, src_prev_in
            mov     rd, less_backscan_start
            call    copy4bytes          ; win_start = hi (for now)

            ; win_start -= LESS_BACKSCAN_LEN (a 16-bit constant, so the
            ; subtract touches the low two bytes and borrows up)
            mov     r7, less_backscan_start
            inc     r7
            inc     r7
            inc     r7                  ; -> LSB (byte 3)
            ldi     low LESS_BACKSCAN_LEN
            str     r2
            ldn     r7
            sm
            str     r7
            dec     r7                  ; byte 2
            ldi     high LESS_BACKSCAN_LEN
            str     r2
            ldn     r7
            smb
            str     r7
            dec     r7                  ; byte 1
            ldi     0
            str     r2
            ldn     r7
            smb
            str     r7
            dec     r7                  ; byte 0
            ldi     0
            str     r2
            ldn     r7
            smb
            str     r7
            lbdf    spr_count_full      ; no borrow: hi >= window size

            ; hi < LESS_BACKSCAN_LEN: clamp win_start to 0, count = hi
            ; (its low 16 bits -- hi < 32768, so bytes 0/1 are zero)
            mov     rf, less_backscan_start
            call    zero4bytes
            mov     rf, src_prev_in
            inc     rf
            inc     rf                  ; -> hi byte 2 (high 8 of count)
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = count
            lbr     spr_have_count

spr_count_full:
            ldi     high LESS_BACKSCAN_LEN
            phi     r9
            ldi     low LESS_BACKSCAN_LEN
            plo     r9                  ; count = a full window

spr_have_count:
            ; less_backscan_count = R9 (16-bit, big-endian)
            mov     rf, less_backscan_count
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; seek win_start
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
            lda     rb
            phi     rc
            ldn     rb
            plo     rc                  ; RC = count (16-bit)
            call    K_FILE_READ         ; RC = bytes actually read

            glo     rc
            lbnz    spr_scan_setup
            ghi     rc
            lbz     spr_next_window     ; nothing read: drop to win_start

spr_scan_setup:
            ; idx = bytes_read - 1 (16-bit)
            mov     r7, less_backscan_idx
            inc     r7                  ; -> low byte
            glo     rc
            smi     1
            str     r7                  ; idx.lo = RC.lo - 1 (DF = borrow)
            dec     r7                  ; -> high byte
            ghi     rc
            smbi    0
            str     r7                  ; idx.hi = RC.hi - borrow

spr_scan:
            mov     rf, less_backscan_idx
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = idx
            mov     r8, less_backscan_buf
            add16   r8, r9              ; R8 = &buf[idx]
            ldn     r8
            xri     10                  ; LF?
            lbz     spr_found

            ; idx == 0? then no LF in this window
            mov     rf, less_backscan_idx
            ldn     rf
            lbnz    spr_dec_idx
            inc     rf
            ldn     rf
            lbz     spr_next_window
spr_dec_idx:
            mov     r7, less_backscan_idx
            inc     r7                  ; low
            ldn     r7
            smi     1
            str     r7
            dec     r7                  ; high
            ldn     r7
            smbi    0
            str     r7
            lbr     spr_scan

spr_next_window:
            ; no LF here -- keep looking below. hi = win_start (strictly
            ; less than the old hi, so this makes real progress toward 0).
            mov     rf, less_backscan_start
            mov     rd, src_prev_in
            call    copy4bytes
            lbr     spr_window

spr_found:
            ; result = win_start + (idx + 1)
            mov     rf, less_backscan_start
            mov     rd, src_prev_result
            call    copy4bytes
            mov     rf, less_backscan_idx
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = idx
            inc     r9                  ; R9 = idx + 1 (1..LESS_BACKSCAN_LEN)

            ; result += R9 (16-bit), carry propagated into the upper bytes
            mov     r7, src_prev_result
            inc     r7
            inc     r7
            inc     r7                  ; -> LSB
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

;------------------------------------------------------------------
; spr_wrap_entry: WRAP-mode src_prev_start. See the header above.
;------------------------------------------------------------------
spr_wrap_entry:
            ; L = find_line_start(P) -- the line CONTAINING P (hi = P, so
            ; a P that is itself a line start gives L == P).
            mov     rf, spr_p
            mov     rd, src_prev_in
            call    copy4bytes
            call    spr_window          ; -> src_prev_result = L
            mov     rf, src_prev_result
            mov     rd, spr_l
            call    copy4bytes

            mov     rf, spr_l           ; L == P ?
            mov     rd, spr_p
            call    spr_eq4
            lbdf    spr_wrap_prevline

            ; --- L < P: P is mid-line. Walk L forward one row at a time;
            ; the answer is the last row boundary <= P (the row before P if
            ; P is itself a boundary, else the row containing P). ---
            mov     rf, spr_l
            mov     rd, spr_prev
            call    copy4bytes          ; prev = L
            mov     rf, spr_l
            mov     rd, spr_cur
            call    copy4bytes          ; cur = L
            mov     rf, spr_cur
            call    src_seek_to         ; position for read_one_row
spr_mid_loop:
            mov     rf, spr_cur         ; cur >= P ?  -> stop
            mov     rd, spr_tmp
            call    copy4bytes
            mov     rf, spr_tmp
            mov     rd, spr_p
            call    sub32               ; spr_tmp = cur - P; DF=1 iff cur>=P
            lbdf    spr_mid_stop
            mov     rf, spr_cur         ; prev = cur
            mov     rd, spr_prev
            call    copy4bytes
            call    read_one_row
            lbdf    spr_mid_stop        ; EOF (should not happen mid-line)
            call    spr_add_consumed    ; cur += less_consumed
            lbr     spr_mid_loop
spr_mid_stop:
            mov     rf, spr_prev
            mov     rd, src_prev_result
            call    copy4bytes
            rtn

spr_wrap_prevline:
            ; P is itself a line start: the previous row is the LAST row of
            ; the PREVIOUS line. L2 = find_line_start(P - 1).
            mov     rf, spr_p
            mov     rd, src_prev_in
            call    copy4bytes
            mov     rf, src_prev_in
            ldi     1
            call    subbyte32           ; hi = P - 1
            call    spr_window          ; -> src_prev_result = L2
            mov     rf, src_prev_result ; cur = L2
            mov     rd, spr_cur
            call    copy4bytes
            mov     rf, spr_cur
            call    src_seek_to
spr_last_loop:
            mov     rf, spr_cur         ; prev = cur (candidate last row)
            mov     rd, spr_prev
            call    copy4bytes
            call    read_one_row
            lbdf    spr_last_stop       ; EOF: prev is the answer
            mov     rf, row_endline
            ldn     rf
            lbnz    spr_last_stop       ; ended at a line end: prev is it
            call    spr_add_consumed    ; width break: cur += row; continue
            lbr     spr_last_loop
spr_last_stop:
            mov     rf, spr_prev
            mov     rd, src_prev_result
            call    copy4bytes
            rtn

;------------------------------------------------------------------
; spr_eq4: DF=1 iff the 4-byte values at [RF] and [RD] are equal.
;------------------------------------------------------------------
spr_eq4:
            ldi     4
            plo     r7
spr_eq_loop:
            lda     rd
            str     r2
            lda     rf
            sm
            lbnz    spr_eq_ne
            dec     r7
            glo     r7
            lbnz    spr_eq_loop
            stc
            rtn
spr_eq_ne:
            clc
            rtn

;------------------------------------------------------------------
; spr_add_consumed: spr_cur (4-byte big-endian) += less_consumed (16-bit,
; low byte at +0, high at +1 -- the order the row readers write it), LSB
; first with carry up. Modifies: R7, RF, D, DF.
;------------------------------------------------------------------
spr_add_consumed:
            mov     r7, spr_cur
            inc     r7
            inc     r7
            inc     r7                  ; -> LSB
            mov     rf, less_consumed
            ldn     rf                  ; low byte
            str     r2
            ldn     r7
            add
            str     r7
            dec     r7
            mov     rf, less_consumed
            inc     rf
            ldn     rf                  ; high byte
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

            proc    src_read_line
            extrn   less_fcb
            extrn   src_pos
            extrn   src_line_buf
            extrn   less_chunk_buf
            extrn   less_chunk_ptr
            extrn   less_chunk_remaining
            extrn   less_linelen
            extrn   less_consumed
            extrn   src_wrap
            extrn   src_room
            extrn   src_fresh
            extrn   src_row_wrapped
            extrn   row_endline
            extrn   src_at_line_start
            extrn   seed_tmp
            extrn   seed_byte
            extrn   srl_col
            extrn   srl_skipcol
            extrn   less_hshift
            extrn   peek_byte
            extrn   consume_byte
            extrn   copy4bytes
            extrn   subbyte32
;------------------------------------------------------------------
; src_read_line: reads one line (nowrap) or one screen ROW (wrap)
; starting at the current position into src_line_buf (NUL-terminated,
; capped at SRC_LINE_MAX-1 chars -- excess bytes are still consumed so
; offset tracking stays correct, just not kept). In NOWRAP mode it
; consumes through the terminating LF; in WRAP mode it stops at the LF
; OR after src_room display columns (a TAB advances to the next multiple
; of 8, and never straddles the width -- the same rule put_line renders
; with, so a chunk always fits). Publishes src_at_line_start (this row
; began a source line -- for -N) and src_row_wrapped (this row ended at a
; width break, so the next row continues the same line). A final line
; with no trailing LF is still returned once (DF=0) before the following
; call reports true EOF (DF=1). Advances src_pos by the number of bytes
; actually consumed.
; Returns: DF=0 -- src_line_buf holds a real (possibly empty) line/row
;          DF=1 -- nothing left to read at all
;------------------------------------------------------------------
            ; --- init: less_consumed = 0, less_linelen = 0 ---
            mov     rf, less_consumed
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; less_consumed = 0
            mov     rf, less_linelen    ; (clobbers D -- gotcha #4)
            ldi     0
            str     rf                  ; less_linelen = 0

            ; --- src_at_line_start (for -N): a nowrap read always begins a
            ; source line; a wrap read reseeds it from byte[pos-1] on the
            ; first read after a seek, else takes the complement of the last
            ; row's wrap state. ---
            mov     rf, src_wrap
            ldn     rf
            lbz     srl_ls_plain
            mov     rf, src_fresh
            ldn     rf
            lbz     srl_ls_seq
            ldi     0
            str     rf                  ; src_fresh = 0
            call    seed_line_start
            lbr     srl_dispatch
srl_ls_seq:
            mov     rf, src_row_wrapped
            ldn     rf
            lbnz    srl_ls_cont         ; last row wrapped -> continuation
            mov     rf, src_at_line_start
            ldi     1
            str     rf
            lbr     srl_dispatch
srl_ls_cont:
            mov     rf, src_at_line_start
            ldi     0
            str     rf
            lbr     srl_dispatch
srl_ls_plain:
            mov     rf, src_at_line_start
            ldi     1
            str     rf

srl_dispatch:
            mov     rf, src_wrap
            ldn     rf
            lbz     srl_nowrap
            ; --- wrap: read exactly one screen row ---
            call    read_one_row
            lbdf    srl_wrap_eof        ; nothing consumed: true EOF
            mov     rf, row_endline
            ldn     rf
            lbz     srl_wrap_wrapped    ; width break -> continuation follows
            mov     rf, src_row_wrapped
            ldi     0
            str     rf                  ; ended at a line end
            lbr     rlh_done
srl_wrap_wrapped:
            mov     rf, src_row_wrapped
            ldi     1
            str     rf
            lbr     rlh_done
srl_wrap_eof:
            stc
            rtn

srl_nowrap:
            mov     rf, src_row_wrapped ; a whole-line read always ends at a
            ldi     0                   ; line end (never a width break)
            str     rf

            ; --- -S horizontal scroll: consume less_hshift display columns
            ; before storing, so src_line_buf holds the VISIBLE window and
            ; the Right arrow can scroll arbitrarily far into a long line --
            ; the buffer never has to hold the scrolled-past prefix. hshift
            ; is 0 until the Right arrow scrolls (and always 0 in wrap mode,
            ; which never reaches here), so an unshifted read skips nothing
            ; and is byte-identical to before. Skipped bytes still count
            ; toward less_consumed, so src_pos advances by the WHOLE line;
            ; the rest of the line past the window is consumed through its LF
            ; by the reader below. This uses the exact column/tab rule
            ; put_line's old pl_skip used: a TAB straddling the boundary is
            ; dropped whole, and tab stops in the window are then counted
            ; from the visible edge. ---
            mov     rf, srl_skipcol     ; 16-bit skip column = 0 (MSB-first)
            ldi     0
            str     rf
            inc     rf
            str     rf
nsk_test:
            mov     r8, less_hshift     ; col >= hshift ?  (16-bit)
            ldn     r8
            str     r2
            mov     r8, srl_skipcol
            ldn     r8
            sm                          ; col.hi - hshift.hi
            lbnf    nsk_step            ; col.hi < hshift.hi -> keep skipping
            lbnz    rlh_loop            ; col.hi > hshift.hi -> window reached
            mov     r8, less_hshift
            inc     r8
            ldn     r8
            str     r2
            mov     r8, srl_skipcol
            inc     r8
            ldn     r8
            sm                          ; col.lo - hshift.lo
            lbdf    rlh_loop            ; col.lo >= hshift.lo -> window reached
nsk_step:
            call    peek_byte
            lbdf    nsk_eof             ; nothing left at this position at all
            plo     r7                  ; b (survives consume_byte)
            xri     10                  ; LF?
            lbz     nsk_lf

            call    consume_byte        ; skip it: consume + count, no store
            mov     rf, less_consumed
            ldn     rf
            adi     1
            str     rf
            lbnf    nsk_adv
            inc     rf
            ldn     rf
            adi     1
            str     rf
nsk_adv:
            glo     r7
            xri     9                   ; TAB?
            lbz     nsk_tab
            mov     r8, srl_skipcol     ; ordinary char: col += 1 (16-bit)
            inc     r8
            ldn     r8
            adi     1
            str     r8
            lbnf    nsk_test
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbr     nsk_test
nsk_tab:
            mov     r8, srl_skipcol     ; col = (col | 7) + 1 (16-bit)
            inc     r8
            ldn     r8
            ori     7
            adi     1
            str     r8
            lbnf    nsk_test
            dec     r8
            ldn     r8
            adi     1
            str     r8
            lbr     nsk_test

nsk_lf:
            ; the line ended within the scrolled-past part: consume + count
            ; the LF and finish with an empty (fully-scrolled-off) row.
            call    consume_byte
            mov     rf, less_consumed
            ldn     rf
            adi     1
            str     rf
            lbnf    nsk_lf_done
            inc     rf
            ldn     rf
            adi     1
            str     rf
nsk_lf_done:
            lbr     rlh_done

nsk_eof:
            ; nothing left here: rlh_eof_check reports true EOF (DF=1) if the
            ; skip consumed nothing, or a final empty scrolled-off row (DF=0)
            ; if it already ate some bytes.
            lbr     rlh_eof_check

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
            lbdf    rlh_skip            ; already full -- skip the rest
                                        ; of the line fast (see below)

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

;------------------------------------------------------------------
; rlh_skip: the line buffer is full; consume the rest of the line
; (through its terminating LF, or to EOF) as fast as possible, without
; a get_next_byte call per byte. Scans less_chunk_buf directly, refills
; it from disk when it runs out, and counts every byte skipped into R9,
; adding the total to less_consumed once at the end. On a file whose
; lines fit in SRC_LINE_MAX this path is never reached, so ordinary
; text reads through the unchanged loop above.
;
; The skip count is 16-bit; a single line longer than 65535 bytes would
; overflow less_consumed, the same 16-bit-per-line limit src_pos_add16
; has always had -- pathological, and no worse than before.
;------------------------------------------------------------------
rlh_skip:
            ldi     0
            phi     r9
            plo     r9                  ; R9 = bytes skipped in this line

rsk_refill:
            mov     rf, less_chunk_remaining
            ldn     rf
            lbnz    rsk_load            ; chunk still has bytes

            mov     rd, less_fcb
            mov     rf, less_chunk_buf
            ldi     LESS_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
            push    r9                  ; R9 (our count) across K_FILE_READ
            call    K_FILE_READ         ; RC = bytes read
            pop     r9
            glo     rc
            lbnz    rsk_seed
            ghi     rc
            lbnz    rsk_seed
            lbr     rsk_finish          ; EOF: line ends here, no LF

rsk_seed:
            mov     rf, less_chunk_remaining
            glo     rc
            str     rf                  ; remaining = bytes read
            mov     r8, less_chunk_buf
            mov     rf, less_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ptr = start of the fresh chunk

rsk_load:
            mov     rf, less_chunk_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = the current read pointer
            mov     rf, less_chunk_remaining
            ldn     rf
            plo     rc                  ; RC.0 = bytes left in this chunk

rsk_byte:
            ldn     r8
            xri     10                  ; LF?
            lbz     rsk_lf
            inc     r8
            inc     r9
            glo     rc
            smi     1
            plo     rc
            lbnz    rsk_byte

            ; chunk exhausted with no LF: mark it empty and refill
            mov     rf, less_chunk_remaining
            ldi     0
            str     rf
            lbr     rsk_refill

rsk_lf:
            ; consume the LF too, then write the chunk state back
            inc     r8
            inc     r9                  ; count the LF
            glo     rc
            smi     1
            plo     rc                  ; remaining after the LF
            mov     rf, less_chunk_remaining
            glo     rc
            str     rf
            mov     rf, less_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

rsk_finish:
            ; less_consumed += R9 (16-bit, low byte first -- same order
            ; the per-byte loop above uses, see rlh_done's own comment)
            mov     r7, less_consumed
            glo     r9
            str     r2
            ldn     r7
            add
            str     r7
            inc     r7
            ghi     r9
            str     r2
            ldn     r7
            adc
            str     r7
            lbr     rlh_done

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
; read_one_row: consume one screen row from the current chunk read
; position, storing its bytes into src_line_buf (up to SRC_LINE_MAX-1)
; and setting less_consumed = the byte count. Same column/tab/width rule
; as documented at src_read_line, ROW-relative: an ordinary char fits iff
; col < room; a TAB advances to the next multiple of 8 and fits iff that
; stop is <= room (and <= 255); a byte that fits nowhere on an empty row
; (an unfittable tab, or room 0) is consumed alone, so wrapping always
; progresses. Does NOT advance src_pos, NUL-terminate, or touch
; src_at_line_start -- the caller does. Public so src_prev_start's forward
; row walk shares the exact same logic (it re-reads afterward, so it does
; not mind less_consumed / src_line_buf being overwritten).
; Returns: DF=1 -- nothing left at all (EOF at the row start);
;          DF=0 -- row_endline = 1 if it ended at LF/EOF, 0 at a width
;                  break; less_consumed = the row's byte count.
;------------------------------------------------------------------
            public  read_one_row
read_one_row:
            mov     rf, less_consumed
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; less_consumed = 0
            mov     rf, less_linelen
            ldi     0
            str     rf                  ; less_linelen = 0
            mov     rf, srl_col
            ldi     0
            str     rf                  ; col = 0 for this row
ror_next:
            call    peek_byte
            lbdf    ror_eof
            plo     r7                  ; b = the peeked byte
            glo     r7
            xri     10
            lbz     ror_lf
            glo     r7
            xri     9
            lbz     ror_tab

            ; --- ordinary char: fits iff col < room ---
            mov     rf, src_room
            ldn     rf
            str     r2
            mov     rf, srl_col
            ldn     rf
            sm                          ; col - room
            lbnf    ror_ord_fits        ; borrow: col < room -> fits
            mov     rf, srl_col
            ldn     rf
            lbz     ror_break_consume   ; col == 0 (room 0): take it anyway
            lbr     ror_break
ror_ord_fits:
            mov     rf, srl_col
            ldn     rf
            adi     1
            str     rf                  ; col++
            call    srw_emit
            lbr     ror_next

ror_tab:
            mov     rf, srl_col
            ldn     rf
            ori     7
            adi     1                   ; stop = (col | 7) + 1
            lbdf    ror_tab_toobig      ; carried past 255
            plo     r9                  ; R9.0 = stop (<= 255)
            mov     rf, src_room
            ldn     rf
            str     r2
            glo     r9
            sm                          ; stop - room
            lbnf    ror_tab_fits        ; stop < room -> fits
            lbz     ror_tab_fits        ; stop == room -> fits
ror_tab_toobig:
            mov     rf, srl_col
            ldn     rf
            lbz     ror_break_consume   ; col == 0: take the tab alone
            lbr     ror_break
ror_tab_fits:
            mov     rf, srl_col
            glo     r9
            str     rf                  ; col = stop
            call    srw_emit
            lbr     ror_next

ror_break_consume:
            call    srw_emit            ; consume+store the one byte
ror_break:
            mov     rf, row_endline
            ldi     0
            str     rf                  ; ended at a width break
            clc
            rtn

ror_lf:
            call    consume_byte        ; the LF belongs to this line
            mov     rf, less_consumed
            ldn     rf
            adi     1
            str     rf
            lbnf    ror_lf_done
            inc     rf
            ldn     rf
            adi     1
            str     rf
ror_lf_done:
            mov     rf, row_endline
            ldi     1
            str     rf                  ; ended at a line end
            clc
            rtn

ror_eof:
            ; peek found nothing. Anything consumed this row -> a final
            ; partial row (line end); else true EOF (DF=1).
            mov     rf, less_consumed
            ldn     rf
            lbnz    ror_eof_row
            inc     rf
            ldn     rf
            lbnz    ror_eof_row
            stc                         ; nothing at all left
            rtn
ror_eof_row:
            mov     rf, row_endline
            ldi     1
            str     rf
            clc
            rtn

;------------------------------------------------------------------
; srw_emit: consume the peeked byte, count it (less_consumed++, low byte
; first -- matching rlh_done's readback), and store it (from R7) into
; src_line_buf if room remains. R7 survives (consume_byte and the store
; touch only R8/RF). Local to src_read_line.
;------------------------------------------------------------------
srw_emit:
            call    consume_byte
            mov     rf, less_consumed
            ldn     rf
            adi     1
            str     rf
            lbnf    sem_stored
            inc     rf
            ldn     rf
            adi     1
            str     rf
sem_stored:
            mov     rf, less_linelen
            ldn     rf
            smi     SRC_LINE_MAX-1
            lbdf    sem_full            ; buffer full: consume but don't keep
            mov     rf, less_linelen
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, src_line_buf
            add16   rf, r8
            glo     r7
            str     rf
            mov     rf, less_linelen
            ldn     rf
            adi     1
            str     rf
sem_full:
            rtn

;------------------------------------------------------------------
; seed_line_start: (wrap, first read after a seek) set src_at_line_start
; = 1 iff the read position begins a source line -- pos == 0, or the byte
; just before it is an LF. Reads that one prior byte via a raw seek+read;
; the FCB is left positioned at src_pos (reading byte[pos-1] leaves the
; pointer at pos) and the chunk buffer is already empty, so the row read
; that follows starts cleanly at src_pos. One extra tiny read, only on a
; jump/up-arrow in wrap mode. Local to src_read_line.
;------------------------------------------------------------------
seed_line_start:
            mov     rf, src_pos
            ldn     rf
            lbnz    slst_prev
            inc     rf
            ldn     rf
            lbnz    slst_prev
            inc     rf
            ldn     rf
            lbnz    slst_prev
            inc     rf
            ldn     rf
            lbnz    slst_prev
            mov     rf, src_at_line_start   ; pos == 0: a line start
            ldi     1
            str     rf
            rtn
slst_prev:
            mov     rf, src_pos             ; seed_tmp = src_pos - 1
            mov     rd, seed_tmp
            call    copy4bytes
            mov     rf, seed_tmp
            ldi     1
            call    subbyte32
            mov     rf, seed_tmp            ; seek there, read one byte
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
            plo     rc                      ; whence = SEEK_SET
            call    K_FILE_SEEK
            mov     rd, less_fcb
            mov     rf, seed_byte
            ldi     1
            plo     rc
            ldi     0
            phi     rc
            call    K_FILE_READ             ; FCB now sits at src_pos
            mov     rf, seed_byte
            ldn     rf
            xri     10
            lbz     slst_yes
            mov     rf, src_at_line_start
            ldi     0
            str     rf
            rtn
slst_yes:
            mov     rf, src_at_line_start
            ldi     1
            str     rf
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

            ; get_next_byte = peek + consume. Both callers of this proc
            ; that only ever move forward (src_search, and nowrap
            ; src_read_line) use it as before; the wrap path peeks and
            ; consumes separately so it can leave an over-wide byte for
            ; the next row.
            call    peek_byte
            lbdf    gnb_eof
            plo     r7                  ; stash the byte (nothing between
            call    consume_byte        ; here and its use clobbers R7)
            glo     r7
            clc
            rtn
gnb_eof:
            stc
            rtn

;------------------------------------------------------------------
; peek_byte: ensure the chunk buffer holds a byte and return the byte at
; the current read pointer WITHOUT advancing (refilling from disk when
; empty). Returns D = byte, DF=0 -- or DF=1 if the file is exhausted.
; Public so src_read_line's wrap path can look before it decides to
; consume (a width break must not eat the over-wide byte).
; Modifies: R8, RC, RD, RF (and D).
;------------------------------------------------------------------
            public  peek_byte
peek_byte:
            mov     rf, less_chunk_remaining
            ldn     rf
            lbnz    pk_have

            mov     rd, less_fcb
            mov     rf, less_chunk_buf
            ldi     LESS_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc
            call    K_FILE_READ         ; RC = bytes actually read
            glo     rc
            lbnz    pk_got
            ghi     rc
            lbnz    pk_got
            stc                         ; 0 bytes: exhausted
            rtn
pk_got:
            mov     rf, less_chunk_remaining
            glo     rc
            str     rf                  ; RC <= LESS_CHUNK_LEN <= 255
            mov     r8, less_chunk_buf
            mov     rf, less_chunk_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ptr = start of the fresh chunk
pk_have:
            mov     rf, less_chunk_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            ldn     r8                  ; D = the byte at the pointer
            clc
            rtn

;------------------------------------------------------------------
; consume_byte: advance the read pointer past one byte. Assumes the
; caller already peeked (remaining > 0). Modifies: R8, RF (and D).
;------------------------------------------------------------------
            public  consume_byte
consume_byte:
            mov     rf, less_chunk_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
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
            rtn
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
            extrn   sl_anchor_pos
            extrn   sl_anchor_line
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
            ; the line reached is known exactly: src_line_of can count
            ; from here, so -N does not re-read the file to number it
            mov     rf, src_goto_result
            mov     rd, sl_anchor_pos
            call    copy4bytes
            mov     rf, src_goto_line
            mov     rd, sl_anchor_line
            call    copy4bytes
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

; --- wrap / -S mode state ---
src_wrap:               db      1       ; 1 = wrap (default), 0 = -S nowrap
src_room:               db      79      ; wrap: per-row text width in columns
src_at_line_start:      db      1       ; published: this row began a src line
src_row_wrapped:        db      0       ; the last row ended at a width break
row_endline:            db      1       ; read_one_row: 1 ended at LF/EOF, 0 wid
src_fresh:              db      0       ; a seek happened; next read reseeds
                                        ; src_at_line_start from byte[pos-1]
seed_tmp:               ds      4       ; scratch for the pos-1 seed read
seed_byte:              db      0
srl_col:                db      0       ; wrap row reader's display column
srl_skipcol:            dw      0       ; -S read's 16-bit hscroll skip column

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
spr_p:                  ds      4       ; the position P (wrap prev walk)
spr_l:                  ds      4       ; the line start containing P
spr_prev:               ds      4       ; previous row boundary in the walk
spr_cur:                ds      4       ; current row boundary in the walk
spr_tmp:                ds      4       ; compare scratch
less_backscan_buf:      ds      LESS_BACKSCAN_LEN
less_backscan_start:    ds      4
less_backscan_count:    dw      0       ; 16-bit now (window > 255)
less_backscan_idx:      dw      0

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

; --- src_line_of's anchor and scratch ---
sl_anchor_pos:          ds      4       ; a position whose number is known
sl_anchor_line:         ds      4       ; ... and that number
sl_target:              ds      4
sl_dist:                ds      4
sl_tmp:                 ds      4
sl_start:               ds      4
sl_base:                ds      4
sl_count:               ds      4
sl_dir:                 db      0       ; 0 = count forward, 1 = backward
sl_buf:                 ds      SL_BUF_LEN

                public  less_fcb
                public  less_iobuf
                public  src_pos
                public  src_line_buf
                public  src_wrap
                public  src_room
                public  src_at_line_start
                public  src_row_wrapped
                public  row_endline
                public  src_fresh
                public  seed_tmp
                public  seed_byte
                public  srl_col
                public  srl_skipcol
                public  less_chunk_buf
                public  less_chunk_ptr
                public  less_chunk_remaining
                public  less_linelen
                public  less_consumed
                public  src_prev_in
                public  src_prev_result
                public  spr_p
                public  spr_l
                public  spr_prev
                public  spr_cur
                public  spr_tmp
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
                public  sl_anchor_pos
                public  sl_anchor_line
                public  sl_target
                public  sl_dist
                public  sl_tmp
                public  sl_start
                public  sl_base
                public  sl_count
                public  sl_dir
                public  sl_buf
            endp
