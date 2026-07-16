;
; ren.asm - rename a file or directory
;
; Usage: REN <path> <newname>
;
; Same-directory rename only -- <newname> must be a bare name (no
; path separators); it always applies within <path>'s own parent
; directory (no cross-directory move). <path> may be a full path,
; e.g. "REN /cfg/old.dat new.dat" -- resolved internally by
; K_FILE_RENAME (see K_PATH_RESOLVE). Works on either a file or a
; directory.
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
            ; program's own name; argv[1] = path, argv[2] = newname --
            ; the shell's own tokenizer already handles quoting/
            ; escaping and multiple/trailing spaces, so no hand-rolled
            ; splitting is needed here anymore. No call happens between
            ; reading both arguments and using them, so both go
            ; straight into the registers K_FILE_RENAME itself expects
            ; with no memory stash needed.
            glo     rc
            smi     3
            lbnf    usage_error         ; argc < 3: path and/or newname
                                        ; missing

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (path)

            mov     rb, ra
            add16   rb, 4               ; RB = &argv[2]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[2] (newname)

            call    K_FILE_RENAME       ; DF = 0/1
            lbdf    ren_error

            call    K_INMSG
            db      "Renamed.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

ren_error:
            call    K_INMSG
            db      "Cannot rename (not found, name already exists, or invalid).",13,10,0
            ldi     1
            rtn

usage_error:
            call    K_INMSG
            db      "Usage: REN <path> <newname>",13,10,0
            ldi     1
            rtn

            end     start
