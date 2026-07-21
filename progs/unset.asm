;
; unset.asm - remove environment variables (matches bash's unset)
;
; Usage: UNSET name [name2 ...]
;
; Removes each named variable. A name that was never set is a silent
; no-op (matches bash's own idempotent unset). Unlike bash (whose
; bare "unset" with no names is itself a silent no-op), a bare UNSET
; here is a usage error -- matching this project's own established
; convention for a missing required argument (DEL/REN/MD/RD all do
; the same).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   env_unsetenv

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no names given

            mov     rb, un_argv
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; un_argv = RA

            mov     rb, un_failed
            ldi     0
            str     rb                  ; un_failed = 0

            mov     rb, un_remaining
            glo     rc
            smi     1
            str     rb                  ; un_remaining = argc - 1

            mov     rb, un_cur_off
            ldi     0
            str     rb
            inc     rb
            ldi     2
            str     rb                  ; un_cur_off = 2 (skip argv[0])

un_loop:
            mov     rf, un_argv
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv base
            mov     rf, un_cur_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = cur_off
            mov     rf, r9
            add16   rf, r8              ; RF = &argv[i]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = argv[i] (name ptr)

            mov     rf, r8
            call    env_unsetenv        ; DF = 0/1
            lbnf    un_advance

            mov     rb, un_failed
            ldi     1
            str     rb

un_advance:
            mov     rf, un_cur_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, 2
            mov     rf, un_cur_off
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; un_cur_off += 2

            mov     rf, un_remaining
            ldn     rf
            smi     1
            str     rf                  ; un_remaining--
            lbnz    un_loop

            mov     rb, un_failed
            ldn     rb
            lbnz    un_exit_err
            ldi     0
            rtn

un_exit_err:
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: UNSET name [name2 ...]",13,10,0
            ldi     1
            rtn

un_argv:        dw      0
un_failed:      db      0
un_remaining:   db      0
un_cur_off:     dw      0

            end     start
