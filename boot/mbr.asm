;
; mbr.asm - Master Boot Record boot code
;
; Written by ROM f_boot to $0100, entered at $0106.
; Sets up the stack, resets the IDE/SD subsystem, loads the
; kernel bootstrap sector (sector 1) to $3000, and jumps to
; the bootstrap entry point at $3006.
;
; Binary must be exactly 512 bytes:
;   $0100-$01BD  boot code (446 bytes max)
;   $01BE-$01FD  partition table (4 x 16 bytes, written by fdisk)
;   $01FE-$01FF  MBR boot signature ($55, $AA)
;
; NOTE: the install tool (installmbr) should read the existing
; sector 0, replace only bytes 0-445 with new boot code, and
; write back -- preserving the partition table and signature.
;

#include    include/bios.inc
#include    include/opcodes.def

#define     KERN_LOAD   $3000           ; kernel bootstrap loads here
#define     KERN_ENTRY  $3006           ; kernel bootstrap entry point

            org         $0100

;--------------------------------------------------------------
; 6-byte header ($0100-$0105)
; f_boot enters at $0106, so these bytes are never executed.
; Provides a visible signature when the sector is hex-dumped.
;--------------------------------------------------------------
            db          'M','B','R'     ; 3-byte magic signature
            db          0,0,0           ; reserved, pad to 6 bytes

;--------------------------------------------------------------
; MBR entry point - $0106
; On entry: SCRT initialized by ROM, small stack at $00FF
;--------------------------------------------------------------
mbr_main:   call        f_freemem       ; RF = address of highest RAM byte
            mov         r2,rf           ; move stack pointer to top of RAM

            call        f_idereset      ; reset IDE/SD card subsystem

            ; set up LBA address for sector 1 in R7/R8
            ldi         1
            plo         r7              ; R7.0 = LBA bits 7-0  = 1
            ldi         0
            phi         r7              ; R7.1 = LBA bits 15-8 = 0
            plo         r8              ; R8.0 = LBA bits 23-16 = 0
            phi         r8              ; R8.1 = drive/head = 0

            mov         rf,KERN_LOAD    ; RF = $3000, destination buffer
            call        f_ideread       ; read sector 1
            lbdf        mbr_err         ; DF=1 means read error

            lbr         KERN_ENTRY      ; jump to $3006, kernel bootstrap

;--------------------------------------------------------------
; Boot error handler
; Prints a message and halts.  We call f_setbd first since we
; may get here before any serial output has been attempted.
;--------------------------------------------------------------
mbr_err:    call        f_setbd         ; ensure baud rate is configured
            call        f_inmsg
            db          "Boot error",13,10,0
mbr_halt:   lbr         mbr_halt        ; hang -- nothing to return to

            end         mbr_main
