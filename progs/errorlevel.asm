;
; errorlevel.asm - print the last command's exit code
;
; Usage: ERRORLEVEL
;
; No-argument utility, same shape as progs/ver.asm's own version print
; -- part of the ERRORLEVEL prelude to batch IF/GOTO (2026-07-25). Goes
; through K_GET_ERRORLEVEL rather than reading RUN_ERRORLEVEL's own
; fixed relay address directly: that address is kernel/shell-internal
; plumbing (same category as RUN_PATH), and an ordinary program
; shouldn't bake it into its own compiled binary -- the exact mistake
; the argv/argc ABI redesign already moved away from. The shell's own
; %ERRORLEVEL% substitution (progs/shell.asm's tokenizer) IS the direct
; consumer that reads RUN_ERRORLEVEL itself, as internal plumbing; this
; utility exists for interactive/scripted use where %ERRORLEVEL% isn't
; convenient (e.g. piping its output, or before %ERRORLEVEL% expansion
; existed at all).
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
            call    K_GET_ERRORLEVEL    ; D = last command's exit code
                                        ; (0-255), DF = 0 always
            plo     rd
            ldi     0
            phi     rd                  ; RD = value (zero-extended)

            mov     rf, el_buf
            call    f_uintout           ; writes decimal ASCII into
                                        ; *rf, advances rf
            ldi     0
            str     rf                  ; null-terminate

            mov     rf, el_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            ldi     0                   ; exit code 0 = success --
                                        ; displaying the value isn't
                                        ; itself an error
            rtn

el_buf:     ds      6                   ; decimal scratch (max "255"+null)

            end     start
