;
; attrib.asm - show or change the hidden/executable attribute on one or
; more files
;
; Usage: ATTRIB [+H|-H|+X|-X] <path...>
;
; Bare "ATTRIB <path...>" (no flag) shows each path's current hidden
; and executable state, one line per path: two flag columns ("H"/"-"
; then "X"/"-") followed by the path, e.g. "H-  foo.txt" (hidden, not
; executable) or "-X  bar" (not hidden, executable). "ATTRIB +H/-H"
; sets/clears the hidden bit; "ATTRIB +X/-X" (2026-08-05) sets/clears
; the executable flag (byte offset 0x0C bit 6 of the raw directory
; entry -- see kernel_api.inc's own DE_EXEC/DE_EXEC_BIT) -- both
; silent on success for every argument, per this project's "no news
; is good news" convention (matches DEL/COPY/MD/RD/REN).
; Multiple paths are handled independently: a failure on one prints
; its own "Not found: " and the rest still run (matching DEL's own
; precedent); the final exit code reflects whether ANY argument failed.
;
; Wildcard support (2026-07-27, redesigned): each argv entry is
; checked via lib/file_glob.asm's is_glob -- a plain path is processed
; directly, exactly as before; a "*"/"?" pattern is expanded via
; glob_init/glob_next and every match processed the same way,
; individually. This replaces the old design (the shell's own
; tokenizer pre-expanding "attrib +h *.bak" into one argv entry per
; match before ATTRIB ever ran) -- see lib/file_glob.asm's own header
; for why: the old design had a hard ARGV_MAX_ARGS=16 ceiling. A
; pattern matching zero files falls back to attempting the literal,
; unexpanded text (nullglob-off) -- it will then simply report "Not
; found" like any other missing literal path.
;
; Built on the K_FILE_SETATTR kernel primitive (a general set/clear-
; mask DE_ATTR rewrite) for the hidden bit, and the new (2026-08-05)
; K_FILE_GETLOC for the executable flag -- unlike K_FILE_SETATTR,
; K_FILE_GETLOC does NOT patch anything itself: it reuses the
; kernel's own already-proven, LFN-aware name-matching search to hand
; back just the raw sector LBA + byte offset, and THIS PROGRAM does
; its own K_SECREAD/patch/K_SECWRITE round trip (see apo_apply_exec
; below) -- deliberately kept out of the kernel, since only the
; search genuinely needs kernel-internal state; the one-byte patch
; doesn't. Plus the existing K_STAT for show mode. A future +R/-R or
; +S/-S would only need more argument parsing here, no kernel change,
; matching K_FILE_SETATTR's own "general primitive" design.
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
#include    include/file_glob.inc

            extrn   is_glob
            extrn   glob_init
            extrn   glob_next

ATTRIB_MODE_SHOW:  equ     0
ATTRIB_MODE_APPLY: equ     1

ATTRIB_TARGET_HIDDEN: equ  0       ; "+H"/"-H" -- K_FILE_SETATTR
ATTRIB_TARGET_EXEC:   equ  1       ; "+X"/"-X" -- K_FILE_GETLOC + this
                                    ; program's own raw sector patch

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
            lbnz    maybe_x             ; not "+H"/"-H" -- try "+X"/"-X"
                                        ; before giving up to mode_show

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
            mov     rf, attrib_target
            ldi     ATTRIB_TARGET_HIDDEN
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

; --- "+X"/"-X" (2026-08-05): the executable flag, mirroring "+H"/"-H"'s
; own argv-parsing shape exactly, but storing a single 0/1 value into
; attrib_setmask (consumed by this program's own raw sector patch in
; apo_apply_exec, not by a kernel primitive the way K_FILE_SETATTR's
; DE_ATTR-based set/clear-mask pair is) ---
maybe_x:
            mov     rf, rd
            inc     rf
            ldn     rf                  ; D = argv[1][1]
            ani     $DF                 ; fold lowercase (only 'X'/'x'
                                        ; collapse to 'X' under this
                                        ; mask, same reasoning as 'H'
                                        ; above)
            xri     'X'
            lbnz    mode_show           ; not "+X"/"-X" either

            mov     rf, rd
            inc     rf
            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
            lbnz    mode_show

            ; confirmed exactly "+X" or "-X" -- requires a path after it
            glo     rc
            smi     3
            lbnf    usage               ; flag given but argc < 3

            mov     rf, attrib_mode
            ldi     ATTRIB_MODE_APPLY
            str     rf
            mov     rf, attrib_start_i
            ldi     2
            str     rf
            mov     rf, attrib_target
            ldi     ATTRIB_TARGET_EXEC
            str     rf

            glo     r8                  ; D = the sign character
            xri     '+'
            lbnz    is_minus_x

            mov     rf, attrib_setmask
            ldi     1                   ; nonzero = set (apo_apply_
                                        ; exec's own convention below)
            str     rf
            lbr     have_mode

is_minus_x:
            mov     rf, attrib_setmask
            ldi     0                   ; 0 = clear
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
            db      "Usage: ATTRIB [+H|-H] <path...>",13,10,0
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

            ; ---- show mode: K_STAT + print "HX  "/"H-  "/"-X  "/"--  "
            ; + path (2026-08-05: widened from a single hidden-only
            ; "H"/"-" column to two columns, hidden then executable,
            ; now that K_STAT's own result buffer carries DIRENT_EXEC
            ; too) ----
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
            ani     ATTR_HIDDEN
            lbz     apo_show_h_notset

            call    K_INMSG
            db      "H",0
            lbr     apo_show_x

apo_show_h_notset:
            call    K_INMSG
            db      "-",0

apo_show_x:
            mov     rf, attrib_statbuf
            add16   rf, DIRENT_EXEC
            ldn     rf                  ; D = 0 or 1 (already isolated
                                        ; by dir_read -- no mask needed)
            lbz     apo_show_x_notset

            call    K_INMSG
            db      "X  ",0
            lbr     apo_show_path

apo_show_x_notset:
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
            mov     rf, attrib_target
            ldn     rf
            lbnz    apo_apply_exec      ; target == EXEC -- K_FILE_GETLOC
                                        ; + this program's own patch

            ; ---- target == HIDDEN: K_FILE_SETATTR (unchanged) ----
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
            lbr     apo_apply_check

; ---- target == EXEC (2026-08-05): no dedicated set/clear kernel
; primitive -- K_FILE_GETLOC locates the entry's own raw sector LBA +
; byte offset (reusing the kernel's own already-proven, LFN-aware
; name matching), then this program does its own K_SECREAD/patch/
; K_SECWRITE round trip, mirroring test/corrupt.asm's/lib/vollabel.
; asm's own already-proven raw-sector-I/O pattern -- deliberately NOT
; a new kernel primitive, since the only thing that genuinely needs
; kernel-internal state is the LFN-aware search, not the one-byte
; patch itself. ----
apo_apply_exec:
            mov     rf, attrib_cur_path
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, rd              ; RF = path
            call    K_FILE_GETLOC       ; DF = 0/1; R8:R7 = sector LBA,
                                        ; RD = byte offset within it
            lbdf    apo_apply_check     ; not found: DF already 1,
                                        ; falls through to apo_not_found

            ; stash LBA + offset to memory before anything else can
            ; clobber them -- K_SECREAD's own documented contract
            ; clobbers R7/R8, and this program doesn't trust any
            ; register across an unaudited call regardless
            mov     rf, attrib_loc_lba
            ghi     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; attrib_loc_lba = R8.hi,
                                        ; R7.hi, R7.lo (R8.lo is always
                                        ; 0 -- K_SECREAD/K_SECWRITE's
                                        ; own convention, not stored)

            mov     rf, attrib_loc_off
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; attrib_loc_off = byte offset

            mov     rf, attrib_loc_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, attrib_secbuf
            call    K_SECREAD           ; DF = 0/1
            lbdf    apo_apply_check     ; read error: report as failure

            mov     rf, attrib_loc_off
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = byte offset

            mov     rf, attrib_secbuf
            add16   rf, rd
            add16   rf, DE_EXEC         ; RF = the NTRes byte's own
                                        ; address within attrib_secbuf

            mov     rb, attrib_setmask
            ldn     rb                  ; D = 0/1
            lbz     apo_exec_clear

            ; set the bit: old_byte | DE_EXEC_BIT
            ldn     rf                  ; D = current raw NTRes byte
            ori     DE_EXEC_BIT
            lbr     apo_exec_write

apo_exec_clear:
            ; clear the bit: old_byte & $BF ($BF = ~DE_EXEC_BIT mod
            ; 256, written as a plain literal rather than a "^"
            ; expression -- "^" has its own, unrelated meaning in
            ; Asm/02's own .prg fixup syntax)
            ldn     rf                  ; D = current raw NTRes byte
            ani     $BF

apo_exec_write:
            str     rf                  ; patch the NTRes byte in
                                        ; attrib_secbuf

            mov     rf, attrib_loc_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, attrib_secbuf
            call    K_SECWRITE          ; DF = 0/1

apo_apply_check:
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
attrib_target:      db      0           ; ATTRIB_TARGET_HIDDEN/EXEC
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
attrib_loc_lba:     ds      3           ; K_FILE_GETLOC's own LBA
                                        ; result (2026-08-05, "+X"/"-X")
attrib_loc_off:     dw      0           ; K_FILE_GETLOC's own byte-
                                        ; offset result
attrib_secbuf:      ds      512         ; raw sector scratch for the
                                        ; K_SECREAD/patch/K_SECWRITE
                                        ; round trip

            end     start
