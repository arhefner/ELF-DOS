;
; krnboot.asm - Kernel bootstrap sector
;
; This is the FIRST sector of the kernel binary (disk sector 1).
; The MBR loads it to $3E00 and enters at $3E06.
;
; KERN_BASE ($0100, where the kernel proper loads to) has stayed put;
; it's THIS sector's own load address (KERN_LOAD, in mbr.asm) that has
; moved twice as the kernel grew -- $3000 originally, then $3800 (both
; on 2026-07-09), now $3E00 (moved proactively after RENAME (REN) was
; added, before headroom actually ran out this time -- see mbr.asm's
; header comment for the full story of both moves).
;
; It reads the kernel sector count from its own header at $3E04,
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
; Header layout (6 bytes at $3E00-$3E05):
;   $3E00-$3E02  'KRN'  3-byte magic signature
;   $3E03        $01    kernel major version
;   $3E04-$3E05  word   number of sectors to load (big-endian)
;                       patched by the 'sys' install utility
;   $3E06        ...    entry point (code starts here)
;
; The 'sys' utility computes the sector count as:
;   (file_size_in_bytes - 512) / 512
; rounded up, where the -512 accounts for this bootstrap sector
; which has already been loaded.
;
; Krnboot slack-space reclaim: this sector's own code (the load loop
; above, plus the one-time init code below) has only ever used about
; 100 of its 512 bytes -- everything from the end of that code to
; $3FFE was pure, wasted zero padding, since nothing else lived here.
; But this whole region is dead the instant KERN_ENTRY is reached (see
; the paragraph above), exactly like krnboot's own load-loop code is --
; so any kernel init code that only ever needs to run ONCE, at boot,
; and never again, is free real estate here instead of a permanent
; cost in the kernel's own resident image. boot_init2 below is exactly
; that: the one-time-only parts of the original kernel_init prologue
; (baud rate config, both startup banners, and the bpb_init/fat_init/
; file_init calls with bpb_init's own error check), moved out of
; kernel.bin and into this sector's own previously-wasted space.
;
; The one thing that couldn't move here: kernel_init's mem_top/
; mem_base/cur_dir writes. Those touch kernel-resident, relocatable-
; address data -- this file is linked completely separately from
; kernel.bin (its own link02 invocation, boot/krnboot.prg only), so it
; has no way to reach a relocatable kernel symbol directly, only fixed,
; absolute addresses. The K_BPB_INIT/K_FAT_INIT/K_FILE_INIT calls below
; work because a jump-table slot IS a fixed address (same mechanism
; every program already uses to call into the kernel) -- there's no
; equivalent fixed-address path for writing to a data label whose own
; position shifts across kernel rebuilds.
;

#include    include/bios.inc
#include    include/opcodes.def
#include    include/kernel_api.inc

#define     KERN_BASE   $0100           ; kernel proper loads here
#define     KERN_ENTRY  $0106           ; kernel proper entry point
#define     SECTOR_SIZE $0200           ; 512 bytes per sector
#define     CNT_ADDR    $3E04           ; address of sector count in header

            org         $3E00

;--------------------------------------------------------------
; 6-byte header ($3E00-$3E05)
; MBR enters at $3E06, so these bytes are never executed.
;--------------------------------------------------------------
            db          'K','R','N'     ; 3-byte magic signature
            db          1               ; kernel major version
            dw          0               ; sector count -- patched by sys

;--------------------------------------------------------------
; Bootstrap entry point - $3E06
; On entry: SCRT initialized, stack at top of RAM
;--------------------------------------------------------------
boot_main:
            ; read kernel sector count from our own header
            ldi         CNT_ADDR.1
            phi         rf
            ldi         CNT_ADDR.0
            plo         rf              ; RF = $3E04
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
; All sectors loaded -- run the relocated one-time init code below,
; which falls through to the real kernel entry point once it's done.
;--------------------------------------------------------------
load_done:  lbr         boot_init2

;--------------------------------------------------------------
; Load error handler
;--------------------------------------------------------------
load_err:   call        f_inmsg
            db          "Kernel load error",13,10,0
load_halt:  lbr         load_halt       ; hang -- nothing to return to

;--------------------------------------------------------------
; boot_init2: one-time kernel init code relocated from kernel_init --
; see this file's own header comment for the full reasoning. Runs
; immediately after the sector load loop above, in the exact same
; SCRT/stack environment that loop already runs in (nothing here
; needs anything more than that).
;--------------------------------------------------------------
boot_init2:
            call        f_setbd             ; configure serial baud rate

            call        f_inmsg
            db          "ELF-DOS v0.1",13,10,0

            call        K_BPB_INIT          ; read MBR + VBR, populate BPB cache
            lbdf        boot_kern_err       ; DF=1 on disk or format error

            call        K_FAT_INIT          ; invalidate FAT cache, clear dirty flag
            call        K_FILE_INIT         ; mark all FCB slots as free

            call        f_inmsg
            db          "Type a command.",13,10,0

            lbr         KERN_ENTRY          ; continue into kernel_init proper

;--------------------------------------------------------------
; boot_init2 error handler -- relocated from kernel.asm's kern_err,
; same message and behavior, just physically moved here along with
; the check that reaches it.
;--------------------------------------------------------------
boot_kern_err:
            call        f_inmsg
            db          "Kernel init failed",13,10,0
boot_kern_halt:
            lbr         boot_kern_halt

;--------------------------------------------------------------
; Pad to exactly 512 bytes (fills the remainder of sector 1)
;--------------------------------------------------------------
            org         $3FFF
            db          0

            end         boot_main
