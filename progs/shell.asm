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
