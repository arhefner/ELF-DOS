;
; dir.asm - list the current directory
;
; Usage: DIR
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

dir_result: ds      DIRENT_LEN          ; 135-byte result buffer for K_DIR_READ
size_buf:   ds      6                   ; decimal size scratch (max "65535"+null)
spaces5:    db      "     ",0           ; 5 spaces -- blank size field, and
                                        ; (via pointer offset) padding
                                        ; source for right-justifying sizes
dir_tag:    db      " <DIR> ",0         ; 7-column directory tag
tag_blank:  db      "       ",0        ; 7 spaces -- blank tag field for files

            end     start
