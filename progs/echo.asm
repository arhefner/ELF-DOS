;
; echo.asm - print arguments, space-separated; also controls batch
; script echo mode (ECHO ON/OFF), matching real MS-DOS
;
; Usage: ECHO [-n] [args...]
;        ECHO ON | ECHO OFF
;        ECHO
;
; Prints argv[1..argc-1] (skipping argv[0], this program's own
; invocation name), separated by single spaces, followed by a
; trailing newline. If argv[1] is exactly "-n" (case-sensitive, no
; other characters), it's consumed and NOT printed, printing starts
; at argv[2] instead, and the trailing newline is suppressed --
; matching the common shell "-n" convention.
;
; If argv[1] is exactly "ON" or "OFF" (case-insensitive, checked as a
; flag regardless of anything after it -- same convention "-n" above
; already uses), sets RUN_BATCH_ECHO_OFF (kernel.inc) instead of
; printing anything: this is the persistent half of MS-DOS's echo-
; control idiom, checked by progs/shell.asm before echoing each batch
; line. The other half, a per-line '@' prefix, is handled entirely in
; shell.asm and never reaches this program.
;
; With no arguments at all (bare "ECHO"), reports the current mode
; ("ECHO is on."/"ECHO is off.") instead of printing a blank line --
; matches real DOS; a deliberate behavior change from this program's
; original bare-ECHO-prints-a-blank-line design.
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
            ; K_MSG/K_INMSG calls below (gotcha #8: assume clobbered
            ; unless proven otherwise).
            mov     rf, echo_argc
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf

            mov     rf, echo_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            ; defaults: start printing at argv[1], print a trailing
            ; newline
            mov     rf, echo_i
            ldi     0
            str     rf
            inc     rf
            ldi     1
            str     rf                  ; echo_i = 1

            mov     rf, echo_newline
            ldi     1
            str     rf                  ; echo_newline = 1 (true)

            ; --- ECHO ON / ECHO OFF / bare ECHO (report state) ---
            glo     rc
            smi     2
            lbnf    echo_bare           ; argc < 2 (always exactly 1,
                                        ; argv[0] always exists): report

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf
            ani     $DF                 ; uppercase-fold: safe here --
                                        ; only 'O'/'o' clear to 0x4F
                                        ; under this mask, same
                                        ; reasoning as check_batch_ext's
                                        ; own established use
            xri     'O'
            lbnz    echo_check_dashn    ; first char isn't O: neither
                                        ; ON nor OFF
            inc     rf                  ; RF = &argv[1][1]
            ldn     rf
            ani     $DF
            xri     'N'
            lbnz    echo_maybe_off      ; RF stays at &argv[1][1] --
                                        ; reused directly below, OFF's
                                        ; own second character
            inc     rf
            ldn     rf                  ; third char must be NUL for
                                        ; "on" to be the whole token
            lbnz    echo_check_dashn
            lbr     echo_set_on

echo_maybe_off:
            ldn     rf                  ; RF already = &argv[1][1]
            ani     $DF
            xri     'F'
            lbnz    echo_check_dashn
            inc     rf                  ; RF = &argv[1][2]
            ldn     rf
            ani     $DF
            xri     'F'
            lbnz    echo_check_dashn
            inc     rf                  ; RF = &argv[1][3], must be NUL
            ldn     rf
            lbnz    echo_check_dashn
            lbr     echo_set_off

echo_set_on:
            mov     rf, RUN_BATCH_ECHO_OFF
            ldi     0
            str     rf
            ldi     0                   ; exit code 0 = success
            rtn

echo_set_off:
            mov     rf, RUN_BATCH_ECHO_OFF
            ldi     1
            str     rf
            ldi     0
            rtn

echo_bare:
            mov     rf, RUN_BATCH_ECHO_OFF
            ldn     rf
            lbnz    echo_bare_off
            call    K_INMSG
            db      "ECHO is on.",13,10,0
            ldi     0
            rtn
echo_bare_off:
            call    K_INMSG
            db      "ECHO is off.",13,10,0
            ldi     0
            rtn

echo_check_dashn:
            ; check argc >= 2 and argv[1] is EXACTLY "-n" (unchanged
            ; from this program's original design -- reached here,
            ; instead of falling through from the top, now that ON/OFF
            ; are checked first; re-fetches argv[1] fresh rather than
            ; risk touching this already-proven block)
            glo     rc
            smi     2
            lbnf    echo_loop_init      ; argc < 2: nothing to check
                                        ; (dead in practice -- argc < 2
                                        ; is already routed to
                                        ; echo_bare above -- kept as a
                                        ; harmless safety net)

            mov     rb, ra
            add16   rb, 2               ; RB = &argv[1]
            lda     rb
            phi     rd
            ldn     rb
            plo     rd                  ; RD = argv[1] pointer

            mov     rf, rd
            ldn     rf                  ; D = argv[1][0]
            xri     '-'
            lbnz    echo_loop_init      ; not "-n": normal case
            inc     rf
            ldn     rf                  ; D = argv[1][1]
            xri     'n'
            lbnz    echo_loop_init
            inc     rf
            ldn     rf                  ; D = argv[1][2] -- must be NUL
                                        ; for "-n" to be the whole token
            lbnz    echo_loop_init

            ; exactly "-n" -- skip it, start at argv[2], suppress the
            ; trailing newline
            mov     rf, echo_i
            ldi     0
            str     rf
            inc     rf
            ldi     2
            str     rf                  ; echo_i = 2

            mov     rf, echo_newline
            ldi     0
            str     rf                  ; echo_newline = 0 (false)

echo_loop_init:
            mov     rf, echo_first
            ldi     1
            str     rf                  ; echo_first = 1 (true --
                                        ; no separator before the very
                                        ; first argument printed)

echo_loop:
            mov     rf, echo_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = echo_i
            mov     rf, echo_argc
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = argc

            ; echo_i >= argc ?
            glo     r8
            str     r2
            glo     rd
            sm
            ghi     r8
            str     r2
            ghi     rd
            smb
            lbdf    echo_done           ; DF=1: echo_i >= argc, done

            mov     rf, echo_first
            ldn     rf
            lbz     echo_have_sep       ; not first: print the
                                        ; separator space
            ldi     0
            str     rf                  ; clear the flag
            lbr     echo_get_arg

echo_have_sep:
            call    K_INMSG
            db      " ",0

echo_get_arg:
            ; &argv[echo_i] = echo_argv + echo_i*2 -- RD still holds
            ; echo_i untouched (the comparison above only touches D)
            shl16   rd                  ; RD = echo_i * 2
            mov     rf, echo_argv
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = argv (base pointer)
            add16   rb, rd              ; RB = &argv[echo_i]

            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[echo_i]
            call    K_MSG

            mov     rf, echo_i
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            mov     rf, echo_i
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; echo_i++

            lbr     echo_loop

echo_done:
            mov     rf, echo_newline
            ldn     rf
            lbz     echo_exit           ; newline flag false: skip it
            call    K_INMSG
            db      13,10,0

echo_exit:
            ldi     0                   ; exit code 0 = success
            rtn

echo_argc:      dw      0
echo_argv:      dw      0
echo_i:         dw      0
echo_first:     db      0
echo_newline:   db      0

            end     start
