;
; drvdump.asm - dump the kernel's drive tables
;
; Diagnostic for the multi-drive work: prints DRIVE_DATA_PTR's target
; and, for each slot, drive_present[] and drive_letter[], plus cur_drive
; and shell_drive. Reads through the published offsets exactly the way
; MOUNT and UMOUNT do, so a disagreement between what this shows and
; what MOUNT lists localises the fault to one side or the other.
;
; Run it, then UMOUNT a drive, then run it again: if that slot's letter
; is still set, UMOUNT's store went somewhere else; if it is 0 but MOUNT
; still lists the drive, MOUNT's listing is at fault.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            org     PROG_BASE

            db      'E','D','F'
            db      1
            db      0
            db      0

start:
            ; ---- base address ----
            call    K_INMSG
            db      "DRIVE_DATA_PTR -> $",0
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                      ; R9 = base
            ghi     r9
            call    dd_hex2
            glo     r9
            call    dd_hex2
            call    K_INMSG
            db      13,10,"slot present letter",13,10,0

            mov     rf, dd_i
            ldi     0
            str     rf

dd_loop:
            call    K_INMSG
            db      "  ",0
            mov     rf, dd_i
            ldn     rf
            adi     '0'
            call    K_TYPE
            call    K_INMSG
            db      "     ",0

            ; drive_present[i]
            call    dd_base                 ; R9 = base
            mov     rf, dd_i
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, r9
            add16   rf, rd
            ldn     rf
            call    dd_hex2
            call    K_INMSG
            db      "      ",0

            ; drive_letter[i]
            call    dd_base
            mov     rf, dd_i
            ldn     rf
            plo     rd
            ldi     0
            phi     rd
            mov     rf, r9
            add16   rf, DRIVE_LETTER_OFF
            add16   rf, rd
            ldn     rf
            call    dd_hex2
            call    K_INMSG
            db      13,10,0

            mov     rf, dd_i
            ldn     rf
            adi     1
            str     rf
            smi     DRIVE_COUNT
            lbnf    dd_loop

            ; ---- cur_drive / shell_drive ----
            call    K_INMSG
            db      "cur_drive   = $",0
            call    dd_base
            mov     rf, r9
            add16   rf, CUR_DRIVE_OFF
            ldn     rf
            call    dd_hex2
            call    K_INMSG
            db      13,10,"shell_drive = $",0
            call    K_GETSHELLDRIVE
            call    dd_hex2
            call    K_INMSG
            db      13,10,0

            ldi     0
            rtn

;------------------------------------------------------------------
; dd_base: R9 = DRIVE_DATA_PTR's target
;------------------------------------------------------------------
dd_base:
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            rtn

;------------------------------------------------------------------
; dd_hex2: print D as two hex digits.
; Deliberately hand-rolled rather than f_hexout2 -- that routine has no
; confirmed caller anywhere in this codebase, and a diagnostic is a bad
; place to debut an unproven BIOS contract.
; Modifies: D, R8, RF
;------------------------------------------------------------------
dd_hex2:
            plo     r8                      ; hold it while the mov below
            mov     rf, dd_byte             ; clobbers D (gotcha #4)
            glo     r8
            str     rf                      ; dd_byte = the byte. NOT a
                                            ; register: dd_nib uses R8
                                            ; itself, and K_TYPE has no
                                            ; proven contract for RB/R8.
            ldn     rf
            shr
            shr
            shr
            shr
            call    dd_nib                  ; high nibble

            mov     rf, dd_byte
            ldn     rf
            ani     $0F
            call    dd_nib                  ; low nibble
            rtn

dd_nib:
            plo     r8                      ; R8.0 = this nibble
            smi     10
            lbdf    dd_alpha
            glo     r8
            adi     '0'
            lbr     dd_emit
dd_alpha:
            glo     r8
            adi     'A' - 10
dd_emit:
            call    K_TYPE
            rtn

dd_i:       db      0
dd_byte:    db      0
