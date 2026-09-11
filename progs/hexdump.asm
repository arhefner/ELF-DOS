;
; hexdump.asm - show a file's contents in hex and ASCII
;
; Usage: HEXDUMP [-c] <filename>
;
; Rows are `hexdump -C` style -- an 8-digit hex offset, the bytes in hex
; (two equal groups), then the same bytes as ASCII between bars:
;
;   00000000  48 65 6c 6c 6f 0a 00 ff  01 02 03 04 05 06 07 08  |Hello...........|
;
; The row length follows the COLUMNS environment variable: the most bytes
; -- a multiple of 4, from 4 to 32 -- whose row fits in COLUMNS-1
; characters, leaving the last column alone (many terminals wrap the
; moment it is written). A row of n bytes is 14 + 4n characters, so an
; 80-column screen (or no COLUMNS at all) gets the usual 16, a 64-column
; one gets 12, and 132 columns get 28. -c follows COLUMNS too.
;
; By default the rows are shown in the pager (lib/pager.asm), with the
; same keys as LESS: SPACE/b page, arrows or j/k scroll a row, g/G top
; and end, / search, n again, q quit. Two things mean something
; different for a hex view, and the hex source decides both:
;   - a number before g jumps to that BYTE OFFSET (typed in decimal),
;     rounded down to its row;
;   - a search matches the file's raw bytes, so a pattern like
;     \x00\xff finds binary data, and a match can span rows.
;
; -c prints every row straight through instead, with no paging, so the
; output can be redirected: HEXDUMP -c file > dump.txt. It reads the
; very same rows from the very same source, so the two modes can never
; disagree about a byte.
;
; Offsets are full 32-bit values, so files over 64K show their real
; offsets. (This program used to format rows itself and kept only a
; 16-bit offset; the formatting now lives in lib/src_hex.asm.)
;
; Below 31 columns even 4 bytes (a 30-character row) cannot fit, and
; rows wrap.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   pager_run
            extrn   src_open
            extrn   src_close
            extrn   src_read_line
            extrn   src_line_buf
            extrn   hx_set_row
            extrn   env_getenv
            extrn   env_parse_uint

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv, RC.0 = argc. The argument scan makes no calls,
            ; so it works in registers: R9.0 = index, R7.0 = -c seen,
            ; R8 = the filename (0 until one is found).
            ldi     0
            plo     r7
            phi     r8
            plo     r8
            ldi     1
            plo     r9

arg_loop:
            glo     rc
            str     r2
            glo     r9
            sm                          ; index - argc
            lbdf    args_done           ; no borrow: index >= argc

            glo     r9
            shl                         ; 2*index (argc <= 16, fits)
            str     r2
            glo     ra
            add
            plo     rd
            ghi     ra
            adci    0
            phi     rd                  ; RD = &argv[index]
            lda     rd
            phi     rb
            ldn     rd
            plo     rb                  ; RB = argv[index]

            ghi     rb
            phi     rf
            glo     rb
            plo     rf                  ; RF = the same, to walk
            ldn     rf
            xri     '-'
            lbnz    arg_name
            inc     rf
            ldn     rf
            ani     $DF                 ; -c or -C
            xri     'C'
            lbnz    usage               ; any other flag
            inc     rf
            ldn     rf
            lbnz    usage               ; "-cx" and the like
            ldi     1
            plo     r7                  ; -c seen
            lbr     arg_next

arg_name:
            ghi     r8
            lbnz    usage               ; a second filename
            glo     r8
            lbnz    usage
            ghi     rb
            phi     r8
            glo     rb
            plo     r8                  ; R8 = the filename

arg_next:
            glo     r9
            adi     1
            plo     r9
            lbr     arg_loop

args_done:
            ghi     r8
            lbnz    have_name
            glo     r8
            lbz     usage               ; no filename at all
have_name:
            mov     rf, hd_continuous
            glo     r7
            str     rf                  ; kept in memory: env_getenv and
            mov     rf, hd_file         ; src_open below clobber every
            ghi     r8                  ; register
            str     rf
            inc     rf
            glo     r8
            str     rf

            ; --- bytes per row from COLUMNS: n = (COLUMNS-15)/4, rounded
            ; down to a multiple of 4 by hx_set_row, and held to 4..32.
            ; Unset or 0 means an 80-column screen. ---
            mov     rf, hd_cols_name
            call    env_getenv          ; RF = value or 0
            ghi     rf
            lbnz    cols_have
            glo     rf
            lbz     cols_default        ; not set
cols_have:
            call    env_parse_uint      ; RD = the value
            ghi     rd
            lbnz    cols_wide           ; 256 or more
            glo     rd
            lbz     cols_default        ; 0
            smi     143
            lbdf    cols_wide           ; 143 or more: 32 bytes fit
            glo     rd
            smi     31
            lbnf    cols_narrow         ; under 31: not even 4 fit
            glo     rd
            smi     15
            shr
            shr                         ; (COLUMNS-15)/4, 4..31
            lbr     cols_set
cols_wide:
            ldi     32
            lbr     cols_set
cols_narrow:
            ldi     4
            lbr     cols_set
cols_default:
            ldi     16
cols_set:
            call    hx_set_row          ; before src_open reads a row

            mov     rf, hd_file
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8
            call    src_open
            lbdf    not_found

            mov     rf, hd_continuous
            ldn     rf
            lbnz    continuous

            mov     rf, hd_name         ; shown on the status line
            ldi     0                   ; options: none (no line numbers)
            call    pager_run
            call    src_close
            ldi     0                   ; exit code 0 = success
            rtn

continuous:
            call    src_read_line
            lbdf    cont_done
            mov     rf, src_line_buf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            lbr     continuous

cont_done:
            call    src_close
            ldi     0
            rtn

not_found:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: HEXDUMP [-c] <filename>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

hd_continuous:  db      0
hd_file:        dw      0           ; the filename argument
hd_name:        db      "HEXDUMP",0
hd_cols_name:   db      "COLUMNS",0

            end     start
