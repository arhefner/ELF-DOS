;
; bootchk.asm - test whether a disk passes the Elf/OS BIOS boot check
;
; Load with the monitor and run it at $2000 (MAX Monitor: L, then G 2000).
; It does what f_boot does in Mike Riley's Elf/OS BIOS (Elf-BIOS,
; bios.asm, bootret and btcheck), using the BIOS that is running:
;
;   1. f_idereset, then read sector 0 of unit 0 (R8.1 = $E0) to $0100.
;   2. The boot check: starting from 0, for each byte of $0100-$0140,
;      value = (value + byte) * 2, mod 256. It must come out to $60.
;      (Riley's code does add, shl, shr, shlc; shr clears the bit that
;      shlc then brings back in, so the three shifts are just a doubling.)
;   3. On a match, jump to $0106 with P=3, X=2, R2 = $00F0 and
;      R8.1 = $E0, as that BIOS does, so whatever is on the disk boots.
;
; It prints the value it computed either way. On a mismatch or a disk
; error it returns to the monitor through the breakpoint vector (MARK,
; SEP R1), which shows the registers. Written from a description of
; Riley's routine, not copied from it.
;
; Unit 0 only, because that is all Riley's f_boot reads.
;

#include    include/bios.inc
#include    include/opcodes.def

            org         $2000

; The monitor's G command runs us with P = X = 0.
start:      mov         r2,bc_stack     ; our own stack
            mov         r6,bc_main      ; f_initcall sets up SCRT,
            lbr         f_initcall      ;  then continues at R6 with P=3

bc_main:    sex         r2
            call        f_inmsg
            db          13,10,"Boot check: reading sector 0 of unit 0 to $0100",13,10,0

            call        f_idereset
            lbdf        bc_rsterr

            ldi         0
            plo         r7
            phi         r7
            plo         r8
            ldi         $E0
            phi         r8
            mov         rf,$0100
            call        f_ideread
            lbdf        bc_rderr

            ; value in RD.0, pointer RF, count RC.0 = 65 bytes
            mov         rf,$0100
            ldi         $41
            plo         rc
            ldi         0
            plo         rd
bc_sum:     lda         rf              ; next byte
            str         r2              ;  to M(R2) for ADD
            glo         rd
            add                         ; value + byte
            shl                         ; times 2
            plo         rd
            dec         rc
            glo         rc
            lbnz        bc_sum

            mov         rf,bc_val       ; keep it in memory: no BIOS call
            glo         rd              ;  is trusted to preserve RD
            str         rf
            call        f_inmsg
            db          "Check value $",0
            call        bc_hex2
            mov         rf,bc_val
            ldn         rf
            xri         $60
            lbnz        bc_fail

            call        f_inmsg
            db          " (needs $60): PASS. Booting...",13,10,0

            ldi         $E0             ; state as Riley's BIOS leaves it
            phi         r8
            mov         r2,$00F0
            sex         r2
            lbr         $0106

bc_fail:    call        f_inmsg
            db          " (needs $60): FAIL. That BIOS would not boot this disk.",13,10,0
            lbr         bc_exit

bc_rsterr:  call        f_inmsg
            db          "Disk reset failed.",13,10,0
            lbr         bc_exit

bc_rderr:   call        f_inmsg
            db          "Disk read failed.",13,10,0

bc_exit:    sex         r2              ; back to the monitor's break routine
            mark
            sep         r1

; Print bc_val as two hex digits.
bc_hex2:    mov         rf,bc_val
            ldn         rf
            shr
            shr
            shr
            shr
            call        bc_nib
            mov         rf,bc_val
            ldn         rf
            ani         $0F
            call        bc_nib
            rtn

; Print the digit for the value 0-15 in D.
bc_nib:     smi         10
            lbdf        bc_letter
            adi         10+'0'
            lbr         bc_out
bc_letter:  adi         'A'
bc_out:     call        f_type          ; a call, never a jump, into the BIOS
            rtn

bc_val:     db          0
            ds          64
bc_stack:   db          0

            end         start
