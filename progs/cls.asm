;
; cls.asm - Clear the screen with ANSI control codes.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

;------------------------------------------------------------------
; 6-byte program header (mirrors the kernel's own header convention)
;------------------------------------------------------------------
            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            call    K_INMSG
            db      27,'[H',27,'[J',0

            ldi     0                   ; exit code 0 = success
            rtn

            end     start
