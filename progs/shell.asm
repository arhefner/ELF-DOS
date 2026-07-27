;
; shell.asm - ELF-DOS command shell
;
; Loaded and run repeatedly by the kernel's own run_loop (see
; kernel_init in kernel/kernel.asm) -- each time this program runs, it
; prompts for and resolves exactly ONE command line, then returns. It
; CANNOT load and run the resolved command directly: this program
; lives at PROG_BASE, the same fixed address any loaded command also
; loads to, so loading a command here would overwrite this program's
; own currently-executing code before it could safely return (the
; same reason kernel.asm's loader never exposes a jump-table call any
; program could invoke on itself). Instead, this program's job is:
; read a command line, tokenize it into an argv table (quoting and
; backslash-escaping aware -- see not_drive_cmd below), resolve
; argv[0] to a path AND CONFIRM IT EXISTS (bare name -> "/bin/"+name
; on the active drive, falling back to the shell's own drive if not
; found there; a name containing '/' -> used as-is, checked once, no
; fallback -- see the resolution section below for the full search,
; and K_GETSHELLDRIVE's own doc in kernel_api.inc for why the fallback
; exists), write that path plus the argument count and table into the
; fixed RUN_PATH/RUN_ARGC/RUN_ARGV_TABLE addresses, and return -- the
; kernel's own run_loop does the actual loading and running, safely,
; from kernel memory. A command that doesn't exist anywhere is
; reported ("File not found.") entirely here, without ever involving
; run_loop. See kernel.inc's own comment on RUN_PATH/RUN_ARGC/
; RUN_ARGV_TABLE for the full hand-off protocol.
;
; No built-in commands, with one narrow exception: a bare drive letter
; ("C:"/"D:"/"E:"/"F:") is shell syntax, not really a command, and is
; special-cased below to call K_SETDRIVE directly. Every other command
; line is resolved as an external program via the hand-off above. See
; include/kernel_api.inc for the K_GETCURDIR/K_SETCURDIR/K_DIR_OPEN/
; K_DIR_READ calls other programs use instead of reaching into kernel
; internals.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

; lib/env.asm's env_getenv, for $FOO/${FOO} expansion (shell_expand_line,
; below) -- linked in via a new multi-file Makefile rule for bin/shell,
; matching the existing bin/ls/bin/more/bin/edlin pattern for the same
; library.
            extrn   env_getenv

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; a batch script (see K_BATCH_START below) is remembered by
            ; the KERNEL, not this program -- this program is reloaded
            ; fresh every single cycle, so it has no memory of its own
            ; that would survive from one batch line to the next.
            ; Checking here, first, means every later branch that loops
            ; back to "start" (empty line, drive switch, file-not-
            ; found, ...) naturally advances to the next batch line for
            ; free, with no special-casing needed anywhere else in this
            ; file.
            call    K_BATCH_READLINE
            lbdf    start_interactive   ; no batch active: read the
                                        ; console as normal

            ; --- '@' prefix: suppresses the echo of just this ONE
            ; line, matching real MS-DOS ("@command" works on any
            ; batch line, not just "echo off" -- RUN_BATCH_ECHO_OFF,
            ; checked just below, is the OTHER, persistent half of
            ; this same idiom: "@echo off" is just "@" applied to a
            ; real "echo off" invocation, which itself sets that flag
            ; for every SUBSEQUENT line). Must be stripped from
            ; LINE_BUF regardless of the echo decision, since every
            ; later stage (the pipe scanner, the tokenizer, command
            ; resolution) needs to see the line exactly as if '@' had
            ; never been there.
            mov     rf, LINE_BUF
            ldn     rf
            xri     '@'
            lbnz    start_check_echo_off

            ; shift the rest of the line left by one byte, including
            ; its own NUL terminator, overwriting the '@' -- standard
            ; in-place left-shift, same convention as not_drive_cmd's
            ; own tokenizer already uses for its in-place mutation
            mov     rd, rf              ; RD = write cursor (the '@'
                                        ; position, about to be
                                        ; overwritten)
            inc     rf                  ; RF = read cursor (the byte
                                        ; right after '@')
start_strip_at:
            lda     rf
            str     rd
            inc     rd
            lbnz    start_strip_at      ; loop until the NUL itself was
                                        ; copied (completing the shift)

            lbr     start_have_line     ; skip the echo entirely for
                                        ; this one line

start_check_echo_off:
            mov     rf, RUN_BATCH_ECHO_OFF
            ldn     rf
            lbnz    start_have_line     ; persistent echo-off mode:
                                        ; skip the echo

            ; expand %ERRORLEVEL%/%0-%9/$FOO/${FOO} BEFORE the echo
            ; below, so batch echo shows the SAME text the command
            ; actually runs with (matches real DOS -- confirmed via
            ; AskUserQuestion rather than assumed). Every OTHER path
            ; that reaches start_have_line (interactive, '@'-prefixed
            ; batch, echo-off batch) gets expansion from the
            ; unconditional call at start_have_line's own top instead
            ; -- this is the one path where the echo would otherwise
            ; run before that call ever gets a chance.
            call    shell_expand_line
            lbdf    start              ; overflow: message already
                                        ; printed, abandon this line

            call    print_prompt

            mov     rf, LINE_BUF
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     start_have_line

start_interactive:
            call    print_prompt

            call    read_line_with_history  ; owns echo/backspace/
                                        ; Up-Down recall itself -- see
                                        ; its own header comment. Same
                                        ; contract K_INPUTL had: LINE_BUF
                                        ; filled, NUL-terminated, on
                                        ; return.

            call    K_INMSG
            db      13,10,0

            call    hist_append         ; best-effort; no-op for a
                                        ; blank line

start_have_line:
            ; expand %ERRORLEVEL%/%0-%9/$FOO/${FOO}. Unconditional --
            ; covers interactive lines, '@'-prefixed batch lines (which
            ; skip the echo and jump straight here), and echo-off batch
            ; lines. The one remaining path (an ordinary batch line
            ; WITH echo firing) already called this once, above, before
            ; its own echo -- shell_expand_line's own Step 1 trigger
            ; scan makes a second call here a cheap no-op in that case
            ; (nothing left to expand), not a correctness problem.
            call    shell_expand_line
            lbdf    start              ; overflow: message already
                                        ; printed, abandon this line

            ; skip leading whitespace
            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char

            ; empty line? just re-prompt -- no kernel round-trip needed
            ldn     rf
            lbz     start

            ; --- label line (":name"), matching real DOS's own batch
            ; label syntax. Only ever meaningful as a GOTO target
            ; (see K_BATCH_GOTO/check_special below) -- reached via
            ; ordinary top-to-bottom flow, a label is silently skipped
            ; entirely, never echoed, never treated as a command,
            ; exactly like REM or a blank line. Checked before REM
            ; (order between the two doesn't matter, they're mutually
            ; exclusive first-character checks) and before the pipe
            ; scanner/tokenizer for the same reason REM is.
            ldn     rf
            xri     ':'
            lbz     start

            ; --- REM: a line comment, matching real DOS's REM. Checked
            ; before the pipe scanner/tokenizer so "REM foo | bar" is
            ; correctly treated as pure comment text, not a pipe. Skips
            ; the whole line entirely -- no argv resolution attempted,
            ; no "File not found." risk from a nonexistent "REM"
            ; program. Works for both batch and interactive lines,
            ; matching real DOS where a bare typed "REM ..." is also a
            ; legal no-op, not an error. Case-insensitive, and must be
            ; a whole word ("REM" followed by a space or end-of-line,
            ; not a prefix of some other word like "REMOVE"). RF stays
            ; at the trimmed line start throughout -- RB is used as the
            ; scan cursor so the pipe-scanner/tokenizer below still see
            ; RF untouched on the "not REM" path.
            ldn     rf
            ani     $DF
            xri     'R'
            lbnz    start_not_rem
            mov     rb, rf
            inc     rb
            ldn     rb
            ani     $DF
            xri     'E'
            lbnz    start_not_rem
            inc     rb
            ldn     rb
            ani     $DF
            xri     'M'
            lbnz    start_not_rem
            inc     rb
            ldn     rb                  ; 4th char: must be space or
                                        ; NUL for "REM" to be a whole
                                        ; word
            lbz     start               ; NUL: bare "REM" -- skip line
            xri     ' '
            lbz     start               ; space: "REM ..." -- skip line

start_not_rem:
            ; --- pipe check: does this line contain a top-level '|'?
            ; A quote-aware scan (pipe_scan, in the new section below),
            ; deliberately kept separate from the main argv/redirect
            ; tokenizer (not_drive_cmd below) rather than folded into
            ; it -- that tokenizer has already taken two hardware-found
            ; bugs to get right (see tok_special's own comment), and
            ; reusing it here would mean teaching it a third, unrelated
            ; job. RF must reach pipe_scan as its own scan cursor, so
            ; the true line start is stashed to memory first and
            ; reloaded fresh afterward regardless of which way the scan
            ; comes back -- DF from the call survives every instruction
            ; between here and the lbnf below untouched (none of mov/
            ; str/inc/glo/ghi/lda/ldn/phi/plo affect DF on the 1802).
            mov     rb, pipe_line_start
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            call    pipe_scan           ; DF=0/RF=pipe position, DF=1=
                                        ; not found
            mov     rb, pipe_pos
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; pipe_pos = RF (stashed
                                        ; unconditionally, regardless of
                                        ; DF, so handle_pipe can read it
                                        ; fresh without trusting a
                                        ; register)

            mov     rf, pipe_line_start
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = trimmed line start again

            lbnf    handle_pipe         ; DF=0: a top-level '|' was found

            ; bare drive-letter command ("C:"/"D:"/"E:"/"F:", case-
            ; insensitive, nothing else on the line) switches the
            ; active drive directly via K_SETDRIVE -- a narrow,
            ; deliberate exception to "no shell built-ins" (a drive
            ; letter is shell syntax, not really a command, the same
            ; category as the mandatory path/tail tokenizing this
            ; shell already does). Never goes through K_PROG_LOAD, and
            ; CD (progs/cd.asm) never calls K_SETDRIVE -- this is the
            ; ONLY place the active drive ever changes (classic DOS
            ; semantics, see kernel.asm's kernel_setdrive comment).
            ldn     rf
            ani     $DF                 ; uppercase-fold (safe: see
                                        ; path.asm's identical check
                                        ; for why no other byte value
                                        ; aliases into 'C'-'F')
            smi     'C'
            lbnf    not_drive_cmd       ; < 'C': not a drive letter
            smi     4
            lbdf    not_drive_cmd       ; >= 'G': not a drive letter

            mov     rb, rf
            inc     rb
            ldn     rb                  ; D = second character
            xri     ':'
            lbnz    not_drive_cmd       ; no ':' following

            inc     rb
            ldn     rb                  ; D = third character
            lbnz    not_drive_cmd       ; more after "X:": not a bare
                                        ; drive command -- fall through
                                        ; to normal name resolution

            ; valid bare drive command -- recompute the index (0-3)
            ; fresh (the smi chain above destroyed D) and switch
            ldn     rf
            ani     $DF
            smi     'C'
            call    K_SETDRIVE
            lbdf    bad_drive

            lbr     start               ; re-prompt

bad_drive:
            call    K_INMSG
            db      "Invalid drive.",13,10,0
            lbr     start

;------------------------------------------------------------------
; shell_is_ident_start / shell_is_ident_continue: environment-variable
; name character classification for $FOO/${FOO} (shell_expand_line,
; below). Split into two small, narrow-clobber ("D only") subroutines
; rather than one combined check, since the name's first character and
; its later characters use different rules (a name can't START with a
; digit, matching bash -- deliberately avoids any ambiguity with %1's
; different sigil). "ani $DF" folds a lowercase letter to uppercase
; for the range check; confirmed safe here the same way the drive-
; letter check and the (now-retired) inline %ERRORLEVEL% match already
; established: a digit folds to a value that still falls outside
; 'A'-'Z' (0x30-0x39 -> 0x10-0x19), and '_' (0x5F) already has bit 5
; clear, so folding leaves it unchanged and still outside 'A'-'Z' --
; neither is ever misclassified as a letter by this fold.
;------------------------------------------------------------------
; Args:    R7 = pointer to the character to check (not advanced)
; Returns: DF = 0 if it's A-Z/a-z/'_', DF = 1 otherwise
; Modifies: D only
;------------------------------------------------------------------
shell_is_ident_start:
            ldn     r7
            ani     $DF
            smi     'A'
            lbnf    sis_check_us
            smi     26
            lbdf    sis_check_us
            clc
            rtn
sis_check_us:
            ldn     r7
            xri     '_'
            lbnz    sis_no
            clc
            rtn
sis_no:
            stc
            rtn

;------------------------------------------------------------------
; Args:    R7 = pointer to the character to check (not advanced)
; Returns: DF = 0 if it's A-Z/a-z/0-9/'_', DF = 1 otherwise
; Modifies: D only
;------------------------------------------------------------------
shell_is_ident_continue:
            ldn     r7
            ani     $DF
            smi     'A'
            lbnf    sic_check_digit
            smi     26
            lbdf    sic_check_digit
            clc
            rtn
sic_check_digit:
            ldn     r7
            smi     '0'
            lbnf    sic_check_us
            smi     10
            lbdf    sic_check_us
            clc
            rtn
sic_check_us:
            ldn     r7
            xri     '_'
            lbnz    sic_no
            clc
            rtn
sic_no:
            stc
            rtn

;------------------------------------------------------------------
; shell_expand_line: %ERRORLEVEL%/%0-%9/$FOO/${FOO} substitution.
; Runs BEFORE the ordinary tokenizer (not_drive_cmd, below), producing
; a fully-expanded line back in LINE_BUF for it to process exactly as
; today -- quote-stripping/escape-collapsing are NOT done here, this
; pass only replaces %/$ tokens verbatim, leaving quote characters and
; backslash-escapes untouched for the real tokenizer to handle
; afterward.
;
; Step 1 (trigger scan): determine the line's total length (via
; shell_strlen) and whether ANY eligible (unescaped, not inside
; '...') % or $ exists anywhere in it, tracking quote/escape state
; with the same 3-state (none/squote/dquote) shape the real tokenizer
; already uses in its own R8.0, just for gating here rather than
; stripping. If nothing eligible is found: returns immediately, DF=0,
; LINE_BUF untouched -- the common case pays only this one cheap scan.
;
; Step 2 (relocate, only if Step 1 found something): move the line's
; current content to the end of LINE_BUF's own 128 bytes, RESERVING
; THE VERY LAST BYTE (offset 127) as an explicit NUL sentinel --
; content occupies [127-length .. 126], one byte less budget than the
; naive "128 total" in exchange for every scan in Step 3 being able to
; rely on hitting a real NUL when it runs out of real content, exactly
; like the ordinary tokenizer's own established idiom, instead of
; needing a separate bounds-tracked countdown. Copies from the highest
; address down to the lowest -- REQUIRED for correctness once the line
; is over half of 127 bytes (source/destination ranges overlap, and a
; forward copy would corrupt not-yet-copied source bytes); independently
; Python-verified byte-for-byte across every length 0..126 before
; trusting this, including confirming a forward copy really does
; self-corrupt for the overlapping case.
;
; Step 3 (expand): read cursor (RF) starts at the relocated content,
; write cursor (RD) at LINE_BUF+0. Copies bytes through; on an
; eligible %/$, dispatches to %ERRORLEVEL% (direct RUN_ERRORLEVEL
; read, no call)/%<digit> (K_BATCH_ARGS_GETARG)/${FOO} or $FOO
; (env_getenv), copying the replacement instead of the original token.
; Checked after EVERY byte written, not just per token (a long
; replacement value could otherwise walk RD past RF's CURRENT
; position -- and past LINE_BUF's own physical end -- mid-copy, before
; a boundary-only check ever ran): if RD ever reaches or passes RF,
; the expanded line doesn't fit -- prints an error and returns DF=1,
; aborting the line entirely. Independently Python-simulated (as
; literal translated instructions, not reimplemented intent) across
; many cases including the exact byte-level boundary and multi-
; substitution accumulation before trusting this.
;
; No recursive re-expansion: a copied replacement's own bytes are
; never re-scanned for further %/$ -- the outer scan resumes right
; after the substitution token consumed from RF. Matches bash/DOS's
; own non-recursive default.
;
; Args:    none (operates on LINE_BUF as a whole)
; Returns: DF = 0 (LINE_BUF now holds the fully-expanded, still NUL-
;          terminated line -- possibly byte-identical to its input, if
;          nothing needed expanding), DF = 1 (overflow -- message
;          already printed, caller should abort the line)
; Modifies: everything (R7, R8, R9, RA, RB, RC, RD, RF, and D) --
;          deliberately NOT documented as safe to carry across a call
;          the way not_drive_cmd's own tokenizer is, since this makes
;          real calls (K_BATCH_ARGS_GETARG, env_getenv, f_uintout)
;          with broad or unconfirmed clobber footprints. Callers must
;          not assume anything survives across this call.
;------------------------------------------------------------------
shell_expand_line:
            mov     rf, LINE_BUF
            call    shell_strlen        ; RC = length, RF unchanged
            mov     rd, shell_expand_len
            ghi     rc
            str     rd
            inc     rd
            glo     rc
            str     rd                  ; shell_expand_len = length

            ; --- Step 1: trigger scan ---
            mov     rf, LINE_BUF
            ldi     0
            plo     r8                  ; R8.0 = quote state (0=none,
                                        ; 1=squote, 2=dquote)
            phi     r8                  ; R8.1 = pending-escape flag
sel_scan_loop:
            ldn     rf
            lbz     sel_scan_notfound   ; end of line: no trigger found

            ghi     r8
            lbz     sel_scan_check      ; not escaped: real dispatch
            ldi     0
            phi     r8                  ; escaped char: clear the
                                        ; flag, not eligible
            lbr     sel_scan_next

sel_scan_check:
            glo     r8
            xri     1
            lbnz    sel_scan_notsq
            ; single-quote mode: only a closing ' matters
            ldn     rf
            xri     '''
            lbnz    sel_scan_next       ; ordinary char in squote:
                                        ; never a trigger
            ldi     0
            plo     r8                  ; close squote
            lbr     sel_scan_next

sel_scan_notsq:
            ; quote state is 0 (none) or 2 (dquote)
            ldn     rf
            xri     '"'
            lbnz    sel_scan_check_sqopen
            glo     r8
            xri     2
            plo     r8                  ; toggle none<->dquote
            lbr     sel_scan_next

sel_scan_check_sqopen:
            glo     r8
            lbnz    sel_scan_check_bs   ; already in dquote: a "'" is
                                        ; just ordinary here
            ldn     rf
            xri     '''
            lbnz    sel_scan_check_bs
            ldi     1
            plo     r8                  ; open squote
            lbr     sel_scan_next

sel_scan_check_bs:
            ldn     rf
            xri     '\'
            lbnz    sel_scan_ordinary
            ldi     $FF
            phi     r8                  ; set pending-escape
            lbr     sel_scan_next

sel_scan_ordinary:
            ldn     rf
            xri     '$'
            lbz     sel_scan_found
            ldn     rf
            xri     '%'
            lbz     sel_scan_found

sel_scan_next:
            inc     rf
            lbr     sel_scan_loop

sel_scan_found:
            lbr     sel_expand_go       ; trigger found: proceed to
                                        ; Step 2/3 below

sel_scan_notfound:
            clc                         ; DF=0: nothing to expand,
                                        ; LINE_BUF already correct
            rtn

sel_expand_go:
            ; --- Step 2: relocate LINE_BUF[0..length-1] to
            ; LINE_BUF[127-length..126], reserving byte 127 as an
            ; explicit NUL sentinel (see this routine's own header) ---
            mov     rf, shell_expand_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = length

            mov     rf, LINE_BUF
            add16   rf, rc
            dec     rf                  ; RF = LINE_BUF + length - 1
                                        ; (last source byte)
            mov     rd, LINE_BUF
            add16   rd, 126             ; RD = last dest byte
                                        ; (LINE_BUF+126)

sel_reloc_loop:
            glo     rc
            lbnz    sel_reloc_have_more
            ghi     rc
            lbz     sel_reloc_done
sel_reloc_have_more:
            ldn     rf
            str     rd
            dec     rf
            dec     rd
            sub16   rc, 1
            lbr     sel_reloc_loop

sel_reloc_done:
            mov     rf, LINE_BUF
            add16   rf, 127
            ldi     0
            str     rf                  ; the NUL sentinel

            ; --- Step 3: expand ---
            mov     rf, shell_expand_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = length (reloaded --
                                        ; Step 2's own RC was
                                        ; decremented to 0)

            mov     rf, LINE_BUF
            add16   rf, 127
            sub16   rf, rc              ; RF = LINE_BUF + 127 - length
                                        ; (the relocated content's
                                        ; start)

            mov     rd, LINE_BUF        ; RD = write cursor

            ldi     0
            plo     r8                  ; quote state = none (fresh
                                        ; for this pass, independent
                                        ; of Step 1's own, already-
                                        ; exhausted, state)
            phi     r8                  ; pending-escape = false

sex_loop:
            ldn     rf
            lbz     sex_done            ; sentinel NUL: done

            ghi     r8
            lbz     sex_check_sq
            ldi     0
            phi     r8
            lbr     sex_copy_one        ; escaped char: copy through
                                        ; unchanged

sex_check_sq:
            glo     r8
            xri     1
            lbnz    sex_check_dq_open
            ldn     rf
            xri     '''
            lbnz    sex_copy_one
            ldi     0
            plo     r8                  ; close squote
            lbr     sex_copy_one        ; the quote char itself is
                                        ; still copied through -- the
                                        ; real tokenizer strips it
                                        ; later, not this pass

sex_check_dq_open:
            ldn     rf
            xri     '"'
            lbnz    sex_check_sqopen
            glo     r8
            xri     2
            plo     r8                  ; toggle none<->dquote
            lbr     sex_copy_one

sex_check_sqopen:
            glo     r8
            lbnz    sex_check_bs
            ldn     rf
            xri     '''
            lbnz    sex_check_bs
            ldi     1
            plo     r8                  ; open squote
            lbr     sex_copy_one

sex_check_bs:
            ldn     rf
            xri     '\'
            lbnz    sex_check_pct
            ldi     $FF
            phi     r8                  ; set pending-escape
            lbr     sex_copy_one        ; the backslash itself is
                                        ; copied through -- the real
                                        ; tokenizer's own \X->X
                                        ; collapsing happens later

sex_check_pct:
            ldn     rf
            xri     '%'
            lbz     sex_percent
            ldn     rf
            xri     '$'
            lbz     sex_dollar
            lbr     sex_copy_one        ; ordinary character

sex_copy_one:
            mov     r7, rd
            sub16   r7, rf
            lbdf    sex_overflow        ; RD >= RF
            ldn     rf
            str     rd
            inc     rd
            inc     rf
            lbr     sex_loop

;--- %ERRORLEVEL% / %<digit> dispatch --------------------------------
sex_percent:
            mov     r7, rf
            inc     r7                  ; R7 = scan cursor, one past
                                        ; the leading '%'
            mov     ra, tok_errlvl_pat  ; reused unchanged from the
                                        ; now-retired inline version
sex_errlvl_cmp:
            ldn     ra
            lbz     sex_errlvl_checktail
            str     r2
            ldn     r7
            ani     $DF
            xor
            lbnz    sex_try_digit       ; mismatch (including hitting
                                        ; the sentinel before the
                                        ; letters are exhausted): try
                                        ; %<digit> instead
            inc     r7
            inc     ra
            lbr     sex_errlvl_cmp

sex_errlvl_checktail:
            ldn     r7
            xri     '%'
            lbnz    sex_try_digit

            inc     r7
            mov     ra, r7              ; RA = new read position (past
                                        ; the whole matched text)

            mov     rb, RUN_ERRORLEVEL
            ldn     rb
            plo     r9
            ldi     0
            phi     r9                  ; R9 = RUN_ERRORLEVEL's value

            push    rf                  ; OLD read position (needed
                                        ; for the overflow check below,
                                        ; and f_uintout is about to
                                        ; clobber RF as its own
                                        ; argument)
            push    ra                  ; NEW read position
            push    rd                  ; write cursor -- MUST be
                                        ; pushed before RD gets
                                        ; overwritten below, since
                                        ; f_uintout's own calling
                                        ; convention takes the VALUE in
                                        ; RD (matching the original,
                                        ; already-proven inline
                                        ; %ERRORLEVEL% code this
                                        ; replaced), not R9 -- REAL BUG
                                        ; found on hardware 2026-07-25:
                                        ; the first draft left RD
                                        ; holding the write cursor and
                                        ; never actually loaded the
                                        ; value into it, so f_uintout
                                        ; silently converted the write
                                        ; CURSOR's own address to
                                        ; decimal instead of the real
                                        ; errorlevel value
            push    r8                  ; quote state

            mov     rd, r9              ; RD = the errorlevel value
            mov     rf, tok_errlvl_buf
            call    f_uintout           ; writes 1-3 decimal digits at
                                        ; *rf, does NOT null-terminate
            ldi     0
            str     rf

            pop     r8
            pop     rd
            pop     ra
            pop     rf                  ; RF = OLD read position

            mov     rb, tok_errlvl_buf
sex_errlvl_copy:
            ldn     rb
            lbz     sex_errlvl_copydone
            mov     r7, rd
            sub16   r7, rf
            lbdf    sex_overflow
            ldn     rb
            str     rd
            inc     rd
            inc     rb
            lbr     sex_errlvl_copy

sex_errlvl_copydone:
            mov     rf, ra
            lbr     sex_loop

sex_try_digit:
            mov     r7, rf
            inc     r7
            ldn     r7
            smi     '0'
            lbnf    sex_percent_literal
            smi     10
            lbdf    sex_percent_literal ; D = (char-'0')-10; DF=1
                                        ; means char-'0' >= 10

            ldn     r7
            smi     '0'
            plo     r9                  ; R9.0 = digit value (0-9)
            ldi     0
            phi     r9

            inc     r7
            mov     ra, r7              ; RA = new read position

            push    rf                  ; OLD read position
            push    ra
            push    rd
            push    r8

            glo     r9
            call    K_BATCH_ARGS_GETARG ; DF=0/RF=value ptr (real or
                                        ; empty), or DF=1 (no batch
                                        ; active at all)
            lbdf    sex_digit_noreplace

            mov     rb, sex_val_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            pop     r8
            pop     rd
            pop     ra
            pop     rf                  ; RF = OLD read position

            mov     rb, sex_val_ptr
            lda     rb
            phi     r9
            ldn     rb
            plo     r9
            mov     rb, r9              ; RB = the value pointer
                                        ; (possibly an empty string)
sex_digit_copy:
            ldn     rb
            lbz     sex_digit_copydone
            mov     r7, rd
            sub16   r7, rf
            lbdf    sex_overflow
            ldn     rb
            str     rd
            inc     rd
            inc     rb
            lbr     sex_digit_copy

sex_digit_copydone:
            mov     rf, ra
            lbr     sex_loop

sex_digit_noreplace:
            pop     r8
            pop     rd
            pop     ra
            pop     rf                  ; RF = OLD read position,
                                        ; restored -- still pointing
                                        ; at the original '%'
            lbr     sex_copy_one        ; copy just the '%' -- the
                                        ; digit is picked up naturally
                                        ; on the next sex_loop
                                        ; iteration

sex_percent_literal:
            lbr     sex_copy_one

;--- ${FOO} / $FOO / env_getenv dispatch -----------------------------
sex_dollar:
            mov     r7, rf
            inc     r7                  ; R7 -> the char right after
                                        ; '$'
            ldn     r7
            xri     '{'
            lbnz    sex_try_bare_dollar

            inc     r7
            mov     r9, r7              ; R9 = name start (right
                                        ; after '{')
sex_brace_scan:
            ldn     r7
            lbz     sex_try_bare_dollar ; hit the sentinel before '}':
                                        ; unterminated -- falls through
                                        ; to the bare-dollar attempt,
                                        ; which also fails (the char
                                        ; right after '$' is '{', not
                                        ; a valid name-start), ending
                                        ; up literal '$' as intended
            xri     '}'
            lbz     sex_brace_found
            inc     r7
            lbr     sex_brace_scan

sex_brace_found:
            ; R7 -> the closing '}', R9 -> name start. New read
            ; position is R7+1 (past the '}').
            mov     ra, r7
            inc     ra
            mov     rb, sex_new_read_pos
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb
            lbr     sex_env_lookup

sex_try_bare_dollar:
            mov     r7, rf
            inc     r7
            call    shell_is_ident_start
            lbdf    sex_dollar_literal  ; not a valid start: literal
                                        ; '$'

            mov     r9, r7              ; R9 = name start
sex_bare_scan:
            ldn     r7
            lbz     sex_bare_scan_done  ; hit sentinel: name ends here
            call    shell_is_ident_continue
            lbdf    sex_bare_scan_done  ; non-identifier char: name
                                        ; ends here
            inc     r7
            lbr     sex_bare_scan

sex_bare_scan_done:
            ; R7 -> one past the name (exclusive), R9 -> name start.
            ; New read position is just R7 (no delimiter to skip).
            mov     rb, sex_new_read_pos
            ghi     r7
            str     rb
            inc     rb
            glo     r7
            str     rb
            lbr     sex_env_lookup

sex_dollar_literal:
            lbr     sex_copy_one

; shared tail for both ${FOO} and bare $FOO -- Args: R9 = name start,
; R7 = name end (exclusive), sex_new_read_pos (memory) = the read
; position once this substitution is applied (already set by the
; caller above).
sex_env_lookup:
            mov     rb, sex_envname_buf
sex_env_namecopy:
            glo     r9
            str     r2
            glo     r7
            sm
            lbnz    sex_env_namecopy_go
            ghi     r9
            str     r2
            ghi     r7
            sm
            lbz     sex_env_namecopy_done
sex_env_namecopy_go:
            ldn     r9
            str     rb
            inc     rb
            inc     r9
            lbr     sex_env_namecopy
sex_env_namecopy_done:
            ldi     0
            str     rb                  ; NUL-terminate the name

            push    rf                  ; OLD read position
            push    rd                  ; write cursor
            push    r8                  ; quote state -- sex_new_read_pos
                                        ; is already in memory, safe
                                        ; across any call with no
                                        ; push/pop needed

            mov     rf, sex_envname_buf
            call    env_getenv          ; RF = value ptr, or 0 if unset

            mov     rb, sex_val_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            pop     r8
            pop     rd
            pop     rf                  ; RF = OLD read position

            mov     rb, sex_val_ptr
            lda     rb
            phi     r9
            ldn     rb
            plo     r9

            glo     r9
            lbnz    sex_env_haveval
            ghi     r9
            lbnz    sex_env_haveval
            lbr     sex_env_done        ; unset: nothing to copy

sex_env_haveval:
            mov     rb, r9
sex_env_copy:
            ldn     rb
            lbz     sex_env_done
            mov     r7, rd
            sub16   r7, rf
            lbdf    sex_overflow
            ldn     rb
            str     rd
            inc     rd
            inc     rb
            lbr     sex_env_copy

sex_env_done:
            mov     rf, sex_new_read_pos
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9              ; RF = the new read position
            lbr     sex_loop

sex_overflow:
            call    K_INMSG
            db      "Line too long after substitution.",13,10,0
            stc
            rtn

sex_done:
            ldi     0
            str     rd                  ; NUL-terminate the fully
                                        ; expanded line
            clc
            rtn

shell_expand_len:      dw      0
sex_new_read_pos:      dw      0
sex_val_ptr:            dw      0
sex_envname_buf:        ds      40

not_drive_cmd:
            ; RF = start of the trimmed line (program name onward).
            ; Tokenize the whole line in place inside LINE_BUF, quoting
            ; and backslash-escaping aware, building the argv table
            ; (RUN_ARGV_TABLE) and counting argc as it goes. Two quote
            ; styles, matching bash: "..." (spaces preserved, \X ->
            ; literal X still works inside or outside) and '...'
            ; (spaces preserved, 100% literal -- added 2026-07-19, not
            ; even \X is special inside single quotes). Either can open
            ; a quoted argument; neither is recognized while inside the
            ; other (a '"' inside '...' or a "'" inside "..." is just
            ; an ordinary character).
            ; No kernel/BIOS calls happen anywhere in this loop, so
            ; register state is safe to carry across iterations with no
            ; memory stashing needed (unlike most of the rest of this
            ; file). See kernel.inc's RUN_ARGC/RUN_ARGV_TABLE comment
            ; for the full hand-off protocol this feeds.
            ;
            ; Registers: RF = read cursor, RD = write cursor (always
            ; <= RF, since quote chars are dropped and every escape
            ; collapses 2 source bytes into 1 output byte -- safe to
            ; write back into LINE_BUF in place), RB = next argv-table
            ; slot to fill, R9.0 = argc, R8.0 = in_quotes flag (0/$FF)
            ; for the token currently being scanned.
            mov     rd, rf              ; RD = start of the trimmed
                                        ; line (captured before RF is
                                        ; reused as scratch below)

            ; reset the I/O-redirection relay slots before tokenizing
            ; -- RUN_REDIR_OUT/RUN_REDIR_IN are fixed addresses below
            ; PROG_BASE, not part of the kernel's own zeroed data
            ; section, so they hold uninitialized RAM on first boot and
            ; whatever a PRIOR command's redirect left behind
            ; otherwise. Only the tok_redir_out/tok_redir_in paths
            ; below ever WRITE them, so an ordinary command with no
            ; `>`/`<` at all needs this explicit reset every pass, or
            ; _redir_setup (kernel/redir.asm) misreads stale/garbage
            ; data as a real redirect request -- exactly the "Cannot
            ; redirect." bug hit on hardware (2026-07-16) testing a
            ; plain "dir" with no redirection at all.
            mov     rf, RUN_REDIR_OUT
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, RUN_REDIR_IN
            ldi     0
            str     rf
            inc     rf
            str     rf

            mov     rf, rd              ; RF restored = start of the
                                        ; trimmed line
            mov     rb, RUN_ARGV_TABLE
            ldi     0
            plo     r9

tok_next:
tok_skip_ws:
            ldn     rf
            xri     ' '
            lbnz    tok_check_end
            inc     rf
            lbr     tok_skip_ws

tok_check_end:
            ldn     rf
            lbz     tok_done            ; end of line: no more tokens

            ; a `>`/`<` here starts a redirect operator, not an
            ; ordinary argv token -- neither counts against argc/
            ; ARGV_MAX_ARGS nor gets written into argv[]. D still
            ; holds *RF from the ldn above (lbz doesn't touch D).
            xri     '>'
            lbz     tok_redir_out
            ldn     rf
            xri     '<'
            lbz     tok_redir_in

            glo     r9
            smi     ARGV_MAX_ARGS
            lbdf    tok_done            ; already have ARGV_MAX_ARGS
                                        ; tokens -- ignore anything left
                                        ; on the line rather than
                                        ; overflowing the table

            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb                  ; argv_table[argc] = RD (this
                                        ; token's first byte), RB ->
                                        ; next slot

            ldi     0
            phi     r8                  ; R8.1 = 0: ordinary argv
                                        ; token -- tok_end_token below
                                        ; increments argc normally
            lbr     tok_char_entry

tok_redir_out:
            inc     rf                  ; consume '>'
            ldn     rf
            xri     '>'
            lbnz    tok_redir_out_trunc
            inc     rf                  ; consume the second '>' (append)
            mov     r7, RUN_REDIR_OUT_APPEND
            ldi     1
            str     r7
            lbr     tok_redir_out_settarget
tok_redir_out_trunc:
            mov     r7, RUN_REDIR_OUT_APPEND
            ldi     0
            str     r7
tok_redir_out_settarget:
            mov     r7, RUN_REDIR_OUT
            lbr     tok_redir_skip_ws

tok_redir_in:
            inc     rf                  ; consume '<'
            mov     r7, RUN_REDIR_IN
                                        ; fall through

tok_redir_skip_ws:
            ; RF -> just past the operator; skip optional whitespace
            ; before the filename token (">file" and "> file" both work)
            ldn     rf
            xri     ' '
            lbnz    tok_redir_capture
            inc     rf
            lbr     tok_redir_skip_ws

tok_redir_capture:
            ; R7 -> the relay slot (RUN_REDIR_OUT or RUN_REDIR_IN) to
            ; fill with RD's current value -- this token's about-to-be-
            ; scanned start, mirroring the argv[argc]=RD capture the
            ; ordinary-token path does above, just writing somewhere
            ; else and never touching argc/RB. If the same operator
            ; appears twice on one line, the later one simply
            ; overwrites the slot -- last one wins, no special-casing
            ; needed.
            ghi     rd
            str     r7
            inc     r7
            glo     rd
            str     r7

            ldi     $FF
            phi     r8                  ; R8.1 = nonzero: this token IS
                                        ; a redirect target -- tok_end_token
                                        ; below must skip the argc++
                                        ; (a missing filename, e.g. a
                                        ; trailing ">" with nothing
                                        ; after it, still lands here and
                                        ; produces an empty-string
                                        ; target -- left to fail
                                        ; naturally via _redir_setup's
                                        ; own file_open error path
                                        ; rather than special-cased here)

tok_char_entry:
            ldi     0
            plo     r8                  ; in_quotes = false (R8.0 --
                                        ; unchanged from the original
                                        ; design; R8.1, set above on
                                        ; both paths before reaching
                                        ; here, is the new redirect-
                                        ; target flag)

tok_char:
            ldn     rf
            lbz     tok_end_token       ; end of line ends the token
                                        ; too -- also correctly closes
                                        ; an unterminated quote here,
                                        ; since this check runs before
                                        ; the in_quotes check below

            glo     r8
            lbnz    tok_special         ; in quotes: space doesn't end
                                        ; the token, fall into the
                                        ; quote/backslash/ordinary
                                        ; dispatch below directly

            ldn     rf
            xri     ' '
            lbz     tok_space_end       ; not in quotes, hit a space:
                                        ; token ends
            lbr     tok_special         ; BUG FIX (hardware-found): not
                                        ; a space either -- must jump
                                        ; to tok_special explicitly.
                                        ; Without this branch, the "not
                                        ; a space" case fell straight
                                        ; through into tok_space_end's
                                        ; own body below (inc rf + jump
                                        ; to tok_end_token), silently
                                        ; skipping every ordinary
                                        ; character instead of copying
                                        ; it and ending the "token"
                                        ; after every single character
                                        ; -- exactly matching the
                                        ; hardware symptom (argc=7 for
                                        ; a 4-word line, mostly-zeroed
                                        ; LINE_BUF where real content
                                        ; should have been copied).

tok_space_end:
            ; BUG FIX (hardware-found): consume the space HERE, before
            ; falling into tok_end_token below, instead of the
            ; original design (leave RF pointing AT the space, for
            ; tok_skip_ws to consume on the next pass). For a token
            ; with no quote/escape shrinkage (e.g. a plain word like
            ; "args"), the write cursor RD equals the read cursor RF
            ; at exactly this point -- so tok_end_token's NUL-
            ; terminator write (via RD) would land on the SAME byte
            ; this space occupies, silently turning the space into a
            ; second NUL before anything ever got a chance to read it
            ; as a real space. The very next check (either here or in
            ; tok_end_token) would then see that NUL and conclude the
            ; whole line had ended, capping every multi-argument
            ; command at just argv[0] -- confirmed via a "TOK argc="
            ; hardware diagnostic showing 1 regardless of how many
            ; words were actually typed. Advancing RF past the space
            ; NOW means RD (which hasn't moved yet) can never coincide
            ; with RF again for the rest of this token's cleanup, so
            ; the terminator write is always safe.
            inc     rf
            lbr     tok_end_token

tok_special:
            ; R8.0 holds the current quote state: 0 = not in any quote,
            ; $FF = inside "..." (backslash-escaping active -- this
            ; project's original double-quote convention, unchanged),
            ; $01 = inside '...' (added 2026-07-19: true bash semantics
            ; -- 100% literal, not even a backslash is special inside a
            ; single-quoted string). Single-quote mode is checked first
            ; and handled by its own much simpler path below, since
            ; nothing except the matching close-quote can end it.
            glo     r8
            xri     $01
            lbz     tok_in_squote

            ldn     rf
            xri     '"'
            lbnz    tok_check_sq_open
            glo     r8
            xri     $FF
            plo     r8                  ; toggle double-quote mode
                                        ; (0 <-> $FF -- r8 is guaranteed
                                        ; to already be one of those two
                                        ; here, single-quote mode having
                                        ; been routed away above)
            inc     rf                  ; consume the quote char itself
                                        ; -- not copied to the output
            lbr     tok_char

tok_check_sq_open:
            ; a "'" only OPENS single-quote mode when not already
            ; inside "..." -- matching bash, where a single quote has
            ; no special meaning inside a double-quoted string (falls
            ; through to the ordinary backslash-escape/copy path below,
            ; same as any other character would inside "...")
            glo     r8
            lbnz    tok_check_bs
            ldn     rf
            xri     '''
            lbnz    tok_check_bs
            ldi     $01
            plo     r8                  ; enter single-quote mode
            inc     rf                  ; consume the quote char itself
            lbr     tok_char

tok_check_bs:
            ldn     rf
            xri     '\'
            lbnz    tok_ordinary_plain

            inc     rf                  ; skip the backslash
            ldn     rf
            lbz     tok_bs_eol          ; trailing lone backslash at
                                        ; end of line: nothing to
                                        ; escape -- treat the backslash
                                        ; itself as literal

            str     rd                  ; write the escaped char
                                        ; literally (D is still fresh
                                        ; from the ldn two lines up --
                                        ; lbz doesn't touch D whether
                                        ; taken or not)
            inc     rd
            inc     rf
            lbr     tok_char

tok_bs_eol:
            ldi     '\'
            str     rd
            inc     rd
            lbr     tok_end_token       ; RF is already at the NUL

tok_in_squote:
            ; true bash semantics: everything up to the matching close
            ; quote is copied 100% literally -- no backslash-escaping,
            ; no recognizing '"' either. Only the matching "'" is
            ; special (closes the quote, itself not copied).
            ldn     rf
            xri     '''
            lbnz    tok_ordinary_plain
            ldi     0
            plo     r8                  ; close single-quote mode
            inc     rf                  ; consume the quote char itself
            lbr     tok_char

; NOTE: %ERRORLEVEL% substitution used to live here, woven directly
; into this tokenizer's own character scan. Retired 2026-07-25 (%1-%9/
; $FOO/${FOO} substitution pass) -- moved into shell_expand_line, a
; separate pass that now runs BEFORE this tokenizer, so %ERRORLEVEL%/
; %0-%9/$FOO/${FOO} all share one mechanism instead of leaving this one
; as a special case. tok_errlvl_pat/tok_errlvl_buf (below) are reused
; by that new code, unchanged.
tok_ordinary_plain:
            ldn     rf
            str     rd
            inc     rd
            inc     rf

tok_ordinary_next:
            lbr     tok_char

tok_end_token:
            ; Reached three ways: (1) tok_char's own "*RF is NUL"
            ; check -- RF already at the true end of line; (2)
            ; tok_space_end above -- RF already advanced past the
            ; space that ended this token; (3) tok_bs_eol -- RF
            ; already at the true end of line. In every case RF now
            ; either points past where RD is about to write, or *RF is
            ; already 0 (so writing another 0 there changes nothing)
            ; -- so a plain post-write read of *RF below is always
            ; safe (see tok_space_end's own comment for the hardware
            ; bug this design replaced, where that wasn't true).
            ldi     0
            str     rd                  ; NUL-terminate this token
            inc     rd

            ghi     r8
            lbnz    tok_end_redir       ; this token was a redirect
                                        ; target (>file/<file), not an
                                        ; ordinary argv entry -- skip
                                        ; the argc++ below, it was
                                        ; never written into argv[]

            glo     r9
            adi     1
            plo     r9                  ; argc++

tok_end_redir:
            ldn     rf
            lbz     tok_done            ; that was the last char on
                                        ; the line
            lbr     tok_next

tok_done:
            ; publish argc, and reload RA = argv[0]'s pointer -- the
            ; path-resolution code right below (scan_slash/have_slash/
            ; no_slash) already expects RA to hold the program name's
            ; pointer exactly as before, so it needs no changes at all
            mov     rf, RUN_ARGC
            ldi     0
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; NOTE (2026-07-27): this used to also call glob_expand
            ; here, rewriting RUN_ARGC/RUN_ARGV_TABLE in place to
            ; expand any "*"/"?" wildcard token before a command was
            ; ever resolved -- removed entirely, along with the whole
            ; glob_expand/ge_*/glob_match block that used to live
            ; further down this file. Wildcard expansion is now the
            ; job of individual glob-AWARE programs (COPY/DEL/MOVE/
            ; ATTRIB/DIR/LS), via the new lib/file_glob.asm
            ; (is_glob/glob_init/glob_next), not the shell's own
            ; tokenizer -- see that file's own header for the full
            ; redesign rationale (the old design's hard ARGV_MAX_ARGS
            ; ceiling silently truncated a directory with more than
            ; ~15 matches). A wildcard pattern now passes through
            ; exactly like any other token, unexpanded.
            mov     rf, RUN_ARGV_TABLE
            lda     rf
            phi     ra
            ldn     rf
            plo     ra

;------------------------------------------------------------------
; check_special: IF/GOTO dispatch, reached once per resolved argv[]
; (looping back here again if IF's own condition is true -- see
; below). Neither IF nor GOTO is an ordinary program: IF conditionally
; re-dispatches an ALREADY-TOKENIZED, shifted view of its own argv[]
; (rather than a program launching another program, which nothing in
; this codebase can do -- see this file's own header on why the shell
; hands off through the kernel instead); GOTO repositions the active
; batch script via K_BATCH_GOTO and never "runs" anything itself.
;------------------------------------------------------------------
check_special:
            mov     rf, ra
            mov     rd, if_pat_if
            call    shell_match_word
            lbnf    if_start

            mov     rf, ra
            mov     rd, if_pat_goto
            call    shell_match_word
            lbnf    goto_start

            lbr     scan_slash          ; neither -- ordinary command,
                                        ; resolve argv[0] normally

;------------------------------------------------------------------
; GOTO <label>
;------------------------------------------------------------------
goto_start:
            mov     rf, RUN_ARGC
            inc     rf
            ldn     rf
            smi     2
            lbnf    goto_usage          ; argc < 2: missing label

            ldi     1
            call    argv_at             ; RF = argv[1] (the label)
            call    K_BATCH_GOTO
            lbdf    goto_notfound
            lbr     start

goto_notfound:
            call    K_INMSG
            db      "Label not found.",13,10,0
            lbr     start

goto_usage:
            call    K_INMSG
            db      "Usage: GOTO <label>",13,10,0
            lbr     start

;------------------------------------------------------------------
; IF [NOT] EXIST <path> <command>
; IF [NOT] <str1>==<str2> <command>
;------------------------------------------------------------------
if_start:
            mov     rf, if_argc
            mov     rd, RUN_ARGC
            inc     rd
            ldn     rd
            str     rf                  ; if_argc = argc (low byte --
                                        ; argc is always < ARGV_MAX_ARGS,
                                        ; comfortably fits)

            mov     rf, if_idx
            ldi     1
            str     rf                  ; start parsing at argv[1]

            mov     rf, if_negate
            ldi     0
            str     rf

            call    if_check_bounds     ; need argv[1] to exist at all
            lbdf    if_usage

            mov     rf, if_idx
            ldn     rf
            call    argv_at             ; RF = argv[if_idx]
            mov     rd, if_pat_not
            call    shell_match_word
            lbdf    if_check_exist      ; not NOT -- try EXIST next
                                        ; (RF still = argv[if_idx],
                                        ; shell_match_word's own
                                        ; contract: unchanged on DF=1)

            mov     rf, if_negate
            ldi     1
            str     rf
            mov     rf, if_idx
            ldn     rf
            adi     1
            str     rf                  ; if_idx++ (consumed NOT)

            call    if_check_bounds     ; need the EXIST/str token too
            lbdf    if_usage

            mov     rf, if_idx
            ldn     rf
            call    argv_at             ; RF = argv[if_idx] (refreshed
                                        ; -- NOT's own consumption moved
                                        ; if_idx, the old RF is stale)

if_check_exist:
            mov     rd, if_pat_exist
            call    shell_match_word
            lbdf    if_streq            ; not EXIST -- str1==str2 form
                                        ; (RF still = argv[if_idx])

            ; --- EXIST form ---
            mov     rf, if_idx
            ldn     rf
            adi     1
            str     rf                  ; if_idx++ (consumed "EXIST")

            call    if_check_bounds     ; need the path argument
            lbdf    if_usage

            mov     rf, if_idx
            ldn     rf
            call    argv_at             ; RF = argv[if_idx] (the path)
            mov     rd, stat_result
            call    K_STAT              ; DF=0 found, DF=1 not found --
                                        ; reuses the SAME scratch buffer
                                        ; check_exists uses later this
                                        ; same cycle, not live yet here

            ; REAL BUG (found 2026-07-25, reviewing a hardware report):
            ; the "if_idx++ (consumed the path)" adi used to sit HERE,
            ; between K_STAT and the DF check below -- but ADI sets DF
            ; from its OWN carry, silently overwriting K_STAT's real
            ; result before it was ever read. For any realistic if_idx
            ; (always tiny, nowhere near 255) that add never carries,
            ; so DF always came out 0 regardless of what K_STAT
            ; actually returned -- capture DF into D immediately, THEN
            ; do the increment.
            ldi     1
            lbnf    if_exist_have       ; DF=0 (found): keep D=1
            ldi     0                   ; DF=1 (not found): D=0
if_exist_have:
            str     r2

            mov     rf, if_idx
            ldn     rf
            adi     1
            str     rf                  ; if_idx++ (consumed the path)
                                        ; -- moved to AFTER the DF
                                        ; capture above, see this
                                        ; block's own comment

            mov     rf, if_negate
            ldn     rf
            xor                         ; D = found XOR negate
            lbr     if_have_condition

;------------------------------------------------------------------
; str1==str2 form -- RF still points at the token (if_check_exist's
; own preceding shell_match_word left it unchanged on its DF=1 return)
;------------------------------------------------------------------
if_streq:
            mov     r7, rf              ; R7 = scan cursor, hunting for
                                        ; the first "=="
if_eq_loop:
            ldn     r7
            lbz     if_usage            ; reached NUL, no "==" anywhere
                                        ; -- malformed IF
            xri     '='
            lbnz    if_eq_next
            mov     r8, r7              ; candidate first '='
            inc     r7
            ldn     r7
            xri     '='
            lbz     if_eq_found
            lbr     if_eq_loop          ; not a real "==" -- r7 is
                                        ; already one past the lone
                                        ; '=', continue scanning from
                                        ; there, nothing skipped
if_eq_next:
            inc     r7
            lbr     if_eq_loop

if_eq_found:
            inc     r7                  ; r7 = right-side start (past
                                        ; both '=' characters)
            mov     r9, rf              ; r9 = left-side cursor
            sub16   r8, r9              ; r8 = left_len (register-
                                        ; register sub16 -- safe per
                                        ; gotcha #18, M(R2) isn't used
                                        ; concurrently here)
if_eq_cmp:
            glo     r8
            lbz     if_eq_rightonly     ; left exhausted
            ldn     r9                  ; left char (guaranteed real,
                                        ; non-NUL token byte)
            str     r2
            ldn     r7                  ; right char
            lbz     if_eq_false         ; right hit NUL early: not equal
            xor
            lbnz    if_eq_false
            inc     r9
            inc     r7
            dec     r8
            lbr     if_eq_cmp

if_eq_rightonly:
            ldn     r7
            lbz     if_eq_true          ; right ALSO exhausted: equal
            lbr     if_eq_false

if_eq_true:
            ldi     1
            lbr     if_eq_have
if_eq_false:
            ldi     0
if_eq_have:
            str     r2

            mov     rf, if_idx
            ldn     rf
            adi     1
            str     rf                  ; if_idx++ (consumed the
                                        ; str1==str2 token)

            mov     rf, if_negate
            ldn     rf
            xor                         ; D = equal XOR negate
            lbr     if_have_condition

;------------------------------------------------------------------
; if_have_condition: D = 0/nonzero from either branch above
;------------------------------------------------------------------
if_have_condition:
            lbz     if_condition_false

            ; --- condition TRUE: shift argv[if_idx..] down to
            ; argv[0..], update RUN_ARGC, reload RA, re-enter
            ; check_special (this is what makes "IF EXIST x GOTO y"
            ; work -- IF's own true branch lands right back on GOTO's
            ; own check, and for free supports a chained "IF ... IF
            ; ... command" too, the same loop either way)
            mov     rf, if_idx
            ldn     rf
            str     r2
            mov     rf, if_argc
            ldn     rf
            sm                          ; D = if_argc - if_idx = new argc
            plo     r9
            mov     rf, RUN_ARGC
            inc     rf
            glo     r9
            str     rf                  ; RUN_ARGC (low byte) = new argc

            mov     rf, if_idx
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; r8 = if_idx * 2 (byte offset)
            mov     r7, RUN_ARGV_TABLE
            add16   r7, r8              ; r7 = &argv_table[if_idx] (src)
            mov     r8, RUN_ARGV_TABLE  ; r8 = &argv_table[0] (dst)

            glo     r9                  ; D = new argc (still fresh --
                                        ; nothing has touched r9 since)
            shl                         ; D = new_argc * 2 (copy_bytes
                                        ; -- always < 2*ARGV_MAX_ARGS,
                                        ; comfortably fits in a byte)
            plo     rc

if_shift_loop:
            glo     rc
            lbz     if_shift_done
            lda     r7
            str     r8
            inc     r8
            dec     rc
            lbr     if_shift_loop
if_shift_done:

            mov     rf, RUN_ARGV_TABLE
            lda     rf
            phi     ra
            ldn     rf
            plo     ra

            lbr     check_special

if_condition_false:
            lbr     start

if_usage:
            call    K_INMSG
            db      "Usage: IF [NOT] EXIST <path> <command>",13,10,0
            call    K_INMSG
            db      "       IF [NOT] <str1>==<str2> <command>",13,10,0
            lbr     start

;------------------------------------------------------------------
; if_check_bounds: is if_idx a valid argv index (if_idx < if_argc)?
; Args:    none (reads if_idx/if_argc)
; Returns: DF = 0 if valid, DF = 1 if not (if_idx >= if_argc)
; Modifies: (none but D)
;------------------------------------------------------------------
if_check_bounds:
            mov     rf, if_idx
            ldn     rf
            str     r2
            mov     rf, if_argc
            ldn     rf
            sm                          ; D = if_argc - if_idx
            lbnf    if_bounds_bad       ; DF=0 (borrow): if_argc < if_idx
            lbz     if_bounds_bad       ; D==0: if_argc == if_idx (one
                                        ; past the end)
            clc
            rtn
if_bounds_bad:
            stc
            rtn

;------------------------------------------------------------------
; argv_at: RF = argv[D]'s own pointer value (D = index, 0-based).
; Caller is responsible for confirming index < argc first (see
; if_check_bounds) -- this routine trusts its argument and does not
; bounds-check itself.
; Args:    D = index
; Returns: RF = argv[index]
; Modifies: R8 (and D)
;------------------------------------------------------------------
argv_at:
            plo     r8
            ldi     0
            phi     r8                  ; R8 = index (zero-extended)
            shl16   r8                  ; R8 = index * 2
            mov     rf, RUN_ARGV_TABLE
            add16   rf, r8              ; RF = &argv_table[index]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = argv[index] (the real
                                        ; token pointer)
            mov     rf, r8
            rtn

;------------------------------------------------------------------
; Resolve RA (the null-terminated program name) into RUN_PATH, and --
; as of 2026-07-13 -- CONFIRM it actually exists (via K_STAT) before
; ever handing it to the kernel, so a genuinely missing command is
; handled entirely here rather than round-tripping through run_loop's
; own "Bad command." A name containing '/' is used as-is (a full
; path, loaded directly per the user's own instruction) and gets
; exactly one existence check, no fallback. A bare name is tried
; first against the active drive's own "/bin/", then -- only if that
; fails, and only if the active drive isn't already the shell's own
; drive -- against "<shell_drive>:/bin/" via K_GETSHELLDRIVE, so
; ordinary commands work from any drive without needing /bin
; duplicated everywhere. Both copy loops are bounds-checked against
; RUN_PATH_LEN so an unusually long name truncates safely instead of
; overrunning past RUN_PATH's own 64-byte allocation (which sits just
; below RUN_ARGV_TABLE -- an unbounded copy here would silently
; corrupt the argument table already written by the tokenizer above).
;------------------------------------------------------------------
            mov     rf, ra
scan_slash:
            ldn     rf
            lbz     no_slash            ; reached NUL: no '/' found
            xri     '/'
            lbz     have_slash
            inc     rf
            lbr     scan_slash

have_slash:
            ; full path given -- copy it as-is into RUN_PATH, then
            ; confirm it exists (no fallback candidate for an
            ; explicit path)
            mov     rd, ra
            mov     rf, RUN_PATH
            ldi     RUN_PATH_LEN - 1    ; leave room for the forced NUL
            plo     rc
copy_path_loop:
            glo     rc
            lbz     force_term_path
            lda     rd
            str     rf
            lbz     check_path
            inc     rf
            dec     rc
            lbr     copy_path_loop
force_term_path:
            ldi     0
            str     rf
check_path:
            call    check_exists
            lbnf    resolved
            lbr     not_found

no_slash:
            ; bare name -- stash it in memory first (not just RA):
            ; check_exists below calls K_STAT, which clobbers RA (see
            ; _find_dirent's own documented clobber list), and this
            ; name is needed again for the shell_drive fallback
            ; candidate after that first call returns
            mov     rb, sh_name
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; sh_name = RA

            mov     rf, RUN_PATH
            ldi     RUN_PATH_LEN - 1
            plo     rc
            call    write_bin_name      ; RUN_PATH = "/bin/" + name
            call    check_exists
            lbnf    resolved            ; found on the active drive

            ; not found there -- try shell_drive's own /bin, but only
            ; if that's actually a DIFFERENT drive (no point retrying
            ; the identical path)
            call    K_GETSHELLDRIVE     ; D = shell_drive
            plo     rb                  ; RB.0 = shell_drive (stashed
                                        ; -- mov below clobbers D)
            call    K_GETCURDIR         ; D = cur_drive (RD, the
                                        ; cluster, unused here)
            str     r2
            glo     rb
            sm                          ; D = shell_drive - cur_drive
            lbz     not_found           ; same drive: no new candidate

            mov     rf, RUN_PATH
            glo     rb
            adi     'C'
            str     rf
            inc     rf
            ldi     ':'
            str     rf
            inc     rf
            ldi     RUN_PATH_LEN - 3
            plo     rc
            call    write_bin_name      ; RUN_PATH = "<letter>:/bin/" + name
            call    check_exists
            lbnf    resolved

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            lbr     start

resolved:
            ; a resolved path ending in ".bat" (case-insensitive) is a
            ; batch script, not an EDF program -- start it directly
            ; from here instead of handing off to the kernel's
            ; run_loop, which would try (and fail) to load it as a
            ; binary. Any trailing command-tail text is simply
            ; discarded for now -- v1 batch scripts take no arguments.
            call    check_batch_ext
            lbnf    is_batch

            ldi     0                   ; exit code 0
            rtn

is_batch:
            mov     rf, RUN_PATH
            call    K_BATCH_START
            lbdf    batch_nested

            ; %0-%9 batch-argument population (2026-07-25). Reserve
            ; the dynamic himem block and, on success, copy up to the
            ; first 10 RUN_ARGV_TABLE entries' own STRING CONTENT into
            ; it -- RUN_ARGV_TABLE[i] itself is a pointer into
            ; LINE_BUF, which the very next shell reload overwrites,
            ; so BATCH_ARGV[i] must never be a copy of that pointer,
            ; only a NEW pointer into the reserved block's own text
            ; region. RUN_ARGV_TABLE/RUN_ARGC are still exactly as
            ; tok_done left them here (confirmed by trace: neither
            ; K_BATCH_START nor K_BATCH_ARGS_RESERVE touches them).
            call    K_BATCH_ARGS_RESERVE   ; DF=0/RD=base, DF=1=failed
            lbdf    start                  ; couldn't reserve: batch
                                        ; still runs anyway, just
                                        ; without %N support for this
                                        ; run -- K_BATCH_ARGS_GETARG
                                        ; will correctly report "not
                                        ; active" (graceful
                                        ; degradation, not an aborted
                                        ; batch)

            ; RD = base, kept in this register for the whole loop
            ; below (confirmed the loop body never touches RD)
            mov     rc, rd              ; RC = text-region write
                                        ; cursor, starts at
                                        ; base+BATCH_ARGS_TEXT_OFF
                                        ; (== base, offset is 0)

            mov     rf, RUN_ARGC
            inc     rf
            ldn     rf                  ; D = argc's low byte (high
                                        ; byte is always 0 -- capped
                                        ; well under 256 by
                                        ; ARGV_MAX_ARGS=16)
            plo     r9                  ; R9.0 = argc (tentatively)
            ldi     0
            phi     r9
            glo     r9
            smi     11
            lbnf    ibp_count_final     ; argc <= 10 (borrow): keep it
            ldi     10
            plo     r9                  ; argc > 10: cap at 10
ibp_count_final:

            ldi     0
            plo     r7                  ; R7.0 = loop index i

ibp_loop:
            glo     r7
            str     r2
            glo     r9
            sm                          ; D = count - i (SM computes
                                        ; D - M(R2), not M(R2) - D --
                                        ; see kernel_batch_args_getarg's
                                        ; own comment for the full
                                        ; story) -- equality check, so
                                        ; the sign doesn't actually
                                        ; matter here, only that it's
                                        ; zero iff i == count
            lbz     ibp_write_argc      ; i == count: done copying

            ; RA = RUN_ARGV_TABLE[i] (dereference)
            mov     rf, RUN_ARGV_TABLE
            glo     r7
            plo     ra
            ldi     0
            phi     ra
            shl16   ra                  ; RA = i * 2
            add16   rf, ra
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; RA = RUN_ARGV_TABLE[i]

            ; argv-table slot address = base + ARGV_OFF + i*2,
            ; recomputed fresh each iteration -- no separate
            ; persistent cursor needed
            mov     rf, rd
            add16   rf, BATCH_ARGS_ARGV_OFF
            glo     r7
            plo     r8
            ldi     0
            phi     r8
            shl16   r8
            add16   rf, r8              ; RF = &BATCH_ARGV[i]

            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; BATCH_ARGV[i] = RC (this
                                        ; arg's NEW pointer, into the
                                        ; text region -- never
                                        ; RUN_ARGV_TABLE[i]'s own
                                        ; LINE_BUF pointer)

ibp_copy_str:
            ldn     ra
            lbz     ibp_copy_done
            str     rc
            inc     rc
            inc     ra
            lbr     ibp_copy_str

ibp_copy_done:
            ldi     0
            str     rc
            inc     rc                  ; NUL-terminate this arg,
                                        ; advance the text cursor past
                                        ; it for the next one

            inc     r7
            lbr     ibp_loop

ibp_write_argc:
            mov     rf, rd
            add16   rf, BATCH_ARGS_ARGC_OFF
            glo     r9
            str     rf

            lbr     start               ; batch now active, %N args
                                        ; populated -- the next trip
                                        ; through "start" pulls the
                                        ; first line via
                                        ; K_BATCH_READLINE

batch_nested:
            call    K_INMSG
            db      "Nested batch not supported.",13,10,0
            lbr     start

;------------------------------------------------------------------
; Pipes ("cmd1 | cmd2"): a top-level '|' (found by pipe_scan, called
; from start_have_line above) means this line describes a pipe rather
; than a single command. Handled entirely in userland, without any
; kernel changes, by synthesizing a 3-line temp batch script:
;   <cmd1 text> >/PIPETMP.DAT
;   <cmd2 text> </PIPETMP.DAT
;   DEL /PIPETMP.DAT
; and routing it through the exact same K_BATCH_START path a real
; ".bat" filename typed at the prompt already uses (is_batch: above) --
; reusing that path also means a pipe used INSIDE an already-running
; batch script correctly, automatically hits K_BATCH_START's own
; nesting rejection ("Nested batch not supported.") rather than
; needing a separate check here. Known, deliberate limitations for v1:
; scoped to exactly one pipe (two commands) per line -- a second '|'
; inside cmd2's own text is carried into the script's second line
; verbatim, so a 3-stage pipe (a|b|c) fails cleanly via the same
; nesting rejection on the NEXT pass, rather than silently doing
; something unexpected; and if either command already has its own
; explicit '>' or '<' redirect, this feature's own appended operator
; simply comes after it in the token stream, so the LAST one on the
; line silently wins -- left undefined/unhandled, an accepted edge
; case rather than a new special case to design around.
;------------------------------------------------------------------

;------------------------------------------------------------------
; pipe_scan: quote-aware scan for the first top-level '|' character.
; Deliberately does none of the tokenizer's other jobs (no argv
; building, no backslash-collapsing output, no redirect-operator
; detection) -- it only needs to locate a byte position, not mutate
; anything, so it's a much smaller, independently-checkable state
; machine than not_drive_cmd's own tokenizer above.
; Args:    RF = line to scan (the trimmed line's own start)
; Returns: DF=0 with RF = pointer to the '|' character (found), or
;          DF=1 (not found -- RF left at the line's own NUL terminator,
;          not meaningful to the caller either way since handle_pipe
;          and the fallthrough path both reload RF fresh from memory)
; Modifies: RF, R8 (and D). Makes no calls.
;------------------------------------------------------------------
pipe_scan:
            ldi     0
            plo     r8                  ; quote state = 0 (none)

ps_loop:
            ldn     rf
            lbz     ps_not_found

            glo     r8
            lbz     ps_unquoted
            xri     $01
            lbz     ps_in_squote

            ; in double-quote mode: only '"' (close) or '\' (escape --
            ; matching the main tokenizer's own "\X inside or outside
            ; double quotes" rule) are special
            ldn     rf
            xri     '"'
            lbz     ps_close_dq
            ldn     rf
            xri     '\'
            lbz     ps_bs
            inc     rf
            lbr     ps_loop

ps_close_dq:
            ldi     0
            plo     r8
            inc     rf
            lbr     ps_loop

ps_in_squote:
            ; true bash semantics (matching tok_in_squote above): 100%
            ; literal until the matching close quote, no backslash-
            ; escaping recognized inside
            ldn     rf
            xri     '''
            lbnz    ps_sq_next
            ldi     0
            plo     r8
ps_sq_next:
            inc     rf
            lbr     ps_loop

ps_unquoted:
            ldn     rf
            xri     '|'
            lbz     ps_found
            ldn     rf
            xri     '"'
            lbz     ps_open_dq
            ldn     rf
            xri     '''
            lbz     ps_open_sq
            ldn     rf
            xri     '\'
            lbz     ps_bs
            inc     rf
            lbr     ps_loop

ps_open_dq:
            ldi     $FF
            plo     r8
            inc     rf
            lbr     ps_loop

ps_open_sq:
            ldi     $01
            plo     r8
            inc     rf
            lbr     ps_loop

ps_bs:
            ; skip the next character too, whatever it is (matches the
            ; main tokenizer's tok_check_bs: "\X" is always a literal
            ; X, so it can never itself be the pipe separator) -- a
            ; trailing lone backslash at end of line safely ends the
            ; scan rather than reading past the NUL
            inc     rf
            ldn     rf
            lbz     ps_not_found
            inc     rf
            lbr     ps_loop

ps_found:
            clc
            rtn

ps_not_found:
            stc
            rtn

;------------------------------------------------------------------
; handle_pipe: reached from start_have_line above with RF = the
; trimmed line's own start and pipe_pos (memory) = the '|' character's
; position within it. Computes the LHS run [line start, pipe_pos) and
; RHS run [pipe_pos+1, end of line), writes the synthesized script
; (see the section header above), and threads into is_batch to invoke
; it exactly as if the user had typed its filename directly.
;------------------------------------------------------------------
handle_pipe:
            mov     rb, pipe_lhs_start
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; pipe_lhs_start = RF (line
                                        ; start)

            mov     r8, rf              ; R8 = line start -- survives
                                        ; the loads below, nothing else
                                        ; in this block touches R8

            mov     rf, pipe_pos
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = pipe_pos (the '|' itself)

            mov     r7, rd              ; R7 = pipe_pos, kept for the
                                        ; RHS-start calc below since the
                                        ; sub16 that follows is about to
                                        ; consume RD
            sub16   rd, r8              ; RD = pipe_pos - line_start =
                                        ; LHS length (register-register
                                        ; sub16 -- safe here, nothing
                                        ; nearby stages a comparison via
                                        ; str r2 for it to clobber, see
                                        ; gotcha #18)
            mov     rb, pipe_lhs_len
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rd, r7
            inc     rd                  ; RD = pipe_pos + 1 (RHS start,
                                        ; skipping the '|' itself)
            mov     rb, pipe_rhs_start
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rf, rd              ; RF = pipe_rhs_start
            call    shell_strlen        ; RC = length, RF unchanged
            mov     rb, pipe_rhs_len
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            ; --- write the synthesized script ---
            mov     rd, pipe_fcb
            mov     ra, pipe_iobuf
            mov     rf, pipe_script_path
            ldi     1                   ; mode 1: create/overwrite
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified --
                                        ; pipe_fcb is a fixed address,
                                        ; nothing to capture)
            lbdf    pipe_open_err

            mov     rf, pipe_echooff_line
            call    pipe_write_str      ; write "@echo off\n" -- the
                                        ; '@' suppresses this line's own
                                        ; echo, and "echo off" itself
                                        ; suppresses every line after it
                                        ; for the rest of this script
                                        ; (see RUN_BATCH_ECHO_OFF), so
                                        ; none of the 3 real lines below
                                        ; clutter the console

            mov     rb, pipe_lhs_start
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = pipe_lhs_start
            mov     rb, pipe_lhs_len
            lda     rb
            phi     rc
            ldn     rb
            plo     rc                  ; RC = pipe_lhs_len
            mov     rd, pipe_fcb
            call    K_FILE_WRITE        ; write cmd1's raw text

            mov     rf, pipe_out_line
            call    pipe_write_str      ; write " >/PIPETMP.DAT\n"

            mov     rb, pipe_rhs_start
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rb, pipe_rhs_len
            lda     rb
            phi     rc
            ldn     rb
            plo     rc
            mov     rd, pipe_fcb
            call    K_FILE_WRITE        ; write cmd2's raw text

            mov     rf, pipe_in_line
            call    pipe_write_str      ; write " </PIPETMP.DAT\n"

            mov     rf, pipe_del_line
            call    pipe_write_str      ; write "del /PIPETMP.DAT\n"

            mov     rd, pipe_fcb
            call    K_FILE_CLOSE

            ; RUN_PATH = "/PIPETMP.BAT" -- reuse the existing batch-
            ; invocation path exactly as if the user had typed this
            ; filename directly (see the section header above for why
            ; this also gets the nested-batch rejection for free)
            mov     rf, RUN_PATH
            mov     rd, pipe_script_path
pipe_copy_path:
            lda     rd
            str     rf
            lbz     pipe_path_done
            inc     rf
            lbr     pipe_copy_path
pipe_path_done:
            lbr     is_batch

pipe_open_err:
            call    K_INMSG
            db      "Cannot create pipe script.",13,10,0
            lbr     start

;------------------------------------------------------------------
; pipe_write_str: writes the NUL-terminated string at RF to pipe_fcb
; (a fixed field, not an argument -- every call site above already has
; it open).
; Args:    RF = string
; Returns: nothing checked -- best-effort, matching this file's own
;          existing write_bin_name, which has no failure path either
; Modifies: RF, RC, RD (and D)
;------------------------------------------------------------------
pipe_write_str:
            call    shell_strlen        ; RC = length, RF unchanged
            mov     rd, pipe_fcb
            call    K_FILE_WRITE
            rtn

;------------------------------------------------------------------
; shell_strlen: Args RF = string (left unchanged). Returns RC = length.
; Makes no calls -- provably safe by direct inspection, matching this
; project's own preference for a tiny hand-rolled helper over trusting
; an unaudited BIOS routine's contract (gotcha #8).
; Modifies: R8, RC (and D)
;------------------------------------------------------------------
shell_strlen:
            mov     r8, rf
            ldi     0
            phi     rc
            plo     rc
ssl_loop:
            ldn     r8
            lbz     ssl_done
            inc     r8
            inc     rc
            lbr     ssl_loop
ssl_done:
            rtn

pipe_line_start: dw 0
pipe_pos:       dw      0
pipe_lhs_start: dw      0
pipe_lhs_len:   dw      0
pipe_rhs_start: dw      0
pipe_rhs_len:   dw      0
pipe_fcb:       ds      FCB_LEN
pipe_iobuf:     ds      FCB_IOBUF_LEN
pipe_echooff_line: db   "@echo off",10,0
pipe_script_path: db    "/PIPETMP.BAT",0
pipe_out_line:  db      " >/PIPETMP.DAT",10,0
pipe_in_line:   db      " </PIPETMP.DAT",10,0
pipe_del_line:  db      "del /PIPETMP.DAT",10,0    ; lowercase -- filename
                                        ; lookups are case-sensitive
                                        ; (f_strcmp does no folding),
                                        ; and executables live on disk
                                        ; lowercase (bin/del, from the
                                        ; Makefile's own progs/%.asm ->
                                        ; bin/% pattern) -- "DEL" here
                                        ; resolved to a nonexistent
                                        ; "/bin/DEL" and silently left
                                        ; PIPETMP.DAT behind uncleaned
                                        ; (hardware-found 2026-07-21)

;------------------------------------------------------------------
; write_bin_name: append "/bin/" + the command name (sh_name) at RF,
; bounded by RC.0 (remaining byte budget), force-terminating on
; overflow -- shared by both drive-candidate attempts above.
; Args:    RF = write position within RUN_PATH, RC.0 = remaining bytes
; Returns: RUN_PATH null-terminated
;------------------------------------------------------------------
write_bin_name:
            mov     rd, bin_prefix
wbn_prefix_loop:
            glo     rc
            lbz     wbn_term
            lda     rd
            lbz     wbn_prefix_done     ; end of "/bin/" -- don't copy
                                        ; its own NUL, the name follows
            str     rf
            inc     rf
            dec     rc
            lbr     wbn_prefix_loop
wbn_prefix_done:
            mov     rb, sh_name
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = sh_name (reloaded from
                                        ; memory, not RA)
wbn_name_loop:
            glo     rc
            lbz     wbn_term
            lda     rd
            str     rf
            lbz     wbn_done
            inc     rf
            dec     rc
            lbr     wbn_name_loop
wbn_term:
            ldi     0
            str     rf                  ; truncate: RC reaching 0 means
                                        ; the budget ran out, so RF is
                                        ; exactly at the last in-bounds
                                        ; byte here
wbn_done:
            rtn

;------------------------------------------------------------------
; shell_match_word: does *RF case-insensitively match the whole word
; RD points to? Used by IF/GOTO's own dispatch (check_special, below)
; for "IF"/"NOT"/"EXIST"/"GOTO" -- factored out rather than repeating
; the REM check's own inline shape (start_have_line, above) several
; more times, matching this project's own standing lesson that
; duplicated fiddly per-character logic is where bugs live.
; Args:    RF = string to check, RD = pointer to a NUL-terminated
;          pattern -- MUST be all-uppercase-letters (this routine
;          blind-folds the live input via "ani $DF" and compares
;          against RD as-is; that fold is only safe when the pattern
;          itself contains no non-letter characters, matching the
;          exact reasoning tok_ordinary's own %ERRORLEVEL% comment
;          already documents for why "%" specifically can't be folded
;          this way -- every pattern this routine is actually called
;          with ("IF"/"NOT"/"EXIST"/"GOTO") is plain letters, so this
;          holds)
; Returns: DF = 0 on a whole-word match (RD's pattern, followed by a
;          space or end-of-string, not a prefix of a longer word) --
;          RF is advanced past the matched word, and past one
;          following space if present, ready to parse the next token
;          (matching f_ltrim's own "point past whitespace" contract).
;          DF = 1 on no match -- RF unchanged.
; Modifies: R7 (and D)
;------------------------------------------------------------------
shell_match_word:
            mov     r7, rf              ; R7 = trial scan cursor -- RF
                                        ; itself stays untouched unless
                                        ; the whole match succeeds
smw_loop:
            ldn     rd
            lbz     smw_checkend        ; pattern exhausted
            str     r2
            ldn     r7
            ani     $DF
            xor
            lbnz    smw_nomatch
            inc     rd
            inc     r7
            lbr     smw_loop

smw_checkend:
            ldn     r7
            lbz     smw_match_noskip    ; NUL right after: whole-word
                                        ; match, nothing to skip
            xri     ' '
            lbnz    smw_nomatch         ; some other char follows --
                                        ; e.g. "IFX" when matching
                                        ; "IF": not a whole-word match
            inc     r7                  ; it WAS a space -- consume it
            mov     rf, r7
            clc
            rtn

smw_match_noskip:
            mov     rf, r7
            clc
            rtn

smw_nomatch:
            stc
            rtn

;------------------------------------------------------------------
; check_exists: confirm RUN_PATH names an existing FILE (not a
; directory) via K_STAT.
; Args:    none (reads RUN_PATH)
; Returns: DF = 0 if it exists and is a file, DF = 1 otherwise (not
;          found, an intermediate path component invalid, or it's a
;          directory)
;------------------------------------------------------------------
check_exists:
            mov     rf, RUN_PATH
            mov     rd, stat_result
            call    K_STAT
            lbdf    chk_no

            mov     rf, stat_result
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    chk_no              ; it's a directory: reject

            clc
            rtn

chk_no:
            stc
            rtn

;------------------------------------------------------------------
; check_batch_ext: does RUN_PATH end in ".bat" (case-insensitive)?
; Args:    none (reads RUN_PATH)
; Returns: DF = 0 if it does, DF = 1 otherwise
;------------------------------------------------------------------
check_batch_ext:
            mov     rf, RUN_PATH
            ldi     0
            plo     r9                  ; R9.0 = length so far (RUN_PATH
                                        ; is well under 256 bytes, see
                                        ; RUN_PATH_LEN, so one byte is
                                        ; enough)
cbe_scan:
            ldn     rf
            lbz     cbe_scanned
            inc     rf
            glo     r9
            adi     1
            plo     r9
            lbr     cbe_scan
cbe_scanned:
            ; RF -> the NUL terminator; a name under 4 characters can't
            ; possibly end in ".bat"
            glo     r9
            smi     4
            lbnf    cbe_no

            dec     rf                  ; walk back to the last 4
            dec     rf                  ; characters
            dec     rf
            dec     rf

            ldn     rf                  ; '.' is not a letter -- compare
            xri     '.'                 ; it directly, with no case-fold
            lbnz    cbe_no              ; mask (which would corrupt it --
            inc     rf                  ; see the mask's own reasoning
                                        ; below)

            ldn     rf
            ani     $DF                 ; uppercase-fold: safe for a
                                        ; single-letter comparison
                                        ; against one fixed target --
                                        ; only 'B'/'b' (0x42/0x62) clear
                                        ; to 0x42 under this mask
            xri     'B'
            lbnz    cbe_no
            inc     rf

            ldn     rf
            ani     $DF
            xri     'A'
            lbnz    cbe_no
            inc     rf

            ldn     rf
            ani     $DF
            xri     'T'
            lbnz    cbe_no

            clc
            rtn

cbe_no:
            stc
            rtn

bin_prefix: db      "/bin/",0
sh_name:    dw      0
stat_result: ds     DIRENT_LEN

;------------------------------------------------------------------
; print_prompt: print "C:/> " at root, "C:/<name>> " one level under
; root, or "C:.../<name>> " deeper -- <name> is always just the
; current directory's own name, never the full path (kept short and
; cheap on purpose; PWD already exists for the full path). "C" is
; actually the ACTIVE drive's own letter ('C'+cur_drive), fetched via
; K_GETCURDIR's D return and printed one character at a time via
; K_TTY (print_drive_letter below) -- a single bare K_TTY call per
; prompt, the same proven-safe pattern COPY's own overwrite-
; confirmation prompt already uses to echo a character (see gotcha
; #14: looping K_TTY over a large buffer corrupted shell input on
; hardware, but a single one-shot call has never shown that problem).
; Reuses PWD's own "find my own name" trick (open current dir, find
; '..' to get the parent's cluster, open the parent, scan for the
; entry whose DIRENT_CLUST matches) but only ONE level -- pwd.asm's
; own header explains why FAT records no "my own name"/"path from
; root" anywhere, only each directory's parent link.
;
; Args:    none
; Returns: nothing (prints the prompt directly)
; Modifies: everything (R7-RD) -- called once at the very top of
;           start, before any other state exists to protect.
;------------------------------------------------------------------
print_prompt:
            call    K_GETCURDIR         ; RD = current directory
                                        ; cluster, D = cur_drive
            plo     r9                  ; R9.0 = cur_drive (stashed
                                        ; immediately -- the mov below
                                        ; clobbers D, gotcha #4)
            mov     rf, pp_drive
            glo     r9
            str     rf                  ; pp_drive = cur_drive

            ; already at root?
            ghi     rd
            lbnz    pp_not_root
            glo     rd
            lbnz    pp_not_root

            call    print_drive_letter
            call    K_INMSG
            db      ":/> ",0
            rtn

pp_not_root:
            mov     rf, pp_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; pp_clust = cur_dir

            ; --- open cur_dir, find its '..' entry -> parent cluster ---
            call    K_DIR_OPEN          ; RD still = cur_dir

pp_find_dotdot:
            mov     rf, pp_dirent
            call    K_DIR_READ
            lbdf    pp_ioerr            ; ran out of entries: shouldn't
                                        ; happen for a real subdirectory

            mov     rf, pp_dirent       ; RF = entry name
            mov     rd, pp_dotdot       ; RD = ".."
            call    f_strcmp
            lbnz    pp_find_dotdot

            ; parent = this entry's DIRENT_CLUST
            mov     rf, pp_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd
            mov     rf, pp_parent
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; pp_parent = RD

            ; --- open parent, find the entry whose cluster == pp_clust ---
            call    K_DIR_OPEN          ; RD is still = parent

pp_find_self:
            mov     rf, pp_dirent
            call    K_DIR_READ
            lbdf    pp_ioerr            ; ran out: shouldn't happen --
                                        ; pp_clust must appear once in
                                        ; its own parent's listing

            ; compare this entry's cluster against pp_clust, high byte
            ; then low byte (same SM-based equality idiom pwd.asm uses)
            mov     rf, pp_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = entry cluster high byte,
                                        ; RF -> entry cluster low byte
            str     r2
            mov     rb, pp_clust
            ldn     rb                  ; D = pp_clust high byte
            sm                          ; D = pp_clust.hi - entry.hi
            lbnz    pp_find_self        ; mismatch: keep looking

            ldn     rf                  ; D = entry cluster low byte
            str     r2
            inc     rb                  ; RB -> pp_clust low byte
            ldn     rb                  ; D = pp_clust low byte
            sm                          ; D = pp_clust.lo - entry.lo
            lbnz    pp_find_self        ; mismatch: keep looking

            ; match: pp_dirent's name is our own name. Reload pp_parent
            ; fresh from memory (not any register -- the scan above
            ; used RD/RF/RB freely) to decide which prompt form to use.
            mov     rf, pp_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = pp_parent

            ghi     rd
            lbnz    pp_deep
            glo     rd
            lbnz    pp_deep

            ; parent is root: "C:/<name>> "
            call    print_drive_letter
            call    K_INMSG
            db      ":/",0
            mov     rf, pp_dirent
            call    K_MSG
            call    K_INMSG
            db      "> ",0
            rtn

pp_deep:
            ; parent is itself a subdirectory: "C:.../<name>> "
            call    print_drive_letter
            call    K_INMSG
            db      ":.../",0
            mov     rf, pp_dirent
            call    K_MSG
            call    K_INMSG
            db      "> ",0
            rtn

pp_ioerr:
            ; shouldn't happen for a real directory -- fall back to a
            ; plain, always-safe prompt rather than fail the whole
            ; command loop over a cosmetic feature
            call    print_drive_letter
            call    K_INMSG
            db      ":> ",0
            rtn

;------------------------------------------------------------------
; print_drive_letter: print 'C'+pp_drive (a single character) via a
; bare, one-shot K_TTY call -- see print_prompt's own header comment
; on why this is safe despite gotcha #14's warning about looping
; K_TTY over a large buffer.
; Args:    none (reads pp_drive)
; Returns: nothing
;------------------------------------------------------------------
print_drive_letter:
            mov     rf, pp_drive
            ldn     rf
            adi     'C'
            call    K_TTY
            rtn

pp_dotdot:  db      "..",0
pp_clust:   dw      0
pp_parent:  dw      0
pp_drive:   db      0                   ; K_GETCURDIR's D return
                                        ; (cur_drive), stashed at
                                        ; print_prompt's own entry
pp_dirent:  ds      DIRENT_LEN

;------------------------------------------------------------------
; Command-line history (2026-07-22). Persistent, disk-backed --
; "<shell_drive letter>:/bin/history.dat" -- the user's own proposal
; over a kernel-resident buffer, since it survives reboots and costs
; zero permanent kernel bytes. Escape sequences: this terminal sends
; real ANSI/VT100 CSI form (ESC [ A / ESC [ B for Up/Down) -- an
; earlier VT52-bare-letter theory (this comment's own original text)
; turned out wrong and was corrected via hardware testing 2026-07-23;
; see rlwh_escape's own header comment below for the full story and
; why the bare-letter fallback was deliberately removed rather than
; kept as defense-in-depth. Anything unrecognized after ESC is
; silently discarded rather than corrupting the line. Backspace is
; 0x08 -- hardware-confirmed working. Enter is CR (0x0D) or LF (0x0A)
; -- treating either as a terminator was a deliberate defensive choice
; made before hardware testing, since the exact byte(s) a live Enter
; keypress sends wasn't independently confirmed the way the arrow
; keys/backspace now are; hardware-confirmed 2026-07-22 that a blank
; Enter produces an immediate clean reprompt with no spurious extra
; blank line, so whatever this terminal actually sends for Enter, the
; CR-or-LF handling deals with it correctly.
;
; Mid-line cursor editing (2026-07-27), added on top of the above:
; Left/Right arrows (ESC [ D / ESC [ C, same CSI family as the
; already-proven Up/Down) and Emacs/readline Ctrl shortcuts (Ctrl-A
; home, Ctrl-E end, Ctrl-B left, Ctrl-F right, Ctrl-D delete-under-
; cursor, Ctrl-H/backspace delete-behind-cursor -- generalized from the
; original design's "always at the end of the line" assumption). A new
; edit_cursor byte tracks position within LINE_BUF (0..hist_cur_len).
; Insert and delete each shift LINE_BUF's own bytes via a small
; byte-shuffle loop (edit_insert_char/edit_delete_at), then redraw via
; the shared edit_redraw_tail (reprint the tail from edit_cursor
; onward, blank any stale trailing character left by a delete, then
; backspace the terminal cursor back to edit_cursor) -- independently
; simulated at the byte level (including 8-bit register-wraparound
; semantics, not just a high-level model) before being trusted, per
; this project's own established practice for new buffer-manipulation
; logic; see the plan file for the specific bug a naive pre-test/
; decrement loop structure would have hit at cursor==0/length==0.
; Deliberately deferred (need a cut buffer, not part of this pass):
; Ctrl-K (kill to end of line), Ctrl-U (kill to start), Ctrl-W (delete
; word back), Ctrl-Y (yank/paste) -- all four are explicitly matched
; and silently discarded rather than falling through to the ordinary-
; character path and being inserted as literal control bytes; so is
; any other unrecognized byte below $20, closing a small pre-existing
; gap (previously any unhandled control byte fell through and got
; inserted as invisible literal text).
;
; read_line_with_history replaces K_INPUTL at its one call site
; (start_interactive) -- this call site is NEVER redirected (shell
; input redirection only ever applies to a CHILD program's own I/O,
; never the shell's own prompt read), so there's no EOF/redirect case
; to handle here. Reads use f_uread (the raw UART BIOS entry point,
; EBIOS+0Ch), not K_READ -- hardware-confirmed 2026-07-23 that K_READ's
; own two-layer indirection (kernel jump table, then the BIOS's own
; internal RAM-vector redirect) was slow enough between this routine's
; per-byte branching to drop the '[' byte of a real "ESC [ A"/"ESC [ B"
; arrow-key sequence -- the exact bug progs/mr.asm/progs/ms.asm already
; hit and fixed the same way (see their own header comments); nothing
; is lost bypassing K_READ here since redirection never applies to this
; call site regardless. Echo still uses K_TYPE, not K_TTY -- K_TYPE is
; already exercised once per byte by TYPE.exe's own hot loop across
; this project's whole history, while K_TTY has a documented hardware
; caution under repeated calls (/CLAUDE.md gotcha #14); the byte-drop
; risk that motivated switching reads to f_uread is specifically about
; input arriving faster than it's read, which doesn't apply to output
; we control the timing of ourselves.
;
; HISTORY_LOAD_BUDGET: how many bytes of history.dat's own tail get
; loaded into RAM for one session's worth of Up/Down recall. Raised
; 255->512 (2026-07-25, user's own request, after the compaction
; feature above made it worth pairing with a matching HISTORY_MAX_LINES
; raise) -- previously kept under 256 specifically so hist_loaded_len
; and hist_split's own remaining-byte countdown could stay single-byte
; arithmetic; both were widened to real 16-bit words to support this
; (independently Python-simulated across the full 16-bit range,
; including the 255/256/257 boundary the old code would have broken
; on, before trusting the assembly -- see hist_split's own comments).
; The FILE itself is never capped -- only the tail loaded into RAM for
; any one session is; hist_compact (below) is what bounds the file.
;
; HISTORY_MAX_LINES raised 25->50 in the same pass, to match: at a
; true ~10-char command average, 512 bytes realistically holds
; something in the low-to-mid 40s-50s of lines, comfortably supporting
; a cap of 50 (255 bytes only reached the low-to-mid 20s against its
; old cap of 25, so the old pairing was already a bit undersized).
; hist_lines[]'s only cost is ordinary shell RAM (HISTORY_MAX_LINES*2
; bytes -- 100 vs 50, no kernel-margin impact) and hist_split's own
; shift-on-full logic is already fully parametric (no hardcoded
; MAX_LINES value anywhere in the actual logic).
;------------------------------------------------------------------
HISTORY_LOAD_BUDGET: equ 512
HISTORY_MAX_LINES:   equ 50

; HISTORY_COMPACT_THRESHOLD: once history.dat's real on-disk size (via
; K_STAT) reaches this many bytes, hist_compact rewrites it down to
; just the tail hist_load would read anyway -- recall never looks
; further back than HISTORY_LOAD_BUDGET bytes from the end, so keeping
; more than that provides zero recall value, only unbounded growth
; (and, past ~32KB, silently breaks recall entirely -- see
; K_FILE_SEEK's own documented range limit in hist_load's comment).
; Deliberately well above HISTORY_LOAD_BUDGET (same ~4x margin as
; before the 2026-07-25 budget raise) so compaction doesn't run on
; nearly every append.
HISTORY_COMPACT_THRESHOLD: equ 2048

;------------------------------------------------------------------
; read_line_with_history: see the section header above.
; Args:    none
; Returns: nothing (LINE_BUF filled, NUL-terminated -- identical
;          contract to the K_INPUTL call this replaces)
;------------------------------------------------------------------
read_line_with_history:
            mov     rf, hist_cur_len
            ldi     0
            str     rf

            mov     rf, edit_cursor
            ldi     0
            str     rf

            mov     rf, LINE_BUF
            ldi     0
            str     rf

            mov     rf, hist_loaded
            ldi     0
            str     rf

            mov     rf, hist_recalling
            ldi     0
            str     rf

            mov     rf, hist_index
            ldi     0
            str     rf

rlwh_loop:
            call    f_uread             ; D = char (blocking) -- direct
                                        ; BIOS call, not K_READ (see this
                                        ; routine's own header comment:
                                        ; hardware-confirmed 2026-07-23
                                        ; that K_READ's own indirection
                                        ; drops bytes arriving in rapid
                                        ; succession, exactly the mr.asm/
                                        ; ms.asm precedent this mirrors)
            plo     rc                  ; RC.0 = char (D unchanged,
                                        ; plo doesn't touch it)

            ; ESC checked FIRST (not last) -- minimizes the latency
            ; between reading ESC and rlwh_escape's own next f_uread
            ; call, giving maximum headroom against the exact byte-drop
            ; risk that motivated switching to f_uread in the first
            ; place (see that routine's own header comment). Costs one
            ; extra comparison on every OTHER byte (ordinary chars, CR/
            ; LF, backspace) to buy this -- negligible, since none of
            ; those paths are timing-sensitive the way a multi-byte
            ; escape sequence is.
            glo     rc
            xri     27                  ; ESC
            lbz     rlwh_escape

            glo     rc
            xri     13                  ; CR
            lbz     rlwh_finish
            glo     rc
            xri     10                  ; LF
            lbz     rlwh_finish

            glo     rc
            xri     8                   ; backspace / Ctrl-H
            lbz     rlwh_backspace

            glo     rc
            xri     1                   ; Ctrl-A: home
            lbz     rlwh_home

            glo     rc
            xri     5                   ; Ctrl-E: end
            lbz     rlwh_end

            glo     rc
            xri     2                   ; Ctrl-B: cursor left
            lbz     rlwh_left

            glo     rc
            xri     6                   ; Ctrl-F: cursor right
            lbz     rlwh_right

            glo     rc
            xri     4                   ; Ctrl-D: delete at cursor
            lbz     rlwh_delete_at

            ; ---- deferred: Ctrl-K/U/W/Y need a cut buffer, not
            ; implemented yet -- explicitly discarded rather than
            ; falling through to the ordinary-character path below
            ; and being inserted as literal control bytes ----
            glo     rc
            xri     11                  ; Ctrl-K
            lbz     rlwh_loop
            glo     rc
            xri     21                  ; Ctrl-U
            lbz     rlwh_loop
            glo     rc
            xri     23                  ; Ctrl-W
            lbz     rlwh_loop
            glo     rc
            xri     25                  ; Ctrl-Y
            lbz     rlwh_loop

            ; ---- any other control byte: silently discard rather
            ; than insert as literal text (closes a pre-existing gap --
            ; previously any unrecognized byte below $20 fell straight
            ; through to the ordinary-character path) ----
            glo     rc
            smi     32
            lbnf    rlwh_loop           ; < 32 ($20): discard

            ; ---- ordinary character: insert at cursor if there's room ----
            mov     rf, hist_cur_len
            ldn     rf
            smi     127
            lbdf    rlwh_loop           ; at cap: silently drop

            call    edit_insert_char    ; RC.0 = character to insert
                                        ; (already set, at the top of
                                        ; this loop, and untouched by
                                        ; every check above -- none of
                                        ; them write RC)

            lbr     rlwh_loop

;------------------------------------------------------------------
; edit_redraw_tail: reprint LINE_BUF[edit_cursor..hist_cur_len-1] (the
; tail after an insert/delete at/before edit_cursor), print blank_count
; trailing spaces to erase a stale character left over from a delete,
; then walk the terminal cursor back to edit_cursor via backspaces.
; Args:    D = blank_count (0 for insert, 1 for a single-character
;          delete -- every edit operation in this pass changes exactly
;          one character, so this is always 0 or 1)
; Returns: nothing
; Modifies: R8, R9, RF (and D)
;------------------------------------------------------------------
edit_redraw_tail:
            plo     r9                  ; R9.0 = blank_count (stashed
                                        ; to memory immediately below --
                                        ; nothing survives in a
                                        ; register across the K_TYPE
                                        ; calls ahead)
            mov     rf, ert_blank_count
            glo     r9
            str     rf

            ; print starts from ert_start, NOT edit_cursor -- these are
            ; DIFFERENT positions for insert (edit_cursor has already
            ; advanced past the newly-inserted character by the time
            ; this runs; ert_start is the OLD position, where the
            ; visible content actually changed and where the terminal's
            ; own physical cursor already sits). Real bug, hardware-
            ; found (2026-07-27): the original version used edit_cursor
            ; for both the print-start AND the backspace-target,
            ; conflating two positions that only happen to coincide for
            ; delete, not insert -- for insert this made the "tail"
            ; start AT the already-advanced cursor, printing ZERO
            ; characters on every ordinary keystroke (100% silent
            ; input). See this routine's own callers for how ert_start
            ; is set correctly in each case.
            mov     rb, ert_pos
            mov     rf, ert_start
            ldn     rf
            str     rb                  ; ert_pos = ert_start

ert_print_loop:
            mov     rf, ert_pos
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ert_pos (zero-ext)
            mov     rf, LINE_BUF
            add16   rf, r8              ; RF = &LINE_BUF[ert_pos]
            ldn     rf                  ; D = LINE_BUF[ert_pos]
            lbz     ert_print_done      ; NUL: tail fully printed

            call    K_TYPE              ; echo (D still holds the
                                        ; character, set by ldn above)

            mov     rf, ert_pos
            ldn     rf
            adi     1
            str     rf                  ; ert_pos++
            lbr     ert_print_loop

ert_print_done:
            ; ert_pos now equals hist_cur_len (the print loop walked
            ; it there) -- print blank_count trailing spaces
            mov     rf, ert_blank_count
            ldn     rf
            lbz     ert_no_blank

            ldi     ' '
            call    K_TYPE

ert_no_blank:
            ; backspace count = (ert_pos - edit_cursor) + blank_count
            mov     rf, edit_cursor
            ldn     rf
            str     r2                  ; M(X) = edit_cursor (subtrahend)
            mov     rf, ert_pos
            ldn     rf                  ; D = ert_pos (minuend)
            sm                          ; D = ert_pos - edit_cursor = tail_len
            plo     r8                  ; stash (mov below clobbers D)

            mov     rf, ert_blank_count
            ldn     rf
            str     r2                  ; M(X) = blank_count
            glo     r8                  ; D = tail_len (reloaded)
            add                         ; D = tail_len + blank_count
            plo     r8                  ; stash (mov below clobbers D)
            mov     rf, ert_bscount
            glo     r8
            str     rf

ert_backspace_loop:
            mov     rf, ert_bscount
            ldn     rf
            lbz     ert_backspace_done

            ldi     8
            call    K_TYPE

            mov     rf, ert_bscount
            ldn     rf
            smi     1
            str     rf
            lbr     ert_backspace_loop

ert_backspace_done:
            rtn

;------------------------------------------------------------------
; edit_insert_char: insert RC.0 into LINE_BUF at edit_cursor, shifting
; the existing tail (including the NUL terminator) right by one, then
; redraw and advance the cursor. Caller has already confirmed there's
; room (hist_cur_len < 127).
;
; The shift loop is a POST-test loop (copy first, then check whether
; that was the last needed copy) rather than the more obvious pre-
; test-then-decrement shape -- independently verified via a byte-
; accurate mechanical simulation (not just a high-level model) that a
; pre-test/decrement loop breaks at cursor==0 with an empty line: the
; loop counter would need to go to -1 to signal "done", but as an
; unsigned byte it wraps to 255 instead, and a naive unsigned
; comparison would then incorrectly treat 255 as "still >= 0" and
; keep looping. The post-test shape never decrements past the target,
; sidestepping the whole issue -- see the plan file for the full
; derivation.
; Args:    RC.0 = character to insert
; Returns: nothing
; Modifies: R7, R8, R9, RB, RF (and D)
;------------------------------------------------------------------
edit_insert_char:
            mov     rb, eic_i
            mov     rf, hist_cur_len
            ldn     rf
            str     rb                  ; eic_i = hist_cur_len (shift
                                        ; starts from the end, working
                                        ; backward, to avoid clobbering
                                        ; not-yet-moved bytes)

eic_shift_loop:
            mov     rf, eic_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = i (zero-extended)
            mov     rf, LINE_BUF
            add16   rf, r8              ; RF = &LINE_BUF[i]
            ldn     rf                  ; D = LINE_BUF[i]
            plo     r9                  ; stash (mov below clobbers D)
            inc     rf                  ; RF = &LINE_BUF[i+1]
            glo     r9
            str     rf                  ; LINE_BUF[i+1] = LINE_BUF[i]

            ; was that the last needed copy (i == edit_cursor)? see
            ; this routine's own header for why this is a post-test
            mov     rf, edit_cursor
            ldn     rf
            str     r2                  ; M(X) = edit_cursor
            mov     rf, eic_i
            ldn     rf                  ; D = i
            sm                          ; D = i - edit_cursor
            lbz     eic_shift_done      ; i == edit_cursor: done

            mov     rf, eic_i
            ldn     rf
            smi     1
            str     rf                  ; i--
            lbr     eic_shift_loop

eic_shift_done:
            ; ert_start = edit_cursor (the OLD, pre-increment value --
            ; must be captured here, before edit_cursor advances below)
            mov     rb, ert_start
            mov     rf, edit_cursor
            ldn     rf
            str     rb                  ; ert_start = edit_cursor (OLD)

            mov     rf, edit_cursor
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, LINE_BUF
            add16   rf, r8
            glo     rc
            str     rf                  ; LINE_BUF[edit_cursor] = char
                                        ; (still the OLD value here)

            mov     rf, hist_cur_len
            ldn     rf
            adi     1
            str     rf                  ; hist_cur_len++

            mov     rf, edit_cursor
            ldn     rf
            adi     1
            str     rf                  ; edit_cursor++ (now FINAL)

            ldi     0                   ; blank_count = 0 (insert)
            call    edit_redraw_tail
            rtn

;------------------------------------------------------------------
; edit_delete_at: delete the character at LINE_BUF[hole], shifting
; LINE_BUF[hole+1..hist_cur_len] (including the NUL) left by one, then
; decrement hist_cur_len and redraw. Does NOT touch edit_cursor OR
; ert_start -- the CALLER must set both to their final values BEFORE
; calling (edit_cursor = the resting position after the delete; for
; Ctrl-D that's unchanged/hole, for backspace that's hole too, but the
; caller writes it explicitly either way; ert_start = hole in both
; cases, since that's where the visible content actually changed and
; -- critically -- where the terminal's own PHYSICAL cursor must
; already be sitting by the time edit_redraw_tail runs: for Ctrl-D the
; cursor never moves, so it's already there; for backspace the caller
; must print one explicit backspace first to move it there, since the
; physical cursor starts one position to the right of hole). Caller
; has already confirmed hole < hist_cur_len.
; Args:    D = hole (position to delete)
; Returns: nothing
; Modifies: R7, R8, R9, RF (and D)
;------------------------------------------------------------------
edit_delete_at:
            plo     r9
            mov     rf, eda_i
            glo     r9
            str     rf                  ; eda_i = hole

eda_shift_loop:
            ; pre-test is safe here (unlike the insert loop) since i
            ; only ever increases -- no underflow risk
            mov     rf, hist_cur_len
            ldn     rf
            str     r2                  ; M(X) = hist_cur_len
            mov     rf, eda_i
            ldn     rf                  ; D = i
            sm                          ; D = i - hist_cur_len, DF=1 if
                                        ; i >= hist_cur_len (no borrow)
            lbdf    eda_shift_done

            mov     rf, eda_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, LINE_BUF
            add16   rf, r8              ; RF = &LINE_BUF[i]
            inc     rf                  ; RF = &LINE_BUF[i+1]
            ldn     rf                  ; D = LINE_BUF[i+1]
            plo     r9                  ; stash (mov below clobbers D)

            mov     rf, eda_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, LINE_BUF
            add16   rf, r8              ; RF = &LINE_BUF[i]
            glo     r9
            str     rf                  ; LINE_BUF[i] = LINE_BUF[i+1]

            mov     rf, eda_i
            ldn     rf
            adi     1
            str     rf                  ; i++
            lbr     eda_shift_loop

eda_shift_done:
            mov     rf, hist_cur_len
            ldn     rf
            smi     1
            str     rf                  ; hist_cur_len--

            ldi     1                   ; blank_count = 1 (delete)
            call    edit_redraw_tail
            rtn

;------------------------------------------------------------------
; rlwh_home/rlwh_end/rlwh_left/rlwh_right/rlwh_delete_at: Ctrl-A/E/B/F/D
; and (via rlwh_escape) the Left/Right arrow equivalents. Plain jump
; targets, not call/return subroutines -- each ends with "lbr
; rlwh_loop" directly, reached via lbz from both the main dispatch
; chain and rlwh_escape.
;------------------------------------------------------------------
rlwh_home:
            mov     rf, edit_cursor
            ldn     rf
            lbz     rlwh_loop           ; already at 0: no-op

            mov     rf, rh_count
            mov     rb, edit_cursor
            ldn     rb
            str     rf                  ; rh_count = edit_cursor

rh_bs_loop:
            mov     rf, rh_count
            ldn     rf
            lbz     rh_done

            ldi     8
            call    K_TYPE

            mov     rf, rh_count
            ldn     rf
            smi     1
            str     rf
            lbr     rh_bs_loop

rh_done:
            mov     rf, edit_cursor
            ldi     0
            str     rf
            lbr     rlwh_loop

rlwh_end:
            mov     rf, edit_cursor
            ldn     rf
            str     r2                  ; M(X) = edit_cursor
            mov     rf, hist_cur_len
            ldn     rf
            sm                          ; D = hist_cur_len - edit_cursor
            lbz     rlwh_loop           ; already at end: no-op

            mov     rb, re_pos
            mov     rf, edit_cursor
            ldn     rf
            str     rb                  ; re_pos = edit_cursor

re_print_loop:
            mov     rf, re_pos
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, LINE_BUF
            add16   rf, r8
            ldn     rf
            lbz     re_print_done       ; NUL: done

            call    K_TYPE

            mov     rf, re_pos
            ldn     rf
            adi     1
            str     rf
            lbr     re_print_loop

re_print_done:
            mov     rb, edit_cursor
            mov     rf, hist_cur_len
            ldn     rf
            str     rb                  ; edit_cursor = hist_cur_len
            lbr     rlwh_loop

rlwh_left:
            mov     rf, edit_cursor
            ldn     rf
            lbz     rlwh_loop           ; already at 0: no-op

            smi     1
            plo     r8                  ; stash (mov below clobbers D)
            mov     rf, edit_cursor
            glo     r8
            str     rf                  ; edit_cursor--

            ldi     8
            call    K_TYPE
            lbr     rlwh_loop

rlwh_right:
            mov     rf, edit_cursor
            ldn     rf
            str     r2                  ; M(X) = edit_cursor
            mov     rf, hist_cur_len
            ldn     rf
            sm                          ; D = hist_cur_len - edit_cursor
            lbz     rlwh_loop           ; already at end: no-op

            mov     rf, edit_cursor
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     rf, LINE_BUF
            add16   rf, r8
            ldn     rf                  ; D = LINE_BUF[edit_cursor] --
                                        ; the character about to be
                                        ; passed over
            call    K_TYPE

            mov     rf, edit_cursor
            ldn     rf
            adi     1
            str     rf                  ; edit_cursor++
            lbr     rlwh_loop

rlwh_delete_at:
            mov     rf, edit_cursor
            ldn     rf
            str     r2                  ; M(X) = edit_cursor
            mov     rf, hist_cur_len
            ldn     rf
            sm                          ; D = hist_cur_len - edit_cursor
            lbz     rlwh_loop           ; at end: nothing to delete

            ; Ctrl-D doesn't move the cursor -- it stays at hole, which
            ; is also where the terminal's own physical cursor already
            ; sits (nothing has moved it), so ert_start = edit_cursor
            ; unchanged, and edit_cursor itself needs no rewrite
            mov     rb, ert_start
            mov     rf, edit_cursor
            ldn     rf
            str     rb                  ; ert_start = edit_cursor (=hole)

            mov     rf, edit_cursor
            ldn     rf                  ; D = hole = edit_cursor
            call    edit_delete_at
            lbr     rlwh_loop

rlwh_backspace:
            mov     rf, edit_cursor
            ldn     rf
            lbz     rlwh_loop           ; at start: no-op

            smi     1                   ; D = edit_cursor - 1 = hole
            plo     r8                  ; stash hole (mov below clobbers D)

            mov     rb, ert_start
            glo     r8
            str     rb                  ; ert_start = hole

            mov     rf, edit_cursor
            glo     r8
            str     rf                  ; edit_cursor = hole (its FINAL
                                        ; value -- must be set BEFORE
                                        ; calling edit_delete_at, since
                                        ; edit_redraw_tail reads it as
                                        ; the backspace target)

            ; move the terminal's own PHYSICAL cursor from its current
            ; position (one past hole) back to hole BEFORE the shift+
            ; redraw runs -- edit_redraw_tail's own print loop starts
            ; from ert_start and assumes the physical cursor is already
            ; sitting there (true for Ctrl-D, where the cursor never
            ; moves, but NOT true for backspace without this explicit
            ; step first)
            ldi     8
            call    K_TYPE

            ; D = hole -- reloaded fresh from memory (edit_cursor
            ; already holds it, stored above), never trusted in R8
            ; across the K_TYPE call (its own clobber footprint isn't
            ; proven, gotcha #8/#10)
            mov     rf, edit_cursor
            ldn     rf
            call    edit_delete_at

            lbr     rlwh_loop

rlwh_escape:
            call    f_uread             ; direct BIOS call, not K_READ
                                        ; -- see below
            plo     rc                  ; RC.0 = byte immediately after ESC

            ; The terminal sends real ANSI/VT100 "ESC [ A"/"ESC [ B" --
            ; an earlier bare-ESC-letter theory turned out to be wrong,
            ; see the CLAUDE.md write-up for the full history. What
            ; actually happened: K_READ's own two-layer indirection
            ; (kernel jump table, then the BIOS's own internal RAM-
            ; vector redirect) was slow enough, between this routine's
            ; own per-byte branching, to lose the '[' byte to the
            ; UART's single-byte holding register being overwritten by
            ; 'A'/'B' before it was ever read -- the exact bug
            ; progs/mr.asm/progs/ms.asm already hit and fixed the same
            ; way (see their own header comments): call the raw BIOS
            ; entry point (f_uread, EBIOS+0Ch) directly, skipping both
            ; indirection hops. Every read in this routine goes through
            ; f_uread instead of K_READ for that reason -- input
            ; redirection never applies to this call site anyway (see
            ; the section header comment above), so nothing is lost by
            ; bypassing K_READ's own redirect-aware dispatch.
            ;
            ; HARDWARE-CONFIRMED 2026-07-23, including a test round that
            ; specifically ruled out a masked failure: a bare-letter
            ; ("ESC A"/"ESC B", no bracket) fallback was tried first as
            ; defense-in-depth, then deliberately removed for one test
            ; round specifically because its presence couldn't
            ; distinguish "the real CSI path arrives intact" from "'['
            ; is still being dropped and we're silently landing on the
            ; fallback every time" -- recall worked with ONLY the real
            ; CSI path reachable, confirming f_uread actually fixed the
            ; byte-drop rather than papering over it. Deliberately left
            ; out permanently (the user's own call): accepting a
            ; malformed sequence here would risk masking a real
            ; regression the same way, e.g. if a future baud-rate change
            ; or the bit-bang UART path reintroduces byte loss -- better
            ; for Up/Down to visibly stop working than to silently
            ; degrade to whatever partial byte arrived.
            glo     rc
            xri     '['
            lbnz    rlwh_loop           ; neither form: discard, continue

            call    f_uread
            plo     rc
            glo     rc
            xri     'A'
            lbz     rlwh_up
            glo     rc
            xri     'B'
            lbz     rlwh_down
            glo     rc
            xri     'C'                 ; Right arrow -- same CSI
                                        ; family as the already-proven
                                        ; Up/Down, confirmed by the
                                        ; user (2026-07-27)
            lbz     rlwh_right
            glo     rc
            xri     'D'                 ; Left arrow
            lbz     rlwh_left

            ; Del key: "ESC [ 3 ~", a 4-byte sequence (vs. the 3-byte
            ; "ESC [ A"-style arrows above) -- '3' here means a THIRD
            ; byte is still expected before this sequence is complete,
            ; unlike A/B/C/D which terminate the sequence immediately.
            glo     rc
            xri     '3'
            lbnz    rlwh_loop           ; unrecognized: discard

            call    f_uread             ; read the expected '~' terminator
            plo     rc
            glo     rc
            xri     '~'
            lbnz    rlwh_loop           ; malformed: discard rather than
                                        ; guess -- same "never accept a
                                        ; partial/malformed sequence"
                                        ; philosophy as the Up/Down
                                        ; byte-drop fix above
            lbr     rlwh_delete_at      ; Del: same as Ctrl-D, delete
                                        ; the character under the
                                        ; cursor (distinct from
                                        ; backspace/Ctrl-H, which
                                        ; deletes the character BEFORE
                                        ; the cursor)

rlwh_up:
            call    hist_recall_up
            lbr     rlwh_loop

rlwh_down:
            call    hist_recall_down
            lbr     rlwh_loop

rlwh_finish:
            rtn

;------------------------------------------------------------------
; hist_copy_entry: copy hist_lines[index] (a NUL-terminated pointer
; into hist_buf) into LINE_BUF.
; Args:    D = index into hist_lines
; Returns: nothing
; Modifies: R8, RD, RF (and D)
;------------------------------------------------------------------
hist_copy_entry:
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = index * 2
            mov     rf, hist_lines
            add16   rf, r8              ; RF = &hist_lines[index]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = hist_lines[index]

            mov     rf, rd
            mov     rd, LINE_BUF
hce_loop:
            lda     rf
            str     rd
            lbz     hce_done
            inc     rd
            lbr     hce_loop
hce_done:
            rtn

;------------------------------------------------------------------
; hist_redraw_linebuf: erase the currently-displayed hist_cur_len
; characters and reprint LINE_BUF's CURRENT content -- caller has
; already written the new content into LINE_BUF before calling this.
; The erase-count is kept in memory, not a register, across the
; repeated K_TYPE calls (gotcha #8/#10 -- only R9 is confirmed to
; survive these, and it isn't used here).
; Args:    none (reads hist_cur_len, LINE_BUF)
; Returns: nothing (hist_cur_len updated to LINE_BUF's new length)
; Modifies: RC, RD, RF (and D)
;------------------------------------------------------------------
hist_redraw_linebuf:
            mov     rf, hist_erase_count
            mov     rb, hist_cur_len
            ldn     rb
            str     rf

hrl_erase_loop:
            mov     rf, hist_erase_count
            ldn     rf
            lbz     hrl_erase_done

            ldi     8
            call    K_TYPE
            ldi     ' '
            call    K_TYPE
            ldi     8
            call    K_TYPE

            mov     rf, hist_erase_count
            ldn     rf
            smi     1
            str     rf
            lbr     hrl_erase_loop

hrl_erase_done:
            mov     rf, LINE_BUF
            call    shell_strlen        ; RC = new length, RF unchanged
            mov     rf, hist_cur_len
            glo     rc
            str     rf

            mov     rf, edit_cursor
            glo     rc
            str     rf                  ; edit_cursor = new length (end)
                                        ; -- recalling a history entry
                                        ; or restoring the originally-
                                        ; typed line places the cursor
                                        ; at the end, matching standard
                                        ; bash/DOS behavior (2026-07-27)

            mov     rf, LINE_BUF
            call    K_MSG

            rtn

;------------------------------------------------------------------
; hist_recall_up: Up arrow -- lazy-load history on first use, then
; move to an older entry (clamped at the oldest loaded one).
;------------------------------------------------------------------
hist_recall_up:
            mov     rf, hist_loaded
            ldn     rf
            lbnz    hru_loaded

            call    hist_load

hru_loaded:
            mov     rf, hist_count
            ldn     rf
            lbz     hru_none            ; no history at all: no-op

            mov     rf, hist_recalling
            ldn     rf
            lbnz    hru_move

            ; first recall this session: save the line as currently
            ; typed, so Down can restore it later
            mov     rf, hist_recalling
            ldi     1
            str     rf

            mov     rf, LINE_BUF
            mov     rd, hist_saved_line
hru_save_loop:
            lda     rf
            str     rd
            lbz     hru_save_done
            inc     rd
            lbr     hru_save_loop
hru_save_done:

            ; start at the newest entry: index = hist_count - 1
            mov     rf, hist_count
            ldn     rf
            smi     1
            plo     r8
            mov     rb, hist_index
            glo     r8
            str     rb
            lbr     hru_redraw

hru_move:
            mov     rf, hist_index
            ldn     rf
            lbz     hru_redraw          ; already oldest: redraw as-is

            smi     1
            plo     r8
            mov     rb, hist_index
            glo     r8
            str     rb

hru_redraw:
            mov     rf, hist_index
            ldn     rf
            call    hist_copy_entry
            call    hist_redraw_linebuf
hru_none:
            rtn

;------------------------------------------------------------------
; hist_recall_down: Down arrow -- move to a newer entry, or (if
; already at the newest loaded one) restore the originally-typed
; line. No-op if not currently recalling.
;------------------------------------------------------------------
hist_recall_down:
            mov     rf, hist_recalling
            ldn     rf
            lbz     hrd_none            ; not currently recalling: no-op

            mov     rf, hist_count
            ldn     rf
            smi     1
            plo     r8                  ; R8.0 = newest_index

            mov     rf, hist_index
            ldn     rf
            str     r2                  ; M(R2) = hist_index
            glo     r8
            xor                         ; D = newest_index XOR hist_index
            lbz     hrd_restore         ; equal: at the newest, restore

            mov     rf, hist_index
            ldn     rf
            adi     1
            plo     r9
            mov     rb, hist_index
            glo     r9
            str     rb

            mov     rf, hist_index
            ldn     rf
            call    hist_copy_entry
            call    hist_redraw_linebuf
hrd_none:
            rtn

hrd_restore:
            mov     rf, hist_recalling
            ldi     0
            str     rf

            mov     rf, hist_saved_line
            mov     rd, LINE_BUF
hrd_restore_loop:
            lda     rf
            str     rd
            lbz     hrd_restore_done
            inc     rd
            lbr     hrd_restore_loop
hrd_restore_done:
            call    hist_redraw_linebuf
            rtn

;------------------------------------------------------------------
; hist_load: lazily load the tail of the history file into hist_buf
; and split it into lines. Called at most once per shell invocation
; (hist_loaded guards a repeat call -- see hist_recall_up, the only
; caller). A missing file, or any I/O error along the way, just
; leaves hist_count at 0 -- Up is then a quiet no-op, matching this
; project's generally quiet style for a non-essential convenience.
; Args:    none
; Returns: nothing (hist_lines/hist_count/hist_loaded set)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF (and D)
;------------------------------------------------------------------
hist_load:
            mov     rf, hist_loaded
            ldi     1
            str     rf

            mov     rf, hist_count
            ldi     0
            str     rf

            mov     rf, hist_loaded_len
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; safe default (both bytes --
                                        ; a word since the 2026-07-25
                                        ; budget widening) if any early
                                        ; exit below skips the real read
                                        ; (hist_split then just scans 0
                                        ; bytes)

            ; build hist_path = "<shell_drive letter>:/bin/history.dat"
            call    K_GETSHELLDRIVE     ; D = shell_drive (0-3) --
                                        ; kernel_getshelldrive's own
                                        ; body uses RF as scratch, so RF
                                        ; can't be set before this call
                                        ; either -- must come after
            adi     'C'
            plo     r8                  ; stash the drive letter (R8
                                        ; survives the mov below; gotcha
                                        ; #4 -- mov itself clobbers D)
            mov     rf, hist_path
            glo     r8
            str     rf
            inc     rf
            ldi     ':'
            str     rf
            inc     rf
            mov     rd, hist_suffix
hl_path_loop:
            lda     rd
            str     rf
            lbz     hl_path_done
            inc     rf
            lbr     hl_path_loop
hl_path_done:

            mov     rd, hist_fcb
            mov     ra, hist_iobuf
            mov     rf, hist_path
            ldi     0                   ; mode 0: read
            call    K_FILE_OPEN
            lbdf    hl_done             ; doesn't exist / open failed:
                                        ; hist_count stays 0

            ; SEEK_END(0) -> file size
            ldi     0
            phi     ra
            plo     ra
            ldi     0
            phi     r9
            plo     r9
            ldi     2                   ; SEEK_END
            plo     rc
            mov     rd, hist_fcb
            call    K_FILE_SEEK
            lbdf    hl_close            ; seek failed: treat as no
                                        ; history (hist_loaded_len is
                                        ; already 0)

            mov     rf, hist_filesize
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; start_offset = max(0, filesize - HISTORY_LOAD_BUDGET)
            mov     rf, hist_filesize
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = filesize
            sub16   rd, HISTORY_LOAD_BUDGET
            lbdf    hl_have_start       ; DF=1: no underflow
            ldi     0
            phi     rd
            plo     rd                  ; clamp to 0

hl_have_start:
            mov     rf, hist_start_offset
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; SEEK_SET(start_offset). KNOWN LIMITATION: K_FILE_SEEK's
            ; documented offset convention only supports a value that's
            ; a valid sign-extension of 16 bits (RA=$0000 with bit 15
            ; clear -- i.e. 0-32767; RA=$FFFF with bit 15 set covers
            ; negative offsets, not used here). start_offset is always
            ; a non-negative 16-bit quantity, but once the history file
            ; grows past ~32KB it can itself exceed 32767, at which
            ; point this SEEK_SET starts failing K_FILE_SEEK's own
            ; range check -- lbdf hl_close below treats that exactly
            ; like "no history this session" (graceful, not a crash),
            ; so the practical effect is just that recall quietly stops
            ; working once the file crosses that size, not a bug this
            ; shell-side code can work around without a kernel change
            ; to K_FILE_SEEK's own offset convention. Not expected to
            ; matter for a long time at realistic usage (roughly
            ; 1500-3000+ typical command lines), but worth knowing.
            mov     rf, hist_start_offset
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ldi     0
            phi     ra
            plo     ra
            ldi     0                   ; SEEK_SET
            plo     rc
            mov     rd, hist_fcb
            call    K_FILE_SEEK
            lbdf    hl_close

            ; read_len = filesize - start_offset (always < BUDGET by
            ; construction -- see start_offset's own clamp above)
            mov     rf, hist_filesize
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, hist_start_offset
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            sub16   rd, r8              ; RD = read_len

            mov     rc, rd              ; RC = read_len (byte count)
            mov     rf, hist_buf
            mov     rd, hist_fcb
            call    K_FILE_READ         ; RC = bytes actually read

            mov     rf, hist_loaded_len
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; word (2026-07-25 widening) --
                                        ; RC = bytes actually read,
                                        ; always <= HISTORY_LOAD_BUDGET
                                        ; by construction

hl_close:
            mov     rd, hist_fcb
            call    K_FILE_CLOSE

            call    hist_split

hl_done:
            rtn

;------------------------------------------------------------------
; hist_split: split hist_buf[0..hist_loaded_len) into lines (LF ->
; NUL, recording each start pointer into hist_lines[]), discarding a
; leading partial fragment if hist_start_offset > 0, and any empty
; span (including a trailing one, since every real append ends in a
; real LF). No calls made anywhere in this loop, so scan state stays
; in registers throughout -- only the final hist_lines[]/hist_count
; results are written to memory.
; Args:    none (reads hist_buf/hist_loaded_len/hist_start_offset)
; Returns: nothing (hist_lines/hist_count populated)
; Modifies: R7, R8, R9, RB, RC, RD, RF (and D)
;------------------------------------------------------------------
hist_split:
            mov     r7, hist_buf        ; R7 = scan pointer
            mov     r8, hist_buf        ; R8 = current line's start
            ldi     0
            phi     r9                  ; R9.1 = "first span already
                                        ; seen" flag (see guard 2 below
                                        ; -- deliberately NOT the same
                                        ; thing as hist_count, which
                                        ; only increments on a RECORDED
                                        ; entry)
            plo     r9                  ; R9.0 = hist_count so far

            mov     rf, hist_loaded_len
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = remaining bytes (word,
                                        ; 2026-07-25 widening)

hsplit_loop:
            glo     rc
            lbnz    hsplit_have_bytes   ; low byte nonzero: definitely
                                        ; more than 0 left, regardless
                                        ; of the high byte
            ghi     rc
            lbz     hsplit_end          ; both bytes 0: truly done
                                        ; (falls through to
                                        ; hsplit_have_bytes otherwise --
                                        ; high nonzero, low zero, e.g.
                                        ; RC=256, still bytes left)
hsplit_have_bytes:

            ldn     r7                  ; D = *scan_ptr
            xri     10                  ; is it LF?
            lbnz    hsplit_advance

            ldi     0
            str     r7                  ; NUL it out in place

            ; guard 1: empty span? (line_start == scan_ptr)
            glo     r8
            str     r2
            glo     r7
            sm
            lbnz    hsplit_g2           ; low bytes differ: not empty
            ghi     r8
            str     r2
            ghi     r7
            sm
            lbz     hsplit_next_line    ; both bytes equal: empty, skip

hsplit_g2:
            ; guard 2: the very first span encountered in this scan
            ; (regardless of whether it ends up recorded or
            ; discarded), AND we started reading mid-file
            ; (hist_start_offset > 0)? presumed partial, discard.
            ;
            ; BUG CAUGHT BY INDEPENDENT PYTHON SIMULATION (before ever
            ; assembling): this used to test hist_count (R9.0) instead
            ; of a dedicated flag -- but hist_count only increments on
            ; a RECORDED entry, so if the true first (partial) span
            ; was itself discarded here, hist_count was STILL 0 when
            ; the very next (real, complete) span was scanned, wrongly
            ; re-triggering this same discard a second time. R9.1 is a
            ; separate flag, set unconditionally the moment the first
            ; LF is seen, so this guard only ever fires once per scan
            ; regardless of what happened to that first span.
            ghi     r9
            lbnz    hsplit_g3           ; already seen a first span:
                                        ; this guard never applies again

            ldi     1
            phi     r9                  ; mark "first span seen" now,
                                        ; whether it's kept or discarded

            mov     rf, hist_start_offset
            lda     rf
            lbnz    hsplit_next_line
            ldn     rf
            lbnz    hsplit_next_line

hsplit_g3:
            ; guard 3: at capacity? REAL BUG, found from a hardware
            ; report (2026-07-25): this used to just stop recording
            ; once hist_count reached HISTORY_MAX_LINES -- but the
            ; scan runs oldest-to-newest through the loaded window, so
            ; once the window holds MORE than HISTORY_MAX_LINES
            ; complete lines (easy with short commands -- the window
            ; is 255 bytes), hist_lines[] filled with the OLDEST
            ; HISTORY_MAX_LINES lines in the window and every NEWER
            ; line after that was scanned but silently never recorded.
            ; hist_recall_up's "newest = hist_count-1" then pointed at
            ; a stale entry, and Down could never reach anything past
            ; it, since the true newest lines were never in the array
            ; at all -- exactly "Up gives a command from several back,
            ; further presses anchored there." Fixed: once full, shift
            ; the array down by one slot (dropping the oldest, slot 0)
            ; and always write the new entry into the last slot, so
            ; hist_lines[hist_count-1] is always the true newest line
            ; seen so far, capped at the most recent HISTORY_MAX_LINES.
            glo     r9
            smi     HISTORY_MAX_LINES
            lbdf    hsplit_full         ; hist_count >= MAX: shift,
                                        ; don't just stop recording

            ; --- room available: append normally, hist_count++ ---
            mov     rf, hist_lines
            glo     r9
            plo     rd
            ldi     0
            phi     rd
            shl16   rd                  ; RD = hist_count * 2
            add16   rf, rd              ; RF = &hist_lines[hist_count]
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            glo     r9
            adi     1
            plo     r9                  ; hist_count++
            lbr     hsplit_next_line

hsplit_full:
            ; shift hist_lines[1..MAX-1] down to [0..MAX-2] (2 bytes/
            ; entry), dropping the oldest slot -- R7/R8/R9/RC are all
            ; live across the OUTER scan loop and must survive this,
            ; so only RF/RD/RB (confirmed unused elsewhere in this
            ; proc) are used as scratch here. hist_count (R9.0) stays
            ; pinned at HISTORY_MAX_LINES -- already at capacity, and
            ; this path doesn't change that.
            mov     rd, hist_lines
            inc     rd
            inc     rd                  ; RD = &hist_lines[1] (source)
            mov     rf, hist_lines      ; RF = &hist_lines[0] (dest)
            ldi     (HISTORY_MAX_LINES-1)*2
            plo     rb
hsplit_shift_loop:
            glo     rb
            lbz     hsplit_shift_done
            lda     rd
            str     rf
            inc     rf
            glo     rb
            smi     1
            plo     rb
            lbr     hsplit_shift_loop
hsplit_shift_done:
            ; RF now points exactly at hist_lines[MAX-1] (the last
            ; slot) -- write the new entry (R8 = its line-start
            ; pointer) there
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

hsplit_next_line:
            mov     r8, r7
            inc     r8                  ; next line starts right after
                                        ; this LF

hsplit_advance:
            inc     r7
            sub16   rc, 1               ; word decrement (2026-07-25
                                        ; widening) -- must borrow
                                        ; across the byte boundary
                                        ; correctly, unlike the old
                                        ; single-byte smi
            lbr     hsplit_loop

hsplit_end:
            mov     rf, hist_count
            glo     r9
            str     rf
            rtn

;------------------------------------------------------------------
; hist_append: append LINE_BUF to the history file if it's non-blank
; (an all-whitespace or empty line is not recorded). Best-effort --
; any I/O failure here is silently ignored, matching this feature's
; "a convenience, never something that should block a command" role.
; Rebuilds hist_path itself (cheap) rather than relying on hist_load
; having already run this session -- Enter can happen with no recall
; ever attempted.
; Args:    none (reads LINE_BUF)
; Returns: nothing
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF (and D)
;------------------------------------------------------------------
hist_append:
            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char
            ldn     rf
            lbz     ha_done             ; blank line: don't record it

            call    K_GETSHELLDRIVE     ; D = shell_drive (0-3) --
                                        ; kernel_getshelldrive's own
                                        ; body uses RF as scratch, so RF
                                        ; can't be set before this call
                                        ; either -- must come after
            adi     'C'
            plo     r8                  ; stash the drive letter (R8
                                        ; survives the mov below; gotcha
                                        ; #4 -- mov itself clobbers D)
            mov     rf, hist_path
            glo     r8
            str     rf
            inc     rf
            ldi     ':'
            str     rf
            inc     rf
            mov     rd, hist_suffix
ha_path_loop:
            lda     rd
            str     rf
            lbz     ha_path_done
            inc     rf
            lbr     ha_path_loop
ha_path_done:

            mov     rd, hist_fcb
            mov     ra, hist_iobuf
            mov     rf, hist_path
            ldi     2                   ; mode 2: create-or-append
            call    K_FILE_OPEN
            lbdf    ha_done             ; couldn't open: give up quietly

            mov     rf, LINE_BUF
            call    shell_strlen        ; RC = length, RF unchanged
            mov     rf, LINE_BUF
            mov     rd, hist_fcb
            call    K_FILE_WRITE

            mov     rf, hist_nl_byte
            ldi     1
            plo     rc
            ldi     0
            phi     rc
            mov     rd, hist_fcb
            call    K_FILE_WRITE        ; trailing LF

            mov     rd, hist_fcb
            call    K_FILE_CLOSE

            call    hist_compact        ; bound history.dat's growth --
                                        ; a no-op unless it's grown
                                        ; past HISTORY_COMPACT_THRESHOLD

ha_done:
            rtn

;------------------------------------------------------------------
; hist_compact: if history.dat has grown past
; HISTORY_COMPACT_THRESHOLD bytes, rewrite it down to just the tail
; hist_load would ever read anyway (recall never looks further back
; than HISTORY_LOAD_BUDGET bytes from the end, so keeping more than
; that provides zero value) via a crash-safe temp-file-then-rename
; swap, matching lib/env.asm's own setenv/unsetenv pattern. Called
; from hist_append right after a successful append+close.
; Args:    none (reads hist_path, already built by the caller)
; Returns: nothing. Any failure along the way (can't stat, can't
;          create the temp file, delete/rename failure) is given up
;          on silently, leaving the real history.dat exactly as it
;          was (oversized but intact) -- compaction is a housekeeping
;          nicety, never allowed to risk losing real history data.
;------------------------------------------------------------------
hist_compact:
            mov     rf, hist_path
            mov     rd, stat_result     ; reuse the shared scratch
                                        ; buffer -- not live here,
                                        ; check_exists hasn't run yet
                                        ; this command cycle
            call    K_STAT
            lbdf    hc_done             ; can't stat (shouldn't
                                        ; happen, we just closed it):
                                        ; skip

            mov     rf, stat_result
            add16   rf, DIRENT_SIZE
            lda     rf                  ; byte 0 (MSB of the 4-byte
                                        ; big-endian size)
            lbnz    hc_go               ; nonzero: file is >= 16MB,
                                        ; way over any real threshold
            lda     rf                  ; byte 1
            lbnz    hc_go               ; nonzero: >= 64KB, also way
                                        ; over
            lda     rf                  ; byte 2 (high byte of the
                                        ; low 16 bits)
            phi     rd
            ldn     rf                  ; byte 3 (low byte)
            plo     rd                  ; RD = size (low 16 bits) --
                                        ; the top 2 bytes are 0, so
                                        ; this IS the real size
            sub16   rd, HISTORY_COMPACT_THRESHOLD
            lbnf    hc_done             ; DF=0 (borrow): under
                                        ; threshold, nothing to do

hc_go:
            call    hist_load           ; ALWAYS does a fresh
                                        ; tail-read+split when called
                                        ; directly -- the "only once
                                        ; per session" guard lives in
                                        ; hist_recall_up, checked
                                        ; BEFORE it decides to call
                                        ; hist_load, not inside
                                        ; hist_load itself -- so this
                                        ; picks up the line just
                                        ; appended, whether or not
                                        ; recall already ran earlier
                                        ; in this same command cycle.
                                        ; hist_lines[]/hist_count now
                                        ; hold exactly the tail worth
                                        ; keeping.

            ; build hist_tmp_path = "<same drive:>/bin/history.tmp"
            ; -- copy hist_path's own already-built drive+colon
            ; prefix rather than a second K_GETSHELLDRIVE call
            mov     rf, hist_path
            lda     rf                  ; D = drive letter, RF now ->
                                        ; the ':' byte
            plo     r8                  ; stash (R8 survives the mov
                                        ; below; gotcha #4)
            mov     rb, hist_tmp_path
            glo     r8
            str     rb
            inc     rb
            ldn     rf                  ; D = ':' (RF unmoved by ldn)
            str     rb
            inc     rb
            mov     rd, hist_tmp_suffix
hc_path_loop:
            lda     rd
            str     rb
            lbz     hc_path_done
            inc     rb
            lbr     hc_path_loop
hc_path_done:

            mov     rd, hist_tmp_fcb
            mov     ra, hist_tmp_iobuf
            mov     rf, hist_tmp_path
            ldi     1                   ; mode 1: create-or-overwrite
            call    K_FILE_OPEN
            lbdf    hc_done             ; can't create temp: give up,
                                        ; real history.dat left as-is

            mov     rf, hc_i
            ldi     0
            str     rf

hc_write_loop:
            mov     rf, hc_i
            ldn     rf
            str     r2
            mov     rf, hist_count
            ldn     rf
            sm                          ; D = hc_i - hist_count
            lbz     hc_write_done       ; hc_i reached hist_count

            mov     rf, hc_i
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            shl16   rd                  ; RD = hc_i * 2

            mov     rf, hist_lines
            add16   rf, rd              ; RF = &hist_lines[hc_i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = hist_lines[hc_i] (RD's
                                        ; old offset value is already
                                        ; consumed by the add16 above)

            mov     rf, rd
            call    shell_strlen        ; RC = length, RF unchanged
            mov     rd, hist_tmp_fcb
            call    K_FILE_WRITE

            mov     rf, hist_nl_byte
            ldi     1
            plo     rc
            ldi     0
            phi     rc
            mov     rd, hist_tmp_fcb
            call    K_FILE_WRITE        ; trailing LF

            mov     rf, hc_i
            ldn     rf
            adi     1
            str     rf                  ; hc_i++ (safe -- nothing
                                        ; checks DF right after)
            lbr     hc_write_loop

hc_write_done:
            mov     rd, hist_tmp_fcb
            call    K_FILE_CLOSE

            ; swap: delete the old file, rename the temp into place.
            ; A crash between these two leaves at worst no
            ; history.dat for one boot -- same caveat lib/env.asm's
            ; own setenv/unsetenv already accept.
            mov     rf, hist_path
            call    K_FILE_DELETE
            lbdf    hc_done             ; delete failed: give up,
                                        ; leaving BOTH files present
                                        ; (oversized original intact,
                                        ; harmless orphan .tmp)

            mov     rf, hist_tmp_path
            mov     rd, hist_name_bare
            call    K_FILE_RENAME

hc_done:
            rtn

tok_errlvl_pat:     db      "ERRORLEVEL",0  ; letters only -- the
                                            ; leading/trailing '%' are
                                            ; checked exactly, in code,
                                            ; not folded (see
                                            ; tok_ordinary's own header)
tok_errlvl_buf:     ds      4           ; up to 3 decimal digits + NUL

; check_special (IF/GOTO dispatch) scratch data
if_idx:             db      0           ; current argv[] index being
                                        ; consumed while parsing IF's
                                        ; own condition
if_negate:          db      0           ; 0/1 -- IF NOT seen?
if_argc:            db      0           ; a copy of RUN_ARGC's own low
                                        ; byte, snapshotted once at
                                        ; if_start so it survives
                                        ; if_idx's own advancement
if_pat_if:          db      "IF",0
if_pat_not:         db      "NOT",0
if_pat_exist:       db      "EXIST",0
if_pat_goto:        db      "GOTO",0

hist_fcb:           ds      FCB_LEN
hist_iobuf:         ds      FCB_IOBUF_LEN
hist_path:          ds      24
hist_suffix:        db      "/bin/history.dat",0
hist_nl_byte:       db      10
hist_buf:           ds      HISTORY_LOAD_BUDGET
hist_lines:         ds      HISTORY_MAX_LINES * 2
hist_count:         db      0
hist_loaded:        db      0
hist_loaded_len:     dw      0
hist_recalling:     db      0
hist_index:         db      0
hist_saved_line:    ds      128
hist_filesize:      dw      0
hist_start_offset:  dw      0
hist_cur_len:       db      0
hist_erase_count:   db      0

; Mid-line cursor editing (2026-07-27) -- see read_line_with_history's
; own header comment above for the full design.
edit_cursor:        db      0           ; position within LINE_BUF,
                                        ; 0..hist_cur_len
ert_blank_count:    db      0           ; edit_redraw_tail's own arg
ert_start:          db      0           ; edit_redraw_tail's own print-
                                        ; start position, set by the
                                        ; caller -- distinct from
                                        ; edit_cursor (the backspace
                                        ; target), see edit_redraw_tail's
                                        ; own header for why these two
                                        ; positions can differ
ert_pos:            db      0           ; edit_redraw_tail's own print
                                        ; cursor
ert_bscount:        db      0           ; edit_redraw_tail's own
                                        ; backspace-loop counter
eic_i:              db      0           ; edit_insert_char's own
                                        ; shift-loop index
eda_i:              db      0           ; edit_delete_at's own
                                        ; shift-loop index
rh_count:           db      0           ; rlwh_home's own backspace-
                                        ; loop counter
re_pos:             db      0           ; rlwh_end's own print cursor

hist_tmp_fcb:       ds      FCB_LEN
hist_tmp_iobuf:     ds      FCB_IOBUF_LEN
hist_tmp_path:      ds      24
hist_tmp_suffix:    db      "/bin/history.tmp",0
hist_name_bare:     db      "history.dat",0
hc_i:               db      0

            end     start
