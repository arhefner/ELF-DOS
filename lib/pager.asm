;
; pager.asm - a reusable full-screen pager: a sliding window over a data
; source, bidirectional scrolling, paging, and forward search.
;
; Extracted from progs/less.asm (2026-09-08) so the same paging engine
; can front different kinds of data. The pager owns the terminal, the
; visible window and the history stack; it knows nothing whatever about
; where the text comes from.
;
;   THE SOURCE CONTRACT -- what a data source must provide
;   ------------------------------------------------------
;     src_open      (RF = whatever identifies the data -- a path for a file)
;           DF=0 ready, positioned at 0;  DF=1 failed.
;     src_close     ()
;           release whatever the source holds.
;     src_rewind    ()
;           back to the very beginning: src_pos = 0, buffers invalid.
;     src_seek_to   (RF = ptr to a 4-byte position; may be src_pos itself)
;           reposition there AND set src_pos to match. (Until 2026-09-10
;           the caller had to set src_pos itself; every caller did, so
;           the source now does it and the pager's copies are gone.)
;     src_read_line ()
;           DF=0: src_line_buf holds the line starting at src_pos,
;                 NUL-terminated and capped at the source's own maximum,
;                 and src_pos has advanced past it.
;           DF=1: nothing left.
;     src_prev_start(RF = ptr to a 4-byte position, > 0)
;           src_prev_result = the start of the line BEFORE it -- or of
;           the line containing it, when the position is mid-line.
;     src_last_page (D = n)
;           src_goto_result = where the last n lines begin.
;     src_goto      (RF = ptr to a 4-byte count typed by the user)
;           DF=0: src_goto_result = where that count lands (a line
;           number for text, a byte offset for a fixed-width source).
;           DF=1: past the end; the pager shows the last page instead.
;     src_search    (RF = pattern bytes, RC.0 = length, RD = ptr to start)
;           DF=0: src_search_top = a displayable position containing the
;           match, src_search_resume = where a following search resumes.
;           DF=1: not found. Either way the source's read position is
;           left unspecified -- the pager always seeks afterward.
;     src_line_of   (RF = ptr to a 4-byte position)
;           DF=0: RD:R8 = that position's 1-based line number (RD high).
;           DF=1: this source has no line numbers; -N is turned off.
;           The read position is left unspecified, as after src_search.
;     src_line_mark (RF = ptr to a 4-byte position, RD = ptr to its
;           4-byte line number)
;           a number the pager already knows, so a later src_line_of can
;           count from there. Must not move the read position.
;
;   Shared variables, all owned and published by the source: src_pos,
;   src_line_buf, src_prev_result, src_goto_result, src_search_top and
;   src_search_resume. A program links exactly ONE source, so every
;   source uses these same names.
;
;   A POSITION IS AN OPAQUE 4-BYTE TOKEN. The pager stores positions in
;   less_visible[] and less_stack and hands them back to the source, but
;   never interprets one. That is the whole point: a byte offset into a
;   text file (lib/src_file.asm), a row-aligned byte offset for a hex
;   view (lib/src_hex.asm), LBA*512 + row*16 for a sector dumper --
;   nothing here changes.
;
;   Entry point: pager_run (RF = the program's name, NUL-terminated, shown
;   on the status line; D = options, PAGER_OPT_NUMBERS = number the lines,
;   like less -N). Runs until the user quits, then returns; the caller
;   opens the source beforehand and closes it afterward.
;
; Terminal behaviour (page redraw vs. IND/RI single-line scrolling, why
; there is no DECSTBM scroll region, and why every scrolled row is
; cleared BEFORE its new text is printed) is documented at the routines
; that implement it, further down.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

LESS_SEARCH_MAX: equ    32          ; longest search pattern (incl NUL)
LESS_PAGE_LINES: equ    23          ; default screen height - 1
LESS_WIDTH_DEFAULT: equ 79          ; widest line: 80 columns - 1
LESS_MAX_VISIBLE: equ   80          ; cap on less_page_lines -- bounds the
                                    ; less_visible[] sliding window's size;
                                    ; a ROWS value producing a larger page
                                    ; is clamped down to this. 80 gives
                                    ; real headroom over a 50-row terminal
                                    ; (found in hardware testing) and keeps
                                    ; page_lines+1 -- the status row number
                                    ; the line-move scroll helpers below
                                    ; print via ESC[<row>H -- comfortably
                                    ; under 100, so the row-number
                                    ; formatter never needs a 3rd digit
COUNT_MAX_DIGITS: equ   9           ; a 9-digit count still fits
                                    ; comfortably inside 32 bits
PAGER_OPT_NUMBERS: equ  1           ; pager_run's D: number the lines
PAGER_OPT_NOWRAP:  equ  2           ; pager_run's D: -S, truncate + hscroll
LINENUM_WIDTH:   equ    7           ; less -N: numbers right-justified in
                                    ; 7 columns, then a space
LINENUM_COL:     equ    8           ; ... so the whole number column is 8 wide
LESS_STACK_MAX:  equ    250         ; line-history stack depth (must stay
                                    ; <= 255 -- less_stack_count is a byte)

            proc    pager_run
            extrn   src_rewind
            extrn   src_seek_to
            extrn   src_read_line
            extrn   src_prev_start
            extrn   src_pos
            extrn   src_line_buf
            extrn   src_prev_result
            extrn   src_search
            extrn   src_search_top
            extrn   src_search_resume
            extrn   src_last_page
            extrn   src_goto_result
            extrn   src_goto
            extrn   src_line_of
            extrn   src_line_mark
            extrn   src_set_mode
            extrn   src_at_line_start
            extrn   src_row_wrapped
            extrn   fmt_uint32
            extrn   subbyte32
            extrn   shl32
            extrn   add32
            extrn   addbyte32
            extrn   copy4bytes
            extrn   copy4bytes_to_r8
            extrn   zero4bytes
            extrn   env_getenv
            extrn   env_parse_uint
            extrn   read_line_ex
            extrn   less_top
            extrn   less_candidate_top
            extrn   less_search_buf
            extrn   less_search_start
            extrn   less_search_resume
            extrn   less_stack
            extrn   less_stack_count
            extrn   less_back_i
            extrn   less_push_i
            extrn   less_visible
            extrn   less_visible_count
            extrn   less_new_line
            extrn   less_dropped
            extrn   less_saved_pos
            extrn   less_page_end
            extrn   less_page_lines
            extrn   less_lines_this_page
            extrn   less_at_eof
            extrn   less_status_mode
            extrn   less_key
            extrn   less_rows_name
            extrn   less_esc_buf
            extrn   less_search_len
            extrn   less_count
            extrn   less_count_x2
            extrn   less_count_buf
            extrn   less_count_len
            extrn   less_count_pending
            extrn   less_title
            extrn   less_cols_name
            extrn   less_width
            extrn   less_col
            extrn   less_status_room
            extrn   less_numbers
            extrn   less_nowrap
            extrn   less_hshift
            extrn   less_top_line
            extrn   less_next_line
            extrn   less_row_line
            extrn   less_row_text
            extrn   less_room
            extrn   less_num_digits
            extrn   less_num_buf

            plo     r9                  ; D = options -- before any mov
            mov     r8, less_numbers    ; clobbers it (gotcha #4)
            glo     r9
            ani     PAGER_OPT_NUMBERS
            str     r8
            mov     r8, less_nowrap
            glo     r9
            ani     PAGER_OPT_NOWRAP
            str     r8

            mov     r8, less_title      ; the caller's name for itself,
            ghi     rf                  ; for the status line -- stashed
            str     r8                  ; before src_rewind can clobber RF
            inc     r8
            glo     rf
            str     r8

            ; --- init state ---
            call    src_rewind          ; the SOURCE resets its own state
                                        ; (src_pos = 0, buffers invalidated)
            mov     rf, less_top
            call    zero4bytes
            mov     rf, less_top_line   ; ... which is line 1
            call    zero4bytes
            mov     rf, less_top_line
            inc     rf
            inc     rf
            inc     rf
            ldi     1
            str     rf
            mov     rf, less_stack_count
            ldi     0
            str     rf
            mov     rf, less_status_mode
            ldi     0
            str     rf
            mov     rf, less_search_len
            ldi     0
            str     rf                  ; empty pattern -- 'n' is a
                                        ; no-op until a real search runs
            mov     rf, less_count_len
            ldi     0
            str     rf
            mov     rf, less_count_pending
            ldi     0
            str     rf
            mov     rf, less_search_resume
            call    zero4bytes

            mov     rf, less_visible_count
            ldi     0
            str     rf

            mov     rf, less_page_lines
            ldi     LESS_PAGE_LINES
            str     rf

            ; --- read ROWS from the environment; if valid, override
            ; less_page_lines with ROWS-1 (same "-1 for the status
            ; line" reasoning as MORE's own identical block, which
            ; this is copied from). RA/RC (entry argv/argc) are no
            ; longer needed past this point. ---
            mov     rf, less_rows_name
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    less_have_rows
            glo     rf
            lbz     less_draw_first     ; not set: keep the default

less_have_rows:
            call    env_parse_uint      ; RD = parsed value
            ghi     rd
            lbnz    less_rows_ok        ; high byte nonzero: >= 256
            ldi     2
            str     r2
            glo     rd
            sm                          ; DF=1 iff RD.lo >= 2
            lbnf    less_draw_first     ; RD < 2: keep the default

less_rows_ok:
            sub16   rd, 1               ; RD = ROWS - 1
            mov     rb, less_page_lines
            glo     rd
            str     rb

less_draw_first:
            ; clamp less_page_lines to LESS_MAX_VISIBLE -- bounds
            ; less_visible[]'s fixed-size array regardless of what a
            ; caller's ROWS happened to be set to. A no-op for the
            ; compile-time default (23), which is already well under it.
            mov     rf, less_page_lines
            ldn     rf
            smi     LESS_MAX_VISIBLE
            lbnf    less_draw_first2    ; not exceeding the cap
            mov     rf, less_page_lines
            ldi     LESS_MAX_VISIBLE
            str     rf

less_draw_first2:
            ; --- read COLUMNS the same way. Nothing the pager prints
            ; may wrap: a wrapped line or status line scrolls the whole
            ; screen, and then no row is where the scroll routines
            ; expect it. So every line -- the source's and the status
            ; line -- stops at COLUMNS-1 display columns, never touching
            ; the last column, which many terminals wrap on the moment
            ; it is written. An unset, zero or one-column value means
            ; 80. ---
            mov     rf, less_width
            ldi     LESS_WIDTH_DEFAULT
            str     rf
            mov     rf, less_cols_name
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    less_have_cols
            glo     rf
            lbz     less_draw_first3    ; not set: keep the default
less_have_cols:
            call    env_parse_uint      ; RD = parsed value
            ghi     rd
            lbnz    less_cols_wide      ; >= 256: as wide as a byte goes
            glo     rd
            smi     2
            lbnf    less_draw_first3    ; 0 or 1: keep the default
            glo     rd
            smi     1
            plo     r9
            mov     rf, less_width
            glo     r9
            str     rf                  ; limit = COLUMNS - 1
            lbr     less_draw_first3
less_cols_wide:
            mov     rf, less_width
            ldi     255
            str     rf
less_draw_first3:
            ; --- tell the source the display mode + per-row text width. In
            ; wrap mode the source breaks rows to fit that width exactly
            ; (COLUMNS-1, less the 8-wide number column when -N is on); in
            ; nowrap (-S) mode the source returns whole lines and the width
            ; is unused. ---
            mov     rf, less_width
            ldn     rf
            plo     r9                  ; R9.0 = width
            mov     rf, less_nowrap
            ldn     rf
            lbnz    lsm_room            ; -S: room = width
            mov     rf, less_numbers
            ldn     rf
            lbz     lsm_room            ; no -N: room = width
            glo     r9
            smi     LINENUM_COL
            lbnf    lsm_min             ; width < 8: clamp
            lbz     lsm_min             ; width == 8: clamp
            plo     r9                  ; room = width - 8
            lbr     lsm_room
lsm_min:
            ldi     1
            plo     r9
lsm_room:
            glo     r9
            plo     rc                  ; RC.0 = room
            mov     rf, less_nowrap
            ldn     rf
            lbz     lsm_wrap            ; nowrap flag clear -> wrapping
            ldi     0
            lbr     lsm_set
lsm_wrap:
            ldi     1
lsm_set:
            call    src_set_mode        ; D = wrap flag, RC.0 = room
            call    draw_page
            lbr     main_loop

;------------------------------------------------------------------
; main_loop: read one console keystroke and dispatch it.
;------------------------------------------------------------------
main_loop:
            call    K_READ              ; D = key (blocking)
            plo     r9                  ; stash D briefly -- "mov"
                                        ; clobbers D (gotcha #4), and
                                        ; nothing calls anything else
                                        ; before it's read back below
            mov     rf, less_key
            glo     r9
            str     rf                  ; less_key = key pressed

            ; A leading NUMBER is a prefix argument for 'g'/'G'
            ; (a line number for a text source, a byte offset for a
            ; fixed-width one -- only the source decides). Collect the
            ; digits here and keep reading; anything else dispatches
            ; normally, taking whatever count had accumulated with it.
            mov     rf, less_key
            ldn     rf
            smi     '0'
            lbnf    ml_not_digit
            smi     10
            lbdf    ml_not_digit
            call    count_digit
            lbr     main_loop

ml_not_digit:
            ; hand the pending count to this command and clear it, so a
            ; count can never leak into a LATER one
            mov     rf, less_count_len
            ldn     rf
            plo     r9
            mov     rf, less_count_pending
            glo     r9
            str     rf
            lbz     ml_no_count         ; nothing typed: leave the
                                        ; status line alone
            mov     rf, less_count_len
            ldi     0
            str     rf
            call    less_reprint_status ; wipe the ":123" echo

ml_no_count:
            mov     rf, less_key
            ldn     rf
            xri     27                  ; ESC -- check for an arrow-key
                                        ; CSI sequence
            lbz     less_escape

            mov     rf, less_key
            ldn     rf
            xri     ' '
            lbz     cmd_forward

            mov     rf, less_key
            ldn     rf
            ani     $DF                 ; uppercase-fold
            xri     'F'
            lbz     cmd_forward

            mov     rf, less_key
            ldn     rf
            ani     $DF
            xri     'B'
            lbz     cmd_back

            mov     rf, less_key        ; 'g'/'G' are DELIBERATELY NOT
            ldn     rf                  ; case-folded here, matching
            xri     'g'                 ; real less: lowercase goes to
            lbz     cmd_top             ; the top, uppercase to the end

            mov     rf, less_key
            ldn     rf
            xri     'G'
            lbz     cmd_goto_end

            mov     rf, less_key
            ldn     rf
            xri     '/'
            lbz     cmd_search

            mov     rf, less_key
            ldn     rf
            ani     $DF
            xri     'N'
            lbz     cmd_next

            mov     rf, less_key
            ldn     rf
            ani     $DF
            xri     'Q'
            lbz     cmd_quit

            mov     rf, less_key
            ldn     rf
            ani     $DF
            xri     'J'
            lbz     cmd_line_down

            mov     rf, less_key
            ldn     rf
            ani     $DF
            xri     'K'
            lbz     cmd_line_up

            mov     rf, less_key
            ldn     rf
            xri     14                  ; Ctrl-N
            lbz     cmd_line_down
            mov     rf, less_key
            ldn     rf
            xri     5                   ; Ctrl-E
            lbz     cmd_line_down
            mov     rf, less_key
            ldn     rf
            xri     16                  ; Ctrl-P
            lbz     cmd_line_up
            mov     rf, less_key
            ldn     rf
            xri     25                  ; Ctrl-Y
            lbz     cmd_line_up

            lbr     main_loop           ; unrecognized key: ignore

;------------------------------------------------------------------
; less_escape: reads the rest of a CSI escape sequence -- "ESC [ A"/
; "ESC [ B" (Up/Down, Left/Right aren't meaningful here) or the longer
; 4-byte "ESC [ 5 ~"/"ESC [ 6 ~" (PgUp/PgDn, the same VT220/xterm
; convention this project's own Delete-key handling, ESC[3~, already
; established elsewhere) and dispatches. Uses K_READ for every follow-
; on read, matching progs/shell.asm's own current (2026-08-26) choice
; for this exact situation over a raw f_uread call -- see rlwh_escape's
; own header comment in shell.asm for the full byte-drop history and
; why this is a real, acknowledged risk rather than a settled-safe
; default; if arrow/PgUp/PgDn keys prove unreliable on real hardware,
; that write-up is the first place to look. Any sequence that doesn't
; match exactly (wrong byte at any position) is silently discarded
; rather than guessed at, matching this project's established
; preference for a visibly-inert malformed sequence over a masked one.
;------------------------------------------------------------------
less_escape:
            call    K_READ
            plo     r9
            glo     r9
            xri     '['
            lbnz    main_loop           ; not a CSI sequence: discard

            call    K_READ
            plo     r9
            glo     r9
            xri     'A'
            lbz     cmd_line_up
            glo     r9
            xri     'B'
            lbz     cmd_line_down
            glo     r9
            xri     'C'
            lbz     cmd_hscroll_right   ; Right arrow (-S mode only)
            glo     r9
            xri     'D'
            lbz     cmd_hscroll_left    ; Left arrow (-S mode only)
            glo     r9
            xri     '5'
            lbz     less_escape_pgup
            glo     r9
            xri     '6'
            lbz     less_escape_pgdn
            lbr     main_loop           ; any other letter: ignore

less_escape_pgup:
            call    K_READ
            plo     r9
            glo     r9
            xri     '~'
            lbnz    main_loop           ; malformed: discard
            lbr     cmd_back

less_escape_pgdn:
            call    K_READ
            plo     r9
            glo     r9
            xri     '~'
            lbnz    main_loop
            lbr     cmd_forward

;------------------------------------------------------------------
cmd_forward:
            mov     rf, less_at_eof
            ldn     rf
            lbnz    main_loop           ; already at EOF: ignore

            call    less_push_visible_all  ; push the OLD page's lines

            ; new top = wherever we currently are -- forward paging
            ; is sequential, so src_pos already sits exactly at the
            ; start of the next page with no seek needed.
            mov     rf, src_pos
            mov     rd, less_top
            call    copy4bytes
            mov     rf, less_next_line  ; and its number is simply the
            mov     rd, less_top_line   ; one after the old bottom row's
            call    copy4bytes

            call    draw_page
            lbr     main_loop

;------------------------------------------------------------------
; cmd_back: pops up to less_page_lines entries from less_stack, one at
; a time. If the stack runs dry before that (or was already empty),
; falls back to a real backward scan (src_prev_start) for
; the REMAINING steps -- the same fallback cmd_line_up uses, and for
; the same reason: an earlier version just stopped early instead,
; which meant 'b' after a big jump ('G', 'g', a search match -- none
; of which push their own old page onto less_stack anymore, see
; cmd_goto_end's own header comment for why) could pop stale, non-
; adjacent entries left over from BEFORE that jump, landing somewhere
; confusingly unrelated rather than genuinely one page back. Stops
; early (using whatever position it has reached) if less_top hits 0 --
; there's nothing before the true start of the file to scan into.
; A zero-step result (nothing popped AND nothing scanned) is a no-op.
;------------------------------------------------------------------
cmd_back:
            mov     rf, less_back_i
            ldi     0
            str     rf

cmd_back_loop:
            mov     rb, less_page_lines
            ldn     rb
            str     r2
            mov     rf, less_back_i
            ldn     rf
            sm                          ; D = back_i - page_lines, DF=1
                                        ; iff back_i >= page_lines
            lbdf    cmd_back_done

            call    less_pop_top
            lbnf    cmd_back_step_done  ; DF=0: popped a real entry

            ; stack empty -- fall back to a real scan, if there's
            ; anything left to scan into
            mov     rf, less_top
            ldn     rf
            lbnz    cmd_back_scan
            inc     rf
            ldn     rf
            lbnz    cmd_back_scan
            inc     rf
            ldn     rf
            lbnz    cmd_back_scan
            inc     rf
            ldn     rf
            lbnz    cmd_back_scan
            lbr     cmd_back_check      ; all 4 bytes are 0: stop here

cmd_back_scan:
            mov     rf, less_top
            call    src_prev_start
            mov     rf, src_prev_result
            mov     rd, less_top
            call    copy4bytes

cmd_back_step_done:
            mov     rf, less_back_i
            ldn     rf
            adi     1
            str     rf
            lbr     cmd_back_loop

cmd_back_check:
            mov     rf, less_back_i
            ldn     rf
            lbz     main_loop           ; zero successful steps: ignore

cmd_back_done:
            call    less_goto
            lbr     main_loop

;------------------------------------------------------------------
; cmd_top ('g'): jump to byte 0. This is a "big jump", not a
; sequential step -- the page that was on screen before it isn't
; necessarily adjacent to anything reachable from the new position, so
; (unlike cmd_forward/cmd_line_down, which only ever move into
; genuinely sequential content and are always safe to push) it clears
; less_stack instead of pushing the old page onto it. A stale entry
; left over from before the jump would otherwise let 'b'/up-arrow pop
; straight to some unrelated old position instead of correctly
; scanning backward from wherever the jump actually landed -- see
; cmd_back's own header for the full reasoning (this used to push,
; and cmd_goto_end's identical old behavior was the confirmed source
; of exactly that bug).
;------------------------------------------------------------------
cmd_top:
            mov     rf, less_count_pending
            ldn     rf
            lbnz    cmd_goto_number     ; "<n>g" -- a numbered jump

            mov     rf, less_stack_count
            ldi     0
            str     rf
            mov     rf, less_top
            call    zero4bytes
            call    less_goto
            lbr     main_loop

;------------------------------------------------------------------
; cmd_goto_end ('G'): jump to the file's true last page -- there's no
; way to know where that starts without actually reading up to it (a
; text file has no fixed line width), so this scans the WHOLE file
; forward from byte 0, maintaining a trailing window of exactly
; less_page_lines lines the entire way (reusing less_shift_left_core,
; the SAME array-shift logic single-line-down moves already use, just
; called directly in a loop instead of via less_shift_visible_left).
;
; Deliberately does NOT push each scanned line onto less_stack (see
; less_shift_left_core's own header for why), and -- like cmd_top --
; clears less_stack entirely rather than pushing the OLD (pre-jump)
; page onto it. An earlier version pushed the old page here, which
; meant the FIRST up-arrow/'b' after 'G' would pop that stale entry
; instead of ever reaching the real backward-scan fallback
; (src_prev_start) -- landing on some unrelated old line
; instead of the true adjacent one. Clearing the stack means every
; 'b'/up-arrow after 'G' goes through the scan fallback from the very
; first press, which is slower (a real backward disk scan each time)
; but always lands on the correct, adjacent line -- exactly what was
; asked for over the old "confusing tradeoff".
;------------------------------------------------------------------
cmd_goto_end:
            mov     rf, less_count_pending
            ldn     rf
            lbnz    cmd_goto_number     ; "<n>G" is the same as "<n>g",
                                        ; matching real less

            ; A "big jump": clear the history stack rather than pushing
            ; the page being left, same as cmd_top and a search match.
            mov     rf, less_stack_count
            ldi     0
            str     rf

            ; Ask the SOURCE for the top of the last page. This used to
            ; read the whole file forward, keeping a sliding window of
            ; the last page_lines line starts -- O(file size) for a
            ; result that is O(one screen) of backward steps. Only the
            ; source can walk backward, since only it knows what a line
            ; is; less_visible[] does not need filling here either,
            ; because draw_page repopulates it from less_top anyway.
            mov     rf, less_page_lines
            ldn     rf
            call    src_last_page
            mov     rf, src_goto_result
            mov     rd, less_top
            call    copy4bytes
            call    less_goto_end       ; last page: mark EOF so the
            lbr     main_loop           ; status shows (END) and forward/
                                        ; down are no-ops

;------------------------------------------------------------------
; less_goto_end: like less_goto, but for a jump that lands on the file's
; LAST page (G, or a numbered jump past the end). draw_page only sets
; less_at_eof when a read hits EOF DURING the draw, i.e. on a SHORT last
; page; a last page that is exactly full ends right at EOF without a
; short read, so less_at_eof would stay 0 and the status would read as
; if there were more below (and forward/down would try to move). Since
; a last-page jump is at the end by construction, set less_at_eof here
; and reprint the status row so it shows (END). Redundant-but-harmless
; on a short page (draw already set it). Verified: after G the last real
; line is always on screen (the backward scan is exact); this only fixes
; the status/at-end behaviour, not what is displayed.
;------------------------------------------------------------------
less_goto_end:
            call    less_goto
            mov     rf, less_at_eof
            ldi     1
            str     rf
            call    less_reprint_status
            rtn

;------------------------------------------------------------------
cmd_search:
            call    K_INMSG
            db      13,10,'/',0
            mov     rf, less_search_buf
            ldi     LESS_SEARCH_MAX-1
            plo     rc
            ldi     LE_MODE_REDIR
            call    read_line_ex

            mov     rf, less_search_buf
            ldn     rf
            lbz     cs_cancel           ; empty pattern: cancel

            ; Turn what was typed into raw BYTES. Escapes are parsed
            ; here, in the pager, because they belong to the input --
            ; the same reason the '/' prompt does. What the resulting
            ; bytes MEAN is the source's business (see src_search).
            call    parse_escapes
            lbdf    cs_bad_escape
            mov     rf, less_search_len
            ldn     rf
            lbz     cs_cancel           ; parsed away to nothing

            ; a NEW search always (re)establishes both the scan start
            ; and the "if this fails, 'n' retries from here" baseline
            ; as the current view position -- lsf_found below advances
            ; less_search_resume past the match on success; on
            ; failure it's left at this same baseline.
            mov     rf, src_pos
            mov     rd, less_search_start
            call    copy4bytes
            mov     rf, src_pos
            mov     rd, less_search_resume
            call    copy4bytes

            call    less_search_forward
            lbr     main_loop

cs_cancel:
            call    less_goto           ; redraw current page, clearing
                                        ; the prompt line remnants
            lbr     main_loop

cs_bad_escape:
            ; Report and drop the pattern rather than searching for
            ; something the user did not mean -- silently treating a
            ; bad escape as literal text hides typos.
            mov     rf, less_search_len
            ldi     0
            str     rf
            mov     rf, less_status_mode
            ldi     2
            str     rf
            call    less_goto           ; redraw, then overwrite the
            mov     rf, less_page_lines ; status row with the message
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            call    K_READ              ; "press any key", same as the
                                        ; not-found path below
            mov     rf, less_status_mode
            ldi     0
            str     rf
            call    less_reprint_status
            lbr     main_loop

;------------------------------------------------------------------
cmd_next:
            mov     rf, less_search_len
            ldn     rf
            lbz     main_loop           ; no previous pattern: ignore

            ; resume scanning from just past the last match (see
            ; less_search_forward's own header for why this can't
            ; just be src_pos -- less_goto always forces
            ; src_pos == less_top, which after landing on a match IS
            ; the match's own start, not one line past it)
            mov     rf, less_search_resume
            mov     rd, less_search_start
            call    copy4bytes

            call    less_search_forward
            lbr     main_loop

;------------------------------------------------------------------
cmd_quit:
            call    K_INMSG
            db      13,10,0             ; land the shell's next prompt
                                        ; at the start of a fresh line
            ldi     0                   ; exit code 0 = success
            rtn

;------------------------------------------------------------------
; cmd_goto_number: "<n>g" / "<n>G" -- jump to whatever the SOURCE
; makes of the number n. The pager only collected the digits; it has
; no idea whether n counts lines, bytes or sectors, and does not need
; to. A count past the end of the data is not an error here: the
; source says so (DF=1) and this shows the last page, exactly as a
; bare 'G' would, because that is a display decision.
;------------------------------------------------------------------
cmd_goto_number:
            mov     rf, less_stack_count
            ldi     0
            str     rf                  ; a "big jump": clear history

            mov     rf, less_count
            call    src_goto
            lbdf    cgn_past_end

            mov     rf, src_goto_result
            mov     rd, less_top
            call    copy4bytes
            call    less_goto
            lbr     main_loop

cgn_past_end:
            mov     rf, less_page_lines
            ldn     rf
            call    src_last_page
            mov     rf, src_goto_result
            mov     rd, less_top
            call    copy4bytes
            call    less_goto_end       ; past the end: same as G
            lbr     main_loop

;------------------------------------------------------------------
; count_digit: fold the ASCII digit in less_key into less_count
; (less_count = less_count*10 + digit) and echo the digits typed so
; far on the status row, so a prefix argument is visible as it is
; entered rather than being typed blind.
;
; Capped at COUNT_MAX_DIGITS, which keeps the value well inside 32
; bits -- further digits are ignored rather than silently wrapping the
; count around into a completely different position.
;------------------------------------------------------------------
count_digit:
            mov     rf, less_count_len
            ldn     rf
            smi     COUNT_MAX_DIGITS
            lbdf    cd_echo             ; already full: ignore the digit
                                        ; but keep the echo on screen

            ; first digit of a fresh count: start from zero
            mov     rf, less_count_len
            ldn     rf
            lbnz    cd_accumulate
            mov     rf, less_count
            call    zero4bytes

cd_accumulate:
            ; less_count = less_count*10 + digit, via 8c + 2c
            mov     rf, less_count
            call    shl32               ; 2c
            mov     rf, less_count
            mov     rd, less_count_x2
            call    copy4bytes          ; keep 2c
            mov     rf, less_count
            call    shl32               ; 4c
            mov     rf, less_count
            call    shl32               ; 8c
            mov     rf, less_count
            mov     rd, less_count_x2
            call    add32               ; 10c
            mov     rf, less_key
            ldn     rf
            smi     '0'
            plo     r9                  ; the digit's value
            mov     rf, less_count
            glo     r9
            call    addbyte32

            ; remember the character too, purely for the echo
            mov     rf, less_count_len
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            mov     r8, less_count_buf
            add16   r8, r9
            mov     rf, less_key
            ldn     rf
            str     r8
            inc     r8
            ldi     0
            str     r8                  ; keep it NUL-terminated

            mov     rf, less_count_len
            ldn     rf
            adi     1
            str     rf

cd_echo:
            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    K_INMSG
            db      27,'[K',':',0
            mov     rf, less_count_buf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; less_search_forward: scan forward from less_search_start (set by
; the caller -- cmd_search uses the current view position, cmd_next
; uses less_search_resume) for less_search_buf (case-sensitive
; literal substring), one line at a time.
;
; On a match: snapshots less_search_resume = the position one line
; PAST the match (so a later 'n' continues instead of re-matching the
; same line forever -- this can't just be "whatever src_pos ends up
; at", since less_goto below always forces src_pos == less_top, and
; less_top after landing on a match IS the match's own start), then
; clears less_stack (a match is a "big jump", not adjacent to the old
; page -- see lsf_found's own comment), sets the new top to the
; matched line's start, and redraws there.
;
; On reaching EOF with no match: redraws the CURRENT (unchanged) page
; with a "not found" status line, and leaves the read position
; exactly where it was before the scan (less_goto re-seeks to
; less_top, which never moved). less_search_resume is left untouched
; (still the search's own starting baseline, set by the caller) --
; so a following 'n' just retries the identical scan.
;------------------------------------------------------------------
less_search_forward:
            ; The whole scan belongs to the source: only it knows what
            ; its bytes are and what a displayable position is (a line
            ; start here, a row start for a fixed-width source). The
            ; pager supplies the pattern and the starting point and
            ; takes back two positions.
            mov     rd, less_search_start
            mov     rf, less_search_buf
            mov     r8, less_search_len ; (mov clobbers D -- load the
            ldn     r8                  ;  length AFTER the pointers)
            plo     rc
            call    src_search
            lbdf    lsf_notfound

            mov     rf, src_search_top
            mov     rd, less_candidate_top
            call    copy4bytes

lsf_found:
            mov     rf, src_search_resume
            mov     rd, less_search_resume
            call    copy4bytes

            ; A search match is a "big jump" like 'g'/'G' -- clear
            ; less_stack rather than pushing the old (pre-search) page
            ; onto it, so a later 'b'/up-arrow correctly scans backward
            ; from the match instead of popping a stale, unrelated
            ; entry from before the search ran. See cmd_goto_end's own
            ; header for the full reasoning (same bug, same fix).
            mov     rf, less_stack_count
            ldi     0
            str     rf
            mov     rf, less_candidate_top
            mov     rd, less_top
            call    copy4bytes
            call    less_goto           ; seeks + redraws (normal
                                        ; status line)
            rtn

lsf_notfound:
            ; restore src_pos (and the FCB's real position) to what
            ; they were for THIS page before the scan -- less_top
            ; never changed, so there's no need for less_goto's own
            ; full CLS+redraw here, just the status line needs
            ; touching; less_page_end holds exactly the right value
            ; (snapshotted by draw_page's own dp_status, every time)
            mov     rf, less_page_end
            call    src_seek_to         ; also sets src_pos

            mov     rf, less_status_mode
            ldi     1
            str     rf
            call    less_reprint_status ; status row only -- see its
                                        ; own header comment

            call    K_READ              ; consume the "press any key"
                                        ; keystroke HERE, matching
                                        ; MORE's own "-- More --"/"any
                                        ; key continues" convention --
                                        ; an earlier version left this
                                        ; unconsumed, so the very next
                                        ; real keystroke fell straight
                                        ; through to main_loop's normal
                                        ; dispatch instead of just
                                        ; dismissing the message. A
                                        ; LATER version redrew the
                                        ; whole page here (via
                                        ; less_goto) to restore the
                                        ; normal status line, which
                                        ; visibly flickered the entire
                                        ; screen just to change one
                                        ; row -- less_reprint_status
                                        ; below fixes that too.

            mov     rf, less_status_mode
            ldi     0
            str     rf
            call    less_reprint_status
            rtn

;------------------------------------------------------------------
; less_goto: seek to less_top (src_seek_to also sets src_pos), and
; redraw.
;------------------------------------------------------------------
less_goto:
            call    less_sync_top_line  ; a jump: ask the source what
                                        ; line the new top is
            mov     rf, less_top
            call    src_seek_to

            call    draw_page
            rtn

;------------------------------------------------------------------
; less_sync_top_line: with -N on, less_top_line = the source's line
; number for less_top. Called only where less_top has just jumped; a
; sequential move knows the number already. The source leaves its read
; position unspecified, so every caller seeks right afterward. A source
; with no line numbers (DF=1) turns -N off for the rest of the session.
;------------------------------------------------------------------
less_sync_top_line:
            mov     rf, less_numbers
            ldn     rf
            lbz     lstl_done
            mov     rf, less_top
            call    src_line_of         ; RD:R8 = its number
            lbdf    lstl_none
            mov     rf, less_top_line
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            inc     rf
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
lstl_done:
            rtn
lstl_none:
            mov     rf, less_numbers
            ldi     0
            str     rf
            rtn

;------------------------------------------------------------------
; draw_page: clear the screen and print up to less_page_lines lines
; starting from the CURRENT position (precondition: src_pos ==
; less_top, and the FCB/chunk buffer are correctly positioned there --
; every caller of draw_page establishes this first), then a status
; line at the FIXED row less_page_lines+1 -- not just wherever content
; happens to stop -- so it always lands on the exact same physical row
; scroll_up_and_print_bottom/scroll_down_and_print_top/
; less_reprint_status already assume when THEY reprint the status line
; later. Sets less_at_eof if EOF is hit before a full page prints.
;
; This explicit positioning matters specifically on a SHORT last page
; (fewer real lines in the file than less_page_lines, i.e. viewing at
; or near true EOF): without it, the status line would print right
; after however many real lines got shown -- several rows ABOVE the
; fixed row every other caller expects -- leaving stray, never-cleared
; text sitting in the middle of the content area. The very next single-
; line move (up/down-arrow) would then scroll the WHOLE screen via
; IND/RI, dragging that leftover text around instead of erasing it,
; compounding with every further move -- confirmed as the real cause
; of a hardware-reported bug (2026-09-02) where phantom lines appeared
; mid-screen, then a `(END)` prompt ended up stuck partway down the
; page, after paging near the end of a file whose last page didn't
; fill the screen.
;
; Also (re)populates the ENTIRE less_visible[] window from scratch --
; less_visible[i] is snapshotted to src_pos immediately before the
; i-th src_read_line call, so it always holds that line's own real
; start offset -- and sets less_visible_count to however many lines
; actually got shown (< less_page_lines only when EOF was hit). This
; is what lets a later single line-up move walk back through EVERY
; line of whatever page was most recently drawn, not just its first.
;------------------------------------------------------------------
draw_page:
            call    K_INMSG
            db      27,'[H',27,'[J',0

            mov     rf, less_at_eof
            ldi     0
            str     rf
            mov     rf, less_lines_this_page
            ldi     0
            str     rf
            mov     rf, less_top_line   ; row 0's number (unused without
            mov     rd, less_row_line   ; -N); put_row advances it
            call    copy4bytes

dp_loop:
            ; less_visible[i] = src_pos (i = less_lines_this_page,
            ; the index about to be filled)
            mov     rf, less_lines_this_page
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9                  ; R9 = i*4
            mov     r8, less_visible
            add16   r8, r9              ; R8 = &less_visible[i]
            mov     rf, src_pos
            call    copy4bytes_to_r8

            call    src_read_line
            lbdf    dp_eof

            ; -N number bookkeeping. less_row_line holds the CURRENT row's
            ; source line number. Row 0 already has it (= less_top_line, and
            ; the source is told the top's number here so a later jump counts
            ; from it -- not before the read: a top at EOF is no line). A
            ; later row that BEGINS a new source line bumps the number by 1;
            ; a wrapped continuation keeps it (put_row blanks the column). A
            ; nowrap source always starts a line, so this is +1 per row --
            ; exactly the old behaviour.
            mov     rf, less_numbers
            ldn     rf
            lbz     dp_print            ; no -N: no number work at all
            mov     rf, less_lines_this_page
            ldn     rf
            lbz     dp_mark_top         ; row 0: no bump, mark the top
            mov     rf, src_at_line_start
            ldn     rf
            lbz     dp_print            ; continuation row: keep the number
            mov     rf, less_row_line
            ldi     1
            call    addbyte32           ; a new source line
            lbr     dp_print
dp_mark_top:
            mov     rf, less_top
            mov     rd, less_top_line
            call    src_line_mark
dp_print:
            mov     rf, src_line_buf
            call    put_row             ; number + line, cut to the width
            call    K_INMSG
            db      13,10,0

            mov     rf, less_lines_this_page
            ldn     rf
            adi     1
            str     rf

            mov     rf, less_page_lines
            ldn     rf                  ; D = page_lines
            str     r2
            mov     rf, less_lines_this_page
            ldn     rf                  ; D = lines_printed
            sm                          ; D = lines_printed -
                                        ; page_lines, DF=1 iff
                                        ; lines_printed >= page_lines
            lbnf    dp_loop             ; not yet a full page

            lbr     dp_status

dp_eof:
            mov     rf, less_at_eof
            ldi     1
            str     rf

dp_status:
            ; less_next_line = the number the row AFTER the bottom will get:
            ; the bottom row's own number, plus 1 unless that row wrapped
            ; (in which case the next row continues the same source line).
            mov     rf, less_row_line
            mov     rd, less_next_line
            call    copy4bytes
            mov     rf, src_row_wrapped
            ldn     rf
            lbnz    dp_status_vis       ; wrapped: next row is a continuation
            mov     rf, less_next_line
            ldi     1
            call    addbyte32
dp_status_vis:
            mov     rb, less_visible_count
            mov     rf, less_lines_this_page
            ldn     rf
            str     rb                  ; less_visible_count =
                                        ; less_lines_this_page

            ; snapshot the correct "resume" position for THIS page --
            ; used by a failed search (lsf_notfound) to restore
            ; src_pos/the FCB position without needing a full redraw
            ; to re-derive it
            mov     rf, src_pos
            mov     rd, less_page_end
            call    copy4bytes

            ; ALWAYS reprint at the fixed status row, regardless of how
            ; many real content lines were actually drawn -- see this
            ; routine's own header comment for why a short last page
            ; makes this matter.
            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            rtn

;------------------------------------------------------------------
; print_status_line: every caller positions at column 1 of the status
; row immediately before calling this, so the leading clear-to-EOL
; below wipes the WHOLE row before any text lands on it. That matters
; after a scroll: RI leaves a real CONTENT line sitting on the status
; row, and IND/RI both leave one on the row above -- text printed over
; a dirty row only covers the columns it actually writes, so anything
; longer than the new text (or anything under a TAB, which advances
; the cursor without writing) shows straight through. Clearing FIRST
; is the only form that handles the tab case; a trailing clear can't.
;------------------------------------------------------------------
print_status_line:
            call    K_INMSG
            db      27,'[K',0

            ; everything below goes through psl_put, which stops once
            ; this line has used up its room (see less_draw_first2)
            mov     rf, less_width
            ldn     rf
            plo     r9
            mov     rf, less_status_room
            glo     r9
            str     rf

            mov     rf, less_status_mode
            ldn     rf
            lbz     psl_normal
            xri     2
            lbz     psl_bad_escape
            lbr     psl_notfound

psl_normal:

            mov     rf, less_at_eof
            ldn     rf
            lbnz    psl_end

            mov     rf, psl_s_open
            call    psl_put
            mov     rf, less_title
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            call    psl_put
            mov     rf, less_width
            ldn     rf
            smi     LESS_WIDTH_DEFAULT
            lbdf    psl_long            ; 80 columns or more: the full text
            mov     rf, psl_s_short     ; narrower: the same keys, briefer
            call    psl_put
            rtn
psl_long:
            mov     rf, psl_s_long
            call    psl_put
            rtn

psl_end:
            mov     rf, psl_s_end
            call    psl_put
            rtn

psl_notfound:
            mov     rf, psl_s_notfound
            call    psl_put
            rtn

psl_bad_escape:
            mov     rf, psl_s_bad_escape
            call    psl_put
            rtn

;------------------------------------------------------------------
; psl_put: print the NUL-terminated string at RF, one character at a
; time, for as long as less_status_room lasts -- a narrow screen gets a
; cut-off status line rather than a wrapped one.
; Args: RF = string.  Modifies: R8, D (RF advanced; RF survives K_TYPE,
; which progs/type.asm's own hot loop has always depended on)
;------------------------------------------------------------------
psl_put:
            ldn     rf
            lbz     psl_put_done        ; end of the string
            mov     r8, less_status_room
            ldn     r8
            lbz     psl_put_done        ; out of room
            smi     1
            str     r8
            lda     rf
            call    K_TYPE
            lbr     psl_put
psl_put_done:
            rtn

;------------------------------------------------------------------
; put_row: print one row -- the line number first when -N is on, then
; the line itself, the two together cut to less_width columns.
;
; The number is right-justified in LINENUM_WIDTH columns and followed by
; a space, as real less -N does; a number wider than that just takes
; more room. put_line then gets whatever columns remain, and counts its
; tab stops from where the text starts, not from the left edge. On a
; screen too narrow for even the number, the number itself is cut and
; the text gets no room at all -- nothing the pager prints may wrap.
;
; Args:    RF = NUL-terminated line.
; Uses:    less_row_line, printed and then advanced by 1 (with -N only).
; Modifies: everything
;------------------------------------------------------------------
put_row:
            mov     r8, less_row_text   ; K_MSG moves RF: keep the line
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8

            mov     rf, less_width
            ldn     rf
            plo     r9
            mov     rf, less_room
            glo     r9
            str     rf                  ; room = the whole width

            mov     rf, less_numbers
            ldn     rf
            lbz     pr_text
            mov     rf, src_at_line_start
            ldn     rf
            lbz     pr_blanks           ; a wrapped continuation row: the
                                        ; number column is left blank

            mov     rf, less_row_line
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, less_num_digits
            call    fmt_uint32

            ; R9.0 = how many digits
            mov     rf, less_num_digits
            ldi     0
            plo     r9
pr_len:
            lda     rf
            lbz     pr_len_done
            glo     r9
            adi     1
            plo     r9
            lbr     pr_len
pr_len_done:
            ; less_num_buf = spaces up to LINENUM_WIDTH, digits, a space.
            ; No calls from here to the K_MSG, so registers are safe.
            mov     rd, less_num_buf    ; write cursor
            glo     r9
            smi     LINENUM_WIDTH
            lbdf    pr_digits           ; that wide already: no padding
            sdi     0                   ; D = LINENUM_WIDTH - digits
            plo     rb
pr_pad:
            ldi     ' '
            str     rd
            inc     rd
            glo     rb
            smi     1
            plo     rb
            lbnz    pr_pad
pr_digits:
            mov     rf, less_num_digits
pr_copy:
            lda     rf
            lbz     pr_copy_done
            str     rd
            inc     rd
            lbr     pr_copy
pr_copy_done:
            ldi     ' '
            str     rd
            inc     rd
            ldi     0
            str     rd

            ; RB.0 = the prefix's length: max(digits, width) + 1
            glo     r9
            smi     LINENUM_WIDTH
            lbdf    pr_wide
            ldi     LINENUM_WIDTH+1
            lbr     pr_have_len
pr_wide:
            glo     r9
            adi     1
pr_have_len:
            plo     rb

            mov     rf, less_width
            ldn     rf
            str     r2
            glo     rb
            sm                          ; prefix - width
            lbdf    pr_cut              ; no borrow: it fills the row

            sdi     0                   ; room = width - prefix
            plo     r9
            mov     rf, less_room
            glo     r9
            str     rf
            lbr     pr_print

pr_cut:
            mov     rf, less_width      ; end the prefix at the width
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            mov     rf, less_num_buf
            add16   rf, r9
            ldi     0
            str     rf
            mov     rf, less_room
            ldi     0
            str     rf                  ; and leave the text no room

pr_print:
            mov     rf, less_num_buf
            call    K_MSG

pr_text:
            mov     rf, less_row_text
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            call    put_line
            rtn                         ; the caller advances less_row_line
                                        ; (only a line-start row bumps it, so
                                        ; the count can't be done here)

;------------------------------------------------------------------
; pr_blanks: -N continuation row -- fill the number column with spaces
; (min(width, LINENUM_COL) of them) instead of a number, leaving the text
; the same room a numbered row leaves it, then print the text.
;------------------------------------------------------------------
pr_blanks:
            mov     rf, less_width
            ldn     rf
            plo     r9                  ; R9.0 = width
            smi     LINENUM_COL
            lbnf    pr_bl_narrow        ; width < 8
            plo     rb                  ; RB.0 = room = width - 8
            mov     rf, less_room
            glo     rb
            str     rf
            ldi     LINENUM_COL
            plo     rb                  ; RB.0 = blank count = 8
            lbr     pr_bl_emit
pr_bl_narrow:
            mov     rf, less_room
            ldi     0
            str     rf                  ; room = 0
            glo     r9
            plo     rb                  ; blank count = width
pr_bl_emit:
            mov     rd, less_num_buf
pr_bl_loop:
            glo     rb
            lbz     pr_bl_done
            ldi     ' '
            str     rd
            inc     rd
            glo     rb
            smi     1
            plo     rb
            lbr     pr_bl_loop
pr_bl_done:
            ldi     0
            str     rd                  ; NUL-terminate
            mov     rf, less_num_buf
            call    K_MSG
            lbr     pr_text

;------------------------------------------------------------------
; put_line: print a line from the source, cut at less_room DISPLAY
; columns -- the `less -S` behaviour. less_room is set by put_row: the
; whole width, or what a line number leaves of it. The line itself is untouched; only
; what reaches the screen is shortened, so searching, positions and
; scrolling never see the difference.
;
; A TAB moves to the next multiple of 8 and is printed only if it lands
; no further right than less_room; any other byte counts as one column.
; A cursor sitting at column less_room is fine -- only a character
; printed THERE would wrap -- so a tab may land exactly on it.
;
; Args:    RF = NUL-terminated line
; Modifies: R8, R9, D, DF (RF advanced; it survives K_TYPE, which
;           progs/type.asm's own hot loop has always depended on)
;------------------------------------------------------------------
put_line:
            ; The source has already applied the -S horizontal scroll: it
            ; skipped less_hshift display columns while READING, so the
            ; buffer at RF already starts at the visible edge and can reach
            ; arbitrarily far into a long line without the pager ever holding
            ; the scrolled-past prefix. (hshift is 0 in wrap mode and for
            ; HEXDUMP, where RF is simply the row start.) Nothing to skip
            ; here -- render up to less_room columns straight from RF.
pl_render:
            mov     r8, less_col
            ldi     0
            str     r8                  ; screen column 0

pl_loop:
            ldn     rf
            lbz     pl_done             ; end of the line
            xri     9
            lbz     pl_tab

            mov     r8, less_room
            ldn     r8
            str     r2
            mov     r8, less_col        ; (mov leaves M(R2) alone)
            ldn     r8
            sm                          ; column - width
            lbdf    pl_done             ; no borrow: no room for it
            ldn     r8
            adi     1
            str     r8                  ; column + 1
            lda     rf
            call    K_TYPE
            lbr     pl_loop

pl_tab:
            mov     r8, less_col
            ldn     r8
            ori     7
            adi     1                   ; the next multiple of 8
            lbdf    pl_done             ; past 255: certainly too far
            plo     r9
            mov     r8, less_room
            ldn     r8
            str     r2
            glo     r9
            sm                          ; stop - width
            lbnf    pl_tab_fits         ; borrow: short of the width
            lbnz    pl_done             ; beyond it
pl_tab_fits:
            mov     r8, less_col
            glo     r9
            str     r8
            lda     rf
            call    K_TYPE              ; the tab itself
            lbr     pl_loop

pl_done:
            rtn

psl_s_open:         db      "-- ",0
psl_s_long:         db      ": SPACE next  b back  g top  G end  / search  n again  q quit --",0
psl_s_short:        db      ": SPACE/b page  g/G ends  / find  n again  q quit --",0
psl_s_end:          db      "-- (END) --  b back  g top  / search  q quit --",0
psl_s_notfound:     db      "-- Pattern not found -- press any key --",0
psl_s_bad_escape:   db      "-- Bad escape (use \\ \n \r \t \0 \xHH) -- press any key --",0

;------------------------------------------------------------------
; less_reprint_status: repositions to the status row and reprints it
; ALONE -- used by lsf_notfound so showing/dismissing the "Pattern not
; found" message doesn't need a full page redraw, unlike every other
; status-line update in this file (which happens as the tail end of a
; real draw_page call). Needs no clear of its own: print_status_line
; clears the row itself now, which also covers this routine's original
; reason for existing (the new text being shorter than what was there).
;------------------------------------------------------------------
less_reprint_status:
            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            rtn

;------------------------------------------------------------------
; format_row_number: writes D's decimal digits (1 or 2 -- D is always
; < 100, see LESS_MAX_VISIBLE's own comment) at [RF], WITHOUT a NUL
; terminator. Makes no calls, so every register here is safely
; register-resident throughout (no memory round-trips needed).
; Args:    D = value (0-99), RF = write cursor
; Returns: RF = advanced past the digit(s) written
; Verified against Python's own str() across the full 0..99 range
; before being trusted here (2026-09-01).
;------------------------------------------------------------------
format_row_number:
            plo     r8                  ; stash D (gotcha #4 -- nothing
                                        ; between here and its use below
                                        ; clobbers D except deliberately)
            ldi     0
            phi     r8                  ; R8 = value, zero-extended
            glo     r8
            smi     10
            lbnf    frn_one_digit       ; < 10: DF=0 (borrow)

            glo     r8
            plo     r9                  ; R9.0 = remaining value
            ldi     0
            plo     rb                  ; RB.0 = tens count

frn_tens_loop:
            glo     r9
            smi     10
            lbnf    frn_tens_done       ; would borrow: r9 is the final
                                        ; remainder, unchanged by this
                                        ; failed attempt
            plo     r9
            glo     rb
            adi     1
            plo     rb
            lbr     frn_tens_loop

frn_tens_done:
            glo     rb
            adi     '0'
            str     rf
            inc     rf
            glo     r9
            adi     '0'
            str     rf
            inc     rf
            rtn

frn_one_digit:
            glo     r8
            adi     '0'
            str     rf
            inc     rf
            rtn

;------------------------------------------------------------------
; position_at_row: moves the cursor to row D, column 1 (ESC[<D>;1H).
; Args: D = row number (1-99)
;------------------------------------------------------------------
position_at_row:
            plo     r7                  ; stash D (gotcha #4)
            mov     rf, less_esc_buf
            ldi     27
            str     rf
            inc     rf
            ldi     '['
            str     rf
            inc     rf
            glo     r7
            call    format_row_number
            ldi     ';'
            str     rf
            inc     rf
            ldi     '1'
            str     rf
            inc     rf
            ldi     'H'
            str     rf
            inc     rf
            ldi     0
            str     rf

            mov     rf, less_esc_buf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; scroll_up_and_print_bottom: scrolls the WHOLE terminal up by one
; line via IND (ESC D, "Index") -- the plain two-character VT100
; sequence, not CSI-based SU (ESC[1S). Switched 2026-09-01 after a
; hardware round confirmed ESC[S has no visible effect on the actual
; terminal in use (the two rows this routine repositions/reprints
; updated correctly, but nothing else on screen shifted) -- CSI SU/SD
; are an ECMA-48/ANSI X3.64 addition, not part of the original VT100
; set, unlike IND/RI, which are. IND only scrolls when the cursor is
; ALREADY at the bottom margin (with no scroll region set, that's the
; terminal's own real last row) -- otherwise it just moves the cursor
; down one row with no scroll at all -- so this positions there FIRST
; (row less_page_lines+1, the status line's own row) before sending
; it. Same reasoning as the old SU-based version for why BOTH rows
; still need reprinting afterward: IND leaves the cursor at the
; (now blank) bottom row, having moved what WAS there (the status
; line's text) up into what should be the new bottom CONTENT row.
;------------------------------------------------------------------
scroll_up_and_print_bottom:
            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row     ; the true bottom margin
            call    K_INMSG
            db      27,'D',0            ; IND -- scrolls up by 1;
                                        ; cursor stays at this row

            mov     rf, less_page_lines
            ldn     rf
            call    position_at_row
            call    K_INMSG
            db      27,'[K',0           ; clear the WHOLE row FIRST --
                                        ; see the header above for why a
                                        ; trailing clear isn't enough
            mov     rf, src_line_buf
            call    put_row             ; number + line, cut to the width

            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            rtn

;------------------------------------------------------------------
; scroll_down_and_print_top: scrolls the WHOLE terminal down by one
; line via RI (ESC M, "Reverse Index") -- IND's own upward
; counterpart, same reasoning as scroll_up_and_print_bottom's own
; header comment. RI only scrolls when the cursor is ALREADY at the
; top margin (row 1, with no scroll region set), so this positions
; there first. Leaves the cursor at row 1 (now blank) -- both rows
; still need reprinting, same as before: the new top content line at
; row 1, then the status line at row less_page_lines+1 (RI pushes
; whatever WAS at the real last row off the bottom entirely).
;------------------------------------------------------------------
scroll_down_and_print_top:
            call    K_INMSG
            db      27,'[H',0           ; the true top margin
            call    K_INMSG
            db      27,'M',0            ; RI -- scrolls down by 1;
                                        ; cursor stays at row 1
            call    K_INMSG
            db      27,'[K',0           ; clear the WHOLE row FIRST --
                                        ; see the header above
            mov     rf, src_line_buf
            call    put_row             ; number + line, cut to the width

            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            rtn

;------------------------------------------------------------------
; cmd_line_down: move the view down by exactly one line (down-arrow,
; j/J, Ctrl-N, Ctrl-E). Seek-free -- src_pos already sits exactly at
; the next line to reveal, since it's only ever changed by reading
; sequentially forward or by an explicit seek that keeps it in sync.
;------------------------------------------------------------------
cmd_line_down:
            mov     rf, less_at_eof
            ldn     rf
            lbnz    main_loop           ; already at EOF: ignore

            ; -N + wrap: the number bookkeeping across a wrapped scroll is
            ; too fiddly to track incrementally, so just redraw the page one
            ; row down (new top = less_visible[1]). less_goto recomputes the
            ; top's number from the source. Only this uncommon combination
            ; pays the redraw; every other mode keeps the fast IND scroll.
            mov     rf, less_numbers
            ldn     rf
            lbz     cld_incr
            mov     rf, less_nowrap
            ldn     rf
            lbnz    cld_incr            ; nowrap -N: incremental is exact
            mov     rf, less_visible
            inc     rf
            inc     rf
            inc     rf
            inc     rf                  ; -> &less_visible[1]
            mov     rd, less_top
            call    copy4bytes          ; less_top = the second visible row
            call    less_goto
            lbr     main_loop

cld_incr:
            mov     rf, src_pos
            mov     rd, less_new_line
            call    copy4bytes          ; less_new_line = current src_pos
                                        ; (where the new bottom row starts)

            call    src_read_line      ; into src_line_buf; advances src_pos
            lbdf    cld_eof

            call    less_shift_visible_left
            mov     rf, less_next_line  ; the new bottom row's number
            mov     rd, less_row_line
            call    copy4bytes
            call    scroll_up_and_print_bottom
            ; less_next_line = this row's number + 1 unless it wrapped (put_row
            ; no longer advances less_row_line itself)
            mov     rf, less_row_line
            mov     rd, less_next_line
            call    copy4bytes
            mov     rf, src_row_wrapped
            ldn     rf
            lbnz    cld_done
            mov     rf, less_next_line
            ldi     1
            call    addbyte32
cld_done:
            lbr     main_loop

cld_eof:
            mov     rf, less_at_eof
            ldi     1
            str     rf
            lbr     main_loop

;------------------------------------------------------------------
; cmd_hscroll_right / cmd_hscroll_left: -S horizontal scroll (Right/Left
; arrows). Shift the view sideways by half the screen width, like real
; less -S, then redraw the current page (less_top is unchanged, so
; less_goto just re-renders it at the new offset). Ignored in wrap mode,
; where there is nothing off to the right.
;------------------------------------------------------------------
cmd_hscroll_right:
            mov     rf, less_nowrap
            ldn     rf
            lbz     main_loop           ; wrap mode: no sideways scroll
            call    hscroll_amount      ; R9.0 = half the width (>= 1)
            mov     r8, less_hshift     ; less_hshift += R9.0 (16-bit BE)
            inc     r8
            glo     r9
            str     r2
            ldn     r8
            add
            str     r8
            dec     r8
            ldi     0
            str     r2
            ldn     r8
            adc
            str     r8
            call    less_goto
            lbr     main_loop

cmd_hscroll_left:
            mov     rf, less_nowrap
            ldn     rf
            lbz     main_loop
            call    hscroll_amount
            mov     r8, less_hshift     ; less_hshift -= R9.0; clamp at 0
            inc     r8
            glo     r9
            str     r2
            ldn     r8
            sm
            str     r8
            dec     r8
            ldi     0
            str     r2
            ldn     r8
            smb
            str     r8
            lbdf    chl_redraw          ; no borrow: still >= 0
            mov     rf, less_hshift
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; underflow: clamp to 0
chl_redraw:
            call    less_goto
            lbr     main_loop

;------------------------------------------------------------------
; hscroll_amount: R9.0 = half the screen width, at least 1.
;------------------------------------------------------------------
hscroll_amount:
            mov     rf, less_width
            ldn     rf
            shr                         ; width / 2
            lbnz    ha_have
            ldi     1
ha_have:
            plo     r9
            rtn

;------------------------------------------------------------------
; cmd_line_up: move the view up by exactly one line (up-arrow, k/K,
; Ctrl-P, Ctrl-Y). If less_stack has a recorded entry, use it (no
; scan needed -- this is the common case, since ordinary forward
; browsing always records history). If the stack is EMPTY (e.g. right
; after 'g'/'G'/a search match, all of which clear less_stack rather
; than push -- see cmd_goto_end's own header comment for why), fall
; back to a genuine backward scan (src_prev_start) instead
; of just giving up: an earlier version treated "no history" as
; "nothing to do", which made up-arrow immediately after 'G' silently
; do nothing at all (or, when the stack instead held a stale pre-jump
; entry, jump much further back than one line) -- confusing, per the
; user's own direct feedback, since real `less` always finds the
; previous line regardless of how it got there.
; Needs one seek either way -- to whatever the stack or the scan
; produces -- since that's not generally wherever the FCB happens to
; be positioned.
;
; src_pos MUST come out of this routine still meaning exactly what
; every other caller assumes it means: "one past the CURRENT bottom-
; most visible line" -- cmd_forward and cmd_line_down both just read
; sequentially from wherever the chunk buffer/FCB already sit, trusting
; src_pos (and the real underlying read position, which the two must
; always agree on) to already be correct. less_top's own read via
; src_read_line below only ever fetches the NEW TOP line's text for
; display -- as a side effect it leaves src_pos/the FCB sitting one
; line PAST that (i.e. at the window's SECOND entry), which is NOT the
; window's true bottom whenever the window holds more than 2 entries.
; src_pos is therefore explicitly reseeked back afterward in BOTH
; outcomes below, to whichever value genuinely represents the (possibly
; unchanged) bottom -- less_saved_pos (GROWING: the bottom didn't move)
; or less_dropped (FULL: the bottom moved to what fell off the end).
; A real hardware-reported bug (2026-09-02) traced to exactly this:
; skipping the reseek in the GROWING case left src_pos advancing by
; only one line per up-arrow instead of tracking the true bottom, so a
; later down-arrow (pressed before the window ever re-filled the
; screen) would re-read and re-display a line ALREADY visible near the
; top of the window -- a duplicated "phantom" line, not the genuinely
; next unseen content.
;------------------------------------------------------------------
cmd_line_up:
            ; snapshot src_pos before anything below can touch it --
            ; this is the value to restore in the GROWING case, since
            ; the window's bottom (and so the correct forward-resume
            ; position) doesn't move when only the top grows.
            mov     rf, src_pos
            mov     rd, less_saved_pos
            call    copy4bytes

            call    less_pop_top
            lbnf    clu_have_top        ; DF=0: got a real entry

            ; stack empty -- can we scan backward? Only if less_top
            ; isn't already 0 (the true start of the file, nothing
            ; before it at all).
            mov     rf, less_top
            ldn     rf
            lbnz    clu_can_scan
            inc     rf
            ldn     rf
            lbnz    clu_can_scan
            inc     rf
            ldn     rf
            lbnz    clu_can_scan
            inc     rf
            ldn     rf
            lbnz    clu_can_scan
            lbr     main_loop           ; all 4 bytes are 0: ignore

clu_can_scan:
            mov     rf, less_top
            call    src_prev_start
            mov     rf, src_prev_result
            mov     rd, less_top
            call    copy4bytes

clu_have_top:
            ; -N + wrap: redraw one row up (less_goto recomputes the number)
            ; rather than tracking it incrementally across a wrapped scroll.
            ; See cmd_line_down's own comment; only this combination pays it.
            mov     rf, less_numbers
            ldn     rf
            lbz     clu_incr
            mov     rf, less_nowrap
            ldn     rf
            lbnz    clu_incr
            call    less_goto
            lbr     main_loop

clu_incr:
            ; less_top now holds the new top row's offset. Its number
            ; comes from the source (the stack keeps positions only) --
            ; asked BEFORE the seek below, since the source leaves its
            ; read position unspecified.
            call    less_sync_top_line
            mov     rf, less_top_line
            mov     rd, less_row_line
            call    copy4bytes

            mov     rf, less_top
            call    src_seek_to

            mov     rf, less_top
            mov     rd, less_new_line
            call    copy4bytes

            call    src_read_line      ; content for display only --
                                        ; its side effect on src_pos/
                                        ; the chunk buffer is irrelevant
                                        ; and gets fully overwritten
                                        ; below either way, see this
                                        ; routine's own header comment

            call    less_shift_visible_right
            lbdf    clu_restore_saved  ; DF=1: window just grew -- the
                                        ; bottom hasn't moved, restore
                                        ; the value saved at entry

            ; DF=0: the dropped line is no longer in view. A read from
            ; it gives the number the bottom row had, one less than
            ; less_next_line said.
            mov     rf, less_next_line
            ldi     1
            call    subbyte32

            ; the dropped line is no longer in view -- resume
            ; future forward reads from exactly where it starts. Both
            ; the FCB/chunk-buffer state AND the src_pos variable need
            ; re-syncing here -- setting the variable alone would leave
            ; the ACTUAL read position stuck one line past the window's
            ; second entry, silently disagreeing with what src_pos
            ; claims (the same class of bug this fix exists for).
            mov     rf, less_dropped
            call    src_seek_to         ; also sets src_pos
            lbr     clu_display

clu_restore_saved:
            mov     rf, less_saved_pos
            call    src_seek_to         ; also sets src_pos

clu_display:
            mov     rf, less_at_eof
            ldi     0
            str     rf                  ; moved away from the tail

            call    scroll_down_and_print_top
            lbr     main_loop

;------------------------------------------------------------------
; parse_escapes: rewrite less_search_buf in place, turning C-style
; escapes into the bytes they name, and set less_search_len to the
; resulting COUNT. Output is always shorter than input (every escape
; collapses 2+ characters into 1), so rewriting in place is safe --
; the same read-cursor/write-cursor convention progs/shell.asm's own
; tokenizer uses.
;
; Recognized: \\  \n  \r  \t  \0  \xHH  (exactly two hex digits).
; Anything else after a backslash -- including end-of-string -- is an
; error rather than a literal, so a typo is reported instead of being
; silently searched for.
;
; A counted result is the whole point: the pattern can then contain
; ANY byte, $00 included, which a NUL-terminated one never could.
;
; Makes no calls except to its own leaf helper below, so RF/RD/R9 stay
; safely register-resident throughout.
; Args:    (none -- operates on less_search_buf)
; Returns: DF=0 ok, less_search_len set;  DF=1 malformed escape
;------------------------------------------------------------------
parse_escapes:
            mov     rf, less_search_buf ; read cursor
            mov     rd, less_search_buf ; write cursor
            ldi     0
            plo     r9                  ; R9.0 = count

pe_loop:
            ldn     rf
            lbz     pe_done
            xri     92                  ; backslash?
            lbz     pe_escape

            ldn     rf                  ; ordinary byte: copy it
            str     rd
            inc     rf
            inc     rd
            glo     r9
            adi     1
            plo     r9
            lbr     pe_loop

pe_escape:
            inc     rf                  ; step over the backslash
            ldn     rf
            lbz     pe_error            ; trailing backslash

            xri     'n'
            lbz     pe_lf
            ldn     rf
            xri     'r'
            lbz     pe_cr
            ldn     rf
            xri     't'
            lbz     pe_tab
            ldn     rf
            xri     '0'
            lbz     pe_nul
            ldn     rf
            xri     92
            lbz     pe_backslash
            ldn     rf
            xri     'x'
            lbz     pe_hex
            lbr     pe_error

pe_lf:      ldi     10
            lbr     pe_emit
pe_cr:      ldi     13
            lbr     pe_emit
pe_tab:     ldi     9
            lbr     pe_emit
pe_nul:     ldi     0
            lbr     pe_emit
pe_backslash:
            ldi     92
            lbr     pe_emit

pe_hex:
            inc     rf                  ; first hex digit
            ldn     rf
            call    pe_hexval
            lbdf    pe_error
            shl
            shl
            shl
            shl
            plo     r8                  ; high nibble, in place

            inc     rf                  ; second hex digit
            ldn     rf
            call    pe_hexval
            lbdf    pe_error
            str     r2
            glo     r8
            or                          ; D = (hi << 4) | lo
            lbr     pe_emit

pe_emit:
            str     rd
            inc     rf                  ; step over the escape's last char
            inc     rd
            glo     r9
            adi     1
            plo     r9
            lbr     pe_loop

pe_done:
            mov     rf, less_search_len
            glo     r9
            str     rf
            clc
            rtn

pe_error:
            stc
            rtn

;------------------------------------------------------------------
; pe_hexval: D = an ASCII character -> DF=0 with D = its hex value,
; or DF=1 if it is not a hex digit. Touches only D/DF and R8.1, so
; parse_escapes' own RF/RD/R9 survive the call untouched.
;------------------------------------------------------------------
pe_hexval:
            phi     r8                  ; keep the character
            smi     '0'
            lbnf    pe_hv_bad           ; below '0'
            smi     10                  ; ('0'..'9') -> < 0 here
            lbnf    pe_hv_dec

            ghi     r8
            ani     $DF                 ; fold a..f up to A..F (only
                                        ; letters reach here, so this
                                        ; is the same safe fold the
                                        ; shell's drive-letter check uses)
            smi     'A'
            lbnf    pe_hv_bad           ; between '9' and 'A'
            str     r2
            ldi     6
            sm                          ; 6 - (c - 'A')
            lbnf    pe_hv_bad           ; 'F' is the last valid one
            ldn     r2
            adi     10                  ; 'A' -> 10
            clc
            rtn

pe_hv_dec:
            ghi     r8
            smi     '0'
            clc
            rtn

pe_hv_bad:
            stc
            rtn

;------------------------------------------------------------------
; less_push_offset: pushes the 4-byte value at [RF] onto less_stack
; (silently dropped, not an error, if the stack is already at
; LESS_STACK_MAX -- see this file's own header comment).
; Args:    RF = pointer to a 4-byte value (fully consumed -- callers
;          must not rely on its value surviving this call)
;------------------------------------------------------------------
less_push_offset:
            mov     rb, less_stack_count
            ldn     rb
            smi     LESS_STACK_MAX
            lbdf    lpo_done            ; count >= MAX: full, skip

            mov     rb, less_stack_count
            ldn     rb
            plo     r9
            ldi     0
            phi     r9                  ; R9 = count (zero-extended)
            shl16   r9                  ; R9 = count*2
            shl16   r9                  ; R9 = count*4
            mov     r8, less_stack
            add16   r8, r9              ; R8 = &less_stack[count*4]

            call    copy4bytes_to_r8    ; copies [RF] (4 bytes) to [R8]

            mov     rb, less_stack_count
            ldn     rb
            adi     1
            str     rb

lpo_done:
            rtn

;------------------------------------------------------------------
; less_push_visible_all: pushes less_visible[0..less_visible_count-1]
; onto less_stack, in order (index 0 first, so it ends up deepest/
; oldest -- the same LIFO convention every other push already uses).
; Called at every SEQUENTIAL full-page transition (cmd_forward), so a
; line-up move afterward can walk back through EVERY line of the page
; being left, not just its first. Deliberately NOT called by any "big
; jump" (cmd_top/cmd_goto_end/lsf_found) -- those clear less_stack
; instead, since the page they're leaving isn't necessarily adjacent
; to where the jump lands (see cmd_goto_end's own header for the bug
; this caused when it used to push here too). The source address is
; recomputed fresh from memory each iteration (via less_push_i),
; rather than trusted in a register across the call to
; less_push_offset.
;------------------------------------------------------------------
less_push_visible_all:
            mov     rf, less_push_i
            ldi     0
            str     rf                  ; less_push_i = 0

lpva_loop:
            mov     rb, less_visible_count
            ldn     rb
            str     r2
            mov     rf, less_push_i
            ldn     rf
            sm                          ; D = push_i - count, DF=1 iff
                                        ; push_i >= count
            lbdf    lpva_done

            mov     rf, less_push_i
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9                  ; R9 = push_i*4
            mov     rf, less_visible
            add16   rf, r9              ; RF = &less_visible[push_i*4]

            call    less_push_offset

            mov     rf, less_push_i
            ldn     rf
            adi     1
            str     rf
            lbr     lpva_loop

lpva_done:
            rtn

;------------------------------------------------------------------
; less_pop_top: pops the most recently pushed offset into less_top.
; Returns: DF=0 on success, DF=1 if the stack was already empty
; (less_top left unchanged in that case).
;------------------------------------------------------------------
less_pop_top:
            mov     rf, less_stack_count
            ldn     rf
            lbz     lpop_empty

            smi     1                   ; D = new count (count-1)
            str     rf                  ; write the decremented count
                                        ; back (D unmodified by str)

            plo     r9
            ldi     0
            phi     r9                  ; R9 = new count (the slot to pop)
            shl16   r9
            shl16   r9
            mov     r8, less_stack
            add16   r8, r9              ; R8 = &less_stack[newcount*4]

            mov     rf, less_top
            lda     r8
            str     rf
            inc     rf
            lda     r8
            str     rf
            inc     rf
            lda     r8
            str     rf
            inc     rf
            ldn     r8
            str     rf

            clc
            rtn

lpop_empty:
            stc
            rtn

;------------------------------------------------------------------
; less_shift_visible_left: shifts less_visible[] left by one entry --
; drops entry 0 (pushed onto less_stack first, for a later line-up to
; retrieve), shifts [1..count-1] down to [0..count-2] (a forward copy,
; safe with no self-overwrite risk since dest < source), and appends
; less_new_line (4 bytes, set by the caller beforehand) as the new
; last entry. Only ever called when NOT at EOF, which -- per draw_page's
; own invariant -- guarantees less_visible_count == less_page_lines, so
; there's no partial-window case to handle here (unlike the right-shift
; below, which does need one). Updates less_top = the new entry 0 (what
; was entry 1 before the shift).
; Verified via an independent Python mechanical simulation (2026-09-01)
; before being trusted, including a full push-then-pop round-trip
; against less_shift_visible_right confirming the window is restored
; exactly.
;------------------------------------------------------------------
less_shift_visible_left:
            mov     rf, less_visible
            call    less_push_offset    ; push the entry about to drop
            lbr     less_shift_left_core  ; tail-jump: less_shift_left_core
                                        ; ends in rtn, which correctly
                                        ; returns to WHOEVER called
                                        ; less_shift_visible_left, since
                                        ; lbr (unlike call) never
                                        ; touches the return-address
                                        ; stack itself

;------------------------------------------------------------------
; less_shift_left_core: the shift-down-and-insert half of
; less_shift_visible_left, WITHOUT the push -- factored out
; specifically for cmd_goto_end's own bulk forward scan, which needs
; to shift the window on every line read but must NOT push each one
; onto less_stack (that would either blow through LESS_STACK_MAX on
; any reasonably-sized file, or -- worse -- silently bury real history
; under thousands of scanned-through lines near the end of the file).
; cmd_goto_end clears less_stack once, up front (see its own header --
; a search match or 'g' does the same, all being "big jumps"), then
; calls this directly for every line it scans past.
;------------------------------------------------------------------
less_shift_left_core:
            mov     rf, less_visible_count
            ldn     rf
            smi     1
            lbz     lsvl_insert         ; D==0 (count==1): nothing to
                                        ; shift -- MUST check for zero
                                        ; here, not DF/borrow (count==1
                                        ; never borrows against smi 1,
                                        ; so an earlier lbnf-based check
                                        ; wrongly fell through and ran
                                        ; the loop body once anyway,
                                        ; reading out-of-bounds memory
                                        ; at less_visible+4 -- caught by
                                        ; re-tracing this exact case,
                                        ; not by any assembler/sweep)
            plo     r9                  ; R9.0 = count-1 (entries to move)
            ldi     0
            phi     r9

            mov     r7, less_visible
            add16   r7, 4               ; R7 = source, starts at entry 1
            mov     r8, less_visible    ; R8 = dest, starts at entry 0

lsvl_loop:
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8

            dec     r9
            glo     r9
            lbnz    lsvl_loop           ; R9 <= 39, so its high byte
                                        ; never comes into play here

lsvl_insert:
            ; append less_new_line at less_visible[count-1] -- the
            ; CURRENT (unchanged) count, since this routine never
            ; changes less_visible_count
            mov     rf, less_visible_count
            ldn     rf
            smi     1
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9
            mov     r8, less_visible
            add16   r8, r9

            mov     rf, less_new_line
            call    copy4bytes_to_r8

            ; less_top = the new entry 0
            mov     rf, less_visible
            mov     rd, less_top
            call    copy4bytes
            rtn

;------------------------------------------------------------------
; less_shift_visible_right: shifts less_visible[] right by one entry
; and inserts less_new_line (set by the caller) at entry 0. Two
; genuinely different cases, not one -- confirmed by tracing a
; scroll-up-from-a-short-final-page scenario, then independently
; verified in Python before writing this (2026-09-01):
;
;   - GROWING (less_visible_count < less_page_lines, e.g. line-up from
;     a short/partial final page): every existing entry [0..count-1]
;     shifts up to [1..count], NOTHING is dropped (there was room),
;     and count simply grows by 1. Returns DF=1 -- the window's bottom
;     hasn't moved, so the caller must restore src_pos to whatever it
;     was BEFORE this call (its own incidental value right after this
;     routine returns is the offset of the window's NEW second entry,
;     not its bottom -- NOT safe to leave as-is; see cmd_line_up's own
;     header comment for the real hardware bug this caused when an
;     earlier version got this wrong).
;   - FULL (count == page_lines, the ordinary case): less_visible
;     [count-1] is captured into less_dropped first (the caller uses
;     it to "un-consume" that line back into src_pos, since it's no
;     longer in view), then [0..count-2] shifts up to [1..count-1],
;     dropping the old last entry; count is unchanged (already at
;     cap). Returns DF=0 -- less_dropped is valid.
;
; An earlier version of this routine always took the FULL path
; unconditionally -- silently discarding a still-visible line instead
; of shifting it whenever the window was still growing (e.g. every
; time except after the very first successful up-arrow), a real
; correctness bug caught only by re-tracing the growing case by hand,
; not by any assembler/sweep check.
;
; Both cases share the same backward-copy shift helper (lsvr_do_shift,
; below) -- a BACKWARD copy, highest index first, is required for a
; right-shift regardless of which case: dest is always 4 bytes above
; source, so a forward copy would clobber source data still needed by
; a later iteration (same class of overlap this project's own
; LINE_BUF-relocation precedent already established).
;------------------------------------------------------------------
less_shift_visible_right:
            mov     rb, less_page_lines
            ldn     rb
            str     r2
            mov     rf, less_visible_count
            ldn     rf
            sm                          ; D = count - page_lines, DF=1
                                        ; iff count >= page_lines (full)
            lbdf    lsvr_full

;-- GROWING: count < page_lines -----------------------------------
            mov     rf, less_visible_count
            ldn     rf
            lbz     lsvr_grow_no_shift  ; count==0: nothing existing
                                        ; to shift at all
            smi     1                   ; D = count-1 = highest
                                        ; existing index to move
            plo     r9
            ldi     0
            phi     r9
            call    lsvr_do_shift

lsvr_grow_no_shift:
            mov     rf, less_new_line
            mov     rd, less_visible
            call    copy4bytes
            mov     rf, less_new_line
            mov     rd, less_top
            call    copy4bytes

            mov     rf, less_visible_count
            ldn     rf
            adi     1
            str     rf

            stc                         ; DF=1: nothing dropped
            rtn

;-- FULL: count == page_lines --------------------------------------
lsvr_full:
            ; less_dropped = less_visible[count-1]
            mov     rf, less_visible_count
            ldn     rf
            smi     1
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9
            mov     r8, less_visible
            add16   r8, r9              ; R8 = &less_visible[count-1]

            mov     rf, r8
            mov     rd, less_dropped
            call    copy4bytes

            mov     rf, less_visible_count
            ldn     rf
            smi     2
            lbnf    lsvr_full_insert    ; count < 2 (i.e. page_lines==1
                                        ; and count==1): the one entry
                                        ; IS the drop -- nothing left
                                        ; to shift

            ; D still holds count-2 here -- the highest SOURCE index
            ; to move
            plo     r9
            ldi     0
            phi     r9
            call    lsvr_do_shift

lsvr_full_insert:
            mov     rf, less_new_line
            mov     rd, less_visible
            call    copy4bytes
            mov     rf, less_new_line
            mov     rd, less_top
            call    copy4bytes
                                        ; count unchanged -- already at cap
            clc                         ; DF=0: less_dropped is valid
            rtn

;------------------------------------------------------------------
; lsvr_do_shift: shifts less_visible[] right by one, moving every
; index from R9 down to 0 (inclusive) to index+1 -- a backward copy,
; highest index first (required; see less_shift_visible_right's own
; header). Args: R9 = highest source index to move (>= 0).
;------------------------------------------------------------------
lsvr_do_shift:
            mov     r7, r9
            shl16   r7
            shl16   r7                  ; R7 = i*4
            mov     r8, less_visible
            add16   r8, r7              ; R8 = &less_visible[i] (source)
            mov     rc, r8
            add16   rc, 4               ; RC = &less_visible[i+1] (dest)

            lda     r8
            str     rc
            inc     rc
            lda     r8
            str     rc
            inc     rc
            lda     r8
            str     rc
            inc     rc
            ldn     r8
            str     rc

            glo     r9
            lbz     lsvr_do_shift_ret   ; just processed i=0 -- stop
                                        ; (post-test: avoids ever
                                        ; needing to represent i=-1)
            dec     r9
            lbr     lsvr_do_shift

lsvr_do_shift_ret:
            rtn
            endp

            proc    _pager_data
less_top:               ds      4       ; start of the displayed page
less_candidate_top:     ds      4       ; scratch, used during search

less_search_buf:        ds      LESS_SEARCH_MAX
less_search_len:        db      0       ; parsed pattern length in BYTES
less_count:             ds      4       ; prefix argument being typed
less_count_x2:          ds      4       ; scratch for the *10 step
less_count_buf:         ds      COUNT_MAX_DIGITS+1
less_count_len:         db      0       ; digits typed so far (0 = none)
less_count_pending:     db      0       ; count handed to THIS command
less_search_start:      ds      4       ; scan-start scratch, set fresh by
                                        ; the caller each search
less_search_resume:     ds      4       ; where 'n' resumes

less_stack:             ds      LESS_STACK_MAX*4
less_stack_count:       db      0
less_back_i:            db      0       ; cmd_back's own loop counter
less_push_i:            db      0       ; less_push_visible_all's counter

less_visible:           ds      LESS_MAX_VISIBLE*4  ; sliding window of the
                                        ; currently-displayed lines' own
                                        ; start offsets
less_visible_count:     db      0       ; how many of the above are valid

less_new_line:          ds      4       ; value to insert/append, set by the
                                        ; caller before either shift routine
less_dropped:           ds      4       ; what a right-shift (line-up) drops
less_saved_pos:         ds      4       ; src_pos, snapshotted by cmd_line_up
less_page_end:          ds      4       ; draw_page's snapshot of the correct
                                        ; src_pos for the CURRENT page

less_page_lines:        db      LESS_PAGE_LINES
less_lines_this_page:   db      0
less_at_eof:            db      0
less_status_mode:       db      0
less_key:               db      0
less_rows_name:         db      "ROWS",0
less_esc_buf:           ds      10
less_title:             dw      0       ; pager_run's RF: the program name
less_cols_name:         db      "COLUMNS",0
less_width:             db      LESS_WIDTH_DEFAULT ; widest line (COLUMNS-1)
less_col:               db      0       ; put_line's current display column
less_status_room:       db      0       ; what is left of it, while printing
less_numbers:           db      0       ; -N: number the lines
less_nowrap:            db      0       ; -S: truncate + horizontal scroll
less_hshift:            dw      0       ; -S horizontal scroll offset (columns)
less_top_line:          ds      4       ; less_top's line number
less_next_line:         ds      4       ; the number a read from src_pos
                                        ; (the row after the bottom) gets
less_row_line:          ds      4       ; the number put_row prints next
less_row_text:          dw      0       ; put_row's line, across K_MSG
less_room:              db      0       ; columns left for put_line
less_num_digits:        ds      11      ; fmt_uint32's digits
less_num_buf:           ds      12      ; padded number + space, printed
                public  less_top
                public  less_candidate_top
                public  less_search_buf
                public  less_search_start
                public  less_search_resume
                public  less_stack
                public  less_stack_count
                public  less_back_i
                public  less_push_i
                public  less_visible
                public  less_visible_count
                public  less_new_line
                public  less_dropped
                public  less_saved_pos
                public  less_page_end
                public  less_page_lines
                public  less_lines_this_page
                public  less_at_eof
                public  less_status_mode
                public  less_key
                public  less_rows_name
                public  less_esc_buf
                public  less_search_len
                public  less_count
                public  less_count_x2
                public  less_count_buf
                public  less_count_len
                public  less_count_pending
                public  less_title
                public  less_cols_name
                public  less_width
                public  less_col
                public  less_status_room
                public  less_numbers
                public  less_nowrap
                public  less_hshift
                public  less_top_line
                public  less_next_line
                public  less_row_line
                public  less_row_text
                public  less_room
                public  less_num_digits
                public  less_num_buf
            endp
