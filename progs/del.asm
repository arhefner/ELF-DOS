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
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1] is the filename argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no filename given

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (filename)
            call    K_FILE_DELETE       ; DF = 0/1
            lbdf    del_error

            call    K_INMSG
            db      "File deleted.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

usage:
            call    K_INMSG
            db      "Usage: DEL <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

del_error:
            call    K_INMSG
            db      "Cannot delete file (not found, or is a directory).",13,10,0
            ldi     1
            rtn

            end     start
