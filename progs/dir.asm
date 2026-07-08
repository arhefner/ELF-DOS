;
; dir.asm - list a directory
;
; Usage: DIR [path]
;
; With no argument, lists the current directory. With a path argument
; (bare name, relative path, or absolute path starting with '/'),
; lists that directory instead -- without changing the current
; directory, since K_DIR_OPEN/K_DIR_READ only drive this program's
; own listing traversal and never touch cur_dir (only CD's
; K_SETCURDIR does that). See K_PATH_RESOLVE in kernel_api.inc.
;
; Each entry is printed as a fixed-width line:
;   columns 1-5:   right-justified decimal byte count (files) or
;                  blank (directories) -- low 16 bits only, since
;                  this hardware's RAM makes files over 64K moot,
;                  see kernel/file.asm's own FCB_FSIZE/FCB_FPOS
;                  ceiling
;   columns 6-12:  " <DIR> " for subdirectories, blank for files
;   columns 13+:   the file/directory name
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
            call    K_GETCURDIR         ; RD = current directory cluster

            ldn     ra                  ; D = first byte of command tail
            lbz     dir_open_target     ; empty: list current directory

            mov     rf, ra              ; RF = path argument
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

            ; must be a directory
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     not_dir

            ; RD = the matched entry's first cluster -- falls through
            ; to dir_open_target below, same as the "empty final
            ; component" shortcuts above
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd

dir_open_target:
            call    K_DIR_OPEN

dir_loop:
            mov     rf, dir_result      ; RF = result buffer
            call    K_DIR_READ
            lbdf    dir_done            ; DF=1 = end of directory

            ; check ATTR_DIR bit
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbnz    dir_is_dir

            ; ---- file: right-justified 5-column decimal size ----
            mov     rf, dir_result
            add16   rf, DIRENT_SIZE
            add16   rf, 2               ; skip to the low word (bytes 2,3)
            lda     rf                  ; D = size byte 2 (low word MSB)
            phi     rd
            ldn     rf                  ; D = size byte 3 (low word LSB)
            plo     rd                  ; RD = size (0-65535)

            mov     rf, size_buf
            call    f_uintout           ; writes decimal ASCII into *rf, advances rf
            ldi     0
            str     rf                  ; null-terminate

            ; count digits written, to right-justify in 5 columns
            mov     rf, size_buf
            ldi     0
            plo     rc                  ; RC.0 = digit count
count_loop:
            ldn     rf
            lbz     count_done
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     count_loop
count_done:
            ; leading spaces = a substring of the 5-space buffer,
            ; starting "digit count" chars in (fewer spaces needed
            ; the more digits there are; always <= 5 digits since
            ; the value is at most 65535)
            mov     rf, spaces5
            add16   rf, rc
            call    K_MSG

            mov     rf, size_buf
            call    K_MSG               ; the digits themselves

            mov     rf, tag_blank       ; blank 7-column directory tag
            call    K_MSG
            lbr     dir_print_name

            ; ---- directory: blank size + " <DIR> " tag ----
dir_is_dir:
            mov     rf, spaces5         ; blank 5-column size field
            call    K_MSG
            mov     rf, dir_tag
            call    K_MSG

dir_print_name:
            mov     rf, dir_result      ; RF = DIRENT_NAME (at offset 0)
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     dir_loop

dir_done:
            ldi     0                   ; exit code 0 = success
            rtn

not_found:
            call    K_INMSG
            db      "Directory not found.",13,10,0
            ldi     1
            rtn

not_dir:
            call    K_INMSG
            db      "Not a directory.",13,10,0
            ldi     1
            rtn

arg_ptr:    dw      0
dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for K_DIR_READ
size_buf:   ds      6                   ; decimal size scratch (max "65535"+null)
spaces5:    db      "     ",0           ; 5 spaces -- blank size field, and
                                        ; (via pointer offset) padding
                                        ; source for right-justifying sizes
dir_tag:    db      " <DIR> ",0         ; 7-column directory tag
tag_blank:  db      "       ",0        ; 7 spaces -- blank tag field for files

            end     start
