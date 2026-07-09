;
; rd.asm - remove an empty subdirectory
;
; Usage: RD <path>
;
; Refuses non-empty directories (no recursive delete), "."/"..", and
; the root itself. <path> may be a full path, e.g. "RD /cfg/old" --
; resolved internally by K_DIR_REMOVE (see K_PATH_RESOLVE).
;

#include    include/opcodes.def
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = command tail = the directory name/path argument
            ldn     ra
            lbnz    have_name

            call    K_INMSG
            db      "Usage: RD <path>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = path
            call    K_DIR_REMOVE        ; DF = 0/1
            lbdf    rd_error

            call    K_INMSG
            db      "Directory removed.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

rd_error:
            call    K_INMSG
            db      "Cannot remove directory (not found, not empty, or invalid).",13,10,0
            ldi     1
            rtn

            end     start
