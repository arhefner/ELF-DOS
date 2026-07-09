;
; md.asm - create a new, empty subdirectory
;
; Usage: MD <path>
;
; Single-level only: the parent must already exist (no implicit
; intermediate directory creation, matching classic DOS MD). <path>
; may be a full path, e.g. "MD /cfg/new" -- resolved internally by
; K_DIR_CREATE (see K_PATH_RESOLVE).
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
            db      "Usage: MD <path>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = path
            call    K_DIR_CREATE        ; DF = 0/1
            lbdf    md_error

            call    K_INMSG
            db      "Directory created.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

md_error:
            call    K_INMSG
            db      "Cannot create directory (already exists, bad path, or disk full).",13,10,0
            ldi     1
            rtn

            end     start
