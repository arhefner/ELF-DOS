;
; args.asm - print argv, one entry per line
;
; Usage: ARGS [anything...]
;
; Prints every element of argv, including argv[0] (this program's own
; invocation name), one per line, with no other formatting -- a direct
; way to see exactly what the shell's tokenizer produced (quoting,
; backslash-escaping, whitespace splitting) without guessing from a
; program that does something else with its arguments. See
; include/kernel_api.inc's "Command line" section for the argv/argc
; convention this reads.
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
            ; RA = argv pointer, RC = argc. Stash both to memory
            ; immediately -- neither is guaranteed to survive the
            ; K_MSG/K_INMSG calls in the loop below (gotcha #8: assume
            ; clobbered unless proven otherwise), so the loop re-reads
            ; everything fresh from memory each iteration rather than
            ; trusting any register across a call.
            mov     rf, args_argc
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            mov     rf, args_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, args_i
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; args_i = 0

args_loop:
            mov     rf, args_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = args_i
            mov     rf, args_argc
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = argc

            ; args_i >= argc ?
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    args_done           ; DF=1: args_i >= argc, done

            ; &argv[args_i] = args_argv + args_i*2 -- RD still holds
            ; args_i untouched (the comparison above only touches D)
            shl16   rd                  ; RD = args_i * 2
            mov     rf, args_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = argv (base pointer)
            add16   rb, rd              ; RB = &argv[args_i]

            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[args_i]
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, args_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, args_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; args_i++

            lbr     args_loop

args_done:
            ldi     0                   ; exit code 0 = success
            rtn

args_argc:  dw      0
args_argv:  dw      0
args_i:     dw      0

            end     start
