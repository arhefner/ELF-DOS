;
; template.asm - starting point for a new ELF-DOS program
;
; Copy this file to begin a new program (it isn't built by "make
; progs" itself -- see the Makefile's PROG_SRCS filter):
;   cp progs/template.asm progs/mynewprog.asm
;
; A program is loaded via prog_load/prog_exec (see kernel/loader.asm)
; at the fixed address PROG_BASE ($2000). Its entry point is always
; PROG_BASE + $06, immediately after the 6-byte header below.
;
; At entry:
;   RA = pointer to the null-terminated command tail -- everything
;        typed after the program's own name, trimmed (an empty
;        string, not a null pointer, if no arguments were given).
;        Save it somewhere if you need it after making any kernel/
;        BIOS call, since those may clobber RA.
;   R2 = kernel's stack pointer -- safe to use normally (call/rtn,
;        push/pop); the kernel restores it after the program exits
;        regardless of what happens in between.
;   D, DF, and every other register: undefined.
;
; To exit, just 'rtn' back to the kernel -- D = exit code by
; convention (0 = success; other values are program-defined; no
; specific non-zero codes are reserved yet).
;
; #include kernel_api.inc, not kernel.inc -- kernel.inc is for the
; kernel's own internal structures (FCB/BPB/directory-entry layout),
; which can change across kernel updates; kernel_api.inc is the
; stable, program-facing surface (K_xxx kernel/BIOS calls, PROG_BASE,
; LOADER_ARGS). See that file for the full call list and conventions.
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
            db      "Hello from ELF-DOS!",13,10,0

            ldi     0                   ; exit code 0 = success
            rtn

            end     start
