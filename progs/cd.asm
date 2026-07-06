;
; cd.asm - change the current directory
;
; Usage: CD <name>
;        CD ..   -- parent directory (the '..' entry already stores
;                    the correct parent cluster, 0 for the FAT16
;                    root, so no special-casing needed)
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
            ; RA = command tail = the directory name argument
            ldn     ra
            lbnz    have_arg

            call    K_INMSG
            db      "Usage: CD <directory>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_arg:
            ; the argument pointer must be stashed in memory, not a
            ; register: K_DIR_READ uses R9/RA/RB/RC/RD/RF internally
            ; (see kernel/dir.asm), so nothing in a register would
            ; survive the search loop below.
            mov     rd, ra
            mov     rf, arg_ptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; arg_ptr = argument pointer

            call    K_GETCURDIR         ; RD = current directory cluster
            call    K_DIR_OPEN

cd_loop:
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
            lbnz    cd_loop             ; no match: keep looking

            ; must be a directory
            mov     rf, dir_result
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_DIR
            lbz     not_dir

            ; set the current directory to the entry's first cluster
            mov     rf, dir_result
            add16   rf, DIRENT_CLUST
            lda     rf                  ; D = cluster high byte
            phi     rd
            ldn     rf                  ; D = cluster low byte
            plo     rd
            call    K_SETCURDIR

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

            end     start
