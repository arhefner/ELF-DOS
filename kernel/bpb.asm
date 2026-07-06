;
; bpb.asm - BPB (BIOS Parameter Block) initialization
;
; Called once at boot by kernel_main.
; Reads the MBR to find the partition 1 start LBA, then reads
; the Volume Boot Record (VBR) of partition 1 and extracts the
; BPB fields needed to navigate the FAT16 filesystem.
;
; Computes and stores:
;   part1_lba    -- partition 1 start LBA
;   bpb_fat_lba  -- LBA of FAT 1
;   bpb_root_lba -- LBA of root directory
;   bpb_data_lba -- LBA of cluster 2 (first data cluster)
;   bpb_spc      -- sectors per cluster
;   bpb_spc_shift -- log2(spc), for shift-based cluster arithmetic
;   bpb_root_ents -- root directory entry count
;
; All derived LBAs are stored in our 3-byte big-endian format:
;   byte 0 = bits 23-16  (-> R8.0)
;   byte 1 = bits 15-8   (-> R7.1)
;   byte 2 = bits  7-0   (-> R7.0)
;
; Uses fat_cache as a scratch buffer for the MBR and VBR reads.
; Leaves fat_csec = $FFFF (cache invalid) on exit.
;
; Returns: DF=0 on success, DF=1 on error
;
; Register usage within bpb_init:
;   R7       LBA bits 15-0 (running computation)
;   R8.0     LBA bits 23-16
;   R8.1     0 (drive/head, set before each f_ideread)
;   R9.0     sectors-per-cluster (saved across f_mul16 call)
;   R9.1     num_fats (saved for multiply)
;   RC.0     shift count in spc_shift loop
;   RD       16-bit operand for additions and multiply
;   RF       memory pointer
;   RA, RB   f_mul16 arguments and result
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   part1_lba
            extrn   bpb_spc
            extrn   bpb_spc_shift
            extrn   bpb_fat_lba
            extrn   bpb_root_lba
            extrn   bpb_data_lba
            extrn   bpb_root_ents
            extrn   fat_csec
            extrn   fat_cache

            proc    bpb_init

;------------------------------------------------------------------
; Step 1: read MBR (sector 0) into fat_cache as a scratch buffer
;------------------------------------------------------------------
            ldi     0
            plo     r7                  ; R7 = 0
            phi     r7
            plo     r8                  ; R8 = 0
            phi     r8                  ; LBA = 0 (MBR)

            mov     rf, fat_cache
            call    f_ideread
            lbdf    bpb_err             ; read error

;------------------------------------------------------------------
; Step 2: extract partition 1 start LBA from MBR partition table
;
; Partition table entry 1 is at fat_cache + PT_OFFSET ($01BE).
; The LBA start field is at entry offset PT_LBA_OFF (8), stored
; as a 4-byte little-endian value.  We use only the low 3 bytes
; (24-bit LBA covers 8GB, more than enough for our hardware).
;
; Little-endian layout on disk -> our big-endian register order:
;   disk byte 0 = LBA bits  7-0  -> R7.0
;   disk byte 1 = LBA bits 15-8  -> R7.1
;   disk byte 2 = LBA bits 23-16 -> R8.0
;   disk byte 3 = LBA bits 31-24 -> (ignored)
;------------------------------------------------------------------
            ; NOTE: "mov rf, fat_cache+CONST" is broken under Asm/02 --
            ; the linker's fixup for a symbol+constant expression drops
            ; the symbol's resolved base address, keeping only the
            ; constant (confirmed by inspecting the linked binary).
            ; Work around it by loading the base separately and adding
            ; the constant with add16, which uses no symbol fixup.
            mov     rf, fat_cache
            ldi     $01                 ; hi(PT_OFFSET+PT_LBA_OFF) = hi($01C6)
            phi     rd
            ldi     $c6                 ; lo(PT_OFFSET+PT_LBA_OFF) = lo($01C6)
            plo     rd
            add16   rf, rd              ; RF = fat_cache + PT_OFFSET + PT_LBA_OFF
            lda     rf                  ; D = LBA bits  7-0  (LE byte 0)
            plo     r7
            lda     rf                  ; D = LBA bits 15-8  (LE byte 1)
            phi     r7
            lda     rf                  ; D = LBA bits 23-16 (LE byte 2)
            plo     r8
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            ; store part1_lba as [bits23-16, bits15-8, bits7-0]
            mov     rf, part1_lba
            glo     r8                  ; bits 23-16
            str     rf
            inc     rf
            ghi     r7                  ; bits 15-8
            str     rf
            inc     rf
            glo     r7                  ; bits  7-0
            str     rf

;------------------------------------------------------------------
; Step 3: read VBR (Volume Boot Record = first sector of partition 1)
; R7/R8 still hold partition 1 LBA from step 2.
; After this call R7/R8 may be modified by f_ideread.
;------------------------------------------------------------------
            mov     rf, fat_cache
            call    f_ideread
            lbdf    bpb_err

;------------------------------------------------------------------
; Step 4: extract sectors-per-cluster (byte at BPB_SPC = $0D)
; Compute spc_shift = log2(spc) by right-shifting D until bit 0
; falls into DF, counting the shifts taken.
;
; Works for any power-of-two spc (FAT spec guarantees this):
;   spc=1  -> shift 0 times -> spc_shift=0
;   spc=2  -> shift 1 time  -> spc_shift=1
;   spc=4  -> shift 2 times -> spc_shift=2
;   spc=64 -> shift 6 times -> spc_shift=6
;------------------------------------------------------------------
            ; see Asm/02 symbol+constant fixup note above
            mov     rf, fat_cache
            ldi     0
            phi     rd
            ldi     BPB_SPC
            plo     rd
            add16   rf, rd              ; RF = fat_cache + BPB_SPC
            ldn     rf                  ; D = sectors_per_cluster
            plo     r9                  ; save in R9.0 (survives f_mul16)

            mov     rf, bpb_spc
            glo     r9
            str     rf                  ; bpb_spc = spc

            ldi     0
            plo     rc                  ; RC.0 = shift count = 0
            glo     r9                  ; D = spc

spc_loop:   shr                         ; shift D right; DF = old bit 0
            lbdf    spc_done            ; 1-bit reached DF, we have the count
            inc     rc                  ; one more shift needed
            lbr     spc_loop

spc_done:   mov     rf, bpb_spc_shift
            glo     rc
            str     rf                  ; bpb_spc_shift = log2(spc)

;------------------------------------------------------------------
; Step 5: compute fat_lba = part1_lba + reserved_sector_count
;
; BPB_RSVD ($0E) is a little-endian word: fat_cache[$0E]=low,
; fat_cache[$0F]=high.  On the 1802 register RD.1 is the high
; byte and RD.0 is the low byte, so we load LE into RD correctly
; as: plo rd = low byte, phi rd = high byte.
;
; 24-bit LBA add: add16 adds RD to R7 (low 16 bits), then
; 'adci 0' propagates any carry into R8.0 (bits 23-16).
;------------------------------------------------------------------
            ; see Asm/02 symbol+constant fixup note above
            mov     rf, fat_cache
            ldi     0
            phi     rd
            ldi     BPB_RSVD
            plo     rd
            add16   rf, rd              ; RF = fat_cache + BPB_RSVD
            lda     rf                  ; D = reserved_sectors low byte
            plo     rd
            ldn     rf                  ; D = reserved_sectors high byte
            phi     rd                  ; RD = reserved_sector_count

            ; reload part1_lba (f_ideread in step 3 may have changed R7/R8)
            mov     rf, part1_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits  7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0

            add16   r7, rd              ; R7 += reserved_sectors, DF = carry
            glo     r8
            adci    0                   ; R8.0 += carry
            plo     r8                  ; R7:R8.0 = fat_lba

            mov     rf, bpb_fat_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; bpb_fat_lba stored

;------------------------------------------------------------------
; Step 6: compute root_lba = fat_lba + (num_fats * sectors_per_fat)
;
; Extract num_fats (byte at BPB_NFAT=$10) into R9.1 to survive
; the f_mul16 call.  Extract sectors_per_fat (LE word at BPB_SPF=$16).
; Call f_mul16 (RF * RD -> RB); reload fat_lba after the call
; since f_mul16 may modify R7/R8.
;------------------------------------------------------------------
            ; see Asm/02 symbol+constant fixup note above
            mov     rf, fat_cache
            ldi     0
            phi     rd
            ldi     BPB_NFAT
            plo     rd
            add16   rf, rd              ; RF = fat_cache + BPB_NFAT
            ldn     rf                  ; D = num_fats
            phi     r9                  ; save in R9.1 (survives f_mul16)

            mov     rf, fat_cache
            ldi     0
            phi     rd
            ldi     BPB_SPF
            plo     rd
            add16   rf, rd              ; RF = fat_cache + BPB_SPF
            lda     rf                  ; D = sectors_per_fat low byte
            plo     rd
            ldn     rf                  ; D = sectors_per_fat high byte
            phi     rd                  ; RD = sectors_per_fat

            ; f_mul16: RF * RD -> RB (low word)
            mov     rf, rd              ; RF = sectors_per_fat
            ldi     0
            phi     rd                  ; RD.1 = 0
            ghi     r9                  ; D = num_fats
            plo     rd                  ; RD = num_fats (zero-extended)
            call    f_mul16             ; RB = num_fats * sectors_per_fat
            mov     rd, rb              ; RD = fat_sectors

            ; reload fat_lba (f_mul16 may have trashed R7/R8)
            mov     rf, bpb_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits  7-0
            plo     r7
            ldi     0
            phi     r8

            add16   r7, rd              ; R7 += fat_sectors, DF = carry
            glo     r8
            adci    0
            plo     r8                  ; R7:R8.0 = root_lba

            mov     rf, bpb_root_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; bpb_root_lba stored

;------------------------------------------------------------------
; Step 7: compute data_lba = root_lba + root_dir_sectors
;
; root_dir_sectors = root_entry_count * 32 / 512
;                  = root_entry_count / 16   (since 32/512 = 1/16)
;                  = root_entry_count >> 4
;
; Extract root_entry_count (LE word at BPB_ROOTENT=$11), store
; in bpb_root_ents, then shift right 4 to get the sector count.
;------------------------------------------------------------------
            ; see Asm/02 symbol+constant fixup note above
            mov     rf, fat_cache
            ldi     0
            phi     rd
            ldi     BPB_ROOTENT
            plo     rd
            add16   rf, rd              ; RF = fat_cache + BPB_ROOTENT
            lda     rf                  ; D = root_entry_count low byte
            plo     rd
            ldn     rf                  ; D = root_entry_count high byte
            phi     rd                  ; RD = root_entry_count

            ; store bpb_root_ents (big-endian in memory)
            mov     rf, bpb_root_ents
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; divide by 16 via four right shifts
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = root_dir_sectors

            ; reload root_lba
            mov     rf, bpb_root_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            lda     rf
            plo     r7
            ldi     0
            phi     r8

            add16   r7, rd              ; R7 += root_dir_sectors, DF = carry
            glo     r8
            adci    0
            plo     r8                  ; R7:R8.0 = data_lba

            mov     rf, bpb_data_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf                  ; bpb_data_lba stored

;------------------------------------------------------------------
; Step 8: invalidate FAT cache
; fat_cache currently holds VBR data, not a FAT sector.
; Setting fat_csec = $FFFF signals "no valid sector cached".
;------------------------------------------------------------------
            mov     rf, fat_csec
            ldi     $ff
            str     rf
            inc     rf
            str     rf                  ; fat_csec = $FFFF

            clc                         ; DF = 0 = success
            rtn

bpb_err:    stc                         ; DF = 1 = error
            rtn

            endp
