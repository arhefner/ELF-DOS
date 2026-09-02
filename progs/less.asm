;
; less.asm - page through a file's contents with bi-directional
; scrolling and basic forward search (a scaled-down "less").
;
; Usage: LESS <filename>
;
; Deliberately scoped for a memory-tight (32K RAM) system and no
; emulator to test against, so every design choice below favors
; simplicity/robustness over completeness:
;
;   - Page moves (SPACE/F forward, B back) do a full screen clear and
;     redraw. Single-LINE moves (arrow keys, j/k, Ctrl-N/P/E/Y) instead
;     scroll the WHOLE terminal by one line via the plain two-character
;     VT100 sequences IND (ESC D, scroll up) and RI (ESC M, scroll
;     down) -- deliberately not CSI-based SU/ESC[1S / SD/ESC[1T (an
;     ECMA-48/ANSI X3.64 addition, not part of the original VT100 set)
;     and deliberately not wrapped in a DECSTBM scroll region either.
;     Two real hardware rounds (2026-09-01) got here in stages: a
;     DECSTBM region sized from a CLAMPED less_page_lines (40) rather
;     than the real terminal height (50, per the user's own ROWS
;     setting) left the bottom 10 rows permanently unreachable by
;     ordinary scrolling from that point on -- including everything
;     printed by any LATER command, since the region was also never
;     reset on exit -- so DECSTBM was dropped entirely in favor of
;     plain whole-terminal SU/SD; a SECOND round then found SU/SD
;     simply had no visible effect on the actual terminal in use (the
;     two rows this routine repositions/reprints updated correctly,
;     but nothing else on screen shifted), pointing at IND/RI -- the
;     older, more universally-supported equivalent -- instead. IND/RI
;     only scroll when the cursor is ALREADY at the relevant margin
;     (with no scroll region set, that's the terminal's own real top/
;     bottom row), so each is preceded by an explicit reposition
;     there. BOTH the status line's row and the new content row still
;     need reprinting after every scroll regardless of which mechanism
;     triggers it -- an unscoped scroll drags the status line's own
;     text along with everything else (see scroll_up_and_print_bottom/
;     scroll_down_and_print_top's own header comments for exactly
;     which two rows and why an unscoped scroll disturbs each of them
;     differently depending on direction).
;
;     Both move types are built on ONE mechanism: less_visible[] is a sliding
;     window holding the START OFFSET of every currently-displayed
;     line (not just the first), and less_stack is a history of lines
;     that have scrolled off the TOP of that window over time. Every
;     forward step -- whether part of a full page redraw or a single
;     line-down move -- pushes the line being dropped off the top onto
;     less_stack before overwriting it; every backward step pops it.
;     'b' pops up to less_page_lines entries (landing wherever a full
;     page back would be, or as close as the recorded history allows);
;     a single line-up move pops exactly one. This is what makes "back"
;     possible at all without any backward byte-scanning through the
;     file. Forward PAGE moves still need NO seek (the file is read
;     strictly sequentially for that case) -- this is the main "as
;     fast as possible" lever, since paging through a big file forward
;     is by far the most common action. A single line-down move is
;     also seek-free (it just reads the very next line from wherever
;     less_pos already is); a single line-up move needs exactly one
;     seek (to the line popped off the history), same as 'b'/'g'/a
;     search match.
;   - less_stack is bounded (LESS_STACK_MAX entries); once full,
;     further forward moves are simply not push-able and can't be
;     undone past that point -- a documented, accepted limit rather
;     than an unbounded structure, generous enough for ordinary use.
;   - Search ('/') is a literal, case-sensitive substring match, no
;     regex -- same scope as EDLIN's own 'S' command. It only ever
;     scans FORWARD from the current view. 'n' repeats the last
;     pattern. There is no backward search.
;   - No PgUp/PgDn, no Home/End goto-line-N, no multiple files, no
;     wildcard expansion -- SPACE/F/B/G/-/N/Q plus the line-move keys
;     above are the whole command set.
;   - A hard K_FILE_READ or K_FILE_SEEK failure partway through the
;     file is deliberately NOT distinguished from ordinary EOF/an
;     already-validated seek target -- both just mean "nothing more to
;     show here". A genuine mid-file disk fault is exceedingly rare
;     and this avoids threading a third error state through every
;     layer of the read/seek plumbing; the one exception is the very
;     first K_FILE_OPEN, whose failure is reported normally.
;
; Since a text line's real start offset can only be known by actually
; reading up to it, back/forward navigation works by remembering PAGE
; TOP byte offsets, not line counts -- less_pos (the running "next byte
; to read" position) and less_top (the offset the CURRENTLY DISPLAYED
; page starts at) are both plain 4-byte big-endian counters (this
; kernel's file API is fully 32-bit -- see K_FILE_SEEK's own doc in
; kernel_api.inc), incremented/copied via copy4bytes/less_pos_add16
; below rather than trusted to fit in a register pair.
;
; File content is read through a small chunk buffer (less_chunk_buf,
; refilled via K_FILE_READ as needed) and split into lines by scanning
; for LF ($0A) only -- same "CR is just an ordinary byte, never
; stripped" convention as TYPE/MORE (a CRLF file prints a harmless
; extra CR before this program's own trailing CR+LF, invisible on a
; real terminal). A line longer than LESS_LINE_MAX-1 characters is
; still fully consumed (so byte-offset tracking stays correct) but
; only its first LESS_LINE_MAX-1 characters are kept/displayed.
;
; Nothing is ever trusted in a register across a kernel/BIOS call
; whose clobber footprint isn't independently confirmed (this
; project's own K_TYPE/K_MSG/K_INMSG/K_READ/K_FILE_READ/K_FILE_SEEK
; history, CLAUDE.md gotchas #4/#8/#10) -- every routine below reloads
; whatever it needs fresh from memory immediately before use rather
; than carrying it in a register through a call.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

            extrn   env_getenv
            extrn   env_parse_uint
            extrn   read_line_ex

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
LESS_LINE_MAX:   equ    128         ; longest displayed line (incl NUL)
LESS_SEARCH_MAX: equ    32          ; longest search pattern (incl NUL)
LESS_PAGE_LINES: equ    23          ; default screen height - 1
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
LESS_STACK_MAX:  equ    250         ; line-history stack depth (must stay
                                    ; <= 255 -- less_stack_count is a byte)
LESS_BACKSCAN_LEN: equ  128         ; look-back window for
                                    ; less_find_prev_line_start's bounded
                                    ; backward scan (see its own header)

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[1] is the filename.
            glo     rc
            smi     2
            lbnf    usage

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (filename)
            mov     rd, less_fcb
            mov     ra, less_iobuf
            ldi     0                   ; mode = read
            call    K_FILE_OPEN
            lbdf    not_found

            ; --- init state ---
            mov     rf, less_top
            call    zero4bytes
            mov     rf, less_pos
            call    zero4bytes

            mov     rf, less_chunk_remaining
            ldi     0
            str     rf
            mov     rf, less_stack_count
            ldi     0
            str     rf
            mov     rf, less_status_mode
            ldi     0
            str     rf
            mov     rf, less_search_buf
            ldi     0
            str     rf                  ; empty pattern -- 'n' is a
                                        ; no-op until a real search runs
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
            ; is sequential, so less_pos already sits exactly at the
            ; start of the next page with no seek needed.
            mov     rf, less_pos
            mov     rd, less_top
            call    copy4bytes

            call    draw_page
            lbr     main_loop

;------------------------------------------------------------------
; cmd_back: pops up to less_page_lines entries from less_stack, one at
; a time. If the stack runs dry before that (or was already empty),
; falls back to a real backward scan (less_find_prev_line_start) for
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
            call    less_find_prev_line_start
            mov     rf, less_new_line
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
; (less_find_prev_line_start) -- landing on some unrelated old line
; instead of the true adjacent one. Clearing the stack means every
; 'b'/up-arrow after 'G' goes through the scan fallback from the very
; first press, which is slower (a real backward disk scan each time)
; but always lands on the correct, adjacent line -- exactly what was
; asked for over the old "confusing tradeoff".
;------------------------------------------------------------------
cmd_goto_end:
            mov     rf, less_stack_count
            ldi     0
            str     rf

            mov     rf, less_candidate_top  ; reused as scratch: a
                                        ; known 4-byte zero to seek to
            call    zero4bytes
            mov     rf, less_candidate_top
            call    less_seek_to
            mov     rf, less_candidate_top
            mov     rd, less_pos
            call    copy4bytes

            mov     rf, less_visible_count
            ldi     0
            str     rf

cge_scan_loop:
            mov     rf, less_pos
            mov     rd, less_new_line
            call    copy4bytes          ; candidate = start of the
                                        ; line about to be read

            call    read_line_here
            lbdf    cge_scan_done       ; true EOF -- scan complete

            mov     rb, less_page_lines
            ldn     rb
            str     r2
            mov     rf, less_visible_count
            ldn     rf
            sm                          ; D = count - page_lines, DF=1
                                        ; iff count >= page_lines (full)
            lbdf    cge_shift

            ; GROWING: window still has room -- append at [count],
            ; count++, nothing to drop or shift
            mov     rf, less_visible_count
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9
            mov     r8, less_visible
            add16   r8, r9
            mov     rf, less_new_line
            call    copy4bytes_to_r8

            mov     rf, less_visible_count
            ldn     rf
            adi     1
            str     rf
            lbr     cge_scan_loop

cge_shift:
            call    less_shift_left_core  ; drops [0] (no stack push),
                                        ; shifts down, appends
                                        ; less_new_line
            lbr     cge_scan_loop

cge_scan_done:
            ; less_visible[] now holds exactly the last
            ; min(page_lines, total lines in the file) lines --
            ; commit and redraw from its own first entry
            mov     rf, less_visible
            mov     rd, less_top
            call    copy4bytes
            call    less_goto
            lbr     main_loop

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

            ; a NEW search always (re)establishes both the scan start
            ; and the "if this fails, 'n' retries from here" baseline
            ; as the current view position -- lsf_found below advances
            ; less_search_resume past the match on success; on
            ; failure it's left at this same baseline.
            mov     rf, less_pos
            mov     rd, less_search_start
            call    copy4bytes
            mov     rf, less_pos
            mov     rd, less_search_resume
            call    copy4bytes

            call    less_search_forward
            lbr     main_loop

cs_cancel:
            call    less_goto           ; redraw current page, clearing
                                        ; the prompt line remnants
            lbr     main_loop

;------------------------------------------------------------------
cmd_next:
            mov     rf, less_search_buf
            ldn     rf
            lbz     main_loop           ; no previous pattern: ignore

            ; resume scanning from just past the last match (see
            ; less_search_forward's own header for why this can't
            ; just be less_pos -- less_goto always forces
            ; less_pos == less_top, which after landing on a match IS
            ; the match's own start, not one line past it)
            mov     rf, less_search_resume
            mov     rd, less_search_start
            call    copy4bytes

            call    less_search_forward
            lbr     main_loop

;------------------------------------------------------------------
cmd_quit:
            mov     rd, less_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      13,10,0             ; land the shell's next prompt
                                        ; at the start of a fresh line
            ldi     0                   ; exit code 0 = success
            rtn

;------------------------------------------------------------------
; less_search_forward: scan forward from less_search_start (set by
; the caller -- cmd_search uses the current view position, cmd_next
; uses less_search_resume) for less_search_buf (case-sensitive
; literal substring), one line at a time.
;
; On a match: snapshots less_search_resume = the position one line
; PAST the match (so a later 'n' continues instead of re-matching the
; same line forever -- this can't just be "whatever less_pos ends up
; at", since less_goto below always forces less_pos == less_top, and
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
            mov     rf, less_search_start
            call    less_seek_to
            mov     rf, less_search_start
            mov     rd, less_pos
            call    copy4bytes

lsf_loop:
            mov     rf, less_pos
            mov     rd, less_candidate_top
            call    copy4bytes          ; candidate = start of the
                                        ; line we're about to read

            call    read_line_here
            lbdf    lsf_notfound

            mov     rf, less_line_buf
            mov     r8, less_search_buf
            call    line_contains
            lbnf    lsf_found
            lbr     lsf_loop

lsf_found:
            ; less_pos has already been advanced past the matched
            ; line by read_line_here -- that's exactly "one line past
            ; the match", snapshot it before less_goto below
            ; overwrites less_pos with the match's own start instead.
            mov     rf, less_pos
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
            ; restore less_pos (and the FCB's real position) to what
            ; they were for THIS page before the scan -- less_top
            ; never changed, so there's no need for less_goto's own
            ; full CLS+redraw here, just the status line needs
            ; touching; less_page_end holds exactly the right value
            ; (snapshotted by draw_page's own dp_status, every time)
            mov     rf, less_page_end
            mov     rd, less_pos
            call    copy4bytes
            mov     rf, less_pos
            call    less_seek_to

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
; less_seek_to: seeks the FCB to the 4-byte big-endian position at
; [RF], and resets the chunk buffer so the next byte read is genuinely
; fresh, not stale pre-seek content.
; Args:    RF = pointer to a 4-byte position
; Returns: nothing meaningful (K_FILE_SEEK's DF is ignored -- see
;          this file's own header comment on the accepted error-
;          handling simplification)
;------------------------------------------------------------------
less_seek_to:
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

;------------------------------------------------------------------
; less_goto: seek to less_top (via less_seek_to), set less_pos =
; less_top, and redraw.
;------------------------------------------------------------------
less_goto:
            mov     rf, less_top
            call    less_seek_to

            mov     rf, less_top
            mov     rd, less_pos
            call    copy4bytes

            call    draw_page
            rtn

;------------------------------------------------------------------
; draw_page: clear the screen and print up to less_page_lines lines
; starting from the CURRENT position (precondition: less_pos ==
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
; less_visible[i] is snapshotted to less_pos immediately before the
; i-th read_line_here call, so it always holds that line's own real
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

dp_loop:
            ; less_visible[i] = less_pos (i = less_lines_this_page,
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
            mov     rf, less_pos
            call    copy4bytes_to_r8

            call    read_line_here
            lbdf    dp_eof

            mov     rf, less_line_buf
            call    K_MSG
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
            mov     rb, less_visible_count
            mov     rf, less_lines_this_page
            ldn     rf
            str     rb                  ; less_visible_count =
                                        ; less_lines_this_page

            ; snapshot the correct "resume" position for THIS page --
            ; used by a failed search (lsf_notfound) to restore
            ; less_pos/the FCB position without needing a full redraw
            ; to re-derive it
            mov     rf, less_pos
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
; print_status_line
;------------------------------------------------------------------
print_status_line:
            mov     rf, less_status_mode
            ldn     rf
            lbnz    psl_notfound

            mov     rf, less_at_eof
            ldn     rf
            lbnz    psl_end

            call    K_INMSG
            db      "-- LESS: SPACE next  b back  g top  G end  / search  n again  q quit --",0
            rtn

psl_end:
            call    K_INMSG
            db      "-- (END) --  b back  g top  / search  q quit --",0
            rtn

psl_notfound:
            call    K_INMSG
            db      "-- Pattern not found -- press any key --",0
            rtn

;------------------------------------------------------------------
; less_reprint_status: repositions to the status row and reprints it
; ALONE, with a trailing clear-to-end-of-line (in case the new text is
; shorter than whatever was there before) -- used by lsf_notfound so
; showing/dismissing the "Pattern not found" message doesn't need a
; full page redraw, unlike every other status-line update in this
; file (which happens as the tail end of a real draw_page call).
;------------------------------------------------------------------
less_reprint_status:
            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            call    K_INMSG
            db      27,'[K',0
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
            mov     rf, less_line_buf
            call    K_MSG
            call    K_INMSG
            db      27,'[K',0

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
            mov     rf, less_line_buf
            call    K_MSG
            call    K_INMSG
            db      27,'[K',0

            mov     rf, less_page_lines
            ldn     rf
            adi     1
            call    position_at_row
            call    print_status_line
            rtn

;------------------------------------------------------------------
; cmd_line_down: move the view down by exactly one line (down-arrow,
; j/J, Ctrl-N, Ctrl-E). Seek-free -- less_pos already sits exactly at
; the next line to reveal, since it's only ever changed by reading
; sequentially forward or by an explicit seek that keeps it in sync.
;------------------------------------------------------------------
cmd_line_down:
            mov     rf, less_at_eof
            ldn     rf
            lbnz    main_loop           ; already at EOF: ignore

            mov     rf, less_pos
            mov     rd, less_new_line
            call    copy4bytes          ; less_new_line = current
                                        ; less_pos (where the new
                                        ; bottom line starts)

            call    read_line_here      ; into less_line_buf; advances
                                        ; less_pos past it
            lbdf    cld_eof

            call    less_shift_visible_left
            call    scroll_up_and_print_bottom
            lbr     main_loop

cld_eof:
            mov     rf, less_at_eof
            ldi     1
            str     rf
            lbr     main_loop

;------------------------------------------------------------------
; cmd_line_up: move the view up by exactly one line (up-arrow, k/K,
; Ctrl-P, Ctrl-Y). If less_stack has a recorded entry, use it (no
; scan needed -- this is the common case, since ordinary forward
; browsing always records history). If the stack is EMPTY (e.g. right
; after 'g'/'G'/a search match, all of which clear less_stack rather
; than push -- see cmd_goto_end's own header comment for why), fall
; back to a genuine backward scan (less_find_prev_line_start) instead
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
; less_pos MUST come out of this routine still meaning exactly what
; every other caller assumes it means: "one past the CURRENT bottom-
; most visible line" -- cmd_forward and cmd_line_down both just read
; sequentially from wherever the chunk buffer/FCB already sit, trusting
; less_pos (and the real underlying read position, which the two must
; always agree on) to already be correct. less_top's own read via
; read_line_here below only ever fetches the NEW TOP line's text for
; display -- as a side effect it leaves less_pos/the FCB sitting one
; line PAST that (i.e. at the window's SECOND entry), which is NOT the
; window's true bottom whenever the window holds more than 2 entries.
; less_pos is therefore explicitly reseeked back afterward in BOTH
; outcomes below, to whichever value genuinely represents the (possibly
; unchanged) bottom -- less_saved_pos (GROWING: the bottom didn't move)
; or less_dropped (FULL: the bottom moved to what fell off the end).
; A real hardware-reported bug (2026-09-02) traced to exactly this:
; skipping the reseek in the GROWING case left less_pos advancing by
; only one line per up-arrow instead of tracking the true bottom, so a
; later down-arrow (pressed before the window ever re-filled the
; screen) would re-read and re-display a line ALREADY visible near the
; top of the window -- a duplicated "phantom" line, not the genuinely
; next unseen content.
;------------------------------------------------------------------
cmd_line_up:
            ; snapshot less_pos before anything below can touch it --
            ; this is the value to restore in the GROWING case, since
            ; the window's bottom (and so the correct forward-resume
            ; position) doesn't move when only the top grows.
            mov     rf, less_pos
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
            call    less_find_prev_line_start
            mov     rf, less_new_line
            mov     rd, less_top
            call    copy4bytes

clu_have_top:
            ; less_top now holds the new top row's offset
            mov     rf, less_top
            call    less_seek_to

            mov     rf, less_top
            mov     rd, less_new_line
            call    copy4bytes

            call    read_line_here      ; content for display only --
                                        ; its side effect on less_pos/
                                        ; the chunk buffer is irrelevant
                                        ; and gets fully overwritten
                                        ; below either way, see this
                                        ; routine's own header comment

            call    less_shift_visible_right
            lbdf    clu_restore_saved  ; DF=1: window just grew -- the
                                        ; bottom hasn't moved, restore
                                        ; the value saved at entry

            ; DF=0: the dropped line is no longer in view -- resume
            ; future forward reads from exactly where it starts. Both
            ; the FCB/chunk-buffer state AND the less_pos variable need
            ; re-syncing here -- setting the variable alone would leave
            ; the ACTUAL read position stuck one line past the window's
            ; second entry, silently disagreeing with what less_pos
            ; claims (the same class of bug this fix exists for).
            mov     rf, less_dropped
            call    less_seek_to
            mov     rf, less_dropped
            mov     rd, less_pos
            call    copy4bytes
            lbr     clu_display

clu_restore_saved:
            mov     rf, less_saved_pos
            call    less_seek_to
            mov     rf, less_saved_pos
            mov     rd, less_pos
            call    copy4bytes

clu_display:
            mov     rf, less_at_eof
            ldi     0
            str     rf                  ; moved away from the tail

            call    scroll_down_and_print_top
            lbr     main_loop

;------------------------------------------------------------------
; less_find_prev_line_start: computes the start offset of the line
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
; (cmd_line_up) always calls less_seek_to right after this returns,
; which resets that state correctly no matter where this leaves the
; FCB's real position.
;
; Precondition: less_top > 0 (checked by the caller -- there's no
; earlier line at all when less_top is already 0).
; Args:    (none -- reads less_top directly)
; Returns: less_new_line = the previous line's start offset
; Verified against an independent Python reference (a naive unbounded
; backward scan for the common case, checked across 2000+ random
; files/positions; a separate bounds/no-crash check for the window-
; exceeded case) before being trusted here (2026-09-01).
;------------------------------------------------------------------
less_find_prev_line_start:
            ; less_backscan_start = less_top - (LESS_BACKSCAN_LEN+1),
            ; clamped to 0 if that would underflow (i.e. less_top is
            ; already within the window of the true file start) --
            ; the standard 4-byte SM/SMB borrow chain, LSB first, this
            ; project already uses elsewhere for 32-bit subtraction
            ; (e.g. progs/chkdsk.asm's own chk_sub32).
            mov     r7, less_top
            add16   r7, 3               ; r7 -> less_top+3 (LSB)
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
            lbdf    lfp_start_ok        ; DF=1: no borrow -- less_top
                                        ; was >= LESS_BACKSCAN_LEN+1
            mov     rf, less_backscan_start
            call    zero4bytes
lfp_start_ok:

            ; diff = less_top - less_backscan_start (4 bytes, but only
            ; the LOW byte matters -- guaranteed to be 1..
            ; LESS_BACKSCAN_LEN+1 by construction: either
            ; less_backscan_start was clamped to 0 and diff==less_top
            ; (which was < LESS_BACKSCAN_LEN+1 in that exact case), or
            ; it wasn't clamped and diff==LESS_BACKSCAN_LEN+1 exactly)
            mov     r7, less_top
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
            mov     rd, less_new_line
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
            ; less_new_line = less_backscan_start + (less_backscan_idx+1)
            mov     rf, less_backscan_start
            mov     rd, less_new_line
            call    copy4bytes

            mov     rf, less_backscan_idx
            ldn     rf
            adi     1
            plo     r9
            ldi     0
            phi     r9                  ; r9 = the small delta (1..
                                        ; LESS_BACKSCAN_LEN)

            mov     r7, less_new_line
            add16   r7, 3               ; r7 -> less_new_line+3 (LSB)

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
            mov     rd, less_new_line
            call    copy4bytes
            rtn

;------------------------------------------------------------------
; read_line_here: reads one line starting at the current position
; into less_line_buf (NUL-terminated, capped at LESS_LINE_MAX-1
; chars -- excess bytes are still consumed so offset tracking stays
; correct, just not kept), consuming through the terminating LF if
; present. A final line with no trailing LF is still returned once
; (DF=0) before the following call reports true EOF (DF=1) -- same
; convention this project's own K_INPUTL/read_line_ex EOF signaling
; already established. Advances less_pos by the number of bytes
; actually consumed.
; Returns: DF=0 -- less_line_buf holds a real (possibly empty) line
;          DF=1 -- nothing left to read at all
;------------------------------------------------------------------
read_line_here:
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

            ; ordinary character -- store into less_line_buf if room
            mov     rf, less_linelen
            ldn     rf
            smi     LESS_LINE_MAX-1
            lbdf    rlh_loop            ; already full -- discard,
                                        ; keep consuming

            mov     rf, less_linelen
            ldn     rf                  ; D = linelen (write index)
            plo     r8
            ldi     0
            phi     r8
            mov     rf, less_line_buf
            add16   rf, r8              ; RF = &less_line_buf[linelen]
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
            mov     rf, less_line_buf
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
            ; silent-but-catastrophic (less_pos/less_top jump to a
            ; wild offset every single line), yet forward paging could
            ; still look superficially plausible whenever the garbage
            ; offset happened to land inside other real text.
            mov     r8, less_consumed
            lda     r8
            plo     rd
            ldn     r8
            phi     rd                  ; RD = the 16-bit delta
            call    less_pos_add16

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
; line_contains: does the NUL-terminated string at RF (haystack)
; contain the NUL-terminated string at R8 (needle, must be non-empty)
; as a substring? Naive search via pure pointer-walking (no computed
; offsets/indices at all, so CLAUDE.md gotcha #18 -- an ADD16/SUB16
; register-register op silently clobbering a just-staged str-r2
; comparison byte -- structurally can't apply here).
; Returns: DF=0 if found, DF=1 if not.
; Modifies: everything (RF, R8, RA, RB, RC)
;------------------------------------------------------------------
line_contains:
            mov     ra, r8              ; RA = needle start (constant)

lc_outer:
            ldn     rf                  ; peek the haystack char here
            lbz     lc_notfound         ; haystack exhausted: no match

            mov     rb, rf              ; RB = inner haystack pointer
            mov     rc, ra              ; RC = inner needle pointer,
                                        ; reset to the needle's start
lc_inner:
            ldn     rc                  ; needle char
            lbz     lc_match            ; needle exhausted: full match

            str     r2                  ; stage the needle char
            ldn     rb                  ; D = haystack char
            sm                          ; D = haystack_char - needle_char
            lbnz    lc_next_outer       ; mismatch

            inc     rb
            inc     rc
            lbr     lc_inner

lc_next_outer:
            inc     rf
            lbr     lc_outer

lc_match:
            clc
            rtn

lc_notfound:
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
;     hasn't moved, so the caller must restore less_pos to whatever it
;     was BEFORE this call (its own incidental value right after this
;     routine returns is the offset of the window's NEW second entry,
;     not its bottom -- NOT safe to leave as-is; see cmd_line_up's own
;     header comment for the real hardware bug this caused when an
;     earlier version got this wrong).
;   - FULL (count == page_lines, the ordinary case): less_visible
;     [count-1] is captured into less_dropped first (the caller uses
;     it to "un-consume" that line back into less_pos, since it's no
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

;------------------------------------------------------------------
; copy4bytes: copies 4 bytes from [RF] to [RD] (both advanced).
;------------------------------------------------------------------
copy4bytes:
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            rtn

;------------------------------------------------------------------
; copy4bytes_to_r8: copies 4 bytes from [RF] to [R8] (both advanced) --
; a separate entry point from copy4bytes purely because several
; callers (less_push_offset, draw_page's own less_visible[] snapshot,
; less_shift_visible_left's insert step) already have their
; destination address computed into R8, with RD needed for something
; else moments later -- avoids a spurious extra register shuffle at
; each of those call sites.
;------------------------------------------------------------------
copy4bytes_to_r8:
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8
            rtn

;------------------------------------------------------------------
; zero4bytes: zeroes the 4 bytes at [RF] (advanced).
;------------------------------------------------------------------
zero4bytes:
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            rtn

;------------------------------------------------------------------
; less_pos_add16: less_pos (4 bytes, big-endian, at less_pos+0..+3)
; += RD (a 16-bit delta). Same proven "4 individual byte steps, LSB
; first, ADD then ADC x3, str r2 immediately consumed by the next
; add/adc with nothing in between" shape as progs/chkdsk.asm's own
; chk_add32 -- independently hand-verified here against a concrete
; example (0x0000FFFF + 0x0002 = 0x00010001) before being trusted.
; Modifies: R7 (and D). RD's bytes are consumed, not needed after.
;------------------------------------------------------------------
less_pos_add16:
            mov     r7, less_pos
            add16   r7, 3               ; R7 -> less_pos+3 (LSB byte)

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

;------------------------------------------------------------------
usage:
            call    K_INMSG
            db      "Usage: LESS <filename>",13,10,0
            ldi     1
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
less_fcb:               ds      FCB_LEN
less_iobuf:              ds      FCB_IOBUF_LEN

less_pos:                ds      4       ; current read position (MSB-first)
less_top:                ds      4       ; start of the displayed page
less_candidate_top:       ds      4       ; scratch, used during search

less_chunk_buf:           ds      LESS_CHUNK_LEN
less_chunk_ptr:            dw      0
less_chunk_remaining:       db      0

less_line_buf:             ds      LESS_LINE_MAX
less_linelen:                db      0
less_consumed:                dw      0

less_search_buf:              ds      LESS_SEARCH_MAX
less_search_start:              ds      4       ; scan-start scratch,
                                                ; set fresh by the
                                                ; caller each search
less_search_resume:               ds      4       ; where 'n' resumes

less_stack:                     ds      LESS_STACK_MAX*4
less_stack_count:                 db      0
less_back_i:                       db      0       ; cmd_back's own loop
                                                    ; counter (successful
                                                    ; pops so far)
less_push_i:                        db      0       ; less_push_visible_all's
                                                    ; own loop counter

less_visible:                        ds      LESS_MAX_VISIBLE*4  ; sliding
                                                    ; window of currently-
                                                    ; displayed lines' own
                                                    ; start offsets
less_visible_count:                    db      0   ; how many of the above
                                                    ; are actually valid
less_new_line:                           ds      4  ; scratch: value to
                                                    ; insert/append, set by
                                                    ; the caller before
                                                    ; calling either shift
                                                    ; routine
less_dropped:                              ds      4  ; scratch: the value
                                                    ; a right-shift (line-
                                                    ; up) drops off the end
less_saved_pos:                            ds      4  ; scratch: less_pos,
                                                    ; snapshotted by
                                                    ; cmd_line_up before it
                                                    ; does anything else --
                                                    ; see its own header
                                                    ; comment
less_page_end:                               ds      4  ; snapshotted by
                                                    ; draw_page: the correct
                                                    ; less_pos for the
                                                    ; CURRENT page, so a
                                                    ; failed search can
                                                    ; restore it without a
                                                    ; full redraw

less_backscan_buf:                             ds      LESS_BACKSCAN_LEN
less_backscan_start:                             ds      4
less_backscan_count:                               db      0
less_backscan_idx:                                   db      0

less_page_lines:                    db      LESS_PAGE_LINES
less_lines_this_page:                 db      0
less_at_eof:                            db      0
less_status_mode:                         db      0
less_key:                                   db      0
less_rows_name:                               db      "ROWS",0
less_esc_buf:                                   ds      10

            end     start
