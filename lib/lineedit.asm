;
; lineedit.asm - K_INPUTL-style line editor with arrow-key/Emacs-style
; Ctrl-shortcut cursor editing (Left/Right/Home/End/Backspace/Del/
; Ctrl-B/F/A/E/D). NOT a standalone program -- no EDF header, no org
; PROG_BASE, no entry point of its own. Assembled separately
; (lib/lineedit.prg) and linked alongside a program that wants it,
; the same way every other lib/*.asm module already does. A calling
; program declares "extrn read_line_ex" and calls it like any other
; routine.
;
; Extracted from progs/shell.asm's own read_line_with_history
; (2026-07-27), at the user's own request (EDLIN bug-report item 7,
; 2026-07-30: "I'd like to see us create that library function that
; programs can use as an alternative to K_INPUTL to give them line
; editing (no history) and use it when entering text in edlin").
;
; Deliberately scoped to cursor editing only -- HISTORY RECALL (Up/
; Down) IS NOT INCLUDED, by design, not as a deferred TODO. Up/Down
; arrow bytes are recognized (so a stray CSI sequence doesn't get
; mis-parsed as literal text) but silently discarded, exactly like
; the still-deferred Ctrl-K/U/W/Y cut/paste shortcuts. A caller that
; wants history needs its own mechanism layered on top (the shell's
; own hist_* machinery stays in progs/shell.asm, not moved here --
; it's tightly coupled to the shell's own history.dat file and
; wouldn't generalize cleanly).
;
; The single hardest design question extracting this out of the
; shell was the choice of underlying byte-read primitive, because the
; two callers this library actually has (the shell and EDLIN) have
; GENUINELY DIFFERENT needs here, not just a style preference:
;
;   - progs/shell.asm's own prompt read is NEVER itself redirected
;     (shell input redirection only ever applies to a CHILD program's
;     own I/O) -- so it was safe for read_line_with_history to always
;     call f_uread (the raw UART BIOS entry point) directly,
;     bypassing K_READ's own kernel-jump-table/RAM-vector redirect
;     indirection entirely. This was a real, hardware-confirmed fix
;     (2026-07-23): that indirection was slow enough, between this
;     routine's own per-byte branching, to drop the '[' byte of a
;     fast-arriving "ESC [ A"/"ESC [ B" arrow-key sequence -- the
;     exact bug progs/mr.asm/progs/ms.asm already hit and fixed the
;     same way (see their own header comments).
;
;   - EDLIN, by contrast, genuinely needs its OWN stdin to support
;     redirection ("edlin file < script.txt", an already-shipped,
;     hardware-confirmed feature depending on K_INPUTL's DF=0/1 EOF
;     contract -- see kernel/redir.asm's own header and the
;     K_INPUTL-EOF bug hunt in CLAUDE.md). f_uread can never see
;     redirected input at all (redirection is a kernel-jump-table-
;     level concept -- _redir_read is reached only via K_READ's own
;     dispatch slot), so a version that always used f_uread would
;     silently break "< file" batch editing for any caller that
;     switched to it.
;
; Resolved (confirmed with the user 2026-07-30) as a caller-selectable
; mode, matching this project's own established -u/-b precedent in
; progs/mr.asm/progs/ms.asm/lib/ymodem.asm (see le_getchar below for
; the mode dispatch itself): LE_MODE_FAST uses f_uread throughout
; (byte-drop-safe, but can never signal EOF); LE_MODE_REDIR uses
; K_READ throughout (redirect-aware, DF=1 at EOF, but subject to the
; same K_READ-latency byte-drop risk on a live arrow-key sequence that
; motivated LE_MODE_FAST in the first place -- a live user might
; occasionally need to press an arrow key twice). Neither mode is
; strictly better; the caller picks based on whether ITS OWN stdin can
; ever be redirected.
;
; State (le_buf/le_max_len/le_mode/le_len/le_cursor and the various
; per-routine scratch fields below) is this library's own private,
; fixed-address static data -- NOT part of the caller's buffer, and
; not caller-visible. Safe because a program is single-threaded and a
; "read a line" call always runs to completion before returning, so
; there's no re-entrancy concern (the same reasoning every other
; lib/*.asm module's own static data already relies on). Only the
; BUFFER itself is caller-supplied (never this library's own fixed
; LINE_BUF-equivalent) -- confirmed with the user as the whole point
; of a reusable library: using the shell's own LINE_BUF here would
; risk corrupting live shell state for any caller other than the
; shell itself.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

            extrn   le_buf
            extrn   le_max_len
            extrn   le_mode
            extrn   le_len
            extrn   le_cursor
            extrn   le_ert_blank_count
            extrn   le_ert_start
            extrn   le_ert_pos
            extrn   le_ert_bscount
            extrn   le_eic_i
            extrn   le_eda_i
            extrn   le_home_count
            extrn   le_end_pos

;------------------------------------------------------------------
; read_line_ex: see this file's own header comment for the full
; design discussion (extraction rationale, history-recall scope, and
; the LE_MODE_FAST/LE_MODE_REDIR tradeoff).
; Args:    RF = caller-owned buffer (must be at least max_len+1 bytes)
;          RC.0 = max_len (max characters, NOT including the NUL
;          terminator)
;          D = mode (LE_MODE_FAST or LE_MODE_REDIR, include/lineedit.inc)
; Returns: DF=0: buffer holds a NUL-terminated line (possibly empty)
;          DF=1: EOF (LE_MODE_REDIR only) -- input was exhausted
;          before any real content was read this call; buffer holds
;          an empty string. LE_MODE_FAST never returns DF=1, matching
;          a live keyboard's own lack of any EOF concept.
; Modifies: everything
;------------------------------------------------------------------
            proc    read_line_ex

            plo     r9                  ; stash D=mode -- the mov
                                        ; below clobbers D (gotcha #4)
            mov     rb, le_mode
            glo     r9
            str     rb                  ; le_mode = mode argument

            mov     rb, le_max_len
            glo     rc
            str     rb                  ; le_max_len = RC.0

            mov     rb, le_buf
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; le_buf = RF (caller's buffer
                                        ; pointer)

            mov     rf, le_len
            ldi     0
            str     rf                  ; le_len = 0

            mov     rf, le_cursor
            ldi     0
            str     rf                  ; le_cursor = 0

            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = caller's buffer
            ldi     0
            str     rf                  ; buffer[0] = 0 (empty line)

            lbr     le_loop

;------------------------------------------------------------------
; le_getchar: mode-aware, blocking single-byte read -- see this
; file's own header comment for the full LE_MODE_FAST/LE_MODE_REDIR
; tradeoff. In LE_MODE_REDIR, D==0 signals EOF, matching
; kernel/redir.asm's _redir_read own documented contract ("D=0 (NUL)
; at EOF or on a read error"); a live console read via K_READ, when
; NOT actually redirected, falls straight through to the real BIOS
; f_read and can never legitimately produce a NUL for a genuine
; keystroke, so this is unambiguous. LE_MODE_FAST/LE_MODE_BITBANG
; never signal EOF.
;
; LE_MODE_BITBANG (2026-08-05) added as a third plain branch, not a
; function-pointer/indirect-call redesign -- extending this dispatch
; to a new already-known, already-proven-convention BIOS routine
; (f_bread, used identically to f_uread by progs/mr.asm/lib/ymodem.asm)
; costs one more three-instruction branch, matching this project's
; own established mr.asm/ms.asm/ymodem.asm "-u"/"-b" mode-number
; precedent exactly. A genuinely dynamic, not-known-at-link-time
; source (e.g. a future parallel-keyboard driver) would be the real
; case for an indirect call -- not needed for any source that exists
; today.
; Args:    none (reads le_mode)
; Returns: DF=0, D=the byte read; or DF=1 (LE_MODE_REDIR only) for
;          EOF -- every caller must check DF immediately after the
;          call, same discipline as K_INPUTL's own DF=0/1 contract.
; Modifies: RD (and D)
;------------------------------------------------------------------
le_getchar:
            mov     rd, le_mode
            ldn     rd
            lbz     lgc_mode0           ; mode 0: LE_MODE_FAST
            xri     1
            lbz     lgc_mode1           ; mode 1: LE_MODE_REDIR

            ; mode 2: LE_MODE_BITBANG
            call    f_bread
            clc
            rtn

lgc_mode0:
            call    f_uread
            clc
            rtn

lgc_mode1:
            call    K_READ
            lbnz    lgc_have_byte
            stc                         ; D==0: EOF
            rtn

lgc_have_byte:
            clc
            rtn

le_loop:
            call    le_getchar
            lbdf    le_do_eof
            plo     rc                  ; RC.0 = char

            ; ESC checked FIRST -- minimizes the latency between
            ; reading ESC and le_escape's own next le_getchar call,
            ; same reasoning as progs/shell.asm's own rlwh_loop.
            glo     rc
            xri     27                  ; ESC
            lbz     le_escape

            glo     rc
            xri     13                  ; CR
            lbz     le_finish
            glo     rc
            xri     10                  ; LF
            lbz     le_finish

            glo     rc
            xri     8                   ; backspace / Ctrl-H
            lbz     le_backspace

            glo     rc
            xri     1                   ; Ctrl-A: home
            lbz     le_home

            glo     rc
            xri     5                   ; Ctrl-E: end
            lbz     le_end

            glo     rc
            xri     2                   ; Ctrl-B: cursor left
            lbz     le_left

            glo     rc
            xri     6                   ; Ctrl-F: cursor right
            lbz     le_right

            glo     rc
            xri     4                   ; Ctrl-D: delete at cursor
            lbz     le_ctrld

            ; ---- deferred: Ctrl-K/U/W/Y need a cut buffer, not
            ; implemented -- explicitly discarded rather than falling
            ; through to the ordinary-character path below ----
            glo     rc
            xri     11                  ; Ctrl-K
            lbz     le_loop
            glo     rc
            xri     21                  ; Ctrl-U
            lbz     le_loop
            glo     rc
            xri     23                  ; Ctrl-W
            lbz     le_loop
            glo     rc
            xri     25                  ; Ctrl-Y
            lbz     le_loop

            ; ---- any other control byte: silently discard ----
            glo     rc
            smi     32
            lbnf    le_loop             ; < 32 ($20): discard

            ; ---- ordinary character: insert at cursor if there's room ----
            mov     rf, le_max_len
            ldn     rf
            str     r2                  ; M(X) = le_max_len (subtrahend)
            mov     rf, le_len
            ldn     rf                  ; D = le_len (minuend)
            sm                          ; DF=1 iff le_len >= le_max_len
            lbdf    le_loop             ; at cap: silently drop

            call    le_insert_char      ; RC.0 = character to insert
                                        ; (already set above, untouched
                                        ; by every check since)

            lbr     le_loop

;------------------------------------------------------------------
; le_redraw_tail: reprint buffer[le_ert_start..le_len-1] (the tail
; after an insert/delete at/before le_cursor), print le_ert_blank_
; count trailing spaces to erase a stale character left over from a
; delete, then walk the terminal cursor back to le_cursor via
; backspaces. le_ert_start and le_cursor are DELIBERATELY different
; positions for an insert (le_cursor has already advanced past the
; newly-inserted character by the time this runs; le_ert_start is the
; OLD position, where the visible content actually changed and where
; the terminal's own physical cursor already sits) -- conflating them
; was a real hardware-found bug the first time this logic was written
; (see progs/shell.asm's own edit_redraw_tail for the full story).
; Args:    D = blank_count (0 for insert, 1 for a single-character
;          delete -- every edit operation here changes exactly one
;          character, so this is always 0 or 1)
; Returns: nothing
; Modifies: R8, R9, RD, RF (and D)
;------------------------------------------------------------------
le_redraw_tail:
            plo     r9                  ; R9.0 = blank_count (stashed
                                        ; to memory immediately below)
            mov     rf, le_ert_blank_count
            glo     r9
            str     rf

            mov     rb, le_ert_pos
            mov     rf, le_ert_start
            ldn     rf
            str     rb                  ; le_ert_pos = le_ert_start

lert_print_loop:
            mov     rf, le_ert_pos
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = le_ert_pos (zero-ext)
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = caller's buffer
            add16   rf, r8              ; RF = &buffer[le_ert_pos]
            ldn     rf                  ; D = buffer[le_ert_pos]
            lbz     lert_print_done     ; NUL: tail fully printed

            call    K_TYPE              ; echo (D still holds the
                                        ; character, set by ldn above)

            mov     rf, le_ert_pos
            ldn     rf
            adi     1
            str     rf                  ; le_ert_pos++
            lbr     lert_print_loop

lert_print_done:
            ; le_ert_pos now equals le_len -- print blank_count
            ; trailing spaces
            mov     rf, le_ert_blank_count
            ldn     rf
            lbz     lert_no_blank

            ldi     ' '
            call    K_TYPE

lert_no_blank:
            ; backspace count = (le_ert_pos - le_cursor) + blank_count
            mov     rf, le_cursor
            ldn     rf
            str     r2                  ; M(X) = le_cursor (subtrahend)
            mov     rf, le_ert_pos
            ldn     rf                  ; D = le_ert_pos (minuend)
            sm                          ; D = le_ert_pos - le_cursor
            plo     r8                  ; stash (mov below clobbers D)

            mov     rf, le_ert_blank_count
            ldn     rf
            str     r2                  ; M(X) = blank_count
            glo     r8                  ; D = tail_len (reloaded)
            add                         ; D = tail_len + blank_count
            plo     r8                  ; stash (mov below clobbers D)
            mov     rf, le_ert_bscount
            glo     r8
            str     rf

lert_backspace_loop:
            mov     rf, le_ert_bscount
            ldn     rf
            lbz     lert_backspace_done

            ldi     8
            call    K_TYPE

            mov     rf, le_ert_bscount
            ldn     rf
            smi     1
            str     rf
            lbr     lert_backspace_loop

lert_backspace_done:
            rtn

;------------------------------------------------------------------
; le_insert_char: insert RC.0 into the caller's buffer at le_cursor,
; shifting the existing tail (including the NUL terminator) right by
; one, then redraw and advance the cursor. Caller has already
; confirmed there's room (le_len < le_max_len).
;
; The shift loop is a POST-test loop (copy first, then check whether
; that was the last needed copy) rather than the more obvious pre-
; test-then-decrement shape -- see progs/shell.asm's own
; edit_insert_char for the full derivation of why a pre-test/decrement
; loop breaks at cursor==0 on an empty line (8-bit unsigned
; underflow: the loop counter would need to go to -1 to signal "done"
; but wraps to 255 instead, and a naive unsigned comparison then
; wrongly treats 255 as "still >= 0").
; Args:    RC.0 = character to insert
; Returns: nothing
; Modifies: R7, R8, R9, RB, RD, RF (and D)
;------------------------------------------------------------------
le_insert_char:
            mov     rb, le_eic_i
            mov     rf, le_len
            ldn     rf
            str     rb                  ; le_eic_i = le_len (shift
                                        ; starts from the end, working
                                        ; backward, to avoid clobbering
                                        ; not-yet-moved bytes)

leic_shift_loop:
            mov     rf, le_eic_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = i (zero-extended)
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = caller's buffer
            add16   rf, r8              ; RF = &buffer[i]
            ldn     rf                  ; D = buffer[i]
            plo     r9                  ; stash (mov below clobbers D)
            inc     rf                  ; RF = &buffer[i+1]
            glo     r9
            str     rf                  ; buffer[i+1] = buffer[i]

            ; was that the last needed copy (i == le_cursor)? see
            ; this routine's own header for why this is a post-test
            mov     rf, le_cursor
            ldn     rf
            str     r2                  ; M(X) = le_cursor
            mov     rf, le_eic_i
            ldn     rf                  ; D = i
            sm                          ; D = i - le_cursor
            lbz     leic_shift_done     ; i == le_cursor: done

            mov     rf, le_eic_i
            ldn     rf
            smi     1
            str     rf                  ; i--
            lbr     leic_shift_loop

leic_shift_done:
            ; le_ert_start = le_cursor (the OLD, pre-increment value --
            ; must be captured here, before le_cursor advances below)
            mov     rb, le_ert_start
            mov     rf, le_cursor
            ldn     rf
            str     rb                  ; le_ert_start = le_cursor (OLD)

            mov     rf, le_cursor
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8
            glo     rc
            str     rf                  ; buffer[le_cursor] = char
                                        ; (still the OLD value here)

            mov     rf, le_len
            ldn     rf
            adi     1
            str     rf                  ; le_len++

            mov     rf, le_cursor
            ldn     rf
            adi     1
            str     rf                  ; le_cursor++ (now FINAL)

            ldi     0                   ; blank_count = 0 (insert)
            call    le_redraw_tail
            rtn

;------------------------------------------------------------------
; le_delete_at: delete the character at buffer[hole], shifting
; buffer[hole+1..le_len] (including the NUL) left by one, then
; decrement le_len and redraw. Does NOT touch le_cursor OR
; le_ert_start -- the CALLER must set both to their final values
; BEFORE calling (see progs/shell.asm's own edit_delete_at for the
; full derivation of why, and why the physical terminal cursor must
; also already be repositioned for a backspace before this runs).
; Caller has already confirmed hole < le_len.
; Args:    D = hole (position to delete)
; Returns: nothing
; Modifies: R7, R8, R9, RD, RF (and D)
;------------------------------------------------------------------
le_delete_at:
            plo     r9
            mov     rf, le_eda_i
            glo     r9
            str     rf                  ; le_eda_i = hole

ledel_shift_loop:
            ; pre-test is safe here (unlike the insert loop) since i
            ; only ever increases -- no underflow risk
            mov     rf, le_len
            ldn     rf
            str     r2                  ; M(X) = le_len
            mov     rf, le_eda_i
            ldn     rf                  ; D = i
            sm                          ; D = i - le_len, DF=1 if
                                        ; i >= le_len (no borrow)
            lbdf    ledel_shift_done

            mov     rf, le_eda_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8              ; RF = &buffer[i]
            inc     rf                  ; RF = &buffer[i+1]
            ldn     rf                  ; D = buffer[i+1]
            plo     r9                  ; stash (mov below clobbers D)

            mov     rf, le_eda_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8              ; RF = &buffer[i]
            glo     r9
            str     rf                  ; buffer[i] = buffer[i+1]

            mov     rf, le_eda_i
            ldn     rf
            adi     1
            str     rf                  ; i++
            lbr     ledel_shift_loop

ledel_shift_done:
            mov     rf, le_len
            ldn     rf
            smi     1
            str     rf                  ; le_len--

            ldi     1                   ; blank_count = 1 (delete)
            call    le_redraw_tail
            rtn

;------------------------------------------------------------------
; le_home/le_end/le_left/le_right/le_ctrld/le_backspace: Ctrl-A/E/B/
; F/D and backspace, plus (via le_escape) the Left/Right/Del arrow
; equivalents. Plain jump targets, not call/return subroutines --
; each ends with "lbr le_loop" directly.
;------------------------------------------------------------------
le_home:
            mov     rf, le_cursor
            ldn     rf
            lbz     le_loop             ; already at 0: no-op

            mov     rf, le_home_count
            mov     rb, le_cursor
            ldn     rb
            str     rf                  ; le_home_count = le_cursor

lhome_bs_loop:
            mov     rf, le_home_count
            ldn     rf
            lbz     lhome_done

            ldi     8
            call    K_TYPE

            mov     rf, le_home_count
            ldn     rf
            smi     1
            str     rf
            lbr     lhome_bs_loop

lhome_done:
            mov     rf, le_cursor
            ldi     0
            str     rf
            lbr     le_loop

le_end:
            mov     rf, le_cursor
            ldn     rf
            str     r2                  ; M(X) = le_cursor
            mov     rf, le_len
            ldn     rf
            sm                          ; D = le_len - le_cursor
            lbz     le_loop             ; already at end: no-op

            mov     rb, le_end_pos
            mov     rf, le_cursor
            ldn     rf
            str     rb                  ; le_end_pos = le_cursor

lend_print_loop:
            mov     rf, le_end_pos
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8
            ldn     rf
            lbz     lend_print_done     ; NUL: done

            call    K_TYPE

            mov     rf, le_end_pos
            ldn     rf
            adi     1
            str     rf
            lbr     lend_print_loop

lend_print_done:
            mov     rb, le_cursor
            mov     rf, le_len
            ldn     rf
            str     rb                  ; le_cursor = le_len
            lbr     le_loop

le_left:
            mov     rf, le_cursor
            ldn     rf
            lbz     le_loop             ; already at 0: no-op

            smi     1
            plo     r8                  ; stash (mov below clobbers D)
            mov     rf, le_cursor
            glo     r8
            str     rf                  ; le_cursor--

            ldi     8
            call    K_TYPE
            lbr     le_loop

le_right:
            mov     rf, le_cursor
            ldn     rf
            str     r2                  ; M(X) = le_cursor
            mov     rf, le_len
            ldn     rf
            sm                          ; D = le_len - le_cursor
            lbz     le_loop             ; already at end: no-op

            mov     rf, le_cursor
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rd, le_buf
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8
            ldn     rf                  ; D = buffer[le_cursor] --
                                        ; the character about to be
                                        ; passed over
            call    K_TYPE

            mov     rf, le_cursor
            ldn     rf
            adi     1
            str     rf                  ; le_cursor++
            lbr     le_loop

le_ctrld:
            mov     rf, le_cursor
            ldn     rf
            str     r2                  ; M(X) = le_cursor
            mov     rf, le_len
            ldn     rf
            sm                          ; D = le_len - le_cursor
            lbz     le_loop             ; at end: nothing to delete

            ; Ctrl-D/Del doesn't move the cursor -- it stays at hole,
            ; which is also where the terminal's own physical cursor
            ; already sits, so le_ert_start = le_cursor unchanged
            mov     rb, le_ert_start
            mov     rf, le_cursor
            ldn     rf
            str     rb                  ; le_ert_start = le_cursor (=hole)

            mov     rf, le_cursor
            ldn     rf                  ; D = hole = le_cursor
            call    le_delete_at
            lbr     le_loop

le_backspace:
            mov     rf, le_cursor
            ldn     rf
            lbz     le_loop             ; at start: no-op

            smi     1                   ; D = le_cursor - 1 = hole
            plo     r8                  ; stash hole (mov below
                                        ; clobbers D)

            mov     rb, le_ert_start
            glo     r8
            str     rb                  ; le_ert_start = hole

            mov     rf, le_cursor
            glo     r8
            str     rf                  ; le_cursor = hole (FINAL --
                                        ; must be set BEFORE calling
                                        ; le_delete_at)

            ; move the terminal's own PHYSICAL cursor from its
            ; current position (one past hole) back to hole BEFORE
            ; the shift+redraw runs
            ldi     8
            call    K_TYPE

            ; D = hole -- reloaded fresh from memory (le_cursor
            ; already holds it), never trusted in R8 across the
            ; K_TYPE call (its own clobber footprint isn't proven,
            ; gotcha #8/#10)
            mov     rf, le_cursor
            ldn     rf
            call    le_delete_at

            lbr     le_loop

;------------------------------------------------------------------
; le_escape: parse the byte(s) following a real ESC. Every follow-up
; read goes through le_getchar (not a raw f_uread/K_READ call) so a
; LE_MODE_REDIR caller's EOF can be detected even mid-sequence --
; without this, a redirected script ending exactly after a stray ESC
; byte could spin forever re-reading D=0 (the exact class of bug this
; project already hit once with K_INPUTL itself, see CLAUDE.md's
; "edlin file <NUL" writeup).
;------------------------------------------------------------------
le_escape:
            call    le_getchar
            lbdf    le_do_eof
            plo     rc                  ; RC.0 = byte immediately
                                        ; after ESC

            ; Real ANSI/VT100 "ESC [ A"/"ESC [ B"/etc -- see
            ; progs/shell.asm's own rlwh_escape for the full history
            ; of why a bare-letter fallback was tried and deliberately
            ; removed: malformed/incomplete sequences are always
            ; discarded here, never guessed at.
            glo     rc
            xri     '['
            lbnz    le_loop             ; not a CSI sequence: discard

            call    le_getchar
            lbdf    le_do_eof
            plo     rc
            glo     rc
            xri     'A'                 ; Up -- no history support in
            lbz     le_loop             ; this library: discard
            glo     rc
            xri     'B'                 ; Down -- discard, same reason
            lbz     le_loop
            glo     rc
            xri     'C'                 ; Right arrow
            lbz     le_right
            glo     rc
            xri     'D'                 ; Left arrow
            lbz     le_left

            ; Del key: "ESC [ 3 ~", a 4-byte sequence
            glo     rc
            xri     '3'
            lbnz    le_loop             ; unrecognized: discard

            call    le_getchar          ; read the expected '~'
            lbdf    le_do_eof
            plo     rc
            glo     rc
            xri     '~'
            lbnz    le_loop             ; malformed: discard
            lbr     le_ctrld            ; Del: same as Ctrl-D

le_finish:
            clc                         ; DF=0: a normal line, Enter
                                        ; was pressed
            rtn

le_do_eof:
            ; LE_MODE_REDIR only (le_getchar never signals DF=1 in
            ; LE_MODE_FAST). A partial line already accumulated this
            ; call is still returned as a normal DF=0 line, matching
            ; K_INPUTL's own "final line with no trailing newline is
            ; still returned once" rule -- only a call that read
            ; nothing at all before hitting EOF reports true DF=1.
            mov     rf, le_len
            ldn     rf
            lbnz    le_finish
            stc                         ; nothing read at all: true EOF
            rtn

            endp

;------------------------------------------------------------------
; Shared data -- one dedicated data proc (not bare top-level content
; between two proc/endp blocks), matching this project's own
; established convention -- see CLAUDE.md gotcha #20: bare top-level
; data referenced from inside a proc can silently anchor the whole
; linked binary to the wrong base address.
;------------------------------------------------------------------
            proc    _lineedit_data

le_buf:             dw      0           ; caller's buffer pointer
le_max_len:         db      0           ; caller's max length (chars,
                                        ; not counting the NUL)
le_mode:            db      0           ; LE_MODE_FAST / LE_MODE_REDIR
le_len:             db      0           ; current line length
le_cursor:          db      0           ; cursor position within the
                                        ; buffer, 0..le_len

le_ert_blank_count: db      0           ; le_redraw_tail's own arg
le_ert_start:       db      0           ; le_redraw_tail's own print-
                                        ; start / caller-set position
le_ert_pos:         db      0           ; le_redraw_tail's own print
                                        ; cursor
le_ert_bscount:     db      0           ; le_redraw_tail's own
                                        ; backspace-count scratch

le_eic_i:           db      0           ; le_insert_char's own shift
                                        ; index
le_eda_i:           db      0           ; le_delete_at's own shift
                                        ; index

le_home_count:      db      0           ; le_home's own backspace
                                        ; count
le_end_pos:         db      0           ; le_end's own print cursor

                public  le_buf
                public  le_max_len
                public  le_mode
                public  le_len
                public  le_cursor
                public  le_ert_blank_count
                public  le_ert_start
                public  le_ert_pos
                public  le_ert_bscount
                public  le_eic_i
                public  le_eda_i
                public  le_home_count
                public  le_end_pos

            endp
