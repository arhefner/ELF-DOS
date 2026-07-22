;
; ls.asm - list a directory, Linux ls-style
;
; Usage: LS [-l] [path]
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

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   bump_init
            extrn   bump_alloc
            extrn   env_getenv
            extrn   env_parse_uint

; ---- per-entry storage struct (fixed size, LSENT_LEN bytes) ----
LSENT_ATTR:     equ     0           ; 1 byte, FAT attribute byte
LSENT_DATE:     equ     1           ; 2 bytes, packed FAT last-write date
LSENT_TIME:     equ     3           ; 2 bytes, packed FAT last-write time
LSENT_SIZE:     equ     5           ; 2 bytes, size low word (0-65535)
LSENT_NAMEPTR:  equ     7           ; 2 bytes: pointer to a heap_bump-
                                    ; allocated, NUL-terminated name
                                    ; (sized to the real name's length,
                                    ; not a fixed buffer -- see the file
                                    ; header comment)
LSENT_NAMELEN:  equ     9           ; 1 byte: the name's real length
                                    ; (0-127), precomputed at collection
                                    ; time so the per-column-width
                                    ; layout pass (2026-07-19) never
                                    ; needs to re-strlen a name
LSENT_LEN:      equ     10

LS_NAME_CAP:    equ     127         ; matches K_DIR_READ's own DIRENT_NAME
                                    ; limit -- caps the length-counting
                                    ; scan and the bump_alloc request
                                    ; size; a real name is never
                                    ; truncated in practice

; LS_MAX_ENTRIES raised back up (2026-07-19, alongside the switch to
; heap_bump for name storage) now that the fixed per-entry cost is tiny
; (LSENT_LEN=9 + 2 bytes in ls_ptrs = 11 bytes/entry, vs. the 137
; bytes/entry the old fixed-inline-name design cost). Capped at 255,
; not raised further, so the collect loop's existing single-byte
; ls_count bounds check (below) needs no changes -- it already treats
; 256 as a hard ceiling. 255 * 11 = 2805 bytes fixed -- well under the
; OLD 48-entry budget (6576 bytes) while supporting over 5x as many
; entries; actual name storage now scales with the real directory
; content instead of a worst-case per-slot reservation.
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
            add16   rf, 2
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
; anywhere on the line (today just "-l", exact-token match, same
; convention progs/mr.asm/progs/ms.asm's own "-u"/"-b" flags already
; use -- not combined-short-option parsing like "-la") and building a
; compacted, zero-based list of the remaining (non-flag) arguments in
; ls_paths/ls_num_paths. Adding a future flag (-a, -F, ...) is just
; one more comparison block here -- everything downstream only ever
; looks at ls_paths/ls_num_paths/ls_longmode, never argv directly.
; Args:    none (reads RA/RC directly, at entry)
; Returns: nothing (ls_paths/ls_num_paths/ls_longmode set)
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

            ; is it exactly "-l"?
            mov     rf, rd
            ldn     rf                  ; D = token[0]
            xri     '-'
            lbnz    lso_is_path

            mov     rf, rd
            inc     rf
            ldn     rf                  ; D = token[1]
            xri     'l'
            lbnz    lso_is_path

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; D = token[2] -- must be NUL
                                        ; for "-l" to be exactly this
                                        ; whole token
            lbnz    lso_is_path

            mov     rf, ls_longmode
            ldi     1
            str     rf                  ; recognized "-l": set the
                                        ; flag, don't copy it forward
            lbr     lso_next

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
            lbnz    ls_resolve_go
            ghi     rd
            lbnz    ls_resolve_go
            lbr     ls_open             ; no path arg -- list current dir

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
            ; expected to actually trigger) ----
            mov     rd, ls_scratch      ; RD = DIRENT_NAME (offset 0)
            ldi     0
            plo     r9                  ; R9.0 = length so far

ls_namelen_loop:
            ldn     rd
            lbz     ls_namelen_done     ; source NUL: done
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

            mov     rd, ls_scratch
            add16   rd, DIRENT_SIZE
            add16   rd, 2               ; skip to the low word
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

            mov     rd, ls_namelen
            ldn     rd
            str     rf                  ; entry->namelen = ls_namelen

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
            add16   rd, 2
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
            add16   rd, 1
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
; ls_multi_stat: two or more path arguments (typically via the
; shell's own glob expansion, e.g. "LS *.txt") -- K_STAT each one
; independently and add it to the collection via ls_add_entry, same
; as a directory-scan entry (works for both columnar and -l output
; with no changes to either print routine, since a multi-stat match's
; attribute byte is exactly what -l mode's own per-entry logic
; already branches on). A bad argument prints its own error and the
; rest still run; ls_any_error drives the final exit code.
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

            ; stash the path pointer for the possible error message
            ; below BEFORE calling K_STAT -- its own clobber footprint
            ; isn't proven anywhere in this codebase yet
            mov     rf, ls_cur_path
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, rd              ; RF = path string
            mov     rd, ls_scratch      ; RD = result buffer
            call    K_STAT              ; DF = 0/1
            lbdf    lms_not_found

            call    ls_add_entry        ; DF=1: out of RAM, stop
                                        ; collecting entirely
            lbdf    ls_collect_done
            lbr     lms_next

lms_not_found:
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
            sub16   rd, 1               ; RD = m-1
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
            sub16   rd, 1
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
            add16   rd, 1
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
            sub16   rd, 1               ; RD = ls_count+candidate-1
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
            add16   rd, 1
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
            add16   rd, 1
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
            sub16   rd, 1
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

            ; print ls_ptrs[idx]->name, padded to col_width
            shl16   rd                  ; RD = idx * 2
            mov     rf, ls_ptrs
            add16   rf, rd              ; RF = &ls_ptrs[idx]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = entry struct address

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

            mov     rf, r9              ; RF = name address (K_MSG's arg)
            call    K_MSG

            ; pad with spaces to this column's own width: track printed
            ; length via
            ; a fresh strlen scan, reloading ls_curname from memory
            ; rather than trusting any register across the call above
            mov     rf, ls_curname
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = name address (fresh)
            ldi     0
            plo     r9                  ; R9.0 = name length -- R9 IS
                                        ; confirmed to survive K_INMSG
                                        ; (gotcha #8, and the redirect
                                        ; dispatcher's own explicit R9
                                        ; preservation), so it's safe to
                                        ; carry across ls_pad_loop's own
                                        ; call below
ls_pad_len_loop:
            ldn     rf
            lbz     ls_pad_len_done
            inc     rf
            glo     r9
            adi     1
            plo     r9
            lbr     ls_pad_len_loop
ls_pad_len_done:
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
            add16   rd, 1
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
            add16   rd, 1
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
            ; right-justified 5-column decimal size (0-65535 always
            ; fits in 5 digits -- matches real ls's own fixed-width
            ; size field; no K/M/G suffixes needed at this file-size
            ; ceiling)
            mov     rf, ls_curentry
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = entry struct address
            add16   rd, LSENT_SIZE
            lda     rd
            phi     r8
            ldn     rd
            plo     r8                  ; R8 = size (0-65535)
            mov     rd, r8

            mov     rf, ls_sizebuf
            call    f_uintout
            ldi     0
            str     rf

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
            mov     rf, rd              ; RF = name address (K_MSG's arg)
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            mov     rf, ls_row
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
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
            add16   r9, 1
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

; ---- scratch / state ----
ls_longmode:    db      0
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
ls_sizebuf:     ds      6           ; decimal size scratch ("65535"+null)
ls_spaces5:     db      "     ",0   ; 5 spaces -- right-justify padding
                                    ; source for the -l size column
ls_digitbuf:    ds      3

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
