;
; errorlevel.asm - print the last command's exit code
;
; Usage: ERRORLEVEL
;
; Lives in test/, not progs/: it always prints exactly what "echo
; %ERRORLEVEL%" already would (and %ERRORLEVEL% is strictly more
; flexible -- inline in any command, usable inside batch scripts), so
; it isn't something a normal install needs day to day. What it's
; actually for is proving K_GET_ERRORLEVEL itself works: it's the one
; call site that goes through the real jump-table API rather than
; reading RUN_ERRORLEVEL directly the way the shell's own
; %ERRORLEVEL% substitution (progs/shell.asm's tokenizer) does as
; internal plumbing -- exercising the path any FUTURE program would
; use to branch on the previous exit code programmatically, even
; though nothing does that yet. No-argument utility, same shape as
; progs/ver.asm's own version print.
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
