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
; final exit code reflects whether ANY argument failed.
;
; Wildcard support (2026-07-27, redesigned): each argv entry is
; checked via lib/file_glob.asm's is_glob -- a plain filename is
; deleted directly, exactly as before; a "*"/"?" pattern is expanded
; via glob_init/glob_next and every match deleted the same way,
; individually. This replaces the old design (the shell's own
; tokenizer pre-expanding "del *.bak" into one argv entry per match
; before DEL ever ran) -- see lib/file_glob.asm's own header for why:
; the old design had a hard ARGV_MAX_ARGS=16 ceiling, silently
; truncating a directory with more matches than that. A pattern
; matching zero files falls back to attempting the literal,
; unexpanded text (nullglob-off, matching bash's own default and this
; project's prior shell-side behavior) -- it will then simply report
; "not found" like any other missing literal filename.
;

#include    include/opcodes.def
#include    include/kernel_api.inc
#include    include/file_glob.inc

            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

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

            ; del_cur_name = argv[del_i] = del_argv + del_i*2 --
            ; stashed to memory immediately, never trusted in a
            ; register across is_glob/glob_init/glob_next (all of
            ; which except is_glob document a broad "Modifies:
            ; everything" clobber footprint)
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
            mov     rf, del_cur_name
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; del_cur_name = argv[del_i]

            mov     rf, del_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = del_cur_name (dereferenced)
            call    is_glob
            lbdf    del_literal         ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, del_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = del_cur_name (dereferenced)
            mov     rd, del_glob_ctx
            call    glob_init
            lbdf    del_bad_path        ; bad prefix path: this argv
                                        ; entry's own error

            mov     rf, del_glob_found
            ldi     0
            str     rf                  ; assume zero matches until
                                        ; the first glob_next succeeds

del_glob_loop:
            mov     rd, del_glob_ctx
            call    glob_next
            lbdf    del_glob_done       ; exhausted

            ; BUG FIX (caught in review, before ever assembling): RF
            ; holds glob_next's own returned match pointer at this
            ; point -- "mov rf, del_glob_found" below would silently
            ; overwrite it with del_glob_found's OWN address before
            ; del_one_file ever got a chance to read it. Stash it in
            ; R9 first (free at this point), restore right before the
            ; call.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, del_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    del_one_file
            lbr     del_glob_loop

del_glob_done:
            mov     rf, del_glob_found
            ldn     rf
            lbnz    del_next            ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, del_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    del_one_file
            lbr     del_next

del_bad_path:
            call    K_INMSG
            db      "Cannot delete file (not found, or is a directory).",13,10,0
            mov     rf, del_any_error
            ldi     $FF
            str     rf
            lbr     del_next

del_literal:
            mov     rf, del_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    del_one_file

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

;------------------------------------------------------------------
; del_one_file: delete a single, already-resolved filename, printing
; the usual error message and setting del_any_error on failure.
; Args:    RF = filename (full path or bare name)
; Returns: nothing
; Modifies: everything (calls K_FILE_DELETE)
;------------------------------------------------------------------
del_one_file:
            call    K_FILE_DELETE       ; DF = 0/1
            lbnf    dof_ok

            call    K_INMSG
            db      "Cannot delete file (not found, or is a directory).",13,10,0
            mov     rf, del_any_error
            ldi     $FF
            str     rf
dof_ok:
            rtn

del_argv:       dw      0
del_argc:       db      0
del_i:          db      0
del_any_error:  db      0
del_cur_name:   dw      0
del_glob_found: db      0
del_glob_ctx:   ds      GLOB_CTX_LEN

            end     start
