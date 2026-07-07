;
; fat.asm - FAT16 sector cache and cluster chain management
;
; Provides:
;   fat_init  -- reset cache state (called at boot)
;   fat_get   -- return next cluster in chain
;   fat_set   -- write a FAT entry (write-back, not write-through)
;   fat_alloc -- find and allocate a free cluster
;   fat_flush -- write dirty cache sector to disk (all FAT copies)
;
; Cache strategy:
;   One 512-byte FAT sector is kept in fat_cache at all times.
;   fat_csec holds the FAT sector INDEX (not absolute LBA) of the
;   cached sector, or $FFFF when no sector is cached.
;   fat_dirty is non-zero when the cache has been modified and
;   must be written back before a different sector is loaded.
;   fat_set only marks the cache dirty -- it does not write to disk
;   immediately. fat_flush is what actually writes it back, called
;   both on natural cache eviction (_fat_load_sector, when a
;   different sector is about to be loaded) and explicitly by a
;   caller like file_write once it's done extending a chain, so a
;   dirty sector doesn't linger unwritten across a power loss.
;
; Cluster-to-cache arithmetic (all power-of-two, no division):
;   FAT sector index  = cluster.1  (high byte -- N / 256)
;   byte offset       = cluster.0 << 1  (low byte * 2 -- N % 256 * 2)
;
; Absolute LBA of FAT sector index S:
;   LBA = bpb_fat_lba + S   (S fits in one byte for FAT16)
; FAT copy C (0-based) of sector index S:
;   LBA = bpb_fat_lba + (C * bpb_spf) + S
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   fat_csec
            extrn   fat_dirty
            extrn   fat_cache
            extrn   bpb_fat_lba
            extrn   bpb_num_fats
            extrn   bpb_spf
            extrn   bpb_max_clust

; same-file proc references (required even within the same file)
            extrn   _fat_load_sector
            extrn   fat_get
            extrn   fat_set
            extrn   fat_alloc
            extrn   fat_flush

; ----------------------------------------------------------------
; fat_init: reset cache state at boot
; Called by kernel_main after bpb_init.
; bpb_init already sets fat_csec=$FFFF; this proc exists for
; symmetry and any future initialisation needs.
; Returns: nothing
; ----------------------------------------------------------------
            proc    fat_init

            rtn

            endp

; ----------------------------------------------------------------
; _fat_load_sector: ensure fat_cache holds the FAT sector containing
; the given cluster's entry. Flushes the currently-cached sector
; first if it's dirty, then loads the new sector if it isn't
; already the one cached.
;
; Args:    RD = cluster number
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RF
; ----------------------------------------------------------------
            proc    _fat_load_sector

            mov     r9, rd              ; R9 = cluster number

            ; ---- check whether the right FAT sector is cached ----
            ; FAT sector index = cluster high byte (RD.1 = R9.1)
            mov     rf, fat_csec
            lda     rf                  ; D = fat_csec high byte
            lbnz    fls_load            ; $FF means invalid ($FFFF)
            ldn     rf                  ; D = fat_csec low byte
            str     r2                  ; save fat_csec.lo at [R2]
            ghi     r9                  ; D = cluster high byte (sector index)
            sm                          ; D = cluster.1 - [R2]
            lbz     fls_hit             ; zero: already cached

fls_load:
            ; flush the currently-cached sector first, if dirty --
            ; a different sector is about to replace it. Protect R9
            ; (our new cluster number) across the call: fat_flush
            ; uses R9 internally for the OLD cached sector's index.
            mov     rf, fat_dirty
            ldn     rf
            lbz     fls_no_flush
            push    r9
            call    fat_flush
            pop     r9
            lbdf    fls_err
fls_no_flush:

            ; absolute LBA = bpb_fat_lba + sector_index (R9.1)
            mov     rf, bpb_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits  7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            ghi     r9                  ; D = sector index
            str     r2
            glo     r7
            add                         ; D = D + [R2], DF = carry
            plo     r7
            ghi     r7
            adci    0
            phi     r7
            glo     r8
            adci    0
            plo     r8

            mov     rf, fat_cache
            call    f_ideread
            lbdf    fls_err

            ; update fat_csec with the loaded sector index
            mov     rf, fat_csec
            ldi     0
            str     rf                  ; fat_csec high byte = 0
            inc     rf
            ghi     r9                  ; D = sector index
            str     rf                  ; fat_csec low byte = index

            ; freshly-loaded sector is clean
            mov     rf, fat_dirty
            ldi     0
            str     rf

fls_hit:
            clc                         ; DF = 0, success
            rtn

fls_err:
            stc                         ; DF = 1, I/O error
            rtn

            endp

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
; ----------------------------------------------------------------
            proc    fat_get

            call    _fat_load_sector    ; RD unchanged; DF = 0/1
            lbdf    fat_get_err

            ; byte offset = cluster.0 * 2 = cluster low byte << 1
            ; compute as: index = cluster.0 shifted left 1
            ; result fits in 9 bits (max 255*2=510), so we need
            ; to carry the shifted-out bit into the high byte
            glo     rd                  ; D = cluster low byte
            shl                         ; D = D << 1, DF = old bit 7
            plo     rf                  ; RF.0 = low byte of offset
            ldi     0
            shlc                        ; D = 0 + DF = carry from shift
            phi     rf                  ; RF.1 = 0 or 1 (high byte of offset)

            ; RF now holds the byte offset (0-510) within fat_cache.
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

            endp

; ----------------------------------------------------------------
; fat_set: write a value into the FAT for a given cluster
; Args:   RD = cluster number to update
;         RB = value to write
; Returns: DF = 0 on success, DF = 1 on error
; ----------------------------------------------------------------
            proc    fat_set

            push    rb                  ; save value across _fat_load_sector
            call    _fat_load_sector    ; RD unchanged; DF = 0/1
            pop     rb
            lbdf    fat_set_err

            ; byte offset = cluster.0 * 2 (RD still holds the cluster)
            glo     rd
            shl
            plo     rf
            ldi     0
            shlc
            phi     rf
            add16   rf, fat_cache       ; RF = fat_cache + offset

            ; write the 2-byte entry (little-endian on disk)
            glo     rb
            str     rf
            inc     rf
            ghi     rb
            str     rf

            mov     rf, fat_dirty
            ldi     1
            str     rf                  ; mark cache dirty (see fat_flush)

            clc                         ; DF = 0, success
            rtn

fat_set_err:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; fat_alloc: find and allocate a free cluster
;
; Scans forward from cluster 2 looking for a FAT entry of 0 (free),
; bounded by bpb_max_clust. Claims the cluster immediately by
; marking it end-of-chain, so a second call in a row can't return
; the same cluster before the caller links it into a chain.
;
; Returns: RD = newly allocated cluster number
;          DF = 0 on success, DF = 1 if disk full or I/O error
; Modifies: R7, R8, R9, RB, RC, RF (via fat_get/fat_set)
; ----------------------------------------------------------------
            proc    fat_alloc

            ldi     0
            phi     r8
            ldi     2
            plo     r8                  ; R8 = candidate cluster, starts at 2

alloc_loop:
            ; bound check: candidate > bpb_max_clust -> disk full
            mov     rf, bpb_max_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = bpb_max_clust

            glo     r8
            str     r2
            glo     rd
            sm                          ; D = max_clust.lo - candidate.lo, DF=1 if no borrow
            ghi     r8
            str     r2
            ghi     rd
            smb                         ; D = max_clust.hi - candidate.hi - borrow
            lbnf    alloc_full          ; DF=0: candidate > max_clust

            ; read this cluster's FAT entry
            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = candidate cluster
            push    r8
            call    fat_get             ; RD = FAT entry value; DF=0/1
            pop     r8
            lbdf    alloc_err

            glo     rd
            lbnz    alloc_next
            ghi     rd
            lbnz    alloc_next
            lbr     alloc_found         ; entry == 0: free

alloc_next:
            inc     r8
            lbr     alloc_loop

alloc_found:
            ; claim it: mark end-of-chain so it won't be handed out
            ; again before the caller links it into a real chain
            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = cluster to claim
            push    rd
            ldi     $FF
            phi     rb
            ldi     $F8
            plo     rb                  ; RB = FAT_EOC ($FFF8)
            call    fat_set
            pop     rd
            lbdf    alloc_err

            clc                         ; DF = 0, RD = allocated cluster
            rtn

alloc_full:
alloc_err:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; fat_flush: write the cached FAT sector back to disk, to every FAT
; copy (bpb_num_fats). No-op if the cache isn't dirty.
;
; Returns: DF = 0 on success, DF = 1 on I/O error
; Modifies: R7, R8, R9, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    fat_flush

            mov     rf, fat_dirty
            ldn     rf
            lbz     flush_done          ; not dirty: nothing to do

            mov     rf, fat_csec
            lda     rf                  ; D = fat_csec high byte
            lbnz    flush_done          ; $FF: no valid sector cached
            ldn     rf                  ; D = fat_csec low byte
            plo     r9                  ; R9.0 = cached sector index

            ldi     0
            plo     rc                  ; RC.0 = FAT copy index (0-based)

flush_copy_loop:
            ; LBA = bpb_fat_lba + (copy_index * bpb_spf) + sector_index
            mov     rf, bpb_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits 7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            ; add (copy_index * bpb_spf), by adding bpb_spf that many times
            glo     rc
            lbz     flush_no_copy_off
            plo     rb                  ; RB.0 = remaining copies to add
flush_copy_off_loop:
            mov     rf, bpb_spf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = bpb_spf

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8

            dec     rb
            glo     rb
            lbnz    flush_copy_off_loop
flush_no_copy_off:

            ; add sector_index (R9.0)
            glo     r9
            str     r2
            glo     r7
            add
            plo     r7
            ghi     r7
            adci    0
            phi     r7
            glo     r8
            adci    0
            plo     r8

            mov     rf, fat_cache
            call    f_idewrite
            lbdf    flush_err

            glo     rc
            adi     1
            plo     rc                  ; copy_index++

            mov     rf, bpb_num_fats
            ldn     rf
            str     r2
            glo     rc
            sm                          ; D = copy_index - num_fats
            lbnz    flush_copy_loop     ; nonzero: more copies remain

            mov     rf, fat_dirty
            ldi     0
            str     rf                  ; cache is now clean

flush_done:
            clc                         ; DF = 0, success
            rtn

flush_err:
            stc                         ; DF = 1, I/O error
            rtn

            endp
