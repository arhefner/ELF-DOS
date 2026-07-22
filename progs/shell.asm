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

            call    print_prompt

            mov     rf, LINE_BUF
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     start_have_line

start_interactive:
            call    print_prompt

            mov     rf, LINE_BUF
            ldi     127
            plo     rc
            ldi     0
            phi     rc                  ; RC = 127 (buffer length for K_INPUTL)
            call    K_INPUTL

            call    K_INMSG
            db      13,10,0

start_have_line:
            ; skip leading whitespace
            mov     rf, LINE_BUF
            call    f_ltrim             ; RF = first non-space char

            ; empty line? just re-prompt -- no kernel round-trip needed
            ldn     rf
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
            lbnz    tok_ordinary

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
            lbnz    tok_ordinary
            ldi     0
            plo     r8                  ; close single-quote mode
            inc     rf                  ; consume the quote char itself
            lbr     tok_char

tok_ordinary:
            ldn     rf
            str     rd
            inc     rd
            inc     rf
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

            ; glob-expand argv[1..argc-1] in place (may rewrite
            ; RUN_ARGC/RUN_ARGV_TABLE -- see glob_expand's own header
            ; below). Zero cost for an ordinary command with no
            ; wildcard token: its own pre-scan returns immediately.
            call    glob_expand

            mov     rf, RUN_ARGV_TABLE
            lda     rf
            phi     ra
            ldn     rf
            plo     ra

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

            lbr     start               ; batch now active -- the next
                                        ; trip through "start" pulls
                                        ; its first line via
                                        ; K_BATCH_READLINE

batch_nested:
            call    K_INMSG
            db      "Nested batch not supported.",13,10,0
            lbr     start

;------------------------------------------------------------------
; File globbing ("*"/"?" wildcard expansion) -- shell-level, Unix-
; style: argv[1..argc-1] tokens whose FINAL path component (after the
; last '/', or the whole token if there's none) contains '*' (zero or
; more characters) or '?' (exactly one) are expanded into every
; matching directory entry, each becoming its own argv entry, BEFORE
; the command is ever resolved/handed to the kernel. argv[0] (the
; command name itself) is never glob-expanded. A pattern with zero
; matches falls back to the literal original token (bash's default
; "nullglob off" behavior) -- lets the resolved command's own normal
; error path report it. Wildcards are only recognized in the final
; path component -- one earlier in the path (e.g. "fo*o/bar.txt") is
; left as an ordinary character; matching mid-path wildcards would
; need recursive per-component expansion, out of scope for v1.
; Case-sensitive, matching this project's own file_open/path_resolve
; lookup convention (no folding). Match order is on-disk directory
; order, not sorted (matches DOS's own DIR *.TXT-style ordering,
; simpler for v1 than collecting-then-sorting).
;
; A cheap pre-scan runs first and costs nothing beyond it for an
; ordinary command with no wildcard token at all: no kernel call, no
; himem reservation. Only once a real wildcard is found does this
; call K_GLOB_RESERVE (kernel/glob.asm) for a dynamic himem buffer to
; hold the expanded text -- see that file's own module header for why
; this can't just be a fixed low buffer or ordinary program-heap
; memory. K_GLOB_RESERVE is idempotent, so re-attempting a second
; command line within the same shell invocation (e.g. after a "File
; not found." loops back to start:) safely reuses the same buffer.
;------------------------------------------------------------------
GLOB_ENTRY_RESERVE: equ 64     ; per-match budget reserved in the
                                ; himem buffer before attempting a
                                ; write -- matches RUN_PATH_LEN's own
                                ; "reasonable single path/name" bound

;------------------------------------------------------------------
; glob_expand: see the section header above for the full design.
; Reads/rewrites RUN_ARGC/RUN_ARGV_TABLE directly (fixed addresses --
; see kernel.inc's own comment on why these are never ordinary
; program-relative labels).
; Args:    none
; Returns: nothing (aborts the whole line via "lbr start", not a
;          normal return, if K_GLOB_RESERVE fails -- see ge_oom)
; Modifies: everything (R7-RD) -- called once from tok_done, before
;           any other state in this file's own "resolve" section
;           exists to protect
;------------------------------------------------------------------
glob_expand:
            mov     rf, RUN_ARGC
            inc     rf                  ; -> argc's low byte
            mov     rb, ge_argc         ; BUG FIX (gotcha #4): mov
                                        ; must happen BEFORE the ldn
                                        ; that fetches the real value
                                        ; -- mov itself clobbers D, so
                                        ; doing it after would have
                                        ; stored ge_argc's own address
                                        ; low byte instead of argc
            ldn     rf                  ; D = argc's low byte (argc
                                        ; never exceeds
                                        ; ARGV_MAX_ARGS=16, so one
                                        ; byte is enough)
            str     rb                  ; ge_argc = argc

            ; --- pre-scan: does ANY argv[1..argc-1]'s final component
            ; contain '*' or '?' ? ---
            mov     rf, ge_i
            ldi     1
            str     rf

ge_prescan_loop:
            mov     rf, ge_i
            ldn     rf
            str     r2                  ; M(X) = ge_i
            mov     rf, ge_argc
            ldn     rf                  ; D = ge_argc
            xor                         ; D = ge_argc XOR ge_i
            lbz     ge_prescan_none     ; ge_i == ge_argc: scanned all
                                        ; of argv[1..argc-1], no
                                        ; wildcard found

            call    ge_get_token
            call    ge_check_wildcard   ; DF=0 if a wildcard was found
            lbnf    ge_prescan_found

            mov     rf, ge_i
            ldn     rf
            adi     1
            str     rf
            lbr     ge_prescan_loop

ge_prescan_found:
            mov     rf, ge_needs_glob
            ldi     $FF
            str     rf
            lbr     ge_prescan_done

ge_prescan_none:
            mov     rf, ge_needs_glob
            ldi     0
            str     rf

ge_prescan_done:
            mov     rf, ge_needs_glob
            ldn     rf
            lbz     ge_return           ; nothing to do: RUN_ARGC/
                                        ; RUN_ARGV_TABLE already
                                        ; correct exactly as tok_done
                                        ; wrote them

            ; --- reserve the himem glob buffer (idempotent) ---
            call    K_GLOB_RESERVE
            lbdf    ge_oom

            mov     rf, ge_glob_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ge_glob_base = RD

            mov     rf, ge_glob_used
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; ge_glob_used = 0

            mov     rf, ge_budget_exhausted
            ldi     0
            str     rf

            ; --- ge_argv_tmp[0] = argv[0] (never glob-expanded) ---
            mov     rf, RUN_ARGV_TABLE
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ge_argv_tmp
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ge_new_argc
            ldi     1
            str     rf

            mov     rf, ge_i
            ldi     1
            str     rf

ge_expand_loop:
            mov     rf, ge_i
            ldn     rf
            str     r2
            mov     rf, ge_argc
            ldn     rf
            xor
            lbz     ge_expand_done      ; scanned all of argv[1..argc-1]

            call    ge_get_token
            call    ge_check_wildcard
            lbdf    ge_copy_literal     ; no wildcard in this token:
                                        ; copy it through unchanged

            call    ge_expand_token     ; may emit 0+ matches directly
                                        ; into ge_argv_tmp/GLOB_BUF
            mov     rf, ge_match_count
            ldn     rf
            lbnz    ge_expand_next      ; at least one match handled

ge_copy_literal:
            mov     rf, ge_token
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = the literal token
                                        ; pointer (unchanged, still
                                        ; valid -- points into LINE_BUF)
            call    ge_append_tmp

ge_expand_next:
            mov     rf, ge_i
            ldn     rf
            adi     1
            str     rf
            lbr     ge_expand_loop

ge_expand_done:
            call    ge_publish
            lbr     ge_return

ge_oom:
            call    K_INMSG
            db      "Out of memory for glob expansion.",13,10,0
            lbr     start               ; abort the whole line -- no
                                        ; half-expanded command

ge_return:
            rtn

;------------------------------------------------------------------
; ge_get_token: RD = argv[ge_i], also stashed into ge_token. No calls
; inside -- RD's return value is safe to use immediately at every
; call site.
; Modifies: RF, R8, RD
;------------------------------------------------------------------
ge_get_token:
            mov     rf, ge_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ge_i (zero-extended)
            shl16   r8                  ; R8 = ge_i * 2
            mov     rf, RUN_ARGV_TABLE
            add16   rf, r8              ; RF = &RUN_ARGV_TABLE[ge_i]
                                        ; (register-register add16 --
                                        ; nothing staged via str r2
                                        ; nearby, gotcha #18-safe)
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = argv[ge_i]

            mov     rf, ge_token
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; ge_check_wildcard: does ge_token's FINAL path component (after the
; last '/', or the whole token if none) contain '*' or '?' ? Side
; effect: always sets ge_last_slash (pointer to the final component's
; own start) and ge_prefix_len (byte count from ge_token's start up
; to there) -- needed by ge_expand_token/ge_emit_match regardless of
; the wildcard result, and cheap to compute unconditionally.
; Returns: DF = 0 if a wildcard was found, DF = 1 otherwise
; Modifies: RF, R8, R9, RD
;------------------------------------------------------------------
ge_check_wildcard:
            mov     rf, ge_token
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ge_token (token start)
            mov     r8, r9              ; R8 = scan cursor
            mov     rd, r9              ; RD = last-slash position
                                        ; (defaults to the token start)

gcw_scan:
            ldn     r8
            lbz     gcw_scanned
            xri     '/'
            lbnz    gcw_next
            inc     r8
            mov     rd, r8              ; RD = position right after '/'
            lbr     gcw_scan
gcw_next:
            inc     r8
            lbr     gcw_scan

gcw_scanned:
            mov     rf, ge_last_slash
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            glo     r9
            str     r2                  ; M(X) = token_start.lo
            mov     rf, ge_prefix_len   ; BUG FIX (gotcha #4): mov
                                        ; must happen BEFORE the sm
                                        ; that computes the real value
                                        ; -- doesn't touch R2/RD, so
                                        ; moving it here is safe
            glo     rd
            sm                          ; D = last_slash.lo -
                                        ; token_start.lo = prefix_len
                                        ; (tokens live in LINE_BUF,
                                        ; 128 bytes -- always fits a
                                        ; single byte)
            str     rf

gcw_wild_scan:
            ldn     rd
            lbz     gcw_no_wild         ; reached the NUL: no wildcard
            xri     '*'
            lbz     gcw_yes
            ldn     rd
            xri     '?'
            lbz     gcw_yes
            inc     rd
            lbr     gcw_wild_scan

gcw_yes:
            clc
            rtn

gcw_no_wild:
            stc
            rtn

;------------------------------------------------------------------
; ge_expand_token: resolve ge_token's directory part and scan it for
; entries matching the final component (ge_last_slash), via
; glob_match, emitting each match through ge_emit_match. A bad
; directory path, or the himem buffer already being exhausted from an
; earlier token, both fall through to ge_match_count staying 0 --
; ge_expand_loop's own caller then falls back to the literal token,
; same as a real zero-match result.
; Args:    none (reads ge_token/ge_prefix_len/ge_last_slash)
; Returns: nothing (ge_match_count set)
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
ge_expand_token:
            mov     rf, ge_match_count
            ldi     0
            str     rf

            mov     rf, ge_budget_exhausted
            ldn     rf
            lbnz    gex_done            ; already exhausted: 0 matches

            mov     rf, ge_prefix_len
            ldn     rf
            lbnz    gex_resolve_path    ; nonzero prefix: real path
                                        ; resolution needed

            call    K_GETCURDIR         ; RD = cur_dir cluster
            lbr     gex_have_clust

gex_resolve_path:
            mov     rb, ge_token
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = ge_token (full text,
                                        ; including the pattern --
                                        ; K_PATH_RESOLVE never looks
                                        ; up the final component
                                        ; itself, matching CD/COPY's
                                        ; own use of it)
            call    K_PATH_RESOLVE      ; RD = parent cluster, DF=0/1
            lbdf    gex_done            ; bad path: 0 matches

gex_have_clust:
            call    K_DIR_OPEN          ; RD = cluster to scan

gex_read_loop:
            mov     rf, ge_dirent
            call    K_DIR_READ
            lbdf    gex_done            ; end of directory

            mov     rf, ge_dirent
            mov     rd, gex_dot
            call    f_strcmp
            lbz     gex_read_loop       ; skip "."

            mov     rf, ge_dirent
            mov     rd, gex_dotdot
            call    f_strcmp
            lbz     gex_read_loop       ; skip ".."

            mov     rb, ge_last_slash
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = pattern
            mov     rd, ge_dirent       ; RD = text (DIRENT_NAME is
                                        ; offset 0 within ge_dirent)
            call    glob_match
            lbdf    gex_read_loop       ; no match: next entry

            call    ge_emit_match
            lbdf    gex_done            ; himem buffer just ran out:
                                        ; stop this scan (ge_expand_
                                        ; loop's caller will still
                                        ; correctly fall back to
                                        ; literal for every token
                                        ; after this one)

            lbr     gex_read_loop

gex_done:
            rtn

gex_dot:        db      ".",0
gex_dotdot:     db      "..",0

;------------------------------------------------------------------
; ge_emit_match: write "ge_token[0..ge_prefix_len) + the matched
; entry's name (ge_dirent's DIRENT_NAME)" into the himem glob buffer
; at the current write cursor, NUL-terminated, then append its
; address to ge_argv_tmp via ge_append_tmp. Budget-checked, reserving
; GLOB_ENTRY_RESERVE bytes per attempt -- if the remaining buffer
; space is under that, sets ge_budget_exhausted and returns DF=1
; without writing anything (ge_match_count NOT incremented).
; Args:    none
; Returns: DF = 0 on success (ge_match_count incremented), DF = 1 if
;          the buffer's budget is exhausted
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
ge_emit_match:
            mov     rf, ge_budget_exhausted
            ldn     rf
            lbnz    gem_fail            ; already exhausted (an
                                        ; earlier match this command
                                        ; already used up the budget)

            mov     rf, ge_glob_used
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ge_glob_used
            mov     r9, r8
            add16   r9, GLOB_ENTRY_RESERVE ; R9 = used + RESERVE
                                        ; (immediate-form add16 --
                                        ; never touches M(R2), gotcha
                                        ; #18-safe regardless)
            mov     rf, r9
            sub16   rf, GLOB_BUF_LEN    ; RF = (used+RESERVE) - LEN;
                                        ; DF=1 (no borrow) means
                                        ; used+RESERVE >= LEN --
                                        ; immediate-form, safe
            lbdf    gem_exhausted

            mov     rf, ge_glob_base
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ge_glob_base
            add16   rd, r8              ; RD = ge_glob_base +
                                        ; ge_glob_used = this entry's
                                        ; own start address (register-
                                        ; register add16 -- nothing
                                        ; staged via str r2 nearby,
                                        ; gotcha #18-safe)
            mov     rb, rd              ; RB = write cursor

            mov     rf, ge_token
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ge_token (prefix source)
            mov     rf, ge_prefix_len
            ldn     rf
            plo     r8                  ; R8.0 = remaining prefix
                                        ; bytes to copy
gem_copy_prefix:
            glo     r8
            lbz     gem_copy_name
            mov     rf, r9
            ldn     rf
            str     rb
            inc     rb
            inc     r9
            dec     r8
            lbr     gem_copy_prefix

gem_copy_name:
            mov     rf, ge_dirent
gem_copy_name_loop:
            ldn     rf
            lbz     gem_name_done
            str     rb
            inc     rf
            inc     rb
            lbr     gem_copy_name_loop

gem_name_done:
            ldi     0
            str     rb                  ; NUL-terminate
            inc     rb                  ; RB = one past the terminator

            mov     rf, gem_new_cursor
            ghi     rb
            str     rf
            inc     rf
            glo     rb
            str     rf                  ; gem_new_cursor = RB (stashed
                                        ; BEFORE the call below, which
                                        ; may clobber RB)

            call    ge_append_tmp       ; RD still holds this entry's
                                        ; own start address (untouched
                                        ; since being computed above)

            mov     rf, gem_new_cursor
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = gem_new_cursor
            mov     rf, ge_glob_base
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = ge_glob_base
            sub16   rd, r9              ; RD = gem_new_cursor -
                                        ; ge_glob_base = new
                                        ; ge_glob_used (register-
                                        ; register sub16 -- nothing
                                        ; staged via str r2 nearby,
                                        ; gotcha #18-safe)
            mov     rf, ge_glob_used
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, ge_match_count
            ldn     rf
            adi     1
            str     rf

            clc
            rtn

gem_exhausted:
            mov     rf, ge_budget_exhausted
            ldi     $FF
            str     rf

gem_fail:
            stc
            rtn

;------------------------------------------------------------------
; ge_append_tmp: append RD as the next entry in ge_argv_tmp, bumping
; ge_new_argc -- silently no-ops if ge_new_argc is already at
; ARGV_MAX_ARGS (same "extra tokens silently dropped" precedent the
; main tokenizer's own tok_check_end already established).
; Args:    RD = pointer to append
; Modifies: RF, RB, R8 (and D)
;------------------------------------------------------------------
ge_append_tmp:
            mov     rf, ge_new_argc
            ldn     rf
            smi     ARGV_MAX_ARGS
            lbdf    gat_done            ; already at capacity

            mov     rf, ge_new_argc
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ge_new_argc (zero-
                                        ; extended)
            shl16   r8                  ; R8 = ge_new_argc * 2
            mov     rb, ge_argv_tmp
            add16   rb, r8              ; RB = &ge_argv_tmp[ge_new_argc]
                                        ; (register-register add16 --
                                        ; nothing staged via str r2
                                        ; nearby, gotcha #18-safe)
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rf, ge_new_argc
            ldn     rf
            adi     1
            str     rf

gat_done:
            rtn

;------------------------------------------------------------------
; ge_publish: copy ge_argv_tmp[0..ge_new_argc) into RUN_ARGV_TABLE,
; and ge_new_argc into RUN_ARGC.
; Modifies: R8, R9, RB, RF (and D)
;------------------------------------------------------------------
ge_publish:
            mov     rf, ge_new_argc
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ge_new_argc (zero-
                                        ; extended)
            shl16   r8                  ; R8 = ge_new_argc * 2 (byte
                                        ; count to copy)

            mov     r9, ge_argv_tmp
            mov     rb, RUN_ARGV_TABLE
gp_copy:
            glo     r8
            lbnz    gp_have
            ghi     r8
            lbz     gp_copy_done
gp_have:
            ldn     r9
            str     rb
            inc     r9
            inc     rb
            sub16   r8, 1               ; immediate-form, gotcha #18-
                                        ; safe
            lbr     gp_copy

gp_copy_done:
            mov     rf, RUN_ARGC
            ldi     0
            str     rf
            inc     rf
            mov     rb, ge_new_argc
            ldn     rb
            str     rf
            rtn

;------------------------------------------------------------------
; glob_match: does the text at RD match the wildcard pattern at RF?
; '*' matches zero or more characters, '?' matches exactly one.
; Case-sensitive. Classic non-recursive backtracking matcher --
; independently verified against 35 hand-picked test cases in a
; Python simulation before writing this (leading/trailing/multiple
; '*', '?' mixed with literal characters, no-match cases, empty
; pattern/text, case-sensitivity, etc. -- see this session's own
; scratch glob_match_sim.py), matching this project's established
; practice for new non-mechanical algorithmic logic.
; Args:    RF = pattern (null-terminated), RD = text (null-terminated)
; Returns: DF = 0 on match, DF = 1 on no match
; Modifies: RF, RD, RB (star_p -- 0 means unset; safe sentinel, no
;           real buffer in this system sits at address 0), R9
;           (star_t), R8 (scratch)
;------------------------------------------------------------------
glob_match:
            ldi     0
            phi     rb
            plo     rb                  ; RB = 0 (star_p unset)

gm_loop:
            ldn     rd                  ; D = *t
            lbnz    gm_have_char

gm_skip_stars:
            ldn     rf
            xri     '*'
            lbnz    gm_check_pat_end
            inc     rf
            lbr     gm_skip_stars
gm_check_pat_end:
            ldn     rf
            lbnz    gm_no               ; pattern has more: no match
            lbr     gm_yes              ; both exhausted: match

gm_have_char:
            plo     r8                  ; R8.0 = *t
            ldn     rf                  ; D = *p
            str     r2                  ; M(X) = *p (consumed by the
                                        ; very next instruction -- no
                                        ; register-register add16/
                                        ; sub16 runs between, gotcha
                                        ; #18-safe)
            glo     r8                  ; D = *t
            sm                          ; D = *t - *p (zero iff equal)
            lbz     gm_advance

            ldn     rf                  ; D = *p (reload)
            xri     '?'
            lbz     gm_advance

            ldn     rf
            xri     '*'
            lbz     gm_set_star

            lbr     gm_try_backtrack

gm_advance:
            inc     rf
            inc     rd
            lbr     gm_loop

gm_set_star:
            mov     rb, rf              ; star_p = p
            inc     rf                  ; p++ (consume the '*' itself)
            mov     r9, rd              ; star_t = t
            lbr     gm_loop

gm_try_backtrack:
            ghi     rb
            lbnz    gm_backtrack
            glo     rb
            lbz     gm_no               ; star_p == 0: never set

gm_backtrack:
            mov     rf, rb
            inc     rf                  ; p = star_p + 1
            inc     r9                  ; star_t++
            mov     rd, r9              ; t = star_t
            lbr     gm_loop

gm_yes:
            clc
            rtn

gm_no:
            stc
            rtn

ge_argc:            db      0
ge_i:               db      0
ge_new_argc:        db      0
ge_needs_glob:       db      0
ge_glob_base:        dw      0
ge_glob_used:        dw      0
ge_budget_exhausted: db      0
ge_match_count:      db      0
ge_token:            dw      0
ge_last_slash:       dw      0
ge_prefix_len:       db      0
gem_new_cursor:       dw      0
ge_dirent:           ds      DIRENT_LEN
ge_argv_tmp:         ds      ARGV_MAX_ARGS * 2

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

            end     start
