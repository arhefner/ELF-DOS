;
; copy.asm - copy one or more files
;
; Usage: COPY [-y] <source> <destination>
;        COPY [-y] <source> [source...] <destination-directory>
;
; -y (2026-07-26; widened the same day to work anywhere on the line,
; matching XCOPY's own convention): auto-confirm any overwrite prompt
; below, matching real DOS COPY's own /Y switch -- useful for
; batch-script use, where an interactive Y/N prompt is exactly the
; kind of thing that needs suppressing. May appear anywhere among the
; arguments, not just first.
;
; Single-source form: <destination> may be a full path; if it names an
; existing directory, the source is copied into it under its own
; basename (e.g. "COPY ../foo ." copies to "./foo") -- checked via the
; same K_PATH_RESOLVE/K_DIR_OPEN/K_DIR_READ/ATTR_DIR pattern CD uses to
; recognize a directory; otherwise <destination> is used as-is.
;
; Multi-source form (argc > 3, e.g. "COPY a.txt b.txt somedir"): the
; LAST argument must already be an existing directory (checked once,
; before any file is touched, the same "safe step before the
; destructive one" caution this project applies elsewhere) -- each of
; the remaining arguments is copied into it under its own basename,
; independently: a failure on one prints its own error and moves on to
; the next rather than aborting the whole command (same "print the
; error, advance" precedent DEL's own multi-argument loop already
; established); final exit code reflects whether ANY source failed.
;
; Wildcard support (2026-07-27, redesigned): each source argument is
; checked via lib/file_glob.asm's is_glob -- a plain filename is
; copied directly, exactly as before; a "*"/"?" pattern is expanded
; via glob_init/glob_next and every match copied the same way,
; individually. This replaces the old design (the shell's own
; tokenizer pre-expanding a wildcard into one argv entry per match
; before COPY ever ran) -- see lib/file_glob.asm's own header for why:
; the old design had a hard ARGV_MAX_ARGS=16 ceiling that silently
; truncated a directory with more matches than that (the bug that
; motivated this whole redesign). A pattern matching zero files falls
; back to attempting the literal, unexpanded text (nullglob-off).
; Because a glob source's own eventual match count (0, 1, or many)
; isn't known until it's actually expanded, the "destination must be
; an existing directory" requirement is decided STATICALLY, before any
; expansion: if ANY source argument is a glob pattern at all --
; regardless of how many files it turns out to match, even exactly
; one -- the destination must already be a directory. This is a small,
; deliberate gap from bash/cp's own exact behavior (which allows a
; glob matching exactly one file to rename into a non-directory
; destination, since bash itself expands the glob before cp ever
; runs and so never sees the ambiguity) -- accepted for simplicity.
;
; If a resolved destination file already exists, the user is prompted
; to confirm the overwrite (Y/N -- anything but Y/y cancels) for EACH
; file, unless -y was given; otherwise it's created directly, same as
; WTEST.
;
; Copying a file onto itself is not specially detected or guarded
; against -- it will open the same file twice, for read and write
; simultaneously (each with its own independent FCB and I/O buffer,
; 2026-07-15), but the mode-1 destination open truncates the file to
; empty immediately (see file_open's own mode-1 semantics), which
; destroys the source's real content out from under the read side
; regardless of separate buffers. Don't do that.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/file_glob.inc

            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

COPY_CHUNK_LEN: equ     512     ; matches the sector size -- was 64,
                                ; bumped once the underlying directory-
                                ; growth bug (fc_grow's unprotected R8
                                ; across fat_set) was found and fixed;
                                ; changing it earlier would have shifted
                                ; the cluster-boundary alignment of the
                                ; test cases that exposed that bug.
                                ; At the time this was bumped, it also
                                ; cut real disk I/O, not just call
                                ; overhead: file_read/file_write used to
                                ; share a SINGLE io_buf slot across all
                                ; FCBs, so every alternation between the
                                ; src and dst FCBs evicted the other's
                                ; cached sector -- at the old 64-byte
                                ; chunk size, copying one 512-byte sector
                                ; took 8 iterations x 3 real disk ops
                                ; each = 24 total. One 512-byte chunk
                                ; per sector cut that to 3. Since
                                ; 2026-07-15, src/dst each have their own
                                ; independent FCB and I/O buffer (see
                                ; below), so this specific thrashing no
                                ; longer applies either way -- but 512
                                ; still means 8x fewer K_FILE_READ/
                                ; K_FILE_WRITE round-trips than 64 did,
                                ; so the chunk size stayed as-is.
DST_BUF_LEN:    equ     132

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; --- optional "-y" flag, anywhere on the line (2026-07-26,
            ; widened at the user's own request to match XCOPY's own
            ; "flags can appear anywhere" convention rather than being
            ; pinned to argv[1]): auto-confirm any overwrite prompt
            ; below, matching real DOS COPY's own /Y switch. A single
            ; pass filters the WHOLE argv line into a local, owned copy
            ; (copy_argv_local) with every exact "-y" token dropped and
            ; argc reduced to match -- argv[0] (this program's own
            ; name, never read again) is always kept unconditionally,
            ; so index 1 onward in the filtered array lines up exactly
            ; as if "-y" had never been typed. Everything below this
            ; block already reads through copy_argv/copy_argc uniformly
            ; (never RA/RC directly), so nothing else in this file
            ; needs to change -- copy_argv is simply pointed at the
            ; filtered local array instead of the real argv table.
            ; RA itself (the real table) is read-only throughout this
            ; scan, never mutated -- avoids touching shell/kernel-owned
            ; memory that isn't this program's own.
            mov     rf, copy_yflag
            ldi     0
            str     rf

            mov     rf, copy_orig_argc
            glo     rc
            str     rf                  ; copy_orig_argc = argc (as
                                        ; received, before filtering)

            ldi     0
            plo     r9                  ; R9.0 = source index i
            ldi     0
            plo     r8                  ; R8.0 = surviving count so far

            mov     rb, copy_argv_local ; RB = filtered-array write
                                        ; cursor

cy_filter_loop:
            mov     rf, copy_orig_argc
            ldn     rf
            str     r2
            glo     r9
            sm                          ; D = i - orig_argc
            lbdf    cy_filter_done      ; i >= orig_argc: scanned every
                                        ; real entry

            ; RD = argv[i] (dereference the REAL table at RA + i*2 --
            ; RA itself is only ever read here, never written)
            glo     r9
            plo     rd
            ldi     0
            phi     rd
            shl16   rd                  ; RD = i*2
            mov     rf, ra
            add16   rf, rd              ; RF = &argv[i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = argv[i]'s string pointer

            glo     r9
            lbz     cy_filter_keep      ; i == 0: always keep (this
                                        ; program's own name, never
                                        ; checked as a flag)

            mov     rf, rd
            ldn     rf
            xri     '-'
            lbnz    cy_filter_keep

            mov     rf, rd
            inc     rf
            ldn     rf
            xri     'y'
            lbnz    cy_filter_keep

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; must be NUL for "-y" to be
                                        ; exactly this whole token
            lbnz    cy_filter_keep

            ; exact "-y" match: record the flag, do NOT copy this
            ; entry into the filtered array (dropping it is exactly
            ; what removes it from the destination/source count below)
            mov     rf, copy_yflag
            ldi     1
            str     rf
            lbr     cy_filter_next

cy_filter_keep:
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb                  ; copy_argv_local[count] =
                                        ; argv[i]
            glo     r8
            adi     1
            plo     r8

cy_filter_next:
            glo     r9
            adi     1
            plo     r9
            lbr     cy_filter_loop

cy_filter_done:
            mov     rf, copy_argv
            mov     rd, copy_argv_local
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; copy_argv = &copy_argv_local
                                        ; (the filtered array, not RA)

            mov     rf, copy_argc
            glo     r8
            str     rf                  ; copy_argc = surviving count

start_argcheck:
            ; copy_argv/copy_argc are already fully populated by the
            ; filter loop above (pointing at copy_argv_local, the
            ; filtered array, with "-y" already removed and argc
            ; already reduced to match) -- RA/RC themselves are NOT
            ; used from here on; K_PATH_RESOLVE/K_DIR_OPEN/K_DIR_READ/
            ; file_open all clobber RA per their own documented lists
            ; anyway (same reasoning DEL's own multi-argument loop
            ; already established for why this can't just stay in a
            ; register). argv[0] is this program's own name;
            ; argv[1..argc-2] are sources (just argv[1] when argc==3);
            ; argv[argc-1] is the destination.
            mov     rf, copy_argc
            ldn     rf
            smi     3
            lbnf    usage_error         ; argc < 3: source and/or
                                        ; destination missing

            ; dst_ptr = argv[argc-1] (the LAST argument -- identical
            ; to argv[2] when argc==3, so the single-source case is
            ; byte-for-byte unaffected)
            mov     rf, copy_argc
            ldn     rf
            smi     1
            plo     r8
            ldi     0
            phi     r8                  ; R8 = (argc-1), zero-extended
            shl16   r8                  ; R8 = (argc-1)*2
            mov     rf, copy_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = copy_argv (base)
            add16   rb, r8              ; RB = &argv[argc-1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[argc-1]
            mov     rf, dst_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; num_sources = argc - 2
            mov     rb, num_sources
            mov     rf, copy_argc
            ldn     rf
            smi     2
            str     rb

            ; --- does ANY source argument (argv[1..num_sources])
            ; contain a wildcard? Decided statically here, before any
            ; expansion -- see this file's own header comment for why
            ; this drives the "destination must be a directory" check
            ; below the same way num_sources>=2 already does. ---
            mov     rf, copy_any_glob
            ldi     0
            str     rf

            mov     rf, copy_scan_i
            ldi     1
            str     rf

copy_glob_prescan:
            mov     rf, copy_scan_i
            ldn     rf
            str     r2
            mov     rf, num_sources
            ldn     rf                  ; D = num_sources
            adi     1                   ; D = num_sources + 1
            xor                         ; D = (num_sources+1) XOR
                                        ; copy_scan_i
            lbz     copy_glob_prescan_done

            mov     rf, copy_scan_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = copy_scan_i * 2
            mov     rf, copy_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = copy_argv (base,
                                        ; reloaded fresh)
            add16   rb, r8              ; RB = &argv[copy_scan_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[copy_scan_i]
            mov     rf, rd
            call    is_glob
            lbdf    copy_glob_prescan_next  ; DF=1: not a glob

            mov     rf, copy_any_glob
            ldi     1
            str     rf

copy_glob_prescan_next:
            mov     rf, copy_scan_i
            ldn     rf
            adi     1
            str     rf
            lbr     copy_glob_prescan

copy_glob_prescan_done:

            ; --- is dst_ptr an existing directory? (checked ONCE,
            ; regardless of num_sources) ---
            call    check_dst_is_dir    ; DF = 0/1
            lbdf    start_not_dir
            mov     rf, dst_is_dir_flag
            ldi     $FF
            str     rf
            lbr     start_have_flag
start_not_dir:
            mov     rf, dst_is_dir_flag
            ldi     0
            str     rf

start_have_flag:
            ; multiple sources, OR a single source that's itself a
            ; glob pattern, REQUIRE an existing destination directory
            ; -- reject up front, before touching any file
            mov     rf, copy_must_be_dir
            ldi     0
            str     rf

            mov     rf, num_sources
            ldn     rf
            smi     2
            lbnf    copy_cmbd_check_glob
            mov     rf, copy_must_be_dir
            ldi     1
            str     rf
            lbr     copy_cmbd_done
copy_cmbd_check_glob:
            mov     rf, copy_any_glob
            ldn     rf
            lbz     copy_cmbd_done
            mov     rf, copy_must_be_dir
            ldi     1
            str     rf
copy_cmbd_done:

            mov     rf, copy_must_be_dir
            ldn     rf
            lbz     start_run           ; doesn't need to be a
                                        ; directory: proceed
            mov     rf, dst_is_dir_flag
            ldn     rf
            lbnz    start_run           ; must be a directory, and is
                                        ; one: OK

            call    K_INMSG
            db      "Destination must be an existing directory for multiple sources.",13,10,0
            ldi     1
            rtn

start_run:
            mov     rf, any_error
            ldi     0
            str     rf

            mov     rf, copy_i
            ldi     1
            str     rf

copy_loop_sources:
            mov     rf, copy_i
            ldn     rf
            str     r2                  ; M(X) = copy_i
            mov     rf, num_sources
            ldn     rf                  ; D = num_sources
            adi     1                   ; D = num_sources + 1
            xor                         ; D = (num_sources+1) XOR
                                        ; copy_i
            lbz     copy_all_done       ; copy_i == num_sources+1:
                                        ; every source handled

            ; RD = argv[copy_i] (this source)
            mov     rf, copy_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = copy_i * 2
            mov     rf, copy_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = copy_argv (base,
                                        ; reloaded fresh every
                                        ; iteration)
            add16   rb, r8              ; RB = &argv[copy_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[copy_i]
            mov     rf, copy_cur_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; copy_cur_arg = this source
                                        ; argv entry, stashed to memory
                                        ; -- never trusted in a
                                        ; register across is_glob/
                                        ; glob_init/glob_next

            mov     rf, copy_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    is_glob
            lbdf    copy_src_literal    ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, copy_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, copy_glob_ctx
            call    glob_init
            lbdf    copy_src_bad_path

            mov     rf, copy_glob_found
            ldi     0
            str     rf

copy_src_glob_loop:
            mov     rd, copy_glob_ctx
            call    glob_next
            lbdf    copy_src_glob_done  ; exhausted

            ; BUG FIX (caught in review, before ever assembling): RF
            ; holds glob_next's own returned match pointer at this
            ; point -- "mov rf, copy_glob_found" below would silently
            ; overwrite it with copy_glob_found's OWN address before
            ; copy_process_one ever got a chance to read it. Stash it
            ; in R9 first (free at this point), restore right before
            ; the call.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, copy_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    copy_process_one
            lbr     copy_src_glob_loop

copy_src_glob_done:
            mov     rf, copy_glob_found
            ldn     rf
            lbnz    copy_next           ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, copy_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    copy_process_one
            lbr     copy_next

copy_src_bad_path:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            mov     rf, any_error
            ldi     $FF
            str     rf
            lbr     copy_next

copy_src_literal:
            mov     rf, copy_cur_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    copy_process_one

copy_next:
            mov     rf, copy_i
            ldn     rf
            adi     1
            str     rf
            lbr     copy_loop_sources

copy_all_done:
            mov     rf, any_error
            ldn     rf
            lbnz    copy_exit_err

            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention (2026-07-21)
            rtn

copy_exit_err:
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: COPY [-y] <source> [source...] <destination>",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; copy_process_one: copy a single, already-resolved source path (a
; literal argv entry, or one glob match) to the destination, tracking
; any_error on failure. Factored out of copy_loop_sources so it can be
; called either once directly (a literal source) or repeatedly in a
; glob_next loop.
; Args:    RF = source path
; Returns: nothing
; Modifies: everything (calls copy_one)
;------------------------------------------------------------------
copy_process_one:
            mov     rb, src_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; src_ptr = RF

            call    copy_one            ; DF = 0/1
            lbnf    cpo_ok

            mov     rf, any_error
            ldi     $FF
            str     rf
cpo_ok:
            rtn

;------------------------------------------------------------------
; check_dst_is_dir: does dst_ptr name an existing directory? Same
; K_PATH_RESOLVE/K_DIR_OPEN/K_DIR_READ/ATTR_DIR pattern CD uses.
; Args:    none (reads dst_ptr)
; Returns: DF = 0 if dst_ptr names an existing directory, DF = 1
;          otherwise (doesn't exist, is a file, or an intermediate
;          path component is invalid)
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
check_dst_is_dir:
            mov     rf, dst_ptr
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = destination string
                                        ; pointer

            mov     rf, rc              ; RF = destination path
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF =
                                        ; final component, RC.0 =
                                        ; resolved drive (unused),
                                        ; DF = 0/1
            lbdf    cdd_no              ; bad intermediate component,
                                        ; or an "X:" prefix named an
                                        ; unmounted drive

            ; an empty final component means dst_ptr itself named a
            ; directory ("/", "cfg/", ...) -- no further lookup needed
            ldn     rf
            lbz     cdd_yes

            ; save the final-component pointer in memory: K_DIR_READ
            ; clobbers R9/RA/RB/RC/RD/RF
            mov     rb, dstchk_arg
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE
            call    K_DIR_OPEN

cdd_loop:
            mov     rf, dstchk_result
            call    K_DIR_READ
            lbdf    cdd_no              ; end of directory: no match

            mov     rf, dstchk_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dstchk_result
            call    f_strcmp
            lbnz    cdd_loop            ; no match: keep looking

            ; found it -- must be a directory
            mov     rf, dstchk_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     cdd_no              ; exists but is a file

cdd_yes:
            clc
            rtn

cdd_no:
            stc
            rtn

;------------------------------------------------------------------
; copy_one: copy src_ptr to its final destination -- dst_ptr + '/' +
; basename(src_ptr) if dst_is_dir_flag is set, else dst_ptr itself
; unchanged. Prompts for overwrite confirmation if the resolved
; destination already exists. Prints its own error message on any
; real failure; declining an overwrite prompt is NOT an error (silent,
; matches this project's "no news is good news" convention).
; Args:    none (reads src_ptr/dst_ptr/dst_is_dir_flag)
; Returns: DF = 0 on success (including a declined overwrite), DF = 1
;          on any real failure
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
copy_one:
            mov     rf, dst_is_dir_flag
            ldn     rf
            lbz     co_dst_plain

            ; --- build dst_final = dst_ptr + '/' (if not already
            ; present) + basename(src_ptr), point real_dst at it ---
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dst_ptr's string
                                        ; pointer
            mov     rf, dst_final
co_dst_loop:
            lda     rd
            lbz     co_dst_done
            str     rf
            inc     rf
            lbr     co_dst_loop
co_dst_done:
            ; RF = one past the last copied char; peek the previous
            ; char to avoid a doubled '/' if dst_ptr already ends in
            ; one
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     co_have_sep
            ldi     '/'
            str     rf
            inc     rf
co_have_sep:
            ; find basename(src_ptr): scan forward, remembering the
            ; position right after the LAST '/' seen (defaults to the
            ; string's own start if none found). RF (dst_final's
            ; current write position) must survive this whole block
            ; untouched -- RC is free here so the indirection uses
            ; that instead of RF.
            mov     rc, src_ptr
            lda     rc
            phi     rd
            ldn     rc
            plo     rd                  ; RD = source string pointer
            mov     r8, rd              ; R8 = scan pointer
            mov     r9, rd              ; R9 = basename pointer
                                        ; (updated on each '/' seen)
co_basename_scan:
            ldn     r8
            lbz     co_basename_done
            xri     '/'
            lbnz    co_basename_next
            inc     r8
            mov     r9, r8              ; R9 = position right after '/'
            lbr     co_basename_scan
co_basename_next:
            inc     r8
            lbr     co_basename_scan
co_basename_done:
            ; RF still holds dst_final's write position (from
            ; co_have_sep above -- not touched by the basename scan)
            mov     rd, r9              ; RD = basename source pointer
co_append_basename_loop:
            lda     rd
            str     rf
            lbz     co_append_basename_done
            inc     rf
            lbr     co_append_basename_loop
co_append_basename_done:

            mov     rb, real_dst
            mov     rf, dst_final
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; real_dst = dst_final
            lbr     co_check_overwrite

co_dst_plain:
            mov     rb, real_dst
            mov     rf, dst_ptr
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; real_dst = dst_ptr (single-
                                        ; source, non-directory
                                        ; destination -- unchanged)

co_check_overwrite:
;------------------------------------------------------------------
; If real_dst already exists, confirm the overwrite before touching
; anything. Checked before either file is opened, so a "no" here
; needs no cleanup.
;------------------------------------------------------------------
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination path string
            mov     rd, dst_fcb         ; RD = our dst_fcb struct
                                        ; (reused below for the REAL
                                        ; destination open too -- this
                                        ; existence-check FCB is always
                                        ; closed before that happens)
            mov     ra, dst_iobuf       ; RA = our dst_iobuf buffer
            ldi     0                   ; mode = read (existence check)
            call    K_FILE_OPEN         ; DF = 0/1 (D unspecified)
            lbdf    co_dst_check_done   ; not found (or a directory):
                                        ; proceed directly, nothing to
                                        ; close

            mov     rd, dst_fcb
            call    K_FILE_CLOSE

            mov     rf, copy_yflag
            ldn     rf
            lbnz    co_dst_check_done   ; -y: skip the prompt entirely,
                                        ; proceed as if "Y" was typed

            call    K_INMSG
            db      "Overwrite ",0
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      "? (Y/N) ",0

            call    K_READ              ; D = character read (blocking)
            ; stash in memory, not a register, across the K_TTY/
            ; K_INMSG calls below -- this project only has R9's
            ; survival confirmed across f_msg/f_inmsg (gotcha #8), and
            ; neither call has been separately audited for any other
            ; register.
            plo     rc
            mov     rf, answer_char
            glo     rc                  ; D = character (reloaded)
            str     rf                  ; answer_char = character

            call    K_TTY               ; echo it back to the console
            call    K_INMSG
            db      13,10,0

            mov     rf, answer_char
            ldn     rf                  ; D = the character read
            ani     $DF                 ; fold lowercase to uppercase
            xri     'Y'
            lbnz    co_cancelled        ; anything but Y/y: cancel

co_dst_check_done:
            ; --- open source (mode 0, read) ---
            mov     rf, src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source string
            mov     rd, src_fcb         ; RD = our src_fcb struct
            mov     ra, src_iobuf       ; RA = our src_iobuf buffer
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified)
            lbdf    co_src_not_found

            ; --- open destination (mode 1, create-or-overwrite) ---
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination string
            mov     rd, dst_fcb         ; RD = our dst_fcb struct (same
                                        ; memory as the existence check
                                        ; above -- already closed there)
            mov     ra, dst_iobuf       ; RA = our dst_iobuf buffer
            ldi     1                   ; mode = write
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified)
            lbdf    co_dst_open_error

;------------------------------------------------------------------
; Copy loop: read a chunk from source, write the same chunk (exact
; byte count K_FILE_READ actually returned) to destination.
;------------------------------------------------------------------
co_copy_loop:
            mov     rf, copy_buf
            ldi     low COPY_CHUNK_LEN
            plo     rc
            ldi     high COPY_CHUNK_LEN
            phi     rc                  ; RC = chunk size requested
            mov     rd, src_fcb         ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at copy_buf)
            call    K_FILE_READ         ; RC = bytes actually read
            lbdf    co_read_error

            glo     rc
            lbnz    co_have_bytes
            ghi     rc
            lbz     co_copy_done        ; 0 bytes read: source EOF
co_have_bytes:
            mov     rf, copy_buf        ; RF = source buffer (RC still
                                        ; holds the byte count)
            mov     rd, dst_fcb         ; RD = FCB pointer (fixed)
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    co_write_error

            lbr     co_copy_loop

co_copy_done:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            clc
            rtn

co_read_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            stc
            rtn

co_write_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            stc
            rtn

co_dst_open_error:
            mov     rd, src_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            stc
            rtn

co_src_not_found:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            stc
            rtn

co_cancelled:
            clc                         ; declining an overwrite is
                                        ; NOT an error -- silent, per
                                        ; this project's "no news is
                                        ; good news" convention
            rtn

copy_argv:      dw      0
copy_argc:      db      0
num_sources:    db      0
copy_i:         db      0
any_error:      db      0
dst_is_dir_flag: db     0
copy_yflag:     db      0
copy_orig_argc: db      0
copy_argv_local: ds     ARGV_MAX_ARGS*2 ; the "-y"-filtered argv table
                                        ; copy_argv actually points at
                                        ; after the entry-point filter
                                        ; loop -- sized to the same
                                        ; bound the real argv table
                                        ; itself is capped at, so it
                                        ; can never overflow regardless
                                        ; of how many real arguments
                                        ; were typed
src_ptr:        dw      0
dst_ptr:        dw      0
real_dst:       dw      0
copy_any_glob:  db      0
copy_scan_i:    db      0
copy_must_be_dir: db    0
copy_cur_arg:   dw      0
copy_glob_found: db     0
copy_glob_ctx:  ds      GLOB_CTX_LEN

; CALLER-ALLOCATED FCBs (2026-07-15), FCB POINTER IS THE HANDLE
; (2026-07-21): src_fcb/dst_fcb are the real FCB memory (K_FILE_OPEN's
; RD arg), each with its own private FCB_IOBUF_LEN I/O buffer (RA arg)
; -- this is the whole point for COPY specifically, since src and dst
; no longer share and thrash a single kernel-resident buffer. Both are
; fixed addresses, referenced directly (RD = src_fcb / dst_fcb) by
; every K_FILE_READ/WRITE/CLOSE call site -- no separate handle
; variable needed. dst_fcb/dst_iobuf are reused for both the
; destination-exists check and the real destination open -- the first
; is always closed before the second happens.
src_fcb:    ds      FCB_LEN
src_iobuf:  ds      FCB_IOBUF_LEN
dst_fcb:    ds      FCB_LEN
dst_iobuf:  ds      FCB_IOBUF_LEN

dstchk_arg: dw      0
dstchk_result: ds   DIRENT_LEN
dst_final:  ds      DST_BUF_LEN
answer_char: db     0
copy_buf:   ds      COPY_CHUNK_LEN

            end     start
