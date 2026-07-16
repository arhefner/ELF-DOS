;
; template.asm - starting point for a new ELF-DOS program
;
; Copy this file to begin a new program (it isn't built by "make
; progs" itself -- see the Makefile's PROG_SRCS filter):
;   cp progs/template.asm progs/mynewprog.asm
;
; A program is loaded via prog_run (see kernel/loader.asm) at the
; fixed address PROG_BASE (see include/kernel_api.inc for its current
; value). Its entry point is always PROG_BASE + $06, immediately after
; the 6-byte header below.
;
; At entry:
;   RA = pointer to the argv table -- an array of RC 16-bit big-endian
;        pointers, argv[0..argc-1], each to a null-terminated string.
;        argv[0] is the program's own invocation name (matching C's
;        main(argc, argv) convention). Arguments are split by the
;        shell with quoting ("..." keeps embedded spaces in one
;        token) and backslash-escaping (\X -> literal X, inside or
;        outside quotes).
;   RC = argc (word) -- always >= 1 on a successful hand-off, since
;        argv[0] is always present.
;   R2 = kernel's stack pointer -- safe to use normally (call/rtn,
;        push/pop); the kernel restores it after the program exits
;        regardless of what happens in between.
;   D, DF, and every other register: undefined.
;
; Like any register, RA/RC are only guaranteed valid until the first
; kernel/BIOS call the program makes -- stash to memory (or another
; register) immediately if either is needed after that. To read
; argv[N] (N a small compile-time constant): compute its address as
; RA + N*2 (add16 supports a constant operand), then dereference the
; 2-byte pointer stored there with the standard lda/phi/ldn/plo
; sequence, e.g. for argv[1]:
;   mov     rb, ra
;   add16   rb, 2               ; RB = &argv[1]
;   lda     rb
;   phi     rf
;   ldn     rb
;   plo     rf                  ; RF = argv[1]
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
