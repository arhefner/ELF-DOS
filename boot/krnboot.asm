;
; krnboot.asm - Kernel bootstrap sector
;
; This is the FIRST sector of the kernel binary (disk sector 1).
; The MBR loads it to $3800 and enters at $3806.
;
; KERN_BASE ($0100, where the kernel proper loads to) was $3000 until
; 2026-07-09 -- moved after the kernel's own growth pushed its
; sector-rounded on-disk size past $3000, into this very sector's own
; resident code, corrupting the load loop below while it was still
; running (see mbr.asm's header comment for the full story). Loading
; this sector further out of the way gives real headroom again.
;
; It reads the kernel sector count from its own header at $3804,
; then loads the kernel proper (sectors 2..N) sequentially into
; RAM starting at $0100, and jumps to the kernel entry at $0106.
;
; By loading the kernel to $0100 the bootstrap overwrites itself
; in RAM as the kernel grows, but that is fine -- this code is
; only needed once and is never called again after the jump to
; $0106. (This is a DIFFERENT overwrite than the one described
; above: this one is intentional and harmless, since nothing needs
; this code anymore once KERN_ENTRY is reached; the $3000 one was
; the load loop overwriting itself mid-flight, before reaching that
; point.)
;
; Header layout (6 bytes at $3800-$3805):
;   $3800-$3802  'KRN'  3-byte magic signature
;   $3803        $01    kernel major version
;   $3804-$3805  word   number of sectors to load (big-endian)
;                       patched by the 'sys' install utility
;   $3806        ...    entry point (code starts here)
;
; The 'sys' utility computes the sector count as:
;   (file_size_in_bytes - 512) / 512
; rounded up, where the -512 accounts for this bootstrap sector
; which has already been loaded.
;

#include    include/bios.inc
#include    include/opcodes.def

#define     KERN_BASE   $0100           ; kernel proper loads here
#define     KERN_ENTRY  $0106           ; kernel proper entry point
#define     SECTOR_SIZE $0200           ; 512 bytes per sector
#define     CNT_ADDR    $3804           ; address of sector count in header

            org         $3800

;--------------------------------------------------------------
; 6-byte header ($3800-$3805)
; MBR enters at $3806, so these bytes are never executed.
;--------------------------------------------------------------
            db          'K','R','N'     ; 3-byte magic signature
            db          1               ; kernel major version
            dw          0               ; sector count -- patched by sys

;--------------------------------------------------------------
; Bootstrap entry point - $3806
; On entry: SCRT initialized, stack at top of RAM
;--------------------------------------------------------------
boot_main:
            ; read kernel sector count from our own header
            ldi         CNT_ADDR.1
            phi         rf
            ldi         CNT_ADDR.0
            plo         rf              ; RF = $3804
            lda         rf              ; D = high byte of sector count
            phi         rc
            lda         rf              ; D = low byte of sector count
            plo         rc              ; RC = total sectors to load

            ; sanity check -- if count is zero there is no kernel
            ghi         rc
            lbnz        boot_go
            glo         rc
            lbz         load_err        ; RC=0 means no kernel installed

            ; set up LBA to start at sector 2
            ; (sector 0 = MBR, sector 1 = this bootstrap)
boot_go:    ldi         2
            plo         r7              ; R7.0 = 2
            ldi         0
            phi         r7              ; R7.1 = 0
            plo         r8              ; R8.0 = 0
            phi         r8              ; R8.1 = 0

            ; RA = current load address, starts at KERN_BASE
            mov         ra,KERN_BASE

;--------------------------------------------------------------
; Sector load loop
; Registers:  RC = remaining sector count
;             R7 = current LBA (low 16 bits)
;             R8 = 0 (drive/head and upper LBA bits)
;             RA = current RAM destination address
;             RF = set from RA before each f_ideread call
;--------------------------------------------------------------
load_loop:  ghi         rc              ; check high byte of count
            lbnz        do_load         ; non-zero means at least 256 left
            glo         rc              ; check low byte of count
            lbz         load_done       ; both zero -- finished

do_load:    mov         rf,ra           ; RF = current load address
            call        f_ideread       ; read sector into [RF]
            lbdf        load_err        ; DF=1 means read error

            add16       ra,SECTOR_SIZE  ; advance load address by 512
            inc         r7              ; advance to next LBA sector
            dec         rc              ; one fewer sector remaining
            lbr         load_loop

;--------------------------------------------------------------
; All sectors loaded -- jump to kernel entry point
;--------------------------------------------------------------
load_done:  lbr         KERN_ENTRY      ; jump to $0106, kernel proper

;--------------------------------------------------------------
; Load error handler
;--------------------------------------------------------------
load_err:   call        f_inmsg
            db          "Kernel load error",13,10,0
load_halt:  lbr         load_halt       ; hang -- nothing to return to

;--------------------------------------------------------------
; Pad to exactly 512 bytes (fills the remainder of sector 1)
;--------------------------------------------------------------
            org         $39FF
            db          0

            end         boot_main
