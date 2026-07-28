;
; mbr.asm - Master Boot Record boot code
;
; Written by ROM f_boot to $0100, entered at $0106.
; Sets up the stack, resets the IDE/SD subsystem, loads the kernel
; bootstrap's KRNBOOT_SECTORS consecutive sectors (sectors 1..
; KRNBOOT_SECTORS) to $4600, and jumps to the bootstrap entry point
; at $4606. KRNBOOT_SECTORS grew from 1 to 3 as part of the
; multi-sector krnboot expansion (moving bpb_init's body into
; krnboot.asm's own sectors) -- see that file's own header comment
; for the full reasoning; boot/krnboot.asm's own "ldi 4" (where the
; kernel proper's own sectors start, sector 0=MBR + KRNBOOT_SECTORS=3
; bootstrap sectors = kernel proper starts at sector 4) and
; sys/sys.c's/progs/sys.asm's own sector-count math must all stay in
; lockstep with this same value.
;
; KERN_LOAD was $3000 until 2026-07-09: the kernel proper (loaded by
; krnboot to $0100, see krnboot.asm) had grown to the point that its
; own sector-rounded on-disk size, loaded starting at $0100, reached
; past $3000 and into krnboot's own resident code while krnboot's
; load loop was still executing from it -- a silent self-overwrite
; with no error message (the corruption happened before kernel_init's
; first print), which looked from the outside like "the kernel does
; not boot at all". Moved to $3800 that same day to restore real
; headroom. Moved again to $3E00 immediately after RENAME (REN) was
; added -- headroom had shrunk to ~256 bytes (MD/RD/REN together added
; a meaningful amount of kernel code in one session), well under this
; project's own "real headroom, not a few dozen bytes" bar, and this
; time moved proactively, before a hardware failure forced the issue.
; $3E00 leaves krnboot ending essentially at PROG_BASE's own start
; ($4000) -- harmless, since krnboot's memory is fully dead by the time
; any user program ever loads there; the only real constraint is
; clearance from the KERNEL's own growth, not from PROG_BASE. Check
; this margin again if the kernel's "Highest address" approaches
; $3E00 - $0100 = ~15.5KB.
;
; Moved again to $4600 (2026-07-20) after file_seek's real
; implementation (replacing the old rewind-only placeholder) pushed
; "Highest address" to $3f44 -- 324 bytes past $3E00. Moved with real
; headroom (see kernel.inc's own copy of this history for the exact
; numbers), not just enough to clear the immediate overflow.
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

#define     KERN_LOAD   $4600           ; kernel bootstrap loads here
#define     KERN_ENTRY  $4606           ; kernel bootstrap entry point
#define     KRNBOOT_SECTORS 3           ; sectors 1..3 hold the bootstrap
                                        ; (must match krnboot.asm's own
                                        ; sector count and sys/sys.c's
                                        ; /progs/sys.asm's sector math)

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

            mov         ra,KERN_LOAD    ; RA = current destination,
                                        ; starts at $4600
            ldi         KRNBOOT_SECTORS
            plo         rc              ; RC.0 = sectors remaining

mbr_load_loop:
            mov         rf,ra           ; RF = current destination
            call        f_ideread       ; read one sector into [RF]
            lbdf        mbr_err         ; DF=1 means read error

            add16       ra,$0200        ; advance destination by 512
            inc         r7              ; advance to next LBA sector
            dec         rc
            glo         rc
            lbnz        mbr_load_loop

            lbr         KERN_ENTRY      ; jump to $3E06, kernel bootstrap

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
