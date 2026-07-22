;
; del.asm - delete one or more files
;
; Usage: DEL <filename> [filename...]
;
; Refuses to delete directories -- use RD for those (once it exists).
; Each <filename> may be a full path, e.g. "DEL /cfg/old.dat" --
; resolved internally by K_FILE_DELETE (see K_PATH_RESOLVE). Multiple
; filenames are deleted independently: a failure on one prints its own
; error and moves on to the next (matching this project's batch-script
; precedent of "print the error, advance" rather than aborting the
; whole line over one bad argument) -- silent on success for every
; argument, per this project's "no news is good news" convention;
; final exit code reflects whether ANY argument failed. This is also
; the natural target of the shell's own file-globbing ("del *.bak"
; expands to one argv entry per match, all handled by this same loop).
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
            ; RA = argv pointer, RC = argc (RC.0 alone is enough --
            ; argc never exceeds ARGV_MAX_ARGS). argv[0] is this
            ; program's own name; argv[1..argc-1] are the filenames.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no filename given

            ; stash the argv pointer to memory -- K_FILE_DELETE's own
            ; clobber footprint isn't confirmed beyond DF, so RA can't
            ; be trusted to survive it across more than one iteration
            ; (same reasoning/pattern progs/echo.asm's own argv loop
            ; already established)
            mov     rf, del_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, del_argc
            glo     rc
            str     rf

            mov     rf, del_any_error
            ldi     0
            str     rf

            mov     rf, del_i
            ldi     1
            str     rf

del_loop:
            mov     rf, del_i
            ldn     rf
            str     r2                  ; M(X) = del_i
            mov     rf, del_argc
            ldn     rf                  ; D = del_argc
            xor                         ; D = del_argc XOR del_i
            lbz     del_done            ; del_i == del_argc: done

            ; RF = argv[del_i] = del_argv + del_i*2
            mov     rf, del_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = del_i (zero-extended)
            shl16   r8                  ; R8 = del_i * 2
            mov     rb, del_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = del_argv (the argv
                                        ; table's own base address,
                                        ; reloaded fresh every
                                        ; iteration)
            add16   rf, r8              ; RF = &argv[del_i]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv[del_i]
            mov     rf, r9              ; RF = the filename pointer
            call    K_FILE_DELETE       ; DF = 0/1
            lbnf    del_next            ; success: next argument

            call    K_INMSG
            db      "Cannot delete file (not found, or is a directory).",13,10,0
            mov     rf, del_any_error
            ldi     $FF
            str     rf

del_next:
            mov     rf, del_i
            ldn     rf
            adi     1
            str     rf
            lbr     del_loop

del_done:
            mov     rf, del_any_error
            ldn     rf
            lbnz    del_exit_err

            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention (2026-07-21)
            rtn

del_exit_err:
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: DEL <filename> [filename...]",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

del_argv:       dw      0
del_argc:       db      0
del_i:          db      0
del_any_error:  db      0

            end     start
