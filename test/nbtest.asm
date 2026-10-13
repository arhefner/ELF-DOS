;
; nbtest.asm - exercise K_NBREAD, the console read with a timeout
;
; Usage: NBTEST
;
; Calls K_NBREAD 20 times with the longest timeout (RC = 0, which is
; 65536 BIOS polling loops) and prints "." for each call that timed out
; or "[x]" for each character x it returned (a control character is
; shown as "[^]"). Then prints how many calls timed out.
;
; What to look for:
;   - No typing: 20 dots. On EDOS-mbios at 4 MHz one call is about 1.6
;     seconds, so the run takes about 31 seconds (about 70 at 1.79 MHz).
;   - Typing: each key appears at once as "[x]". If the BIOS's echo flag
;     is set the key is also echoed, giving "x[x]".
;   - NBTEST < file: the file's first bytes at once, then dots at once
;     for whatever is left of the 20 calls after the end of the file.
;   - NBTEST < NUL: 20 dots at once.
;
; f_nbread is a BIOS extension. On a BIOS without it, the console runs
; may hang or print garbage; the two redirected runs never reach the
; BIOS and work anywhere.
;
; Nothing is kept in a register across a kernel call: the counters live
; in memory.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

NB_CALLS:   equ     20

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            mov     rf, nb_left
            ldi     NB_CALLS
            str     rf
            inc     rf                  ; -> nb_timeouts
            ldi     0
            str     rf

nb_loop:
            ldi     0
            phi     rc
            plo     rc                  ; RC = 0: the longest timeout
            call    K_NBREAD            ; DF = 0, D = character
                                        ; DF = 1: timed out
            lbdf    nb_timeout

            plo     r9                  ; keep the character (plo
                                        ; leaves D alone; mov does not)
            mov     rf, nb_char
            glo     r9
            smi     32                  ; a control character?
            lbdf    nb_printable
            ldi     '^'
            lbr     nb_store
nb_printable:
            glo     r9
nb_store:
            str     rf

            ldi     '['
            call    K_TYPE
            mov     rf, nb_char
            ldn     rf
            call    K_TYPE
            ldi     ']'
            call    K_TYPE
            lbr     nb_next

nb_timeout:
            mov     rf, nb_timeouts
            ldn     rf
            adi     1
            str     rf
            ldi     '.'
            call    K_TYPE

nb_next:
            mov     rf, nb_left
            ldn     rf
            smi     1
            str     rf
            lbnz    nb_loop

            call    K_INMSG
            db      13,10,"Timeouts: ",0

            mov     rf, nb_timeouts
            ldn     rf
            plo     rd
            ldi     0
            phi     rd                  ; RD = count (zero-extended)
            mov     rf, nb_buf
            call    f_uintout           ; decimal ASCII at *rf
            ldi     0
            str     rf
            mov     rf, nb_buf
            call    K_MSG

            call    K_INMSG
            db      " of 20",13,10,0

            ldi     0                   ; exit code 0
            rtn

nb_left:        db      0               ; calls still to make
nb_timeouts:    db      0               ; calls that timed out (keep
                                        ; right after nb_left)
nb_char:        db      0               ; the character to show
nb_buf:         ds      6               ; decimal scratch

            end     start
