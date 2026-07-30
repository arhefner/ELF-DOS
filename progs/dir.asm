;
; dir.asm - list a directory, or show info for one or more files
;
; Usage: DIR [path...]
;
; With no argument, lists the current directory. With ONE path argument
; that resolves to a directory (bare name, relative path, or absolute
; path starting with '/'), lists that directory instead -- without
; changing the current directory, since K_DIR_OPEN/K_DIR_READ only drive
; this program's own listing traversal and never touch cur_dir (only
; CD's K_SETCURDIR does that). See K_PATH_RESOLVE in kernel_api.inc.
;
; With ONE path argument that resolves to a FILE, or with TWO OR MORE
; arguments (e.g. via the shell's own file-globbing -- "DIR *.txt"),
; each argument is K_STAT'd independently and shown as its own single
; entry line -- a matched directory gets one line too (its own entry),
; not a recursive listing of its contents. A bad argument prints its own
; "Not found: " message and the rest still run (matching this project's
; own DEL/COPY multi-argument precedent) rather than aborting the whole
; command; the final exit code reflects whether any argument failed.
;
; A bare directory listing skips entries with the hidden attribute set
; (2026-07-22, no override flag for now -- see ATTRIB). An explicit
; single-file/multi-arg reference still shows a hidden entry, matching
; DOS's "hidden only affects casual listing" convention.
;
; Wildcard support (2026-07-27, redesigned): a "*"/"?" pattern argument
; is detected via lib/file_glob.asm's is_glob and expanded via
; glob_init/glob_next, one match at a time, into the SAME per-match
; K_STAT+print_dir_entry body dir_multi_arg already uses -- whether the
; pattern is the program's only argument or one of several. This is a
; deliberate behavior improvement over the old shell-side pre-expansion
; design: previously a glob matching exactly one file took a DIFFERENT
; code path (the single-argument K_PATH_RESOLVE-and-maybe-list-a-
; directory logic) than one matching several (dir_multi_arg) -- an
; accidental quirk of match-count-dependent pre-expansion. Now match
; count is irrelevant: ANY glob pattern always shows one line per
; match, never recursing into a matched directory's own contents (a
; literal, non-glob directory argument still lists its contents, as
; always). A pattern matching zero files falls back to the literal,
; unexpanded text (nullglob-off), which for a single argument re-enters
; the original K_PATH_RESOLVE logic unchanged.
;
; Each entry is printed as a fixed-width line (column order changed
; 2026-07-26, at the user's own request, to match later MS-DOS/Windows
; `dir` output -- post-LFN versions print date/time before the size/
; type column, not after; 12-hour AM/PM time and a size/name separator
; both added the same day, after a hardware round showed the first cut
; of the reorder missing a separator and using 24-hour time):
;   date/time:  "MM/DD/YYYY  HH:MM AM/PM  " (unpacked from
;               DIRENT_WRTDATE/DIRENT_WRTTIME's packed FAT bit fields
;               -- see kernel/rtc.asm; hour converted from the on-disk
;               24-hour value to 12-hour + AM/PM display)
;   type:       a dedicated 7-character column, " <DIR> " for a
;               directory or 7 blank spaces for a file (2026-07-26,
;               split from the size column below into its own field
;               at the user's own request -- previously <DIR> and the
;               byte count shared ONE right-justified field; now every
;               entry always shows the SAME two columns, one of them
;               blank, rather than one column whose content depends on
;               entry type)
;   size:       right-justified, comma-grouped decimal byte count for
;               a file, or 13 blank spaces for a directory (its own
;               type already shown in the column above). Up to 10
;               digits + 3 commas, "4,294,967,295" is the largest
;               32-bit value and fills the column exactly (2026-07-26,
;               widened from a plain 5-column 16-bit-only field to
;               match kernel/file.asm's own >64K support -- see
;               fmt_size32/lib/fmt32.asm)
;   name:       the file/directory name, separated from the size/type
;               field above by 2 spaces (a real hardware-found bug,
;               2026-07-26: the first cut of the column reorder left
;               NO separator here at all for files, so a name printed
;               glued directly onto its own size digits)
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/file_glob.inc
#include    include/vollabel.inc

            extrn   fmt_size32          ; lib/fmt32.asm -- 32-bit
                                        ; comma-grouped decimal
                                        ; formatting, shared with
                                        ; progs/stat.asm
            extrn   is_glob
            extrn   glob_init
            extrn   glob_next
            extrn   vol_label_get       ; lib/vollabel.asm -- 2026-07-30,
                                        ; the "Volume in drive X is..."
                                        ; header below
            extrn   path_print_from_cluster  ; lib/pathstr.asm --
                                        ; 2026-07-30, the "Directory of
                                        ; <path>" header below

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            call    K_GETCURDIR         ; RD = current directory cluster
                                        ; (RA/RC survive this call --
                                        ; see kernel_getcurdir's own
                                        ; documented RA/RB/RC/R7
                                        ; protection, added specifically
                                        ; because this program reads RA
                                        ; right after this call)

            ; stash it -- the new (2026-07-27) is_glob check in the
            ; argc==2 path below clobbers RD before the literal-path
            ; fallback would otherwise still need it as K_PATH_
            ; RESOLVE's base cluster for a relative path
            mov     rf, dir_curdir_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; stash argc/argv too, before the volume-label header print
            ; below makes calls of its own that clobber RA/RC -- reloaded
            ; fresh right after, so the existing argc-based branching
            ; further down sees them exactly as before
            mov     rf, dir_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf
            mov     rf, dir_argc
            glo     rc
            str     rf

            ; --- "Volume in drive X is LABEL" / "has no label" header,
            ; matching real MS-DOS DIR (2026-07-30). A second
            ; K_GETCURDIR call, purely for its own D=cur_drive return
            ; value -- a provably safe no-op status check (cur_drive's
            ; BPB is already active from the first call above), chosen
            ; over touching that first call site's own carefully-
            ; reasoned RA/RC-survival comment. ---
            call    K_GETCURDIR
            adi     'C'                 ; D = 'C'+cur_drive
            plo     r9                  ; stash -- "mov rf,
                                        ; dir_vol_letter" right below
                                        ; clobbers D (gotcha #4)
            mov     rf, dir_vol_letter
            glo     r9
            str     rf

            mov     rd, dir_vol_buf
            call    vol_label_get       ; DF = 0/1
            lbdf    dir_vol_none

            call    K_INMSG
            db      "Volume in drive ",0
            mov     rf, dir_vol_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      " is ",0
            mov     rf, dir_vol_buf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     dir_vol_done

dir_vol_none:
            call    K_INMSG
            db      "Volume in drive ",0
            mov     rf, dir_vol_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      " has no label.",13,10,0

dir_vol_done:
            ; reload RA/RC fresh -- both were clobbered by the calls above
            mov     rf, dir_argv
            lda     rf
            phi     ra
            ldn     rf
            plo     ra
            mov     rf, dir_argc
            ldn     rf
            plo     rc

            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name.
            glo     rc
            smi     3
            lbdf    dir_multi_arg       ; argc >= 3: two or more path
                                        ; arguments

            glo     rc
            smi     2
            lbnf    dir_bare_listing    ; argc < 2: no path given, list
                                        ; the current directory

            ; argc == 2: exactly one path argument. Check is_glob
            ; FIRST (2026-07-27) -- see the file header for why a glob
            ; routes into dir_multi_arg's own per-match body instead of
            ; the literal K_PATH_RESOLVE-and-maybe-list-a-directory
            ; logic below.
            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] (path argument)
            mov     rf, dir_single_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dir_single_arg = argv[1]

            mov     rf, rd
            call    is_glob
            lbdf    dir_single_literal  ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, dir_single_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, dir_glob_ctx
            call    glob_init
            lbdf    not_found           ; bad prefix path -- same
                                        ; message as any other bad path

            mov     rf, dir_any_error
            ldi     0
            str     rf

            mov     rf, dir_glob_found
            ldi     0
            str     rf

dir_single_glob_loop:
            mov     rd, dir_glob_ctx
            call    glob_next
            lbdf    dir_single_glob_done  ; exhausted

            ; BUG FIX (caught in review, before ever assembling): RF
            ; holds glob_next's own returned match pointer at this
            ; point -- "mov rf, dir_glob_found" below would silently
            ; overwrite it with dir_glob_found's OWN address before
            ; dir_stat_and_print ever got a chance to read it. Stash
            ; it in R9 first (free at this point), restore right
            ; before the call.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, dir_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    dir_stat_and_print
            lbr     dir_single_glob_loop

dir_single_glob_done:
            mov     rf, dir_glob_found
            ldn     rf
            lbz     dir_single_literal  ; zero matches: nullglob-off
                                        ; fallback to the literal text

            mov     rf, dir_any_error
            ldn     rf
            lbnz    dma_exit_err        ; reuse dir_multi_arg's own
                                        ; error exit
            ldi     0                   ; exit code 0 = success
            rtn

dir_single_literal:
            mov     rb, dir_single_arg
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (path argument)
            mov     rb, dir_curdir_clust
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = cur_dir cluster (base
                                        ; for a relative path -- see the
                                        ; stash in start: above)
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, DF = 0/1
            lbdf    not_found           ; bad intermediate component

            ; an empty final component means the path itself named
            ; the target directory ("/", "cfg/", ...) -- the resolved
            ; parent cluster IS the target already
            ldn     rf
            lbz     dir_open_target

            ; save the final-component pointer in memory (not a
            ; register): K_DIR_READ uses R9/RA/RB/RC/RD/RF internally
            ; (see kernel/dir.asm), so nothing in a register would
            ; survive the search loop below.
            mov     rb, arg_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; arg_ptr = final component pointer

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE (untouched by the arg_ptr store above)
            call    K_DIR_OPEN

dir_find:
            mov     rf, dir_result
            call    K_DIR_READ
            lbdf    not_found           ; end of directory: no match

            ; compare entry name against the saved argument
            mov     rf, arg_ptr
            lda     rf                  ; D = argument pointer high byte
            phi     rd
            ldn     rf                  ; D = argument pointer low byte
            plo     rd                  ; RD = argument pointer
            mov     rf, dir_result      ; RF = entry name
            call    f_strcmp
            lbnz    dir_find            ; no match: keep looking

            ; a matching FILE (not a directory) just shows its own
            ; entry line and exits -- dir_result is already filled by
            ; the K_DIR_READ match above, no extra lookup needed
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     dir_single_file

            ; RD = the matched entry's first cluster -- falls through
            ; to dir_open_target below, same as the "empty final
            ; component" shortcuts above
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd
            lbr     dir_open_target

; dir_bare_listing: argc < 2 (no path given) -- reload RD from the
; cluster stashed at the very top of start:, before any of the
; volume-label header's own calls (a second K_GETCURDIR, vol_label_get)
; had a chance to clobber it. A real hardware-found bug (2026-07-30):
; dir_open_target expects RD to already hold the target cluster on
; entry, and this bare-listing path used to just fall straight into it
; with none of the header code in between -- back when RD still
; genuinely held the FIRST K_GETCURDIR's own result, untouched. Once
; the header code was inserted, RD ended up holding whatever
; vol_label_get's internal directory scan happened to leave behind
; instead, silently opening a garbage cluster (dir_curdir_clust/RA/RC
; were already being reloaded fresh after the header, RD was not).
dir_bare_listing:
            ; "Directory of <path>" header (2026-07-30), matching real
            ; MS-DOS's own blank-line/Directory-of/blank-line layout --
            ; only for the bare (no-argument) listing, since
            ; path_print_from_cluster assumes the cluster it's given
            ; belongs to the CURRENTLY ACTIVE drive, true here (cur_dir
            ; on the active drive) but not guaranteed for an arbitrary
            ; resolved path argument on a different drive
            call    K_INMSG
            db      13,10,"Directory of ",0

            mov     rf, dir_curdir_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    path_print_from_cluster

            call    K_INMSG
            db      13,10,13,10,0

            mov     rf, dir_curdir_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; reload RD -- clobbered by
                                        ; path_print_from_cluster above

dir_open_target:
            call    K_DIR_OPEN

dir_loop:
            mov     rf, dir_result      ; RF = result buffer
            call    K_DIR_READ
            lbdf    dir_done            ; DF=1 = end of directory

            ; skip hidden entries in the bare listing (2026-07-22) --
            ; no override flag for now (dir has no flag-parsing
            ; machinery today); an explicit reference via dir_single_file/
            ; dir_multi_arg or STAT still shows a hidden entry, matching
            ; DOS's "hidden only affects casual listing" convention
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_HIDDEN
            lbnz    dir_loop            ; hidden: skip, read the next

            call    print_dir_entry
            lbr     dir_loop

dir_done:
            ldi     0                   ; exit code 0 = success
            rtn

dir_single_file:
            call    print_dir_entry
            ldi     0                   ; exit code 0 = success
            rtn

not_found:
            call    K_INMSG
            db      "Directory not found.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; dir_multi_arg: two or more path arguments (typically via the shell's
; own glob expansion, e.g. "DIR *.txt") -- K_STAT each one independently
; and show its own entry line. A bad argument prints its own error and
; the rest still run; the final exit code reflects whether any argument
; failed.
;------------------------------------------------------------------
dir_multi_arg:
            ; stash argv/argc to memory -- K_STAT's own clobber
            ; footprint isn't proven anywhere in this codebase yet, so
            ; nothing here is trusted to survive it in a register
            ; (same defensive pattern progs/del.asm's own multi-
            ; argument loop already established)
            mov     rf, dir_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, dir_argc
            glo     rc
            str     rf

            mov     rf, dir_any_error
            ldi     0
            str     rf

            mov     rf, dir_i
            ldi     1
            str     rf

dma_loop:
            mov     rf, dir_i
            ldn     rf
            str     r2                  ; M(X) = dir_i
            mov     rf, dir_argc
            ldn     rf                  ; D = dir_argc
            xor                         ; D = dir_argc XOR dir_i
            lbz     dma_done            ; dir_i == argc: done

            ; RD = argv[dir_i]
            mov     rf, dir_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = dir_i (zero-extended)
            shl16   r8                  ; R8 = dir_i * 2
            mov     rb, dir_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = dir_argv (base, reloaded
                                        ; fresh every iteration)
            add16   rf, r8              ; RF = &argv[dir_i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = argv[dir_i]

            mov     rf, dir_cur_path
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; dir_cur_path = argv[dir_i]

            mov     rf, rd
            call    is_glob
            lbdf    dma_literal         ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, dir_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, dir_glob_ctx
            call    glob_init
            lbdf    dma_bad_path        ; bad prefix path: this argv
                                        ; entry's own error

            mov     rf, dir_glob_found
            ldi     0
            str     rf

dma_glob_loop:
            mov     rd, dir_glob_ctx
            call    glob_next
            lbdf    dma_glob_done       ; exhausted

            ; BUG FIX (caught in review, before ever assembling): see
            ; dir_single_glob_loop's own identical fix above -- RF
            ; must be stashed before the flag-set clobbers it.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, dir_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    dir_stat_and_print
            lbr     dma_glob_loop

dma_glob_done:
            mov     rf, dir_glob_found
            ldn     rf
            lbnz    dma_next            ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, dir_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    dir_stat_and_print
            lbr     dma_next

dma_bad_path:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, dir_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, dir_any_error
            ldi     $FF
            str     rf
            lbr     dma_next

dma_literal:
            mov     rf, dir_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    dir_stat_and_print

dma_next:
            mov     rf, dir_i
            ldn     rf
            adi     1
            str     rf
            lbr     dma_loop

dma_done:
            mov     rf, dir_any_error
            ldn     rf
            lbnz    dma_exit_err

            ldi     0                   ; exit code 0 = success
            rtn

dma_exit_err:
            ldi     1
            rtn

;------------------------------------------------------------------
; dir_stat_and_print: K_STAT a single path and print its entry line
; via print_dir_entry, or print "Not found: "+path and set
; dir_any_error on failure. Shared by dir_multi_arg's own per-item loop
; and the argc==2 glob-match loop above.
; Args:    RF = path
; Returns: nothing
; Modifies: everything (calls K_STAT/print_dir_entry)
;------------------------------------------------------------------
dir_stat_and_print:
            mov     r9, rf              ; R9 = path (RF is about to be
                                        ; reused for K_STAT's own args)
            mov     rf, dir_cur_path
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; dir_cur_path = path (for the
                                        ; possible error message)

            mov     rf, r9              ; RF = path string
            mov     rd, dir_result      ; RD = result buffer
            call    K_STAT              ; DF = 0/1
            lbdf    dsp_not_found

            call    print_dir_entry
            rtn

dsp_not_found:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, dir_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, dir_any_error
            ldi     $FF
            str     rf
            rtn

;------------------------------------------------------------------
; print_dir_entry: print dir_result (already filled by K_DIR_READ or
; K_STAT) as one fixed-width listing line -- see the file header for
; the column layout.
; Args:    none (reads dir_result)
; Returns: nothing
; Modifies: R7-RD (and D)
;------------------------------------------------------------------
print_dir_entry:
            ; ---- column order (2026-07-26): date/time, then the
            ; dir-tag-or-size field, then name -- matching later
            ; MS-DOS/Windows `dir` output (post-LFN) rather than this
            ; project's own original size-first layout, at the user's
            ; own request. Purely a reorder of the same three already-
            ; working blocks below (date/time unpacking+printing, the
            ; mutually-exclusive size-vs-<DIR>-tag block, the name) --
            ; none of their own internal formatting logic changed. ----

            ; ---- unpack last-write date into day/month/year ----
            mov     rf, dir_result
            add16   rf, DIRENT_WRTDATE
            lda     rf                  ; D = date high byte
            phi     rd
            ldn     rf                  ; D = date low byte
            plo     rd                  ; RD = packed date

            ; BUG FIX: "mov rf, wr_day" itself clobbers D (its own
            ; final LDI leaves D = wr_day's low address byte), so the
            ; masked day value just computed in D would not survive
            ; to "str rf" below unless the mov happens first, with D
            ; recomputed fresh right before the store -- the same
            ; class of bug this project has hit repeatedly (see
            ; CLAUDE.md gotcha #4). Confirmed on hardware: every
            ; entry showed the identical (wrong) "122/00 ... 125:126"
            ; -- wr_day/wr_month/wr_hour/wr_minute's own low address
            ; bytes, constant regardless of the real per-entry value,
            ; since only wr_year's store happened to reload D (via
            ; ghi/glo) after its own mov and so wasn't affected.
            mov     rf, wr_day
            glo     rd
            ani     $1F                 ; day = bits 4-0
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_date >> 5
            mov     rf, wr_month
            glo     rd
            ani     $0F                 ; month = bits 8-5 (now bits 3-0)
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_date >> 9 (year-1980)
            add16   rd, 1980
            mov     rf, wr_year
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; ---- unpack last-write time into hour/minute ----
            mov     rf, dir_result
            add16   rf, DIRENT_WRTTIME
            lda     rf                  ; D = time high byte
            phi     rd
            ldn     rf                  ; D = time low byte
            plo     rd                  ; RD = packed time

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_time >> 5
            mov     rf, wr_minute
            glo     rd
            ani     $3F                 ; minute = bits 10-5 (now bits 5-0)
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = packed_time >> 11 (hour)
            mov     rf, wr_hour
            glo     rd
            str     rf

            ; ---- convert the 24-hour wr_hour just stored above into a
            ; 12-hour wr_hour12 (1-12) + "AM"/"PM" string, matching the
            ; user's own desired format ("09:00 PM") rather than the
            ; previous 24-hour display. RD.0 still holds the 24-hour
            ; value here, untouched by the str above (str doesn't
            ; modify RD). ----
            glo     rd
            smi     12
            lbnf    dir_hour_is_am      ; DF=0 (borrow): wr_hour < 12

            mov     rf, dir_ampm
            ldi     'P'
            str     rf
            inc     rf
            ldi     'M'
            str     rf
            inc     rf
            ldi     0
            str     rf

            glo     rd
            smi     12
            plo     rd                  ; RD.0 = wr_hour - 12 (0-11)
            lbr     dir_hour12_zero_check

dir_hour_is_am:
            mov     rf, dir_ampm
            ldi     'A'
            str     rf
            inc     rf
            ldi     'M'
            str     rf
            inc     rf
            ldi     0
            str     rf
                                        ; RD.0 already = wr_hour (0-11)
                                        ; -- no subtraction needed here

dir_hour12_zero_check:
            glo     rd
            lbnz    dir_hour12_done     ; nonzero: use as-is (1-11)
            ldi     12
            plo     rd                  ; zero (midnight or noon, mod
                                        ; 12): display as 12
dir_hour12_done:
            mov     rf, wr_hour12
            glo     rd
            str     rf                  ; wr_hour12 = display hour
                                        ; (1-12)

            ; ---- print "MM/DD/YYYY  HH:MM AM/PM  " ----
            mov     rf, wr_month
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, wr_day
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, wr_year
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, size_buf        ; reuse size_buf (a separate,
                                        ; small 6-byte scratch buffer
                                        ; from size_buf13, which holds
                                        ; the actual file-size column
                                        ; printed LATER now, after
                                        ; date/time -- see the 2026-
                                        ; 07-26 column-reorder note
                                        ; above) for wr_year's own
                                        ; digits, a genuinely 16-bit
                                        ; value unrelated to file size
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, size_buf
            call    K_MSG

            call    K_INMSG
            db      "  ",0

            mov     rf, wr_hour12
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      ":",0

            mov     rf, wr_minute
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    print2digit

            call    K_INMSG
            db      " ",0

            mov     rf, dir_ampm
            call    K_MSG

            call    K_INMSG
            db      "  ",0

            ; ---- <DIR>-or-blank column (2026-07-26, split into its
            ; own field at the user's own request -- see the file
            ; header for the full rationale): a dedicated 7-character
            ; column, separate from the size column that follows. ----
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     pde_dirtag_blank

            mov     rf, dir_tag
            call    K_MSG
            lbr     pde_dirtag_done

pde_dirtag_blank:
            mov     rf, spaces13
            add16   rf, 6               ; 13-7=6 -- last 7 chars of
                                        ; spaces13 = 7 blank spaces,
                                        ; matching dir_tag's own width
            call    K_MSG

pde_dirtag_done:
            call    K_INMSG
            db      "  ",0

            ; ---- size-or-blank column: right-justified 13-column
            ; comma-grouped decimal byte count for a file, or 13
            ; blank spaces for a directory (its own type already
            ; shown in the column above) ----
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    pde_size_blank

            ; ---- file: right-justified 13-column comma-grouped
            ; decimal size (2026-07-26, >64K support) -- was a plain
            ; 5-column f_uintout of the low 16 bits only. Max value
            ; 4,294,967,295 is exactly 13 characters (10 digits + 3
            ; commas), matching the full 32-bit range kernel/file.asm
            ; now supports. ----
            mov     rf, dir_result
            add16   rf, DIRENT_SIZE
            lda     rf
            phi     rd                  ; RD.hi = size byte 0 (MSB)
            lda     rf
            plo     rd                  ; RD.lo = size byte 1
            lda     rf
            phi     r8                  ; R8.hi = size byte 2
            ldn     rf
            plo     r8                  ; R8.lo = size byte 3 (LSB)
                                        ; => RD:R8 = 32-bit size

            mov     rf, size_buf13      ; RF = destination buffer
            call    fmt_size32          ; builds the comma-grouped
                                        ; digit string into size_buf13
                                        ; and null-terminates it (see
                                        ; lib/fmt32.asm -- factored out
                                        ; 2026-07-26 so stat.asm and
                                        ; any future program can share
                                        ; this exact, already-verified
                                        ; conversion instead of each
                                        ; duplicating it)

            ; count characters written, to right-justify in 13 columns
            mov     rf, size_buf13
            ldi     0
            plo     rc                  ; RC.0 = character count
pde_count_loop:
            ldn     rf
            lbz     pde_count_done
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     pde_count_loop
pde_count_done:
            ; leading spaces = a substring of the 13-space buffer,
            ; starting "char count" chars in (fewer spaces needed the
            ; wider the formatted number is; always <= 13 characters
            ; since the value is at most 4,294,967,295)
            mov     rf, spaces13
            add16   rf, rc
            call    K_MSG

            mov     rf, size_buf13
            call    K_MSG               ; the digits+commas themselves
            lbr     pde_print_name

pde_size_blank:
            mov     rf, spaces13
            call    K_MSG               ; 13 blank spaces -- no size
                                        ; shown for a directory, its
                                        ; own type already printed in
                                        ; the dedicated column above

pde_print_name:
            ; separator before the name (2026-07-26; originally a
            ; hardware-found bug where this was missing entirely --
            ; see the file's own git history -- now applies uniformly
            ; regardless of entry type, matching this file's own
            ; established 2-space separator convention used between
            ; every other pair of columns).
            call    K_INMSG
            db      "  ",0

            mov     rf, dir_result      ; RF = DIRENT_NAME (at offset 0)
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            rtn

; ----------------------------------------------------------------
; print2digit: print RD (0-99) as two zero-padded decimal digits
; (e.g. 3 -> "03", 14 -> "14"). Used for month/day/hour/minute.
; Args:   RD = value (0-99)
; Returns: nothing
; ----------------------------------------------------------------
print2digit:
            glo     rd
            smi     10
            lbdf    p2d_use_uintout     ; value >= 10: two digits already

            glo     rd
            adi     '0'
            plo     rc                  ; stash the single digit's char
            mov     rf, digit_buf
            ldi     '0'
            str     rf
            inc     rf
            glo     rc
            str     rf
            inc     rf
            ldi     0
            str     rf
            lbr     p2d_print

p2d_use_uintout:
            mov     rf, digit_buf
            call    f_uintout
            ldi     0
            str     rf

p2d_print:
            mov     rf, digit_buf
            call    K_MSG
            rtn

arg_ptr:    dw      0
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for
                                        ; K_DIR_READ/K_STAT
size_buf:   ds      6                   ; decimal scratch reused for
                                        ; wr_year's own digits only now
                                        ; (max "65535"+null) -- the
                                        ; file-size column below has
                                        ; its own size_buf13 (fmt_size32,
                                        ; lib/fmt32.asm)
dir_tag:    db      " <DIR> ",0         ; 7-column directory tag,
                                        ; right-justified in the shared
                                        ; 13-column size field (2026-
                                        ; 07-26 column reorder -- see
                                        ; pde_is_dir) -- tag_blank (the
                                        ; old blank-tag-for-files field
                                        ; this reorder made unnecessary,
                                        ; see pde_print_name's own area
                                        ; above) removed as dead code
digit_buf:  ds      3                   ; scratch for print2digit ("99"+null)

; size_buf13/spaces13: the widened (2026-07-26, >64K support) file-size
; column -- size_buf13 holds fmt_size32's own comma-grouped digit
; string (max "4,294,967,295" = 13 chars + null = 14); spaces13 is the
; blank/right-justify-padding source, replacing the old spaces5 (no
; longer used anywhere, removed). The digit-extraction scratch itself
; (raw_digits/mod3_table) now lives in lib/fmt32.asm, shared with
; progs/stat.asm (factored out 2026-07-26, at the user's own
; suggestion, rather than duplicated here).
size_buf13: ds      14
spaces13:   db      "             ",0   ; 13 spaces

wr_day:     db      0
wr_month:   db      0
wr_year:    dw      0
wr_hour:    db      0
wr_minute:  db      0
wr_hour12:  db      0           ; 2026-07-26: 12-hour display value
                                ; (1-12), converted from wr_hour
dir_ampm:   ds      3           ; "AM"/"PM"+null

dir_argv:       dw      0
dir_argc:       db      0
dir_i:          db      0
dir_any_error:  db      0
dir_cur_path:   dw      0
dir_curdir_clust: dw    0
dir_single_arg: dw      0
dir_glob_found: db      0
dir_glob_ctx:   ds      GLOB_CTX_LEN
dir_vol_letter: db      0
dir_vol_buf:    ds      12

            end     start
