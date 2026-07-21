;
; export.asm - set environment variables (matches bash's export, for
; the most part)
;
; Usage: EXPORT [name[=value] ...]
;
; No arguments: lists every variable currently set, one per line, as
; "NAME=VALUE" -- same listing as PRINTENV's own no-args case (real
; bash's bare "export" uses a fancier "declare -x NAME=\"VALUE\""
; format; this project uses the simpler plain format for both
; commands instead, a deliberate simplification).
;
; One or more "name[=value]" arguments:
;   name=value  -- sets the variable, always overwriting any existing
;                  value (matches bash's own export NAME=VALUE). The
;                  value may itself contain '=' -- only the FIRST '='
;                  in the token is the separator, matching bash.
;   name        -- (no '=') creates the variable with an empty value
;                  ONLY IF it isn't already set; leaves an existing
;                  value untouched. Matches bash's own "export
;                  EXISTING_VAR" not clobbering an already-exported
;                  variable's value.
; Exits 1 if any of the given tokens failed (a name containing '=' in
; its own NAME portion, which can't happen here since export.asm
; itself splits on the first '=' before ever calling env_setenv -- so
; in practice this only fires if the underlying temp-file create/
; rename fails), otherwise 0.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   env_setenv
            extrn   env_split_line
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
            mov     rb, ex_argv
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; ex_argv = RA

            mov     rb, ex_failed
            ldi     0
            str     rb                  ; ex_failed = 0

            glo     rc
            smi     2
            lbnf    ex_list_all         ; argc < 2: no args given

            mov     rb, ex_remaining
            glo     rc
            smi     1
            str     rb                  ; ex_remaining = argc - 1

            mov     rb, ex_cur_off
            ldi     0
            str     rb
            inc     rb
            ldi     2
            str     rb                  ; ex_cur_off = 2 (skip argv[0])

ex_loop:
            mov     rf, ex_argv
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv base
            mov     rf, ex_cur_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = cur_off
            mov     rf, r9
            add16   rf, r8              ; RF = &argv[i]
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = argv[i] (token ptr)

            mov     rb, ex_name
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb                  ; ex_name = token (stashed
                                        ; BEFORE env_split_line
                                        ; advances/clobbers RF -- see
                                        ; its own contract, RF no
                                        ; longer points at the start
                                        ; of the name once it returns)

            mov     rf, r8
            call    env_split_line      ; RD = value ptr or 0
            ghi     rd
            lbnz    ex_have_eq
            glo     rd
            lbz     ex_no_eq

ex_have_eq:
            mov     rb, ex_value
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb                  ; ex_value = value (stash --
                                        ; reloading ex_name below
                                        ; doesn't touch RD, but stash
                                        ; anyway for a uniform reload
                                        ; right before the call)

            mov     rf, ex_name
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = name (reloaded fresh)

            mov     rd, ex_value
            lda     rd
            phi     r8
            ldn     rd
            plo     r8
            mov     rd, r8              ; RD = value (reloaded fresh)

            ldi     1                   ; overwrite=1 -- set LAST
                                        ; (mov clobbers D, gotcha #4)
            call    env_setenv
            lbdf    ex_mark_failed
            lbr     ex_advance

ex_no_eq:
            mov     rf, ex_name
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF = name (reloaded fresh)

            mov     rd, ex_empty        ; RD = empty-string constant
            ldi     0                   ; overwrite=0 -- set LAST
            call    env_setenv
            lbdf    ex_mark_failed
            lbr     ex_advance

ex_mark_failed:
            mov     rb, ex_failed
            ldi     1
            str     rb

ex_advance:
            mov     rf, ex_cur_off
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, 2
            mov     rf, ex_cur_off
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; ex_cur_off += 2

            mov     rf, ex_remaining
            ldn     rf
            smi     1
            str     rf                  ; ex_remaining--
            lbnz    ex_loop

            mov     rb, ex_failed
            ldn     rb
            lbnz    ex_exit_err
            ldi     0
            rtn

ex_exit_err:
            ldi     1
            rtn

;------------------------------------------------------------------
; ex_list_all: no args given -- print every "NAME=VALUE" line.
;------------------------------------------------------------------
ex_list_all:
            call    env_first
ex_list_loop:
            ghi     rf
            lbnz    ex_list_print
            glo     rf
            lbz     ex_list_done
ex_list_print:
            call    K_MSG               ; RF = the raw line
            call    K_INMSG
            db      13,10,0
            call    env_next
            lbr     ex_list_loop

ex_list_done:
            ldi     0
            rtn

ex_argv:        dw      0
ex_failed:      db      0
ex_remaining:   db      0
ex_cur_off:     dw      0
ex_name:        dw      0
ex_value:       dw      0
ex_empty:       db      0

            end     start
