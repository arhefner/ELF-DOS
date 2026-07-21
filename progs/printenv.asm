;
; printenv.asm - print environment variables (matches Linux printenv)
;
; Usage: PRINTENV [name...]
;
; No arguments: lists every variable currently set, one per line, as
; "NAME=VALUE" (matches GNU printenv's own no-args listing). If
; /cfg/env.dat doesn't exist yet, prints nothing and exits 0 (an
; empty environment, not an error).
;
; One or more names given: prints each named variable's VALUE alone
; (no "NAME=" prefix), one per line, in the order given. A name that
; isn't set is silently skipped (matches GNU printenv -- no error
; message per missing name); if ANY name was missing, exit code is 1,
; otherwise 0.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   env_getenv
            extrn   env_first
            extrn   env_next

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc at entry -- stash both
            ; immediately (env_getenv's own broad clobber footprint
            ; means neither survives a call).
            mov     rb, pe_argv
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; pe_argv = RA

            mov     rb, pe_missing
            ldi     0
            str     rb                  ; pe_missing = 0

            glo     rc
            smi     2
            lbnf    pe_list_all         ; argc < 2: no names given

            mov     rb, pe_remaining
            glo     rc
            smi     1
            str     rb                  ; pe_remaining = argc - 1

            mov     rb, pe_cur_off
            ldi     0
            str     rb
            inc     rb
            ldi     2
            str     rb                  ; pe_cur_off = 2 (byte offset
                                        ; into argv, skipping argv[0]
                                        ; -- the program's own name)

pe_loop:
            mov     rf, pe_argv
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv base
            mov     rf, pe_cur_off
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
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    pe_print_value
            glo     rf
            lbz     pe_not_found

pe_print_value:
            call    K_MSG               ; RF still = value pointer
            call    K_INMSG
            db      13,10,0
            lbr     pe_advance

pe_not_found:
            mov     rb, pe_missing
            ldi     1
            str     rb

pe_advance:
            mov     rf, pe_cur_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, 2
            mov     rf, pe_cur_off
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; pe_cur_off += 2

            mov     rf, pe_remaining
            ldn     rf
            smi     1
            str     rf                  ; pe_remaining--
            lbnz    pe_loop             ; still > 0: continue

            mov     rb, pe_missing
            ldn     rb
            lbnz    pe_exit_err
            ldi     0
            rtn

pe_exit_err:
            ldi     1
            rtn

;------------------------------------------------------------------
; pe_list_all: no names given -- print every "NAME=VALUE" line.
;------------------------------------------------------------------
pe_list_all:
            call    env_first
pe_list_loop:
            ghi     rf
            lbnz    pe_list_print
            glo     rf
            lbz     pe_list_done
pe_list_print:
            call    K_MSG               ; RF = the raw line
            call    K_INMSG
            db      13,10,0
            call    env_next
            lbr     pe_list_loop

pe_list_done:
            ldi     0
            rtn

pe_argv:        dw      0
pe_missing:     db      0
pe_remaining:   db      0
pe_cur_off:     dw      0

            end     start
