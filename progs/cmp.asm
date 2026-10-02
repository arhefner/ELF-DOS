;
; cmp.asm - compare two files byte by byte
;
; Usage: CMP [-l] [-s] [-b] [-n <count>] [-i <skip>[:<skip2>]]
;            <file1> <file2> [<skip1> [<skip2>]]
;
; Modelled on the Unix cmp:
;
;   (no option)  stop at the first difference and print
;                    <file1> <file2> differ: byte N, line M
;   -l           list every differing byte: its number (decimal) and
;                the two byte values (octal)
;   -s           print nothing; the exit code is the only answer
;   -b           also show the differing bytes: each one's octal value
;                and the character itself (^X for a control character,
;                M- before a byte of 128 or more)
;   -n <count>   compare at most <count> bytes
;   -i <skip>    skip the first <skip> bytes of both files, or
;   -i <a>:<b>   <a> bytes of file 1 and <b> bytes of file 2. Byte and
;                line numbers then count from the first byte compared.
;                A skip past the end of a file leaves it at its end.
;   <skip1> <skip2>  after the file names: the same thing as
;                -i <skip1>:<skip2>. Each one given replaces that
;                file's -i value; one left out keeps it (0 without -i).
;
; <count> and <skip> are decimal, up to 4294967295, and may be joined
; to the flag (-n100) or follow it as the next argument (-n 100).
;
; Byte and line numbers start at 1. If one file is a prefix of the
; other, "cmp: EOF on <shorter file> ..." is printed. Flags may be
; upper or lower case and may be combined (-ls is refused: the two
; cannot be used together).
;
; Exit code: 0 = identical, 1 = different, 2 = trouble (bad arguments,
; a file that cannot be opened, a read error).
;
; Both files are read CMP_CHUNK bytes at a time. The compare loop makes
; no calls, so its state lives in registers (RF/RD = cursors, RC =
; bytes left, R8 = newlines seen in this chunk); everything else is in
; memory and reloaded after each kernel call.
;
; Links lib/fmt32.prg (fmt_uint32, for 32-bit byte and line numbers).
;

#include    include/opcodes.def
#include    include/kernel_api.inc

            extrn   fmt_uint32          ; lib/fmt32.asm

CMP_CHUNK:  equ     512

CMP_F_LIST: equ     1                   ; -l
CMP_F_SILENT: equ   2                   ; -s
CMP_F_BYTES: equ    4                   ; -b
CMP_F_LIMIT: equ    8                   ; -n
CMP_F_SKIP: equ     16                  ; -i, or a skip operand
CMP_F_OP1:  equ     32                  ; <skip1> operand given
CMP_F_OP2:  equ     64                  ; <skip2> operand given

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
; RA = argv, RC = argc
;------------------------------------------------------------------
start:
            ; ---- argument parsing ----
            ; RA = &argv[i], RC.0 = arguments left, RC.1 = file names
            ; seen. Flags go straight into cmp_flags. None of the
            ; routines called here touch RA or RC.
            ldi     0
            phi     rc
            inc     ra
            inc     ra                  ; RA = &argv[1]
arg_loop:
            dec     rc
            glo     rc
            lbz     arg_done
            lda     ra
            phi     rf
            lda     ra
            plo     rf                  ; RF = this argument
            ldn     rf
            xri     '-'
            lbz     arg_flag

            ; a file name
            ghi     rc
            lbnz    arg_second
            mov     rb, cmp_name1
            lbr     arg_store
arg_second:
            smi     1
            lbnz    arg_skip1
            mov     rb, cmp_name2
arg_store:
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            lbr     arg_count

            ; third and fourth operands: <skip1>, <skip2>. Kept apart
            ; from -i's values until every argument has been read, so
            ; they win wherever -i appears on the line.
arg_skip1:
            smi     1
            lbnz    arg_skip2
            call    parse_operand       ; RD:R8 = value
            lbdf    usage
            mov     rb, cmp_op1
            call    store32
            ldi     $30                 ; CMP_F_OP1 + CMP_F_SKIP
            lbr     arg_skipset
arg_skip2:
            smi     1
            lbnz    usage               ; a fifth operand
            call    parse_operand
            lbdf    usage
            mov     rb, cmp_op2
            call    store32
            ldi     $50                 ; CMP_F_OP2 + CMP_F_SKIP
arg_skipset:
            call    set_flag
arg_count:
            ghi     rc
            adi     1
            phi     rc
            lbr     arg_loop

arg_flag:
            inc     rf                  ; past the '-'
            ldn     rf
            lbz     usage               ; a bare "-"
flag_loop:
            lda     rf
            lbz     arg_loop
            ori     $20                 ; fold to lower case
            plo     rb
            xri     'l'
            lbz     flag_l
            glo     rb
            xri     's'
            lbz     flag_s
            glo     rb
            xri     'b'
            lbz     flag_b
            glo     rb
            xri     'n'
            lbz     flag_n
            glo     rb
            xri     'i'
            lbz     flag_i
            lbr     usage
flag_l:
            ldi     CMP_F_LIST
            lbr     flag_simple
flag_s:
            ldi     CMP_F_SILENT
            lbr     flag_simple
flag_b:
            ldi     CMP_F_BYTES
flag_simple:
            call    set_flag            ; keeps RF
            lbr     flag_loop

            ; -n <count>
flag_n:
            call    flag_value
            lbdf    usage
            call    parse_u32           ; RD:R8 = count
            lbdf    usage
            ldn     rf
            lbnz    usage               ; something after the number
            mov     rb, cmp_limit
            call    store32
            ldi     CMP_F_LIMIT
            call    set_flag
            lbr     arg_loop

            ; -i <skip>[:<skip2>]
flag_i:
            call    flag_value
            lbdf    usage
            call    parse_u32
            lbdf    usage
            mov     rb, cmp_skip1
            call    store32
            mov     rb, cmp_skip2
            call    store32             ; one number: both files
            ldn     rf
            lbz     flag_i_done
            xri     ':'
            lbnz    usage
            inc     rf
            call    parse_u32
            lbdf    usage
            ldn     rf
            lbnz    usage
            mov     rb, cmp_skip2
            call    store32
flag_i_done:
            ldi     CMP_F_SKIP
            call    set_flag
            lbr     arg_loop

arg_done:
            ghi     rc
            smi     2
            lbnf    usage               ; need two file names

            ; skip operands replace -i's values
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_OP1
            lbz     arg_no_op1
            mov     ra, cmp_op1
            mov     rb, cmp_skip1
            call    copy32
arg_no_op1:
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_OP2
            lbz     arg_no_op2
            mov     ra, cmp_op2
            mov     rb, cmp_skip2
            call    copy32
arg_no_op2:
            mov     rb, cmp_flags
            ldn     rb
            ani     3
            xri     3                   ; CMP_F_LIST + CMP_F_SILENT
            lbz     usage               ; -l and -s together

            ; ---- open both files ----
            mov     rb, cmp_name1
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, cmp_fcb1
            mov     ra, cmp_iobuf1
            ldi     0                   ; mode = read
            call    K_FILE_OPEN
            lbdf    open1_fail

            mov     rb, cmp_name2
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rd, cmp_fcb2
            mov     ra, cmp_iobuf2
            ldi     0
            call    K_FILE_OPEN
            lbdf    open2_fail

            ; ---- -i: start each file at its skip offset ----
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_SKIP
            lbz     chunk_loop
            mov     rb, cmp_skip1
            mov     rd, cmp_fcb1
            call    do_skip
            mov     rb, cmp_skip2
            mov     rd, cmp_fcb2
            call    do_skip

;------------------------------------------------------------------
; Read one chunk from each file.
;------------------------------------------------------------------
chunk_loop:
            ; bytes to ask for: CMP_CHUNK, or what is left of -n's
            ; count when that is smaller
            mov     r9, CMP_CHUNK
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_LIMIT
            lbz     have_req
            mov     rb, cmp_limit
            lda     rb
            lbnz    have_req
            lda     rb
            lbnz    have_req
            lda     rb
            phi     r7
            ldn     rb
            plo     r7                  ; R7 = low word of what is left
            ghi     r7
            smi     high CMP_CHUNK      ; CMP_CHUNK's low byte is 0, so
            lbdf    have_req            ; the high bytes decide
            ghi     r7
            phi     r9
            glo     r7
            plo     r9
            lbnz    have_req
            ghi     r9
            lbz     all_done            ; the count is used up
have_req:
            mov     rb, cmp_req
            ghi     r9
            str     rb
            inc     rb
            glo     r9
            str     rb

            mov     rb, cmp_req
            lda     rb
            phi     rc
            ldn     rb
            plo     rc
            mov     rf, cmp_buf1
            mov     rd, cmp_fcb1
            call    K_FILE_READ         ; RC = bytes read
            lbdf    read1_fail
            mov     rb, cmp_c1
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            mov     rb, cmp_req
            lda     rb
            phi     rc
            ldn     rb
            plo     rc
            mov     rf, cmp_buf2
            mov     rd, cmp_fcb2
            call    K_FILE_READ
            lbdf    read2_fail
            mov     rb, cmp_c2
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            ; RC = min(c1, c2): the number of bytes to compare
            mov     rb, cmp_c1
            lda     rb
            phi     r9
            ldn     rb
            plo     r9                  ; R9 = c1, RC = c2
            glo     r9
            str     r2
            glo     rc
            sm
            ghi     r9
            str     r2
            ghi     rc
            smb                         ; DF=1: c2 >= c1
            lbnf    have_n
            ghi     r9
            phi     rc
            glo     r9
            plo     rc                  ; RC = c1
have_n:
            mov     rb, cmp_n
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb

            mov     rf, cmp_buf1
            mov     rd, cmp_buf2
            ldi     0
            phi     r8
            plo     r8                  ; R8 = newlines in this chunk

;------------------------------------------------------------------
; Compare loop. No calls. RF/RD = cursors, RC = bytes left,
; R8 = newlines passed.
;------------------------------------------------------------------
cmp_loop:
            glo     rc
            lbnz    cmp_go
            ghi     rc
            lbz     chunk_done
cmp_go:
            lda     rd
            str     r2                  ; M(R2) = file 2's byte
            lda     rf                  ; D = file 1's byte
            xor
            lbnz    mismatch
cmp_next:
            dec     rc
            ldn     r2
            xri     10
            lbnz    cmp_loop
            inc     r8                  ; a newline
            lbr     cmp_loop

;------------------------------------------------------------------
; The compared bytes of this chunk are done (RF = cmp_buf1 + n).
;------------------------------------------------------------------
chunk_done:
            ghi     r8
            phi     r9
            glo     r8
            plo     r9
            mov     rb, cmp_lines
            call    add32_16            ; lines += newlines

            mov     rb, cmp_n
            lda     rb
            phi     r9
            ldn     rb
            plo     r9                  ; R9 = n
            lbnz    cd_last
            ghi     r9
            lbz     cd_nolast
cd_last:
            dec     rf
            ldn     rf                  ; last byte compared
            plo     r7
            mov     rb, cmp_last
            glo     r7
            str     rb
cd_nolast:
            mov     rb, cmp_base
            call    add32_16            ; base += n
            mov     rb, cmp_limit
            call    sub32_16            ; -n's count -= n (unused, and
                                        ; harmless, without -n)

            mov     rb, cmp_c1
            lda     rb
            phi     r9
            lda     rb
            plo     r9                  ; R9 = c1
            lda     rb
            phi     r7
            ldn     rb
            plo     r7                  ; R7 = c2 (cmp_c2 follows cmp_c1)

            glo     r7
            str     r2
            glo     r9
            xor
            lbnz    cd_uneven
            ghi     r7
            str     r2
            ghi     r9
            xor
            lbnz    cd_uneven

            ; same count from both
            glo     r9
            lbnz    chunk_loop
            ghi     r9
            lbnz    chunk_loop

            ; both files ended together, or -n's count is used up
all_done:
            call    close_both
            mov     rb, cmp_differ
            ldn     rb                  ; 0 = identical, 1 = -l found some
            rtn

cd_uneven:
            glo     r7
            str     r2
            glo     r9
            sm
            ghi     r7
            str     r2
            ghi     r9
            smb                         ; DF=0: c1 < c2, file 1 ended
            mov     rb, cmp_name1
            lbnf    eof_on
            mov     rb, cmp_name2

;------------------------------------------------------------------
; One file ended first. RB = address of that file's name pointer.
;------------------------------------------------------------------
eof_on:
            lda     rb
            phi     r7
            ldn     rb
            plo     r7
            mov     rb, cmp_eofname
            ghi     r7
            str     rb
            inc     rb
            glo     r7
            str     rb

            call    close_both
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_SILENT
            lbnz    exit_differ

            call    K_INMSG
            db      "cmp: EOF on ",0
            mov     rb, cmp_eofname
            call    print_ptr

            ; anything before the end?
            mov     rb, cmp_base
            lda     rb
            lbnz    eof_after
            lda     rb
            lbnz    eof_after
            lda     rb
            lbnz    eof_after
            ldn     rb
            lbnz    eof_after
            call    K_INMSG
            db      " which is empty",13,10,0
            lbr     exit_differ

eof_after:
            call    K_INMSG
            db      " after byte ",0
            mov     rb, cmp_base
            call    print_num32

            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_LIST
            lbnz    eof_crlf            ; -l: no line number

            mov     ra, cmp_lines
            call    copy_to_num
            mov     rb, cmp_last
            ldn     rb
            xri     10
            lbnz    eof_inline
            call    K_INMSG
            db      ", line ",0
            lbr     eof_line
eof_inline:
            ; the file ends part way through a line
            mov     r9, 1
            mov     rb, cmp_num
            call    add32_16
            call    K_INMSG
            db      ", in line ",0
eof_line:
            mov     rb, cmp_num
            call    print_num32
eof_crlf:
            call    K_INMSG
            db      13,10,0
exit_differ:
            ldi     1
            rtn

;------------------------------------------------------------------
; Two bytes differ. M(R2) = file 2's byte, RF/RD are one past the
; pair, RC has not been decremented for it yet.
;------------------------------------------------------------------
mismatch:
            ldn     r2
            plo     r7                  ; R7.0 = file 2's byte
            dec     rf
            ldn     rf
            phi     r7                  ; R7.1 = file 1's byte
            inc     rf

            mov     rb, cmp_save        ; save the loop's registers
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            inc     rb
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb
            inc     rb
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb
            inc     rb
            ghi     r7
            str     rb
            inc     rb
            glo     r7
            str     rb

            mov     rb, cmp_differ
            ldi     1
            str     rb

            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_SILENT
            lbz     mm_report
            call    close_both
            lbr     exit_differ

mm_report:
            ; cmp_num = base + (RF - cmp_buf1): this byte's number,
            ; counting from 1 (RF is already one past it)
            glo     rf
            smi     low cmp_buf1
            plo     r9
            ghi     rf
            smbi    high cmp_buf1
            phi     r9
            mov     ra, cmp_base
            call    copy_to_num         ; keeps R9
            mov     rb, cmp_num
            call    add32_16

            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_LIST
            lbnz    mm_list

            ; ---- first difference: report it and stop ----
            mov     rb, cmp_name1
            call    print_ptr
            call    K_INMSG
            db      " ",0
            mov     rb, cmp_name2
            call    print_ptr
            call    K_INMSG
            db      " differ: byte ",0
            mov     rb, cmp_num
            call    print_num32
            call    K_INMSG
            db      ", line ",0

            ; line = newlines before this byte + 1
            mov     ra, cmp_lines
            call    copy_to_num
            mov     rb, cmp_save+6
            lda     rb
            phi     r9
            ldn     rb
            plo     r9                  ; R9 = newlines in this chunk
            inc     r9
            mov     rb, cmp_num
            call    add32_16
            mov     rb, cmp_num
            call    print_num32

            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_BYTES
            lbz     mm_crlf
            call    K_INMSG             ; -b: " is 141 a 142 b"
            db      " is ",0
            mov     rf, cmp_obuf
            ldi     0
            plo     r8                  ; no padding
            mov     rb, cmp_save+8
            ldn     rb                  ; file 1's byte
            call    put_byte
            ldi     ' '
            str     rf
            inc     rf
            mov     rb, cmp_save+9
            ldn     rb                  ; file 2's byte
            call    put_byte
            ldi     0
            str     rf
            mov     rf, cmp_obuf
            call    K_MSG
mm_crlf:
            call    K_INMSG
            db      13,10,0
            call    close_both
            lbr     exit_differ

            ; ---- -l: print "<byte> <octal> <octal>", carry on ----
            ; (with -b: "<byte> <octal> <char> <octal> <char>", the
            ; first character padded to 4 columns)
mm_list:
            mov     rb, cmp_num
            call    print_num32
            mov     rf, cmp_obuf
            ldi     ' '
            str     rf
            inc     rf
            ldi     4
            plo     r8
            mov     rb, cmp_save+8
            ldn     rb                  ; file 1's byte
            call    put_byte
            ldi     ' '
            str     rf
            inc     rf
            ldi     0
            plo     r8
            mov     rb, cmp_save+9
            ldn     rb                  ; file 2's byte
            call    put_byte
            ldi     13
            str     rf
            inc     rf
            ldi     10
            str     rf
            inc     rf
            ldi     0
            str     rf
            mov     rf, cmp_obuf
            call    K_MSG

            mov     rb, cmp_save        ; back into the compare loop
            lda     rb
            phi     rf
            lda     rb
            plo     rf
            lda     rb
            phi     rd
            lda     rb
            plo     rd
            lda     rb
            phi     rc
            lda     rb
            plo     rc
            lda     rb
            phi     r8
            lda     rb
            plo     r8
            dec     rc                  ; this pair is done
            lbr     cmp_loop

;------------------------------------------------------------------
; Errors
;------------------------------------------------------------------
open2_fail:
            mov     rd, cmp_fcb1
            call    K_FILE_CLOSE
            mov     rb, cmp_name2
            lbr     open_fail
open1_fail:
            mov     rb, cmp_name1
open_fail:
            lda     rb
            phi     r7
            ldn     rb
            plo     r7
            mov     rb, cmp_eofname
            ghi     r7
            str     rb
            inc     rb
            glo     r7
            str     rb
            call    K_INMSG
            db      "cmp: cannot open ",0
            lbr     fail_name

read2_fail:
            mov     rb, cmp_name2
            lbr     read_fail
read1_fail:
            mov     rb, cmp_name1
read_fail:
            lda     rb
            phi     r7
            ldn     rb
            plo     r7
            mov     rb, cmp_eofname
            ghi     r7
            str     rb
            inc     rb
            glo     r7
            str     rb
            call    close_both
            call    K_INMSG
            db      "cmp: read error on ",0
fail_name:
            mov     rb, cmp_eofname
            call    print_ptr
            call    K_INMSG
            db      13,10,0
            ldi     2
            rtn

usage:
            call    K_INMSG
            db      "Usage: CMP [-l] [-s] [-b] [-n <count>] [-i <skip>[:<skip2>]]",13,10
            db      "           <file1> <file2> [<skip1> [<skip2>]]",13,10
            db      "  -l  list every differing byte (number, octal values)",13,10
            db      "  -s  print nothing, just set the exit code (0 same, 1 different)",13,10
            db      "  -b  also show the differing bytes as characters",13,10
            db      "  -n  compare at most <count> bytes",13,10
            db      "  -i  skip the first <skip> bytes of both files (a:b = of each)",13,10
            db      "  <skip1> <skip2>  bytes to skip in each file, replacing -i's values",13,10,0
            ldi     2
            rtn

;------------------------------------------------------------------
; set_flag: cmp_flags |= D.
; Modifies: R7, RB, D
;------------------------------------------------------------------
set_flag:
            plo     r7
            mov     rb, cmp_flags
            ldn     rb
            str     r2
            glo     r7
            or
            str     rb
            rtn

;------------------------------------------------------------------
; flag_value: find the value of a -n/-i flag. RF = the text right
; after the flag letter: the value itself if there is any, otherwise
; the value is the next argument.
; Returns: RF = value text, DF=1 if there is no next argument
; Modifies: RA, RC (the argument cursor), RF, D
;------------------------------------------------------------------
flag_value:
            ldn     rf
            lbnz    fv_ok
            dec     rc
            glo     rc
            lbz     fv_none
            lda     ra
            phi     rf
            lda     ra
            plo     rf
fv_ok:
            clc
            rtn
fv_none:
            stc
            rtn

;------------------------------------------------------------------
; parse_operand: read a whole argument as a decimal number.
; Args: RF = the argument
; Returns: RD:R8 = value, DF=1 if it is not a number or is too large
; Modifies: as parse_u32
;------------------------------------------------------------------
parse_operand:
            call    parse_u32
            lbdf    op_bad
            ldn     rf
            lbnz    op_bad              ; something after the digits
            clc
            rtn
op_bad:
            stc
            rtn

;------------------------------------------------------------------
; parse_u32: read a decimal number at RF.
; Returns: RD:R8 = value, RF = the first character after the digits,
;          DF=1 if there were no digits or the value passes 32 bits
; Modifies: R7, R8, R9, RB, RD, RF, D
;------------------------------------------------------------------
parse_u32:
            ldi     0
            phi     rd
            plo     rd
            phi     r8
            plo     r8
            plo     rb                  ; RB.0 = digits read
pu_loop:
            ldn     rf
            smi     '0'
            lbnf    pu_end
            smi     10
            lbdf    pu_end              ; not a digit

            ; value = value * 10: (value*2) + (value*2)*4
            call    shl32
            lbdf    pu_bad
            ghi     rd
            phi     r7
            glo     rd
            plo     r7
            ghi     r8
            phi     r9
            glo     r8
            plo     r9                  ; R7:R9 = value * 2
            call    shl32
            lbdf    pu_bad
            call    shl32
            lbdf    pu_bad
            glo     r9
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r9
            str     r2
            ghi     r8
            adc
            phi     r8
            glo     r7
            str     r2
            glo     rd
            adc
            plo     rd
            ghi     r7
            str     r2
            ghi     rd
            adc
            phi     rd
            lbdf    pu_bad

            ; value += digit
            lda     rf
            smi     '0'
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r8
            adci    0
            phi     r8
            glo     rd
            adci    0
            plo     rd
            ghi     rd
            adci    0
            phi     rd
            lbdf    pu_bad
            inc     rb
            lbr     pu_loop
pu_end:
            glo     rb
            lbz     pu_bad              ; no digits at all
            clc
            rtn
pu_bad:
            stc
            rtn

;------------------------------------------------------------------
; shl32: RD:R8 <<= 1. Returns DF = the bit shifted out.
; Modifies: R8, RD, D
;------------------------------------------------------------------
shl32:
            glo     r8
            shl
            plo     r8
            ghi     r8
            shlc
            phi     r8
            glo     rd
            shlc
            plo     rd
            ghi     rd
            shlc
            phi     rd
            rtn

;------------------------------------------------------------------
; store32: write RD:R8 to the 4 bytes at RB (big-endian).
; Modifies: RB, D. Keeps RD, R8, RF.
;------------------------------------------------------------------
store32:
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            inc     rb
            ghi     r8
            str     rb
            inc     rb
            glo     r8
            str     rb
            rtn

;------------------------------------------------------------------
; do_skip: position a file at the 32-bit offset stored at RB. An
; offset past the end of the file leaves it at its end, so the file
; then reads as empty.
; Args: RB = address of the offset, RD = FCB
; Modifies: everything
;------------------------------------------------------------------
do_skip:
            lda     rb
            phi     ra
            lda     rb
            plo     ra
            lda     rb
            phi     r9
            ldn     rb
            plo     r9                  ; RA:R9 = offset
            mov     rb, cmp_skfcb
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            ldi     0                   ; SEEK_SET
            plo     rc
            call    K_FILE_SEEK
            lbnf    ds_done
            mov     rb, cmp_skfcb
            lda     rb
            phi     rd
            ldn     rb
            plo     rd
            ldi     0
            phi     ra
            plo     ra
            phi     r9
            plo     r9
            ldi     2                   ; SEEK_END + 0
            plo     rc
            call    K_FILE_SEEK
ds_done:
            rtn

;------------------------------------------------------------------
; close_both: close both files.
; Modifies: everything
;------------------------------------------------------------------
close_both:
            mov     rd, cmp_fcb1
            call    K_FILE_CLOSE
            mov     rd, cmp_fcb2
            call    K_FILE_CLOSE
            rtn

;------------------------------------------------------------------
; print_ptr: print the string whose address is stored at RB.
; Modifies: everything
;------------------------------------------------------------------
print_ptr:
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; print_num32: print the 32-bit big-endian value at RB, in decimal.
; Modifies: everything
;------------------------------------------------------------------
print_num32:
            lda     rb
            phi     rd
            lda     rb
            plo     rd
            lda     rb
            phi     r8
            ldn     rb
            plo     r8                  ; RD:R8 = value
            mov     rf, cmp_numbuf
            call    fmt_uint32
            mov     rf, cmp_numbuf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; copy_to_num: cmp_num = the 32-bit value at RA.
; copy32: the 4 bytes at RB = the 4 bytes at RA.
; Modifies: RA, RB, D. Keeps R9.
;------------------------------------------------------------------
copy_to_num:
            mov     rb, cmp_num
copy32:
            lda     ra
            str     rb
            inc     rb
            lda     ra
            str     rb
            inc     rb
            lda     ra
            str     rb
            inc     rb
            ldn     ra
            str     rb
            rtn

;------------------------------------------------------------------
; add32_16: add R9 to the 32-bit big-endian value at RB.
; Modifies: RB, D, DF. (ldn/str/dec/glo/ghi leave DF alone, so the
; carry runs through the four bytes.)
;------------------------------------------------------------------
add32_16:
            inc     rb
            inc     rb
            inc     rb                  ; RB -> low byte
            ldn     rb
            str     r2
            glo     r9
            add
            str     rb
            dec     rb
            ldn     rb
            str     r2
            ghi     r9
            adc
            str     rb
            dec     rb
            ldn     rb
            adci    0
            str     rb
            dec     rb
            ldn     rb
            adci    0
            str     rb
            rtn

;------------------------------------------------------------------
; sub32_16: subtract R9 from the 32-bit big-endian value at RB.
; Modifies: RB, D, DF
;------------------------------------------------------------------
sub32_16:
            inc     rb
            inc     rb
            inc     rb                  ; RB -> low byte
            glo     r9
            str     r2
            ldn     rb
            sm
            str     rb
            dec     rb
            ghi     r9
            str     r2
            ldn     rb
            smb
            str     rb
            dec     rb
            ldn     rb
            smbi    0
            str     rb
            dec     rb
            ldn     rb
            smbi    0
            str     rb
            rtn

;------------------------------------------------------------------
; put_byte: write one differing byte at RF: three octal digits and,
; with -b, a space and the character itself, padded with spaces to
; R8.0 columns.
; Args: D = the byte, R8.0 = width of the character column (0 = none)
; Modifies: R7, R9, RB, D, DF. RF is left past what was written.
;------------------------------------------------------------------
put_byte:
            plo     r7
            call    put_octal
            mov     rb, cmp_flags
            ldn     rb
            ani     CMP_F_BYTES
            lbz     pb_done
            ldi     ' '
            str     rf
            inc     rf
            glo     r7
            call    put_vis             ; R9.1 = characters written
pb_pad:
            ghi     r9
            str     r2
            glo     r8
            sm                          ; width - written
            lbnf    pb_done
            lbz     pb_done
            ldi     ' '
            str     rf
            inc     rf
            ghi     r9
            adi     1
            phi     r9
            lbr     pb_pad
pb_done:
            rtn

;------------------------------------------------------------------
; put_vis: write D at RF the way cat -v shows it: "M-" before a byte
; of 128 or more, then ^X for a control character (^? for 127), or
; the character itself.
; Returns: R9.1 = characters written (1-4), RF past them
; Modifies: R9, D, DF
;------------------------------------------------------------------
put_vis:
            plo     r9
            ldi     0
            phi     r9
            glo     r9
            ani     $80
            lbz     pv_low
            ldi     'M'
            str     rf
            inc     rf
            ldi     '-'
            str     rf
            inc     rf
            ldi     2
            phi     r9
            glo     r9
            ani     $7F
            plo     r9
pv_low:
            glo     r9
            smi     32
            lbdf    pv_notctl
            glo     r9
            adi     64                  ; ^@ ^A ...
            plo     r9
            lbr     pv_caret
pv_notctl:
            glo     r9
            xri     127
            lbnz    pv_put
            ldi     '?'
            plo     r9
pv_caret:
            ldi     '^'
            str     rf
            inc     rf
            ghi     r9
            adi     1
            phi     r9
pv_put:
            glo     r9
            str     rf
            inc     rf
            ghi     r9
            adi     1
            phi     r9
            rtn

;------------------------------------------------------------------
; put_octal: write D as three octal digits at RF, leading zeros as
; spaces (Unix cmp's "%3o"). RF is left past them.
; Modifies: R9, D, DF
;------------------------------------------------------------------
put_octal:
            plo     r9                  ; R9.0 = the byte
            shr
            shr
            shr
            shr
            shr
            shr                         ; top two bits
            phi     r9                  ; R9.1 = nonzero once a digit
                                        ; has been written
            lbz     po_blank1
            adi     '0'
            lskp
po_blank1:
            ldi     ' '
            str     rf
            inc     rf

            glo     r9
            shr
            shr
            shr
            ani     7
            lbnz    po_digit2
            ghi     r9
            lbnz    po_zero2
            ldi     ' '
            lbr     po_store2
po_zero2:
            ldi     0
po_digit2:
            adi     '0'
po_store2:
            str     rf
            inc     rf

            glo     r9
            ani     7
            adi     '0'
            str     rf
            inc     rf
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
cmp_name1:      dw      0               ; file 1's name
cmp_name2:      dw      0               ; file 2's name
cmp_eofname:    dw      0               ; the name a message is about
cmp_flags:      db      0               ; CMP_F_*
cmp_differ:     db      0               ; 1 once a difference is found
cmp_last:       db      0               ; the last byte compared
cmp_base:       db      0,0,0,0         ; bytes compared so far
cmp_lines:      db      0,0,0,0         ; newlines passed so far
cmp_num:        db      0,0,0,0         ; scratch for a number to print
cmp_c1:         dw      0               ; bytes read from file 1
cmp_c2:         dw      0               ; bytes read from file 2 (must
                                        ; follow cmp_c1)
cmp_n:          dw      0               ; bytes to compare in this chunk
cmp_req:        dw      0               ; bytes to ask for in this chunk
cmp_limit:      db      0,0,0,0         ; -n: bytes still to compare
cmp_skip1:      db      0,0,0,0         ; -i: file 1's starting offset
cmp_skip2:      db      0,0,0,0         ; -i: file 2's starting offset
cmp_op1:        db      0,0,0,0         ; <skip1> operand
cmp_op2:        db      0,0,0,0         ; <skip2> operand
cmp_skfcb:      dw      0               ; do_skip's FCB
cmp_save:       ds      10              ; RF, RD, RC, R8, R7
cmp_numbuf:     ds      12
cmp_obuf:       ds      28

.align  32                  ; an FCB must not straddle a page
cmp_fcb1:       ds      FCB_LEN
cmp_fcb2:       ds      FCB_LEN
#if (cmp_fcb1 & $FF) > (256 - FCB_LEN)
#error cmp_fcb1 crosses a page boundary
#endif
#if (cmp_fcb2 & $FF) > (256 - FCB_LEN)
#error cmp_fcb2 crosses a page boundary
#endif
cmp_iobuf1:     ds      FCB_IOBUF_LEN
cmp_iobuf2:     ds      FCB_IOBUF_LEN
cmp_buf1:       ds      CMP_CHUNK
cmp_buf2:       ds      CMP_CHUNK

            end     start
