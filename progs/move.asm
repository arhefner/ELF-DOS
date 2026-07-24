;
; move.asm - move (relocate) one or more files
;
; Usage: MOVE <source> <destination>
;        MOVE <source> [source...] <destination-directory>
;
; Same argv shape and destination-directory conventions as COPY (see
; progs/copy.asm's own header for the full rationale -- repeated only
; briefly here): single-source form's <destination> may be a full
; path, or an existing directory (source copied/renamed into it under
; its own basename); multi-source form requires the LAST argument to
; already be an existing directory, checked once up front before any
; file is touched. A failure on one source prints its own error and
; moves on to the next rather than aborting the whole command; final
; exit code reflects whether ANY source failed. No wildcards handled
; directly here -- the shell's own tokenizer already expands them.
;
; For each source, first tries a fast, data-free rename via
; lib/move.asm's move_rename -- it takes the fast path whenever the
; resolved destination is a bare name (no '/', no "X:" drive prefix),
; which is exactly what K_FILE_RENAME itself requires for a same-
; directory rename; true for the overwhelmingly common case of moving
; a file or directory within one directory tree. If that's not
; applicable -- a destination that's a path, or a genuine cross-
; directory/cross-drive relocation -- falls back to a full copy of
; the file's data into the new location followed by deleting the
; original (same "safe step before the destructive one" ordering used
; throughout this project: the delete only happens after the copy has
; fully succeeded). This fallback is single-file only, matching
; COPY's own scope -- moving a DIRECTORY across directories would need
; a recursive copy (a future XCOPY's own job, not this command's), so
; it's reported as an error rather than attempted.
;
; If the resolved destination already exists (only reachable via the
; copy+delete fallback -- move_rename's own fast path never overwrites,
; matching REN), the user is prompted to confirm the overwrite (Y/N --
; anything but Y/y cancels), same as COPY.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

MOVE_CHUNK_LEN: equ     512     ; matches COPY's own chunk size --
                                ; see copy.asm's own comment for why
DST_BUF_LEN:    equ     132

            extrn   move_rename

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. Same layout as COPY:
            ; argv[0] is this program's own name; argv[1..argc-2] are
            ; sources (just argv[1] when argc==3); argv[argc-1] is the
            ; destination.
            glo     rc
            smi     3
            lbnf    usage_error         ; argc < 3: source and/or
                                        ; destination missing

            ; stash argv + argc to memory -- everything called from
            ; here on clobbers RA per its own documented list
            mov     rf, move_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, move_argc
            glo     rc
            str     rf

            ; dst_ptr = argv[argc-1] (the LAST argument)
            mov     rf, move_argc
            ldn     rf
            smi     1
            plo     r8
            ldi     0
            phi     r8                  ; R8 = (argc-1), zero-extended
            shl16   r8                  ; R8 = (argc-1)*2
            mov     rf, move_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = move_argv (base)
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
            mov     rf, move_argc
            ldn     rf
            smi     2
            str     rb

            ; --- is dst_ptr an existing directory? (checked ONCE,
            ; regardless of num_sources) -- same pattern CD/COPY use ---
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
            ; multiple sources REQUIRE an existing destination
            ; directory -- reject up front, before touching any file
            mov     rf, num_sources
            ldn     rf
            smi     2
            lbnf    start_run           ; num_sources < 2: single-
                                        ; source form, always OK
            mov     rf, dst_is_dir_flag
            ldn     rf
            lbnz    start_run           ; multi-source AND a real
                                        ; directory: OK

            call    K_INMSG
            db      "Destination must be an existing directory for multiple sources.",13,10,0
            ldi     1
            rtn

start_run:
            mov     rf, any_error
            ldi     0
            str     rf

            mov     rf, move_i
            ldi     1
            str     rf

move_loop_sources:
            mov     rf, move_i
            ldn     rf
            str     r2                  ; M(X) = move_i
            mov     rf, num_sources
            ldn     rf                  ; D = num_sources
            adi     1                   ; D = num_sources + 1
            xor                         ; D = (num_sources+1) XOR
                                        ; move_i
            lbz     move_all_done       ; move_i == num_sources+1:
                                        ; every source handled

            ; RD = argv[move_i] (this source)
            mov     rf, move_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            shl16   r8                  ; R8 = move_i * 2
            mov     rf, move_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = move_argv (base,
                                        ; reloaded fresh every
                                        ; iteration)
            add16   rb, r8              ; RB = &argv[move_i]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[move_i]
            mov     rf, src_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; src_ptr = this source

            call    move_one            ; DF = 0/1
            lbnf    move_next

            mov     rf, any_error
            ldi     $FF
            str     rf

move_next:
            mov     rf, move_i
            ldn     rf
            adi     1
            str     rf
            lbr     move_loop_sources

move_all_done:
            mov     rf, any_error
            ldn     rf
            lbnz    move_exit_err

            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention
            rtn

move_exit_err:
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: MOVE <source> [source...] <destination>",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; check_dst_is_dir: does dst_ptr name an existing directory? Identical
; to COPY's own routine of the same name (progs/copy.asm) -- not
; shared as library code since it's a small, self-contained block and
; neither program depends on the other.
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
; move_one: move src_ptr to its final destination -- dst_ptr + '/' +
; basename(src_ptr) if dst_is_dir_flag is set, else dst_ptr itself
; unchanged. Tries move_rename (data-free) first; falls back to
; move_fallback_copy_delete on a genuine cross-directory/cross-drive
; relocation.
; Args:    none (reads src_ptr/dst_ptr/dst_is_dir_flag)
; Returns: DF = 0 on success (including a declined overwrite), DF = 1
;          on any real failure
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
move_one:
            mov     rf, dst_is_dir_flag
            ldn     rf
            lbz     mo_dst_plain

            ; --- build dst_final = dst_ptr + '/' (if not already
            ; present) + basename(src_ptr), point real_dst at it ---
            ; identical shape to COPY's own copy_one (progs/copy.asm)
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dst_ptr's string
                                        ; pointer
            mov     rf, dst_final
mo_dst_loop:
            lda     rd
            lbz     mo_dst_done
            str     rf
            inc     rf
            lbr     mo_dst_loop
mo_dst_done:
            ; RF = one past the last copied char; peek the previous
            ; char to avoid a doubled '/' if dst_ptr already ends in
            ; one
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     mo_have_sep
            ldi     '/'
            str     rf
            inc     rf
mo_have_sep:
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
mo_basename_scan:
            ldn     r8
            lbz     mo_basename_done
            xri     '/'
            lbnz    mo_basename_next
            inc     r8
            mov     r9, r8              ; R9 = position right after '/'
            lbr     mo_basename_scan
mo_basename_next:
            inc     r8
            lbr     mo_basename_scan
mo_basename_done:
            ; RF still holds dst_final's write position (from
            ; mo_have_sep above -- not touched by the basename scan)
            mov     rd, r9              ; RD = basename source pointer
mo_append_basename_loop:
            lda     rd
            str     rf
            lbz     mo_append_basename_done
            inc     rf
            lbr     mo_append_basename_loop
mo_append_basename_done:

            mov     rb, real_dst
            mov     rf, dst_final
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; real_dst = dst_final
            lbr     mo_try_rename

mo_dst_plain:
            mov     rb, real_dst
            mov     rf, dst_ptr
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; real_dst = dst_ptr (single-
                                        ; source, non-directory
                                        ; destination -- unchanged)

mo_try_rename:
;------------------------------------------------------------------
; Fast path: RF=src_ptr, RD=real_dst -> move_rename.
;------------------------------------------------------------------
            mov     rf, src_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = src_ptr's string
                                        ; pointer (staged, since both
                                        ; RF and RD are about to be
                                        ; loaded fresh for the call)

            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = real_dst's string
                                        ; pointer

            mov     rf, r8              ; RF = source path

            call    move_rename         ; DF=0/1, D=0/1 valid only
                                        ; when DF=1
            lbnf    mo_done             ; DF=0: renamed, done
            lbnz    mo_real_fail        ; DF=1, D!=0 (i.e. D==1):
                                        ; real failure, no fallback

            ; DF=1, D==0: not the same directory/drive -- fall back
            ; to a full copy of the data, then delete the original
            call    move_fallback_copy_delete
            rtn                         ; propagate its own DF

mo_real_fail:
            call    K_INMSG
            db      "Cannot move (destination exists, source not found, or invalid).",13,10,0
            stc
            rtn

mo_done:
            clc
            rtn

;------------------------------------------------------------------
; move_fallback_copy_delete: genuine cross-directory/cross-drive
; relocation -- copy src_ptr's data to real_dst, then delete src_ptr.
; Single-file only (a directory source is rejected via the ordinary
; "source not found" path, since file_open itself refuses to open a
; directory -- see kernel/file.asm's file_open). Prompts for overwrite
; confirmation if real_dst already exists, same as COPY.
; Args:    none (reads src_ptr/real_dst)
; Returns: DF = 0 on success (including a declined overwrite), DF = 1
;          on any real failure (including "copied but couldn't delete
;          the source" -- a real problem, since a duplicate is left
;          behind rather than a clean relocation)
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
move_fallback_copy_delete:
;------------------------------------------------------------------
; If real_dst already exists, confirm the overwrite before touching
; anything. Checked before either file is opened, so a "no" here
; needs no cleanup. Identical shape to COPY's own co_check_overwrite.
;------------------------------------------------------------------
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination path string
            mov     rd, mv_dst_fcb      ; RD = our dst_fcb struct
                                        ; (reused below for the REAL
                                        ; destination open too -- this
                                        ; existence-check FCB is always
                                        ; closed before that happens)
            mov     ra, mv_dst_iobuf    ; RA = our dst_iobuf buffer
            ldi     0                   ; mode = read (existence check)
            call    K_FILE_OPEN         ; DF = 0/1 (D unspecified)
            lbdf    mfc_dst_check_done  ; not found (or a directory):
                                        ; proceed directly, nothing to
                                        ; close

            mov     rd, mv_dst_fcb
            call    K_FILE_CLOSE

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
            ; K_INMSG calls below -- see copy.asm's own identical note
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
            lbnz    mfc_cancelled       ; anything but Y/y: cancel

mfc_dst_check_done:
            ; --- open source (mode 0, read) ---
            mov     rf, src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source string
            mov     rd, mv_src_fcb      ; RD = our src_fcb struct
            mov     ra, mv_src_iobuf    ; RA = our src_iobuf buffer
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified)
            lbdf    mfc_src_not_found

            ; --- open destination (mode 1, create-or-overwrite) ---
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination string
            mov     rd, mv_dst_fcb      ; RD = our dst_fcb struct (same
                                        ; memory as the existence check
                                        ; above -- already closed there)
            mov     ra, mv_dst_iobuf    ; RA = our dst_iobuf buffer
            ldi     1                   ; mode = write
            call    K_FILE_OPEN         ; DF=0/1 (D unspecified)
            lbdf    mfc_dst_open_error

;------------------------------------------------------------------
; Copy loop: read a chunk from source, write the same chunk (exact
; byte count K_FILE_READ actually returned) to destination. Identical
; shape to COPY's own co_copy_loop.
;------------------------------------------------------------------
mfc_copy_loop:
            mov     rf, move_buf
            ldi     low MOVE_CHUNK_LEN
            plo     rc
            ldi     high MOVE_CHUNK_LEN
            phi     rc                  ; RC = chunk size requested
            mov     rd, mv_src_fcb      ; RD = FCB pointer (fixed --
                                        ; RF stays pointed at move_buf)
            call    K_FILE_READ         ; RC = bytes actually read
            lbdf    mfc_read_error

            glo     rc
            lbnz    mfc_have_bytes
            ghi     rc
            lbz     mfc_copy_done       ; 0 bytes read: source EOF
mfc_have_bytes:
            mov     rf, move_buf        ; RF = source buffer (RC still
                                        ; holds the byte count)
            mov     rd, mv_dst_fcb      ; RD = FCB pointer (fixed)
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    mfc_write_error

            lbr     mfc_copy_loop

mfc_copy_done:
            mov     rd, mv_src_fcb
            call    K_FILE_CLOSE
            mov     rd, mv_dst_fcb
            call    K_FILE_CLOSE

            ; --- data now safely at the new location: delete the
            ; original ---
            mov     rf, src_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = src_ptr's string
                                        ; pointer (staged, RF is about
                                        ; to be loaded fresh)
            mov     rf, r8              ; RF = source path
            call    K_FILE_DELETE       ; DF = 0/1
            lbdf    mfc_delete_failed

            clc
            rtn

mfc_delete_failed:
            call    K_INMSG
            db      "Moved data but could not delete source file.",13,10,0
            stc
            rtn

mfc_read_error:
            mov     rd, mv_src_fcb
            call    K_FILE_CLOSE
            mov     rd, mv_dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            stc
            rtn

mfc_write_error:
            mov     rd, mv_src_fcb
            call    K_FILE_CLOSE
            mov     rd, mv_dst_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            stc
            rtn

mfc_dst_open_error:
            mov     rd, mv_src_fcb
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            stc
            rtn

mfc_src_not_found:
            call    K_INMSG
            db      "Source file not found (or is a directory -- a directory can only be moved within the same drive/directory).",13,10,0
            stc
            rtn

mfc_cancelled:
            clc                         ; declining an overwrite is
                                        ; NOT an error -- silent, per
                                        ; this project's "no news is
                                        ; good news" convention
            rtn

move_argv:      dw      0
move_argc:      db      0
num_sources:    db      0
move_i:         db      0
any_error:      db      0
dst_is_dir_flag: db     0
src_ptr:        dw      0
dst_ptr:        dw      0
real_dst:       dw      0

; CALLER-ALLOCATED FCBs (2026-07-15), FCB POINTER IS THE HANDLE
; (2026-07-21) -- same convention as COPY's own src_fcb/dst_fcb, given
; a distinct "mv_" prefix to avoid any confusion with anything in
; lib/move.asm (a completely separate file/link unit -- though as of
; the 2026-07-23 redesign, move_rename itself is stateless and owns no
; scratch of its own at all).
mv_src_fcb:     ds      FCB_LEN
mv_src_iobuf:   ds      FCB_IOBUF_LEN
mv_dst_fcb:     ds      FCB_LEN
mv_dst_iobuf:   ds      FCB_IOBUF_LEN

dstchk_arg:     dw      0
dstchk_result:  ds      DIRENT_LEN
dst_final:      ds      DST_BUF_LEN
answer_char:    db      0
move_buf:       ds      MOVE_CHUNK_LEN

            end     start
