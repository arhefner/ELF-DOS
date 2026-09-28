;
; attrib.asm - show or change the read-only and hidden attributes
;
; Usage: ATTRIB [+R|-R] [+H|-H] <path...>
;
; Bare "ATTRIB <path...>" shows each path's current attributes, one
; line per path: two columns, R (read-only) and H (hidden), each shown
; as its letter or "-", then the path -- e.g. "R-  <path>".
; Any number of leading +R/-R/+H/-H flags (case-insensitive, one per
; argv token, in any order) set or clear those bits on every path that
; follows -- silent on success, per this project's "no news is good
; news" convention (matches DEL/COPY/MD/RD/REN). A token that isn't
; exactly one of those four ends the flags and is the first path.
; Multiple paths are handled independently: a failure on one prints
; its own "Not found: " and the rest still run (matching DEL's own
; precedent); the final exit code reflects whether ANY argument failed.
;
; Read-only (2026-09-28) works as in MS-DOS: the kernel refuses to open
; a read-only file for write or append, or to delete it; reading and
; renaming it are allowed. The bit on a directory is ignored.
;
; Wildcard support (2026-07-27, redesigned): each argv entry is
; checked via lib/file_glob.asm's is_glob -- a plain path is processed
; directly; a "*"/"?" pattern is expanded via glob_init/glob_next and
; every match processed the same way, individually. A pattern matching
; zero files falls back to attempting the literal, unexpanded text
; (nullglob-off) -- it will then simply report "Not found" like any
; other missing literal path.
;
; Built on K_FILE_SETATTR (a general set/clear-mask attribute-byte
; rewrite) for apply mode and K_STAT for show mode.
;

#include    include/opcodes.def
#include    include/kernel_api.inc
#include    include/file_glob.inc

            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

ATTRIB_MODE_SHOW:  equ     0
ATTRIB_MODE_APPLY: equ     1

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
            ; program's own name.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            ; stash argv/argc to memory -- K_FILE_SETATTR/K_STAT's own
            ; clobber footprint isn't confirmed beyond DF, same
            ; defensive pattern DEL/DIR's own multi-argument loops
            ; already establish
            mov     rf, attrib_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf
            mov     rf, attrib_argc
            glo     rc
            str     rf

            ; --- leading flags: any number of +R/-R/+H/-H tokens ---
            ; No calls in this loop, so its state lives in registers:
            ; R9.0 = set mask, R9.1 = clear mask, R7.0 = argv index,
            ; RA walks the argv table, RC.0 = argc.
            ldi     0
            plo     r9
            phi     r9
            ldi     1
            plo     r7
            inc     ra
            inc     ra                  ; RA = &argv[1]

af_loop:
            glo     r7
            str     r2
            glo     rc
            xor
            lbz     af_end              ; ran out of arguments

            lda     ra
            phi     rd
            lda     ra
            plo     rd                  ; RD = argv[i], RA = &argv[i+1]

            ldn     rd                  ; D = first character
            plo     r8                  ; R8.0 = sign (plo keeps D)
            xri     '+'
            lbz     af_sign
            glo     r8
            xri     '-'
            lbnz    af_end              ; not a flag: first path

af_sign:
            inc     rd
            inc     rd
            ldn     rd                  ; must be exactly 2 characters
            lbnz    af_end
            dec     rd
            ldn     rd
            ani     $DF                 ; fold to uppercase ('h'/'r' only
                                        ; alias to 'H'/'R' under this mask)
            plo     rb                  ; RB.0 = letter
            xri     'H'
            lbnz    af_not_h
            ldi     ATTR_HIDDEN
            lbr     af_have_bit
af_not_h:
            glo     rb
            xri     'R'
            lbnz    af_end              ; "+X" for another letter: a path
            ldi     ATTR_RDONLY
af_have_bit:
            plo     rb                  ; RB.0 = the attribute bit
            str     r2                  ; M(X) = bit
            glo     r8
            xri     '+'
            lbnz    af_minus
            glo     r9
            or
            plo     r9                  ; set mask |= bit
            lbr     af_next
af_minus:
            ghi     r9
            or
            phi     r9                  ; clear mask |= bit
af_next:
            inc     r7
            lbr     af_loop

af_end:
            mov     rf, attrib_setmask
            glo     r9
            str     rf
            mov     rf, attrib_clearmask
            ghi     r9
            str     rf
            mov     rf, attrib_start_i
            glo     r7
            str     rf

            glo     r7
            str     r2
            glo     rc
            xor
            lbz     usage               ; flags but no path

            glo     r9
            str     r2
            ghi     r9
            or                          ; D = set | clear
            lbz     af_show             ; no flags: show mode
            ldi     ATTRIB_MODE_APPLY
af_show:                                ; D = 0 = ATTRIB_MODE_SHOW here
            plo     r8
            mov     rf, attrib_mode
            glo     r8
            str     rf

            mov     rf, attrib_any_error
            ldi     0
            str     rf

            mov     rb, attrib_i
            mov     rf, attrib_start_i
            ldn     rf
            str     rb

attrib_loop:
            mov     rf, attrib_i
            ldn     rf
            str     r2                  ; M(X) = attrib_i
            mov     rf, attrib_argc
            ldn     rf                  ; D = attrib_argc
            xor                         ; D = attrib_argc XOR attrib_i
            lbz     attrib_done         ; attrib_i == argc: done

            ; R9 = argv[attrib_i], stashed into attrib_argv_text --
            ; never trusted in a register across is_glob/glob_init/
            ; glob_next (all but is_glob document a broad "Modifies:
            ; everything" clobber footprint)
            mov     rf, attrib_i
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = attrib_i (zero-extended)
            shl16   r8                  ; R8 = attrib_i * 2
            mov     rb, attrib_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = attrib_argv (base,
                                        ; reloaded fresh every iteration)
            add16   rf, r8              ; RF = &argv[attrib_i]
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = argv[attrib_i]

            mov     rf, attrib_argv_text
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; attrib_argv_text = argv[attrib_i]

            mov     rf, attrib_argv_text
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = attrib_argv_text (deref)
            call    is_glob
            lbdf    attrib_literal      ; DF=1: not a glob

            ; --- is a glob: glob_init ---
            mov     rf, attrib_argv_text
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            mov     rd, attrib_glob_ctx
            ldi     GLOB_HIDDEN         ; ATTRIB sees hidden files too, as in MS-DOS
            call    glob_init
            lbdf    attrib_glob_bad_path

            mov     rf, attrib_glob_found
            ldi     0
            str     rf

attrib_glob_loop:
            mov     rd, attrib_glob_ctx
            call    glob_next
            lbdf    attrib_glob_done    ; exhausted

            ; BUG FIX (caught in review, before ever assembling): RF
            ; holds glob_next's own returned match pointer at this
            ; point -- "mov rf, attrib_glob_found" below would
            ; silently overwrite it with attrib_glob_found's OWN
            ; address before attrib_process_one ever got a chance to
            ; read it. Stash it in R9 first (free at this point),
            ; restore right before the call.
            mov     r9, rf              ; R9 = matched full path

            mov     rf, attrib_glob_found
            ldi     1
            str     rf

            mov     rf, r9              ; RF = matched full path again
            call    attrib_process_one
            lbr     attrib_glob_loop

attrib_glob_done:
            mov     rf, attrib_glob_found
            ldn     rf
            lbnz    attrib_next         ; had at least one match: done

            ; zero matches: nullglob-off fallback to the literal,
            ; unexpanded text
            mov     rf, attrib_argv_text
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    attrib_process_one
            lbr     attrib_next

attrib_glob_bad_path:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, attrib_argv_text
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, attrib_any_error
            ldi     $FF
            str     rf
            lbr     attrib_next

attrib_literal:
            mov     rf, attrib_argv_text
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    attrib_process_one

attrib_next:
            mov     rf, attrib_i
            ldn     rf
            adi     1
            str     rf
            lbr     attrib_loop

attrib_done:
            mov     rf, attrib_any_error
            ldn     rf
            lbnz    attrib_exit_err

            ldi     0                   ; exit code 0 = success
            rtn

attrib_exit_err:
            ldi     1                   ; exit code 1 = error
            rtn

usage:
            call    K_INMSG
            db      "Usage: ATTRIB [+R|-R] [+H|-H] <path...>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

;------------------------------------------------------------------
; attrib_process_one: show or apply the hidden-attribute change for a
; single, already-resolved path.
; Args:    RF = path (full path or bare name)
; Returns: nothing
; Modifies: everything (calls K_STAT/K_FILE_SETATTR/K_MSG/K_INMSG)
;------------------------------------------------------------------
attrib_process_one:
            mov     rb, attrib_cur_path
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb                  ; attrib_cur_path = RF (stashed
                                        ; for the possible error
                                        ; message, and for show mode's
                                        ; own print)

            mov     rf, attrib_mode
            ldn     rf
            lbnz    apo_apply           ; mode == APPLY

            ; ---- show mode: K_STAT + print "H  "/"-  " + path ----
            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = path
            mov     rd, attrib_statbuf  ; RD = result buffer
            call    K_STAT
            lbdf    apo_not_found

            mov     rf, attrib_statbuf
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_RDONLY
            lbz     apo_show_not_ro
            call    K_INMSG
            db      "R",0
            lbr     apo_show_h
apo_show_not_ro:
            call    K_INMSG
            db      "-",0

apo_show_h:
            mov     rf, attrib_statbuf
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte (reloaded --
                                        ; nothing survives K_INMSG here)
            ani     ATTR_HIDDEN
            lbz     apo_show_notset

            call    K_INMSG
            db      "H  ",0
            lbr     apo_show_path

apo_show_notset:
            call    K_INMSG
            db      "-  ",0

apo_show_path:
            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            rtn

apo_apply:
            mov     rf, attrib_setmask
            ldn     rf
            plo     rc
            mov     rf, attrib_clearmask
            ldn     rf
            phi     rc                  ; RC.0 = set mask, RC.1 = clear
                                        ; mask -- K_FILE_SETATTR's own
                                        ; convention

            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = path
            call    K_FILE_SETATTR      ; DF = 0/1
            lbnf    apo_ok              ; success: silent

apo_not_found:
            call    K_INMSG
            db      "Not found: ",0
            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, attrib_any_error
            ldi     $FF
            str     rf

apo_ok:
            rtn

attrib_mode:        db      0
attrib_start_i:     db      0
attrib_setmask:     db      0
attrib_clearmask:   db      0
attrib_argv:        dw      0
attrib_argc:        db      0
attrib_i:           db      0
attrib_argv_text:   dw      0
attrib_cur_path:    dw      0
attrib_any_error:   db      0
attrib_glob_found:  db      0
attrib_statbuf:     ds      DIRENT_LEN
attrib_glob_ctx:    ds      GLOB_CTX_LEN

            end     start
