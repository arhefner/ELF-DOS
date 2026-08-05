;
; chkdsk.asm - check a FAT16 volume for filesystem consistency errors
;
; Usage: CHKDSK [X:]
;
; Check-only (no -f/fix mode -- see CLAUDE.md's own roadmap note: fix
; mode is a deliberately separate, later follow-up, since correcting
; on-disk state will very likely need a reboot afterward to avoid the
; kernel's own BPB/FAT cache going stale relative to what was just
; corrected).
;
; With no argument, checks the currently active drive. With an "X:"
; argument (C-F, case-insensitive), checks that drive instead, WITHOUT
; changing cur_drive -- the same K_PATH_RESOLVE-for-its-side-effect
; trick already proven by progs/xcopy.asm/lib/file_glob.asm.
;
; Checks performed: FAT consistency (lost clusters, cross-linked
; clusters, invalid/out-of-range cluster references, bad-sector
; markers reported as their own category), file size vs. cluster-
; chain-length mismatches, directory entry structural validity
; (duplicate short names, orphaned/checksum-mismatched LFN entries),
; "."/".." correctness, and a final DOS-style summary report.
;
; Zero kernel changes -- built entirely on the existing K_DIR_OPEN/
; K_DIR_READ/K_DIR_SAVE_STATE/K_DIR_RESTORE_STATE/K_SECREAD/
; K_PATH_RESOLVE/K_GETCURDIR/BPB_DATA_PTR primitives. No hardware or
; emulator access exists in this environment -- everything here is
; build-verified only, awaiting a real hardware round. Full design at
; ~/.claude/plans/graceful-fluttering-summit.md.
;
; This is a flat file (no proc/endp, matching every other progs/*.asm
; in this project) -- gotcha #20 (a bare top-level label between
; proc/endp blocks corrupting the linked base address) does not apply
; here, since there are no proc/endp segments at all.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   fmt_size32

; ---- raw on-disk constants (kernel.inc is not includable from progs/) ----
ATTR_RDONLY:    equ     $01
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
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = argv pointer, RC = argc. argv[0] is this program's
            ; own name.
            glo     rc
            smi     2
            lbnf    chk_no_arg          ; argc < 2: check active drive

            ; argv[1] must be present and non-NUL to consider -- fall
            ; through to validating it as a drive-letter token
            mov     rb, ra
            add16   rb, 2
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = argv[1] pointer

            ldn     rf
            ani     $DF                 ; uppercase-fold (same idiom as
                                        ; progs/shell.asm's bare-drive
                                        ; check -- safe: no other byte
                                        ; value aliases into 'C'-'F')
            smi     'C'
            lbnf    chk_usage           ; < 'C': not a drive letter
            smi     4
            lbdf    chk_usage           ; >= 'G': not a drive letter

            mov     rb, rf
            inc     rb
            ldn     rb                  ; D = second character
            xri     ':'
            lbnz    chk_usage           ; no ':' following

            inc     rb
            ldn     rb                  ; D = third character
            lbnz    chk_usage           ; more after "X:": not a bare
                                        ; drive token

            ; valid "X:" token -- recompute the uppercase letter fresh
            ; (the smi chain above destroyed D) and stash it for the
            ; header/"X:/" path build below. Destination pointer set up
            ; BEFORE loading D (gotcha #4 -- mov clobbers D, so it must
            ; never run between computing D and the str that stores it).
            mov     rb, chk_drive_letter
            ldn     rf
            ani     $DF
            str     rb
            lbr     chk_have_drive_arg

chk_no_arg:
            ; no argument: check the ACTIVE drive. K_GETCURDIR already
            ; tells us which one -- no K_PATH_RESOLVE call needed at
            ; all in this branch, since the active drive's BPB is
            ; already the one we want.
            call    K_GETCURDIR         ; D = cur_drive (0-3)
            adi     'C'                 ; D = drive letter
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
            lbnf    chk_print_header

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
            db      "Usage: CHKDSK [X:]",13,10,0
            ldi     1
            rtn

chk_print_header:
            call    K_INMSG
            db      "Checking drive ",0
            mov     rb, chk_drive_letter
            ldn     rb
            call    K_TYPE
            call    K_INMSG
            db      ":",13,10,0

            call    chk_read_bpb

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
            mov     rf, chk_tally_file_bytes
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf

            ; zero the needed portion of the "seen" bitmap --
            ; needed_bytes = (max_clust+8)>>3, only the bytes that
            ; could ever legitimately be touched (avoids an
            ; unconditional 8192-byte zero loop regardless of the
            ; real volume's size). `ds` does NOT zero-initialize
            ; memory in this codebase -- without this, chk_mark_
            ; cluster/chk_bit_is_set would read GARBAGE bits from
            ; uninitialized RAM, producing false cross-link reports
            ; and wrong lost-cluster detection.
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

            mov     rf, chk_bitmap
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

            call    chk_print_summary

            ldi     0
            rtn

;------------------------------------------------------------------
; chk_read_bpb: snapshot the ACTIVE drive's BPB fields into local,
; chkdsk-owned memory. Safe to snapshot ONCE, not re-dereference
; BPB_DATA_PTR on every use like most callers in this codebase do --
; deliberate deviation, justified because chkdsk never calls any
; path-based kernel routine again after this point for the rest of
; the run (see the plan's own "activating a drive" note), so the
; active BPB is guaranteed stable from here on.
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
; chk_fat_read: read the raw 16-bit FAT16 entry for a given cluster,
; directly via K_SECREAD (K_DIR_OPEN/K_DIR_READ never expose this --
; fat_get itself is kernel-internal only). Uncached -- every call
; re-reads the FAT sector from disk; a same-sector cache is a later,
; separately-verified optimization per the plan, not attempted here.
;
; Args:    RD = cluster number
; Returns: DF = 0 with RD = raw 16-bit FAT entry value (little-endian
;          on disk, returned here as an ordinary 16-bit value);
;          DF = 1 on a K_SECREAD I/O error (RD undefined)
; Modifies: R7, R8, R9, RB, RF (and D) -- treat as fully clobbering
;------------------------------------------------------------------
chk_fat_read:
            ; stash the cluster number in memory immediately -- RD
            ; itself is about to be reused as scratch below, and nothing
            ; here may be trusted to survive the eventual K_SECREAD call
            mov     rb, chk_fr_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            ; fat_sector_lba = chk_fat_lba + (cluster >> 8), i.e. the
            ; cluster's own HIGH byte added into chk_fat_lba's low
            ; (bits 7-0) byte, with carry rippled up -- exact mirror of
            ; kernel/fat.asm's _fat_load_sector's own proven shape
            mov     rf, chk_fat_lba
            lda     rf                  ; D = bits 23-16
            plo     r8
            lda     rf                  ; D = bits 15-8
            phi     r7
            lda     rf                  ; D = bits 7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)

            mov     rf, chk_fr_cluster
            ldn     rf                  ; D = cluster high byte (sector index)
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

            mov     rf, chk_fr_secbuf
            call    K_SECREAD
            lbdf    chk_fr_ioerr

            ; byte_offset = (cluster & 0xFF) * 2 -- the cluster's own
            ; low byte, zero-extended then doubled (max 255*2=510,
            ; safely fits in 16 bits, well within one 512-byte sector)
            mov     rf, chk_fr_cluster
            inc     rf                  ; -> cluster's low byte
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9                  ; R9 = byte_offset

            mov     rf, chk_fr_secbuf
            add16   rf, r9              ; RF -> the FAT entry's low byte
                                        ; (little-endian on disk)
            lda     rf                  ; D = entry low byte
            plo     rb
            ldn     rf                  ; D = entry high byte
            phi     rb

            ghi     rb
            phi     rd
            glo     rb
            plo     rd                  ; RD = raw FAT entry value
            clc
            rtn

chk_fr_ioerr:
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

            mov     rf, chk_bitmap
            add16   rf, r8              ; RF -> chk_bitmap[byte_index]

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
CHK_REASON_EOC:         equ     0
CHK_REASON_TOOLONG:     equ     1
CHK_REASON_BADCLUSTER:  equ     2
CHK_REASON_FREEHIT:     equ     3
CHK_REASON_BADSECTOR:   equ     4

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

cwc_toolong:
            call    K_INMSG
            db      "Cluster chain too long (possible cycle), stopped.",13,10,0
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
            ldi     CHK_REASON_BADCLUSTER
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
CHK_FRAME_LEN:          equ     14

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
            call    chk_walk_chain      ; DF ignored -- any problem is
                                        ; already reported by this call

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
            rtn

ccf_have_cluster:
            call    chk_walk_chain      ; RD already holds DIRENT_CLUST
            lbdf    ccf_done            ; DF=1: chk_walk_chain already
                                        ; reported the specific problem

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
ccf_done:
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
            ldi     0
            phi     r8
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
            ldi     0
            phi     r8
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

            ghi     rd
            lbnz    csdr_subdir_init
            glo     rd
            lbnz    csdr_subdir_init

            ; ---- root init ----
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
            shr16   r9                  ; R9 = root_ents >> 4 (16
                                        ; entries/sector)
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

            lbr     csdr_loop

csdr_subdir_init:
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

            call    chk_cluster_to_lba ; RD already = starting cluster
            mov     rf, chk_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

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

            mov     rf, chk_bitmap
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
; reporting any ALLOCATED cluster (nonzero FAT entry) whose bit in
; the "seen" bitmap was never set by the tree walk -- a lost cluster.
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
            ldi     0
            phi     r8
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
            mov     rf, chk_fscan_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = cluster

            call    chk_bit_is_set
            lbdf    cfsl_entry_done     ; referenced -- not lost

            call    K_INMSG
            db      "Lost cluster: ",0
            mov     rf, chk_fscan_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    chk_print_uint
            call    K_INMSG
            db      13,10,0
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

            ; total_bytes = mul16x8(max_clust, spc) * 512
            mov     rf, chk_max_clust
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
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
chk_bitmap:         ds      CHK_BITMAP_LEN

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

chk_dup_names:              ds  CHK_DUPNAME_CAP*11
chk_dup_next_offset:        ds  2
chk_dup_search_offset:      ds  2
chk_dup_capped_reported:    ds  1

chk_fscan_cluster:          ds  2
chk_fscan_sector_idx:       ds  2
chk_fscan_entry_idx:        ds  2
chk_tally_free:             ds  2
