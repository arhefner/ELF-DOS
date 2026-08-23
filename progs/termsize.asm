;
; termsize.asm - detect the console terminal's row/column count and
; record it as the ROWS/COLUMNS environment variables
;
; Usage: TERMSIZE [-u|-b]
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

#define ESC 27

            extrn   env_setenv

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[0] is this program's
            ; own name; argv[1], if present, must be exactly "-u" or
            ; "-b" -- no positional argument at all.
            glo     rc
            smi     2
            lbnf    u_setsize           ; argc < 2: no flag given, default

            glo     rc
            smi     3
            lbdf    usage               ; argc > 2: too many arguments

            mov     rb, ra
            inc     rb
            inc     rb                  ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1]

            lda     rf
            xri     '-'
            lbnz    usage

            lda     rf
            plo     r8                  ; R8.0 = flag letter

            ldn     rf                  ; must be NUL for a bare 2-char
                                        ; flag
            lbnz    usage

            glo     r8
            xri     'u'
            lbz     u_setsize
            glo     r8
            xri     'b'
            lbz     b_setsize
            lbr     usage               ; unrecognized flag letter

usage:
            call    K_INMSG
            db      "Usage: TERMSIZE [-u|-b]",13,10,0
            ldi     1
            rtn

u_setsize:  call    u_inmsg
            db      ESC,"[s",0

            call    u_inmsg
            db      ESC,"[999;999H",0

            call    u_getpos

            call    u_inmsg
            db      ESC,"[u",0

            call    set_env

            ldi     0
            rtn

u_getpos:   mov     rf, size_buf

            call    u_inmsg
            db      ESC,"[6n",0

u_readpos:  call    f_uread
            str     rf
            inc     rf
            xri     'R'
            bnz     u_readpos
            ldi     0
            str     rf
            rtn

u_inmsglp:  call    f_utype
u_inmsg:    lda     r6
            bnz     u_inmsglp
            rtn

u_msglp:    call    f_utype
u_msg:      lda     rf
            bnz     u_msglp
            rtn

            .align  page

b_setsize:  call    b_inmsg
            db      ESC,"[s",0

            call    b_inmsg
            db      ESC,"[999;999H",0

            call    b_getpos

            call    b_inmsg
            db      ESC,"[u",0

            call    set_env

            ldi     0
            rtn

b_getpos:   mov     rf, size_buf

            call    b_inmsg
            db      ESC,"[6n",0

b_readpos:  call    f_bread
            str     rf
            inc     rf
            xri     'R'
            bnz     b_readpos
            ldi     0
            str     rf
            rtn

b_inmsglp:  call    f_btype
b_inmsg:    lda     r6
            bnz     b_inmsglp
            rtn

b_msglp:    call    f_btype
b_msg:      lda     rf
            bnz     b_msglp
            rtn

set_env:    mov     rd, size_buf        ; rd -> returned size
find_semi:  ldn     rd                  ; search for ';' and replace with '\0'
            xri     ';'
            bz      set_rows
            inc     rd
            br      find_semi

set_rows:   ldi     0
            str     rd
            inc     rd

            push    rd                  ; save pointer to columns on stack

            mov     rd, size_buf + 2    ; rd -> rows as string
            mov     rf, rows
            ldi     1
            call    env_setenv          ; set ROWS = <rows>

            pop     rd                  ; get pointer to columns
            mov     ra, rd              ; save it in ra

find_R:     ldn     rd                  ; search for 'R' and replace with '\0'
            xri     'R'
            bz      set_cols
            inc     rd
            br      find_R

set_cols:   ldi     0
            str     rd
            mov     rd, ra              ; rd -> columns as string
            mov     rf, columns
            ldi     1
            call    env_setenv          ; set COLUMNS = <columns>

            rtn  

size_buf:   ds      16                  ; buffer for terminal size response
rows:       db      "ROWS",0
columns:    db      "COLUMNS",0

            end     start
