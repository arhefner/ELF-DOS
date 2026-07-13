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
            extrn   fls_cluster
            extrn   ffl_sector_idx
            extrn   fat_next_free

; ----------------------------------------------------------------
; _fat_load_sector's own scratch: the cluster number it was called
; with, kept across its internal fat_flush/f_ideread calls.
;
; BUG FIX: this used to live in R9 ("mov r9, rd" at _fat_load_sector's
; entry) -- but R9 is relied upon by a caller several levels further
; up the stack: dir_read stashes its own caller's result-buffer
; pointer in R9 across its internal call to _dir_next_sector (see
; dir.asm), and _dir_next_sector's own cluster-chain-follow path
; (dns_subdir) calls fat_get, which calls THIS routine. Nothing in
; that chain's own documented Args/Returns mentions R9, so the clobber
; was completely invisible from any single routine's own contract --
; classic gotcha #10 (a callee's "obviously scratch" register turns
; out to be exactly what a distant caller depends on surviving).
; Confirmed on hardware (2026-07-10): every directory scan that
; crossed a cluster boundary (forcing exactly one fat_get call) wrote
; the NEXT decoded entry's attr/cluster/size fields to a garbage
; address computed from the FAT cluster number instead of the real
; result buffer -- which for a scan on this card's test directory
; (cluster $10) computed to address $0090, squarely inside LINE_BUF
; ($0080-$00FF), silently corrupting the shell's own command-line
; buffer. Moved to memory instead of a register specifically so this
; class of "unrelated distant caller relies on this register" bug
; can't recur here regardless of what any future caller happens to
; keep in a register across a call into this routine.
            proc    _fat_data

fls_cluster:    dw      0

; ffl_sector_idx: fat_flush's own scratch (see its own BUG FIX note) --
; same fix, same reason: fat_flush is called from INSIDE
; _fat_load_sector's fls_load branch (cache dirty case), which sits in
; the exact same dir_read -> _dir_next_sector -> fat_get ->
; _fat_load_sector -> fat_flush chain that made R9 unsafe above. Not
; yet observed to misfire on hardware (the test scans that exposed the
; fls_cluster bug happened to hit a clean cache), but the mechanism is
; identical and would trigger under the right timing (a scan crossing
; a cluster boundary shortly after a write left the FAT cache dirty) --
; fixed proactively rather than waiting for a second hardware failure.
ffl_sector_idx: db      0

; fat_next_free: fat_alloc's "next-fit" search hint -- the cluster to
; start its next scan from, instead of always restarting at cluster 2.
; See fat_alloc's own header for why the always-restart design was a
; real, measured performance problem. Initialized by fat_init (below);
; kept in memory (not a register) since it must survive across every
; call into this file between one fat_alloc and the next.
fat_next_free:  dw      0

                public  fls_cluster
                public  ffl_sector_idx
                public  fat_next_free

                endp

; ----------------------------------------------------------------
; fat_init: reset cache state at boot
; Called by kernel_main after bpb_init.
; bpb_init already sets fat_csec=$FFFF; this proc exists for
; symmetry and any future initialisation needs.
;
; Also sets fat_next_free = 2 -- the same starting point fat_alloc's
; old always-restart-from-2 design used unconditionally, now just the
; one-time initial value for its search hint.
; Returns: nothing
; ----------------------------------------------------------------
            proc    fat_init

            mov     rf, fat_next_free
            ldi     0
            str     rf
            inc     rf
            ldi     2
            str     rf                  ; fat_next_free = 2

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
; Modifies: R7, R8, RF
; ----------------------------------------------------------------
            proc    _fat_load_sector

            ; stash the cluster number in memory, not R9 -- see the
            ; BUG FIX note on fls_cluster's own declaration above for
            ; why R9 specifically is unsafe to use here
            mov     rf, fls_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fls_cluster = cluster number

            ; ---- check whether the right FAT sector is cached ----
            ; FAT sector index = cluster high byte
            mov     rf, fat_csec
            lda     rf                  ; D = fat_csec high byte
            lbnz    fls_load            ; $FF means invalid ($FFFF)
            ldn     rf                  ; D = fat_csec low byte
            str     r2                  ; save fat_csec.lo at [R2]
            mov     rf, fls_cluster
            ldn     rf                  ; D = cluster high byte (sector index)
            sm                          ; D = cluster.1 - [R2]
            lbz     fls_hit             ; zero: already cached

fls_load:
            ; flush the currently-cached sector first, if dirty --
            ; a different sector is about to replace it. No register
            ; protection needed around this call for THIS proc's own
            ; purposes, since fls_cluster (memory) drives everything
            ; below rather than RD -- but see the BUG FIX note just
            ; below for a gap that observation alone would miss.
            mov     rf, fat_dirty
            ldn     rf
            lbz     fls_no_flush
            call    fat_flush
            lbdf    fls_err
fls_no_flush:

            ; BUG FIX (2026-07-13): fat_flush's own header documents RD
            ; as clobbered -- but THIS proc's own header promises "RD
            ; unchanged" to ITS caller (fat_get, which reuses RD
            ; immediately after this call returns to compute a byte
            ; offset). Without this reload, any cache-miss that also
            ; had to flush a dirty sector first would hand fat_get back
            ; a corrupted cluster number, making it compute the wrong
            ; offset into fat_cache -- confirmed on hardware via a
            ; related instance of this same class of bug (see git
            ; history for the full story). Reloading unconditionally is
            ; a no-op when the flush above wasn't actually taken, so
            ; this is cheap insurance either way.
            mov     rf, fls_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            ; absolute LBA = bpb_fat_lba + sector_index
            mov     rf, bpb_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits  7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            mov     rf, fls_cluster
            ldn     rf                  ; D = sector index
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

            ; update fat_csec with the loaded sector index (= cluster
            ; HIGH byte, same as every other "sector index" read in
            ; this proc -- matches the original "ghi r9" here exactly)
            mov     rf, fat_csec
            ldi     0
            str     rf                  ; fat_csec high byte = 0
            inc     rf                  ; rf = fat_csec+1 (destination
                                        ; for the low byte, kept live
                                        ; across the reload below)
            mov     rb, fls_cluster     ; rb -> fls_cluster's HIGH byte
            ldn     rb                  ; D = sector index
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
; PERFORMANCE (2026-07-15): used to always restart its scan at cluster
; 2, forgetting where the previous call left off. Correct, but
; O(clusters already in use) per call -- fine on a mostly-empty disk,
; but on a volume formatted with spc=1 (512-byte clusters, one of this
; project's real test cards) every 512 bytes written needs a fresh
; cluster, so total allocation work for an N-cluster file grew roughly
; with N^2. Confirmed as the dominant cost behind a 63828-byte COPY
; (~125 clusters) taking over a minute, against ~15 seconds for the
; same data over a 57600-baud serial link (which has no allocation
; cost on the sending side at all). Now uses a "next-fit" search:
; start from fat_next_free (wherever the previous successful
; allocation left off) and wrap around to cluster 2 exactly once if
; the scan reaches bpb_max_clust without finding anything, so clusters
; freed by an earlier DEL/RD (which live before the hint) stay
; reachable -- at the cost of a second bounded pass only when the
; first one comes up empty.
;
; Claims the cluster immediately by marking it end-of-chain, so a
; second call in a row can't return the same cluster before the
; caller links it into a chain.
;
; Returns: RD = newly allocated cluster number
;          DF = 0 on success, DF = 1 if disk full or I/O error
; Modifies: R7, R8, R9, RB, RC, RF (via fat_get/fat_set)
; ----------------------------------------------------------------
            proc    fat_alloc

            mov     rf, fat_next_free
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = candidate, starts at the hint

            ldi     0
            plo     r9                  ; R9.0 = wrapped-already flag

alloc_loop:
            ; bound check: candidate > bpb_max_clust -> wrap to 2 once,
            ; or disk full if this scan has already wrapped
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
            lbdf    alloc_have_candidate ; DF=1: candidate <= max_clust

            glo     r9
            lbnz    alloc_full          ; already wrapped once: truly full
            ldi     1
            plo     r9                  ; mark wrapped
            ldi     0
            phi     r8
            ldi     2
            plo     r8                  ; candidate = 2
            lbr     alloc_loop

alloc_have_candidate:
            ; read this cluster's FAT entry -- R9 (wrapped flag)
            ; protected across fat_get the same way R8 (the scan
            ; candidate) already is
            ghi     r8
            phi     rd
            glo     r8
            plo     rd                  ; RD = candidate cluster
            push    r8
            push    r9
            call    fat_get             ; RD = FAT entry value; DF=0/1
            pop     r9
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

            ; fat_next_free = this cluster + 1 -- write RD first, then
            ; increment IN PLACE (rather than computing "RD+1" into a
            ; spare register), since fat_set's own internal call into
            ; _fat_load_sector documents R7/R8/RF as clobbered, so
            ; nothing but RD itself (explicitly restored above) is
            ; trustworthy here. RD stays the allocated cluster -- the
            ; documented return value -- untouched by any of this.
            mov     rf, fat_next_free
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fat_next_free = allocated cluster

            mov     rf, fat_next_free
            inc     rf                  ; rf -> fat_next_free's low byte
            ldn     rf
            adi     1
            str     rf
            lbnz    alloc_hint_done
            dec     rf                  ; rf -> fat_next_free's high byte
            ldn     rf
            adi     1
            str     rf
alloc_hint_done:

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
; Modifies: R7, R8, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    fat_flush

            mov     rf, fat_dirty
            ldn     rf
            lbz     flush_done          ; not dirty: nothing to do

            mov     rf, fat_csec
            lda     rf                  ; D = fat_csec high byte
            lbnz    flush_done          ; $FF: no valid sector cached
            ldn     rf                  ; D = fat_csec low byte
            plo     rb                  ; stash it -- "mov rf,
                                        ; ffl_sector_idx" below itself
                                        ; clobbers D (gotcha #4), so
                                        ; without this stash the value
                                        ; just loaded would not survive
                                        ; to "str rf"
            mov     rf, ffl_sector_idx
            glo     rb                  ; D = cached sector index
                                        ; (reloaded; see BUG FIX note
                                        ; on ffl_sector_idx's own
                                        ; declaration -- was R9.0,
                                        ; unsafe for the same reason
                                        ; fls_cluster was)
            str     rf                  ; ffl_sector_idx = cached
                                        ; sector index

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

            ; add sector_index
            mov     rf, ffl_sector_idx
            ldn     rf
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
