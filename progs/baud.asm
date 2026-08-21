            ; Include kernel API entry points

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

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
            ; program's own name; argv[1] is the rate argument.
            glo     rc
            smi     2
            lbnf    usage               ; argc < 2: no rate given

            mov     rb, ra
            inc     rb
            inc     rb                  ; RB = &argv[1]
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] (the rate argument)

            call    f_atoi
            bdf     bad                 ; couldn't convert to number
            ldn     rf
            bnz     bad                 ; extra characters after number

            mov     ra, table

            ldi     (table_end-table)/3
            plo     rc

compare:    lda     ra
            str     r2
            ghi     rd
            xor
            bnz     hi_mis
            lda     ra
            str     r2
            glo     rd
            xor
            bnz     lo_mis
            ldn     ra
            call    f_usetbd
            ldi     0
            rtn

hi_mis:     inc     ra
lo_mis:     inc     ra

            dec     rc
            glo     rc
            bnz     compare

bad:        call    K_INMSG
            db      'Invalid baud rate.'13,10,0
            ldi     2                   ; exit code 2 = invalid rate
            rtn

usage:      call    K_INMSG
            db      'Usage: baud <baudrate>',13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

table:      dw      300
            db      $30
            dw      1200
            db      $31
            dw      2400
            db      $32
            dw      4800
            db      $33
            dw      9600
            db      $34
            dw      19200
            db      $35
            dw      38400
            db      $36
            dw      57600
            db      $37
table_end:

            end     start
