;
; mem.asm - print the current top-of-memory address and how much
; program+data space remains above PROG_BASE
;
; Usage: MEM
;
; mem_top (read fresh from LOADER_ARGS+2 -- see kernel_api.inc) is
; the last usable RAM byte for THIS specific run, not a fixed
; constant: it shrinks whenever something reserves space out of high
; memory for the duration of one command, via the kernel's own
; _himem_reserve mechanism (kernel/redir.asm) -- the loadable batch
; module (kernel/batch_mod.asm, reserved for as long as a .bat script
; is running, via K_BATCH_START) and a dual-redirect's second
; FCB+iobuf pair (needed only when a single command redirects BOTH
; input and output at once) both carve their own space out of high
; memory this same way, then give it back once no longer needed.
; Running MEM from inside a .bat script, or with both stdin and
; stdout redirected on the same command line, is expected to print a
; SMALLER "available" figure than running it plain and interactively
; -- that's the intended behavior, not a bug: this command's whole
; job is showing the real, current budget a program actually has
; right now, not a fixed build-time constant.
;
; "Available" is computed as the plain difference mem_top - PROG_BASE
; (both are absolute addresses; mem_top is the highest usable byte,
; PROG_BASE is the lowest a program/its data can use), matching
; kernel/loader.asm's own _prog_finish_load, which computes a loaded
; program's own available space the exact same way.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; mem_top = LOADER_ARGS word 1 (word 0 is mem_base, not
            ; needed here) -- read fresh every run, never cached,
            ; since it's only meaningful for THIS specific invocation
            ; (see this file's own header comment)
            mov     rf, LOADER_ARGS
            add16   rf, 2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            mov     rb, mem_top_val
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; mem_top_val = mem_top

            call    K_INMSG
            db      "Top of memory:               ",0

            mov     rf, mem_top_val
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, mem_buf
            call    f_uintout           ; writes decimal ASCII into
                                        ; *rf, advances rf
            ldi     0
            str     rf                  ; null-terminate
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            call    K_INMSG
            db      "PROG_BASE:                   ",0

            ldi     high PROG_BASE
            phi     rd
            ldi     low PROG_BASE
            plo     rd
            mov     rf, mem_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      13,10,0

            ; available = mem_top - PROG_BASE (plain difference,
            ; matching kernel/loader.asm's own _prog_finish_load).
            ; sub16 with an immediate constant expands to SMI/SMBI --
            ; it never touches M(R2), so this is safe regardless of
            ; what precedes it (gotcha #18 only applies to the
            ; register-register form).
            mov     rf, mem_top_val
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            sub16   rd, PROG_BASE       ; RD = mem_top - PROG_BASE

            call    K_INMSG
            db      "Available for program+data:  ",0

            mov     rf, mem_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, mem_buf
            call    K_MSG

            call    K_INMSG
            db      " bytes",13,10,0

            ldi     0                   ; exit code 0 = success
            rtn

mem_top_val:    dw      0
mem_buf:        ds      6               ; decimal scratch (max
                                        ; "65535"+null)

            end     start
