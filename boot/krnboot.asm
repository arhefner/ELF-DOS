;
; krnboot.asm - Kernel bootstrap sectors
;
; This is the kernel bootstrap, occupying disk sectors 1-3
; (KRNBOOT_SECTORS = 3, as of the multi-sector expansion below).
; The MBR loads all 3 sectors to $3E00 and enters at $3E06.
;
; KERN_BASE ($0100, where the kernel proper loads to) has stayed put;
; it's THIS bootstrap's own load address (KERN_LOAD, in mbr.asm) that
; has moved as the kernel grew -- $3000 originally, then $3800, then
; $3E00 (see mbr.asm's header comment for the full story). Growing
; this bootstrap from 1 sector to 3 does not move KERN_LOAD itself --
; it's still the same $3E00 starting address, just now MBR reads 3
; consecutive sectors into it instead of 1.
;
; It reads the kernel sector count from its own header at $3E04,
; then loads the kernel proper (sectors 4..N, shifted from 2..N now
; that this bootstrap itself spans 3 sectors instead of 1) sequentially
; into RAM starting at $0100, and jumps to the kernel entry at $0106.
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
;   (file_size_in_bytes - KRNBOOT_SECTORS*512) / 512
; rounded up, where the subtraction accounts for this bootstrap's own
; sectors, which have already been loaded by the time this header
; field is consulted.
;
; Krnboot slack-space reclaim, extended (multi-sector expansion): the
; original 2b pass reclaimed sector 1's own ~330 bytes of dead padding
; for the one-time init code below (baud rate config, both startup
; banners, the bpb_init/fat_init/file_init calls). This later pass
; goes further: bpb_init's own BODY (not just the call to it) is now
; inlined directly below too, which needed 2 more sectors of room
; (997 bytes generated, verified 2026-07-12) -- still free real estate
; by the same reasoning as 2b, since this whole region is dead the
; instant KERN_ENTRY is reached, exactly like the load loop itself.
;
; The one thing that couldn't move here: kernel_init's mem_top/
; mem_base/cur_dir writes. Those touch kernel-resident, relocatable-
; address data -- this file is linked completely separately from
; kernel.bin (its own link02 invocation, boot/krnboot.prg only), so it
; has no way to reach a relocatable kernel symbol directly, only fixed,
; absolute addresses. The K_FAT_INIT/K_FILE_INIT calls below work
; because a jump-table slot IS a fixed address (same mechanism every
; program already uses to call into the kernel) -- there's no
; equivalent fixed-address path for writing to a data label whose own
; position shifts across kernel rebuilds. bpb_init's own fields
; (part1_lba etc.) are the one exception: BPB_DATA_PTR (see
; kernel_api.inc) is a SECOND fixed-address mechanism, a pointer
; rather than a jump-table slot, purpose-built so this file's own
; inlined bpb_init body (below) can write those specific fields
; directly without needing a K_BPB_INIT call at all -- K_BPB_INIT's
; jump-table slot itself is now a harmless stub (kernel.asm), since
; this is the only place that ever called it.
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

            ; set up LBA to start at sector 4
            ; (sector 0 = MBR, sectors 1-3 = this bootstrap,
            ; 3 sectors as of the multi-sector krnboot expansion)
boot_go:    ldi         4
            plo         r7              ; R7.0 = 4
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

;--------------------------------------------------------------
; Inlined bpb_init (relocated from kernel/bpb.asm -- see this file's
; own header comment for the full reasoning). Two phases:
;
; Phase 1 (below, through the fat_csec write) computes every BPB
; field into LOCAL, krnboot-resident scratch variables (boot_part1_lba
; etc.) using the EXACT same register logic as the original bpb_init --
; this part touches nothing kernel-resident, so it's a pure rename of
; the original's destination labels, not a redesign.
;
; Phase 2 (the "copy into the real kernel-resident block" section
; further below) is the ONLY new logic: it reads BPB_DATA_PTR (the
; fixed pointer kernel.asm populates at its own link time -- see
; kernel_api.inc's own header comment on it) to find the real BPB
; data block's address, then copies each of Phase 1's local results
; into it via BPBBLK_* offsets. Deliberately kept as one uniform,
; repetitive, easy-to-verify pass at the very end, instead of
; interleaving the offset arithmetic into Phase 1's own live register
; state -- concentrates the only genuinely new risk into code that's
; trivial to eyeball-check field by field (right offset, right local
; source, right byte count), rather than needing to trace complex
; register interactions throughout.
;--------------------------------------------------------------

; ---- Phase 1, Step 1: read MBR (sector 0) into local scratch ----
            ldi         0
            plo         r7
            phi         r7
            plo         r8
            phi         r8                  ; LBA = 0

            mov         rf,boot_scratch
            call        f_ideread
            lbdf        boot_kern_err       ; read error

; ---- Phase 1, Step 2: extract partition 1 start LBA ----
            mov         rf,boot_scratch
            ldi         $01
            phi         rd
            ldi         $c6
            plo         rd
            add16       rf,rd               ; RF = boot_scratch + PT_OFFSET + PT_LBA_OFF
            lda         rf
            plo         r7
            lda         rf
            phi         r7
            lda         rf
            plo         r8
            ldi         0
            phi         r8

            mov         rf,boot_part1_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 3: read VBR (partition 1's first sector) ----
            mov         rf,boot_scratch
            call        f_ideread
            lbdf        boot_kern_err       ; read error

; ---- Phase 1, Step 4: sectors-per-cluster, spc_shift ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_SPC
            plo         rd
            add16       rf,rd
            ldn         rf                  ; D = sectors_per_cluster
            plo         r9

            mov         rf,boot_spc
            glo         r9
            str         rf

            ldi         0
            plo         rc
            glo         r9
boot_spc_loop:
            shr
            lbdf        boot_spc_done
            inc         rc
            lbr         boot_spc_loop
boot_spc_done:
            mov         rf,boot_spc_shift
            glo         rc
            str         rf

; ---- Phase 1, Step 5: fat_lba = part1_lba + reserved_sectors ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_RSVD
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = reserved_sector_count

            mov         rf,boot_part1_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = fat_lba

            mov         rf,boot_fat_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 6: root_lba = fat_lba + num_fats*spf; also
; num_fats, spf, max_clust ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_NFAT
            plo         rd
            add16       rf,rd
            ldn         rf
            phi         r9                  ; R9.1 = num_fats

            mov         rf,boot_num_fats
            ghi         r9
            str         rf

            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_SPF
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = sectors_per_fat

            mov         rf,boot_spf
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf

            ; max_clust = spf.lo - 1, $FF (re-read spf.lo from memory,
            ; matching the original bpb_init's own pattern)
            mov         rf,boot_spf
            inc         rf
            ldn         rf
            smi         1
            phi         rb
            ldi         $FF
            plo         rb

            mov         rf,boot_max_clust
            ghi         rb
            str         rf
            inc         rf
            glo         rb
            str         rf

            ; f_mul16: RF * RD -> RB
            mov         rf,rd               ; RF = sectors_per_fat
            ldi         0
            phi         rd
            ghi         r9
            plo         rd                  ; RD = num_fats (zero-extended)
            call        f_mul16             ; RB = num_fats * sectors_per_fat
            mov         rd,rb               ; RD = fat_sectors

            mov         rf,boot_fat_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = root_lba

            mov         rf,boot_root_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 7: data_lba = root_lba + root_dir_sectors; also
; root_ents ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_ROOTENT
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = root_entry_count

            mov         rf,boot_root_ents
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf

            shr16       rd
            shr16       rd
            shr16       rd
            shr16       rd                  ; RD = root_dir_sectors

            mov         rf,boot_root_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = data_lba

            mov         rf,boot_data_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 8: fat_csec = $FFFF (invalidate) ----
            mov         rf,boot_fat_csec
            ldi         $ff
            str         rf
            inc         rf
            str         rf

;--------------------------------------------------------------
; Phase 2: copy every field computed above into the real,
; kernel-resident BPB data block via BPB_DATA_PTR. See this section's
; own header comment above for why this is deliberately one simple,
; uniform pass rather than interleaved into Phase 1.
;--------------------------------------------------------------
            mov         rf,BPB_DATA_PTR
            lda         rf
            phi         rd
            ldn         rf
            plo         rd                  ; RD = BPB block's real,
                                            ; link-time-resolved address

            mov         rf,boot_bpb_base
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf                  ; boot_bpb_base = block address

            ; part1_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_PART1_LBA
            mov         ra,boot_part1_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; fat_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_FAT_LBA
            mov         ra,boot_fat_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; root_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_ROOT_LBA
            mov         ra,boot_root_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; data_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_DATA_LBA
            mov         ra,boot_data_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; spc (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPC
            mov         ra,boot_spc
            ldn         ra
            str         rf

            ; spc_shift (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPC_SHIFT
            mov         ra,boot_spc_shift
            ldn         ra
            str         rf

            ; root_ents (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_ROOT_ENTS
            mov         ra,boot_root_ents
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; num_fats (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_NUM_FATS
            mov         ra,boot_num_fats
            ldn         ra
            str         rf

            ; spf (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPF
            mov         ra,boot_spf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; max_clust (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_MAX_CLUST
            mov         ra,boot_max_clust
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; fat_csec (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_FAT_CSEC
            mov         ra,boot_fat_csec
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

;--------------------------------------------------------------
; end of inlined bpb_init
;--------------------------------------------------------------

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
; Local scratch for the inlined bpb_init above (Phase 1's working
; variables plus its own 512-byte MBR/VBR read buffer). Deliberately
; NOT the kernel's own fat_cache -- keeps BPB_DATA_PTR's reach limited
; to exactly the 23-byte block it's meant for (see kernel_api.inc's
; own header comment on this), not a byte more. Field sizes match
; BPBBLK_* exactly, though these are plain local labels, not accessed
; via offsets themselves -- only the real, kernel-resident copies are.
;--------------------------------------------------------------
boot_part1_lba:     ds      3
boot_fat_lba:       ds      3
boot_root_lba:      ds      3
boot_data_lba:      ds      3
boot_spc:           db      0
boot_spc_shift:     db      0
boot_root_ents:     dw      0
boot_num_fats:      db      0
boot_spf:           dw      0
boot_max_clust:     dw      0
boot_fat_csec:      dw      0
boot_bpb_base:      dw      0
boot_scratch:       ds      512

;--------------------------------------------------------------
; Pad to exactly 1536 bytes = 3 sectors (KRNBOOT_SECTORS). Generated
; code measured at 997 bytes (2026-07-12) -- 3 sectors chosen over 2
; (1024 bytes, only 27 bytes of margin) for real headroom, matching
; this project's own standing margin bar.
;--------------------------------------------------------------
            org         $43FF
            db          0

            end         boot_main
