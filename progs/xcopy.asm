;
; xcopy.asm - recursive directory copy, with MS-DOS XCOPY-flavored
; switches within this project's own constraints
;
; Usage: XCOPY [-h] [-v] [-y] [-s] [-e] [-i] [-c] [-d] <source> <dest>
;
; <source> may be a file (single-file copy, same shape as COPY) or a
; directory. This matches real MS-DOS XCOPY's own flexibility -- the
; COPY/XCOPY split in real DOS isn't about file-vs-directory, it's
; about capability (XCOPY can do what COPY can't: hidden/system
; files, verify, recursion).
;
; Switches (real MS-DOS XCOPY analogues, per the user's own request
; for "as compatible as possible given our constraints" -- kept DASH-
; prefixed rather than real XCOPY's SLASH-prefixed style, deliberately:
; this project's own paths are forward-slash-rooted, e.g. "/cfg", so a
; "/S"-style switch would be genuinely ambiguous with a path argument,
; not just a style mismatch):
;   -h  Include hidden entries (files AND directories) in a directory
;       walk. Without it, a hidden entry is silently skipped -- same
;       "hidden affects casual enumeration only" convention DIR/LS
;       already use. Irrelevant for an explicitly-named single-file
;       source (matches real XCOPY: naming a hidden file directly
;       still copies it either way).
;   -v  Verify: after each file is fully written, re-open both the
;       source and the just-written destination fresh and compare
;       them byte-for-byte end to end. A mismatch is reported as an
;       error for that file (source unaffected either way).
;   -y  Don't prompt before overwriting an existing destination file --
;       just overwrite it. Without -y, an existing destination prompts
;       Y/N per file, identical to COPY's own overwrite prompt.
;   -s  Descend into subdirectories (matches real /S). WITHOUT -s, a
;       directory source only copies its own top-level files -- real
;       XCOPY's actual default, not "always recurse" (an earlier,
;       wrong design this project's own first XCOPY pass shipped with,
;       replaced here). A subdirectory that ends up empty (nothing
;       copied anywhere inside it) is removed again afterward unless
;       -e is also given.
;   -e  Also keep subdirectories that end up empty (matches real /E;
;       only meaningful together with -s -- without -s, no
;       subdirectories are touched at all regardless of -e).
;   -i  Accepted for compatibility, otherwise inert: real XCOPY uses
;       it to suppress an interactive "does destination specify a
;       file name or directory name?" prompt this implementation
;       never has in the first place (source type is already
;       unambiguous via K_STAT).
;   -c  Continue past a per-file/per-directory error instead of
;       aborting the whole run at the first one (matches real /C).
;       WITHOUT -c, matching real XCOPY's actual default, the first
;       error stops the entire operation rather than skipping and
;       continuing.
;   -d  Only copy a file if its source is newer than an already-
;       existing destination (matches real /D with no cutoff date
;       given). FAT's packed date/time fields compare correctly as
;       plain 16-bit values, so this needs no date-string parsing --
;       an explicit "-d:date" cutoff argument is deliberately not
;       implemented.
; Clustered like LS's own flags ("-hv" and "-h -v" behave identically).
;
; Directory-tree copy design: two-pass, non-kernel-scan-reentrant.
; K_DIR_OPEN/K_DIR_READ track a single, kernel-resident scan position
; -- not safe to interleave with a recursive call that also opens a
; directory (the recursive call's own K_DIR_OPEN would silently
; clobber the outer level's own scan position). So xc_walk always
; fully collects a directory's own entries (name/attr/cluster) into a
; bump-allocated array FIRST (pass 1, matching progs/ls.asm's own
; already-proven "collect everything, use it" pattern for the same
; underlying reason), then iterates that array (pass 2) -- by pass 2,
; the kernel's own directory-scan state is free to be reused by
; however deep a recursive call goes, since nothing here still depends
; on it surviving.
;
; Each level's own "resume state" (its entries array, current index,
; count, and bump_mark) lives in one bump-allocated XC_FRAME struct,
; addressed via a single pointer kept in R8 for that level's own
; pass-2 loop -- the ONLY value that needs protecting across a
; recursive call (or a per-file copy call), via a plain push/pop
; (R8's own contents, not what it points to -- bump allocation only
; ever grows forward, so a deeper call's own allocations can never
; disturb an outer level's already-allocated frame/entries). This is
; the first real recursion in this codebase; see the file's own
; xc_walk header for the full reasoning once more, close to the code.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   bump_init
            extrn   bump_alloc
            extrn   bump_mark
            extrn   bump_release

XCOPY_CHUNK_LEN: equ    512     ; matches COPY's own chunk size
XC_PATH_LEN:     equ    200     ; generous headroom over PATH_BUF_LEN
                                ; (128) for a multi-level accumulated
                                ; path; append is bounds-checked
                                ; against this either way
XC_NAME_CAP:     equ    128     ; matches DIRENT_NAME's own established
                                ; "up to 127 chars" max, copied
                                ; verbatim (DIRENT_ATTR starts right
                                ; after it in K_DIR_READ's own buffer)

; XC_ENTRY: one collected directory entry (name/attr/cluster only --
; not a full DIRENT_LEN copy, since size/time/date are never needed
; for a copy decision).
XC_ENTRY_NAME:      equ 0               ; XC_NAME_CAP bytes
XC_ENTRY_ATTR:      equ XC_NAME_CAP     ; 1 byte
XC_ENTRY_CLUST:     equ XC_NAME_CAP+1   ; 2 bytes, big-endian
XC_ENTRY_LEN:        equ XC_NAME_CAP+3

; XC_FRAME: one xc_walk invocation's own resume state, bump-allocated
; so each recursion level gets its own, and reclaimed for free by the
; same bump_release that reclaims that level's own entries array.
XC_FRAME_MARK:       equ 0   ; 2 bytes -- this level's own bump_mark
XC_FRAME_ARRAYBASE:  equ 2   ; 2 bytes -- collected-entries array start
XC_FRAME_COUNT:      equ 4   ; 1 byte
XC_FRAME_INDEX:      equ 5   ; 1 byte
XC_FRAME_SRCLENB:    equ 6   ; 1 byte -- xc_src_len before the
                              ; CURRENT entry's name was appended
XC_FRAME_DSTLENB:    equ 7   ; 1 byte
XC_FRAME_COPIEDB:    equ 8   ; 2 bytes -- xc_copied_count snapshotted
                              ; right before recursing into the
                              ; CURRENT entry (a directory) -- compared
                              ; against the live count after the
                              ; recursive call returns, to detect
                              ; "nothing was copied anywhere inside it"
                              ; for the -e empty-subdirectory cleanup
XC_FRAME_FRESH:      equ 10  ; 1 byte -- 1 if THIS call just
                              ; K_DIR_CREATE'd the current entry's own
                              ; destination directory, 0 if it already
                              ; existed (merge case) -- only a freshly
                              ; created directory is ever a candidate
                              ; for the empty-subdirectory cleanup;
                              ; pre-existing destination content is
                              ; never removed
XC_FRAME_LEN:         equ 11

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; init the bump allocator over [mem_base..mem_top]
            ; (LOADER_ARGS) -- same proven pattern progs/ls.asm and
            ; progs/bumptest.asm already established
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rf, LOADER_ARGS
            add16   rf, 2
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top
            mov     rf, r8
            call    bump_init           ; RD still holds mem_base

            call    xc_scan_options     ; sets xc_hmode/xc_vmode/
                                        ; xc_ymode, xc_src_arg/
                                        ; xc_dest_arg
            lbdf    usage_error         ; DF=1: not exactly 2 path
                                        ; arguments

            mov     rf, xc_copied_count
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; xc_copied_count = 0 (word)
            mov     rf, xc_any_error
            ldi     0
            str     rf
            mov     rf, xc_abort
            ldi     0
            str     rf

            ; --- does the source exist, and is it a directory? ---
            mov     rf, xc_src_arg
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = source path string

            mov     rf, r8
            mov     rd, xc_stat_dirent
            call    K_STAT              ; DF=0/1
            lbdf    xc_src_not_found

            mov     rf, xc_stat_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = source's attribute byte
            ani     ATTR_DIR
            lbnz    xc_source_is_dir

;------------------------------------------------------------------
; Single-file source: same destination convention as COPY (full path,
; or an existing directory + the source's own basename).
;------------------------------------------------------------------
            call    xc_resolve_file_dest ; sets real_dst
            lbdf    xc_exit_err

            mov     rf, xc_src_arg
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = source path

            mov     rf, real_dst
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = destination path

            mov     rf, r8
            mov     rd, r9
            call    xc_copy_one_file    ; DF=0/1
            lbdf    xc_exit_err

            ldi     0
            rtn

;------------------------------------------------------------------
; Directory source: ensure the destination exists as a directory
; (creating it if it doesn't), then recursively walk.
;------------------------------------------------------------------
xc_source_is_dir:
            mov     rf, xc_dest_arg
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = destination path

            mov     rf, r8
            mov     rd, xc_stat_dirent2
            call    K_STAT              ; DF=0/1
            lbdf    xc_dest_create      ; not found: create it

            mov     rf, xc_stat_dirent2
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     xc_dest_not_dir     ; exists, but is a file
            lbr     xc_dest_ready

xc_dest_create:
            mov     rf, xc_dest_arg
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            call    K_DIR_CREATE        ; DF=0/1
            lbdf    xc_dest_create_err

xc_dest_ready:
            ; --- set up xc_src_path/xc_dest_path to the top-level
            ; arguments, verbatim ---
            mov     rf, xc_src_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source arg string
            mov     rd, xc_src_path
            call    xc_strcpy           ; RC = length copied
            mov     rf, xc_src_len
            glo     rc
            str     rf

            mov     rf, xc_dest_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, xc_dest_path
            call    xc_strcpy
            mov     rf, xc_dest_len
            glo     rc
            str     rf

            ; RD = source directory's own resolved cluster, from the
            ; earlier K_STAT (xc_stat_dirent, still valid -- nothing
            ; since has re-issued K_STAT/K_DIR_READ)
            mov     rf, xc_stat_dirent+DIRENT_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            call    xc_walk             ; the recursive walk itself
                                        ; never fails outright -- per-
                                        ; entry problems are reported
                                        ; and skipped, tracked via
                                        ; xc_any_error

            mov     rf, xc_any_error
            ldn     rf
            lbnz    xc_exit_err

            ldi     0
            rtn

xc_src_not_found:
            call    K_INMSG
            db      "Source not found.",13,10,0
            ldi     1
            rtn

xc_dest_not_dir:
            call    K_INMSG
            db      "Destination exists and is not a directory.",13,10,0
            ldi     1
            rtn

xc_dest_create_err:
            call    K_INMSG
            db      "Cannot create destination directory.",13,10,0
            ldi     1
            rtn

xc_exit_err:
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: XCOPY [-h] [-v] [-y] <source> <destination>",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; xc_scan_options: walk argv[1..argc-1] once, recognizing "-h"/"-v"/
; "-y" as a clustered option group (matching progs/ls.asm's own
; ls_scan_options exactly -- "-hv" and "-h -v" behave identically).
; Everything else is collected as a path argument; there must be
; EXACTLY two (source, destination).
; Args:    none (reads RA/RC directly, at entry)
; Returns: DF=0 with xc_src_arg/xc_dest_arg set (exactly two path
;          arguments found), DF=1 otherwise (usage error).
;          xc_hmode/xc_vmode/xc_ymode set either way.
; Modifies: R7, R8, RB, RD, RF (and D)
;------------------------------------------------------------------
xc_scan_options:
            mov     rf, xc_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, xc_argc
            glo     rc
            str     rf

            mov     rf, xc_hmode
            ldi     0
            str     rf
            mov     rf, xc_vmode
            ldi     0
            str     rf
            mov     rf, xc_ymode
            ldi     0
            str     rf
            mov     rf, xc_smode
            ldi     0
            str     rf
            mov     rf, xc_emode
            ldi     0
            str     rf
            mov     rf, xc_imode
            ldi     0
            str     rf
            mov     rf, xc_cmode
            ldi     0
            str     rf
            mov     rf, xc_dmode
            ldi     0
            str     rf
            mov     rf, xc_num_paths
            ldi     0
            str     rf

            mov     rf, xc_scan_i
            ldi     1
            str     rf

xso_loop:
            mov     rf, xc_scan_i
            ldn     rf
            str     r2
            mov     rf, xc_argc
            ldn     rf
            xor
            lbz     xso_done

            mov     rf, xc_scan_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8
            mov     rb, xc_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            add16   rf, r8              ; RF = &argv[xc_scan_i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = argv[xc_scan_i]

            mov     rf, rd
            ldn     rf
            xri     '-'
            lbnz    xso_is_path

            mov     rf, rd
            inc     rf
            ldn     rf
            lbz     xso_is_path         ; bare "-": treat as a path

xso_optchar_loop:
            ldn     rf
            lbz     xso_next

            xri     'h'
            lbnz    xso_opt_notv
            mov     rb, xc_hmode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_notv:
            ldn     rf
            xri     'v'
            lbnz    xso_opt_noty
            mov     rb, xc_vmode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_noty:
            ldn     rf
            xri     'y'
            lbnz    xso_opt_nots
            mov     rb, xc_ymode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_nots:
            ldn     rf
            xri     's'
            lbnz    xso_opt_note
            mov     rb, xc_smode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_note:
            ldn     rf
            xri     'e'
            lbnz    xso_opt_noti
            mov     rb, xc_emode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_noti:
            ldn     rf
            xri     'i'
            lbnz    xso_opt_notc
            mov     rb, xc_imode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_notc:
            ldn     rf
            xri     'c'
            lbnz    xso_opt_notd
            mov     rb, xc_cmode
            ldi     1
            str     rb
            lbr     xso_optchar_next

xso_opt_notd:
            ldn     rf
            xri     'd'
            lbnz    xso_optchar_next
            mov     rb, xc_dmode
            ldi     1
            str     rb

xso_optchar_next:
            inc     rf
            lbr     xso_optchar_loop

xso_is_path:
            mov     rf, xc_num_paths
            ldn     rf
            smi     2
            lbdf    xso_too_many        ; already have 2: too many

            mov     rf, xc_num_paths
            ldn     rf
            lbnz    xso_second_path

            mov     rf, xc_src_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     xso_path_stored

xso_second_path:
            mov     rf, xc_dest_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

xso_path_stored:
            mov     rf, xc_num_paths
            ldn     rf
            adi     1
            str     rf

xso_next:
            mov     rf, xc_scan_i
            ldn     rf
            adi     1
            str     rf
            lbr     xso_loop

xso_too_many:
            stc
            rtn

xso_done:
            mov     rf, xc_num_paths
            ldn     rf
            smi     2
            lbnz    xso_bad_count       ; not exactly 2
            clc
            rtn

xso_bad_count:
            stc
            rtn

;------------------------------------------------------------------
; xc_resolve_file_dest: single-file-source case only -- same
; directory-target convenience as COPY's own copy_one (progs/
; copy.asm): if xc_dest_arg names an existing directory, real_dst =
; xc_dest_arg + '/' + basename(xc_src_arg); otherwise real_dst =
; xc_dest_arg unchanged. Reuses xc_stat_dirent (already read for the
; top-level source/dest -- but this checks the DESTINATION, so it's
; read fresh here into xc_stat_dirent2 to avoid disturbing the
; caller's own copy of the source's stat).
; Args:    none (reads xc_src_arg/xc_dest_arg)
; Returns: DF=0 with real_dst set, DF=1 on a hard error (none
;          currently possible here -- kept for a uniform contract
;          with every other DF-returning routine in this file)
; Modifies: R7, R8, R9, RA, RB, RC, RD, RF
;------------------------------------------------------------------
xc_resolve_file_dest:
            mov     rf, xc_dest_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, xc_stat_dirent2
            call    K_STAT
            lbdf    xrfd_plain          ; doesn't exist: use as-is

            mov     rf, xc_stat_dirent2
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     xrfd_plain          ; exists, but is a file

            ; --- build real_dst = xc_dest_arg + '/' (if needed) +
            ; basename(xc_src_arg) into dst_final ---
            mov     rf, xc_dest_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dst_final
xrfd_dst_loop:
            lda     rd
            lbz     xrfd_dst_done
            str     rf
            inc     rf
            lbr     xrfd_dst_loop
xrfd_dst_done:
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     xrfd_have_sep
            ldi     '/'
            str     rf
            inc     rf
xrfd_have_sep:
            mov     rc, xc_src_arg
            lda     rc
            phi     rd
            ldn     rc
            plo     rd                  ; RD = source string pointer
            mov     r8, rd
            mov     r9, rd
xrfd_basename_scan:
            ldn     r8
            lbz     xrfd_basename_done
            xri     '/'
            lbnz    xrfd_basename_next
            inc     r8
            mov     r9, r8
            lbr     xrfd_basename_scan
xrfd_basename_next:
            inc     r8
            lbr     xrfd_basename_scan
xrfd_basename_done:
            mov     rd, r9
xrfd_append_loop:
            lda     rd
            str     rf
            lbz     xrfd_append_done
            inc     rf
            lbr     xrfd_append_loop
xrfd_append_done:

            mov     rb, real_dst
            mov     rf, dst_final
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            clc
            rtn

xrfd_plain:
            mov     rb, real_dst
            mov     rf, xc_dest_arg
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            clc
            rtn

;------------------------------------------------------------------
; xc_strcpy: copy a null-terminated string from RF to RD, including
; the terminator.
; Args:    RF = source, RD = destination
; Returns: RC = length copied (not counting the terminator)
; Modifies: RF, RD, RC (and D)
;------------------------------------------------------------------
xc_strcpy:
            ldi     0
            plo     rc
            phi     rc
xcs_loop:
            lda     rf
            str     rd
            lbz     xcs_done
            inc     rd
            glo     rc
            adi     1
            plo     rc
            lbr     xcs_loop
xcs_done:
            rtn

;------------------------------------------------------------------
; xc_append_name: append '/' + a null-terminated name onto a path
; buffer, bounds-checked against XC_PATH_LEN.
; Args:    RD = path buffer base, RC.0 = current length (byte),
;          RF = name to append (null-terminated)
; Returns: DF=0 with the buffer updated and the new length written
;          back to *the same RC.0 byte location the caller passed --
;          actually returns the new length in D (caller stores it);
;          DF=1 if it wouldn't fit (buffer left unchanged)
; Modifies: R7, R8, R9 (and D)
;------------------------------------------------------------------
xc_append_name:
            ldi     0
            phi     rc                  ; zero-extend the caller's
                                        ; length byte -- every call
                                        ; site builds RC via "mov rc,
                                        ; symbol / ldn rc / plo rc",
                                        ; which leaves RC's OWN high
                                        ; byte holding the symbol
                                        ; address's high byte, not 0;
                                        ; the add16 below would
                                        ; otherwise add that garbage
                                        ; in as part of a bogus 16-bit
                                        ; offset
            mov     r7, rd
            add16   r7, rc              ; R7 = path buffer + current
                                        ; length (write position)
            mov     r8, rc              ; R8.0 = running length
                                        ; (starts at current length)

            glo     r8
            smi     XC_PATH_LEN-2
            lbdf    xan_too_long        ; not even room for '/'+NUL

            ldi     '/'
            str     r7
            inc     r7
            glo     r8
            adi     1
            plo     r8

xan_loop:
            ldn     rf
            lbz     xan_done
            glo     r8
            smi     XC_PATH_LEN-1
            lbdf    xan_too_long
            ldn     rf
            str     r7
            inc     r7
            inc     rf
            glo     r8
            adi     1
            plo     r8
            lbr     xan_loop

xan_done:
            ldi     0
            str     r7
            glo     r8
            plo     rc
            clc
            rtn

xan_too_long:
            stc
            rtn

;------------------------------------------------------------------
; xc_report_error: mark xc_any_error, and (unless -c was given) also
; mark xc_abort -- xcw_process_loop's own top-of-loop check then stops
; the whole walk at the next opportunity, at every recursion level
; (xc_abort is a plain global, not per-frame, so every level's own
; next check sees it once set -- no special handling needed at any
; return point for it to propagate all the way up).
; Args:    none
; Returns: nothing
; Modifies: R7 (and D)
;------------------------------------------------------------------
xc_report_error:
            mov     r7, xc_any_error
            ldi     $FF
            str     r7

            mov     r7, xc_cmode
            ldn     r7
            lbnz    xre_done            ; -c given: note the error,
                                        ; but don't abort the walk

            mov     r7, xc_abort
            ldi     $FF
            str     r7

xre_done:
            rtn

;------------------------------------------------------------------
; xc_walk: recursively copy the directory at cluster RD (whose full
; path is already reflected in xc_src_path/xc_src_len) into the
; directory at xc_dest_path/xc_dest_len (already confirmed to exist,
; by the caller). See the file's own header comment for the full
; two-pass/frame design.
;
; REGISTER-SAFETY NOTE (found before ever assembling, by checking
; K_DIR_READ's own real clobber footprint rather than assuming): this
; project's own file.asm/dir.asm establish that K_DIR_READ (via
; _dir_next_sector -> _cluster_to_lba, whose own header explicitly
; documents "Modifies: R7, R8, RC, RD, RF, RA, RB") clobbers R8 --
; along with R9 (dir_read's own top-of-proc scratch) and everything
; else K_DIR_READ's own established doc already lists. K_STAT/
; K_DIR_CREATE are assumed just as aggressively clobbering (gotcha
; #8/#10 -- never proven safe, treat as fully clobbered). This means
; the frame pointer CANNOT be kept live in a register across ANY of
; these calls, including within pass 1's own collection loop -- it is
; instead kept in a global, xcw_frame_ptr, and reloaded fresh into R8
; immediately before every single use, with no exceptions, even
; where an earlier reload might seem to still be live in straight-
; line code. The one place a plain reload isn't enough is the
; recursive call itself: xc_walk calls itself, and the inner
; invocation's own "xcw_frame_ptr = its own new frame" write clobbers
; the SAME global the outer level still needs -- so that one spot
; additionally push/pops R8 around the call, and explicitly re-syncs
; xcw_frame_ptr from R8 afterward (the popped value, not the global,
; is correct at that point).
;
; Args:    RD = source directory's own resolved cluster
; Returns: nothing (xc_any_error/xc_copied_count updated)
; Modifies: everything
;------------------------------------------------------------------
xc_walk:
            ; --- THE ACTUAL BUG (found 2026-07-24 from a real hardware
            ; report: XCOPY recursed into the SAME directory name
            ; forever, no files ever copied) ---
            ; RD (this routine's own cluster argument) must be stashed
            ; HERE, before anything else runs. bump_mark's own header
            ; documents "Modifies: RD (and D)" and bump_alloc's own
            ; header documents "Modifies: R7, R8, R9, RB, RD (and D)"
            ; -- BOTH calls below clobber RD, which K_DIR_OPEN (a few
            ; lines further down) still needs. The comment that used
            ; to sit next to that K_DIR_OPEN call ("RD still holds the
            ; source cluster passed in -- nothing above this line
            ; touches RD") was simply wrong, asserted without actually
            ; checking bump_mark/bump_alloc's own documented clobber
            ; lists. In practice RD ended up holding whatever
            ; bump_alloc's own internal "size - 1" arithmetic last
            ; left it as (XC_FRAME_LEN - 1 = 7, a FIXED value,
            ; identical on every call) -- so every single invocation
            ; of xc_walk, at every recursion depth, opened the SAME
            ; wrong cluster 7 instead of the real source cluster,
            ; genuinely re-reading the identical (wrong) directory
            ; contents forever: same entry, same name, same
            ; "recursion" that was never really descending into
            ; anything. Originally fixed with an RA stash (RA was
            ; untouched by bump_mark/bump_alloc's own clobber lists);
            ; superseded below by a memory stash instead, once a THIRD
            ; call (K_STAT, with no such guarantee) also needed to run
            ; before K_DIR_OPEN -- see the next comment block.

            ; SECOND real bug, also found via a hardware report
            ; (2026-07-25, a cross-drive "xcopy /cfg F:/cfg" created
            ; the destination directory but copied zero files, no
            ; error): K_DIR_OPEN/K_DIR_READ (kernel/dir.asm's own
            ; dir_open header: "Args: RD = starting cluster... " -- no
            ; drive parameter at all) operate against WHATEVER drive
            ; is currently active in the kernel's BPB/FAT cache, not
            ; necessarily the drive the cluster number actually
            ; belongs to. Only path_resolve (reached via K_STAT/
            ; K_DIR_CREATE/K_FILE_OPEN/etc, called with a real path
            ; STRING) ever calls the kernel's own _switch_drive --
            ; there's no userland-callable primitive to activate a
            ; drive directly from a bare cluster number. The caller of
            ; xc_walk (xc_source_is_dir at the top level, or this same
            ; routine's own xcw_subdir_recurse one level up) always
            ; does at least one K_STAT/K_DIR_CREATE on the
            ; DESTINATION path immediately before, which leaves the
            ; DESTINATION's drive active -- so by the time pass 1
            ; below called K_DIR_OPEN on the SOURCE's cluster, it was
            ; silently reading sectors under the wrong drive's BPB.
            ; Fixed by re-resolving xc_src_path (already set to this
            ; level's own full source path, at the top level from
            ; xc_src_arg, or by xc_append_name during recursive
            ; descent -- see xc_dest_ready/xcw_process_loop) via
            ; K_STAT purely for the side effect of reactivating the
            ; correct drive; the DIRENT result itself is discarded.
            ; The cluster itself is stashed to MEMORY here (not just
            ; RA) since this new K_STAT call's own clobber footprint
            ; isn't trusted any more than bump_mark/bump_alloc's
            ; already-documented one above (gotcha #8/#10) -- RA is
            ; genuinely fine for the two calls immediately below (both
            ; already audited), but reusing it as a THIRD call's
            ; implicit protection would be exactly the kind of
            ; unverified assumption that caused the first bug above.
            mov     rf, xcw_src_clust
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            call    bump_mark           ; RF = mark
            mov     rb, xcw_mark_tmp
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; stash mark (survives the
                                        ; frame-alloc call right below)

            ldi     low XC_FRAME_LEN
            plo     rc
            ldi     high XC_FRAME_LEN
            phi     rc
            call    bump_alloc          ; RF = frame pointer, or 0
            glo     rf
            lbnz    xcw_have_frame
            ghi     rf
            lbnz    xcw_have_frame
            lbr     xcw_oom             ; out of memory: abort this
                                        ; whole xcopy (no frame to
                                        ; work with at all)

xcw_have_frame:
            mov     rb, xcw_frame_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; xcw_frame_ptr = frame ptr

            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = frame ptr (fresh)
            mov     rf, r8
            add16   rf, XC_FRAME_MARK
            mov     rd, xcw_mark_tmp
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; frame->mark = mark

            ; reactivate the SOURCE's own drive -- see this routine's
            ; own entry comment above for why. Result discarded; only
            ; the _switch_drive side effect inside path_resolve is
            ; wanted here.
            mov     rf, xc_src_path
            mov     rd, xc_stat_dirent
            call    K_STAT

            ; --- pass 1: collect entries ---
            mov     rf, xcw_src_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = source cluster (fresh
                                        ; from memory -- do NOT trust
                                        ; RA or RD to have survived
                                        ; bump_mark/bump_alloc/the
                                        ; K_STAT above)
            call    K_DIR_OPEN

            mov     rf, xcw_count
            ldi     0
            str     rf
            mov     rf, xcw_array_base
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; xcw_array_base = 0 (0000 --
                                        ; sentinel for "not set yet")

xcw_collect_loop:
            mov     rf, xc_dirent
            call    K_DIR_READ
            lbdf    xcw_collect_done    ; end of directory

            mov     rf, xc_dirent
            mov     rd, xc_dot
            call    f_strcmp
            lbz     xcw_collect_loop    ; "."

            mov     rf, xc_dirent
            mov     rd, xc_dotdot
            call    f_strcmp
            lbz     xcw_collect_loop    ; ".."

            mov     rf, xc_hmode
            ldn     rf
            lbnz    xcw_collect_keep    ; -h: keep hidden entries too

            mov     rf, xc_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_HIDDEN
            lbnz    xcw_collect_loop    ; hidden, no -h: skip

            ; -s gates recursion entirely: without it, a directory
            ; entry is never even collected, matching real XCOPY's
            ; own default (top-level files only, no subdirectories
            ; touched at all). Filtering here (like the hidden check
            ; above) rather than in pass 2 keeps pass 2 simple -- an
            ; entry that never made it into the array can't need a
            ; "should I skip this" branch there at all.
            mov     rf, xc_smode
            ldn     rf
            lbnz    xcw_collect_keep    ; -s given: keep directories

            mov     rf, xc_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    xcw_collect_loop    ; directory, no -s: skip

xcw_collect_keep:
            ldi     low XC_ENTRY_LEN
            plo     rc
            ldi     high XC_ENTRY_LEN
            phi     rc
            call    bump_alloc          ; RF = entry pointer, or 0
            glo     rf
            lbnz    xcw_entry_ok
            ghi     rf
            lbnz    xcw_entry_ok
            lbr     xcw_oom

xcw_entry_ok:
            mov     r7, rf              ; R7 = new entry pointer --
                                        ; survives to the end of THIS
                                        ; iteration only; no call
                                        ; below this point (before the
                                        ; loop repeats) touches R7 --
                                        ; xc_dirent-copy work below is
                                        ; pure register/memory motion

            mov     rf, xcw_array_base
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = xcw_array_base
            ghi     r9
            lbnz    xcw_have_base
            glo     r9
            lbnz    xcw_have_base
            ; first entry this level: remember it as the array base
            mov     rf, xcw_array_base
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

xcw_have_base:
            ; copy name (128 bytes, verbatim -- K_DIR_READ's own
            ; DIRENT_NAME field is always NUL-terminated within it)
            mov     rf, xc_dirent
            mov     rd, r7
            ldi     low XC_NAME_CAP
            plo     rc
            ldi     high XC_NAME_CAP
            phi     rc
xcw_name_copy:
            ghi     rc
            lbnz    xcw_name_copy_go
            glo     rc
            lbz     xcw_name_copy_done
xcw_name_copy_go:
            lda     rf
            str     rd
            inc     rd
            sub16   rc, 1               ; immediate form -- doesn't
                                        ; touch M(R2), unlike the
                                        ; register-register form
                                        ; (gotcha #18); simpler and
                                        ; safer than a hand-rolled
                                        ; smi/smbi decrement
            lbr     xcw_name_copy
xcw_name_copy_done:

            mov     rf, xc_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attr byte
            plo     r9                  ; stash it -- gotcha #4: the
                                        ; "mov rd, r7" below clobbers
                                        ; D before "str rd" would ever
                                        ; see it otherwise
            mov     rd, r7
            add16   rd, XC_ENTRY_ATTR
            glo     r9                  ; D = attr byte (reloaded)
            str     rd

            mov     rf, xc_dirent
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte, RF ->
                                        ; low byte
            plo     r9                  ; stash it (same gotcha #4
                                        ; shape as above)
            mov     rd, r7
            add16   rd, XC_ENTRY_CLUST
            glo     r9                  ; D = cluster high byte
                                        ; (reloaded)
            str     rd
            inc     rd
            ldn     rf                  ; D = cluster low byte (RF
                                        ; untouched since the lda
                                        ; above, safe as-is)
            str     rd

            mov     rf, xcw_count
            ldn     rf
            adi     1
            str     rf

            lbr     xcw_collect_loop

xcw_collect_done:
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = frame ptr (fresh --
                                        ; K_DIR_READ, called last, has
                                        ; no proven-safe registers)

            mov     rf, r8
            add16   rf, XC_FRAME_ARRAYBASE
            mov     rd, xcw_array_base
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            mov     rf, r8
            add16   rf, XC_FRAME_COUNT
            mov     rd, xcw_count
            ldn     rd
            str     rf

            mov     rf, r8
            add16   rf, XC_FRAME_INDEX
            ldi     0
            str     rf

            ; --- pass 2: process each collected entry ---
xcw_process_loop:
            ; -c gate: without it, the FIRST real error anywhere
            ; (this level or any descendant) stops the whole
            ; operation, matching real XCOPY's own default. xc_abort
            ; is a plain global (not per-frame) -- every level's own
            ; next loop check sees it once set, so it propagates up
            ; through the recursion for free with no special handling
            ; needed at any return point.
            mov     rf, xc_abort
            ldn     rf
            lbnz    xcw_epilogue

            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = frame ptr (fresh)

            mov     rf, r8
            add16   rf, XC_FRAME_INDEX
            ldn     rf
            str     r2                  ; M(X) = frame->index
            mov     rf, r8
            add16   rf, XC_FRAME_COUNT
            ldn     rf
            xor                         ; D = count XOR index
            lbz     xcw_epilogue        ; index == count: done here

            ; entry_ptr = frame->array_base + index*XC_ENTRY_LEN
            mov     rf, r8
            add16   rf, XC_FRAME_INDEX
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = index (zero-extended)
            mov     rf, xcw_idx_tmp
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; stash index (16-bit mul
                                        ; below needs real registers,
                                        ; not just D)

            ; R9 = index * XC_ENTRY_LEN via repeated add (XC_ENTRY_LEN
            ; isn't a power of two, and this project has no f_mul16
            ; precedent to lean on -- a plain loop is simplest and
            ; correct; entry counts per directory are small)
            mov     rf, xcw_idx_tmp
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = index again
            mov     r7, r9              ; R7 = remaining multiplier
            ldi     0
            plo     r9
            phi     r9                  ; R9 = accumulator, starts 0
xcw_mul_loop:
            ghi     r7
            lbnz    xcw_mul_go
            glo     r7
            lbz     xcw_mul_done
xcw_mul_go:
            add16   r9, XC_ENTRY_LEN
            sub16   r7, 1               ; immediate form -- see the
                                        ; identical simplification in
                                        ; xcw_name_copy above
            lbr     xcw_mul_loop
xcw_mul_done:
            ; R9 = index*XC_ENTRY_LEN -- R8 (frame ptr) untouched by
            ; the whole multiply above (register-only, no calls)
            mov     rf, r8
            add16   rf, XC_FRAME_ARRAYBASE
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = array_base
            add16   r7, r9              ; R7 = entry_ptr

            mov     rf, xcw_entry_ptr
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

            ; --- record src/dst lengths before this entry, into the
            ; frame (still the SAME r8 loaded at the top of this
            ; iteration -- no call since then) ---
            mov     rf, r8
            add16   rf, XC_FRAME_SRCLENB
            mov     rd, xc_src_len
            ldn     rd
            str     rf
            mov     rf, r8
            add16   rf, XC_FRAME_DSTLENB
            mov     rd, xc_dest_len
            ldn     rd
            str     rf

            ; --- append this entry's name to both paths (each
            ; xc_append_name call clobbers everything -- entry_ptr is
            ; reloaded fresh from its own global at each use, exactly
            ; as it already was) ---
            mov     rf, xcw_entry_ptr
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = entry_ptr
            mov     rf, r7
            add16   rf, XC_ENTRY_NAME   ; RF = entry's own name string

            mov     rd, xc_src_path
            mov     rc, xc_src_len
            ldn     rc
            plo     rc
            call    xc_append_name      ; DF=0/1
            lbdf    xcw_entry_toolong
            mov     rd, xc_src_len
            glo     rc
            str     rd

            mov     rf, xcw_entry_ptr
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, r7
            add16   rf, XC_ENTRY_NAME

            mov     rd, xc_dest_path
            mov     rc, xc_dest_len
            ldn     rc
            plo     rc
            call    xc_append_name
            lbdf    xcw_entry_toolong_undo
            mov     rd, xc_dest_len
            glo     rc
            str     rd

            ; --- is this entry a directory or a file? ---
            mov     rf, xcw_entry_ptr
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, r7
            add16   rf, XC_ENTRY_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbz     xcw_entry_file

;------------------------------------------------------------------
; Directory entry: ensure the matching destination subdirectory
; exists, then recurse. Reached only when -s allowed this entry to be
; collected at all (see xcw_collect_loop above).
;------------------------------------------------------------------
            mov     rf, xc_dest_path
            mov     rd, xc_stat_dirent2
            call    K_STAT
            lbdf    xcw_subdir_create

            mov     rf, xc_stat_dirent2
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    xcw_subdir_merge

            call    K_INMSG
            db      "Skipped (destination exists, not a directory): ",0
            mov     rf, xc_dest_path
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            call    xc_report_error
            lbr     xcw_entry_restore

xcw_subdir_create:
            mov     rf, xc_dest_path
            call    K_DIR_CREATE
            lbdf    xcw_subdir_create_err

            ; freshly created this call -- a candidate for the -e
            ; empty-directory cleanup below, once we know whether
            ; anything ended up inside it
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            add16   rf, XC_FRAME_FRESH
            ldi     1
            str     rf
            lbr     xcw_subdir_recurse

xcw_subdir_merge:
            ; already existed -- never a cleanup candidate, regardless
            ; of what ends up inside it (pre-existing destination
            ; content is never removed)
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            add16   rf, XC_FRAME_FRESH
            ldi     0
            str     rf

xcw_subdir_recurse:
            ; snapshot xc_copied_count into frame->copied_before,
            ; compared against the live count after the recursive
            ; call returns to detect "nothing was copied anywhere in
            ; this subtree" for the -e cleanup
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, xc_copied_count
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = xc_copied_count (current)
            mov     rf, r8
            add16   rf, XC_FRAME_COPIEDB
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

            ; RD = subdir's own cluster
            mov     rf, xcw_entry_ptr
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, r7
            add16   rf, XC_ENTRY_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            ; frame pointer MUST be reloaded fresh right here -- the
            ; K_STAT/K_DIR_CREATE calls and the snapshot above have
            ; all run since the last reload at the top of this
            ; iteration
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

            push    r8                  ; protect frame pointer
                                        ; across the recursive call
            call    xc_walk             ; RECURSION
            pop     r8                  ; restore THIS level's own
                                        ; frame pointer

            ; xcw_frame_ptr itself now holds the INNER call's own
            ; (dead) frame pointer -- resync it to match the just-
            ; popped R8 before anything below reloads it fresh again
            mov     rf, xcw_frame_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

            ; --- -e cleanup: only for a directory THIS call freshly
            ; created, and only if nothing was copied anywhere inside
            ; it, and only if -e was NOT given ---
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8

            mov     rf, r8
            add16   rf, XC_FRAME_FRESH
            ldn     rf
            lbz     xcw_subdir_done     ; merged into an existing dir:
                                        ; never a cleanup candidate

            mov     rf, xc_emode
            ldn     rf
            lbnz    xcw_subdir_done     ; -e given: always keep it

            mov     rf, xc_copied_count
            lda     rf                  ; D = current count's high
                                        ; byte, rf -> low byte position
            str     r2
            mov     rb, r8
            add16   rb, XC_FRAME_COPIEDB
            ldn     rb                  ; D = snapshot's high byte
            xor
            lbnz    xcw_subdir_done     ; differs: something was
                                        ; copied somewhere inside

            mov     rf, xc_copied_count
            inc     rf
            ldn     rf                  ; D = current count's low byte
            str     r2
            mov     rb, r8
            add16   rb, XC_FRAME_COPIEDB
            inc     rb
            ldn     rb                  ; D = snapshot's low byte
            xor
            lbnz    xcw_subdir_done     ; differs: something was
                                        ; copied somewhere inside

            ; equal counts: nothing was copied anywhere in this
            ; subtree -- remove the now-confirmed-empty directory this
            ; call created. A failure here is silently ignored (best-
            ; effort cleanup only; worst case an empty directory is
            ; left behind, which is harmless)
            mov     rf, xc_dest_path
            call    K_DIR_REMOVE

xcw_subdir_done:
            lbr     xcw_entry_restore

xcw_subdir_create_err:
            call    K_INMSG
            db      "Cannot create: ",0
            mov     rf, xc_dest_path
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            call    xc_report_error
            lbr     xcw_entry_restore

;------------------------------------------------------------------
; File entry: copy it. xc_copy_one_file never touches xcw_frame_ptr
; (it has no knowledge of xc_walk's own internals), so no push/pop
; or resync is needed here -- a plain fresh reload in
; xcw_entry_restore (below) is sufficient, same as after any other
; call.
;------------------------------------------------------------------
xcw_entry_file:
            mov     rf, xc_src_path
            mov     rd, xc_dest_path
            call    xc_copy_one_file    ; DF=0/1
            lbnf    xcw_entry_restore

            call    xc_report_error

xcw_entry_restore:
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = frame ptr (fresh --
                                        ; K_STAT/K_DIR_CREATE/
                                        ; xc_copy_one_file/xc_walk all
                                        ; reach here by different
                                        ; paths, all equally untrusted)

            mov     rf, r8
            add16   rf, XC_FRAME_SRCLENB
            ldn     rf
            plo     r7                  ; R7.0 = saved src length
            ldi     0
            phi     r7                  ; zero-extend -- R7.1 is
                                        ; otherwise stale from
                                        ; whatever last wrote it, and
                                        ; the add16 below needs a real
                                        ; 16-bit R7 (same class of bug
                                        ; xc_append_name's own header
                                        ; comment already documents)
            mov     rf, xc_src_path
            add16   rf, r7
            ldi     0
            str     rf                  ; truncate src path
            mov     rf, xc_src_len
            glo     r7
            str     rf

            mov     rf, r8
            add16   rf, XC_FRAME_DSTLENB
            ldn     rf
            plo     r7
            ldi     0
            phi     r7                  ; zero-extend (see above)
            mov     rf, xc_dest_path
            add16   rf, r7
            ldi     0
            str     rf
            mov     rf, xc_dest_len
            glo     r7
            str     rf

            mov     rf, r8
            add16   rf, XC_FRAME_INDEX
            ldn     rf
            adi     1
            str     rf

            lbr     xcw_process_loop

xcw_entry_toolong_undo:
            ; the SOURCE append already succeeded; undo it before
            ; reporting, so the path buffers stay consistent for the
            ; next sibling entry. Frame pointer reloaded fresh --
            ; xc_append_name (the source append, just above) clobbers
            ; everything.
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            add16   rf, XC_FRAME_SRCLENB
            ldn     rf
            plo     r7
            ldi     0
            phi     r7                  ; zero-extend (see the
                                        ; identical fix in
                                        ; xcw_entry_restore above)
            mov     rf, xc_src_path
            add16   rf, r7
            ldi     0
            str     rf
            mov     rf, xc_src_len
            glo     r7
            str     rf
            lbr     xcw_entry_toolong

xcw_entry_toolong:
            call    K_INMSG
            db      "Skipped (path too long).",13,10,0
            call    xc_report_error
            lbr     xcw_entry_restore

xcw_epilogue:
            ; RD (frame->mark, via a fresh reload) is the only thing
            ; needed here -- pass 2's own loop just ended, no reason
            ; to trust R8 across whatever the LAST iteration's own
            ; calls did
            mov     rf, xcw_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            add16   rf, XC_FRAME_MARK
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9              ; RF = this level's own mark
            call    bump_release
            rtn

xcw_oom:
            call    K_INMSG
            db      "Out of memory.",13,10,0
            mov     rf, xc_any_error
            ldi     $FF
            str     rf
            mov     rf, xc_abort
            ldi     $FF
            str     rf                  ; unconditional abort,
                                        ; regardless of -c -- the bump
                                        ; arena is shared across the
                                        ; whole walk, so continuing
                                        ; would almost certainly just
                                        ; fail the exact same way for
                                        ; every remaining entry
            rtn

;------------------------------------------------------------------
; xc_src_newer: is the source directory entry's own last-write
; date/time strictly newer than the destination's? Compares WRTDATE
; then WRTTIME, most-significant field first -- FAT's own packed
; format (year/month/day packed high-to-low in WRTDATE, hour/min/sec
; likewise in WRTTIME) means a plain unsigned compare of each whole
; 16-bit field, with no need to unpack individual components, already
; gives the correct chronological ordering.
; Args:    RF = pointer to source's own DIRENT_LEN-byte K_STAT buffer
;          RD = pointer to destination's own DIRENT_LEN-byte K_STAT
;          buffer
; Returns: DF=1 if source is STRICTLY newer, DF=0 otherwise (older or
;          identical -- an unchanged file is not re-copied under -d)
; Modifies: R7, R8, R9 (and D)
;------------------------------------------------------------------
xc_src_newer:
            mov     r7, rf              ; R7 = source dirent
            mov     r8, rd              ; R8 = dest dirent

            ; NOTE (real bug, found via hardware test 2026-07-25): SM
            ; computes D = D - M(R(X)), NOT M(R(X)) - D -- confirmed
            ; against Asm/02's own SUB16 macro expansion (opcodes.def:
            ; stages the SUBTRAHEND via "str r2" first, then loads the
            ; MINUEND into D, then SM). The first version of this
            ; routine staged the byte it wanted to SUBTRACT (dest)
            ; into D and the one to subtract FROM (source) into
            ; M(R2) -- backwards -- so it silently computed dest-
            ; source instead of source-dest, and reported "source is
            ; newer" whenever dest was newer than source (which it
            ; always is right after a copy, since file_close always
            ; stamps the CURRENT time, not the source's original
            ; time). Every byte pair below now stages the DEST byte
            ; first (the subtrahend), loads the SOURCE byte into D
            ; right before SM (the minuend) -- D = source - dest.

            ; --- WRTDATE high byte ---
            mov     r9, r8
            add16   r9, DIRENT_WRTDATE
            ldn     r9
            str     r2                  ; M(R2) = dest's byte
            mov     r9, r7
            add16   r9, DIRENT_WRTDATE
            ldn     r9                  ; D = source's byte
            sm                          ; D = source - dest
            lbz     xsn_date_hi_eq
            lbdf    xsn_yes
            lbr     xsn_no

xsn_date_hi_eq:
            ; --- WRTDATE low byte ---
            mov     r9, r8
            add16   r9, DIRENT_WRTDATE
            inc     r9
            ldn     r9
            str     r2
            mov     r9, r7
            add16   r9, DIRENT_WRTDATE
            inc     r9
            ldn     r9
            sm
            lbz     xsn_date_lo_eq
            lbdf    xsn_yes
            lbr     xsn_no

xsn_date_lo_eq:
            ; WRTDATE identical -- compare WRTTIME as the tiebreaker
            mov     r9, r8
            add16   r9, DIRENT_WRTTIME
            ldn     r9
            str     r2
            mov     r9, r7
            add16   r9, DIRENT_WRTTIME
            ldn     r9
            sm
            lbz     xsn_time_hi_eq
            lbdf    xsn_yes
            lbr     xsn_no

xsn_time_hi_eq:
            mov     r9, r8
            add16   r9, DIRENT_WRTTIME
            inc     r9
            ldn     r9
            str     r2
            mov     r9, r7
            add16   r9, DIRENT_WRTTIME
            inc     r9
            ldn     r9
            sm
            lbz     xsn_no              ; fully identical: not newer
            lbdf    xsn_yes
            lbr     xsn_no

xsn_yes:
            stc
            rtn

xsn_no:
            clc
            rtn

;------------------------------------------------------------------
; xc_copy_one_file: copy src_path to dst_path (both exact, caller-
; resolved paths). Prompts for overwrite confirmation unless xc_ymode
; is set; verifies afterward if xc_vmode is set. Prints its own error
; message on any real failure; a declined overwrite is NOT an error.
; On success (and not silently skipped), prints dst_path and
; increments xc_copied_count -- classic XCOPY-style progress output.
; Args:    RF = source path, RD = destination path
; Returns: DF=0 on success (including a declined overwrite), DF=1 on
;          any real failure (including a verify mismatch)
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
xc_copy_one_file:
            mov     rb, xc_cp_src
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            mov     rb, xc_cp_dst
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rf, xc_dmode
            ldn     rf
            lbz     xcp_check_overwrite ; -d not given: skip date check

            ; -d given: does the destination exist? If not, always
            ; copy -- nothing to compare against.
            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_stat_dirent2
            call    K_STAT
            lbdf    xcp_check_overwrite ; dest doesn't exist: copy

            mov     rb, xc_cp_src
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_stat_dirent
            call    K_STAT
            lbdf    xcp_check_overwrite ; source stat failed -- let the
                                        ; real open below report the
                                        ; real error

            mov     rf, xc_stat_dirent
            mov     rd, xc_stat_dirent2
            call    xc_src_newer
            lbdf    xcp_check_overwrite ; source strictly newer: copy

            ; not newer than the existing destination -- skip this
            ; file silently. DF is already 0 (xc_src_newer's own "not
            ; newer" return), so this is success-with-no-copy.
            rtn

xcp_check_overwrite:
            mov     rf, xc_ymode
            ldn     rf
            lbnz    xcp_open_source     ; -y: never prompt

            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_cp_ck_fcb
            mov     ra, xc_cp_ck_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    xcp_open_source     ; doesn't exist: no prompt
                                        ; needed

            mov     rd, xc_cp_ck_fcb
            call    K_FILE_CLOSE

            call    K_INMSG
            db      "Overwrite ",0
            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    K_MSG
            call    K_INMSG
            db      "? (Y/N) ",0

            call    K_READ
            plo     rc
            mov     rf, xc_cp_answer
            glo     rc
            str     rf

            call    K_TTY
            call    K_INMSG
            db      13,10,0

            mov     rf, xc_cp_answer
            ldn     rf
            ani     $DF
            xri     'Y'
            lbnz    xcp_cancelled

xcp_open_source:
            mov     rb, xc_cp_src
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_cp_src_fcb
            mov     ra, xc_cp_src_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    xcp_src_not_found

            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_cp_dst_fcb
            mov     ra, xc_cp_dst_iobuf
            ldi     1
            call    K_FILE_OPEN
            lbdf    xcp_dst_open_error

xcp_copy_loop:
            mov     rf, xc_cp_buf
            ldi     low XCOPY_CHUNK_LEN
            plo     rc
            ldi     high XCOPY_CHUNK_LEN
            phi     rc
            mov     rd, xc_cp_src_fcb
            call    K_FILE_READ
            lbdf    xcp_read_error

            glo     rc
            lbnz    xcp_have_bytes
            ghi     rc
            lbz     xcp_copy_done
xcp_have_bytes:
            mov     rf, xc_cp_buf
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_WRITE
            lbdf    xcp_write_error

            lbr     xcp_copy_loop

xcp_copy_done:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_CLOSE

            mov     rf, xc_vmode
            ldn     rf
            lbz     xcp_report_ok

            call    xc_verify_file      ; DF=0/1
            lbdf    xcp_verify_failed

xcp_report_ok:
            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, xc_copied_count
            inc     rf                  ; RF -> low byte (this file's
                                        ; own established word
                                        ; convention: high byte at the
                                        ; base address, low byte at
                                        ; base+1 -- matches every
                                        ; other word field here, e.g.
                                        ; XC_FRAME_MARK's own store)
            ldn     rf                  ; D = low byte
            adi     1                   ; D = low byte + 1, DF = carry
            str     rf                  ; store new low byte
            dec     rf                  ; RF -> high byte (base)
            ldn     rf                  ; D = high byte
            adci    0                   ; D = high byte + 0 + carry-in
            str     rf                  ; store new high byte
                                        ; xc_copied_count++ (16-bit)

            clc
            rtn

xcp_verify_failed:
            call    K_INMSG
            db      "Verify failed: ",0
            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            stc
            rtn

xcp_read_error:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            stc
            rtn

xcp_write_error:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            stc
            rtn

xcp_dst_open_error:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            stc
            rtn

xcp_src_not_found:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            stc
            rtn

xcp_cancelled:
            clc
            rtn

;------------------------------------------------------------------
; xc_verify_file: re-open src/dst (both read-only) fresh and compare
; them byte-for-byte, chunk by chunk, to end of file. Reuses the same
; FCBs xc_copy_one_file just closed.
; Args:    none (reads xc_cp_src/xc_cp_dst)
; Returns: DF=0 if identical end-to-end, DF=1 on any mismatch
;          (including a length mismatch) or I/O error
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
xc_verify_file:
            mov     rb, xc_cp_src
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_cp_src_fcb
            mov     ra, xc_cp_src_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    xvf_mismatch

            mov     rb, xc_cp_dst
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, xc_cp_dst_fcb
            mov     ra, xc_cp_dst_iobuf
            ldi     0
            call    K_FILE_OPEN
            lbdf    xvf_close_src_mismatch

xvf_loop:
            mov     rf, xc_cp_buf
            ldi     low XCOPY_CHUNK_LEN
            plo     rc
            ldi     high XCOPY_CHUNK_LEN
            phi     rc
            mov     rd, xc_cp_src_fcb
            call    K_FILE_READ
            lbdf    xvf_close_both_mismatch
            mov     rf, xvf_src_n
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            mov     rf, xvf_buf2
            ldi     low XCOPY_CHUNK_LEN
            plo     rc
            ldi     high XCOPY_CHUNK_LEN
            phi     rc
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_READ
            lbdf    xvf_close_both_mismatch

            ; same byte count?
            mov     rf, xvf_src_n
            lda     rf
            str     r2
            ghi     rc
            xor
            lbnz    xvf_close_both_mismatch
            mov     rf, xvf_src_n
            inc     rf
            ldn     rf
            str     r2
            glo     rc
            xor
            lbnz    xvf_close_both_mismatch

            ; both zero: end of both files, success
            ghi     rc
            lbnz    xvf_compare
            glo     rc
            lbnz    xvf_compare
            lbr     xvf_done

xvf_compare:
            mov     r7, rc              ; R7 = remaining byte count
            mov     r8, xc_cp_buf
            mov     r9, xvf_buf2
xvf_cmp_loop:
            ghi     r7
            lbnz    xvf_cmp_go
            glo     r7
            lbz     xvf_loop            ; chunk matched, read more
xvf_cmp_go:
            ldn     r8
            str     r2
            ldn     r9
            xor
            lbnz    xvf_close_both_mismatch
            inc     r8
            inc     r9
            sub16   r7, 1               ; immediate form -- see the
                                        ; identical simplification in
                                        ; xc_walk above
            lbr     xvf_cmp_loop

xvf_done:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_CLOSE
            clc
            rtn

xvf_close_both_mismatch:
            mov     rd, xc_cp_dst_fcb
            call    K_FILE_CLOSE
xvf_close_src_mismatch:
            mov     rd, xc_cp_src_fcb
            call    K_FILE_CLOSE
xvf_mismatch:
            stc
            rtn

xc_argv:            dw      0
xc_argc:             db      0
xc_num_paths:        db      0
xc_scan_i:           db      0
xc_hmode:            db      0
xc_vmode:            db      0
xc_ymode:            db      0
xc_smode:            db      0
xc_emode:            db      0
xc_imode:            db      0
xc_cmode:            db      0
xc_dmode:            db      0
xc_src_arg:          dw      0
xc_dest_arg:         dw      0
real_dst:            dw      0
xc_copied_count:     dw      0   ; widened to a word (2026-07-24) --
                                ; a byte could wrap at 256 files
                                ; copied within one subtree, causing
                                ; a false "nothing was copied here"
                                ; reading for the -e empty-directory
                                ; cleanup
xc_any_error:        db      0
xc_abort:            db      0   ; set once a real error occurs and
                                ; -c was NOT given -- checked at the
                                ; top of xcw_process_loop; naturally
                                ; propagates up through every
                                ; recursion level once set, since each
                                ; level's own next loop check sees it

xc_src_path:         ds      XC_PATH_LEN
xc_dest_path:        ds      XC_PATH_LEN
xc_src_len:          db      0
xc_dest_len:         db      0

xc_stat_dirent:       ds      DIRENT_LEN
xc_stat_dirent2:      ds      DIRENT_LEN
xc_dirent:            ds      DIRENT_LEN
xc_dot:                db      ".",0
xc_dotdot:             db      "..",0

xcw_frame_ptr:        dw      0
xcw_mark_tmp:         dw      0
xcw_array_base:       dw      0
xcw_count:            db      0
xcw_idx_tmp:          dw      0
xcw_entry_ptr:        dw      0
xcw_src_clust:        dw      0

dst_final:            ds      132

; CALLER-ALLOCATED FCBs for the per-file copy/verify routines
xc_cp_src:            dw      0
xc_cp_dst:            dw      0
xc_cp_answer:         db      0
xc_cp_src_fcb:        ds      FCB_LEN
xc_cp_src_iobuf:      ds      FCB_IOBUF_LEN
xc_cp_dst_fcb:        ds      FCB_LEN
xc_cp_dst_iobuf:      ds      FCB_IOBUF_LEN
xc_cp_ck_fcb:         ds      FCB_LEN
xc_cp_ck_iobuf:       ds      FCB_IOBUF_LEN
xc_cp_buf:            ds      XCOPY_CHUNK_LEN

xvf_src_n:            dw      0
xvf_buf2:             ds      XCOPY_CHUNK_LEN

            end     start
