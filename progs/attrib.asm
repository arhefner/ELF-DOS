;
; attrib.asm - show or change the hidden attribute on one or more files
;
; Usage: ATTRIB [+H|-H] <path...>
;
; Bare "ATTRIB <path...>" (no +H/-H) shows each path's current hidden
; state, one line per path: "H  <path>" (hidden) or "-  <path>" (not).
; "ATTRIB +H <path...>" sets the hidden bit; "ATTRIB -H <path...>"
; clears it -- silent on success for every argument, per this project's
; "no news is good news" convention (matches DEL/COPY/MD/RD/REN).
; Multiple paths (explicit, or via the shell's own file-globbing, e.g.
; "attrib +h *.bak") are handled independently: a failure on one prints
; its own "Not found: " and the rest still run (matching DEL's own
; precedent); the final exit code reflects whether ANY argument failed.
;
; Built on the new K_FILE_SETATTR kernel primitive (a general set/
; clear-mask attribute-byte rewrite) for apply mode and the existing
; K_STAT for show mode. Deliberately scoped to just the hidden bit for
; now -- K_FILE_SETATTR itself is general, so a future +R/-R or +S/-S
; would only need more argument parsing here, no kernel change.
;
; "+H"/"-H" (case-insensitive -- "+h"/"-h" work identically, 2026-07-23)
; is matched as an exact 2-character-plus-NUL token in argv[1] (same
; shape as progs/mr.asm's own "-u"/"-b" check) -- not combined-cluster
; parsing like LS's "-lF", since a signed single-letter switch doesn't
; cluster the same way. Anything else in argv[1] (including no argv[1]
; at all matching the pattern) means show mode, with argv[1] itself
; treated as the first path.
;

#include    include/opcodes.def
#include    include/kernel_api.inc

ATTRIB_MODE_SHOW:  equ     0
ATTRIB_MODE_APPLY: equ     1

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
            ; program's own name.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: nothing at all

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            plo     r8                  ; R8.0 = the sign char (temp --
                                        ; plo doesn't touch D, so D
                                        ; still holds the char for the
                                        ; xri right below)
            xri     '+'
            lbz     maybe_h

            glo     r8
            xri     '-'
            lbnz    mode_show           ; neither '+' nor '-': argv[1]
                                        ; is a path, show mode

maybe_h:
            mov     rf, rd
            inc     rf
            ldn     rf                  ; D = argv[1][1]
            ani     $DF                 ; fold lowercase to uppercase
                                        ; (same idiom already used
                                        ; elsewhere in this project,
                                        ; e.g. shell.asm's REM/drive-
                                        ; letter checks -- only 'H'/'h'
                                        ; collapse to 'H' under this
                                        ; mask, confirmed no other
                                        ; character aliases to it)
            xri     'H'
            lbnz    mode_show           ; not "+H"/"-H" (case-insensitive)

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
                                        ; for "+H"/"-H" to be exactly
                                        ; this whole token
            lbnz    mode_show

            ; confirmed exactly "+H" or "-H" -- requires a path after it
            glo     rc
            smi     3
            lbnf    usage               ; flag given but argc < 3

            mov     rf, attrib_mode
            ldi     ATTRIB_MODE_APPLY
            str     rf
            mov     rf, attrib_start_i
            ldi     2
            str     rf

            glo     r8                  ; D = the sign character (still
                                        ; intact in R8.0 -- nothing
                                        ; since has touched it)
            xri     '+'
            lbnz    is_minus_h

            mov     rf, attrib_setmask
            ldi     ATTR_HIDDEN
            str     rf
            mov     rf, attrib_clearmask
            ldi     0
            str     rf
            lbr     have_mode

is_minus_h:
            mov     rf, attrib_setmask
            ldi     0
            str     rf
            mov     rf, attrib_clearmask
            ldi     ATTR_HIDDEN
            str     rf
            lbr     have_mode

mode_show:
            mov     rf, attrib_mode
            ldi     ATTRIB_MODE_SHOW
            str     rf
            mov     rf, attrib_start_i
            ldi     1
            str     rf

have_mode:
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

            ; R9 = argv[attrib_i]
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

            mov     rf, attrib_cur_path
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf                  ; attrib_cur_path = R9 (stashed
                                        ; for the possible error message,
                                        ; and for show mode's own print)

            mov     rf, attrib_mode
            ldn     rf
            lbnz    attrib_apply        ; mode == APPLY

            ; ---- show mode: K_STAT + print "H  "/"-  " + path ----
            mov     rf, r9              ; RF = path
            mov     rd, attrib_statbuf  ; RD = result buffer
            call    K_STAT
            lbdf    attrib_not_found

            mov     rf, attrib_statbuf
            add16   rf, DIRENT_ATTR
            ldn     rf                  ; D = attribute byte
            ani     ATTR_HIDDEN
            lbz     attrib_show_notset

            call    K_INMSG
            db      "H  ",0
            lbr     attrib_show_path

attrib_show_notset:
            call    K_INMSG
            db      "-  ",0

attrib_show_path:
            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     attrib_next

attrib_apply:
            mov     rf, attrib_setmask
            ldn     rf
            plo     rc
            mov     rf, attrib_clearmask
            ldn     rf
            phi     rc                  ; RC.0 = set mask, RC.1 = clear
                                        ; mask -- K_FILE_SETATTR's own
                                        ; convention

            mov     rf, r9              ; RF = path (R9 untouched since
                                        ; it was loaded above)
            call    K_FILE_SETATTR      ; DF = 0/1
            lbnf    attrib_next         ; success: silent, next arg

attrib_not_found:
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
            db      "Usage: ATTRIB [+H|-H] <path...>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

attrib_mode:        db      0
attrib_start_i:     db      0
attrib_setmask:     db      0
attrib_clearmask:   db      0
attrib_argv:        dw      0
attrib_argc:        db      0
attrib_i:           db      0
attrib_cur_path:    dw      0
attrib_any_error:   db      0
attrib_statbuf:     ds      DIRENT_LEN

            end     start
