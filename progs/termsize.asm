;
; termsize.asm - detect the console terminal's row/column count and
; record it as the ROWS/COLUMNS environment variables
;
; Usage: TERMSIZE [-u|-b]
;

#include    include/opcodes.def
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
            call    K_INMSG
            db      ESC,"[s",0

            call    K_INMSG
            db      ESC,"[999;999H",0

getpos:     mov     rf, size_buf

            call    K_INMSG
            db      ESC,"[6n",0

readpos:    call    K_READ
            str     rf
            inc     rf
            xri     'R'
            bnz     readpos
            ldi     0
            str     rf

            call    K_INMSG
            db      ESC,"[u",0

            call    set_env

            ldi     0
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
