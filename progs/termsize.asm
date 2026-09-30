;
; termsize.asm - detect the console terminal's row/column count and
; record it as the ROWS/COLUMNS environment variables, and in the
; kernel's TERM_ROWS/TERM_COLS bytes (kernel_api.inc) -- the copy the
; line editor reads, since it needs the width on every input line and
; opening /cfg/env.dat that often would be far too slow.
;
; Usage: TERMSIZE              ask the terminal (VT100 cursor report)
;        TERMSIZE <rows> <cols>  set the size by hand, for a terminal
;                              that does not answer the cursor report
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
            glo     rc                  ; argc
            xri     1
            lbz     query               ; no arguments: ask the terminal
            glo     rc
            xri     3
            lbnz    usage               ; only 0 or 2 arguments

            ; TERMSIZE <rows> <cols>: argv[1], argv[2]
            inc     ra
            inc     ra                  ; RA -> argv[1]
            mov     rf, ts_rowptr
            lda     ra
            str     rf
            inc     rf
            lda     ra
            str     rf                  ; ts_rowptr = argv[1]
            inc     rf
            lda     ra
            str     rf
            inc     rf
            lda     ra
            str     rf                  ; ts_colptr = argv[2]
            lbr     apply

usage:
            call    K_INMSG
            db      "Usage: TERMSIZE [<rows> <cols>]",13,10,0
            ldi     1
            rtn

query:
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

            ; reply is ESC [ <rows> ; <cols> R -- split it in place
            mov     rd, size_buf + 2    ; rows text starts after ESC [
            mov     rf, ts_rowptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ts_rowptr = rows text

find_semi:  ldn     rd                  ; search for ';', replace with NUL
            lbz     bad_reply
            xri     ';'
            lbz     got_semi
            inc     rd
            lbr     find_semi

got_semi:   ldi     0
            str     rd
            inc     rd
            mov     rf, ts_colptr
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; ts_colptr = columns text

find_R:     ldn     rd                  ; search for 'R', replace with NUL
            lbz     bad_reply
            xri     'R'
            lbz     got_R
            inc     rd
            lbr     find_R

got_R:      ldi     0
            str     rd

;------------------------------------------------------------------
; apply: parse ts_rowptr/ts_colptr, store TERM_ROWS/TERM_COLS, then set
; ROWS/COLUMNS. Both are parsed (and rejected if bad) before anything is
; written, so a bad argument changes nothing.
;------------------------------------------------------------------
apply:
            mov     rd, ts_rowptr
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            call    parse_byte          ; D = rows
            lbdf    bad_value
            plo     r9                  ; mov below clobbers D
            mov     rf, ts_rows
            glo     r9
            str     rf

            mov     rd, ts_colptr
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            call    parse_byte          ; D = columns
            lbdf    bad_value
            plo     r9
            mov     rf, TERM_COLS
            glo     r9
            str     rf                  ; kernel's copy of the width
            mov     rf, ts_rows
            ldn     rf
            plo     r9
            mov     rf, TERM_ROWS
            glo     r9
            str     rf                  ; kernel's copy of the height

            mov     rd, ts_rowptr
            lda     rd
            plo     r9
            ldn     rd
            plo     rd
            glo     r9
            phi     rd                  ; RD -> rows text
            mov     rf, rows
            ldi     1
            call    env_setenv          ; ROWS = <rows>

            mov     rd, ts_colptr
            lda     rd
            plo     r9
            ldn     rd
            plo     rd
            glo     r9
            phi     rd                  ; RD -> columns text
            mov     rf, columns
            ldi     1
            call    env_setenv          ; COLUMNS = <columns>

            ldi     0
            rtn

bad_reply:
            call    K_INMSG
            db      "No size reported by the terminal.",13,10,0
            ldi     1
            rtn

bad_value:
            call    K_INMSG
            db      "Invalid size.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; parse_byte: decimal text -> byte, values above 255 stored as 255.
; Args:    RF = NUL-terminated text
; Returns: DF=0, D = value; DF=1 if empty or not all digits
; Modifies: R7, R8, R9, RB, RF (and D). Makes no calls.
;------------------------------------------------------------------
parse_byte:
            ldi     0
            phi     r9
            plo     r9                  ; R9 = value
            plo     r8                  ; R8.0 = digit count
pb_loop:    lda     rf
            lbz     pb_end
            smi     '0'
            lbnf    pb_bad
            plo     r7                  ; R7.0 = digit
            smi     10
            lbdf    pb_bad
            glo     r8
            adi     1
            plo     r8
            ghi     r9
            lbnz    pb_loop             ; already > 255: saturated
            mov     rb, r9
            shl16   r9                  ; x2
            shl16   r9                  ; x4
            add16   r9, rb              ; x5
            shl16   r9                  ; x10
            glo     r7
            plo     rb
            ldi     0
            phi     rb
            add16   r9, rb              ; + digit
            lbr     pb_loop
pb_end:     glo     r8
            lbz     pb_bad              ; no digits
            ghi     r9
            lbz     pb_small
            ldi     255
            clc
            rtn
pb_small:   glo     r9
            clc
            rtn
pb_bad:     stc
            rtn

size_buf:   ds      16                  ; buffer for terminal size response
rows:       db      "ROWS",0
columns:    db      "COLUMNS",0
ts_rowptr:  dw      0
ts_colptr:  dw      0
ts_rows:    db      0

            end     start
