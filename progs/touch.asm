;
; touch.asm - update one or more files' last-write time to now
;
; Usage: TOUCH <filename> [filename...]
;
; Each <filename> must already exist -- TOUCH does not create files
; (unlike the real Unix `touch`, which does); content, size, and
; attributes are untouched, only the last-write date/time is refreshed
; to the current time via K_FILE_TOUCH. Each <filename> may be a full
; path, e.g. "TOUCH /cfg/env.dat" -- resolved internally by
; K_FILE_TOUCH (see K_PATH_RESOLVE). Multiple filenames are processed
; independently: a failure on one prints its own error and moves on to
; the next (this project's established batch-script precedent) --
; silent on success for every argument, per the "no news is good news"
; convention; final exit code reflects whether ANY argument failed.
;
; Wildcard support via lib/file_glob.asm's is_glob/glob_init/glob_next,
; same pattern as DEL/COPY/MOVE/ATTRIB -- a plain filename is touched
; directly; a "*"/"?" pattern is expanded and every match touched
; individually. A pattern matching zero files falls back to attempting
; the literal, unexpanded text (nullglob-off).
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

            ; stash the argv pointer to memory -- K_FILE_TOUCH's own
            ; clobber footprint isn't confirmed beyond DF, so RA can't
            ; be trusted to survive it across more than one iteration
            ; (same reasoning/pattern progs/del.asm's own argv loop
            ; already established)
            mov     rf, tch_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, tch_argc
            glo     rc
            str     rf

            mov     rf, tch_any_error
            ldi     0
            str     rf

            mov     rf, tch_i
            ldi     1
            str     rf

tch_loop:
            mov     rf, tch_i
            ldn     rf
            str     r2                  ; M(X) = tch_i
            mov     rf, tch_argc
            ldn     rf                  ; D = tch_argc
            xor                         ; D = tch_argc XOR tch_i
            lbz     tch_done            ; tch_i == tch_argc: done

            ; tch_cur_name = argv[tch_i] = tch_argv + tch_i*2 --
            ; stashed to memory immediately, never trusted in a
            ; register across is_glob/glob_init/glob_next (all of
            ; which except is_glob document a broad "Modifies:
            ; everything" clobber footprint)
            mov     rf, tch_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = tch_i (zero-extended)
            shl16   r8                  ; R8 = tch_i * 2
            mov     rb, tch_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = tch_argv (the argv
                                        ; table's own base address,
                                        ; reloaded fresh every
                                        ; iteration)
            add16   rf, r8              ; RF = &argv[tch_i]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv[tch_i]
            mov     rf, tch_cur_name
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; tch_cur_name = argv[tch_i]

            mov     rf, tch_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = tch_cur_name (dereferenced)
            call    is_glob
            lbdf    tch_literal         ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, tch_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = tch_cur_name (dereferenced)
            mov     rd, tch_glob_ctx
            call    glob_init
            lbdf    tch_bad_path        ; bad prefix path: this argv
                                        ; entry's own error

            mov     rf, tch_glob_found
            ldi     0
            str     rf                  ; assume zero matches until
                                        ; the first glob_next succeeds

tch_glob_loop:
            mov     rd, tch_glob_ctx
            call    glob_next
            lbdf    tch_glob_done       ; exhausted

            ; same RF-vs-tch_glob_found collision DEL's own history
            ; already found and fixed -- stash the match pointer in R9
            ; before the "mov rf, tch_glob_found" below would silently
            ; overwrite it
            mov     r9, rf              ; R9 = matched full path

            mov     rf, tch_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    tch_one_file
            lbr     tch_glob_loop

tch_glob_done:
            mov     rf, tch_glob_found
            ldn     rf
            lbnz    tch_next            ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, tch_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    tch_one_file
            lbr     tch_next

tch_bad_path:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, tch_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, tch_any_error
            ldi     $FF
            str     rf
            lbr     tch_next

tch_literal:
            mov     rf, tch_cur_name
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    tch_one_file

tch_next:
            mov     rf, tch_i
            ldn     rf
            adi     1
            str     rf
            lbr     tch_loop

tch_done:
            mov     rf, tch_any_error
            ldn     rf
            lbnz    tch_exit_err

            ldi     0                   ; exit code 0 = success --
                                        ; silent, per this project's
                                        ; "no news is good news"
                                        ; convention
            rtn

tch_exit_err:
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: TOUCH <filename> [filename...]",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

;------------------------------------------------------------------
; tch_one_file: touch a single, already-resolved filename, printing
; the usual error message and setting tch_any_error on failure.
; Args:    RF = filename (full path or bare name)
; Returns: nothing
; Modifies: everything (calls K_FILE_TOUCH)
;------------------------------------------------------------------
tch_one_file:
            ; stash THIS call's own path (which for a glob match is a
            ; specific matched path, NOT the same as tch_cur_name's own
            ; original pattern text) so the error message below names
            ; the file that actually failed, not the argv entry it came
            ; from -- same distinction ATTRIB's own attrib_process_one/
            ; attrib_cur_path already establishes
            mov     rb, tch_this_path
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            call    K_FILE_TOUCH        ; DF = 0/1
            lbnf    tof_ok

            call    K_INMSG
            db      "Not found: ",0
            mov     rf, tch_this_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, tch_any_error
            ldi     $FF
            str     rf
tof_ok:
            rtn

tch_argv:       dw      0
tch_argc:       db      0
tch_i:          db      0
tch_any_error:  db      0
tch_cur_name:   dw      0
tch_this_path:  dw      0
tch_glob_found: db      0
tch_glob_ctx:   ds      GLOB_CTX_LEN

            end     start
