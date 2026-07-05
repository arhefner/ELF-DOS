;
; fat.asm - FAT16 sector cache and cluster chain management
;
; Provides:
;   fat_init  -- reset cache state (called at boot)
;   fat_get   -- return next cluster in chain  [IMPLEMENTED]
;   fat_set   -- write a FAT entry (both FAT copies)
;   fat_alloc -- find and allocate a free cluster
;   fat_flush -- write dirty cache sector to disk
;
; Cache strategy:
;   One 512-byte FAT sector is kept in fat_cache at all times.
;   fat_csec holds the FAT sector INDEX (not absolute LBA) of the
;   cached sector, or $FFFF when no sector is cached.
;   fat_dirty is non-zero when the cache has been modified and
;   must be written back before a different sector is loaded.
;
; Cluster-to-cache arithmetic (all power-of-two, no division):
;   FAT sector index  = cluster.1  (high byte -- N / 256)
;   byte offset       = cluster.0 << 1  (low byte * 2 -- N % 256 * 2)
;
; Absolute LBA of FAT sector index S:
;   LBA = bpb_fat_lba + S   (S fits in one byte for FAT16)
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   fat_csec
            extrn   fat_dirty
            extrn   fat_cache
            extrn   bpb_fat_lba

.link       .align  page

; ----------------------------------------------------------------
; fat_init: reset cache state at boot
; Called by kernel_main after bpb_init.
; bpb_init already sets fat_csec=$FFFF; this proc exists for
; symmetry and any future initialisation needs.
; Returns: nothing
; ----------------------------------------------------------------
            proc    fat_init

            rtn

; ----------------------------------------------------------------
; fat_get: look up the next cluster in a chain
;
; Args:   RD = current cluster number
; Returns: RD = FAT entry for that cluster, which is one of:
;            0x0000          free (shouldn't appear in a chain)
;            0x0002-0xFFEF   next cluster number
;            0xFFF7          bad cluster
;            0xFFF8-0xFFFF   end of chain (>= FAT_EOC)
;          DF = 0 on success
;          DF = 1 on I/O error (RD undefined)
;
; Register usage:
;   R7/R8   LBA for f_ideread
;   R9      saved cluster number across potential sector load
;   RF      memory pointer
; ----------------------------------------------------------------
            endp

            proc    fat_get

            ; save cluster number -- we need both bytes separately
            ; and R9 survives the f_ideread call if we need one
            mov     r9, rd              ; R9 = cluster number

            ; ---- check whether the right FAT sector is cached ----
            ;
            ; FAT sector index = cluster high byte (RD.1 = R9.1)
            ; Compare against fat_csec low byte (fat_csec.1 is
            ; always 0 for valid entries since max index is ~257)

            mov     rf, fat_csec
            lda     rf                  ; D = fat_csec high byte
            lbnz    fat_get_load        ; $FF means invalid ($FFFF)
            ldn     rf                  ; D = fat_csec low byte
            str     r2                  ; save fat_csec.lo at [R2]
            ghi     r9                  ; D = cluster high byte (sector index)
            sm                          ; D = cluster.1 - [R2]
            lbz     fat_get_hit         ; zero means sector already cached

            ; ---- load the required FAT sector into cache ----
            ;
            ; For now (read-only phase) we skip the dirty check
            ; since fat_dirty is always 0.  fat_flush will be
            ; called here once write support is added.

fat_get_load:
            ; absolute LBA = bpb_fat_lba + sector_index
            ; bpb_fat_lba is 3 bytes [bits23-16, bits15-8, bits7-0]
            ; sector_index = R9.1 (fits in one byte, max ~257)

            mov     rf, bpb_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8                  ; R8.0 = bits 23-16
            lda     rf                  ; D = bits 15-8
            phi     r7                  ; R7.1 = bits 15-8
            lda     rf                  ; D = bits  7-0
            plo     r7                  ; R7.0 = bits  7-0
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            ; add sector index (R9.1) to the 24-bit LBA
            ghi     r9                  ; D = sector index
            str     r2                  ; save at [R2] for ADD
            glo     r7                  ; D = LBA bits 7-0
            add                         ; D = D + [R2] (sector index), DF=carry
            plo     r7
            ghi     r7                  ; D = LBA bits 15-8
            adci    0                   ; propagate carry
            phi     r7
            glo     r8                  ; D = LBA bits 23-16
            adci    0                   ; propagate carry
            plo     r8

            mov     rf, fat_cache
            call    f_ideread
            lbdf    fat_get_err         ; I/O error

            ; update fat_csec with the loaded sector index
            mov     rf, fat_csec
            ldi     0
            str     rf                  ; fat_csec high byte = 0
            inc     rf
            ghi     r9                  ; D = sector index
            str     rf                  ; fat_csec low byte = index

            ; ---- read the 2-byte FAT entry from the cache ----
fat_get_hit:
            ; byte offset = cluster.0 * 2 = cluster low byte << 1
            ; compute as: index = cluster.0 shifted left 1
            ; result fits in 9 bits (max 255*2=510), so we need
            ; to carry the shifted-out bit into the high byte

            glo     r9                  ; D = cluster low byte
            shl                         ; D = D << 1, DF = old bit 7
            plo     rf                  ; RF.0 = low byte of offset
            ldi     0
            shlc                        ; D = 0 + DF = carry from shift
            phi     rf                  ; RF.1 = 0 or 1 (high byte of offset)

            ; RF now holds the byte offset (0-510) within fat_cache.
            ; Add fat_cache base address to get the actual pointer.
            add16   rf, fat_cache       ; RF = fat_cache + offset

            lda     rf                  ; D = FAT entry low byte (little-endian on disk)
            plo     rd                  ; RD.0 = low byte
            ldn     rf                  ; D = FAT entry high byte
            phi     rd                  ; RD.1 = high byte
                                        ; RD = next cluster number

            clc                         ; DF = 0, success
            rtn

fat_get_err:
            stc                         ; DF = 1, I/O error
            rtn

; ----------------------------------------------------------------
; fat_set: write a value into the FAT for a given cluster
; Args:   RD = cluster number to update
;         RB = value to write
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            endp

            proc    fat_set
            ; TODO
            clc
            rtn

; ----------------------------------------------------------------
; fat_alloc: find and allocate a free cluster
; Returns: RD = newly allocated cluster number
;          DF = 0 on success, DF = 1 if disk full or I/O error
; ----------------------------------------------------------------
            endp

            proc    fat_alloc
            ; TODO
            stc
            rtn

; ----------------------------------------------------------------
; fat_flush: write dirty cache sector to disk (both FAT copies)
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            endp

            proc    fat_flush
            ; TODO
            clc
            rtn

            endp
