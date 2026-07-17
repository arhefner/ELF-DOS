;
; ls.asm - list a directory, Linux ls-style
;
; Usage: LS [-l] [path]
;
; Default output: sorted file/directory names only, printed in
; columns (column-major fill order, matching real Unix ls -- entries
; fill down each column before moving to the next), assuming an
; 80-column screen (LS_SCREEN_COLS below -- a constant for now; a
; future version could read ROWS/COLUMNS environment variables or
; query an ANSI terminal once this project gets that far).
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
; Collected entries are held in a fixed-size static table (up to
; LS_MAX_ENTRIES, names truncated at LS_NAME_CAP chars for display
; purposes only) rather than the heap_bump/heap_malloc libraries --
; deliberate: those libraries are not yet hardware-tested, and this
; program's own directory-collection pattern (collect everything, use
; it, exit) doesn't need dynamic sizing badly enough to take on that
; dependency yet. A future version could switch once the heap
; libraries are hardware-confirmed.
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

; ---- per-entry storage struct (fixed size, LSENT_LEN bytes) ----
LSENT_ATTR:     equ     0           ; 1 byte, FAT attribute byte
LSENT_DATE:     equ     1           ; 2 bytes, packed FAT last-write date
LSENT_TIME:     equ     3           ; 2 bytes, packed FAT last-write time
LSENT_SIZE:     equ     5           ; 2 bytes, size low word (0-65535)
LSENT_NAME:     equ     7           ; NUL-terminated name, up to
                                    ; LS_NAME_CAP chars + NUL
LS_NAME_CAP:    equ     32
LSENT_LEN:      equ     (LSENT_NAME+LS_NAME_CAP+1)

LS_MAX_ENTRIES: equ     128
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

            ; ---- parse argv: optional "-l", optional path ----
            glo     rc
            smi     2
            lbnf    ls_resolve          ; argc < 2: nothing to parse

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    ls_arg1_path

            inc     rf
            ldn     rf                  ; D = argv[1][1]
            xri     'l'
            lbnz    ls_arg1_path

            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
                                        ; for "-l" to be exactly this
                                        ; whole token
            lbnz    ls_arg1_path

            mov     rf, ls_longmode
            ldi     1
            str     rf                  ; ls_longmode = 1

            glo     rc
            smi     3
            lbnf    ls_resolve          ; argc < 3: no path after -l

            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] pointer
            lbr     ls_save_patharg

ls_arg1_path:
            ; RD already holds argv[1]'s pointer, untouched by the "-l"
            ; character checks above (same fallback shape as mr.asm's
            ; own "not_flag" -- an unrecognized dash-prefixed token
            ; just becomes the path argument, probably invalid)
ls_save_patharg:
            mov     rb, ls_patharg
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

ls_resolve:
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
            lbz     ls_not_dir

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

            mov     rb, ls_count
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_count = 0

            mov     rb, ls_maxlen
            ldi     0
            str     rb                  ; ls_maxlen = 0

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

;------------------------------------------------------------------
; Collect loop: K_DIR_READ each entry, copy the fields we need into
; a fixed-size struct at ls_next_entry, record that struct's address
; in the pointer table at ls_next_ptrslot, advance both, cap at
; LS_MAX_ENTRIES (extras are silently dropped rather than failing).
;------------------------------------------------------------------
ls_collect_loop:
            mov     rf, ls_scratch
            call    K_DIR_READ
            lbdf    ls_collect_done     ; end of directory

            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            ghi     rd
            lbnz    ls_collect_loop     ; count >= 256: drop this entry
            glo     rd
            smi     LS_MAX_ENTRIES
            lbdf    ls_collect_loop     ; count >= LS_MAX_ENTRIES: drop

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
            inc     rf                  ; RF now at LSENT_NAME in dest

            ; ---- copy name, truncating at LS_NAME_CAP, tracking the
            ; copied length for the column-width computation later ----
            mov     rd, ls_scratch      ; RD = DIRENT_NAME (offset 0)
            ldi     0
            plo     r9                  ; R9.0 = copied length so far

ls_namecopy_loop:
            ldn     rd
            lbz     ls_namecopy_done    ; source NUL: done
            glo     r9
            smi     LS_NAME_CAP
            lbdf    ls_namecopy_done    ; cap reached: truncate here

            ldn     rd                  ; reload -- smi above clobbered D
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

            mov     rd, ls_maxlen
            ldn     rd
            str     r2                  ; M(R2) = current maxlen
            glo     r9
            sm                          ; D = copied_len - maxlen,
                                        ; DF=1 if copied_len >= maxlen
            lbnf    ls_store_ptr
            mov     rd, ls_maxlen
            glo     r9
            str     rd                  ; maxlen = copied_len

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

            lbr     ls_collect_loop

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
            add16   rf, LSENT_NAME      ; RF = ls_ptrs[m-1]->name
            mov     rd, ls_sort_key
            lda     rd
            phi     r9
            ldn     rd
            plo     r9                  ; R9 = key (entry addr)
            mov     rd, r9
            add16   rd, LSENT_NAME      ; RD = key->name
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
; Columnar (default) output: column-major fill order, column width
; = longest name + 2, column count = 80 / column width (min 1,
; capped at LS_MAX_COLS). Column base offsets (col * num_rows) are
; precomputed into ls_colbase to avoid any runtime multiplication --
; the print loop then only ever adds a row number to a table lookup.
;------------------------------------------------------------------
ls_print_columnar:
            mov     rf, ls_maxlen
            ldn     rf
            plo     rd
            ldi     0
            phi     rd                  ; RD = ls_maxlen (0-32)
            add16   rd, 2               ; RD = col_width
            mov     rb, ls_colwidth
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            ldi     0
            phi     rd
            ldi     LS_SCREEN_COLS
            plo     rd                  ; RD = 80 (dividend)
            mov     rf, ls_colwidth
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = col_width (divisor)
            call    ls_div              ; RD = 80 / col_width

            ghi     rd
            lbnz    ls_numcols_ok
            glo     rd
            lbnz    ls_numcols_ok
            ldi     1
            plo     rd                  ; num_cols == 0: clamp to 1

ls_numcols_ok:
            glo     rd
            smi     LS_MAX_COLS
            lbnf    ls_numcols_final
            ldi     LS_MAX_COLS
            plo     rd                  ; clamp to LS_MAX_COLS

ls_numcols_final:
            mov     rb, ls_numcols
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            ; num_rows = ceil(ls_count / num_cols)
            mov     rf, ls_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_count
            mov     rf, ls_numcols
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = num_cols
            add16   rd, rc
            sub16   rd, 1               ; RD = ls_count + num_cols - 1
            call    ls_div              ; RD = RD / RC (RC preserved
                                        ; by ls_div -- read-only there)
            mov     rb, ls_numrows
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            ; ---- build ls_colbase[c] = c * num_rows incrementally ----
            mov     rb, ls_colbase_i
            ldi     0
            str     rb
            inc     rb
            ldi     0
            str     rb                  ; ls_colbase_i = 0

            ldi     0
            phi     r8
            plo     r8                  ; R8 = running base, starts at 0

ls_colbase_loop:
            mov     rf, ls_colbase_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = ls_colbase_i
            mov     rf, ls_numcols
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = num_cols

            glo     r9
            str     r2
            glo     rd
            sm
            ghi     r9
            str     r2
            ghi     rd
            smb
            lbdf    ls_colbase_done     ; ls_colbase_i >= num_cols: done

            shl16   rd                  ; RD = ls_colbase_i * 2
            mov     rf, ls_colbase
            add16   rf, rd              ; RF = &ls_colbase[ls_colbase_i]
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ls_colbase[i] = running base

            mov     rf, ls_numrows
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = num_rows
            glo     r8
            str     r2
            glo     r9
            add                         ; D = base.lo + num_rows.lo
            plo     r8
            ghi     r8
            str     r2
            ghi     r9
            adc                         ; D = base.hi + num_rows.hi + carry
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
            str     rf                  ; ls_colbase_i++

            lbr     ls_colbase_loop

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
            add16   rf, LSENT_NAME      ; RF = entry's name
            mov     rb, ls_curname
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; ls_curname = name address --
                                        ; stashed to memory since R8/RF
                                        ; are not confirmed to survive
                                        ; the K_MSG/K_INMSG calls below
                                        ; (gotcha #8/#10: only R9 has
                                        ; ever been confirmed safe
                                        ; across these)

            call    K_MSG

            ; pad with spaces to ls_colwidth: track printed length via
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
            ; col_width is re-read from memory every iteration rather
            ; than held in a register, since R8 is not confirmed safe
            ; across the call below
            mov     rf, ls_colwidth
            ldn     rf                  ; D = col_width
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
            ; right-justified 6-column decimal size
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
ls_long_count_loop:
            ldn     rf
            lbz     ls_long_count_done
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     ls_long_count_loop
ls_long_count_done:
            mov     rf, ls_spaces6
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
            plo     rd
            add16   rd, LSENT_NAME
            mov     rf, rd
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
            ldi     0                   ; exit code 0 = success
            rtn

ls_not_found:
            call    K_INMSG
            db      "Directory not found.",13,10,0
            ldi     1
            rtn

ls_not_dir:
            call    K_INMSG
            db      "Not a directory.",13,10,0
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

ls_count:       dw      0
ls_maxlen:      db      0
ls_next_entry:  dw      0
ls_next_ptrslot: dw     0

ls_sort_i:      dw      0
ls_sort_m:      dw      0
ls_sort_key:    dw      0

ls_colwidth:    dw      0
ls_numcols:     dw      0
ls_numrows:     dw      0
ls_colbase_i:   dw      0
ls_row:         dw      0
ls_col:         dw      0
ls_curname:     dw      0

ls_curentry:    dw      0
ls_sizebuf:     ds      6           ; decimal size scratch ("65535"+null)
ls_spaces6:     db      "      ",0  ; 6 spaces -- right-justify padding
                                    ; source for the -l size column
ls_digitbuf:    ds      3

ls_wr_day:      db      0
ls_wr_month:    db      0
ls_wr_year:     dw      0
ls_wr_hour:     db      0
ls_wr_minute:   db      0

ls_colbase:     ds      2*LS_MAX_COLS
ls_ptrs:        ds      2*LS_MAX_ENTRIES
ls_entries:     ds      LSENT_LEN*LS_MAX_ENTRIES

            end     start
