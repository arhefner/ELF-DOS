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
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1] is the path argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no path given

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (path)
            call    K_DIR_REMOVE        ; DF = 0/1
            lbdf    rd_error

            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention (2026-07-21)
            rtn

usage:
            call    K_INMSG
            db      "Usage: RD <path>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

rd_error:
            call    K_INMSG
            db      "Cannot remove directory (not found, not empty, or invalid).",13,10,0
            ldi     1
            rtn

            end     start
