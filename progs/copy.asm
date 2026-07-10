;
; copy.asm - copy a file
;
; Usage: COPY <source> <destination>
;
; Single file to single file only -- no wildcards, no directory
; trees. <source> must already exist (opened mode 0, read). Both
; arguments may be full paths, e.g. "COPY /cfg/env.dat backup.dat"
; -- K_FILE_OPEN already resolves paths internally (see
; K_PATH_RESOLVE), so nothing special is needed here for that.
;
; If <destination> is an existing directory, the source is copied
; into it under its own basename (e.g. "COPY ../foo ." copies to
; "./foo") -- checked via the same K_PATH_RESOLVE/K_DIR_OPEN/
; K_DIR_READ/ATTR_DIR pattern CD uses to recognize a directory.
;
; If the resolved destination file already exists, the user is
; prompted to confirm the overwrite (Y/N -- anything but Y/y
; cancels); otherwise it's created directly, same as WTEST.
;
; Copying a file onto itself is not specially detected or guarded
; against -- it will open the same file twice, for read and write
; simultaneously, and produce garbled results (this hardware's
; single shared io_buf sector cache means only one FCB's sector can
; be resident at a time). Don't do that.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

COPY_CHUNK_LEN: equ     64
DST_BUF_LEN:    equ     132

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = command tail = "<source> <destination>"
            ldn     ra
            lbz     usage_error

            ; find the space separating the two arguments
            mov     rf, ra
scan_src_end:
            ldn     rf
            lbz     usage_error         ; only one token: no destination
            xri     ' '
            lbz     have_src_end
            inc     rf
            lbr     scan_src_end
have_src_end:
            ldi     0
            str     rf                  ; null-terminate source in place
            inc     rf

            ; skip any additional spaces before the destination
skip_spaces:
            ldn     rf
            xri     ' '
            lbnz    have_dst
            inc     rf
            lbr     skip_spaces
have_dst:
            ldn     rf
            lbz     usage_error         ; nothing after the spaces

            ; save both pointers in memory: RA is still the (now
            ; null-terminated) source string, RF the destination
            ; string; both get clobbered by the K_FILE_OPEN calls
            ; below, so neither can stay in a register
            mov     rb, src_ptr
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; src_ptr = source string pointer

            mov     rb, dst_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; dst_ptr = destination string ptr

;------------------------------------------------------------------
; If dst_ptr names an existing directory, redirect the real
; destination to <dst_ptr>/<basename of src_ptr> instead. real_dst
; defaults to dst_ptr unchanged; only overwritten if this check
; confirms a directory.
;------------------------------------------------------------------
            mov     rb, real_dst
            mov     rf, dst_ptr
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; real_dst = dst_ptr (default)

            ; load dst_ptr's string value into RC before K_GETCURDIR
            ; clobbers RD
            mov     rf, dst_ptr
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = destination string pointer

            call    K_GETCURDIR         ; RD = current directory cluster
            mov     rf, rc              ; RF = destination path
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, DF = 0/1
            lbdf    dst_not_dir         ; bad intermediate component

            ; an empty final component means dst_ptr itself named a
            ; directory ("/", "cfg/", ...) -- no further lookup needed
            ldn     rf
            lbz     dst_is_dir

            ; save the final-component pointer in memory: K_DIR_READ
            ; clobbers R9/RA/RB/RC/RD/RF internally, so nothing
            ; survives in a register across the search loop below
            mov     rb, dstchk_arg
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE
            call    K_DIR_OPEN

dstchk_loop:
            mov     rf, dstchk_result
            call    K_DIR_READ
            lbdf    dst_not_dir         ; end of directory: no match,
                                        ; dst_ptr doesn't exist as this
                                        ; name -- not a directory

            mov     rf, dstchk_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, dstchk_result
            call    f_strcmp
            lbnz    dstchk_loop         ; no match: keep looking

            ; found it -- must be a directory
            mov     rf, dstchk_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     dst_not_dir         ; exists but is a file

dst_is_dir:
            ; build dst_final = dst_ptr + '/' (if not already present)
            ; + basename(src_ptr), then point real_dst at it.
            ; BUG FIX: re-read dst_ptr fresh from memory here rather
            ; than relying on RC (stashed with dst_ptr's value earlier)
            ; to have survived -- K_PATH_RESOLVE's own header documents
            ; RC as one of its clobbered registers, so by this point
            ; (reached after a K_PATH_RESOLVE call, possibly also a
            ; K_DIR_OPEN/K_DIR_READ/f_strcmp chain) RC no longer holds
            ; what was stashed there before the call.
            mov     rf, dst_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = dst_ptr's string pointer
                                        ; (reloaded from memory)
            mov     rf, dst_final
copy_dst_loop:
            lda     rd
            lbz     copy_dst_done
            str     rf
            inc     rf
            lbr     copy_dst_loop
copy_dst_done:
            ; RF = one past the last copied char; peek the previous
            ; char to avoid a doubled '/' if dst_ptr already ends in one
            mov     r8, rf
            dec     r8
            ldn     r8
            xri     '/'
            lbz     have_sep
            ldi     '/'
            str     rf
            inc     rf
have_sep:
            ; find basename(src_ptr): scan forward, remembering the
            ; position right after the LAST '/' seen (defaults to the
            ; string's own start if none found). RF (dst_final's
            ; current write position, set above) must survive this
            ; whole block untouched -- BUG FIX: an earlier draft used
            ; RF itself as scratch for the src_ptr indirection load
            ; below, silently losing the write position (RF was left
            ; pointing at src_ptr+1, not dst_final's real position).
            ; RC is free here (not used anywhere in this block) so the
            ; indirection uses that instead.
            mov     rc, src_ptr
            lda     rc
            phi     rd
            ldn     rc
            plo     rd                  ; RD = source string pointer
            mov     r8, rd              ; R8 = scan pointer
            mov     r9, rd              ; R9 = basename pointer (updated
                                        ; on each '/' seen)
basename_scan:
            ldn     r8
            lbz     basename_done
            xri     '/'
            lbnz    basename_next
            inc     r8
            mov     r9, r8              ; R9 = position right after '/'
            lbr     basename_scan
basename_next:
            inc     r8
            lbr     basename_scan
basename_done:
            ; RF still holds dst_final's write position (from have_sep
            ; above -- not touched by the basename scan)
            mov     rd, r9              ; RD = basename source pointer
append_basename_loop:
            lda     rd
            str     rf
            lbz     append_basename_done
            inc     rf
            lbr     append_basename_loop
append_basename_done:

            mov     rb, real_dst
            mov     rf, dst_final
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; real_dst = dst_final

dst_not_dir:
; NOTE: reached two ways -- as an explicit jump target when dst_ptr
; is NOT a directory (real_dst still holds its default, dst_ptr
; unchanged), and by plain fallthrough right after the dst_is_dir
; block above finishes building dst_final and repointing real_dst at
; it. Either way, real_dst already holds the correct value by the
; time this runs.
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
            mov     rf, rd
            ldi     0                   ; mode = read (existence check)
            call    K_FILE_OPEN         ; D = FCB index, DF = 0/1
            lbdf    dst_check_done      ; not found (or a directory):
                                        ; proceed directly, nothing to
                                        ; close

            ; D still holds the FCB index K_FILE_OPEN just returned
            ; (lbdf above doesn't touch D) -- file_close takes it
            ; directly in D, not RF, so no stash/reload is even needed
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
            ; K_INMSG calls below -- this project only has R9's
            ; survival confirmed across f_msg/f_inmsg (CLAUDE.md
            ; gotcha #8), and neither call has been separately
            ; audited for any other register, so a register stash
            ; across THEM would be an unverified assumption. RC is
            ; only used here as a very short-lived stash to survive
            ; "mov rf, answer_char"'s own D-clobber (gotcha #4) --
            ; not across any call.
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
            lbnz    copy_cancelled      ; anything but Y/y: cancel

dst_check_done:
            ; --- open source (mode 0, read) ---
            mov     rf, src_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = source string
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    src_not_found

            plo     rd                  ; stash FCB index (mov below
                                        ; clobbers D)
            mov     rf, src_fcb
            glo     rd
            str     rf                  ; src_fcb = FCB index

            ; --- open destination (mode 1, create-or-overwrite) ---
            mov     rf, real_dst
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = destination string
            ldi     1                   ; mode = write
            call    K_FILE_OPEN         ; D = FCB index, DF=0/1
            lbdf    dst_open_error

            plo     rd
            mov     rf, dst_fcb
            glo     rd
            str     rf                  ; dst_fcb = FCB index

;------------------------------------------------------------------
; Copy loop: read a chunk from source, write the same chunk (exact
; byte count K_FILE_READ actually returned) to destination.
;------------------------------------------------------------------
copy_loop:
            mov     rf, copy_buf
            ldi     COPY_CHUNK_LEN
            plo     rc
            ldi     0
            phi     rc                  ; RC = chunk size requested
            mov     rd, src_fcb
            ldn     rd                  ; D = FCB index, RF untouched
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    read_error

            glo     rc
            lbnz    have_bytes
            ghi     rc
            lbz     copy_done           ; 0 bytes read: source EOF
have_bytes:
            mov     rf, copy_buf        ; RF = source buffer (RC still
                                        ; holds the byte count from
                                        ; K_FILE_READ -- mov only
                                        ; touches RF/D, not RC)
            mov     rd, dst_fcb
            ldn     rd                  ; D = FCB index, RF untouched
            call    K_FILE_WRITE        ; DF=0/1
            lbdf    write_error

            lbr     copy_loop

copy_done:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "File copied.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

read_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Read error.",13,10,0
            ldi     1
            rtn

write_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            mov     rd, dst_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Write error.",13,10,0
            ldi     1
            rtn

dst_open_error:
            mov     rd, src_fcb
            ldn     rd
            call    K_FILE_CLOSE
            call    K_INMSG
            db      "Cannot create destination.",13,10,0
            ldi     1
            rtn

src_not_found:
            call    K_INMSG
            db      "Source file not found.",13,10,0
            ldi     1
            rtn

copy_cancelled:
            call    K_INMSG
            db      "Copy cancelled.",13,10,0
            ldi     0                   ; exit code 0 -- user's own choice,
                                        ; not an error
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: COPY <source> <destination>",13,10,0
            ldi     1
            rtn

src_ptr:    dw      0
dst_ptr:    dw      0
real_dst:   dw      0
src_fcb:    db      0
dst_fcb:    db      0
dstchk_arg: dw      0
dstchk_result: ds   DIRENT_LEN
dst_final:  ds      DST_BUF_LEN
answer_char: db     0
copy_buf:   ds      COPY_CHUNK_LEN

            end     start
