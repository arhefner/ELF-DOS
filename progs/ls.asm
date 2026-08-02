;
; ls.asm - list a directory, Linux ls-style
;
; Usage: LS [-laF] [path...]
;
; Options may appear anywhere on the line, combined or separate ("-lF"
; and "-l -F" behave identically -- see ls_scan_options), and don't
; count as path arguments.
;
; Default output: sorted file/directory names only, printed in
; columns (column-major fill order, matching real Unix ls -- entries
; fill down each column before moving to the next). Column width uses
; the COLUMNS environment variable if set to a valid nonzero number
; (read once, in ls_resolve below, since that's the point every
; parse-argv code path already converges through); LS_SCREEN_COLS
; (80) is both the compile-time fallback and ls_screen_cols' own
; initial value, so an unset/malformed/zero COLUMNS behaves exactly
; like before this was added.
;
; -l: one entry per line, "d"/"-" type indicator, size, last-write
; date/time (same MM/DD/YYYY HH:MM format DIR already uses, and the
; same FAT packed-date/time unpacking logic, copied rather than
; shared -- this project's established precedent, see DIR/STAT), then
; the name.
;
; -l's size column is human-readable, Linux `ls -h` style, always --
; not a separate opt-in flag (confirmed with the user, 2026-07-26):
; plain byte count under 1024 (no suffix), else 1-3 significant digits
; with a K/M/G suffix, one decimal place shown only for a single-digit
; whole part (e.g. "512", "1.5K", "42K", "3.9G"). See ls_fmt_human's
; own header comment for the exact algorithm and its two documented,
; deliberate approximations (smallest-unit-under-1000 selection, and a
; reduced-precision decimal digit that avoids a 32-bit multiply
; overflow for the G unit).
;
; -F: append "/" after directory entries (no executable-attribute
; concept on ELF-DOS, so unlike real ls -F this is the only suffix
; case). Composes with quoting below -- a directory name containing a
; space prints as 'my dir'/, quotes around the name, slash outside.
;
; -a: show entries with the hidden attribute set too (2026-07-22). A
; bare directory-scan listing normally skips them; an explicit
; file/dir argument or a shell glob match is never filtered regardless
; of -a, matching DOS's "hidden only affects casual listing, not
; access" convention -- see K_STAT/ATTRIB (progs/attrib.asm) for
; setting/clearing the bit.
;
; A name containing a space (2026-07-22) prints single-quoted, e.g.
; 'my file.txt' -- shows exactly how the name would need to be typed
; on a future command line, and makes an otherwise invisible trailing
; space (legal in an LFN entry, though never in an 8.3 short name)
; visible. Precomputed once per entry at collection time
; (ls_add_entry's own namelen scan, LSENT_QUOTE) rather than
; rescanned at print time -- see ls_print_name.
;
; With no path argument, lists the current directory (matching DIR's
; own default). A path argument (bare name, relative, or absolute)
; lists that directory instead, without changing the current
; directory -- same K_PATH_RESOLVE-based approach DIR itself uses.
;
; Collected entries live in a fixed-size static table (up to
; LS_MAX_ENTRIES) of small fixed structs -- but each entry's NAME is a
; pointer into heap_bump-allocated storage, sized to the name's real
; length (+1 for the NUL), not a fixed 128-byte buffer per slot.
; Switched to this 2026-07-19 (originally deferred, per the comment
; below this used to have -- those libraries are now hardware-
; confirmed, see lib/heap_bump.asm/progs/bumptest.asm): ls's own
; "collect everything, use it, exit" pattern is exactly what a bump
; (arena) allocator is for, no per-object free() ever needed. Links
; against lib/heap_bump.prg -- NOT a self-contained single-file
; program like most of progs/*.asm; see the Makefile's own dedicated
; rule for it (same pattern bumptest/malloctest already established).
; bump_init runs once at startup over [mem_base..mem_top] (LOADER_ARGS
; -- guaranteed past ls's own loaded image, code+static-data included,
; since mem_base = PROG_BASE + the loaded program's own size, see
; kernel/loader.asm). If bump_alloc ever fails (directory content
; exceeds available RAM, extremely unlikely), collection just stops
; there and whatever was already gathered is sorted/printed -- the
; same graceful cap LS_MAX_ENTRIES already applies for "too many
; entries," now also covering "not enough RAM for the entries' names."
;
; Sorting uses a hand-rolled byte-by-byte comparison (ls_namecmp)
; rather than the BIOS's f_strcmp -- every existing call site of
; f_strcmp in this codebase only ever checks for zero/nonzero
; (equality), never ordering, so f_strcmp's ordering behavior for
; unequal strings is unconfirmed; ls_namecmp's own ordering contract
; is fully known since it's defined right here.
;
; Wildcard support (2026-07-27, redesigned): identical shape to DIR's
; own -- see progs/dir.asm's header for the full rationale. A "*"/"?"
; pattern (single-path or one of several) is detected via lib/
; file_glob.asm's is_glob and expanded via glob_init/glob_next into
; the SAME per-match K_STAT+ls_add_entry body ls_multi_stat already
; uses, one match at a time; a single-path glob no longer takes a
; different code path than a multi-path one just because of how many
; files it happens to match. A pattern matching zero files falls back
; to the literal, unexpanded text (nullglob-off).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/file_glob.inc

            extrn   bump_init
            extrn   bump_alloc
            extrn   env_getenv
            extrn   env_parse_uint
            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

; ---- per-entry storage struct (fixed size, LSENT_LEN bytes) ----
LSENT_ATTR:     equ     0           ; 1 byte, FAT attribute byte
LSENT_DATE:     equ     1           ; 2 bytes, packed FAT last-write date
LSENT_TIME:     equ     3           ; 2 bytes, packed FAT last-write time
LSENT_SIZE:     equ     5           ; 4 bytes, full 32-bit size (widened
                                    ; 2026-07-26, matching DIR/STAT's own
                                    ; >64K support -- was 2 bytes/low-
                                    ; word-only; every field after this
                                    ; one shifted +2 as a result)
LSENT_NAMEPTR:  equ     9           ; 2 bytes: pointer to a heap_bump-
                                    ; allocated, NUL-terminated name
                                    ; (sized to the real name's length,
                                    ; not a fixed buffer -- see the file
                                    ; header comment)
LSENT_NAMELEN:  equ     11          ; 1 byte: this entry's DISPLAY
                                    ; length (2026-07-22: redefined from
                                    ; "real name length" -- now the real
                                    ; length + 2 if LSENT_QUOTE is set +
                                    ; 1 if -F applies to this entry),
                                    ; precomputed at collection time so
                                    ; the per-column-width layout pass
                                    ; (2026-07-19) and the print-time
                                    ; padding calculation both just read
                                    ; this back rather than rescanning
                                    ; the name or re-checking -F/ATTR_DIR
                                    ; live. The real string length used
                                    ; for the bump_alloc size and the
                                    ; name-copy loop's bound is a
                                    ; SEPARATE local (ls_namelen) that
                                    ; never includes these adjustments --
                                    ; conflating the two would make the
                                    ; copy loop read past the real name.
LSENT_QUOTE:    equ     12          ; 1 byte: 1 if this entry's name
                                    ; contains a space and should be
                                    ; printed single-quoted, else 0 --
                                    ; precomputed at collection time
                                    ; (ls_add_entry) so print time never
                                    ; needs to rescan for a space either.
LSENT_LEN:      equ     13

LS_NAME_CAP:    equ     127         ; matches K_DIR_READ's own DIRENT_NAME
                                    ; limit -- caps the length-counting
                                    ; scan and the bump_alloc request
                                    ; size; a real name is never
                                    ; truncated in practice

; LS_MAX_ENTRIES raised back up (2026-07-19, alongside the switch to
; heap_bump for name storage) now that the fixed per-entry cost is tiny
; (LSENT_LEN=11 [was 10 before the 2026-07-22 LSENT_QUOTE addition] + 2
; bytes in ls_ptrs = 13 bytes/entry, vs. the 137 bytes/entry the old
; fixed-inline-name design cost). Capped at 255, not raised further, so
; the collect loop's existing single-byte ls_count bounds check (below)
; needs no changes -- it already treats 256 as a hard ceiling.
; 255 * 13 = 3315 bytes fixed -- well under the OLD 48-entry budget
; (6576 bytes) while supporting over 5x as many entries; actual name
; storage now scales with the real directory content instead of a
; worst-case per-slot reservation.
LS_MAX_ENTRIES: equ     255
LS_MAX_COLS:    equ     32
LS_SCREEN_COLS: equ     80

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; init the bump allocator over the real [mem_base..mem_top]
            ; range (LOADER_ARGS -- same pattern bumptest.asm already
            ; established on hardware). mem_base is guaranteed past
            ; this whole loaded program's own image (code + every
            ; static ds/dw below), so this can't collide with anything
            ; ls itself declares.
            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_base
            mov     rf, LOADER_ARGS
            inc     rf                  ; +2 via two INCs (2026-08-01
                                        ; size-reduction pass): cheaper
                                        ; than ADD16 reg,2's 8-byte
                                        ; macro expansion, and DF isn't
                                        ; needed from it here (the very
                                        ; next instruction is "lda rf",
                                        ; which reloads D from memory
                                        ; regardless)
            inc     rf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top
            mov     rf, r8              ; RF = mem_top (bump_init's arg)
            call    bump_init           ; RD still holds mem_base

            call    K_GETCURDIR         ; RD = current directory cluster
                                        ; (RA/RC survive this call, same
                                        ; guarantee DIR itself relies on)
            mov     rb, ls_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ls_cluster = current dir (default)

            mov     rf, ls_longmode
            ldi     0
            str     rf                  ; ls_longmode = 0

            mov     rf, ls_fmode
            ldi     0
            str     rf                  ; ls_fmode = 0

            mov     rf, ls_amode
            ldi     0
            str     rf                  ; ls_amode = 0

            mov     rf, ls_patharg
            ldi     0
            str     rf
            inc     rf
            ldi     0
            str     rf                  ; ls_patharg = 0 (no path arg)

            mov     rf, ls_any_error
            ldi     0
            str     rf                  ; ls_any_error = 0 -- only
                                        ; ls_multi_stat ever sets this
                                        ; nonzero, but it must start
                                        ; clean regardless of which of
                                        ; the 0/1/2+-path cases below
                                        ; actually runs

            ; ---- option scan: recognize flags (today just "-l",
            ; exact-token match) ANYWHERE on the line, not just
            ; argv[1] -- the user's own proposal, so a future flag
            ; (-a, -F, ...) is just one more comparison in
            ; ls_scan_options below, with zero changes needed here.
            ; Builds a compacted, zero-based ls_paths[]/ls_num_paths
            ; with every recognized flag token removed.
            call    ls_scan_options

            ; if exactly one path argument was found, capture it into
            ; ls_patharg the same way the old single-slot parser did,
            ; so the existing K_PATH_RESOLVE/ls_find_loop logic below
            ; (unchanged) needs no further changes. 0 or 2+ paths
            ; leave ls_patharg at 0 -- handled by ls_resolve_body's
            ; own dispatch further down.
            mov     rf, ls_num_paths
            ldn     rf
            smi     1
            lbnz    ls_resolve

            mov     rf, ls_paths
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_paths[0]
            mov     rb, ls_patharg
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            lbr     ls_resolve          ; BUG FIX (hardware-found,
                                        ; 2026-07-22): this used to fall
                                        ; straight through into
                                        ; ls_scan_options' own body
                                        ; below (no branch separated
                                        ; them) -- a second, un-called
                                        ; pass through that routine
                                        ; would hit its own "rtn" and
                                        ; pop the ORIGINAL call-into-
                                        ; start return address, exiting
                                        ; the whole program silently
                                        ; before ever reaching
                                        ; ls_resolve. Explains why every
                                        ; single-path case (explicit
                                        ; file, explicit dir, a single
                                        ; glob match, even a not-found
                                        ; name) printed nothing at all.

;------------------------------------------------------------------
; ls_scan_options: walk argv[1..argc-1] once, recognizing flags
; anywhere on the line. A token is an option cluster if it starts with
; "-" and has at least one character after it ("-l", "-F", "-lF", ...
; -- real getopt-style clustering, so "-lF" and "-l -F" behave
; identically); every character after the leading "-" is scanned
; independently ('l' sets ls_longmode, 'F' sets ls_fmode, 'a' sets
; ls_amode, anything else is silently ignored -- a deliberate minimal
; choice, matching this project's generally lenient argument handling
; elsewhere, e.g. echo/args don't validate either). The whole token is
; consumed either way, never copied into ls_paths, even if some/all of
; its characters went unrecognized. A bare "-" (nothing after it) falls
; through and is treated as an ordinary path token instead, avoiding an
; ambiguous empty cluster. Builds a compacted, zero-based list of the
; remaining (non-flag) arguments in ls_paths/ls_num_paths -- everything
; downstream only ever looks at ls_paths/ls_num_paths/ls_longmode/
; ls_fmode/ls_amode, never argv directly.
; Args:    none (reads RA/RC directly, at entry)
; Returns: nothing (ls_paths/ls_num_paths/ls_longmode/ls_fmode/ls_amode
;          set)
; Modifies: R7, R8, RB, RD, RF (and D)
;------------------------------------------------------------------
ls_scan_options:
            ; stash argv/argc to memory -- needed since this loop
            ; re-derives argv[i] fresh each iteration, and safe
            ; regardless of what runs after this routine returns
            ; (env_getenv/env_parse_uint's own broad clobber
            ; footprint, in particular)
            mov     rf, ls_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, ls_argc
            glo     rc
            str     rf

            mov     rf, ls_num_paths
            ldi     0
            str     rf

            mov     rf, ls_scan_i
            ldi     1
            str     rf

lso_loop:
            mov     rf, ls_scan_i
            ldn     rf
            str     r2                  ; M(X) = ls_scan_i
            mov     rf, ls_argc
            ldn     rf                  ; D = ls_argc
            xor                         ; D = ls_argc XOR ls_scan_i
            lbz     lso_done            ; ls_scan_i == argc: done

            ; RD = argv[ls_scan_i]
            mov     rf, ls_scan_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ls_scan_i (zero-extended)
            shl16   r8                  ; R8 = ls_scan_i * 2
            mov     rb, ls_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = ls_argv (base, reloaded
                                        ; fresh every iteration)
            add16   rf, r8              ; RF = &argv[ls_scan_i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = argv[ls_scan_i]

            ; is this token an option cluster ("-" followed by at
            ; least one flag character)? A bare "-" (nothing after it)
            ; falls through and is treated as an ordinary path token.
            mov     rf, rd
            ldn     rf                  ; D = token[0]
            xri     '-'
            lbnz    lso_is_path

            mov     rf, rd
            inc     rf                  ; RF = &token[1]
            ldn     rf                  ; D = token[1]
            lbz     lso_is_path         ; bare "-": treat as a path

lso_optchar_loop:
            ldn     rf                  ; D = current option character
            lbz     lso_next            ; end of cluster: whole token
                                        ; consumed, move to the next
                                        ; argv slot (never added to
                                        ; ls_paths)

            xri     'l'
            lbnz    lso_opt_notl
            mov     rb, ls_longmode
            ldi     1
            str     rb                  ; recognized 'l': set the flag
            lbr     lso_optchar_next

lso_opt_notl:
            ldn     rf                  ; reload -- xri above clobbered D
            xri     'F'
            lbnz    lso_opt_nota
            mov     rb, ls_fmode
            ldi     1
            str     rb                  ; recognized 'F': set the flag
            lbr     lso_optchar_next

lso_opt_nota:
            ldn     rf                  ; reload -- xri above clobbered D
            xri     'a'
            lbnz    lso_optchar_next    ; unrecognized: silently ignore,
                                        ; just advance past it
            mov     rb, ls_amode
            ldi     1
            str     rb                  ; recognized 'a': set the flag

lso_optchar_next:
            inc     rf
            lbr     lso_optchar_loop

lso_is_path:
            ; append RD to ls_paths[ls_num_paths]
            mov     rf, ls_num_paths
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ls_num_paths (zero-
                                        ; extended)
            shl16   r8                  ; R8 = ls_num_paths * 2
            mov     rb, ls_paths
            add16   rb, r8              ; RB = &ls_paths[ls_num_paths]
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rf, ls_num_paths
            ldn     rf
            adi     1
            str     rf

lso_next:
            mov     rf, ls_scan_i
            ldn     rf
            adi     1
            str     rf
            lbr     lso_loop

lso_done:
            rtn

ls_resolve:
            ; --- read COLUMNS from the environment, once, here -- the
            ; one point every argv-parsing path above converges
            ; through (ls_scan_options' own 0/1-path fallthroughs, and
            ; the 1-path ls_patharg capture just above), and safely
            ; past every use of the entry RA/RC this program still
            ; needs (env_getenv/env_parse_uint's own broad clobber
            ; footprint includes both). Falls back to LS_SCREEN_COLS
            ; (ls_screen_cols' own compile-time initial value) if
            ; COLUMNS is unset, non-numeric, or parses to 0.
            mov     rf, ls_columns_name
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    ls_have_columns
            glo     rf
            lbz     ls_resolve_body     ; not set: keep the default

ls_have_columns:
            call    env_parse_uint      ; RD = parsed value
            ghi     rd
            lbnz    ls_columns_set
            glo     rd
            lbz     ls_resolve_body     ; parsed to 0: keep the default

ls_columns_set:
            mov     rb, ls_screen_cols
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

ls_resolve_body:
            mov     rf, ls_num_paths
            ldn     rf
            smi     2
            lbdf    ls_multi_stat       ; 2+ paths: new multi-stat mode

            mov     rf, ls_patharg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_patharg
            glo     rd
            lbnz    ls_have_patharg
            ghi     rd
            lbnz    ls_have_patharg
            lbr     ls_open             ; no path arg -- list current dir

ls_have_patharg:
            ; check is_glob first (2026-07-27) -- see the file header
            ; for why a glob routes into ls_multi_stat's own per-match
            ; K_STAT+ls_add_entry body instead of the literal
            ; K_PATH_RESOLVE-and-maybe-list-a-directory logic below.
            mov     rf, rd
            call    is_glob
            lbdf    ls_resolve_go       ; DF=1: not a glob -- proceed
                                        ; exactly as before (RD still
                                        ; = ls_patharg, untouched by
                                        ; is_glob -- its own header
                                        ; documents "Modifies: RF, D"
                                        ; only, confirmed not assumed)

            ; --- is a glob: glob_init ---
            mov     rf, ls_patharg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_patharg (reload --
                                        ; is_glob advanced RF through
                                        ; it above)
            mov     rf, rd
            mov     rd, ls_glob_ctx
            call    glob_init
            lbdf    ls_not_found        ; bad prefix path -- same
                                        ; message as any other bad path

            call    ls_init_collect

            mov     rf, ls_glob_found
            ldi     0
            str     rf

ls_single_glob_loop:
            mov     rd, ls_glob_ctx
            call    glob_next
            lbdf    ls_single_glob_done ; exhausted

            ; BUG FIX (caught in review, before ever assembling): RF
            ; holds glob_next's own returned match pointer at this
            ; point -- "mov rf, ls_glob_found" below would silently
            ; overwrite it with ls_glob_found's OWN address before
            ; ls_stat_and_add ever got a chance to read it. Stash it
            ; in R9 first (free at this point), restore right before
            ; the call.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, ls_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    ls_stat_and_add     ; DF=1: out of RAM
            lbdf    ls_collect_done
            lbr     ls_single_glob_loop

ls_single_glob_done:
            mov     rf, ls_glob_found
            ldn     rf
            lbnz    ls_collect_done     ; had at least one match: done
                                        ; (sort+print handles ls_any_
                                        ; error at exit time)

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded pattern
            mov     rf, ls_patharg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_patharg (re-derived)

ls_resolve_go:
            mov     rf, rd              ; RF = path string
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, DF = 0/1
            lbdf    ls_not_found

            ldn     rf
            lbz     ls_use_cluster      ; empty final component: the
                                        ; resolved parent cluster IS
                                        ; the target already

            mov     rb, ls_argptr2
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            call    K_DIR_OPEN          ; RD = parent cluster still

ls_find_loop:
            mov     rf, ls_scratch
            call    K_DIR_READ
            lbdf    ls_not_found        ; end of directory: no match

            mov     rf, ls_argptr2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ls_scratch
            call    f_strcmp
            lbnz    ls_find_loop        ; no match: keep looking

            mov     rf, ls_scratch
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     ls_single_file      ; a matching FILE (not a
                                        ; directory) just shows its
                                        ; own entry line and exits

            mov     rf, ls_scratch
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd

ls_use_cluster:
            mov     rb, ls_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

ls_open:
            mov     rf, ls_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    K_DIR_OPEN

            call    ls_init_collect     ; falls through into the
                                        ; collect loop below

;------------------------------------------------------------------
; Collect loop: K_DIR_READ each entry, hand it to ls_add_entry (which
; copies the fields we need into a fixed-size struct, records it in
; the pointer table, and advances/caps at LS_MAX_ENTRIES -- see its
; own header below).
;------------------------------------------------------------------
ls_collect_loop:
            mov     rf, ls_scratch
            call    K_DIR_READ
            lbdf    ls_collect_done     ; end of directory

            ; skip hidden entries unless -a is active (2026-07-22) --
            ; this loop is only ever reached via ls_open's own bare
            ; directory-scan path, never ls_single_file/ls_multi_stat's
            ; explicit-reference paths, so this filter can't accidentally
            ; hide an explicitly-named/glob-matched hidden entry
            mov     rf, ls_amode
            ldn     rf
            lbnz    ls_collect_add      ; -a active: don't filter

            mov     rf, ls_scratch
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_HIDDEN
            lbnz    ls_collect_loop     ; hidden, -a not active: skip

ls_collect_add:
            call    ls_add_entry        ; DF=1: out of RAM, stop
                                        ; collecting entirely
            lbdf    ls_collect_done
            lbr     ls_collect_loop

;------------------------------------------------------------------
; ls_init_collect: reset the entry-collection state (ls_count,
; ls_next_entry, ls_next_ptrslot) -- must run before the FIRST
; ls_add_entry call, regardless of which of the three paths
; (directory scan via ls_open above, a single-file match via
; ls_single_file, or ls_multi_stat) is about to populate the table.
; Args:    none
; Returns: nothing
;------------------------------------------------------------------
ls_init_collect:
            mov     rb, ls_count
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_count = 0

            mov     rf, ls_entries
            mov     rb, ls_next_entry
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ls_next_entry = ls_entries

            mov     rf, ls_ptrs
            mov     rb, ls_next_ptrslot
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ls_next_ptrslot = ls_ptrs
            rtn

;------------------------------------------------------------------
; ls_add_entry: given ls_scratch already filled (by K_DIR_READ or
; K_STAT -- same DIRENT_LEN field layout either way), copy the fields
; we need into a fixed-size struct at ls_next_entry, record that
; struct's address in the pointer table at ls_next_ptrslot, advance
; both, cap at LS_MAX_ENTRIES (extras are silently dropped rather than
; failing).
; Args:    none (reads ls_scratch)
; Returns: nothing
; Modifies: R7-RD (and D)
;------------------------------------------------------------------
ls_add_entry:
            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            ghi     rd
            lbnz    ls_add_entry_drop   ; count >= 256: drop this entry
            glo     rd
            smi     LS_MAX_ENTRIES
            lbdf    ls_add_entry_drop   ; count >= LS_MAX_ENTRIES: drop

            ; ---- compute this entry's real name length, bounded at
            ; LS_NAME_CAP (a safety bound -- DIRENT_NAME is always
            ; NUL-terminated within its own buffer, so this is never
            ; expected to actually trigger). Also detects a space
            ; anywhere in the name (2026-07-22, ls_hasquote) -- position
            ; doesn't matter, so this catches a trailing space (the
            ; user's own motivating case, otherwise invisible) the same
            ; as an embedded one. ----
            mov     rd, ls_scratch      ; RD = DIRENT_NAME (offset 0)
            ldi     0
            plo     r9                  ; R9.0 = length so far

            mov     rb, ls_hasquote
            ldi     0
            str     rb                  ; ls_hasquote = 0 (reset fresh
                                        ; for every entry)

ls_namelen_loop:
            ldn     rd
            lbz     ls_namelen_done     ; source NUL: done
            xri     ' '
            lbnz    ls_namelen_notspace
            mov     rb, ls_hasquote
            ldi     1
            str     rb

ls_namelen_notspace:
            glo     r9
            smi     LS_NAME_CAP
            lbdf    ls_namelen_done     ; cap reached: truncate here
            inc     rd
            glo     r9
            adi     1
            plo     r9
            lbr     ls_namelen_loop

ls_namelen_done:
            ; stash the length to memory NOW -- bump_alloc's own header
            ; documents R9 (along with R7/R8/RB/RD) as modified, so it
            ; cannot be trusted to survive the call below
            mov     rb, ls_namelen
            glo     r9
            str     rb

ls_alloc_name:
            mov     rf, ls_namelen
            ldn     rf
            adi     1
            plo     rc
            ldi     0
            phi     rc                  ; RC = len+1 (high byte always
                                        ; 0 -- len is capped at
                                        ; LS_NAME_CAP=127)
            call    bump_alloc          ; RF = new buffer, or 0 if it
                                        ; doesn't fit
            ghi     rf
            lbnz    ls_have_namebuf
            glo     rf
            lbnz    ls_have_namebuf

            ; BUG FIX (caught in review, before ever assembling): this
            ; used to be "lbr ls_collect_done" directly, safe back when
            ; this code ran inline (never via "call"). Now that
            ; ls_add_entry is a real callable routine, jumping away
            ; instead of returning would leave the return address
            ; ls_collect_loop/ls_single_file/ls_multi_stat's own "call
            ; ls_add_entry" just pushed sitting unpopped on the stack
            ; -- every later "rtn" would then pop the WRONG address.
            ; Signal "stop collecting entirely" via DF instead, and let
            ; each caller decide what that means for its own loop (see
            ; each call site).
            stc                         ; DF=1: out of RAM, caller
                                        ; should stop collecting
                                        ; entirely and go straight to
                                        ; sort/print (same graceful-cap
                                        ; shape as the LS_MAX_ENTRIES
                                        ; check above, just signaled
                                        ; instead of jumped-to directly)
            rtn

ls_have_namebuf:
            mov     rb, ls_curnamebuf
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ls_curnamebuf = new buffer

            ; ---- copy ls_namelen bytes from DIRENT_NAME into the new
            ; buffer and NUL-terminate ----
            mov     rd, ls_scratch      ; RD = source (DIRENT_NAME)
            mov     rf, ls_curnamebuf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = dest buffer address
            mov     rf, r8              ; RF = dest cursor

            ldi     0
            plo     r9                  ; R9.0 = bytes copied so far

ls_namecopy_loop:
            mov     rb, ls_namelen
            ldn     rb
            str     r2                  ; M(R2) = target length
            glo     r9
            sm                          ; D = copied - target, DF=1 if
                                        ; copied >= target
            lbdf    ls_namecopy_done    ; copied it all
            ldn     rd                  ; reload -- sm above clobbered D
            str     rf
            inc     rf
            inc     rd
            glo     r9
            adi     1
            plo     r9
            lbr     ls_namecopy_loop

ls_namecopy_done:
            ldi     0
            str     rf                  ; NUL-terminate

            ; ---- now populate the fixed-size entry struct -- fetched
            ; fresh here (rather than before the bump_alloc/copy work
            ; above) since bump_alloc's own clobber list would have
            ; forced stashing it to memory anyway ----
            mov     rf, ls_next_entry
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = dest entry struct address

            mov     rf, r8              ; RF = write cursor into struct

            mov     rd, ls_scratch
            add16   rd, DIRENT_ATTR
            ldn     rd                  ; D = attr byte
            str     rf
            inc     rf

            mov     rd, ls_scratch
            add16   rd, DIRENT_WRTDATE
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            inc     rf

            mov     rd, ls_scratch
            add16   rd, DIRENT_WRTTIME
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            inc     rf

            ; full 32-bit size (widened 2026-07-26, matching DIR/STAT --
            ; was low-word-only, "add16 rd, 2" skip removed)
            mov     rd, ls_scratch
            add16   rd, DIRENT_SIZE
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            inc     rf                  ; RF now at LSENT_NAMEPTR in dest

            mov     rd, ls_curnamebuf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; entry->nameptr = ls_curnamebuf
            inc     rf                  ; RF now at LSENT_NAMELEN in dest

            ; ---- compute this entry's DISPLAY length (real name
            ; length + 2 if it'll be single-quoted for containing a
            ; space + 1 if -F is active and this entry is a
            ; directory) -- precomputed here, once, so BOTH the
            ; column-width layout pass and the print-time padding
            ; calculation can just read it back rather than rescanning
            ; the name or re-checking -F/ATTR_DIR at print time. The
            ; REAL string length (ls_namelen) is left untouched --
            ; it's still needed as-is for the bump_alloc size and the
            ; name-copy loop's bound above, both already done by this
            ; point. ----
            mov     rd, ls_namelen
            ldn     rd
            plo     r9                  ; R9.0 = real name length

            mov     rb, ls_hasquote
            ldn     rb
            lbz     ladd_dlen_noquote
            glo     r9
            adi     2
            plo     r9
ladd_dlen_noquote:

            mov     rb, ls_fmode
            ldn     rb
            lbz     ladd_dlen_nof       ; -F not active: skip
            mov     rd, ls_scratch
            add16   rd, DIRENT_ATTR
            ldn     rd
            ani     ATTR_DIR
            lbz     ladd_dlen_nof       ; not a directory: skip
            glo     r9
            adi     1
            plo     r9
ladd_dlen_nof:
            glo     r9
            str     rf                  ; entry->namelen = display len
            inc     rf                  ; RF now at LSENT_QUOTE in dest

            mov     rd, ls_hasquote
            ldn     rd
            str     rf                  ; entry->quote = ls_hasquote

ls_store_ptr:
            mov     rf, ls_next_ptrslot
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = dest pointer-table slot

            mov     rf, r9
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; *slot = R8 (entry struct addr)

            mov     rf, ls_next_ptrslot
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +2 via two INCs (2026-08-01
                                        ; size-reduction pass, same
                                        ; reasoning as the LOADER_ARGS
                                        ; +2 above -- the next real use
                                        ; of RD is a fresh ghi/str, so
                                        ; DF isn't needed from here)
            inc     rd
            mov     rf, ls_next_ptrslot
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_next_ptrslot += 2

            mov     rf, ls_next_entry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, LSENT_LEN
            mov     rf, ls_next_entry
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_next_entry += LSENT_LEN

            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_count
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_count++

            clc                         ; DF=0: caller should keep
                                        ; collecting (explicit, not
                                        ; relying on whatever DF the
                                        ; add16 above happened to
                                        ; leave -- that's a 16-bit
                                        ; overflow carry, unrelated to
                                        ; "should I stop collecting")
            rtn

ls_add_entry_drop:
            ; BUG FIX (caught in review, before ever assembling): this
            ; used to be "lbr ls_collect_loop" from back when this code
            ; was inline inside that loop -- now that it's a separate
            ; callable routine, also called from ls_single_file/
            ; ls_multi_stat (neither of which ever did a K_DIR_OPEN),
            ; jumping back into ls_collect_loop here would have issued
            ; a K_DIR_READ against whatever directory happened to be
            ; open (or none), corrupting the collection. A plain
            ; return here has the same effect the old jump-back had
            ; from ls_collect_loop's own perspective -- "don't add
            ; this entry, go on to whatever's next" -- correctly for
            ; every caller, since each caller already loops on its
            ; own. Unreachable in practice today (LS_MAX_ENTRIES=255
            ; comfortably exceeds anything ls_single_file/
            ; ls_multi_stat can ever produce, capped by
            ; ARGV_MAX_ARGS=16), but wrong regardless.
            clc                         ; DF=0: caller should keep
                                        ; collecting -- dropping one
                                        ; entry for being over the cap
                                        ; isn't the fatal "stop
                                        ; entirely" case bump_alloc
                                        ; failure is
            rtn

;------------------------------------------------------------------
; ls_print_name: print one entry's display name -- single-quoted if
; LSENT_QUOTE is set (a space anywhere in the name, precomputed at
; collection time so this never needs to rescan), with a trailing "/"
; appended if -F is active and the entry is a directory (outside the
; closing quote, e.g. 'my dir'/). Shared by both the columnar and -l
; print paths so the quote/-F logic exists in exactly one place.
;
; Reads ls_curentry (entry struct address) / ls_curname (name pointer)
; from memory rather than taking register args -- neither R8 nor RF is
; confirmed to survive a K_MSG/K_INMSG call (gotcha #8/#10, only R9
; has ever been confirmed safe across these), so both are reloaded
; fresh from memory at each point they're needed, matching this file's
; own established discipline (see ls_pad_loop's own header comment for
; the same reasoning). Callers must set both before calling.
;
; Args:    none (reads ls_curentry/ls_curname)
; Returns: nothing
; Modifies: RD, RF (and D)
;------------------------------------------------------------------
ls_print_name:
            mov     rd, ls_curentry
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = entry struct address
            add16   rf, LSENT_QUOTE
            ldn     rf                  ; D = quote flag
            lbz     lpn_open_done

            call    K_INMSG
            db      "'",0

lpn_open_done:
            mov     rf, ls_curname
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = name address
            call    K_MSG

            mov     rd, ls_curentry
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = entry struct address
            add16   rf, LSENT_QUOTE
            ldn     rf                  ; D = quote flag
            lbz     lpn_close_done

            call    K_INMSG
            db      "'",0

lpn_close_done:
            mov     rf, ls_fmode
            ldn     rf
            lbz     lpn_done            ; -F not active: no suffix

            mov     rd, ls_curentry
            lda     rd
            phi     rf
            ldn     rd
            plo     rf                  ; RF = entry struct address
            add16   rf, LSENT_ATTR
            ldn     rf                  ; D = attr byte
            ani     ATTR_DIR
            lbz     lpn_done            ; not a directory: no suffix

            call    K_INMSG
            db      "/",0

lpn_done:
            rtn

;------------------------------------------------------------------
; ls_stat_and_add: K_STAT a single path and add it via ls_add_entry,
; or print "Not found: "+path and set ls_any_error on failure. Shared
; by ls_multi_stat's own per-path loop and the single-path glob loop
; in ls_resolve_body above (factored out 2026-07-27, replacing what
; used to be inline in ls_multi_stat only).
; Args:    RF = path
; Returns: DF = 0 (keep collecting) or DF = 1 (ls_add_entry ran out of
;          RAM -- caller should stop collecting entirely, same
;          convention ls_add_entry itself uses); a K_STAT failure
;          (path not found) always returns DF = 0, since that's a
;          per-item error, not a "stop everything" signal
; Modifies: everything (calls K_STAT/ls_add_entry)
;------------------------------------------------------------------
ls_stat_and_add:
            mov     r9, rf              ; R9 = path (RF is about to be
                                        ; reused for K_STAT's own args)
            mov     rf, ls_cur_path
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; ls_cur_path = path (for the
                                        ; possible error message)

            mov     rf, r9              ; RF = path string
            mov     rd, ls_scratch      ; RD = result buffer
            call    K_STAT              ; DF = 0/1
            lbdf    lsa_not_found

            call    ls_add_entry        ; DF = 0/1, propagated to caller
            rtn

lsa_not_found:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, ls_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, ls_any_error
            ldi     $FF
            str     rf
            clc                         ; DF=0: not a "stop collecting"
                                        ; condition, just this one item
            rtn

;------------------------------------------------------------------
; ls_single_file: the one path argument resolved to a FILE (not a
; directory) -- ls_scratch is already filled by ls_find_loop's own
; successful match, so this just adds that one entry and jumps
; straight to sort+print (which produces a single-line result, same
; as any other one-entry collection).
;------------------------------------------------------------------
ls_single_file:
            call    ls_init_collect
            call    ls_add_entry        ; DF result deliberately
                                        ; unchecked -- only one entry
                                        ; is ever added here, and the
                                        ; next step is ls_collect_done
                                        ; either way
            lbr     ls_collect_done

;------------------------------------------------------------------
; ls_multi_stat: two or more path arguments -- each one is checked via
; is_glob (2026-07-27) and either K_STAT'd directly (a literal name,
; via the shared ls_stat_and_add helper above) or expanded via
; glob_init/glob_next, one match at a time, into that same helper. A
; pattern matching zero files falls back to the literal, unexpanded
; text. Every match/literal is added to the collection via
; ls_add_entry, same as a directory-scan entry (works for both
; columnar and -l output with no changes to either print routine,
; since attribute byte is exactly what -l mode's own per-entry logic
; already branches on). A bad path/argument prints its own error and
; the rest still run; ls_any_error drives the final exit code.
;------------------------------------------------------------------
ls_multi_stat:
            call    ls_init_collect

            mov     rf, ls_multi_i
            ldi     0
            str     rf

lms_loop:
            mov     rf, ls_multi_i
            ldn     rf
            str     r2                  ; M(X) = ls_multi_i
            mov     rf, ls_num_paths
            ldn     rf                  ; D = ls_num_paths
            xor                         ; D = ls_num_paths XOR ls_multi_i
            lbz     lms_done            ; ls_multi_i == ls_num_paths: done

            ; RD = ls_paths[ls_multi_i]
            mov     rf, ls_multi_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = ls_multi_i (zero-extended)
            shl16   r8                  ; R8 = ls_multi_i * 2
            mov     rf, ls_paths
            add16   rf, r8              ; RF = &ls_paths[ls_multi_i]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_paths[ls_multi_i]

            mov     rf, ls_cur_path
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_cur_path = ls_paths[ls_multi_i]

            mov     rf, rd
            call    is_glob
            lbdf    lms_literal         ; DF=1: not a glob

            ; --- is a glob (2026-07-27): glob_init ---
            mov     rf, ls_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, ls_glob_ctx
            call    glob_init
            lbdf    lms_bad_path        ; bad prefix path: this path
                                        ; entry's own error

            mov     rf, ls_glob_found
            ldi     0
            str     rf

lms_glob_loop:
            mov     rd, ls_glob_ctx
            call    glob_next
            lbdf    lms_glob_done       ; exhausted

            mov     r9, rf              ; R9 = matched full path (RF
                                        ; is about to be reused to set
                                        ; the found flag)

            mov     rf, ls_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    ls_stat_and_add     ; DF=1: out of RAM
            lbdf    ls_collect_done
            lbr     lms_glob_loop

lms_glob_done:
            mov     rf, ls_glob_found
            ldn     rf
            lbnz    lms_next            ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, ls_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ls_stat_and_add
            lbdf    ls_collect_done
            lbr     lms_next

lms_bad_path:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, ls_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, ls_any_error
            ldi     $FF
            str     rf
            lbr     lms_next

lms_literal:
            mov     rf, ls_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    ls_stat_and_add
            lbdf    ls_collect_done

lms_next:
            mov     rf, ls_multi_i
            ldn     rf
            adi     1
            str     rf
            lbr     lms_loop

lms_done:
            lbr     ls_collect_done

;------------------------------------------------------------------
; Insertion sort ls_ptrs[0 .. ls_count-1] by name (ls_namecmp).
; Standard "m = i, shift while ls_ptrs[m-1] > key" shape, using m
; (not the more usual j = i-1) specifically to avoid ever needing a
; negative index on this hardware.
;------------------------------------------------------------------
ls_collect_done:
            mov     rb, ls_sort_i
            ldi     0
            str     rb
            inc     rb
            ldi     1
            str     rb                  ; ls_sort_i = 1

ls_sort_outer:
            mov     rf, ls_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ls_count
            mov     rf, ls_sort_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_sort_i

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ls_sort_done        ; ls_sort_i >= ls_count: done

            ; key = ls_ptrs[ls_sort_i]
            shl16   rd                  ; RD = ls_sort_i * 2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[ls_sort_i]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = key (entry struct addr)
            mov     rb, ls_sort_key
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb

            mov     rf, ls_sort_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rb, ls_sort_m
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ls_sort_m = ls_sort_i

ls_sort_inner:
            mov     rf, ls_sort_m
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_sort_m
            ghi     rd
            lbnz    ls_sort_inner_go    ; high byte nonzero: m > 0
            glo     rd
            lbz     ls_sort_inner_place ; m == 0 exactly: stop shifting
                                        ; (falls through to ls_sort_inner_go
                                        ; otherwise -- low byte nonzero)
ls_sort_inner_go:
            mov     rf, ls_sort_m
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = m
            dec     rd                  ; RD = m-1
            shl16   rd                  ; RD = (m-1)*2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[m-1]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ls_ptrs[m-1] (entry addr)

            mov     rf, r8
            add16   rf, LSENT_NAMEPTR   ; RF = &(ls_ptrs[m-1]->nameptr)
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = ls_ptrs[m-1]'s real name
                                        ; pointer (dereferenced)

            mov     rd, ls_sort_key
            lda     rd
            phi     r9
            ldn     rd
            plo     r9                  ; R9 = key (entry addr)
            mov     rf, r9
            add16   rf, LSENT_NAMEPTR   ; RF = &(key->nameptr)
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = key's real name pointer
                                        ; (dereferenced)

            mov     rf, r7              ; RF = ls_ptrs[m-1]'s name
            mov     rd, r9              ; RD = key's name
            call    ls_namecmp          ; DF=1 if ls_ptrs[m-1]->name >
                                        ; key->name
            lbnf    ls_sort_inner_place ; not greater: stop shifting

            ; shift: ls_ptrs[m] = ls_ptrs[m-1] (still held in R8), m--
            mov     rf, ls_sort_m
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = m
            shl16   rd                  ; RD = m*2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[m]
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ls_ptrs[m] = ls_ptrs[m-1]

            mov     rf, ls_sort_m
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd                  ; -1 (2026-08-01 size-reduction pass: DEC is 1 byte vs SUB16's 8-byte macro -- DF not needed here)
            mov     rf, ls_sort_m
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_sort_m--

            lbr     ls_sort_inner

ls_sort_inner_place:
            mov     rf, ls_sort_m
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = m
            shl16   rd
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[m]
            mov     rd, ls_sort_key
            lda     rd
            phi     r8
            ldn     rd
            plo     r8                  ; R8 = key
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ls_ptrs[m] = key

            mov     rf, ls_sort_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_sort_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_sort_i++

            lbr     ls_sort_outer

ls_sort_done:
            mov     rf, ls_longmode
            ldn     rf
            lbnz    ls_print_long
            lbr     ls_print_columnar

;------------------------------------------------------------------
; Columnar (default) output: column-major fill order. Column widths
; are computed PER COLUMN (2026-07-19 redesign, matching real
; BSD/GNU ls -- replaces an earlier design that used one GLOBAL
; width, the longest name in the whole directory + 2, for every
; column -- meaning a single unusually long name forced every column
; that wide, often collapsing the whole listing to 1 column even
; when most names were short). Candidate column counts are tried
; from min(ls_count, LS_MAX_COLS) down to 1; for each candidate,
; each column's own width is the longest name landing in THAT column
; (column-major fill: column c holds indices [c*num_rows,
; (c+1)*num_rows)) plus 2 for spacing, and the first (widest)
; candidate whose summed column widths fit LS_SCREEN_COLS wins.
; Candidate 1 is always accepted even if it doesn't fit -- nowhere
; narrower to try, same overflow behavior the old design already had
; for a single name wider than the screen. Column base offsets
; (ls_colbase[c] = c*num_rows) fall out of the same per-column scan
; for free, exactly as the old design's own separate pass did.
;------------------------------------------------------------------
ls_print_columnar:
            ; starting candidate = min(ls_count, LS_MAX_COLS), clamped
            ; to >= 1 (ls_count == 0 is possible for an empty
            ; directory -- degenerates harmlessly below: num_rows
            ; comes out 0, the single trial column has no rows to
            ; scan, and the row-print loop later does nothing)
            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            ghi     rd
            lbnz    ls_col0_clamp       ; high byte nonzero: > 255,
                                        ; definitely > LS_MAX_COLS
            glo     rd
            smi     LS_MAX_COLS
            lbnf    ls_col0_ok          ; ls_count <= LS_MAX_COLS
ls_col0_clamp:
            ldi     LS_MAX_COLS
            plo     rd
            ldi     0
            phi     rd
ls_col0_ok:
            glo     rd
            lbnz    ls_trycols_init
            ldi     1
            plo     rd                  ; candidate == 0: force to 1

ls_trycols_init:
            mov     rb, ls_trycols
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ls_trycols = starting
                                        ; candidate (high byte always
                                        ; 0 from here on -- clamped to
                                        ; <= LS_MAX_COLS=32 and only
                                        ; ever decremented while > 1)

ls_trycols_loop:
            ; num_rows = ceil(ls_count / ls_trycols)
            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            mov     rf, ls_trycols
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = candidate
            add16   rd, rc
            dec     rd                  ; RD = ls_count+candidate-1
            call    ls_div              ; RD = RD / RC (RC preserved)
            mov     rb, ls_numrows
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ls_numrows = num_rows

            mov     rb, ls_totalwidth
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_totalwidth = 0

            mov     rb, ls_colbase_i
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_colbase_i = 0 (column idx)

            ldi     0
            phi     r8
            plo     r8                  ; R8 = running column base
                                        ; (col * num_rows), starts at 0

ls_trycol_loop:
            mov     rf, ls_colbase_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = colbase_i
            mov     rf, ls_trycols
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = candidate

            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    ls_trycols_done     ; DF=1: colbase_i >= candidate
                                        ; -- every column scanned, this
                                        ; candidate's totalwidth final

            shl16   rd                  ; RD = colbase_i * 2
            mov     rf, ls_colbase
            add16   rf, rd              ; RF = &ls_colbase[colbase_i]
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ls_colbase[colbase_i] = R8

            mov     rb, ls_colmax
            ldi     0
            str     rb                  ; ls_colmax = 0

            mov     rb, ls_colrow
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_colrow = 0

ls_colrow_loop:
            mov     rf, ls_colrow
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = colrow
            mov     rf, ls_numrows
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = num_rows

            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    ls_colrow_done      ; DF=1: colrow >= num_rows

            glo     r8
            str     r2
            glo     rd
            add
            plo     r9
            ghi     r8
            str     r2
            ghi     rd
            adc
            phi     r9                  ; R9 = idx (col base + colrow)

            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            glo     rd
            str     r2
            glo     r9
            sm
            ghi     rd
            str     r2
            ghi     r9
            smb
            lbdf    ls_colrow_next      ; DF=1: idx >= ls_count --
                                        ; short last column, skip

            shl16   r9                  ; R9 = idx * 2
            mov     rf, ls_ptrs
            add16   rf, r9              ; RF = &ls_ptrs[idx]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = entry struct address
            add16   rd, LSENT_NAMELEN
            mov     rf, rd
            ldn     rf                  ; D = this entry's namelen
            plo     r9                  ; stash it (R9 free -- idx no
                                        ; longer needed)

            mov     rb, ls_colmax
            ldn     rb
            str     r2                  ; M(R2) = colmax
            glo     r9                  ; D = namelen
            sm                          ; DF=1 iff namelen >= colmax
            lbnf    ls_colrow_next      ; smaller: leave colmax alone
            mov     rb, ls_colmax
            glo     r9
            str     rb                  ; colmax = namelen

ls_colrow_next:
            mov     rf, ls_colrow
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_colrow
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; colrow++
            lbr     ls_colrow_loop

ls_colrow_done:
            mov     rf, ls_colmax
            ldn     rf
            adi     2
            plo     r9                  ; R9.0 = col_width (colmax is
                                        ; at most LS_NAME_CAP=127, +2
                                        ; still fits a byte)

            mov     rf, ls_colbase_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = colbase_i
            mov     rf, ls_colwidths
            add16   rf, rd              ; RF = &ls_colwidths[colbase_i]
            glo     r9
            str     rf                  ; ls_colwidths[colbase_i] =
                                        ; col_width

            mov     rf, ls_totalwidth
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = totalwidth
            glo     r9
            str     r2
            glo     rd
            add
            plo     rd
            ghi     rd
            str     r2
            ldi     0
            adc
            phi     rd                  ; RD += col_width (zero-
                                        ; extended)
            mov     rf, ls_totalwidth
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; totalwidth updated

            mov     rf, ls_numrows
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = num_rows
            glo     r8
            str     r2
            glo     r9
            add
            plo     r8
            ghi     r8
            str     r2
            ghi     r9
            adc
            phi     r8                  ; R8 += num_rows

            mov     rf, ls_colbase_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_colbase_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; colbase_i++

            lbr     ls_trycol_loop

ls_trycols_done:
            mov     rf, ls_trycols
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = candidate (high byte
                                        ; provably 0, see the comment
                                        ; at ls_trycols_init)
            glo     rd
            smi     1
            lbz     ls_trycols_success  ; candidate == 1: forced
                                        ; accept, nowhere narrower

            mov     rf, ls_totalwidth
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = totalwidth
            glo     rd
            str     r2
            mov     rf, ls_screen_cols
            inc     rf
            ldn     rf                  ; D = ls_screen_cols' low byte
                                        ; (big-endian storage: high
                                        ; byte at the base address,
                                        ; low byte at +1)
            sm
            ghi     rd
            str     r2
            mov     rf, ls_screen_cols
            ldn     rf                  ; D = ls_screen_cols' high byte
            smb
            lbdf    ls_trycols_success  ; DF=1: ls_screen_cols >=
                                        ; totalwidth, fits

            ; doesn't fit -- try one fewer column
            mov     rf, ls_trycols
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd                  ; -1 (2026-08-01 size-reduction pass: DEC is 1 byte vs SUB16's 8-byte macro -- DF not needed here)
            mov     rf, ls_trycols
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; candidate--
            lbr     ls_trycols_loop

ls_trycols_success:
            mov     rf, ls_numcols
            mov     rd, ls_trycols
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; ls_numcols = candidate --
                                        ; ls_colbase[]/ls_colwidths[]
                                        ; are already fully populated
                                        ; for this exact candidate by
                                        ; the scan above, nothing left
                                        ; to compute before printing

ls_colbase_done:
            ; ---- print rows ----
            mov     rb, ls_row
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_row = 0

ls_row_loop:
            mov     rf, ls_row
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_row
            mov     rf, ls_numrows
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = num_rows

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ls_print_done       ; ls_row >= num_rows: all done

            mov     rb, ls_col
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_col = 0

ls_col_loop:
            mov     rf, ls_col
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_col
            mov     rf, ls_numcols
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = num_cols

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ls_row_end          ; ls_col >= num_cols: end of row

            ; idx = ls_colbase[ls_col] + ls_row
            shl16   rd                  ; RD = ls_col * 2
            mov     rf, ls_colbase
            add16   rf, rd              ; RF = &ls_colbase[ls_col]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_colbase[ls_col]

            mov     rf, ls_row
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ls_row
            glo     rd
            str     r2
            glo     r8
            add
            plo     rd
            ghi     rd
            str     r2
            ghi     r8
            adc
            phi     rd                  ; RD = idx (colbase[col] + row)

            mov     rf, ls_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ls_count

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ls_col_next         ; idx >= ls_count: nothing here,
                                        ; skip printing (leaves a gap,
                                        ; matching the last, short row)

            ; print ls_ptrs[idx]->name (quoted/-F suffixed as
            ; appropriate -- see ls_print_name), padded to col_width
            shl16   rd                  ; RD = idx * 2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[idx]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = entry struct address

            mov     rb, ls_curentry
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb                  ; ls_curentry = entry struct
                                        ; address (ls_print_name's own
                                        ; memory-argument convention --
                                        ; see its header comment)

            mov     rf, r8
            add16   rf, LSENT_NAMEPTR   ; RF = &(entry->nameptr)
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = entry's real name pointer
                                        ; (dereferenced)

            mov     rb, ls_curname
            ghi     r9
            str     rb
            inc     rb
            glo     r9
            str     rb                  ; ls_curname = name address --
                                        ; stashed to memory since R8/RF
                                        ; are not confirmed to survive
                                        ; the K_MSG/K_INMSG calls below
                                        ; (gotcha #8/#10: only R9 has
                                        ; ever been confirmed safe
                                        ; across these)

            call    ls_print_name

            ; pad with spaces to this column's own width: length comes
            ; from entry->LSENT_NAMELEN, the precomputed DISPLAY length
            ; (already including quote/-F adjustments -- see
            ; ls_add_entry) rather than a live rescan of the raw name,
            ; which would under-pad once quoting/-F print characters
            ; that were never part of the raw name text at all.
            mov     rf, ls_curentry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = entry struct address
            add16   rd, LSENT_NAMELEN
            mov     rf, rd
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = display length -- R9 IS
                                        ; confirmed to survive K_INMSG
                                        ; (gotcha #8, and the redirect
                                        ; dispatcher's own explicit R9
                                        ; preservation), so it's safe to
                                        ; carry across ls_pad_loop's own
                                        ; call below
ls_pad_loop:
            ; col_width is looked up fresh from ls_colwidths[ls_col]
            ; every iteration (2026-07-19: per-column widths, not one
            ; global width -- see the layout redesign above) rather
            ; than held in a register, since R8 is not confirmed safe
            ; across the K_INMSG call below.
            mov     rf, ls_col
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_col
            mov     rf, ls_colwidths
            add16   rf, rd              ; RF = &ls_colwidths[ls_col]
                                        ; (1 byte/entry, no shl16 needed)
            ldn     rf                  ; D = col_width (this column's
                                        ; own real width)
            str     r2                  ; M(R2) = col_width
            glo     r9                  ; D = name_len
            sm                          ; D = name_len - col_width,
                                        ; DF=1 if name_len >= col_width
            lbdf    ls_col_next         ; no more padding needed
            call    K_INMSG
            db      " ",0
            glo     r9
            adi     1
            plo     r9
            lbr     ls_pad_loop

ls_col_next:
            mov     rf, ls_col
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_col
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_col++

            lbr     ls_col_loop

ls_row_end:
            call    K_INMSG
            db      13,10,0

            mov     rf, ls_row
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_row
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_row++

            lbr     ls_row_loop

;------------------------------------------------------------------
; -l output: one entry per line, type/size/date/time/name.
;------------------------------------------------------------------
ls_print_long:
            mov     rb, ls_row          ; reuse ls_row as the entry index
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb

ls_long_loop:
            mov     rf, ls_row
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = index
            mov     rf, ls_count
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = ls_count

            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    ls_print_done       ; index >= ls_count: done

            shl16   rd                  ; RD = index * 2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[index]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = entry struct address
            mov     rb, ls_curentry
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb

            ; type indicator
            mov     rf, r8
            add16   rf, LSENT_ATTR
            ldn     rf                  ; D = attr byte
            ani     ATTR_DIR
            lbz     ls_long_file
            call    K_INMSG
            db      "d  ",0
            lbr     ls_long_size

ls_long_file:
            call    K_INMSG
            db      "-  ",0

ls_long_size:
            ; right-justified 5-column human-readable size (2026-07-26:
            ; replaces the old plain 0-65535 f_uintout call, now that
            ; LSENT_SIZE is a full 32-bit field -- see ls_fmt_human's own
            ; header comment for the K/M/G formatting rules). Output is
            ; always <=4 characters, so the existing 5-space right-
            ; justify padding infrastructure below needs no changes.
            mov     rf, ls_curentry
            lda     rf
            phi     r7
            ldn     rf
            plo     r7                  ; R7 = entry struct address
                                        ; (pure read pointer, not one of
                                        ; ls_fmt_human's own arguments)
            mov     rf, r7
            add16   rf, LSENT_SIZE
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = 32-bit size (RD=hi
                                        ; word, R8=lo word -- matches
                                        ; ls_fmt_human's own Args)
            mov     rf, ls_sizebuf
            call    ls_fmt_human        ; fills ls_sizebuf, null-terminated

            mov     rf, ls_sizebuf
            ldi     0
            plo     rc
            ldi     0
            phi     rc                  ; BUG FIX (hardware-found,
                                        ; 2026-07-20): RC's HIGH byte
                                        ; was never cleared here, only
                                        ; the low byte -- whatever
                                        ; garbage an earlier call left
                                        ; in RC.hi (f_uintout/K_MSG/
                                        ; K_INMSG are none of them
                                        ; confirmed to preserve RC)
                                        ; then fed straight into the
                                        ; "ls_spaces5 + rc" address
                                        ; computation below, computing
                                        ; a wildly wrong pointer and
                                        ; printing little or no real
                                        ; padding -- explains the
                                        ; observed "sizes not right-
                                        ; justified" symptom exactly.
ls_long_count_loop:
            ldn     rf
            lbz     ls_long_count_done
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     ls_long_count_loop
ls_long_count_done:
            mov     rf, ls_spaces5
            add16   rf, rc
            call    K_MSG

            mov     rf, ls_sizebuf
            call    K_MSG

            call    K_INMSG
            db      "  ",0

            ; ---- unpack last-write date (identical bit layout/shift
            ; sequence to dir.asm's own already-hardware-confirmed
            ; code, copied rather than shared -- see this project's
            ; established DIR/STAT precedent for small helpers) ----
            mov     rf, ls_curentry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, LSENT_DATE
            lda     rd
            phi     r8
            ldn     rd
            plo     r8                  ; R8 = packed date
            mov     rd, r8

            mov     rf, ls_wr_day
            glo     rd
            ani     $1F
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            mov     rf, ls_wr_month
            glo     rd
            ani     $0F
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            add16   rd, 1980
            mov     rf, ls_wr_year
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; ---- unpack last-write time ----
            mov     rf, ls_curentry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, LSENT_TIME
            lda     rd
            phi     r8
            ldn     rd
            plo     r8                  ; R8 = packed time
            mov     rd, r8

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            mov     rf, ls_wr_minute
            glo     rd
            ani     $3F
            str     rf

            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            mov     rf, ls_wr_hour
            glo     rd
            str     rf

            mov     rf, ls_wr_month
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    ls_print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, ls_wr_day
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    ls_print2digit

            call    K_INMSG
            db      "/",0

            mov     rf, ls_wr_year
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ls_sizebuf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ls_sizebuf
            call    K_MSG

            call    K_INMSG
            db      " ",0

            mov     rf, ls_wr_hour
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    ls_print2digit

            call    K_INMSG
            db      ":",0

            mov     rf, ls_wr_minute
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            call    ls_print2digit

            call    K_INMSG
            db      "  ",0

            mov     rf, ls_curentry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = entry struct address
            add16   rd, LSENT_NAMEPTR   ; RD = &(entry->nameptr)
            mov     rf, rd
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = entry's real name pointer

            mov     rb, ls_curname
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ls_curname = name address
                                        ; (ls_curentry is already set
                                        ; earlier in this loop --
                                        ; ls_print_name's own
                                        ; memory-argument convention)

            call    ls_print_name

            call    K_INMSG
            db      13,10,0

            mov     rf, ls_row
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd                  ; +1 (2026-08-01 size-reduction pass: INC is 1 byte, no D-clobber, vs ADD16's 8-byte macro -- DF not needed here)
            mov     rf, ls_row
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            lbr     ls_long_loop

ls_print_done:
            mov     rf, ls_any_error
            ldn     rf
            lbnz    ls_exit_err

            ldi     0                   ; exit code 0 = success
            rtn

ls_exit_err:
            ldi     1
            rtn

ls_not_found:
            call    K_INMSG
            db      "Directory not found.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; ls_namecmp: compare two null-terminated strings byte by byte.
; Args:    RF = name1, RD = name2 (both consumed/advanced)
; Returns: DF = 1 if name1 > name2, DF = 0 if name1 <= name2
; Modifies: RF, RD, D, DF only.
;------------------------------------------------------------------
ls_namecmp:
lnc_loop:
            ldn     rd                  ; D = *name2
            str     r2                  ; M(R2) = *name2
            ldn     rf                  ; D = *name1 (reload -- ldn rd
                                        ; above overwrote D)
            sm                          ; D = *name1 - *name2, DF=1 if
                                        ; no borrow (name1 byte >= name2)
            lbnz    lnc_diff            ; bytes differ: DF already holds
                                        ; the correct ordering answer
            ldn     rf
            lbz     lnc_equal           ; both hit NUL simultaneously
            inc     rf
            inc     rd
            lbr     lnc_loop

lnc_diff:
            rtn

lnc_equal:
            clc
            rtn

;------------------------------------------------------------------
; ls_div: unsigned 16-bit integer division via repeated subtraction.
; Fine for this program's magnitudes (screen width / name lengths /
; entry counts, never more than a few hundred) -- avoids depending on
; the BIOS's f_div16, which (like f_hexout4 before it) has zero prior
; callers anywhere in this codebase and so is an unconfirmed contract.
; Args:    RD = dividend, RC = divisor (must be nonzero)
; Returns: RD = quotient (remainder discarded)
; Modifies: RD, R9, D, DF.
;------------------------------------------------------------------
ls_div:
            ldi     0
            phi     r9
            plo     r9                  ; R9 = quotient, starts at 0

ls_div_loop:
            glo     rc
            str     r2
            glo     rd
            sm
            ghi     rc
            str     r2
            ghi     rd
            smb
            lbnf    ls_div_done         ; RD < RC: done

            sub16   rd, rc
            inc     r9                  ; +1 (2026-08-01 size-reduction pass, same reasoning)
            lbr     ls_div_loop

ls_div_done:
            mov     rd, r9
            rtn

;------------------------------------------------------------------
; ls_print2digit: print RD (0-99) as two zero-padded decimal digits.
; Copied from dir.asm's own print2digit (same established DIR/STAT
; precedent as the date-unpacking code above).
; Args:   RD = value (0-99)
;------------------------------------------------------------------
ls_print2digit:
            glo     rd
            smi     10
            lbdf    lp2d_use_uintout

            glo     rd
            adi     '0'
            plo     rc
            mov     rf, ls_digitbuf
            ldi     '0'
            str     rf
            inc     rf
            glo     rc
            str     rf
            inc     rf
            ldi     0
            str     rf
            lbr     lp2d_print

lp2d_use_uintout:
            mov     rf, ls_digitbuf
            call    f_uintout
            ldi     0
            str     rf

lp2d_print:
            mov     rf, ls_digitbuf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; ls_pairshr10: shift a 32-bit register pair RD:R8 (RD=hi word,
; R8=lo word) right by 10 bits -- 10 repeated single-bit pair-shifts
; via SHR16/SHRC16 (SHR16 rd shifts RD right by 1, leaving the bit
; that fell off in DF; SHRC16 r8 then shifts R8 right by 1 USING that
; DF as its own carry-in -- together, one true 32-bit right-shift-by-
; one of the pair). No byte-reassignment shortcut needed for a shift
; count this small -- matches this file's own established convention
; (dir.asm/stat.asm's date-unpacking code, and ls_wr_year's own
; shr16-repeated-inline style elsewhere in this file) of just
; repeating the shift macro rather than reaching for a cleverer
; technique when the count is a small, fixed constant.
;
; Used to compute each candidate unit's own whole part directly:
; N>>10 for K, and (2026-07-26: no longer used for remainder
; reduction -- see ls_fmt_human's own header for why an earlier,
; reduced-precision approach was replaced with exact arithmetic).
;
; Args:    RD:R8 = value
; Returns: RD:R8 = value >> 10
; Modifies: RD, R8 (and D, DF)
;------------------------------------------------------------------
ls_pairshr10:
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            shr16   rd
            shrc16  r8
            rtn

;------------------------------------------------------------------
; ls_fmt_human: format a 32-bit byte count as a human-readable
; string, Linux `ls -h` style -- plain decimal bytes under 1024 (no
; suffix), else 1-3 significant digits with a K/M/G suffix, with one
; decimal place shown only when the whole part is a single digit
; (0-9). Deliberately picks the SMALLEST unit whose whole part comes
; out under 1000 (not the more obvious "largest unit whose whole part
; is >=1", which can leave a 4-digit whole part, e.g. 1023K) -- this
; guarantees the display is NEVER more than 4 characters wide
; (3 digits + suffix, or 1 digit + '.' + 1 digit + suffix).
;
; ROUNDS to nearest, not floors (2026-07-26: a first version floored,
; documented as a deliberate approximation -- the user tested it on
; hardware against real values verified with their own host `ls` and
; found it wrong, not just imprecise: 290421 bytes showed "283K"
; where real `ls -h` shows "284K"; 1462695 showed "1.3M" where real
; `ls -h` shows "1.4M". Both are exactly what floor-vs-round predicts:
; 290421/1024 = 283.61..., 1462695/1048576 = 1.3948... -- genuinely
; closer to 284/1.4 than to 283/1.3. Rewritten to round-to-nearest
; using EXACT 32-bit arithmetic throughout (ls_add32/ls_sub32/
; ls_cmp32_ge/ls_dbl32 below) -- no reduced-precision shortcut this
; time, since the whole point of the fix is to stop approximating.
; Verified against 66,000+ values (including exhaustive coverage
; around every unit/digit boundary, plus the user's own two reported
; values) via a from-scratch mechanical 1802-instruction simulator
; before any of this was trusted -- see the design scratch history for
; the two real bugs that simulation caught before this ever reached
; real assembly: (1) an early ls_cmp32_ge draft only compared 2 of the
; 4 relevant bytes, silently never referencing the high word (R9) at
; all; (2) rounding a decimal digit all the way up to 10 does NOT
; always mean "drop the decimal point" -- e.g. whole=1,dec=10 carries
; to whole=2,dec=0, which must still print "2.0K", not "2K"; only an
; ORIGINAL whole of exactly 9 crosses all the way to a bare "10K".
; Rounding can also push a 10-999 whole up to exactly 1000, which must
; bump to the NEXT larger unit rather than print a 4-digit value --
; handled by lfh_round_and_print's own DF=1 "please retry the next
; unit" signal back to the K/M call sites below.
;
; Args:    RD:R8 = 32-bit byte count (RD = high word, R8 = low word)
;          RF = destination buffer (>= 5 bytes: max "999K"/"9.9K"/
;          "1023"+null)
; Returns: buffer filled and null-terminated
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
ls_fmt_human:
            mov     rb, ls_human_dest
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ls_human_dest = RF (dest buffer)

            mov     rb, ls_human_n
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb                  ; ls_human_n = N (4 bytes: hi
                                        ; word then lo word, matching
                                        ; DIRENT_SIZE's own big-endian
                                        ; convention)

            ; ---- plain-byte case: N < 1024 (RD entirely zero AND
            ; R8 < 1024). MUST check the FULL 16-bit RD (both ghi AND
            ; glo), not just ghi(rd) alone -- caught in the design
            ; simulation before ever reaching real assembly: RD=16
            ; (for example) has a zero HIGH byte even though the
            ; register itself is not zero, and checking only ghi(rd)
            ; would have silently mis-treated N=1048576 (RD=16) as
            ; "high word zero", then wrongly evaluated R8 alone
            ; (which happened to be 0) as if it were the whole value.
            ; ----
            ghi     rd
            lbnz    lfh_try_k           ; RD.hi nonzero: N >= 65536,
                                        ; definitely not plain-byte
            glo     rd
            lbnz    lfh_try_k           ; RD.lo nonzero (hi was 0):
                                        ; RD is 1-255, N >= 65536 still
            ghi     r8
            smi     4                   ; 1024 = 0x0400 -- R8.hi>=4
                                        ; means R8>=1024 exactly at
                                        ; this byte-aligned boundary,
                                        ; no need to also check R8.lo
            lbdf    lfh_try_k           ; R8 >= 1024: not plain-byte

            ; plain-byte path: N < 1024, print R8 directly via
            ; f_uintout (no RF reload needed -- nothing since entry
            ; has touched RF's own value, only str/inc/branches)
            mov     rd, r8
            call    f_uintout
            ldi     0
            str     rf
            rtn

lfh_try_k:
            ; reload N fresh into RD:R8
            mov     rf, ls_human_n
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = N

            call    ls_pairshr10        ; RD:R8 = whole_K = N >> 10

            ; is whole_K < 1000? Same full-register-zero discipline
            ; as the plain-byte check above -- any nonzero RD (either
            ; byte) means whole_K >= 65536 > 1000, skip straight to M.
            ghi     rd
            lbnz    lfh_try_m
            glo     rd
            lbnz    lfh_try_m

            ; RD == 0: compare R8 (16-bit) against 1000 (0x03E8) via
            ; the staged SM/SMB idiom already used throughout this
            ; file (e.g. ls_sort_outer/ls_trycol_loop) -- stage the
            ; SUBTRAHEND via str r2 first, load the MINUEND right
            ; before sm/smb (D = D - M(R(X)), the corrected polarity
            ; this project learned the hard way earlier this session)
            ldi     3
            phi     r9
            ldi     $E8
            plo     r9                  ; R9 = 1000
            glo     r9
            str     r2
            glo     r8
            sm
            ghi     r9
            str     r2
            ghi     r8
            smb
            lbdf    lfh_try_m           ; DF=1: R8 >= 1000, use M
                                        ; instead

            ; whole_K < 1000: use K
            mov     rb, ls_human_whole
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb                  ; ls_human_whole = whole_K
                                        ; (fits entirely in R8 -- RD
                                        ; confirmed 0 above)
            mov     rb, ls_human_suffix
            ldi     'K'
            str     rb

            ; remainder_K = N's low word & 0x03FF (exact -- stored as
            ; a full 4-byte value, high word always 0, since K's own
            ; scale, 1024, comfortably fits remainder in the low word
            ; alone)
            mov     rb, ls_human_remainder
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; remainder.hi word = 0
            mov     rf, ls_human_n
            inc     rf
            inc     rf                  ; RF -> N's low word, high byte
            ldn     rf
            ani     3
            str     rb
            inc     rb
            inc     rf
            ldn     rf
            str     rb                  ; remainder.lo word = N's low
                                        ; word & 0x3FF

            mov     rb, ls_human_scale
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            ldi     4
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_human_scale = 1024

            call    lfh_round_and_print
            lbnf    lfh_done            ; DF=0: already printed
            lbr     lfh_try_m           ; DF=1: rounded up to 1000K --
                                        ; retry at the next unit

lfh_try_m:
            ; whole_M = N >> 20, computed as (N's high word alone) >> 4
            ; -- exact for any 32-bit N, not an approximation: N's low
            ; word (max 65535) can never accumulate a full unit at
            ; this shift depth (verified algebraically during design,
            ; and by the 150,000+-case simulation)
            mov     rf, ls_human_n
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = N's high word
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = whole_M

            ldi     3
            phi     r9
            ldi     $E8
            plo     r9                  ; R9 = 1000
            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    lfh_use_g           ; DF=1: whole_M >= 1000, force G

            ; whole_M < 1000: use M
            mov     rb, ls_human_whole
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            mov     rb, ls_human_suffix
            ldi     'M'
            str     rb

            ; remainder_M = ((N's high word's low nibble) : N's low
            ; word), exact (no reduction). N's bits 19-16 (the 4 bits
            ; remainder_M needs beyond its own low word) live in the
            ; LOW NIBBLE of N's high word's LOW BYTE -- same masking
            ; this project's own design history already had to fix
            ; once for the earlier reduced-precision version (a first
            ; draft masked the wrong byte/nibble entirely -- kept
            ; correct here since it's independent of the rounding fix).
            mov     rb, ls_human_remainder
            ldi     0
            str     rb
            inc     rb                  ; remainder.hi word's own high
                                        ; byte = 0 (only 4 bits ever
                                        ; needed, comfortably within
                                        ; the low byte)
            mov     rf, ls_human_n
            lda     rf                  ; D = N's high word, high byte
                                        ; (discarded -- not part of the
                                        ; 20-bit remainder)
            ldn     rf                  ; D = N's high word, low byte
            ani     $0F
            str     rb
            inc     rb                  ; remainder.hi word's low byte
                                        ; = the masked nibble
            inc     rf
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; remainder.lo word = N's low
                                        ; word (unchanged, all 16 bits
                                        ; are part of the 20-bit
                                        ; remainder)

            mov     rb, ls_human_scale
            ldi     0
            str     rb
            inc     rb
            ldi     $10
            str     rb
            inc     rb
            ldi     0
            str     rb
            inc     rb
            str     rb                  ; ls_human_scale = 0x00100000
                                        ; = 1048576

            call    lfh_round_and_print
            lbnf    lfh_done            ; DF=0: already printed
            lbr     lfh_use_g           ; DF=1: rounded up to 1000M --
                                        ; retry (forced) at G

lfh_use_g:
            ; whole_G = N >> 30 = (N's high word alone) >> 14 -- exact
            ; for the same reason whole_M's >>4-of-the-high-word-alone
            ; shortcut is exact (verified algebraically + simulated).
            ; Always < 10 for any real 32-bit N (max ~4294967295 >> 30
            ; = 3), so this always takes the decimal-digit path below
            ; in practice -- the ">= 10, no decimal" fallback exists
            ; only for completeness/correctness, matching this
            ; project's own standing practice of keeping a technically-
            ; unreachable-but-still-correct code path rather than
            ; assuming the precondition.
            mov     rf, ls_human_n
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = N's high word
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = whole_G (>>14 total)

            mov     rb, ls_human_whole
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            mov     rb, ls_human_suffix
            ldi     'G'
            str     rb

            ; remainder_G = N & 0x3FFFFFFF (mask off N's own top 2
            ; bits), exact (no reduction). Since masking N's own byte0
            ; to its low 6 bits already zeroes bits 31-30 IN PLACE, the
            ; full 4-byte remainder is simply (N.byte0 & 0x3F, N.byte1,
            ; N.byte2, N.byte3) -- NO extra leading zero byte, unlike
            ; K's/M's own remainder (which genuinely need one, since
            ; their remainders are much smaller than 32 bits and don't
            ; fill the representation on their own). A first draft of
            ; this got that distinction wrong, inserting a spurious
            ; leading zero byte here too -- shifting every real byte
            ; one position to the right and silently dropping N's own
            ; LSB (byte3) entirely. Caught by hand-verifying the byte
            ; mapping in Python against 20,000 random 32-bit values
            ; before trusting this fix.
            mov     rb, ls_human_remainder
            mov     rf, ls_human_n
            lda     rf
            ani     $3F
            str     rb
            inc     rb                  ; remainder.byte0 = N.byte0 &
                                        ; 0x3F
            lda     rf
            str     rb
            inc     rb                  ; remainder.byte1 = N.byte1
                                        ; (unmasked)
            lda     rf
            str     rb
            inc     rb                  ; remainder.byte2 = N.byte2
                                        ; (unmasked)
            ldn     rf
            str     rb                  ; remainder.byte3 = N.byte3
                                        ; (unmasked)

            mov     rb, ls_human_scale
            ldi     $40
            str     rb
            inc     rb
            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb                  ; ls_human_scale = 0x40000000
                                        ; = 1073741824

            call    lfh_round_and_print ; G is the last unit -- no
                                        ; further unit to bump to
                                        ; (DF=1 is mathematically
                                        ; unreachable here, see
                                        ; lfh_use_g's own header
                                        ; comment; if it somehow
                                        ; occurred, the buffer would be
                                        ; left unprinted -- an accepted
                                        ; theoretical gap, matching
                                        ; this project's existing
                                        ; "unreachable but not
                                        ; specially guarded" precedent)
lfh_done:
            rtn

;------------------------------------------------------------------
; ls_add32/ls_sub32/ls_cmp32_ge/ls_dbl32: exact 32-bit register-pair
; arithmetic primitives (RD=high word, R8=low word convention
; throughout this file), used by the rounding computation below.
; Deliberately real 32-bit arithmetic, not a reduced-precision
; shortcut -- see ls_fmt_human's own header for why (a reduced
; approach was tried first and shipped, then found wrong on hardware
; against real values).
;------------------------------------------------------------------

; ls_add32: RD:R8 += R9:RA (R9=addend high word, RA=addend low word,
; both left unchanged)
; Modifies: RD, R8 (and D, DF)
ls_add32:
            add16   r8, ra              ; R8 += RA (16-bit reg-reg
                                        ; add, DF = carry-out)
            glo     r9
            str     r2
            glo     rd
            adc
            plo     rd
            ghi     r9
            str     r2
            ghi     rd
            adc
            phi     rd
            rtn

; ls_sub32: RD:R8 -= R9:RA (R9=subtrahend high word, RA=subtrahend low
; word, both left unchanged)
; Modifies: RD, R8 (and D, DF)
ls_sub32:
            sub16   r8, ra              ; R8 -= RA (16-bit reg-reg
                                        ; subtract -- the SUB16 macro
                                        ; itself stages the subtrahend
                                        ; RA first internally, matching
                                        ; the corrected SM/SMB polarity
                                        ; this project learned the hard
                                        ; way; DF = borrow-out)
            glo     r9
            str     r2
            glo     rd
            smb
            plo     rd
            ghi     r9
            str     r2
            ghi     rd
            smb
            phi     rd
            rtn

; ls_cmp32_ge: is RD:R8 >= R9:RA ? Non-destructive -- RD/R8/R9/RA all
; left unchanged. A first draft of this only compared 2 of the 4
; relevant bytes (never referencing R9 at all), caught by this
; design's own mechanical simulation before ever reaching real
; assembly -- fixed to the full 4-byte chain below.
; Returns: DF = 1 if RD:R8 >= R9:RA, else DF = 0
; Modifies: nothing persistent (D clobbered, as always)
ls_cmp32_ge:
            glo     ra
            str     r2
            glo     r8
            sm                          ; low word, low byte
            ghi     ra
            str     r2
            ghi     r8
            smb                         ; low word, high byte
            glo     r9
            str     r2
            glo     rd
            smb                         ; high word, low byte
            ghi     r9
            str     r2
            ghi     rd
            smb                         ; high word, high byte --
                                        ; final DF is the real result
            rtn

; ls_dbl32: RD:R8 *= 2 (32-bit pair left-shift-by-1 -- SHL16 r8 shifts
; the low word, leaving the bit that fell off in DF; SHLC16 rd then
; shifts the high word USING that DF as its own carry-in, together one
; true 32-bit left-shift-by-one of the pair)
; Modifies: RD, R8 (and D, DF)
ls_dbl32:
            shl16   r8
            shlc16  rd
            rtn

;------------------------------------------------------------------
; ls_human_decdigit: compute ROUND(10*remainder/scale) EXACTLY, via 10
; repeated add+compare+subtract iterations (each exact -- no precision
; loss, unlike the reduced-precision approach this replaced), followed
; by a final round-to-nearest check against the loop's own leftover.
; Args:    none (reads ls_human_remainder/ls_human_scale)
; Returns: D = the rounded decimal digit, 0-10 (10 means "rounded up
;          to a full unit -- caller must apply the carry")
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
ls_human_decdigit:
            ldi     0
            phi     rd
            plo     rd
            ldi     0
            phi     r8
            plo     r8                  ; RD:R8 = acc = 0

            mov     rb, lhd_dec
            ldi     0
            str     rb                  ; dec = 0

            ldi     10
            plo     r7                  ; R7.0 = iterations remaining

lhd_loop:
            glo     r7
            lbz     lhd_round

            mov     rf, ls_human_remainder
            lda     rf
            phi     r9
            lda     rf
            plo     r9
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; R9:RA = remainder (reloaded
                                        ; fresh, every iteration --
                                        ; never trusted to survive a
                                        ; call)

            call    ls_add32            ; RD:R8 += remainder

            mov     rf, ls_human_scale
            lda     rf
            phi     r9
            lda     rf
            plo     r9
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; R9:RA = scale (reloaded
                                        ; fresh)

            call    ls_cmp32_ge         ; DF=1 if acc >= scale
            lbnf    lhd_next

            mov     rf, ls_human_scale
            lda     rf
            phi     r9
            lda     rf
            plo     r9
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; R9:RA = scale (reloaded
                                        ; again -- ls_cmp32_ge doesn't
                                        ; modify it, but this project's
                                        ; own standing discipline is to
                                        ; reload rather than trust a
                                        ; register across any call)

            call    ls_sub32            ; acc -= scale

            mov     rb, lhd_dec
            ldn     rb
            adi     1
            str     rb                  ; dec += 1

lhd_next:
            glo     r7
            smi     1
            plo     r7
            lbr     lhd_loop

lhd_round:
            ; RD:R8 = acc (leftover after 10 iterations). Round: is
            ; 2*acc >= scale?
            call    ls_dbl32            ; RD:R8 = acc*2

            mov     rf, ls_human_scale
            lda     rf
            phi     r9
            lda     rf
            plo     r9
            lda     rf
            phi     ra
            ldn     rf
            plo     ra

            call    ls_cmp32_ge         ; DF=1 if 2*acc >= scale
            lbnf    lhd_done

            mov     rb, lhd_dec
            ldn     rb
            adi     1
            str     rb                  ; round up: dec += 1

lhd_done:
            mov     rf, lhd_dec
            ldn     rf                  ; D = dec (0-10)
            rtn

;------------------------------------------------------------------
; ls_human_whole_round_check: is 2*remainder >= scale ? (the rounding
; decision for a 10-999 whole part, which needs no decimal digit --
; just a yes/no "round up by 1"). Reads ls_human_remainder/
; ls_human_scale.
; Returns: DF = 1 if round-up needed
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
ls_human_whole_round_check:
            mov     rf, ls_human_remainder
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; RD:R8 = remainder

            call    ls_dbl32            ; RD:R8 = remainder*2

            mov     rf, ls_human_scale
            lda     rf
            phi     r9
            lda     rf
            plo     r9
            lda     rf
            phi     ra
            ldn     rf
            plo     ra                  ; R9:RA = scale

            call    ls_cmp32_ge         ; DF=1 if 2*remainder>=scale
            rtn

;------------------------------------------------------------------
; lfh_round_and_print: given ls_human_whole/remainder/scale/suffix all
; set for the CURRENT candidate unit (whole already confirmed <1000
; via floor, by the caller), decide decimal-vs-plain display, round
; EXACTLY, print, OR signal "this unit doesn't work after rounding,
; try the next one" if a 10-999 whole rounds up to exactly 1000.
; Args:    none (reads ls_human_whole/remainder/scale/suffix)
; Returns: DF=0 -- already printed; caller should just return too.
;          DF=1 -- whole rounded up to 1000; caller should jump to
;          the next unit's own try-label and recompute everything
;          fresh there (ls_human_whole/remainder/scale are stale for
;          any further use).
; Modifies: everything
;------------------------------------------------------------------
lfh_round_and_print:
            mov     rf, ls_human_whole
            ldn     rf
            lbnz    lfh_rp_plain        ; whole.hi nonzero: definitely
                                        ; >= 256, no decimal
            inc     rf
            ldn     rf
            smi     10
            lbdf    lfh_rp_plain        ; whole.lo >= 10: no decimal

            ; --- decimal case: whole is 0-9 ---
            call    ls_human_decdigit   ; D = dec (0-10)
            plo     r8                  ; R8.0 = dec (stashed; R8 is
                                        ; free here)

            glo     r8
            smi     10
            lbnz    lfh_rp_dec_no_carry ; dec != 10: no carry

            ; dec == 10: carry into whole (whole was 0-9, so +1 gives
            ; 1-10 -- never wraps the byte)
            mov     rf, ls_human_whole
            inc     rf
            ldn     rf
            adi     1
            str     rf
            ldi     0
            plo     r8                  ; dec = 0

lfh_rp_dec_no_carry:
            ; re-check whole < 10 AFTER any carry -- NOT just "dec==10
            ; implies no decimal" (a real bug caught during design
            ; verification: e.g. whole=1,dec=10 carries to whole=2,
            ; dec=0, which must STILL print "2.0<suffix>", not
            ; "2<suffix>" -- only an ORIGINAL whole of exactly 9
            ; crosses all the way to a bare "10<suffix>")
            mov     rf, ls_human_whole
            inc     rf
            ldn     rf
            smi     10
            lbdf    lfh_rp_plain_go     ; whole is now >= 10 (only
                                        ; reachable via the 9->10
                                        ; carry): print plain, no
                                        ; decimal -- shares the same
                                        ; tail the 10-999 case uses

            ; print "whole.dec<suffix>"
            mov     rf, ls_human_whole
            inc     rf
            ldn     rf
            plo     rd
            ldi     0
            phi     rd                  ; RD = whole (0-9)

            mov     rf, ls_human_dest
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = dest buffer address
            mov     rf, rb              ; RF = write cursor

            glo     rd
            adi     '0'
            str     rf
            inc     rf                  ; buffer[0] = whole digit

            ldi     '.'
            str     rf
            inc     rf                  ; buffer[1] = '.'

            glo     r8                  ; D = dec (0-9 -- the ==10
                                        ; carry case was already
                                        ; handled and routed away
                                        ; above)
            adi     '0'
            str     rf
            inc     rf                  ; buffer[2] = decimal digit

            mov     rb, ls_human_suffix
            ldn     rb
            str     rf
            inc     rf                  ; buffer[3] = suffix

            ldi     0
            str     rf                  ; buffer[4] = null
            clc                         ; DF=0: printed
            rtn

lfh_rp_plain:
            ; --- plain case: whole is 10-999 (floored) -- round to
            ; nearest whole number, possibly bumping to the next unit
            call    ls_human_whole_round_check
            lbnf    lfh_rp_plain_go

            ; round up: whole += 1 (proper 16-bit increment, handles
            ; any lo-to-hi carry for free -- e.g. 255 -> 256)
            mov     rf, ls_human_whole
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = whole
            inc     rd                  ; +1 (2026-08-01 size-reduction
                                        ; pass: INC is a native 1-byte
                                        ; 16-bit register increment --
                                        ; strictly cheaper than ADD16
                                        ; reg,1's 8-byte macro, and
                                        ; touches no memory at all, so
                                        ; gotcha #18 doesn't even apply)
            mov     rf, ls_human_whole
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ls_human_whole = rounded

lfh_rp_plain_go:
            ; is whole now exactly 1000? if so, signal a bump instead
            ; of printing. Reached both from the 10-999 path above
            ; (the real check) and from the decimal-carry path (whole
            ; is provably at most 10 there, so this always falls
            ; through to printing in that case -- no special-casing
            ; needed between the two callers)
            mov     rf, ls_human_whole
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = whole (final)

            ldi     3
            phi     r9
            ldi     $E8
            plo     r9                  ; R9 = 1000
            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbnz    lfh_rp_print_plain  ; whole != 1000: print
                                        ; normally

            stc                         ; DF=1: signal bump
            rtn

lfh_rp_print_plain:
            ; print "whole<suffix>" (no decimal) via f_uintout
            mov     rf, ls_human_dest
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9              ; RF = dest buffer
            call    f_uintout           ; writes decimal digits,
                                        ; advances RF, no null term
            mov     rb, ls_human_suffix
            ldn     rb
            str     rf
            inc     rf
            ldi     0
            str     rf
            clc                         ; DF=0: printed
            rtn

; ---- scratch / state ----
ls_longmode:    db      0
ls_fmode:       db      0           ; -F: append "/" to directory entries
ls_amode:       db      0           ; -a: show hidden entries too (bare
                                    ; directory-scan listing only --
                                    ; ls_single_file/ls_multi_stat's own
                                    ; explicit-reference paths never
                                    ; filter regardless of this flag)
ls_hasquote:    db      0           ; per-entry scratch, set during
                                    ; ls_add_entry's own namelen scan --
                                    ; NOT a global mode flag like
                                    ; ls_longmode/ls_fmode, reset fresh
                                    ; for every entry
ls_cluster:     dw      0
ls_patharg:     dw      0
ls_argptr2:     dw      0
ls_scratch:     ds      DIRENT_LEN

; ---- multi-argument / option-scan state (2026-07-22) ----
ls_argv:        dw      0           ; stashed argv pointer (ls_scan_options)
ls_argc:        db      0           ; stashed argc
ls_scan_i:      db      0           ; ls_scan_options' own loop index
ls_paths:       ds      ARGV_MAX_ARGS * 2  ; compacted, zero-based
                                    ; non-flag argv pointers
ls_num_paths:   db      0           ; count of entries in ls_paths
ls_multi_i:     db      0           ; ls_multi_stat's own loop index
                                    ; (0-based, indexes ls_paths)
ls_cur_path:    dw      0           ; ls_multi_stat's current path,
                                    ; stashed before each K_STAT call
ls_any_error:   db      0           ; set if any ls_multi_stat lookup
                                    ; failed -- drives the exit code
ls_glob_found:  db      0           ; shared by the single-path glob
                                    ; loop (ls_resolve_body) and the
                                    ; per-path glob loop inside
                                    ; ls_multi_stat -- mutually
                                    ; exclusive, never active at once
ls_glob_ctx:    ds      GLOB_CTX_LEN ; ditto

ls_count:       dw      0
ls_next_entry:  dw      0
ls_next_ptrslot: dw     0
ls_namelen:     db      0           ; current entry's name length,
                                    ; stashed across the bump_alloc call
ls_curnamebuf:  dw      0           ; current entry's bump-allocated
                                    ; name buffer address

ls_sort_i:      dw      0
ls_sort_m:      dw      0
ls_sort_key:    dw      0

ls_numcols:     dw      0
ls_numrows:     dw      0
ls_colbase_i:   dw      0
ls_row:         dw      0
ls_col:         dw      0
ls_curname:     dw      0

; per-column-width layout state (2026-07-19 redesign -- see
; ls_print_columnar's own header comment)
ls_trycols:     dw      0           ; candidate column count being tried
ls_totalwidth:  dw      0           ; running summed column width for
                                    ; the current candidate
ls_colmax:      db      0           ; running max namelen for the
                                    ; column currently being scanned
ls_colrow:      dw      0           ; row index within that column scan

ls_curentry:    dw      0
ls_sizebuf:     ds      6           ; human-readable size scratch
                                    ; (2026-07-26: was plain-decimal
                                    ; "65535"+null; max content is now
                                    ; "999K"/"9.9K"/"1023" -- 4 chars +
                                    ; null -- still fits within 6)
ls_spaces5:     db      "     ",0   ; 5 spaces -- right-justify padding
                                    ; source for the -l size column
ls_digitbuf:    ds      3

; ---- ls_fmt_human's own scratch (2026-07-26) ----
ls_human_dest:  dw      0           ; caller's destination buffer,
                                    ; stashed at entry
ls_human_n:     dw      0, 0        ; the 32-bit byte count being
                                    ; formatted (hi word, lo word --
                                    ; reloaded fresh from here at each
                                    ; unit-selection attempt, never
                                    ; trusted to survive in a register
                                    ; across ls_pairshr10/the K-vs-M-
                                    ; vs-G branching)
ls_human_whole: dw      0           ; the chosen unit's whole part
                                    ; (<1000, or <10 for G)
ls_human_suffix: db     0           ; 'K'/'M'/'G'
ls_human_remainder: dw  0, 0        ; the chosen unit's EXACT remainder
                                    ; (2026-07-26: replaces the old
                                    ; reduced-precision version -- see
                                    ; ls_fmt_human's own header for why)
ls_human_scale: dw      0, 0        ; the chosen unit's scale (1024 /
                                    ; 1048576 / 1073741824)
lhd_dec:        db      0           ; ls_human_decdigit's own dec
                                    ; counter (0-10), kept in memory --
                                    ; needs to survive across
                                    ; ls_add32/ls_cmp32_ge/ls_sub32
                                    ; calls inside its own loop

ls_wr_day:      db      0
ls_wr_month:    db      0
ls_wr_year:     dw      0
ls_wr_hour:     db      0
ls_wr_minute:   db      0

ls_colbase:     ds      2*LS_MAX_COLS
ls_colwidths:   ds      LS_MAX_COLS ; 1 byte/column (max width 129 --
                                    ; LS_NAME_CAP+2 -- fits easily)
ls_ptrs:        ds      2*LS_MAX_ENTRIES
ls_entries:     ds      LSENT_LEN*LS_MAX_ENTRIES

ls_columns_name: db     "COLUMNS",0
ls_screen_cols:  dw     LS_SCREEN_COLS  ; overridden by ls_resolve if
                                        ; COLUMNS is set to a valid
                                        ; nonzero number

            end     start
