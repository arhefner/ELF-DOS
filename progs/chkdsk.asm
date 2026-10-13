;
; chkdsk.asm - check a FAT16 volume for filesystem consistency errors
;
; Usage: CHKDSK [X:] [-f]
;
; With no argument, checks the current drive; with "X:", that drive
; (cur_drive is not changed). Without -f nothing is written.
;
; Checks: lost clusters, cross-linked clusters, chains that run into an
; invalid, free or bad-marked cluster, file size against chain length,
; "." and ".." links, duplicate short names and broken LFN runs.
;
; -f repairs what MS-DOS CHKDSK /F repaired, the same way:
;   - lost chains: asks, then turns each into /FILEnnnn.CHK or frees them
;   - a chain that runs into an invalid cluster: ended at its last good
;     cluster ("file truncated"); if the first cluster is invalid the
;     entry is emptied (a directory becomes an empty file)
;   - size that does not fit the chain: size set to the chain's length
;   - wrong "." or ".." cluster: corrected
; Reported but never repaired, as in MS-DOS: cross-linked files (copy
; them, then delete the originals). Also report-only: duplicate short
; names and LFN problems. A chain that loops back on itself is ended at
; the cluster whose link closes the loop.
;
; How -f writes: FAT and directory sectors go out with K_SECWRITE, with
; K_DRIVE_INVALIDATE before and after each batch of FAT writes so the
; kernel never holds a stale FAT sector. The tree walk still uses
; K_DIR_OPEN/K_DIR_READ, which give no on-disk location, so a repair
; finds its entry again by counting: the Nth entry K_DIR_READ returned
; is the Nth in-use short entry of a raw scan (same skip rules), and the
; entry's cluster is compared before anything is changed. Recovered
; files are created empty through K_FILE_OPEN (so the kernel picks the
; slot and the time stamp) and then given their chain and size raw.
;
; -f is refused while output is redirected: a file being written on the
; checked drive would be changing the FAT underneath the repair.
;
; This is a flat file (no proc/endp, matching every other progs/*.asm
; in this project) -- gotcha #20 (a bare top-level label between
; proc/endp blocks corrupting the linked base address) does not apply
; here, since there are no proc/endp segments at all.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   drive_letter_of
            extrn   drive_index_of

            extrn   fmt_size32

; ---- raw on-disk constants (kernel.inc is not includable from progs/) ----
ATTR_HIDDEN2:   equ     $02         ; also in kernel_api.inc as ATTR_HIDDEN
ATTR_SYSTEM:    equ     $04
ATTR_VOLID:     equ     $08
ATTR_DIR2:      equ     $10         ; also in kernel_api.inc as ATTR_DIR
ATTR_ARCHIVE:   equ     $20
ATTR_LFN:       equ     $0F

DE_NAME:        equ     0           ; 11 bytes, space-padded
DE_ATTR:        equ     11          ; 1 byte
DE_WRTTIME:     equ     22          ; 2 bytes, LE
DE_WRTDATE:     equ     24          ; 2 bytes, LE
DE_CLUSTER:     equ     26          ; 2 bytes, LE
DE_SIZE:        equ     28          ; 4 bytes, LE
DIR_ENT_SIZE:   equ     32

LFN_CHKSUM:     equ     13

FAT_FREE:       equ     $0000
FAT_BAD:        equ     $FFF7
FAT_EOC:        equ     $FFF8       ; >= this value = end-of-chain

; ---- chkdsk-local tuning knobs ----
CHK_MAX_DEPTH:      equ     24      ; recursion-depth cap (9 bytes/level)
CHK_DUPNAME_CAP:    equ     256     ; duplicate-short-name buffer entries
CHK_BITMAP_LEN:     equ     8192    ; 1 bit/cluster, FAT16 worst case

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. Arguments, in any order: one
            ; "X:" and/or "-f". The loop makes no calls, so its state
            ; stays in registers: RB = argv slot, R7.0 = slots left.
            mov     rf, chk_fix
            ldi     0
            str     rf
            mov     rf, chk_fix_req
            ldi     0
            str     rf
            mov     rf, chk_drive_letter
            ldi     0
            str     rf

            glo     rc
            plo     r7
            mov     rb, ra
chk_arg_loop:
            dec     r7
            glo     r7
            lbz     chk_args_done
            inc     rb
            inc     rb                  ; RB -> next argv slot
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = this argument
            dec     rb                  ; RB back on the slot's first byte

            ldn     rf
            xri     '-'
            lbnz    chk_arg_drive
            inc     rf
            lda     rf
            ani     $DF
            xri     'F'
            lbnz    chk_usage
            ldn     rf
            lbnz    chk_usage           ; more after "-f"
            mov     rf, chk_fix
            ldi     1
            str     rf
            mov     rf, chk_fix_req
            ldi     1
            str     rf
            lbr     chk_arg_loop

chk_arg_drive:
            mov     r8, chk_drive_letter
            ldn     r8
            lbnz    chk_usage           ; a second drive
            ldn     rf
            ani     $DF                 ; uppercase-fold: only $41-$5A and
                                        ; $61-$7A land in $41-$5A
            smi     DRIVE_LETTER_MIN
            lbnf    chk_usage           ; below 'A'
            ldn     rf
            ani     $DF
            smi     DRIVE_LETTER_MAX+1
            lbdf    chk_usage           ; above 'Z'
            mov     r9, rf
            inc     r9
            lda     r9
            xri     ':'
            lbnz    chk_usage
            ldn     r9
            lbnz    chk_usage           ; more after "X:"
            ldn     rf
            ani     $DF
            str     r8                  ; chk_drive_letter
            lbr     chk_arg_loop

chk_args_done:
            mov     rf, chk_drive_letter
            ldn     rf
            lbnz    chk_have_drive_arg

chk_no_arg:
            ; no argument: check the ACTIVE drive. K_GETCURDIR already
            ; tells us which one -- no K_PATH_RESOLVE call needed at
            ; all in this branch, since the active drive's BPB is
            ; already the one we want.
            call    K_GETCURDIR         ; D = cur_drive
            plo     r9
            mov     rb, chk_drive_slot
            glo     r9
            str     rb                  ; slot, for K_DRIVE_INVALIDATE
            call    drive_letter_of     ; D = slot in, letter out
            plo     r9                  ; stash D (R9 free here) --
                                        ; K_GETCURDIR's own doc doesn't
                                        ; promise RB survives it, so set
                                        ; up the destination pointer
                                        ; only AFTER D is safely stashed
            mov     rb, chk_drive_letter
            glo     r9
            str     rb
            lbr     chk_print_header

chk_have_drive_arg:
            ; build "X:/",0 and activate that drive's BPB via
            ; K_PATH_RESOLVE, purely for its _switch_drive side effect
            ; -- discard RD/RF/RC, use only DF. Same trick already
            ; proven by progs/xcopy.asm's xc_walk (via K_STAT) and
            ; lib/file_glob.asm's glob_next (via K_PATH_RESOLVE).
            mov     rf, chk_path_buf
            mov     rb, chk_drive_letter
            ldn     rb
            str     rf
            inc     rf
            ldi     ':'
            str     rf
            inc     rf
            ldi     '/'
            str     rf
            inc     rf
            ldi     0
            str     rf

            mov     rf, chk_path_buf
            call    K_PATH_RESOLVE
            lbdf    chk_not_present

            mov     rf, chk_drive_letter
            ldn     rf
            call    drive_index_of      ; D = slot
            lbdf    chk_not_present
            plo     r9
            mov     rf, chk_drive_slot
            glo     r9
            str     rf
            lbr     chk_print_header

chk_not_present:

            ; DF=1 here can only mean "no mounted partition on that
            ; drive" per K_PATH_RESOLVE's own contract -- there's no
            ; intermediate path component to fail on for a bare "X:/".
            call    K_INMSG
            db      "Drive ",0
            mov     rb, chk_drive_letter
            ldn     rb
            call    K_TYPE
            call    K_INMSG
            db      ": not present.",13,10,0
            ldi     1
            rtn

chk_usage:
            call    K_INMSG
            db      "Usage: CHKDSK [X:] [-f]",13,10,0
            ldi     1
            rtn

chk_print_header:
            ; -f with output redirected: refuse. K_TYPE's slot differs
            ; from IO_TYPE_TARGET exactly while output is redirected.
            mov     rf, chk_fix
            ldn     rf
            lbz     chk_hdr_go
            mov     rf, K_TYPE+1
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = K_TYPE's target
            mov     rf, IO_TYPE_TARGET
            lda     rf
            str     r2
            ghi     r8
            xor
            lbnz    chk_redirected
            ldn     rf
            str     r2
            glo     r8
            xor
            lbz     chk_hdr_go
chk_redirected:
            call    K_INMSG
            db      "CHKDSK -f cannot run with its output redirected.",13,10,0
            ldi     1
            rtn

chk_hdr_go:
            call    K_INMSG
            db      "Checking drive ",0
            mov     rb, chk_drive_letter
            ldn     rb
            call    K_TYPE
            call    K_INMSG
            db      ":",13,10,0

            ; FAT cache: nothing loaded, nothing to write
            mov     rf, chk_fc_sec
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_fc_dirty
            ldi     0
            str     rf
            mov     rf, chk_f12_dirty
            ldi     0
            str     rf
            call    chk_read_bpb
            call    chk_load_fat12      ; FAT12 only; no-op on FAT16
            lbnf    chk_fat_loaded
            call    K_INMSG
            db      "Cannot read the file allocation table.",13,10,0
            ldi     1
            rtn
chk_fat_loaded:

            ; zero every tally counter -- `ds` does NOT guarantee
            ; zero-initialized memory in this codebase (confirmed via
            ; progs/xcopy.asm's own established "explicitly zero every
            ; counter at start" convention)
            mov     rf, chk_tally_crosslink
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_badsector
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_mismatch
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_lost
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_chain
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_structural
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_files
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_dirs
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_hidden
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_free
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_badfree
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_tally_file_bytes
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            ; The "seen" bitmap, one bit per cluster, lives in the free
            ; memory after the program (LOADER_ARGS: mem_base..mem_top)
            ; and is only as long as this volume needs:
            ; (max_clust+8)>>3 bytes, 8,191 at most. It is zeroed here --
            ; nothing else clears that memory.
            mov     rf, chk_max_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = max_clust
            add16   r9, 8
            shr16   r9
            shr16   r9
            shr16   r9                  ; R9 = (max_clust+8) >> 3

            mov     rf, chk_bitmap_needed
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, LOADER_ARGS
            lda     rf
            phi     rd
            lda     rf
            plo     rd                  ; RD = mem_base
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = mem_top (last usable byte)
            mov     rf, chk_bm1_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, chk_bm_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            sub16   r8, rd              ; R8 = mem_top - mem_base
            lbnf    chk_no_memory
            sub16   r8, r9              ; room for the bitmap?
            lbdf    chk_mem_ok
chk_no_memory:
            call    K_INMSG
            db      "Not enough memory to check this drive.",13,10,0
            ldi     1
            rtn
chk_mem_ok:
            mov     rf, chk_bitmap_needed
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = bytes to clear
            mov     rf, chk_bm1_base
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, r8              ; RF -> the bitmap
cbmz_loop:
            ghi     r9
            lbnz    cbmz_body
            glo     r9
            lbz     cbmz_done
cbmz_body:
            ldi     0
            str     rf
            inc     rf
            dec     r9
            lbr     cbmz_loop
cbmz_done:

            ; walk the whole tree from the root (cluster 0, the
            ; established "root" sentinel this project uses
            ; everywhere -- FAT16's root has no "."/".." entries at
            ; all, so parent=0/depth=0 are never actually consulted
            ; for this top-level call, just supplied for a uniform
            ; argument convention)
            ldi     0
            phi     rd
            plo     rd
            ldi     0
            phi     r9
            plo     r9
            ldi     0
            plo     rc
            call    chk_walk_dir

            ; FAT-table second pass: lost-cluster scan + free-cluster
            ; tally, run once now that the tree walk's own "seen"
            ; bitmap is complete
            call    chk_fat_scan_lost
            call    chk_lost_chains     ; report; with -f, recover or free

            call    chk_fat_flush       ; nothing may stay unwritten
            call    chk_print_summary
            call    chk_print_verdict

            ldi     0
            rtn

;------------------------------------------------------------------
; chk_read_bpb: snapshot the ACTIVE drive's BPB fields into local,
; chkdsk-owned memory. Safe to snapshot ONCE, not re-dereference
; BPB_DATA_PTR on every use like most callers in this codebase do --
; deliberate deviation, justified because nothing CHKDSK calls after
; this point makes another drive active: the only path-based calls
; (K_STAT/K_FILE_OPEN in chk_recover_chain) name this same drive, and
; this snapshot is of the drive's geometry, which they do not change.
;
; Args:    none
; Returns: nothing (chk_fat_lba/chk_data_lba/chk_root_lba/chk_spc/
;          chk_spc_shift/chk_root_ents/chk_spf/chk_max_clust/
;          chk_cluster_bytes all populated)
; Modifies: R7, R8, R9, RB, RF (and D)
;------------------------------------------------------------------
chk_read_bpb:
            mov     rf, BPB_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = BPB block's real address

            mov     rf, r9
            add16   rf, BPBBLK_FAT_LBA
            mov     rb, chk_fat_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_fat_lba = BPBBLK_FAT_LBA (3B)

            mov     rf, r9
            add16   rf, BPBBLK_ROOT_LBA
            mov     rb, chk_root_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_root_lba (3B)

            mov     rf, r9
            add16   rf, BPBBLK_DATA_LBA
            mov     rb, chk_data_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_data_lba (3B)

            mov     rf, r9
            add16   rf, BPBBLK_SPC
            mov     rb, chk_spc
            ldn     rf
            str     rb                  ; chk_spc (1B)

            mov     rf, r9
            add16   rf, BPBBLK_SPC_SHIFT
            mov     rb, chk_spc_shift
            ldn     rf
            str     rb                  ; chk_spc_shift (1B)

            mov     rf, r9
            add16   rf, BPBBLK_ROOT_ENTS
            mov     rb, chk_root_ents
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_root_ents (2B)

            mov     rf, r9
            add16   rf, BPBBLK_SPF
            mov     rb, chk_spf
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_spf (2B)

            mov     rf, r9
            add16   rf, BPBBLK_MAX_CLUST
            mov     rb, chk_max_clust
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb                  ; chk_max_clust (2B)

            mov     rf, r9
            add16   rf, BPBBLK_NUM_FATS
            ldn     rf
            lbnz    crb_nf_ok
            ldi     1                   ; never 0: chk_fat_flush counts
                                        ; copies up to this value
crb_nf_ok:
            plo     r8
            mov     rb, chk_num_fats
            glo     r8
            str     rb                  ; chk_num_fats (1B)

            ; BUG FIX (2026-09-11): chk_unit -- every raw sector read below
            ; used to hardcode R8.1 = 0 (the boot device), so CHKDSK on a
            ; drive MOUNTed from another unit read the wrong device.
            mov     rf, r9
            add16   rf, BPBBLK_DEV
            mov     rb, chk_unit
            ldn     rf
            str     rb                  ; chk_unit (1B)

            ; chk_fat12 = (max_clust < $0FF6). max_clust is the cluster
            ; count + 1, and the FAT type IS the cluster count: fewer
            ; than 4085 clusters is FAT12 (same rule the kernel's own
            ; _switch_drive uses).
            mov     rf, chk_max_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = max_clust
            glo     r9
            smi     $F6
            ghi     r9
            smbi    $0F                 ; DF = 1: FAT16
            ldi     0
            shlc
            xri     1                   ; D = 1 for FAT12
            plo     r9
            mov     rb, chk_fat12
            glo     r9
            str     rb

            ; chk_cluster_bytes (32-bit, big-endian, matching
            ; DIRENT_SIZE's own in-memory convention) = chk_spc * 512.
            ; 512 = 2^9: compute temp16 = chk_spc*2 (a plain 16-bit
            ; zero-extend-then-double, chk_spc <= 255 so temp16 <= 510,
            ; safely fits in 16 bits with no overflow), then the
            ; remaining x256 is a pure byte reposition -- temp16
            ; becomes the MIDDLE two bytes of the 32-bit result, with
            ; the top byte and bottom byte both zero. No general
            ; multiply needed for this one value.
            mov     rf, chk_spc
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = chk_spc, zero-extended
            shl16   r8                  ; R8 = chk_spc * 2 (<=510, fits)

            mov     rb, chk_cluster_bytes
            ldi     0
            str     rb                  ; byte0 (MSB) = 0
            inc     rb
            ghi     r8
            str     rb                  ; byte1 = temp16 high byte
            inc     rb
            glo     r8
            str     rb                  ; byte2 = temp16 low byte
            inc     rb
            ldi     0
            str     rb                  ; byte3 (LSB) = 0

            rtn

;------------------------------------------------------------------
; chk_cluster_to_lba: convert a cluster number to its starting LBA,
; ready for K_SECREAD. Direct userland mirror of kernel/dir.asm's own
; kernel-internal _cluster_to_lba (not exposed to userland) -- same
; formula, same instruction shape, hand-traced against that real,
; already-proven routine rather than re-derived independently.
;
; Args:    RD = cluster number (must be >= 2 -- caller's own
;          responsibility to range-check first)
; Returns: R7/R8 set for K_SECREAD (first sector of that cluster)
; Modifies: R7, R8, RA, RC, RD, RF (and D) -- matches the real kernel
;          routine's own documented clobber list exactly; the ONE
;          caller in this file (chk_fetch_data_sector) must never
;          trust any of these to survive this call.
;------------------------------------------------------------------
chk_cluster_to_lba:
            dec     rd
            dec     rd                  ; RD = cluster - 2

            ghi     rd
            phi     r7
            glo     rd
            plo     r7
            ldi     0
            plo     r8                  ; R8.0 = 0 (bits 23-16)

            mov     rf, chk_spc_shift
            ldn     rf
            plo     rc                  ; RC.0 = shift count
            glo     rc
            lbz     cctl_done

cctl_shift:
            shl16   r7                  ; R7 <<= 1, DF = old bit 15
            glo     r8
            shlc                        ; R8.0 = (R8.0 << 1) | DF
            plo     r8
            dec     rc
            glo     rc
            lbnz    cctl_shift

cctl_done:
            ; add chk_data_lba (3 bytes, big-endian: [bits23-16,
            ; bits15-8, bits7-0]) into R8.0:R7 -- same add-with-carry
            ; shape as the real kernel routine
            mov     rf, chk_data_lba
            lda     rf                  ; D = bits 23-16
            phi     ra
            lda     rf                  ; D = bits 15-8
            phi     rc
            ldn     rf                  ; D = bits 7-0

            str     r2
            glo     r7
            add
            plo     r7

            ghi     rc
            str     r2
            ghi     r7
            adc
            phi     r7

            ghi     ra
            str     r2
            glo     r8
            adc
            plo     r8

            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)
            rtn

;------------------------------------------------------------------
; chk_fat_read: read the FAT entry for a cluster. FAT16 entries come
; from a one-sector cache (chk_fr_secbuf, see chk_fat_load), FAT12
; entries from the whole-FAT copy in RAM.
;
; Args:    RD = cluster number
; Returns: DF = 0 with RD = the entry as a 16-bit value;
;          DF = 1 on an I/O error (RD undefined)
; Modifies: R7, R8, R9, RB, RF (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_fat_read:
            mov     rb, chk_fat12
            ldn     rb
            lbnz    cfr12               ; FAT12: decode from RAM

            mov     rb, chk_fr_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            call    chk_fat_load
            lbdf    chk_fr_ioerr

            ; byte offset = (cluster & $FF) * 2, at most 510
            mov     rf, chk_fr_cluster
            inc     rf                  ; -> cluster's low byte
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9                  ; R9 = byte offset

            mov     rf, chk_fr_secbuf
            add16   rf, r9              ; RF -> the entry (little-endian)
            lda     rf
            plo     rd
            ldn     rf
            phi     rd                  ; RD = entry
            clc
            rtn

chk_fr_ioerr:
            stc
            rtn

;------------------------------------------------------------------
; chk_fat_sec_lba: LBA of one sector of one copy of the FAT.
; Args:    R9.0 = sector index within the FAT, R9.1 = copy (0 = first)
; Returns: R7/R8 ready for K_SECREAD/K_SECWRITE (unit in R8.1)
; Modifies: R7, R8, R9, RF (and D). Makes no calls.
;------------------------------------------------------------------
chk_fat_sec_lba:
            mov     rf, chk_fat_lba
            lda     rf
            plo     r8                  ; bits 23-16
            lda     rf
            phi     r7                  ; bits 15-8
            ldn     rf
            plo     r7                  ; bits 7-0
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
cfsa_copy:
            ghi     r9
            lbz     cfsa_have
            mov     rf, chk_spf
            inc     rf                  ; -> spf low byte
            ldn     rf
            str     r2
            glo     r7
            add
            plo     r7
            dec     rf
            ldn     rf
            str     r2
            ghi     r7
            adc
            phi     r7
            glo     r8
            adci    0
            plo     r8
            ghi     r9
            smi     1
            phi     r9
            lbr     cfsa_copy
cfsa_have:
            mov     rf, chk_unit
            ldn     rf
            phi     r8                  ; R8.1 = this drive's unit
            rtn

;------------------------------------------------------------------
; chk_fat_load (FAT16): make chk_fr_secbuf hold the FAT sector with the
; entry for chk_fr_cluster. The sector index is the cluster's high byte.
; A different sector already in the buffer is written back first if it
; was changed.
; Returns: DF = 0 loaded, DF = 1 on an I/O error (nothing cached)
; Modifies: everything
;------------------------------------------------------------------
chk_fat_load:
            mov     rf, chk_fr_cluster
            ldn     rf
            plo     r9                  ; R9.0 = wanted sector
            mov     rf, chk_fc_sec
            lda     rf
            lbnz    cfl_miss            ; $FFxx: nothing cached
            ldn     rf
            str     r2
            glo     r9
            xor
            lbnz    cfl_miss
            clc
            rtn
cfl_miss:
            call    chk_fat_flush
            lbdf    cfl_fail

            mov     rf, chk_fc_sec      ; nothing valid during the read
            ldi     $FF
            str     rf
            inc     rf
            str     rf

            mov     rf, chk_fr_cluster
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; first copy
            call    chk_fat_sec_lba
            mov     rf, chk_fr_secbuf
            call    K_SECREAD
            lbdf    cfl_fail

            mov     rf, chk_fc_sec
            ldi     0
            str     rf
            inc     rf
            mov     r9, chk_fr_cluster
            ldn     r9
            str     rf                  ; chk_fc_sec = that sector
            clc
            rtn
cfl_fail:
            stc
            rtn

;------------------------------------------------------------------
; chk_kinval: K_DRIVE_INVALIDATE for the checked drive -- the kernel
; writes out and forgets its own FAT sector. Called before and after
; every batch of raw FAT writes.
; Modifies: everything
;------------------------------------------------------------------
chk_kinval:
            mov     rf, chk_drive_slot
            ldn     rf
            call    K_DRIVE_INVALIDATE
            rtn

;------------------------------------------------------------------
; chk_fat_write: set the FAT entry for a cluster. Changes memory only;
; chk_fat_flush (or, FAT16, loading another sector) writes it out.
; Args:    RD = cluster, RB = value ($FFFF = end of chain, 0 = free;
;          FAT12 keeps the low 12 bits)
; Returns: DF = 0 done, DF = 1 on an I/O error
; Modifies: everything
;------------------------------------------------------------------
chk_fat_write:
            mov     rf, chk_fw_value
            ghi     rb
            str     rf
            inc     rf
            glo     rb
            str     rf

            mov     rf, chk_fat12
            ldn     rf
            lbnz    cfw12

            mov     rf, chk_fr_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            call    chk_fat_load
            lbdf    cfw_fail

            mov     rf, chk_fr_cluster
            inc     rf
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9                  ; R9 = byte offset in the sector
            mov     rf, chk_fr_secbuf
            add16   rf, r9
            mov     r8, chk_fw_value
            inc     r8
            ldn     r8
            str     rf                  ; low byte first on disk
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            mov     rf, chk_fc_dirty
            ldi     1
            str     rf
            clc
            rtn
cfw_fail:
            stc
            rtn

            ; FAT12: the entry for cluster N is 12 bits starting at byte
            ; N + N/2 -- the low 12 of those 16 bits for an even N, the
            ; high 12 for an odd one.
cfw12:
            ghi     rd
            shr
            phi     r9
            glo     rd
            shrc
            plo     r9                  ; R9 = N >> 1
            add16   r9, rd              ; R9 = byte offset
            mov     rf, chk_fat12_buf
            add16   rf, r9              ; RF -> first byte
            mov     r8, chk_fw_value
            lda     r8
            ani     $0F
            phi     r7                  ; R7.1 = value bits 11-8
            ldn     r8
            plo     r7                  ; R7.0 = value bits 7-0
            glo     rd
            shr
            lbdf    cfw12_odd

            glo     r7
            str     rf
            inc     rf
            ldn     rf
            ani     $F0
            str     r2
            ghi     r7
            or
            str     rf
            lbr     cfw12_done
cfw12_odd:
            glo     r7
            shl
            shl
            shl
            shl
            str     r2
            ldn     rf
            ani     $0F
            or
            str     rf
            inc     rf
            glo     r7
            shr
            shr
            shr
            shr
            str     r2
            ghi     r7
            shl
            shl
            shl
            shl
            or
            str     rf
cfw12_done:
            mov     rf, chk_f12_dirty
            ldi     1
            str     rf
            clc
            rtn

;------------------------------------------------------------------
; chk_fat_flush: write changed FAT data to every copy of the FAT. Does
; nothing when nothing was changed. FAT16: the one cached sector.
; FAT12: the whole RAM copy.
; Returns: DF = 0 written (or nothing to write); DF = 1 on a write
;          error, after chk_write_failed has turned repairs off
; Modifies: everything
;------------------------------------------------------------------
chk_fat_flush:
            mov     rf, chk_fat12
            ldn     rf
            lbnz    cff12

            mov     rf, chk_fc_dirty
            ldn     rf
            lbnz    cff_go
            clc
            rtn
cff_go:
            call    chk_kinval
            mov     rf, chk_fw_copy
            ldi     0
            str     rf
cff_loop:
            mov     rf, chk_fw_copy
            ldn     rf
            phi     r9
            mov     rf, chk_fc_sec
            inc     rf
            ldn     rf
            plo     r9
            call    chk_fat_sec_lba
            mov     rf, chk_fr_secbuf
            call    K_SECWRITE
            lbdf    chk_write_failed

            mov     rf, chk_fw_copy
            ldn     rf
            adi     1
            str     rf
            mov     r9, chk_num_fats
            ldn     r9
            str     r2
            ldn     rf
            xor
            lbnz    cff_loop

            mov     rf, chk_fc_dirty
            ldi     0
            str     rf
            call    chk_kinval
            clc
            rtn

cff12:
            mov     rf, chk_f12_dirty
            ldn     rf
            lbnz    cff12_go
            clc
            rtn
cff12_go:
            call    chk_kinval
            mov     rf, chk_fw_copy
            ldi     0
            str     rf
cff12_copy:
            mov     rf, chk_lf_idx
            ldi     0
            str     rf
cff12_sec:
            ; this copy is done at index 12 or index spf, whichever
            ; comes first -- the same sectors chk_load_fat12 read
            mov     rf, chk_lf_idx
            ldn     rf
            plo     r9
            smi     CHK_FAT12_MAXSEC
            lbdf    cff12_nextcopy
            mov     rf, chk_spf
            lda     rf
            lbnz    cff12_do            ; spf >= 256
            ldn     rf
            str     r2
            glo     r9
            sm
            lbdf    cff12_nextcopy      ; index >= spf
cff12_do:
            mov     rf, chk_fw_copy
            ldn     rf
            phi     r9                  ; R9 = copy : index
            call    chk_fat_sec_lba
            mov     rf, chk_lf_idx
            ldn     rf
            phi     r9
            ldi     0
            plo     r9
            shl16   r9                  ; R9 = index * 512
            mov     rf, chk_fat12_buf
            add16   rf, r9
            call    K_SECWRITE
            lbdf    chk_write_failed

            mov     rf, chk_lf_idx
            ldn     rf
            adi     1
            str     rf
            lbr     cff12_sec
cff12_nextcopy:
            mov     rf, chk_fw_copy
            ldn     rf
            adi     1
            str     rf
            mov     r9, chk_num_fats
            ldn     r9
            str     r2
            ldn     rf
            xor
            lbnz    cff12_copy

            mov     rf, chk_f12_dirty
            ldi     0
            str     rf
            call    chk_kinval
            clc
            rtn

;------------------------------------------------------------------
; chk_write_failed: a sector write failed. Jumped to, not called, by
; the routines that write; it returns to THEIR caller with DF = 1.
; Repairs are turned off for the rest of the run, so the remainder is
; an ordinary check.
;------------------------------------------------------------------
chk_write_failed:
            mov     rf, chk_fix
            ldi     0
            str     rf
            mov     rf, chk_fc_sec      ; the buffer no longer matches the disk
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_fc_dirty
            ldi     0
            str     rf
            mov     rf, chk_f12_dirty
            ldi     0
            str     rf
            call    K_INMSG
            db      "Disk write error. No further repairs will be made.",13,10,0
            call    chk_kinval
            stc
            rtn

;------------------------------------------------------------------
; cfr12: the FAT12 half of chk_fat_read. The entry for cluster N starts
; at byte N + N/2 of the FAT, which chk_load_fat12 has already read into
; chk_fat12_buf, so there is no I/O here at all. Values $FF7-$FFF are
; widened to $FFF7-$FFFF so every 16-bit end-of-chain/bad-cluster test
; in this program keeps working unchanged.
;------------------------------------------------------------------
cfr12:
            ghi     rd
            shr
            phi     r9
            glo     rd
            shrc
            plo     r9                  ; R9 = cluster >> 1
            add16   r9, rd              ; R9 = byte offset of the entry
            mov     rf, chk_fat12_buf
            add16   rf, r9
            lda     rf
            plo     r8                  ; R8.0 = first byte
            ldn     rf
            phi     r8                  ; R8 = the 16 bits holding it
            glo     rd
            shr
            lbnf    cfr12_even
            glo     r8                  ; odd cluster: entry = R8 >> 4
            shr
            shr
            shr
            shr
            str     r2
            ghi     r8
            shl
            shl
            shl
            shl
            or
            plo     r8
            ghi     r8
            shr
            shr
            shr
            shr
            phi     r8
cfr12_even:
            ghi     r8
            ani     $0F
            phi     r8
            xri     $0F
            lbnz    cfr12_done
            glo     r8
            smi     $F7
            lbnf    cfr12_done
            ldi     $FF
            phi     r8
cfr12_done:
            ghi     r8
            phi     rd
            glo     r8
            plo     rd
            clc
            rtn

;------------------------------------------------------------------
; chk_load_fat12: read the whole FAT into chk_fat12_buf (FAT12 only;
; a no-op on FAT16). Called once, right after chk_read_bpb.
; Returns: DF = 0 on success (or not FAT12), DF = 1 on an I/O error
; Modifies: everything
;------------------------------------------------------------------
chk_load_fat12:
            mov     rf, chk_fat12
            ldn     rf
            lbnz    clf_go
            clc
            rtn
clf_go:
            mov     rf, chk_lf_idx
            ldi     0
            str     rf
clf_loop:
            mov     rf, chk_lf_idx
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = sector index
            mov     rf, chk_spf
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = spf
            mov     r7, r9
            sub16   r7, r8
            lbdf    clf_done            ; index >= spf: whole FAT read
            glo     r9
            smi     CHK_FAT12_MAXSEC
            lbdf    clf_done            ; a FAT12 FAT is never longer

            mov     rf, chk_fat_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            lda     rf
            plo     r7
            mov     rf, chk_lf_idx
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
            mov     rf, chk_unit
            ldn     rf
            phi     r8                  ; R8.1 = this drive's unit

            mov     rf, chk_lf_idx
            ldn     rf
            phi     r9
            ldi     0
            plo     r9                  ; R9 = index * 256
            shl16   r9                  ; R9 = index * 512
            mov     rf, chk_fat12_buf
            add16   rf, r9              ; RF -> this sector's slot

            call    K_SECREAD
            lbdf    clf_err

            mov     rf, chk_lf_idx
            ldn     rf
            adi     1
            str     rf
            lbr     clf_loop
clf_done:
            clc
            rtn
clf_err:
            stc
            rtn

;------------------------------------------------------------------
; chk_add32: acc += addend, both 4-byte big-endian (MSB-first) values
; in memory -- the general 32-bit-value + 32-bit-value idiom this
; plan uses (NOT two independent ADD16 calls, which would not
; propagate carry across the 16-bit boundary -- see the plan's own
; "32-bit arithmetic idioms" note). 4 individual byte steps, LSB
; first: ADD (no carry in) then ADC x3 (carry in from the previous
; byte), mirroring kernel/file.asm's own proven SM/SMB subtract shape
; with ADD/ADC in its place. Independently verified via a byte-
; accurate mechanical simulation of this exact instruction sequence
; across 200,000+ random 32-bit pairs plus every carry-boundary case
; before being trusted here.
;
; Args:    RF = pointer to the 4-byte accumulator (modified in place)
;          RD = pointer to the 4-byte addend (read only)
; Returns: nothing
; Modifies: R7, R8, RF, RD (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_add32:
            mov     r7, rf
            add16   r7, 3               ; R7 -> acc byte3 (LSB)
            mov     r8, rd
            add16   r8, 3               ; R8 -> addend byte3 (LSB)

            ldn     r8
            str     r2
            ldn     r7
            add                         ; D = acc.b3 + addend.b3, DF=carry
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            adc
            str     r7
            rtn

;------------------------------------------------------------------
; chk_sub32: minuend -= subtrahend, both 4-byte big-endian values in
; memory -- the one genuine 32-bit subtraction in this whole program
; (chk_walk_chain's own per-hop accumulation needs no subtract at all,
; see prev_capacity below). Direct copy of kernel/file.asm's own
; fread_check_eof (lines ~4788-4842, "full 32-bit subtract-with-
; borrow"): 4 individual SM/SMB byte steps, LSB first, each
; subtrahend byte staged via str r2 immediately before its own sm/smb
; consumer (gotcha #18 -- never let a register-register add16/sub16
; run in between). Independently verified the same way as chk_add32
; above, across 200,000+ cases plus every borrow-boundary case.
;
; Args:    RF = pointer to the 4-byte minuend (modified in place)
;          RD = pointer to the 4-byte subtrahend (read only)
; Returns: nothing
; Modifies: R7, R8, RF, RD (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_sub32:
            mov     r7, rf
            add16   r7, 3               ; R7 -> minuend byte3 (LSB)
            mov     r8, rd
            add16   r8, 3               ; R8 -> subtrahend byte3 (LSB)

            ldn     r8
            str     r2
            ldn     r7
            sm                          ; D = minuend.b3 - subtrahend.b3
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7

            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r7
            rtn

;------------------------------------------------------------------
; chk_print_uint: print a 16-bit value in decimal to the console.
; Args:    RD = value
; Returns: nothing
; Modifies: R7, R8, R9, RB, RD, RF (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_print_uint:
            mov     rf, chk_num_buf
            call    f_uintout           ; RF advanced past the digits
                                        ; (f_uintout does not null-
                                        ; terminate itself)
            ldi     0
            str     rf
            mov     rf, chk_num_buf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; chk_inc16: increment a 2-byte memory counter by 1.
; Args:    RF = pointer to the 2-byte (big-endian) counter
; Returns: nothing
; Modifies: R9, RF (and D)
;------------------------------------------------------------------
chk_inc16:
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            inc     r9
            dec     rf
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            rtn

;------------------------------------------------------------------
; chk_mark_cluster: mark a cluster's bit in the "seen" bitmap.
;
; Args:    RD = cluster number (must already be range-checked, 2 <=
;          cluster <= chk_max_clust, by the caller)
; Returns: DF = 1 if the bit was ALREADY set (a cross-link -- the
;          caller should report it); DF = 0 if this is the first time
;          this cluster has been marked. The bit is set either way.
; Modifies: R7, R8, R9, RB, RD, RF (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_mark_cluster:
            dec     rd
            dec     rd                  ; RD = cluster - 2

            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = cluster - 2 (full 16-bit)

            glo     r8
            ani     7
            plo     r9                  ; R9.0 = bit position (0-7),
                                        ; from the low 3 bits BEFORE
                                        ; the >>3 shift below removes
                                        ; them

            shr16   r8
            shr16   r8
            shr16   r8                  ; R8 = byte_index = (cluster-2)>>3

            ldi     1
            plo     rb                  ; RB.0 = mask, starts at 1
mc_shiftloop:
            glo     r9
            lbz     mc_shiftdone
            glo     rb
            shl
            plo     rb
            dec     r9
            lbr     mc_shiftloop
mc_shiftdone:

            mov     rd, chk_bm_base     ; which bitmap: the "seen" one,
            lda     rd                  ; or chk_lost_chains' second one
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8              ; RF -> bitmap[byte_index]

            ldn     rf                  ; D = current byte
            str     r2
            glo     rb                  ; D = bit_mask
            and                         ; D = current_byte & bit_mask
            lbnz    mc_already_set

            ldn     rf                  ; re-read the original byte fresh
                                        ; (the AND above consumed D)
            str     r2
            glo     rb
            or
            str     rf
            clc
            rtn

mc_already_set:
            ldn     rf
            str     r2
            glo     rb
            or
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; chk_walk_chain: walk a FAT16 cluster chain starting at the given
; cluster, marking every visited cluster in the "seen" bitmap
; (cross-link detection is a side effect of chk_mark_cluster) and
; accumulating byte-capacity. Bounded by max_clust hops -- valid
; clusters run 2..max_clust inclusive, so a real, non-cyclic chain can
; never legitimately need more than (max_clust-1) hops; using
; max_clust itself (not max_clust+1) leaves one hop of slack while
; still defending against a corrupt, self-looping chain hanging the
; scan forever.
;
; BUG FIX (2026-08-02): this used to compute the bound as "max_clust +
; 1" -- which silently OVERFLOWS to 0 in the 16-bit chk_wc_remaining
; counter whenever max_clust is itself already $FFFF, the maximum
; representable 16-bit value (a real, legitimate case: a near-maximal
; FAT16 volume with spc=16 can genuinely reach max_clust=65535).
; Confirmed on hardware (2026-08-02): every single chk_walk_chain call
; hit "Cluster chain too long" with hops=0 -- the remaining-hops check
; at the top of the loop saw 0 on its very first read, before a single
; cluster was ever visited or marked "seen" -- on a volume fsck.fat had
; just independently confirmed clean. Fixed by dropping the +1
; entirely: max_clust alone is still provably >= the true maximum
; possible chain length (max_clust-1), so no headroom is lost, and the
; bound can never overflow since max_clust is already representable in
; the same 16-bit width by construction.
;
; Args:    RD = start cluster
; On any exit chk_wc_cluster is the cluster (or bad link value) the
; walk stopped on and chk_wc_prev the cluster before it (0 = none),
; which is what chk_fix_chain needs to end the chain.
;
; Returns: DF = 0 if the chain ended normally (EOC), with results in
;          chk_wc_hops(2B)/chk_wc_capacity(4B,BE)/chk_wc_prevcap
;          (4B,BE, capacity as of one hop earlier -- free, snapshotted
;          each hop before that hop's own addition); DF = 1 for any
;          other outcome, already reported to the console by this
;          routine itself (chk_wc_reason holds which one, for the
;          caller's own tallying if it wants it -- not currently
;          consumed by any caller, but kept for completeness).
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
; A FAT12 FAT is at most 12 sectors (4085 entries * 1.5 bytes = 6128),
; so CHKDSK reads the whole thing into RAM once and decodes from there.
; That is both simpler than the FAT16 sector-at-a-time path and much
; faster on a floppy, where chk_fat_read's uncached read would otherwise
; cost a seek per chain hop.
CHK_FAT12_MAXSEC:       equ     12
CHK_FAT12_BUF_LEN:      equ     CHK_FAT12_MAXSEC*512

CHK_REASON_EOC:         equ     0
CHK_REASON_TOOLONG:     equ     1
CHK_REASON_BADCLUSTER:  equ     2
CHK_REASON_FREEHIT:     equ     3
CHK_REASON_BADSECTOR:   equ     4
CHK_REASON_IOERR:       equ     5
CHK_REASON_LOOP:        equ     6

chk_walk_chain:
            mov     rf, chk_wc_hops
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; chk_wc_hops = 0

            mov     rf, chk_wc_capacity
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf                  ; chk_wc_capacity = 0 (4B)

            mov     rf, chk_max_clust
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = max_clust (used directly
                                        ; as the bound -- see the BUG
                                        ; FIX note above; no "+1", which
                                        ; overflowed to 0 for a real
                                        ; max_clust=$FFFF volume)
            mov     rf, chk_wc_remaining
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, chk_wc_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, chk_wc_start
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, chk_wc_prev     ; 0 = still on the first cluster
            ldi     0
            str     rf
            inc     rf
            str     rf

cwc_loop:
            mov     rf, chk_wc_remaining
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = remaining
            glo     r9
            lbnz    cwc_remaining_nz
            ghi     r9
            lbnz    cwc_remaining_nz
            lbr     cwc_toolong

cwc_remaining_nz:
            dec     r9
            mov     rf, chk_wc_remaining
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; load the current cluster into RD and range-check it
            ; (2 <= cluster <= max_clust)
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = current cluster

            ghi     rd
            lbnz    cwc_range_hi_ok     ; high byte nonzero: cluster
                                        ; >= 256, so >= 2 is automatic
            glo     rd
            smi     2
            lbnf    cwc_badcluster      ; cluster < 2

cwc_range_hi_ok:
            mov     r9, rd
            mov     rf, chk_max_clust
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = max_clust
            sub16   r8, r9              ; R8 = max_clust - cluster,
                                        ; DF=1 if max_clust>=cluster
            lbnf    cwc_badcluster      ; DF=0: cluster > max_clust

            ; in range -- mark it (cross-link check is a side effect,
            ; reported here but doesn't stop the walk)
            call    chk_mark_cluster
            lbnf    cwc_not_crosslink
            call    chk_wc_in_chain     ; one of this chain's own clusters?
            lbdf    cwc_looped
            call    K_INMSG
            db      "Cross-linked cluster: ",0
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_crosslink
            call    chk_inc16

cwc_not_crosslink:
            ; prevcap = capacity (snapshot BEFORE this hop's own add --
            ; a plain 4-byte copy, no arithmetic, no carry concerns)
            mov     r7, chk_wc_capacity
            mov     r8, chk_wc_prevcap
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8

            ; capacity += cluster_bytes
            mov     rf, chk_wc_capacity
            mov     rd, chk_cluster_bytes
            call    chk_add32

            ; hops += 1
            mov     rf, chk_wc_hops
            call    chk_inc16

            ; read this cluster's own FAT entry to find the next link
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_fat_read
            lbdf    cwc_ioerr

            ; classify the raw FAT value in RD
            ghi     rd
            lbnz    cwc_check_eoc       ; nonzero high byte: can't be
                                        ; FAT_FREE (0000); check EOC/bad
            glo     rd
            lbz     cwc_freehit         ; RD == 0000 exactly: free

cwc_check_eoc:
            mov     r9, rd
            sub16   r9, FAT_EOC         ; R9 = value - FAT_EOC (immediate
                                        ; constant, not a relocatable
                                        ; symbol -- safe, see gotcha #17),
                                        ; DF=1 if value >= FAT_EOC
            lbdf    cwc_eoc             ; >= FAT_EOC: normal end of chain

            ; not EOC, not free -- check for the exact bad-sector
            ; marker ($FFF7)
            ghi     rd
            xri     high FAT_BAD
            lbnz    cwc_next_link       ; high byte differs: not FAT_BAD,
                                        ; must be an ordinary next-link
                                        ; cluster number -- continue
            glo     rd
            xri     low FAT_BAD
            lbnz    cwc_next_link
            lbr     cwc_badsector

cwc_next_link:
            ; RD names the next cluster in the chain -- store it and
            ; loop back (the top of the loop will range-check it)
            mov     rf, chk_wc_cluster
            mov     r8, chk_wc_prev
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8                  ; prev = the cluster just done
            dec     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     cwc_loop

cwc_eoc:
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_EOC
            str     rf
            clc
            rtn

cwc_looped:
            ; The chain has come back to a cluster it already holds.
            ; Nothing was counted for this second visit, so hops,
            ; capacity and chk_wc_prev describe the chain up to the
            ; cluster whose link closes the loop.
            call    K_INMSG
            db      "Cluster chain loops back on itself at cluster: ",0
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_chain
            call    chk_inc16
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_LOOP
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; chk_wc_in_chain: is chk_wc_cluster one of the chk_wc_hops clusters
; this walk has already been through? Follows the chain again from
; chk_wc_start. Only called when a cluster turns out to be marked
; already, which is rare, so the second walk costs nothing normally.
; Returns: DF = 1 yes (the chain loops), DF = 0 no (a real cross-link)
; Modifies: everything
;------------------------------------------------------------------
chk_wc_in_chain:
            mov     r7, chk_wc_start
            mov     r8, chk_lp_cur
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8
            mov     r7, chk_wc_hops
            mov     r8, chk_lp_left
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8
cwi_loop:
            mov     rf, chk_lp_left
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cwi_more
            glo     r9
            lbz     cwi_no
cwi_more:
            dec     r9
            mov     rf, chk_lp_left
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, chk_lp_cur
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = a cluster of this chain
            mov     rf, chk_wc_cluster
            lda     rf
            str     r2
            ghi     rd
            xor
            lbnz    cwi_next
            ldn     rf
            str     r2
            glo     rd
            xor
            lbz     cwi_yes
cwi_next:
            call    chk_fat_read        ; RD = its link
            lbdf    cwi_no
            mov     rf, chk_lp_cur
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     cwi_loop
cwi_yes:
            stc
            rtn
cwi_no:
            clc
            rtn

cwc_toolong:
            call    K_INMSG
            db      "Cluster chain too long (possible cycle), stopped.",13,10,0
            mov     rf, chk_tally_chain
            call    chk_inc16
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_TOOLONG
            str     rf
            stc
            rtn

cwc_badcluster:
            call    K_INMSG
            db      "Invalid cluster in chain: ",0
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_chain
            call    chk_inc16
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_BADCLUSTER
            str     rf
            stc
            rtn

cwc_freehit:
            call    K_INMSG
            db      "Chain references a free cluster: ",0
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_chain
            call    chk_inc16
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_FREEHIT
            str     rf
            stc
            rtn

cwc_badsector:
            call    K_INMSG
            db      "Bad-sector cluster referenced by a chain: ",0
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_badsector
            call    chk_inc16
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_BADSECTOR
            str     rf
            stc
            rtn

cwc_ioerr:
            call    K_INMSG
            db      "Disk read error while walking a cluster chain.",13,10,0
            mov     rf, chk_wc_reason
            ldi     CHK_REASON_IOERR
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; chk_get_frame: dereference the shared chk_frame_ptr global to get
; the CURRENTLY ACTIVE recursion level's own frame address. Reload
; fresh via this helper every time a frame field is needed -- never
; trust a register to carry the frame address across any other call.
;
; Args:    none
; Returns: R8 = this level's own frame address
; Modifies: R8, RF (and D)
;------------------------------------------------------------------
chk_get_frame:
            mov     rf, chk_frame_ptr
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            rtn

;------------------------------------------------------------------
; chk_walk_dir: recursively walk one directory level and everything
; beneath it. Uses K_DIR_SAVE_STATE/K_DIR_RESTORE_STATE (not a
; heap_bump collect-then-recurse design like progs/xcopy.asm) since
; chkdsk never needs to reorder entries or build destination paths --
; only "resume this level's scan after the subtree beneath one entry
; is fully processed," which those two calls do directly.
;
; Per-recursion-level state (this level's own cluster, its parent's
; cluster, its own depth, and its own 9-byte K_DIR_SAVE_STATE buffer)
; lives in a genuinely separate, depth-indexed "frame" (chk_frames,
; a fixed CHK_MAX_DEPTH*CHK_FRAME_LEN array -- NOT a heap_bump
; allocation or the hardware stack, both considered and rejected in
; the plan as more complex than needed for a handful of small, easily
; depth-indexed fields). The frame's ADDRESS for whichever level is
; currently executing is kept in the shared global chk_frame_ptr,
; reloaded fresh via chk_get_frame before every single use, and
; explicitly protected (push/pop) plus resynced immediately after
; popping across the one recursive call itself -- the exact same
; "xcw_frame_ptr" pattern progs/xcopy.asm already proved correct on
; hardware, since the recursive call's own execution otherwise leaves
; the global pointing at ITS OWN, now-dead frame.
;
; Args:    RD = this level's own starting cluster (0 = root)
;          R9 = this level's own parent cluster (0 if the parent is
;          root; unused/uninspected when RD is itself the root, since
;          FAT16's root has no "."/".." entries to validate against it)
;          RC.0 = this level's own recursion depth (0 for the root)
; Returns: nothing
; Modifies: everything (R7-RD) -- treat as fully clobbering. A
;          caller recursing into this MUST protect chk_frame_ptr's
;          own dereferenced value (not just assume it) exactly as
;          this routine's own recursive call site does.
;------------------------------------------------------------------
CHK_FRAME_DIRSTATE_OFF: equ     0           ; 9 bytes
CHK_FRAME_CLUSTER_OFF:  equ     9           ; 2 bytes
CHK_FRAME_PARENT_OFF:   equ     11          ; 2 bytes
CHK_FRAME_DEPTH_OFF:    equ     13          ; 1 byte
CHK_FRAME_ORD_OFF:      equ     14          ; 2 bytes: entries K_DIR_READ
                                            ; has returned at this level
CHK_FRAME_LEN:          equ     16

chk_walk_dir:
            ; depth cap check FIRST -- smi sets DF=1 if depth >=
            ; CHK_MAX_DEPTH (no borrow, this codebase's own
            ; established SM-family DF convention), before touching
            ; any frame state or args at all
            glo     rc
            smi     CHK_MAX_DEPTH
            lbdf    cwd_too_deep

            ; stash all 3 incoming args to memory IMMEDIATELY -- every
            ; register gets reused freely from here on
            mov     rf, chk_cwd_cluster_arg
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, chk_cwd_parent_arg
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, chk_cwd_depth_arg
            glo     rc
            str     rf

            ; compute this level's own frame offset = depth *
            ; CHK_FRAME_LEN via a small counted-addition loop (depth
            ; is always small, <= CHK_MAX_DEPTH-1 -- not perf-
            ; critical, called once per directory-level entry, and a
            ; plain repeated-add loop is the simplest possible thing
            ; to hand-verify, no multiply-by-constant trick needed)
            mov     rf, chk_cwd_depth_arg
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = depth, zero-extended
                                        ; (loop counter)
            ldi     0
            plo     r8
            phi     r8                  ; R8 = 0 (accumulator)
cwd_mul_loop:
            glo     r9
            lbz     cwd_mul_done
            add16   r8, CHK_FRAME_LEN
            dec     r9
            lbr     cwd_mul_loop
cwd_mul_done:
            ; R8 = depth * CHK_FRAME_LEN

            mov     rf, chk_frames
            add16   rf, r8              ; RF = this level's own frame
                                        ; address
            mov     r7, chk_frame_ptr
            ghi     rf
            str     r7
            inc     r7
            glo     rf
            str     r7                  ; chk_frame_ptr = RF

            ; populate the frame: cluster, parent, depth (all reloaded
            ; fresh from the stashed-args memory, not trusted in any
            ; register across the multiply loop above)
            call    chk_get_frame       ; R8 = frame address

            mov     rf, r8
            add16   rf, CHK_FRAME_CLUSTER_OFF
            mov     rb, chk_cwd_cluster_arg
            lda     rb
            str     rf
            inc     rf
            ldn     rb
            str     rf

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_PARENT_OFF
            mov     rb, chk_cwd_parent_arg
            lda     rb
            str     rf
            inc     rf
            ldn     rb
            str     rf

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_DEPTH_OFF
            mov     rb, chk_cwd_depth_arg
            ldn     rb
            str     rf
            inc     rf                  ; -> CHK_FRAME_ORD_OFF
            ldi     0
            str     rf
            inc     rf
            str     rf

            ; pass B: raw structural scan of this SAME directory
            ; (duplicate short names, orphaned/mismatched LFN entries)
            ; -- independent of pass A below, no shared state, so
            ; order relative to pass A doesn't matter
            mov     rf, chk_cwd_cluster_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_scan_dir_raw

            ; K_DIR_OPEN(RD = this level's own cluster)
            mov     rf, chk_cwd_cluster_arg
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    K_DIR_OPEN

cwd_loop:
            mov     rf, chk_dirent
            call    K_DIR_READ
            lbdf    cwd_done            ; end of this directory

            call    chk_get_frame       ; count it: chk_locate_entry finds
            mov     rf, r8              ; this entry again by its number
            add16   rf, CHK_FRAME_ORD_OFF
            call    chk_inc16

            ; name == "." ?
            mov     rf, chk_dirent
            mov     rd, chk_dot_str
            call    f_strcmp
            lbnz    cwd_not_dot

            ; validate DIRENT_CLUST == this level's own cluster
            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_CLUSTER_OFF
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = expected cluster

            mov     rf, chk_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = actual cluster from "."

            ghi     rb
            str     r2
            ghi     r9
            xor
            lbnz    cwd_dot_mismatch
            glo     rb
            str     r2
            glo     r9
            xor
            lbz     cwd_next
cwd_dot_mismatch:
            call    K_INMSG
            db      ". entry points to the wrong cluster: ",0
            mov     rd, rb
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_structural
            call    chk_inc16
            ldi     CHK_FRAME_CLUSTER_OFF
            call    chk_fix_dot
            lbr     cwd_next

cwd_not_dot:
            ; name == ".." ?
            mov     rf, chk_dirent
            mov     rd, chk_dotdot_str
            call    f_strcmp
            lbnz    cwd_not_dotdot

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_PARENT_OFF
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = expected parent cluster

            mov     rf, chk_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            phi     rb
            ldn     rf
            plo     rb                  ; RB = actual cluster from ".."

            ghi     rb
            str     r2
            ghi     r9
            xor
            lbnz    cwd_dotdot_mismatch
            glo     rb
            str     r2
            glo     r9
            xor
            lbz     cwd_next
cwd_dotdot_mismatch:
            call    K_INMSG
            db      ".. entry points to the wrong cluster: ",0
            mov     rd, rb
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_structural
            call    chk_inc16
            ldi     CHK_FRAME_PARENT_OFF
            call    chk_fix_dot
            lbr     cwd_next

cwd_not_dotdot:
            ; hidden-entry tally (any hidden entry, file or directory)
            mov     rf, chk_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_HIDDEN2
            lbz     cwd_not_hidden
            mov     rf, chk_tally_hidden
            call    chk_inc16
cwd_not_hidden:

            mov     rf, chk_dirent
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR2
            lbz     cwd_is_file

            ; subdirectory: tally, mark its own cluster chain as
            ; "seen" (a directory's own clusters must count as
            ; referenced too, same as a file's), save this level's
            ; scan position, recurse, then restore
            mov     rf, chk_tally_dirs
            call    chk_inc16

            mov     rf, chk_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_walk_chain      ; problems are reported there
            lbnf    cwd_dir_walk
            call    chk_fix_chain       ; D = 0 left alone, 1 chain ended,
            xri     2                   ; 2 = no valid cluster at all
            lbz     cwd_dir_empty

            ; Not descending into a chain that loops, or whose very
            ; first cluster is out of range (K_DIR_OPEN would read
            ; whatever that number happens to address).
            mov     rf, chk_wc_reason
            ldn     rf
            xri     CHK_REASON_TOOLONG
            lbz     cwd_dir_skip
            ldn     rf
            xri     CHK_REASON_LOOP
            lbz     cwd_dir_skip
            ldn     rf
            xri     CHK_REASON_BADCLUSTER
            lbnz    cwd_dir_walk
            mov     rf, chk_wc_prev
            lda     rf
            lbnz    cwd_dir_walk
            ldn     rf
            lbnz    cwd_dir_walk
cwd_dir_skip:
            call    K_INMSG
            db      "   Subdirectory not checked: ",0
            call    chk_print_dirent_name
            call    K_INMSG
            db      13,10,0
            lbr     cwd_next

cwd_dir_empty:
            ; -f, and the directory has no usable cluster: MS-DOS turned
            ; such an entry into a file. It becomes an empty one.
            call    chk_locate_entry
            lbdf    cwd_next
            add16   rf, DE_ATTR
            ldi     ATTR_ARCHIVE
            str     rf
            add16   rf, DE_CLUSTER-DE_ATTR
            ldi     0
            str     rf                  ; DE_CLUSTER (2) and DE_SIZE (4)
            inc     rf                  ; are adjacent
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            call    chk_write_dir_sector
            lbdf    cwd_next
            call    K_INMSG
            db      "   Invalid subdirectory entry converted to an empty file.",13,10,0
            lbr     cwd_next

cwd_dir_walk:
            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_DIRSTATE_OFF
            call    K_DIR_SAVE_STATE

            ; set up the recursive call's own args, each reloaded
            ; fresh from its own source right before use
            mov     rf, chk_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = child's own cluster

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_CLUSTER_OFF
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = this level's cluster,
                                        ; becomes the CHILD's parent

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_DEPTH_OFF
            ldn     rf
            adi     1
            plo     rc                  ; RC.0 = this level's depth + 1

            ; protect chk_frame_ptr's own dereferenced VALUE across
            ; the recursive call -- it otherwise leaves the global
            ; pointing at its own, now-dead frame (the exact xcw_
            ; frame_ptr pattern progs/xcopy.asm already proved)
            call    chk_get_frame       ; R8 = this level's frame addr
            push    r8
            call    chk_walk_dir        ; RECURSION
            pop     r8
            mov     rf, chk_frame_ptr
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf                  ; chk_frame_ptr resynced

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_DIRSTATE_OFF
            call    K_DIR_RESTORE_STATE
            lbr     cwd_next

cwd_is_file:
            mov     rf, chk_tally_files
            call    chk_inc16
            call    chk_check_file

cwd_next:
            lbr     cwd_loop

cwd_done:
            rtn

cwd_too_deep:
            call    K_INMSG
            db      "Directory nesting too deep (possible cycle), not descending further.",13,10,0
            rtn

;------------------------------------------------------------------
; chk_cmp32: compare two 32-bit big-endian values WITHOUT modifying
; either one -- unlike chk_sub32 (which computes the difference in
; place), this discards the subtraction's own numeric result into a
; private scratch buffer and keeps only the final DF. Same exact
; byte-chain shape as chk_sub32 (already verified), just redirecting
; the store target.
;
; Args:    RF = pointer to a (4 bytes BE, unmodified)
;          RD = pointer to b (4 bytes BE, unmodified)
; Returns: DF = 1 if a >= b (no borrow), DF = 0 if a < b
; Modifies: R7, R8, R9 (and D) -- RF/RD themselves untouched
;------------------------------------------------------------------
chk_cmp32:
            mov     r7, rf
            add16   r7, 3
            mov     r8, rd
            add16   r8, 3
            mov     r9, chk_cmp32_scratch
            add16   r9, 3

            ldn     r8
            str     r2
            ldn     r7
            sm
            str     r9

            dec     r7
            dec     r8
            dec     r9
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r9

            dec     r7
            dec     r8
            dec     r9
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r9

            dec     r7
            dec     r8
            dec     r9
            ldn     r8
            str     r2
            ldn     r7
            smb
            str     r9
            rtn

;------------------------------------------------------------------
; chk_print_dirent_name: print chk_dirent's own name field (a plain
; null-terminated string, DIRENT_NAME is offset 0).
; Modifies: RF (and D)
;------------------------------------------------------------------
chk_print_dirent_name:
            mov     rf, chk_dirent
            call    K_MSG
            rtn

;------------------------------------------------------------------
; chk_check_file: check one file's DIRENT_SIZE against its own
; cluster-chain length, using the ALREADY-FILLED chk_dirent buffer
; (the caller's own most recent K_DIR_READ result). No division and
; (per the plan's own arithmetic idioms) no subtraction needed for the
; "smallest size this many clusters could hold" value -- chk_walk_
; chain's own chk_wc_prevcap already IS that value, free.
;
; Args:    none (reads chk_dirent directly)
; Returns: nothing
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
chk_check_file:
            ; tally this file's size toward the summary's "bytes in
            ; N files" line, unconditionally, before any check outcome
            ; is known -- matches counting real allocated space, not
            ; just files that passed the check
            mov     rf, chk_tally_file_bytes
            mov     rd, chk_dirent
            add16   rd, DIRENT_SIZE
            call    chk_add32

            mov     rf, chk_dirent
            add16   rf, DIRENT_CLUST
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = DIRENT_CLUST

            ghi     rd
            lbnz    ccf_have_cluster
            glo     rd
            lbnz    ccf_have_cluster

            ; DIRENT_CLUST == 0 -- no allocated cluster. OK only if
            ; size is also 0 (never-allocated empty file, this
            ; project's own established lazy-allocation convention).
            mov     rf, chk_dirent
            add16   rf, DIRENT_SIZE
            lda     rf
            lbnz    ccf_nocluster_baddata
            lda     rf
            lbnz    ccf_nocluster_baddata
            lda     rf
            lbnz    ccf_nocluster_baddata
            ldn     rf
            lbnz    ccf_nocluster_baddata
            rtn                         ; size==0, cluster==0: OK

ccf_nocluster_baddata:
            call    K_INMSG
            db      "File has data but no allocated cluster: ",0
            call    chk_print_dirent_name
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_mismatch
            call    chk_inc16

            mov     rf, chk_fix
            ldn     rf
            lbz     ccf_done
            call    chk_locate_entry
            lbdf    ccf_done
            add16   rf, DE_SIZE
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            call    chk_write_dir_sector
            lbdf    ccf_done
            call    K_INMSG
            db      "   Allocation error, size adjusted.",13,10,0
            rtn

ccf_have_cluster:
            call    chk_walk_chain      ; RD already holds DIRENT_CLUST
            lbnf    ccf_size_check
                                        ; DF=1: chk_walk_chain already
                                        ; reported the specific problem
            call    chk_fix_chain       ; D = 0 left alone, 1 chain ended,
            lbz     ccf_done            ; 2 = no valid cluster at all
            smi     1
            lbz     ccf_size_check      ; ended: now check the size

            ; no valid cluster: empty the entry
            call    chk_locate_entry
            lbdf    ccf_done
            add16   rf, DE_CLUSTER
            ldi     0
            str     rf                  ; DE_CLUSTER (2) and DE_SIZE (4)
            inc     rf                  ; are adjacent
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            call    chk_write_dir_sector
            lbdf    ccf_done
            call    K_INMSG
            db      "   First cluster number is invalid, entry truncated.",13,10,0
            rtn

ccf_size_check:

            ; hops == 1 and size == 0 is the one explicitly tolerated
            ; case (a lazily-allocated first cluster on a still-empty
            ; file) -- anything else with size == 0 (hops >= 2) falls
            ; through to the normal range compare below and is
            ; correctly flagged, since nothing in this project's own
            ; file_open history suggests a 0-byte file should ever
            ; legitimately hold more than one cluster
            mov     rf, chk_wc_hops
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = hops
            ghi     r9
            lbnz    ccf_normal_compare
            glo     r9
            xri     1
            lbnz    ccf_normal_compare

            mov     rf, chk_dirent
            add16   rf, DIRENT_SIZE
            lda     rf
            lbnz    ccf_normal_compare
            lda     rf
            lbnz    ccf_normal_compare
            lda     rf
            lbnz    ccf_normal_compare
            ldn     rf
            lbnz    ccf_normal_compare
            rtn                         ; size==0, hops==1: OK

ccf_normal_compare:
            ; size > prevcap required, i.e. NOT(prevcap >= size)
            mov     rf, chk_wc_prevcap
            mov     rd, chk_dirent
            add16   rd, DIRENT_SIZE
            call    chk_cmp32           ; DF=1 if prevcap >= size
            lbdf    ccf_mismatch        ; prevcap >= size: size is NOT
                                        ; > prevcap -- bad

            ; size <= capacity required, i.e. capacity >= size
            mov     rf, chk_wc_capacity
            mov     rd, chk_dirent
            add16   rd, DIRENT_SIZE
            call    chk_cmp32           ; DF=1 if capacity >= size
            lbnf    ccf_mismatch        ; DF=0: capacity < size -- bad
            rtn                         ; both checks passed -- OK

ccf_mismatch:
            call    K_INMSG
            db      "File size/cluster-chain mismatch: ",0
            call    chk_print_dirent_name
            call    K_INMSG
            db      " (chain holds ",0
            mov     rf, chk_wc_hops
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " cluster(s))",13,10,0
            mov     rf, chk_tally_mismatch
            call    chk_inc16

            ; -f: as MS-DOS did, the size becomes what the chain holds
            mov     rf, chk_fix
            ldn     rf
            lbz     ccf_done
            call    chk_locate_entry
            lbdf    ccf_done
            add16   rf, DE_SIZE         ; little-endian on disk
            mov     r8, chk_wc_capacity
            add16   r8, 3
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            call    chk_write_dir_sector
            lbdf    ccf_done
            call    K_INMSG
            db      "   Allocation error, size adjusted.",13,10,0
ccf_done:
            rtn

;------------------------------------------------------------------
; chk_copy4: copy 4 bytes from R7 to R8.
; Modifies: R7, R8 (and D)
;------------------------------------------------------------------
chk_copy4:
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8
            rtn

;------------------------------------------------------------------
; chk_fix_chain: with -f, end a chain that chk_walk_chain just reported
; as running into something invalid. MS-DOS's "has invalid cluster,
; file truncated".
;   - the chain reached a free cluster: that cluster becomes the end
;   - the next link is out of range, names a cluster marked bad, or
;     leads back into the chain itself: the cluster before it becomes
;     the end
; A chain that could not be read is left alone.
;
; Returns: D = 0 nothing changed (no -f, not repairable, write error)
;          D = 1 chain ended; chk_wc_hops/capacity/prevcap describe it
;          D = 2 not even the first cluster is usable: nothing written,
;                the caller empties the directory entry
; Modifies: everything
;------------------------------------------------------------------
chk_fix_chain:
            mov     rf, chk_fix
            ldn     rf
            lbz     cfc_none
            mov     rf, chk_wc_reason
            ldn     rf
            xri     CHK_REASON_FREEHIT
            lbz     cfc_free
            ldn     rf
            xri     CHK_REASON_BADCLUSTER
            lbz     cfc_cut
            ldn     rf
            xri     CHK_REASON_LOOP
            lbz     cfc_cut
            ldn     rf
            xri     CHK_REASON_BADSECTOR
            lbz     cfc_bad
cfc_none:
            ldi     0
            rtn

cfc_free:
            mov     rf, chk_wc_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            lbr     cfc_end_at

cfc_bad:
            ; the bad-marked cluster was counted before its mark was
            ; seen: take it back out
            mov     rf, chk_wc_hops
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            dec     r9
            dec     rf
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     r7, chk_wc_prevcap
            mov     r8, chk_wc_capacity
            call    chk_copy4
cfc_cut:
            mov     rf, chk_wc_prev
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ghi     rd
            lbnz    cfc_cut_go
            glo     rd
            lbnz    cfc_cut_go
            ldi     2                   ; nothing before it
            rtn
cfc_cut_go:
            ; RD = the last good cluster. Write the end mark first, so
            ; a failed write leaves the counters unused.
            ldi     $FF
            phi     rb
            plo     rb
            call    chk_fat_write
            lbdf    cfc_none
            call    chk_fat_flush
            lbdf    cfc_none
            ; prevcap = capacity less one cluster (hops is at least 1)
            mov     r7, chk_wc_capacity
            mov     r8, chk_wc_prevcap
            call    chk_copy4
            mov     rf, chk_wc_prevcap
            mov     rd, chk_cluster_bytes
            call    chk_sub32
            lbr     cfc_done

cfc_end_at:
            ldi     $FF
            phi     rb
            plo     rb
            call    chk_fat_write
            lbdf    cfc_none
            call    chk_fat_flush
            lbdf    cfc_none
cfc_done:
            call    K_INMSG
            db      "   Chain ended at its last valid cluster.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; chk_fix_dot: with -f, correct the cluster of the "." or ".." entry
; K_DIR_READ just returned.
; Args:    D = CHK_FRAME_CLUSTER_OFF for ".", CHK_FRAME_PARENT_OFF for
;          ".." -- the frame field holding the right value
; Modifies: everything
;------------------------------------------------------------------
chk_fix_dot:
            plo     r9
            mov     rf, chk_fx_off
            glo     r9
            str     rf
            mov     rf, chk_fix
            ldn     rf
            lbz     cfd_done
            call    chk_locate_entry    ; RF = the raw entry
            lbdf    cfd_done
            mov     r7, rf
            call    chk_get_frame       ; R8 = frame (RF, D changed)
            mov     rf, chk_fx_off
            ldn     rf
            str     r2
            glo     r8
            add
            plo     r8
            ghi     r8
            adci    0
            phi     r8
            lda     r8
            phi     r9
            ldn     r8
            plo     r9                  ; R9 = the right cluster
            add16   r7, DE_CLUSTER
            glo     r9
            str     r7                  ; little-endian on disk
            inc     r7
            ghi     r9
            str     r7
            call    chk_write_dir_sector
            lbdf    cfd_done
            call    K_INMSG
            db      "   Corrected.",13,10,0
cfd_done:
            rtn

;------------------------------------------------------------------
; chk_raw_begin: start a raw, sector-by-sector walk of a directory.
; Args:    RD = the directory's first cluster (0 = root)
; Modifies: everything
;------------------------------------------------------------------
chk_raw_begin:
            mov     rf, chk_dpb_entry_idx
            ldi     16                  ; chk_raw_next: no sector yet
            str     rf

            ghi     rd
            lbnz    crb_subdir
            glo     rd
            lbnz    crb_subdir

            ; ---- root ----
            mov     rf, chk_dpb_is_root
            ldi     1
            str     rf

            mov     rf, chk_dpb_root_sector_idx
            ldi     0
            str     rf
            inc     rf
            str     rf

            mov     rf, chk_root_ents
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = root_ents
            shr16   r9
            shr16   r9
            shr16   r9
            shr16   r9                  ; 16 entries per sector
            mov     rf, chk_dpb_root_sectors
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     r7, chk_root_lba
            mov     r8, chk_dpb_lba
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8
            rtn

crb_subdir:
            mov     rf, chk_dpb_is_root
            ldi     0
            str     rf

            mov     rf, chk_dpb_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, chk_dpb_sector_in_cluster
            ldi     0
            str     rf

            call    chk_cluster_to_lba ; RD still = first cluster
            mov     rf, chk_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf
            rtn

;------------------------------------------------------------------
; chk_raw_next: the next in-use short entry of the directory begun with
; chk_raw_begin. Skips exactly what the kernel's dir_read skips --
; deleted entries, LFN entries, volume labels -- so the Nth entry here
; is the Nth entry K_DIR_READ returns.
; Returns: DF = 0, RF = the entry (in chk_dpb_secbuf; also kept in
;          chk_dpb_entry_ptr); DF = 1 at the end of the directory
; Modifies: everything
;------------------------------------------------------------------
chk_raw_next:
            mov     rf, chk_dpb_entry_idx
            ldn     rf
            xri     16
            lbnz    crn_have
            call    chk_read_next_dir_sector
            lbdf    crn_end
            mov     rf, chk_dpb_entry_idx
            ldi     0
            str     rf
crn_have:
            mov     rf, chk_dpb_entry_idx
            ldn     rf
            plo     r9
            adi     1
            str     rf
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9                  ; R9 = index * 32
            mov     rf, chk_dpb_secbuf
            add16   rf, r9
            mov     r8, chk_dpb_entry_ptr
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8

            ldn     rf
            lbz     crn_end             ; $00: end of directory
            xri     $E5
            lbz     chk_raw_next        ; deleted
            add16   rf, DE_ATTR
            ldn     rf
            xri     ATTR_LFN
            lbz     chk_raw_next
            ldn     rf
            ani     ATTR_VOLID
            lbnz    chk_raw_next
            call    chk_get_entry_ptr
            clc
            rtn
crn_end:
            stc
            rtn

;------------------------------------------------------------------
; chk_write_dir_sector: write chk_dpb_secbuf back where chk_read_next_
; dir_sector read it from. That routine steps chk_dpb_lba past each
; sector it reads, so the sector in the buffer is at chk_dpb_lba - 1.
; Returns: DF = 0 written; DF = 1 on a write error (repairs then off)
; Modifies: everything
;------------------------------------------------------------------
chk_write_dir_sector:
            mov     rf, chk_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            glo     r7
            smi     1
            plo     r7
            ghi     r7
            smbi    0
            phi     r7
            glo     r8
            smbi    0
            plo     r8
            mov     rf, chk_unit
            ldn     rf
            phi     r8
            mov     rf, chk_dpb_secbuf
            call    K_SECWRITE
            lbdf    chk_write_failed
            clc
            rtn

;------------------------------------------------------------------
; chk_locate_entry: find on disk the entry K_DIR_READ returned last at
; the current level (the one in chk_dirent). K_DIR_READ gives no
; location, so this counts: the frame's CHK_FRAME_ORD_OFF is how many
; entries K_DIR_READ has returned, and chk_raw_next applies the same
; skip rules. The raw entry's cluster must equal chk_dirent's before it
; is accepted, so a miscount can never patch the wrong entry.
;
; Returns: DF = 0, RF = the entry, its sector in chk_dpb_secbuf ready
;          for chk_write_dir_sector; DF = 1 (message printed) if not
; Modifies: everything
;------------------------------------------------------------------
chk_locate_entry:
            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_ORD_OFF
            mov     r7, chk_loc_left
            lda     rf
            str     r7
            inc     r7
            ldn     rf
            str     r7

            call    chk_get_frame
            mov     rf, r8
            add16   rf, CHK_FRAME_CLUSTER_OFF
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_raw_begin
cle_loop:
            call    chk_raw_next
            lbdf    cle_fail
            mov     rf, chk_loc_left
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            dec     r9
            dec     rf
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            ghi     r9
            lbnz    cle_loop
            glo     r9
            lbnz    cle_loop

            call    chk_get_entry_ptr
            add16   rf, DE_CLUSTER      ; little-endian on disk
            mov     r8, chk_dirent
            add16   r8, DIRENT_CLUST    ; big-endian in the dirent
            inc     r8
            lda     rf
            str     r2
            ldn     r8
            xor
            lbnz    cle_fail
            dec     r8
            ldn     rf
            str     r2
            ldn     r8
            xor
            lbnz    cle_fail
            call    chk_get_entry_ptr
            clc
            rtn
cle_fail:
            call    K_INMSG
            db      "   Cannot find the directory entry again; not corrected.",13,10,0
            stc
            rtn

;------------------------------------------------------------------
; chk_lba_inc: increment the running 3-byte big-endian chk_dpb_lba by
; 1, with carry propagation into the top byte. Direct mirror of
; lib/vollabel.asm's own already-proven _vol_scan sequential-sector
; pattern.
; Modifies: R8, RD, RF (and D)
;------------------------------------------------------------------
chk_lba_inc:
            mov     rf, chk_dpb_lba
            lda     rf
            plo     r8                  ; R8.0 = top byte (bits 23-16)
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = bits 15-8 : bits 7-0
            add16   rd, 1
            ghi     rd
            lbnz    clbi_no_carry
            glo     rd
            lbnz    clbi_no_carry
            glo     r8
            adi     1
            plo     r8
clbi_no_carry:
            mov     rf, chk_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; chk_get_entry_ptr: dereference chk_dpb_entry_ptr.
; Returns: RF = current raw directory entry's real address
; Modifies: R9, RF (and D)
;------------------------------------------------------------------
chk_get_entry_ptr:
            mov     rf, chk_dpb_entry_ptr
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            rtn

;------------------------------------------------------------------
; chk_names_equal: compare 11 raw bytes at RF and RD (DE_NAME has no
; NUL terminator, so f_strcmp is not usable here -- a fixed 11-byte
; compare loop instead).
; Args:    RF, RD = two 11-byte buffers
; Returns: DF = 1 if identical, DF = 0 if different
; Modifies: R7, R8, R9 (and D)
;------------------------------------------------------------------
chk_names_equal:
            mov     r7, rf
            mov     r8, rd
            ldi     11
            plo     r9
cne_loop:
            ldn     r8
            str     r2
            ldn     r7
            xor
            lbnz    cne_diff
            inc     r7
            inc     r8
            dec     r9
            glo     r9
            lbnz    cne_loop
            stc
            rtn
cne_diff:
            clc
            rtn

;------------------------------------------------------------------
; chk_copy11: copy 11 raw bytes from RF to RD.
; Modifies: R9, RF, RD (and D)
;------------------------------------------------------------------
chk_copy11:
            ldi     11
            plo     r9
ccp_loop:
            lda     rf
            str     rd
            inc     rd
            dec     r9
            glo     r9
            lbnz    ccp_loop
            rtn

;------------------------------------------------------------------
; chk_print_name11: print an 11-byte raw (non-NUL-terminated,
; space-padded) short name, one character at a time via K_TYPE --
; this codebase's own already-established byte-at-a-time console
; convention (see e.g. this file's own drive-letter print), not the
; f_tty-in-a-loop shape gotcha #14 warns against.
; Args:    RF = 11-byte buffer
; Modifies: R9, RF (and D)
;------------------------------------------------------------------
chk_print_name11:
            ldi     11
            plo     r9
cpn_loop:
            lda     rf
            call    K_TYPE
            dec     r9
            glo     r9
            lbnz    cpn_loop
            rtn

;------------------------------------------------------------------
; chk_report_orphan_lfn: a pending LFN run ended without a valid
; matching short entry (deleted entry, volume label, or end of
; directory reached while a checksum'd LFN sequence was still open).
; Modifies: RF (and D)
;------------------------------------------------------------------
chk_report_orphan_lfn:
            call    K_INMSG
            db      "Orphaned or incomplete LFN entry sequence in directory.",13,10,0
            mov     rf, chk_tally_structural
            call    chk_inc16
            rtn

;------------------------------------------------------------------
; chk_dir_chksum: FAT LFN checksum of an 11-byte short name. Direct
; byte-for-byte mirror of kernel/dir.asm's own already-proven
; _dir_chksum, including its own documented bug-fix note (the running
; checksum must live in RB.0 across the loop-counter check, since
; "glo rc" to test the counter would otherwise clobber D and discard
; it every iteration).
;
; Args:    RF = pointer to 11-byte short name
; Returns: D = checksum
; Modifies: RC.0, RF, RB.0
;------------------------------------------------------------------
chk_dir_chksum:
            ldi     11
            plo     rc
            ldi     0

dcs_loop:
            shr
            lbdf    dcs_setb7
            lbr     dcs_add
dcs_setb7:  ori     $80
dcs_add:
            str     r2
            lda     rf
            add
            plo     rb
            dec     rc
            glo     rc
            lbz     dcs_done
            glo     rb
            lbr     dcs_loop

dcs_done:
            glo     rb
            rtn

;------------------------------------------------------------------
; chk_read_next_dir_sector: read the next sector of the directory
; currently being scanned by chk_scan_dir_raw (root's fixed area, or
; a subdirectory's own cluster chain, tracked via chk_dpb_*) into
; chk_dpb_secbuf.
;
; Returns: DF = 0 with chk_dpb_secbuf filled; DF = 1 at true end of
;          directory (root sectors exhausted, subdirectory FAT chain
;          reached EOC/free/bad, or a K_SECREAD I/O error -- treated
;          conservatively as end-of-scan rather than risking garbage)
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
chk_read_next_dir_sector:
            mov     rf, chk_dpb_is_root
            ldn     rf
            lbz     crnds_subdir

            ; ---- root: fixed area ----
            mov     r7, chk_dpb_root_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = root_sector_idx
            mov     r7, chk_dpb_root_sectors
            lda     r7
            phi     r8
            ldn     r7
            plo     r8                  ; R8 = root_sectors
            mov     r7, r9
            sub16   r7, r8              ; DF=1 if idx >= total
            lbdf    crnds_eof

            mov     rf, chk_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, chk_unit
            ldn     rf
            phi     r8                  ; R8.1 = this drive's block-device unit
            mov     rf, chk_dpb_secbuf
            call    K_SECREAD
            lbdf    crnds_eof

            mov     r7, chk_dpb_root_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, chk_dpb_root_sector_idx
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7

            call    chk_lba_inc
            clc
            rtn

crnds_subdir:
            ; ---- subdirectory: cluster chain ----
            mov     rf, chk_dpb_sector_in_cluster
            ldn     rf
            plo     r9
            ldi     0
            phi     r9                  ; R9 = sector_in_cluster
            mov     rf, chk_spc
            ldn     rf
            plo     r8
            ldi     0
            phi     r8                  ; R8 = spc
            mov     r7, r9
            sub16   r7, r8              ; DF=1 if sector_in_cluster>=spc
            lbnf    crnds_subdir_read

            ; sector_in_cluster >= spc: follow the FAT to the next
            ; cluster in this subdirectory's own chain
            mov     rf, chk_dpb_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_fat_read
            lbdf    crnds_eof

            ghi     rd
            lbnz    crnds_check_eoc
            glo     rd
            lbz     crnds_eof           ; free cluster -- stop (already
                                        ; reported by chk_walk_chain's
                                        ; own earlier pass over this
                                        ; same chain)
crnds_check_eoc:
            mov     r9, rd
            sub16   r9, FAT_EOC
            lbdf    crnds_eof           ; >= FAT_EOC: end of this
                                        ; subdirectory's own chain

            mov     rf, chk_dpb_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, chk_dpb_sector_in_cluster
            ldi     0
            str     rf

            call    chk_cluster_to_lba ; RD already = the new cluster
            mov     rf, chk_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

crnds_subdir_read:
            mov     rf, chk_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, chk_unit
            ldn     rf
            phi     r8                  ; R8.1 = this drive's block-device unit
            mov     rf, chk_dpb_secbuf
            call    K_SECREAD
            lbdf    crnds_eof

            mov     rf, chk_dpb_sector_in_cluster
            ldn     rf
            adi     1
            str     rf

            call    chk_lba_inc
            clc
            rtn

crnds_eof:
            stc
            rtn

;------------------------------------------------------------------
; chk_scan_dir_raw: pass B -- a raw, sector-by-sector walk of one
; directory's own storage (independent of K_DIR_OPEN/K_DIR_READ),
; purely for duplicate-short-name and orphaned/checksum-mismatched
; LFN detection -- the narrow slice of structural detail dir_read's
; own LFN resolution silently hides (kernel/dir.asm:374-389 falls
; back to the raw 8.3 name on a checksum mismatch rather than
; surfacing it).
;
; Args:    RD = this directory's own starting cluster (0 = root)
; Returns: nothing
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
chk_scan_dir_raw:
            mov     rf, chk_dup_next_offset
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, chk_dup_capped_reported
            ldi     0
            str     rf
            mov     rf, chk_pb_pending_lfn
            ldi     0
            str     rf

            call    chk_raw_begin       ; RD = this directory's cluster

csdr_loop:
            call    chk_read_next_dir_sector
            lbdf    csdr_done

            mov     rf, chk_dpb_entry_idx
            ldi     0
            str     rf

csdr_entry_loop:
            ; entry_ptr = chk_dpb_secbuf + entry_idx*32 (entry_idx is
            ; small, 0-15 -- a plain 5-bit shift, not a general
            ; multiply)
            mov     rf, chk_dpb_entry_idx
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9                  ; R9 = entry_idx * 32
            mov     rf, chk_dpb_secbuf
            add16   rf, r9
            mov     r8, chk_dpb_entry_ptr
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8

            call    chk_get_entry_ptr  ; RF = entry pointer, fresh
            ldn     rf
            lbz     csdr_hit_end
            xri     $E5
            lbz     csdr_deleted

            call    chk_get_entry_ptr
            add16   rf, DE_ATTR
            ldn     rf
            xri     ATTR_LFN
            lbz     csdr_lfn_entry

            call    chk_get_entry_ptr
            add16   rf, DE_ATTR
            ldn     rf
            ani     ATTR_VOLID
            lbnz    csdr_volid_entry

            ; ordinary short entry -- checksum check against any
            ; pending LFN run, then duplicate-name check
            mov     rf, chk_pb_pending_lfn
            ldn     rf
            lbz     csdr_no_pending

            call    chk_get_entry_ptr
            call    chk_dir_chksum      ; D = computed checksum
            plo     rb                  ; stash it (rb free here)
            mov     rf, chk_pb_pending_chksum
            ldn     rf
            str     r2
            glo     rb
            xor
            lbz     csdr_no_pending
            call    K_INMSG
            db      "LFN checksum mismatch before: ",0
            call    chk_get_entry_ptr
            call    chk_print_name11
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_structural
            call    chk_inc16

csdr_no_pending:
            mov     rf, chk_pb_pending_lfn
            ldi     0
            str     rf

            ; duplicate short-name search: search_offset walks 0 ..
            ; chk_dup_next_offset (exclusive) in steps of 11
            mov     rf, chk_dup_search_offset
            ldi     0
            str     rf
            inc     rf
            str     rf

csdr_dup_search:
            mov     r7, chk_dup_search_offset
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = search_offset
            mov     r7, chk_dup_next_offset
            lda     r7
            phi     r8
            ldn     r7
            plo     r8                  ; R8 = next_offset (bound)
            mov     r7, r9
            sub16   r7, r8              ; DF=1 if search_offset>=bound
            lbdf    csdr_dup_after_search

            mov     r7, chk_dup_names
            add16   r7, r9              ; R7 = candidate pointer
            mov     rd, r7
            call    chk_get_entry_ptr  ; RF = entry's own 11-byte name
            call    chk_names_equal
            lbdf    csdr_dup_found

            mov     r7, chk_dup_search_offset
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 11
            mov     r7, chk_dup_search_offset
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7
            lbr     csdr_dup_search

csdr_dup_after_search:
            mov     r7, chk_dup_next_offset
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = next_offset
            mov     r8, r9
            sub16   r8, CHK_DUPNAME_CAP*11  ; DF=1 if next_offset>=cap
            lbdf    csdr_dup_truncated

            mov     rd, chk_dup_names
            add16   rd, r9              ; RD = destination
            call    chk_get_entry_ptr  ; RF = source (entry's name)
            call    chk_copy11

            mov     r7, chk_dup_next_offset
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 11
            mov     r7, chk_dup_next_offset
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7
            lbr     csdr_entry_done

csdr_dup_truncated:
            mov     rf, chk_dup_capped_reported
            ldn     rf
            lbnz    csdr_entry_done
            ldi     1
            str     rf
            call    K_INMSG
            db      "Directory too large, duplicate-name check truncated.",13,10,0
            lbr     csdr_entry_done

csdr_dup_found:
            call    K_INMSG
            db      "Duplicate short name in directory: ",0
            mov     r7, chk_dup_search_offset
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            mov     rf, chk_dup_names
            add16   rf, r9
            call    chk_print_name11
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_tally_structural
            call    chk_inc16
            lbr     csdr_entry_done

csdr_lfn_entry:
            call    chk_get_entry_ptr
            add16   rf, LFN_CHKSUM
            mov     r8, chk_pb_pending_chksum
            ldn     rf
            str     r8
            mov     r8, chk_pb_pending_lfn
            ldi     1
            str     r8
            lbr     csdr_entry_done

csdr_volid_entry:
            mov     rf, chk_pb_pending_lfn
            ldn     rf
            lbz     csdr_entry_done
            call    chk_report_orphan_lfn
            mov     rf, chk_pb_pending_lfn
            ldi     0
            str     rf
            lbr     csdr_entry_done

csdr_deleted:
            mov     rf, chk_pb_pending_lfn
            ldn     rf
            lbz     csdr_entry_done
            call    chk_report_orphan_lfn
            mov     rf, chk_pb_pending_lfn
            ldi     0
            str     rf

csdr_entry_done:
            mov     rf, chk_dpb_entry_idx
            ldn     rf
            adi     1
            str     rf
            xri     16
            lbz     csdr_sector_done
            lbr     csdr_entry_loop

csdr_sector_done:
            lbr     csdr_loop

csdr_hit_end:
            mov     rf, chk_pb_pending_lfn
            ldn     rf
            lbz     csdr_done
            call    chk_report_orphan_lfn

csdr_done:
            rtn

;------------------------------------------------------------------
; chk_bit_is_set: read-only check of a cluster's own bit in the
; "seen" bitmap (mirrors chk_mark_cluster's own bit-index math, kept
; as a separate, independently-written routine rather than factored
; together with it -- chk_mark_cluster is already verified working,
; and refactoring it purely for DRY-ness with no hardware available
; to re-confirm the result isn't worth the risk at this stage).
;
; Args:    RD = cluster number (must already be range-checked, 2 <=
;          cluster <= chk_max_clust, by the caller)
; Returns: DF = 1 if the bit is set, DF = 0 if not
; Modifies: R8, R9, RB, RD, RF (and D)
;------------------------------------------------------------------
chk_bit_is_set:
            dec     rd
            dec     rd                  ; RD = cluster - 2

            ghi     rd
            phi     r8
            glo     rd
            plo     r8                  ; R8 = cluster - 2

            glo     r8
            ani     7
            plo     r9                  ; R9.0 = bit position (0-7)

            shr16   r8
            shr16   r8
            shr16   r8                  ; R8 = byte_index

            ldi     1
            plo     rb
cbis_shiftloop:
            glo     r9
            lbz     cbis_shiftdone
            glo     rb
            shl
            plo     rb
            dec     r9
            lbr     cbis_shiftloop
cbis_shiftdone:

            mov     rd, chk_bm_base
            lda     rd
            phi     rf
            ldn     rd
            plo     rf
            add16   rf, r8
            ldn     rf
            str     r2
            glo     rb
            and
            lbz     cbis_notset
            stc
            rtn
cbis_notset:
            clc
            rtn

;------------------------------------------------------------------
; chk_fat_scan_lost: sequential scan of the whole FAT table (reusing
; chk_dpb_lba/chk_lba_inc/chk_fr_secbuf -- all idle by this point,
; the tree walk having already finished), tallying free clusters and
; counting any ALLOCATED cluster (nonzero FAT entry) whose bit in
; the "seen" bitmap was never set by the tree walk -- a lost cluster.
; chk_lost_chains reports them and, with -f, deals with them.
;
; Args:    none
; Returns: nothing
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
; BUG FIX (2026-08-02): chk_fscan_cluster used to start at 2 (skipping
; the two reserved clusters up front) while chk_fscan_entry_idx (the
; byte-offset index into whichever FAT sector is currently loaded)
; always starts/resets at 0 -- since the two counters only ever
; increment together, by exactly 1 each, this left them permanently
; offset by a constant +2 for the ENTIRE scan, not just near a
; boundary: at every point, chk_fscan_cluster's own reported value was
; 2 MORE than the real cluster whose FAT entry was actually being
; decoded (algebraically: entry_idx = t mod 256, sector_idx = t div
; 256, so sector_idx*256+entry_idx == t exactly, while cluster == t+2
; -- confirmed via a mechanical simulation across the full 16-bit
; range before trusting this). Confirmed on hardware (2026-08-02): a
; drive with exactly one real entry (a single-cluster subdirectory at
; cluster 3, correctly visited and marked "seen" by the tree walk)
; still reported "Lost cluster: 2" (really decoding cluster 0's own
; always-nonzero reserved FAT entry, mislabeled) and "Lost cluster: 5"
; (really decoding cluster 3's own entry -- correctly allocated -- but
; checking the "seen" bitmap under the WRONG label, 5, which was never
; marked). Fixed by tracking cluster from 0 (perfectly in lockstep
; with entry_idx, offset always 0) and explicitly skipping/never
; reporting on the two reserved cluster numbers (0, 1) via a dedicated
; check inside cfsl_entry_loop below, rather than trying to start the
; two counters at a mismatched offset.
chk_fat_scan_lost:
            mov     rf, chk_fat12
            ldn     rf
            lbz     cfsl_fat16

            ; FAT12: the whole FAT is already in RAM, so walk the
            ; clusters directly -- no sector loop, no entry_idx.
            mov     rf, chk_fscan_cluster
            ldi     0
            str     rf
            inc     rf
            ldi     2
            str     rf                  ; cluster = 2
cfsl12_loop:
            mov     r7, chk_fscan_cluster
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = cluster
            mov     r7, chk_max_clust
            lda     r7
            phi     r8
            ldn     r7
            plo     r8                  ; R8 = max_clust
            mov     r7, r8
            sub16   r7, r9              ; DF=1 if max_clust >= cluster
            lbnf    cfsl12_done

            ghi     r9
            phi     rd
            glo     r9
            plo     rd                  ; RD = cluster
            call    chk_fat_read        ; RD = entry (no I/O: RAM copy)
            lbdf    cfsl12_done

            glo     rd
            lbnz    cfsl12_nonzero
            ghi     rd
            lbnz    cfsl12_nonzero
            mov     rf, chk_tally_free
            call    chk_inc16
            lbr     cfsl12_next

cfsl12_nonzero:
            ; an unreferenced bad-cluster marker is not lost -- FORMAT
            ; marks unreadable clusters that way (see cfsl_nonzero)
            glo     rd
            xri     low FAT_BAD
            lbnz    cfsl12_not_bad
            ghi     rd
            xri     high FAT_BAD
            lbnz    cfsl12_not_bad
            mov     rf, chk_tally_badfree
            call    chk_inc16
            lbr     cfsl12_next
cfsl12_not_bad:
            mov     rf, chk_fscan_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_bit_is_set
            lbdf    cfsl12_next         ; referenced -- not lost

            mov     rf, chk_tally_lost
            call    chk_inc16

cfsl12_next:
            mov     r7, chk_fscan_cluster
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, chk_fscan_cluster
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7
            lbr     cfsl12_loop
cfsl12_done:
            rtn

cfsl_fat16:
            ; This scan reads FAT sectors into chk_fr_secbuf itself, so
            ; chk_fat_read's cached sector goes: written out if it was
            ; changed, then forgotten.
            call    chk_fat_flush
            mov     rf, chk_fc_sec
            ldi     $FF
            str     rf
            inc     rf
            str     rf

            mov     rf, chk_fscan_cluster
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; cluster = 0 (tracked in
                                        ; lockstep with entry_idx from
                                        ; here on -- clusters 0/1 are
                                        ; explicitly skipped below,
                                        ; not by starting at a
                                        ; mismatched offset)

            mov     r7, chk_fat_lba
            mov     r8, chk_dpb_lba
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8                  ; chk_dpb_lba = chk_fat_lba

            mov     rf, chk_fscan_sector_idx
            ldi     0
            str     rf
            inc     rf
            str     rf

cfsl_sector_loop:
            mov     r7, chk_fscan_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = sector_idx
            mov     r7, chk_spf
            lda     r7
            phi     r8
            ldn     r7
            plo     r8                  ; R8 = spf
            mov     r7, r9
            sub16   r7, r8              ; DF=1 if sector_idx >= spf
            lbdf    cfsl_done

            mov     rf, chk_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, chk_unit
            ldn     rf
            phi     r8                  ; R8.1 = this drive's block-device unit
            mov     rf, chk_fr_secbuf
            call    K_SECREAD
            lbdf    cfsl_done

            mov     rf, chk_fscan_entry_idx
            ldi     0
            str     rf
            inc     rf
            str     rf

cfsl_entry_loop:
            ; if cluster > max_clust: stop entirely (the FAT's own
            ; last sector may hold padding entries past the real
            ; cluster count)
            mov     r7, chk_fscan_cluster
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = cluster
            mov     r7, chk_max_clust
            lda     r7
            phi     r8
            ldn     r7
            plo     r8                  ; R8 = max_clust
            mov     r7, r8
            sub16   r7, r9              ; DF=1 if max_clust >= cluster
            lbnf    cfsl_done

            ; clusters 0 and 1 are reserved (not real allocatable
            ; clusters) -- R9 still holds cluster fresh from above
            ; (SUB16's register-register form only ever writes back
            ; into its FIRST operand, confirmed against every other
            ; use of this idiom in this file, so R9 is untouched by
            ; the check just above). Skip decoding/reporting for them
            ; entirely rather than special-casing an initial offset.
            ghi     r9
            lbnz    cfsl_decode         ; cluster >= 256: can't be < 2
            glo     r9
            smi     2
            lbnf    cfsl_entry_done     ; cluster is 0 or 1: skip

cfsl_decode:
            ; decode this entry (little-endian on disk)
            mov     r7, chk_fscan_entry_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9                  ; R9 = entry_idx
            shl16   r9                  ; R9 = entry_idx * 2
            mov     rf, chk_fr_secbuf
            add16   rf, r9
            lda     rf
            plo     r8                  ; R8.0 = low byte
            ldn     rf
            phi     r8                  ; R8 = entry value (LE-decoded)

            ghi     r8
            lbnz    cfsl_nonzero
            glo     r8
            lbnz    cfsl_nonzero

            mov     rf, chk_tally_free
            call    chk_inc16
            lbr     cfsl_entry_done

cfsl_nonzero:
            ; A bad-cluster marker ($FFF7) that no chain reaches is not a
            ; lost cluster: it is how FORMAT's surface scan (and MS-DOS
            ; before it) takes an unreadable cluster out of use. Count it
            ; for the summary's "bytes in bad sectors" instead. One that
            ; a chain DOES reach was already reported by chk_walk_chain.
            glo     r8
            xri     low FAT_BAD
            lbnz    cfsl_not_bad
            ghi     r8
            xri     high FAT_BAD
            lbnz    cfsl_not_bad
            mov     rf, chk_tally_badfree
            call    chk_inc16
            lbr     cfsl_entry_done
cfsl_not_bad:
            mov     rf, chk_fscan_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = cluster

            call    chk_bit_is_set
            lbdf    cfsl_entry_done     ; referenced -- not lost

            mov     rf, chk_tally_lost
            call    chk_inc16

cfsl_entry_done:
            mov     r7, chk_fscan_cluster
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, chk_fscan_cluster
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7

            mov     r7, chk_fscan_entry_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, chk_fscan_entry_idx
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7

            ghi     r9                  ; entry_idx's own high byte:
                                        ; nonzero exactly when
                                        ; entry_idx just reached 256
                                        ; (it only ever increments by
                                        ; 1, so this is the first and
                                        ; only moment this goes nonzero)
            lbnz    cfsl_sector_advance
            lbr     cfsl_entry_loop

cfsl_sector_advance:
            mov     r7, chk_fscan_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, chk_fscan_sector_idx
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7

            call    chk_lba_inc
            lbr     cfsl_sector_loop

cfsl_done:
            rtn

;------------------------------------------------------------------
; chk_valid_cluster: is RD a usable cluster number, 2..max_clust?
; Returns: DF = 1 yes, DF = 0 no. RD unchanged.
; Modifies: R8, RF (and D)
;------------------------------------------------------------------
chk_valid_cluster:
            ghi     rd
            lbnz    cvc_hi
            glo     rd
            smi     2
            lbnf    cvc_no              ; 0 or 1
cvc_hi:
            mov     rf, chk_max_clust
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            sub16   r8, rd              ; DF = 1 if max_clust >= RD
            rtn
cvc_no:
            clc
            rtn

;------------------------------------------------------------------
; chk_bm_use2 / chk_bm_use1: point chk_mark_cluster and chk_bit_is_set
; at chk_lost_chains' second bitmap, or back at the "seen" bitmap.
; Both leave RD and DF alone.
; Modifies: R9, RF (and D)
;------------------------------------------------------------------
chk_bm_use2:
            mov     r9, chk_bm2_base
            mov     rf, chk_bm_base
            lda     r9
            str     rf
            inc     rf
            ldn     r9
            str     rf
            rtn
chk_bm_use1:
            mov     r9, chk_bm1_base
            mov     rf, chk_bm_base
            lda     r9
            str     rf
            inc     rf
            ldn     r9
            str     rf
            rtn

;------------------------------------------------------------------
; chk_bit2_test: is RD's bit set in the second bitmap?
; Returns: DF = 1 set, DF = 0 not
; Modifies: R8, R9, RB, RD, RF (and D)
;------------------------------------------------------------------
chk_bit2_test:
            call    chk_bm_use2
            call    chk_bit_is_set
            lbr     chk_bm_use1         ; keeps DF

;------------------------------------------------------------------
; chk_ls_begin / chk_ls_next: step through the lost clusters in
; ascending order. A cluster is lost while its FAT entry is neither
; free nor the bad mark and its "seen" bit is clear -- so freeing one,
; or marking it seen, takes it out of later passes.
; chk_ls_next returns: DF = 0, RD = chk_ls_cluster = the next lost
;          cluster, chk_ls_value = its FAT entry; DF = 1 when there are
;          no more (or the FAT could not be read)
; Modifies: everything
;------------------------------------------------------------------
chk_ls_begin:
            mov     rf, chk_ls_cluster
            ldi     0
            str     rf
            inc     rf
            ldi     1
            str     rf                  ; chk_ls_next steps before it looks
            rtn

chk_ls_next:
            mov     rf, chk_ls_cluster
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = the cluster done last
            mov     rf, chk_max_clust
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     r7, r9
            sub16   r7, r8              ; DF = 1 if it was the last one
            lbdf    cln_end
            inc     r9
            mov     rf, chk_ls_cluster
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rd, r9
            call    chk_fat_read
            lbdf    cln_end
            mov     rf, chk_ls_value
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            ghi     rd
            lbnz    cln_nz
            glo     rd
            lbz     chk_ls_next         ; free
cln_nz:
            ghi     rd
            xri     high FAT_BAD
            lbnz    cln_seen
            glo     rd
            xri     low FAT_BAD
            lbz     chk_ls_next         ; marked bad
cln_seen:
            mov     rf, chk_ls_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_bit_is_set
            lbdf    chk_ls_next         ; belongs to something
            mov     rf, chk_ls_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            clc
            rtn
cln_end:
            stc
            rtn

;------------------------------------------------------------------
; chk_ask_yn: read one key as the answer to a yes/no question, echo it.
; The end of redirected input reads as 0, which is a no.
; Returns: DF = 1 for Y or y, DF = 0 for anything else
; Modifies: everything
;------------------------------------------------------------------
chk_ask_yn:
            call    K_READ
            plo     r9
            mov     rf, chk_key
            glo     r9
            str     rf
            smi     32
            lbnf    cay_nl              ; nothing printable to echo
            ldn     rf
            call    K_TYPE
cay_nl:
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_key
            ldn     rf
            ani     $DF
            xri     'Y'
            lbz     cay_yes
            clc
            rtn
cay_yes:
            stc
            rtn

;------------------------------------------------------------------
; chk_lost_bytes: chk_ck_size = chk_tally_lost clusters, in bytes, then
; print it.
; Modifies: everything
;------------------------------------------------------------------
chk_lost_bytes:
            mov     rf, chk_tally_lost
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, chk_spc
            ldn     rf
            plo     rc
            call    chk_mul16x8
            mov     rf, chk_ck_size
            call    chk_scale_mul_result_x512
            mov     rf, chk_ck_size
            lbr     chk_print_size32_field

;------------------------------------------------------------------
; chk_lost_chains: report the lost clusters chk_fat_scan_lost counted
; and, with -f, ask what MS-DOS asked: turn each lost chain into a file
; in the root (FILE0000.CHK, FILE0001.CHK ...) or free the clusters.
;
; A chain's first cluster is a lost cluster no other lost cluster links
; to. Finding those takes a second bitmap, "a lost cluster links to
; this one". It needs no memory of its own: by now the duplicate-name
; table is idle and, on FAT16, so is the FAT12 buffer declared right
; before it -- together 8,960 bytes, more than the 8,192 the largest
; FAT16 needs. A FAT12 volume needs at most 511 bytes and uses the
; duplicate-name table alone.
;
; Modifies: everything
;------------------------------------------------------------------
chk_lost_chains:
            mov     rf, chk_tally_lost
            lda     rf
            lbnz    clc_some
            ldn     rf
            lbnz    clc_some
            rtn
clc_some:
            call    chk_fat_flush

            mov     rf, chk_fat12
            ldn     rf
            lbnz    clc_b12
            mov     r9, chk_fat12_buf
            lbr     clc_bset
clc_b12:
            mov     r9, chk_dup_names
clc_bset:
            mov     rf, chk_bm2_base
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            mov     rf, chk_bitmap_needed
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                  ; R8 = bytes to clear at R9
clc_z:
            ghi     r8
            lbnz    clc_zb
            glo     r8
            lbz     clc_zd
clc_zb:
            ldi     0
            str     r9
            inc     r9
            dec     r8
            lbr     clc_z
clc_zd:

            ; pass 1: note every cluster some lost cluster links to
            call    chk_ls_begin
clc_p1:
            call    chk_ls_next
            lbdf    clc_p1d
            mov     rf, chk_ls_value
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_valid_cluster
            lbnf    clc_p1
            call    chk_bm_use2
            call    chk_mark_cluster
            call    chk_bm_use1
            lbr     clc_p1
clc_p1d:

            ; pass 2: count the lost clusters nothing links to
            mov     rf, chk_lost_nchains
            ldi     0
            str     rf
            inc     rf
            str     rf
            call    chk_ls_begin
clc_p2:
            call    chk_ls_next
            lbdf    clc_p2d
            call    chk_bit2_test
            lbdf    clc_p2
            mov     rf, chk_lost_nchains
            call    chk_inc16
            lbr     clc_p2
clc_p2d:

            mov     rf, chk_tally_lost
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " lost cluster(s) found in ",0
            mov     rf, chk_lost_nchains
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " chain(s).",13,10,0

            mov     rf, chk_fix
            ldn     rf
            lbnz    clc_ask
            call    chk_lost_bytes
            call    K_INMSG
            db      " bytes of disk space would be freed.",13,10,0
            rtn

clc_ask:
            call    K_INMSG
            db      "Convert lost chains to files (Y/N)? ",0
            call    chk_ask_yn
            lbdf    clc_convert

            ; ---- free them ----
            call    chk_ls_begin
clc_f:
            call    chk_ls_next         ; RD = a lost cluster
            lbdf    clc_fd
            ldi     0
            phi     rb
            plo     rb
            call    chk_fat_write
            lbdf    clc_ret
            lbr     clc_f
clc_fd:
            call    chk_fat_flush
            lbdf    clc_ret
            mov     rf, chk_fix         ; off: a write failed on the way
            ldn     rf
            lbz     clc_ret
            call    chk_lost_bytes
            call    K_INMSG
            db      " bytes of disk space freed.",13,10,0

            ; the summary's free space now includes them
            mov     rf, chk_tally_lost
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, chk_tally_free
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            add16   r8, r9
            mov     rf, chk_tally_free
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf
clc_ret:
            rtn

            ; ---- turn them into files ----
clc_convert:
            mov     rf, chk_ck_num
            ldi     0
            str     rf
            inc     rf
            str     rf
            call    chk_ls_begin
clc_c1:
            call    chk_ls_next
            lbdf    clc_c1d
            call    chk_bit2_test
            lbdf    clc_c1              ; not the start of a chain
            call    chk_recover_chain
            lbdf    clc_ret
            lbr     clc_c1
clc_c1d:
            ; Whatever is still lost belongs to a chain that loops back
            ; on itself, which has no first cluster. Each recovery marks
            ; its clusters seen, so starting anywhere takes the lot.
            call    chk_ls_begin
clc_c2:
            call    chk_ls_next
            lbdf    clc_ret
            call    chk_recover_chain
            lbdf    clc_ret
            lbr     clc_c2

;------------------------------------------------------------------
; chk_recover_chain: make a file of the lost chain starting at
; chk_ls_cluster. Walks the chain marking each cluster seen, and ends
; it (FAT entry = end of chain) at the first link that is invalid or
; leads to a cluster something else already owns, so a recovered file
; is never cross-linked. Then creates the next unused /FILEnnnn.CHK
; through the kernel, empty, and writes the chain's first cluster and
; its length in bytes into the new entry.
;
; Returns: DF = 0 recovered; DF = 1 stop (message printed)
; Modifies: everything
;------------------------------------------------------------------
chk_recover_chain:
            mov     rf, chk_ls_cluster
            mov     r8, chk_rc_cur
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8
            mov     rf, chk_rc_count
            ldi     0
            str     rf
            inc     rf
            str     rf
crc_loop:
            mov     rf, chk_rc_cur
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_mark_cluster
            mov     rf, chk_rc_count
            call    chk_inc16

            mov     rf, chk_rc_cur
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_fat_read        ; RD = the link
            lbdf    crc_readerr
            mov     rf, chk_rc_next
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     r9, rd
            sub16   r9, FAT_EOC         ; DF = 1: a proper end of chain
            lbdf    crc_end
            call    chk_valid_cluster   ; RD kept
            lbnf    crc_cut
            call    chk_bit_is_set
            lbdf    crc_cut             ; owned by something else

            mov     rf, chk_rc_next
            mov     r8, chk_rc_cur
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8
            lbr     crc_loop

crc_cut:
            mov     rf, chk_rc_cur
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ldi     $FF
            phi     rb
            plo     rb
            call    chk_fat_write
            lbdf    crc_fail
crc_end:
            call    chk_fat_flush
            lbdf    crc_fail

            ; size = clusters * sectors per cluster * 512
            mov     rf, chk_rc_count
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, chk_spc
            ldn     rf
            plo     rc
            call    chk_mul16x8
            mov     rf, chk_ck_size
            call    chk_scale_mul_result_x512

crc_name:
            call    chk_ck_build
            mov     rf, chk_ck_path
            mov     rd, chk_dirent
            call    K_STAT
            lbdf    crc_create          ; no such file: the name is free
            mov     rf, chk_ck_num
            call    chk_inc16
            mov     rf, chk_ck_num
            lda     rf
            xri     high 10000
            lbnz    crc_name
            ldn     rf
            xri     low 10000
            lbnz    crc_name
            call    K_INMSG
            db      "No FILEnnnn.CHK name is left.",13,10,0
            lbr     crc_fail

crc_create:
            mov     rf, chk_ck_path
            mov     rd, chk_ck_fcb
            mov     ra, chk_dpb_secbuf  ; idle; used as the I/O buffer
            ldi     1
            call    K_FILE_OPEN
            lbdf    crc_rootfull
            mov     rd, chk_ck_fcb
            call    K_FILE_CLOSE

            ; the kernel has been at this disk: drop the FAT16 sector
            ; held here rather than assume it is still current
            mov     rf, chk_fc_sec
            ldi     $FF
            str     rf
            inc     rf
            str     rf

            ; find the new entry in the root by its 11-byte name
            ldi     0
            phi     rd
            plo     rd
            call    chk_raw_begin
crc_find:
            call    chk_raw_next        ; RF = entry
            lbdf    crc_noentry
            mov     rd, chk_ck_name11
            call    chk_names_equal
            lbnf    crc_find

            call    chk_get_entry_ptr
            add16   rf, DE_CLUSTER      ; little-endian on disk
            mov     r8, chk_ls_cluster
            inc     r8
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            inc     rf                  ; -> DE_SIZE
            mov     r8, chk_ck_size
            add16   r8, 3
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            inc     rf
            dec     r8
            ldn     r8
            str     rf
            call    chk_write_dir_sector
            lbdf    crc_fail

            call    K_INMSG
            db      "   Recovered ",0
            mov     rf, chk_ck_path
            add16   rf, 3               ; past "X:/"
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            mov     rf, chk_ck_num
            call    chk_inc16
            clc
            rtn

crc_readerr:
            call    K_INMSG
            db      "Disk read error while following a lost chain.",13,10,0
            lbr     crc_fail
crc_noentry:
            call    K_INMSG
            db      "Cannot find the new file's directory entry.",13,10,0
            lbr     crc_fail
crc_rootfull:
            call    K_INMSG
            db      "No room in the root directory. Delete files there and run CHKDSK -f again.",13,10,0
crc_fail:
            stc
            rtn

;------------------------------------------------------------------
; chk_ck_build: put the drive letter and chk_ck_num (0..9999, as four
; digits) into chk_ck_path ("X:/FILEnnnn.CHK") and chk_ck_name11
; ("FILEnnnnCHK", the form the name takes on disk).
; Modifies: R7, R8, R9, RB, RD, RF (and D). Makes no kernel calls.
;------------------------------------------------------------------
chk_ck_build:
            mov     rf, chk_ck_num
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = what is left of the number
            mov     r8, chk_ck_digits
            mov     r7, 1000
            call    ckb_digit
            mov     r7, 100
            call    ckb_digit
            mov     r7, 10
            call    ckb_digit
            glo     r9
            adi     '0'
            str     r8

            mov     rf, chk_drive_letter
            ldn     rf
            plo     r9
            mov     rf, chk_ck_path
            glo     r9
            str     rf
            add16   rf, 7               ; -> the digits in the path
            mov     r8, chk_ck_digits
            mov     r7, chk_ck_name11
            add16   r7, 4               ; -> the digits in the name
            ldi     4
            plo     r9
ckb_cp:
            lda     r8
            str     rf
            str     r7
            inc     rf
            inc     r7
            dec     r9
            glo     r9
            lbnz    ckb_cp
            rtn

            ; one digit: how many times R7 comes out of R9, stored at R8
ckb_digit:
            ldi     '0'
            plo     rb
ckb_dl:
            mov     rd, r9
            sub16   rd, r7              ; DF = 1 if R9 >= R7
            lbnf    ckb_dd
            mov     r9, rd
            glo     rb
            adi     1
            plo     rb
            lbr     ckb_dl
ckb_dd:
            glo     rb
            str     r8
            inc     r8
            rtn

;------------------------------------------------------------------
; chk_print_verdict: after the summary, say what the user should know
; about the problems found: that nothing was changed (no -f), or what
; -f does not repair.
; Modifies: everything
;------------------------------------------------------------------
chk_print_verdict:
            mov     rf, chk_fix_req
            ldn     rf
            lbnz    cpv_fixed

            ; no -f: any problem at all?
            mov     rf, chk_tally_crosslink
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            mov     rf, chk_tally_badsector
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            mov     rf, chk_tally_mismatch
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            mov     rf, chk_tally_lost
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            mov     rf, chk_tally_structural
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            mov     rf, chk_tally_chain
            lda     rf
            lbnz    cpv_errors
            ldn     rf
            lbnz    cpv_errors
            rtn
cpv_errors:
            call    K_INMSG
            db      13,10,"Errors found; -f not given, so nothing was changed.",13,10,0
            rtn

cpv_fixed:
            mov     rf, chk_tally_crosslink
            lda     rf
            lbnz    cpv_xlink
            ldn     rf
            lbz     cpv_done
cpv_xlink:
            call    K_INMSG
            db      13,10,"Cross-linked files are not repaired. Copy each one, then delete",13,10
            db      "the originals.",13,10,0
cpv_done:
            rtn

;------------------------------------------------------------------
; chk_mul16x8: 32-bit = 16-bit * 8-bit, standard shift-add multiply.
; Independently verified via a byte-accurate mechanical simulation of
; this exact instruction sequence across 200,000+ random (a,b) pairs
; plus every real-world-relevant boundary case (including spc=128,
; confirmed on this project's own hardware) before being trusted here.
;
; Args:    RD = a (16-bit), RC.0 = b (8-bit)
; Returns: chk_mul_result (4 bytes, big-endian) = a * b
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
chk_mul16x8:
            mov     rf, chk_mul_result
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf                  ; result = 0

            mov     rf, chk_mul_multiplicand
            ldi     0
            str     rf
            inc     rf
            ldi     0
            str     rf
            inc     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; multiplicand = zero-extend(a)

            mov     rf, chk_mul_multiplier
            glo     rc
            str     rf                  ; multiplier = b

            mov     rf, chk_mul_loopcount
            ldi     8
            str     rf

cmul_loop:
            mov     rf, chk_mul_multiplier
            ldn     rf
            ani     1
            lbz     cmul_no_add

            mov     rf, chk_mul_result
            mov     rd, chk_mul_multiplicand
            call    chk_add32

cmul_no_add:
            ; multiplicand <<= 1 (32-bit, LSB=byte3 first, carry
            ; propagating up into higher bytes; any final carry-out
            ; past the MSB is silently discarded -- harmless for the
            ; real ranges this routine is ever called with here, see
            ; this routine's own header)
            mov     rf, chk_mul_multiplicand
            add16   rf, 3
            ldn     rf
            shl
            str     rf

            dec     rf
            ldn     rf
            shlc
            str     rf

            dec     rf
            ldn     rf
            shlc
            str     rf

            dec     rf
            ldn     rf
            shlc
            str     rf

            ; multiplier >>= 1
            mov     rf, chk_mul_multiplier
            ldn     rf
            shr
            str     rf

            mov     rf, chk_mul_loopcount
            ldn     rf
            smi     1
            str     rf
            lbnz    cmul_loop
            rtn

;------------------------------------------------------------------
; chk_scale_mul_result_x512: dest(4B BE) = chk_mul_result(4B BE) * 512.
; 512 = 2^9: the x256 part is a pure byte reposition (chk_mul_result's
; own byte0 is always 0 for every real value this routine is ever
; called with -- max_clust*spc tops out at 65535*255, 24 bits -- so
; shifting it out costs nothing); the remaining x2 is one more 32-bit
; left shift, whose own final carry-out is the overflow indicator.
;
; Args:    RF = destination pointer (4 bytes BE)
; Returns: DF = 1 if the true product doesn't fit in 32 bits (the
;          theoretical extreme this codebase's own real hardware has
;          never approached); DF = 0 normally, dest filled
; Modifies: everything (R7-RD) -- treat as fully clobbering
;------------------------------------------------------------------
chk_scale_mul_result_x512:
            mov     r8, chk_scale_dest
            ghi     rf
            str     r8
            inc     r8
            glo     rf
            str     r8

            mov     r7, chk_mul_result
            inc     r7                  ; skip old byte0 (always 0)
            mov     r8, chk_scale_dest
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = dest, dereferenced
            lda     r7
            str     rd
            inc     rd
            lda     r7
            str     rd
            inc     rd
            ldn     r7
            str     rd
            inc     rd
            ldi     0
            str     rd                  ; dest = chk_mul_result << 8

            mov     r8, chk_scale_dest
            lda     r8
            phi     rd
            ldn     r8
            plo     rd                  ; RD = dest, dereferenced (fresh)
            add16   rd, 3
            ldn     rd
            shl
            str     rd
            dec     rd
            ldn     rd
            shlc
            str     rd
            dec     rd
            ldn     rd
            shlc
            str     rd
            dec     rd
            ldn     rd
            shlc
            str     rd                  ; DF from this final shlc IS
                                        ; the return value -- str
                                        ; doesn't affect DF
            rtn

;------------------------------------------------------------------
; chk_print_size32_field: load a 4-byte BE value and print it via the
; already-proven fmt_size32 (dir.asm/stat.asm's own routine).
; Args:    RF = pointer to the 4-byte BE value
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
chk_print_size32_field:
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8
            mov     rf, chk_fmt_buf
            call    fmt_size32
            mov     rf, chk_fmt_buf
            call    K_MSG
            rtn

;------------------------------------------------------------------
; chk_print_summary: final DOS-style summary report.
; Modifies: everything (R7-RD)
;------------------------------------------------------------------
chk_print_summary:
            call    K_INMSG
            db      13,10,0

            ; total_bytes = mul16x8(max_clust - 1, spc) * 512 -- valid
            ; clusters run 2..max_clust, so there are max_clust - 1 of
            ; them. BUG FIX (2026-09-11): used max_clust itself, one
            ; cluster too many (hidden until then by krnboot/MOUNT's much
            ; larger max_clust over-estimate).
            mov     rf, chk_max_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd
            mov     rf, chk_spc
            ldn     rf
            plo     rc
            call    chk_mul16x8
            mov     rf, chk_total_bytes
            call    chk_scale_mul_result_x512
            mov     rf, chk_overflow_flag
            lbnf    cps_total_ok
            ldi     1
            str     rf
            lbr     cps_free
cps_total_ok:
            ldi     0
            str     rf

cps_free:
            ; free_bytes = mul16x8(free_cluster_count, spc) * 512
            mov     rf, chk_tally_free
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, chk_spc
            ldn     rf
            plo     rc
            call    chk_mul16x8
            mov     rf, chk_free_bytes
            call    chk_scale_mul_result_x512
            lbnf    cps_free_ok
            mov     rf, chk_overflow_flag
            ldi     1
            str     rf
cps_free_ok:

            mov     rf, chk_overflow_flag
            ldn     rf
            lbnz    cps_overflow_msg
            lbr     cps_print_sizes

cps_overflow_msg:
            call    K_INMSG
            db      "Disk too large to report exact byte counts.",13,10,0
            lbr     cps_after_sizes

cps_print_sizes:
            ; used_bytes = total_bytes - free_bytes (a copy first,
            ; since chk_sub32 modifies its minuend in place and
            ; chk_total_bytes is still needed for its own print below)
            mov     r7, chk_total_bytes
            mov     r8, chk_used_bytes
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            lda     r7
            str     r8
            inc     r8
            ldn     r7
            str     r8

            mov     rf, chk_used_bytes
            mov     rd, chk_free_bytes
            call    chk_sub32

            mov     rf, chk_total_bytes
            call    chk_print_size32_field
            call    K_INMSG
            db      " bytes total disk space",13,10,0

            ; bytes in bad sectors (unreferenced $FFF7 clusters), only
            ; when there are any
            mov     rf, chk_tally_badfree
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            glo     rd
            lbnz    cps_show_badfree
            ghi     rd
            lbz     cps_after_badfree
cps_show_badfree:
            mov     rf, chk_spc
            ldn     rf
            plo     rc
            call    chk_mul16x8
            mov     rf, chk_bad_bytes
            call    chk_scale_mul_result_x512
            mov     rf, chk_bad_bytes
            call    chk_print_size32_field
            call    K_INMSG
            db      " bytes in bad sectors",13,10,0
cps_after_badfree:

            mov     rf, chk_used_bytes
            call    chk_print_size32_field
            call    K_INMSG
            db      " bytes used",13,10,0

            mov     rf, chk_free_bytes
            call    chk_print_size32_field
            call    K_INMSG
            db      " bytes available on disk",13,10,0

cps_after_sizes:
            call    K_INMSG
            db      13,10,0

            mov     rf, chk_tally_files
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " file(s)",13,10,0

            mov     rf, chk_tally_dirs
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " director(y/ies)",13,10,0

            mov     rf, chk_tally_hidden
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      " hidden entr(y/ies)",13,10,0

            ; the remaining problem tallies only print a line when
            ; nonzero -- matches real DOS CHKDSK's own "only mention
            ; it if it happened" convention
            mov     rf, chk_tally_crosslink
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_crosslink
            glo     r9
            lbz     cps_after_crosslink
cps_show_crosslink:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " cross-linked cluster(s) found",13,10,0
cps_after_crosslink:

            mov     rf, chk_tally_lost
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_lost
            glo     r9
            lbz     cps_after_lost
cps_show_lost:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " lost cluster(s) found",13,10,0
cps_after_lost:

            mov     rf, chk_tally_mismatch
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_mismatch
            glo     r9
            lbz     cps_after_mismatch
cps_show_mismatch:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " file(s) with size/cluster-chain mismatches",13,10,0
cps_after_mismatch:

            mov     rf, chk_tally_badsector
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_badsector
            glo     r9
            lbz     cps_after_badsector
cps_show_badsector:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " bad-sector cluster reference(s) found",13,10,0
cps_after_badsector:

            mov     rf, chk_tally_chain
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_chain
            glo     r9
            lbz     cps_after_chain
cps_show_chain:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " damaged cluster chain(s) found",13,10,0
cps_after_chain:

            mov     rf, chk_tally_structural
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    cps_show_structural
            glo     r9
            lbz     cps_after_structural
cps_show_structural:
            mov     rd, r9
            call    chk_print_uint
            call    K_INMSG
            db      " directory structural problem(s) found",13,10,0
cps_after_structural:
            rtn

            end     start

; ---- data ----
chk_drive_letter:   ds      1
chk_path_buf:       ds      4           ; "X:/",0

chk_fat_lba:        ds      3           ; big-endian, matches BPBBLK_*
chk_root_lba:       ds      3
chk_data_lba:       ds      3
chk_spc:            ds      1
chk_spc_shift:      ds      1
chk_root_ents:      ds      2
chk_spf:            ds      2
chk_max_clust:      ds      2
chk_cluster_bytes:  ds      4           ; 32-bit, big-endian

chk_fr_cluster:     ds      2
chk_fr_secbuf:      ds      512

chk_num_buf:        ds      8           ; f_uintout scratch (max 5
                                        ; digits + NUL, some headroom)

chk_bitmap_needed:  ds      2           ; (max_clust+8)>>3, cached

chk_wc_hops:        ds      2
chk_wc_capacity:    ds      4           ; big-endian
chk_wc_prevcap:     ds      4           ; big-endian
chk_wc_remaining:   ds      2
chk_wc_cluster:     ds      2
chk_wc_reason:      ds      1

chk_tally_crosslink:    ds  2
chk_tally_badsector:    ds  2
chk_tally_mismatch:     ds  2
chk_tally_lost:         ds  2
chk_tally_structural:   ds  2
chk_tally_files:        ds  2
chk_tally_dirs:         ds  2
chk_tally_hidden:       ds  2
chk_tally_file_bytes:   ds  4           ; 32-bit, big-endian

chk_mul_result:         ds  4
chk_mul_multiplicand:   ds  4
chk_mul_multiplier:     ds  1
chk_mul_loopcount:      ds  1

chk_scale_dest:         ds  2

chk_fmt_buf:            ds  14
chk_total_bytes:        ds  4
chk_unit:               db  0       ; block-device unit of the checked drive
chk_fat12:              db  0       ; 1 = this volume is FAT12
chk_lf_idx:             db  0       ; chk_load_fat12's sector counter
chk_free_bytes:         ds  4
chk_used_bytes:         ds  4
chk_overflow_flag:      ds  1

chk_cwd_cluster_arg:    ds  2
chk_cwd_parent_arg:     ds  2
chk_cwd_depth_arg:      ds  1

chk_frame_ptr:          ds  2
chk_frames:             ds  CHK_MAX_DEPTH*CHK_FRAME_LEN

chk_dirent:             ds  DIRENT_LEN
chk_dot_str:            db  ".",0
chk_dotdot_str:         db  "..",0

chk_cmp32_scratch:      ds  4

chk_dpb_is_root:            ds  1
chk_dpb_lba:                ds  3           ; big-endian
chk_dpb_root_sector_idx:    ds  2
chk_dpb_root_sectors:       ds  2
chk_dpb_cluster:            ds  2
chk_dpb_sector_in_cluster:  ds  1
chk_dpb_secbuf:             ds  512
chk_dpb_entry_idx:          ds  1
chk_dpb_entry_ptr:          ds  2

chk_pb_pending_lfn:         ds  1
chk_pb_pending_chksum:      ds  1

; chk_fat12_buf and chk_dup_names MUST stay adjacent, in this order:
; chk_lost_chains uses the two together as one 8,192-byte bitmap on a
; FAT16 volume.
chk_fat12_buf:              ds  CHK_FAT12_BUF_LEN
chk_dup_names:              ds  CHK_DUPNAME_CAP*11
#if (CHK_FAT12_BUF_LEN + CHK_DUPNAME_CAP*11) < CHK_BITMAP_LEN
#error chk_fat12_buf + chk_dup_names is smaller than the second bitmap
#endif
chk_dup_next_offset:        ds  2
chk_dup_search_offset:      ds  2
chk_dup_capped_reported:    ds  1

chk_fscan_cluster:          ds  2
chk_fscan_sector_idx:       ds  2
chk_fscan_entry_idx:        ds  2
chk_tally_free:             ds  2
chk_tally_badfree:          ds  2   ; unreferenced $FFF7 clusters
chk_bad_bytes:              ds  4

; ---- -f ----
chk_fix:                    db  0       ; 1 = repairs are being written
chk_fix_req:                db  0       ; 1 = -f was given
chk_drive_slot:             db  0       ; for K_DRIVE_INVALIDATE
chk_num_fats:               db  1
chk_fc_sec:                 ds  2       ; FAT sector in chk_fr_secbuf,
                                        ; $FFFF = none
chk_fc_dirty:               db  0       ; that sector was changed
chk_f12_dirty:              db  0       ; the FAT12 copy was changed
chk_fw_value:               ds  2
chk_fw_copy:                db  0
chk_bm1_base:               ds  2       ; the "seen" bitmap (mem_base)
chk_bm_base:                ds  2       ; bitmap chk_mark_cluster uses
chk_bm2_base:               ds  2       ; chk_lost_chains' second one
chk_wc_prev:                ds  2
chk_wc_start:               ds  2
chk_lp_cur:                 ds  2
chk_lp_left:                ds  2
chk_tally_chain:            ds  2       ; chains ended by something invalid
chk_fx_off:                 db  0
chk_loc_left:               ds  2
chk_key:                    db  0
chk_ls_cluster:             ds  2
chk_ls_value:               ds  2
chk_lost_nchains:           ds  2
chk_rc_cur:                 ds  2
chk_rc_next:                ds  2
chk_rc_count:               ds  2
chk_ck_num:                 ds  2
chk_ck_size:                ds  4       ; big-endian
chk_ck_digits:              ds  4
chk_ck_path:                db  "X:/FILE0000.CHK",0
chk_ck_name11:              db  "FILE0000CHK"

.align  32                  ; an FCB must not straddle a page
chk_ck_fcb:                 ds  FCB_LEN
#if (chk_ck_fcb & $FF) > (256 - FCB_LEN)
#error chk_ck_fcb crosses a page boundary
#endif

; Keep this LAST. Link/02 places the libraries after the last byte this
; file emits, and a `ds` emits none: without an emitted byte here they
; would be linked on top of chk_ck_fcb.
chk_data_end:               db  0
