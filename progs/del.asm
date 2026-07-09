;
; del.asm - delete a file
;
; Usage: DEL <filename>
;
; Refuses to delete directories -- use RD for those (once it exists).
; <filename> may be a full path, e.g. "DEL /cfg/old.dat" -- resolved
; internally by K_FILE_DELETE (see K_PATH_RESOLVE).
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
            ; RA = command tail = the filename argument
            ldn     ra
            lbnz    have_name

            call    K_INMSG
            db      "Usage: DEL <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            mov     rf, ra              ; RF = filename
            call    K_FILE_DELETE       ; DF = 0/1
            lbdf    del_error

            call    K_INMSG
            db      "File deleted.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

del_error:
            call    K_INMSG
            db      "Cannot delete file (not found, or is a directory).",13,10,0
            ldi     1
            rtn

            end     start
