;
; cd.asm - change the current directory
;
; Usage: CD <path>
;        CD ..            -- parent directory (the '..' entry already
;                             stores the correct parent cluster, 0 for
;                             the FAT16 root, so no special-casing needed)
;        CD /cfg/sub       -- absolute, multi-component path
;        CD cfg/sub        -- relative, multi-component path
;        CD /               -- root
;
; Path resolution (leading '/' = absolute, '.'/'..' handled as real
; directory entries, multi-component walking) is done by
; K_PATH_RESOLVE -- see include/kernel_api.inc. CD only has to search
; the resolved parent directory for the final component and confirm
; it's a directory, exactly as before path support existed.
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
            ; RA = command tail = the path argument
            ldn     ra
            lbnz    have_arg

            call    K_INMSG
            db      "Usage: CD <directory>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_arg:
            call    K_GETCURDIR         ; RD = current directory cluster
            mov     rf, ra              ; RF = path argument
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, DF = 0/1
            lbdf    not_found           ; bad intermediate component

            ; an empty final component means the path itself named
            ; the target directory ("/", "cfg/", ...) -- the resolved
            ; parent cluster IS the target, no further lookup needed
            ldn     rf
            lbnz    have_component
            call    K_SETCURDIR         ; RD unchanged since K_PATH_RESOLVE
            ldi     0
            rtn

have_component:
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
