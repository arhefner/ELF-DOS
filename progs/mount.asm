;
; mount.asm - attach an MBR partition to a drive letter at runtime
;
; MOUNT                              list the current drive mapping
; MOUNT <partition> <letter>         mount MBR partition 1-4
; MOUNT <unit> <partition> <letter>  ... from a specific block device
;
; Partition 0 means "no partition table -- the volume starts at sector
; 0", which is how a floppy is laid out: MOUNT 1 0 A: mounts unit 1's
; whole surface as A:.
;
; The unit is a BIOS block-device number, 0-7. It is recorded in the
; drive's BPB (BPBBLK_DEV) at mount time and used for every subsequent
; access to that drive -- see _set_lba_dev in kernel/fat.asm. Omitting
; it means unit 0, which is the boot device and the only one a
; single-device BIOS has.
;
; Replaces (at runtime) the fixed mapping boot/krnboot.asm's own
; partition-scan loop sets up at boot, where MBR entries 0-3 always
; become C:-F:. That scan still runs and is still the default; this
; program just lets any slot be reassigned afterwards.
;
; Entirely userland -- no kernel code is involved beyond one call to
; K_DRIVE_INVALIDATE (see below). The drive tables themselves are
; reached through DRIVE_DATA_PTR, exactly the way boot/krnboot.asm
; reaches them, using the DRIVE_PRESENT/DRIVE_BPB_TABLE_OFF/
; DRIVE_CUR_DIR_OFF offsets published in include/kernel_api.inc.
;
; *** THE ONE ORDERING RULE THAT MATTERS ***
; K_DRIVE_INVALIDATE must be called BEFORE drive_bpb_table[i] is
; overwritten, never after. It flushes the FAT cache if drive i is the
; currently active one, and that flush computes its LBAs from the
; active BPB fields -- so running it against an already-replaced entry
; would write a cached FAT sector to an address derived from the NEW
; partition's geometry. That is silent cross-partition corruption, not
; an error anyone would see. See kernel/kinit.asm's own
; kernel_drive_invalidate header.
;
; The BPB-field arithmetic below (spc_shift, fat_lba, root_lba,
; data_lba, max_clust) is a deliberate port of boot/krnboot.asm's own
; Phase 1 steps 4-8 (and 7b), not an independent re-derivation -- that code is
; hardware-proven on every boot, and two implementations of the same
; FAT16 geometry that disagree in some corner would be a genuinely
; nasty bug to find. Keep them in sync if either changes.
;
; Deliberately refuses to touch the shell's own drive (K_GETSHELLDRIVE).
; Remounting it would leave the cached shell location (shell_elba, see
; kernel/loader.asm's prog_run_shell) pointing into a filesystem that
; is no longer there; the fallback path-based load would then look for
; "<shell_drive>:/bin/shell" on the new partition and, not finding it,
; strand the system with no way to run anything.
;
; Nothing stops the same partition being mounted under two letters at
; once (MOUNT 4 E: then MOUNT 4 F:), and that is deliberate -- it is
; occasionally useful, and refusing it would mean scanning every other
; drive on every mount. It is safe but not free: the two letters keep
; independent current directories, and every switch between them
; flushes and reloads the single shared FAT cache, so it is slower than
; using one letter. Writing through both at once is not something this
; system has ever been tested doing.
;
; A note on 24-bit LBAs: ELF-DOS addresses sectors with 24 bits
; (LBA_SIZE = 3), so a partition must start below sector 2^24 (8GB).
; The MBR's own start-LBA field is 4 bytes; this program checks the
; top byte is zero and reports a clear error rather than silently
; truncating, which is what krnboot's own scan does today.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   drive_letter_of
            extrn   drive_index_of

            extrn   fmt_size32

            org     PROG_BASE

;------------------------------------------------------------------
; 6-byte program header
;------------------------------------------------------------------
            db      'E','D','F'
            db      1                       ; major
            db      0                       ; minor
            db      0                       ; reserved

;------------------------------------------------------------------
; Entry: RA = argv table, RC = argc
;------------------------------------------------------------------
start:
            ; Stash argv/argc immediately -- neither register survives
            ; the first kernel call.
            mov     rf, mnt_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            mov     rf, mnt_argc
            glo     rc
            str     rf

            ; argc < 2 -> no arguments: list the current mapping
            glo     rc
            smi     2
            lbnf    mnt_do_list

            ; Two accepted forms, distinguished by argc:
            ;   MOUNT <partition> <letter>          (argc 3) unit 0
            ;   MOUNT <unit> <partition> <letter>   (argc 4)
            ; The short form is the common case on a single-device
            ; machine and is the syntax that shipped first; the long
            ; form names a block device explicitly.
            mov     rf, mnt_argc
            ldn     rf
            smi     3
            lbz     mnt_form_short
            mov     rf, mnt_argc
            ldn     rf
            smi     4
            lbnz    mnt_usage

            ; long form: argv[1] = unit, so the partition and letter
            ; shift one place right
            ldi     1
            call    mnt_argv_at             ; RF = argv[1]
            lda     rf
            smi     '0'
            lbnf    mnt_bad_unit
            plo     r9                      ; R9.0 = unit
            ldn     rf
            lbnz    mnt_bad_unit            ; more than one character
            glo     r9
            smi     8
            lbdf    mnt_bad_unit            ; only units 0-7 exist: the
                                            ; BIOS masks R8.1 and rejects
                                            ; anything >= 8

            mov     rf, mnt_unit
            glo     r9
            str     rf
            mov     rf, mnt_argbase
            ldi     2
            str     rf                      ; partition is argv[2]
            lbr     mnt_do_mount

mnt_form_short:
            mov     rf, mnt_unit
            ldi     0
            str     rf                      ; default device
            mov     rf, mnt_argbase
            ldi     1
            str     rf                      ; partition is argv[1]
            lbr     mnt_do_mount

mnt_usage:
            call    K_INMSG
            db      "Usage: MOUNT [[<unit 0-7>] <partition 1-4> <drive letter>]",13,10,0
            ldi     1
            rtn

;==================================================================
; Listing mode -- no arguments
;==================================================================
mnt_do_list:
            ; Iterate the LETTER from 'A' to 'Z' and look each one up,
            ; rather than iterating slots. Three things fall out of that:
            ; unmounted slots never appear at all (a row of "(not
            ; mounted)" filler per slot is useless once there are more
            ; than a handful), the output is alphabetically sorted, and
            ; no sort code is needed. 26 lookups of at most DRIVE_COUNT
            ; comparisons each is nothing on this machine.
            call    K_INMSG
            db      "Drive  Unit  Partition start LBA",13,10,0

            mov     rf, mnt_shown
            ldi     0
            str     rf                      ; nothing listed yet

            mov     rf, mnt_i
            ldi     DRIVE_LETTER_MIN
            str     rf                      ; start at 'A'

mnt_list_loop:
            mov     rf, mnt_i
            ldn     rf
            call    mnt_slot_of_letter      ; DF=1 -> that letter is not
            lbdf    mnt_list_next           ;         mounted; skip it
            plo     rc                      ; stash before the mov below
                                            ; clobbers D (gotcha #4)
            mov     rf, mnt_slot
            glo     rc
            str     rf                      ; remember which slot

            ; --- letter ---
            mov     rf, mnt_i
            ldn     rf
            call    K_TYPE
            ldi     ':'
            call    K_TYPE
            call    K_INMSG
            db      "     ",0

            ; --- unit ---
            mov     rf, mnt_slot
            ldn     rf
            call    mnt_entry_addr          ; RF = &drive_bpb_table[slot]
            add16   rf, BPBBLK_DEV
            ldn     rf
            adi     '0'
            call    K_TYPE
            call    K_INMSG
            db      "     ",0

            ; --- partition start LBA ---
            mov     rf, mnt_slot
            ldn     rf
            call    mnt_entry_addr
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_get_lba             ; R7:R8.0 = LBA, R8.1 = 0

            ; fmt_size32 wants the 32-bit value in RD:R8 (RD = high
            ; word). Our LBA is 24-bit in R7:R8.0, so rebuild it:
            ;   high word RD = R8.0 (bits 23-16), zero-extended
            ;   low  word R8 = R7
            glo     r8
            plo     rd
            ldi     0
            phi     rd
            mov     r8, r7

            mov     rf, mnt_numbuf
            call    fmt_size32
            mov     rf, mnt_numbuf
            call    K_MSG
            call    K_INMSG
            db      13,10,0

            mov     rf, mnt_shown
            ldn     rf
            adi     1
            str     rf

mnt_list_next:
            mov     rf, mnt_i
            ldn     rf
            adi     1
            str     rf
            smi     DRIVE_LETTER_MAX + 1
            lbnf    mnt_list_loop           ; DF=0: still <= 'Z'

            ; --- summary. Also the only way to see how many slots
            ; exist, now that unmounted ones are not printed. ---
            mov     rf, mnt_shown
            ldn     rf
            lbz     mnt_list_none

            mov     rf, mnt_shown
            ldn     rf
            plo     rd
            ldi     0
            phi     rd                      ; RD = count
            mov     rf, mnt_numbuf          ; f_uintout writes at [RF] --
                                            ; point it at the buffer, not
                                            ; at mnt_shown itself
            call    f_uintout               ; ...advancing RF past the
            ldi     0                       ;    digits, and NOT
            str     rf                      ;    terminating them
            mov     rf, mnt_numbuf
            call    K_MSG
            call    K_INMSG
            db      " of ",0
            ldi     DRIVE_COUNT + '0'
            call    K_TYPE
            call    K_INMSG
            db      " drives mounted.",13,10,0
            ldi     0
            rtn

mnt_list_none:
            call    K_INMSG
            db      "No drives mounted.",13,10,0
            ldi     0
            rtn

;==================================================================
; Mount mode -- MOUNT <partition> <letter>
;==================================================================
mnt_do_mount:
            ; ---- parse the partition number ----
            ; 1..MBR_PART_COUNT selects an MBR primary partition.
            ; 0 means "there is no partition table -- the volume starts
            ; at sector 0", which is how a floppy is laid out.
            mov     rf, mnt_argbase
            ldn     rf
            call    mnt_argv_at
            lda     rf
            smi     '0'
            lbnf    mnt_bad_part            ; below '0'
            plo     r9                      ; R9.0 = the digit itself
            ldn     rf
            lbnz    mnt_bad_part            ; more than one character

            glo     r9
            smi     MBR_PART_COUNT+1
            lbdf    mnt_bad_part            ; an MBR has four primary
                                            ; entries; this bound is not
                                            ; DRIVE_COUNT and never was
                                            ; the same question

            mov     rf, mnt_part
            glo     r9
            str     rf                      ; mnt_part = 0..MBR_PART_COUNT

            ; ---- parse the drive letter (one past the partition) ----
            mov     rf, mnt_argbase
            ldn     rf
            adi     1
            call    mnt_argv_at
            lda     rf
            ani     $DF                     ; uppercase-fold. Safe across
                                            ; the whole A-Z range: the only
                                            ; bytes aliasing into $41-$5A
                                            ; under this mask are $41-$5A
                                            ; and $61-$7A themselves.
            plo     rb                      ; RB.0 = folded letter
            smi     DRIVE_LETTER_MIN
            lbnf    mnt_bad_drive           ; below 'A'
            glo     rb
            smi     DRIVE_LETTER_MAX+1
            lbdf    mnt_bad_drive           ; above 'Z'

            ; a trailing ':' is allowed but optional ("D" or "D:")
            lda     rf
            lbz     mnt_drive_ok
            xri     ':'
            lbnz    mnt_bad_drive
            ldn     rf
            lbnz    mnt_bad_drive           ; anything after the ':'
mnt_drive_ok:
            ; Remember the letter itself; the slot it will occupy is
            ; decided next.
            mov     rf, mnt_letter
            glo     rb
            str     rf

            ; ---- pick the slot ----
            ; If this letter is already mounted, reuse ITS slot: that is
            ; a remount, which is what "mount 3 e:" has always meant.
            ; Otherwise take the first free slot -- drive_letter[i] == 0.
            glo     rb
            call    drive_index_of
            lbnf    mnt_have_slot           ; DF=0: already mounted here,
                                            ; D = its slot -- reuse it

            ldi     0
            plo     rb                      ; RB.0 = candidate slot
mnt_free_scan:
            glo     rb
            call    drive_letter_of         ; D = that slot's letter
            lbz     mnt_free_found          ; 0 = free
            glo     rb
            adi     1
            plo     rb
            smi     DRIVE_COUNT
            lbnf    mnt_free_scan
            lbr     mnt_no_slots            ; every slot is taken

mnt_free_found:
            glo     rb                      ; D = the free slot

mnt_have_slot:
            plo     rb                      ; stash before the mov below
                                            ; clobbers D (gotcha #4)
            mov     rf, mnt_drive
            glo     rb
            str     rf                      ; mnt_drive = slot

            ; ---- refuse the shell's own drive (see header) ----
            call    K_GETSHELLDRIVE         ; D = shell_drive
            str     r2
            mov     rf, mnt_drive
            ldn     rf
            sm                              ; D = target - shell_drive
            lbz     mnt_is_shell

            ; ---- partition 0: no partition table at all ----
            mov     rf, mnt_part
            ldn     rf
            lbz     mnt_whole_device

            ; ---- read the MBR ----
            ldi     0
            plo     r7
            phi     r7
            plo     r8                      ; LBA 0
            mov     rf, mnt_unit
            ldn     rf
            phi     r8                      ; R8.1 = block device unit.
                                            ; K_SECREAD is a bare
                                            ; passthrough to f_ideread, so
                                            ; this reaches the BIOS
                                            ; verbatim -- no kernel call
                                            ; is needed to pick a device.
            mov     rf, mnt_sector
            call    K_SECREAD
            lbdf    mnt_mbr_err

            ; ---- validate the $AA55 signature ----
            ; This is what makes a nonexistent device fail cleanly
            ; rather than being mistaken for a valid partition table
            ; full of whatever bytes happened to be there.
            mov     rf, mnt_sector
            add16   rf, $01FE
            lda     rf
            xri     $55
            lbnz    mnt_no_mbr
            ldn     rf
            xri     $AA
            lbnz    mnt_no_mbr

            ; ---- locate this partition's table entry ----
            ; offset = PT_OFFSET + index*PT_ENTRY_LEN
            mov     rf, mnt_part
            ldn     rf
            smi     1                       ; number (1-4) -> entry index
            shl                             ; (0-3); partition 0 never
            shl                             ; reaches here
            shl
            shl                             ; D = index * 16
            adi     low PT_OFFSET
            plo     rd
            ldi     high PT_OFFSET
            phi     rd                      ; RD = entry offset (index 0-3
                                            ; keeps the low byte in
                                            ; $BE-$EE, never carrying)

            mov     rf, mnt_sector
            add16   rf, rd                  ; RF -> partition entry

            ; type byte at +4; zero means the entry is unused
            mov     rd, rf                  ; keep the entry base
            add16   rf, 4
            ldn     rf
            lbz     mnt_empty_part

            ; start LBA at +8, 4 bytes little-endian. We use 3; the
            ; 4th must be zero (see the header note on 24-bit LBAs).
            mov     rf, rd
            add16   rf, PT_LBA_OFF
            lda     rf
            plo     r7
            lda     rf
            phi     r7
            lda     rf
            plo     r8
            ldn     rf
            lbnz    mnt_too_far             ; bits 31-24 set: past 8GB
            ldi     0
            phi     r8                      ; R7:R8.0 = partition start LBA

            ; a start LBA of 0 is not a real partition
            glo     r8
            lbnz    mnt_have_start
            ghi     r7
            lbnz    mnt_have_start
            glo     r7
            lbz     mnt_empty_part
mnt_have_start:

            ; ---- stash it, and seed the BPB image with it ----
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_put_lba             ; part1_lba
            lbr     mnt_read_vbr

mnt_whole_device:
            ; No MBR, so no partition entry and no $AA55 check: the
            ; volume simply starts at sector 0. Worth knowing what that
            ; costs -- the signature check is also the portable "this
            ; unit does not exist" guard (see the header), so a
            ; whole-device mount of a missing device fails later and
            ; less clearly, at the VBR sanity checks below, rather than
            ; immediately. Those checks are why they are still there.
            ldi     0
            plo     r7
            phi     r7
            plo     r8
            phi     r8                      ; part1_lba = 0
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_put_lba

mnt_read_vbr:
            ; ---- read the volume's VBR (R7:R8 still hold its LBA) ----
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_get_lba             ; sets R8.1 = 0 ...
            mov     rf, mnt_unit
            ldn     rf
            phi     r8                      ; ... so override it after
            mov     rf, mnt_sector
            call    K_SECREAD
            lbdf    mnt_vbr_err

            ; ---- is this actually a FAT16 volume? ----
            ; The 8-byte type string at offset $36 is informational per
            ; the FAT spec -- the authoritative test is cluster count --
            ; but as a guard it earns its keep twice over:
            ;
            ;   * it rejects mounting a partition TABLE as a volume,
            ;     which "MOUNT 0" would otherwise do on a partitioned
            ;     device: an MBR's boot code passes the geometry checks
            ;     below by accident.
            ;
            ;   * it rejects a FAT12 floppy outright. This kernel reads
            ;     16-bit FAT entries unconditionally and checks the FAT
            ;     type NOWHERE else, so a FAT12 volume is not refused --
            ;     it is silently misread. An error beats that, and this
            ;     is the only place positioned to say so.
            ;
            ; The cost is that a genuinely-FAT16 volume whose formatter
            ; omitted the string would be refused. That is a loud,
            ; recoverable failure rather than a quiet destructive one,
            ; and every formatter in practical use writes it.
            mov     rf, mnt_sector
            add16   rf, $36
            mov     rd, mnt_fat16_sig
mnt_sig_loop:
            lda     rd                      ; D = expected char
            lbz     mnt_sig_ok              ; end of "FAT16": matched
            str     r2
            lda     rf                      ; D = actual char
            sm                              ; D = actual - expected
            lbnz    mnt_not_fat16
            lbr     mnt_sig_loop
mnt_sig_ok:

;------------------------------------------------------------------
; From here to mnt_commit is the port of boot/krnboot.asm's Phase 1
; steps 4-8. Keep the two in sync.
;------------------------------------------------------------------

            ; ---- bytes per sector must be 512: every LBA and buffer
            ; in this system assumes it ----
            mov     rf, mnt_sector
            add16   rf, $0B
            call    mnt_get_le16
            glo     rd
            lbnz    mnt_bad_vbr
            ghi     rd
            xri     2
            lbnz    mnt_bad_vbr

            ; ---- Step 4: sectors-per-cluster and its log2 ----
            mov     rf, mnt_sector
            add16   rf, BPB_SPC
            ldn     rf                      ; D = sectors_per_cluster
            plo     r9

            lbz     mnt_bad_vbr             ; spc of 0 is not a FAT16 VBR

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_SPC
            glo     r9
            str     rf

            ldi     0
            plo     rc
            glo     r9
mnt_spc_loop:
            shr
            lbdf    mnt_spc_done
            inc     rc
            lbr     mnt_spc_loop
mnt_spc_done:
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_SPC_SHIFT
            glo     rc
            str     rf

            ; ---- Step 5: fat_lba = part1_lba + reserved_sectors ----
            mov     rf, mnt_sector
            add16   rf, BPB_RSVD
            call    mnt_get_le16            ; RD = reserved_sector_count

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_get_lba

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8                      ; R7:R8.0 = fat_lba

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_FAT_LBA
            call    mnt_put_lba

            ; ---- Step 6: num_fats, spf, max_clust, root_lba ----
            mov     rf, mnt_sector
            add16   rf, BPB_NFAT
            ldn     rf
            plo     r9                      ; R9.0 = num_fats
            lbz     mnt_bad_vbr             ; zero FAT copies: not FAT16

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_NUM_FATS
            glo     r9
            str     rf

            mov     rf, mnt_sector
            add16   rf, BPB_SPF
            call    mnt_get_le16            ; RD = sectors_per_fat

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_SPF
            call    mnt_put16

            ; (max_clust is computed exactly in Step 7b, once data_lba
            ; is known -- see the note there)

            ; root_lba = fat_lba + num_fats * spf   (f_mul16: RF*RD -> RB)
            mov     rf, mnt_sector
            add16   rf, BPB_SPF
            call    mnt_get_le16            ; RD = spf. Re-read from the
                                            ; sector rather than relying on
                                            ; RD surviving the calls above:
                                            ; cheaper to reload than to
                                            ; reason about, and this file
                                            ; keeps no live state in
                                            ; registers across calls.
            mov     rf, rd                  ; RF = spf (f_mul16's first arg)
            mov     rd, mnt_sector
            add16   rd, BPB_NFAT
            ldn     rd
            plo     rd
            ldi     0
            phi     rd                      ; RD = num_fats, zero-extended
            call    f_mul16                 ; RB = num_fats * spf
            mov     rd, rb                  ; RD = total FAT sectors

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_FAT_LBA
            call    mnt_get_lba

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8                      ; R7:R8.0 = root_lba

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_ROOT_LBA
            call    mnt_put_lba

            ; ---- Step 7: root_ents, data_lba ----
            mov     rf, mnt_sector
            add16   rf, BPB_ROOTENT
            call    mnt_get_le16            ; RD = root_entry_count

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_ROOT_ENTS
            call    mnt_put16

            ; root_dir_sectors = root_ents / 16 (32 bytes per entry,
            ; 512 bytes per sector)
            mov     rf, mnt_sector
            add16   rf, BPB_ROOTENT
            call    mnt_get_le16
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                      ; RD = root_dir_sectors

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_ROOT_LBA
            call    mnt_get_lba

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8                      ; R7:R8.0 = data_lba

            mov     rf, mnt_bpb
            add16   rf, BPBBLK_DATA_LBA
            call    mnt_put_lba

            ; ---- Step 7b: max_clust = cluster count + 1 ----
            ; count = (total_sectors - (data_lba - part1_lba)) >> spc_shift
            ;
            ; BUG FIX (2026-09-11): this used to be the spf*256-1
            ; estimate, which overshoots real FAT16 volumes -- the FAT is
            ; sized generously -- and let fat_alloc hand out clusters
            ; past the end of the partition. Same fix as krnboot's own
            ; Step 7b; keep the two in sync.
            ;
            ; The count is also the authoritative FAT-type test the
            ; signature check above only approximates: fewer than 4085
            ; clusters is FAT12, 65525 or more is FAT32.
            mov     rf, mnt_sector
            add16   rf, $13
            call    mnt_get_le16            ; RD = 16-bit total sectors
            mov     ra, rd
            ldi     0
            phi     r9
            plo     r9                      ; R9:RA = total sectors
            glo     ra
            lbnz    mnt_have_total
            ghi     ra
            lbnz    mnt_have_total
            mov     rf, mnt_sector
            add16   rf, $20
            call    mnt_get_le16            ; low word (RF left at $21)
            mov     ra, rd
            inc     rf
            call    mnt_get_le16            ; high word
            mov     r9, rd                  ; R9:RA = 32-bit total sectors
mnt_have_total:
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_DATA_LBA
            call    mnt_get_lba             ; R7 = data_lba, low 16 bits
            mov     rd, r7
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_PART1_LBA
            call    mnt_get_lba             ; R7 = part1_lba, low 16 bits
            sub16   rd, r7                  ; RD = sectors before cluster 2
            glo     rd
            str     r2
            glo     ra
            sm
            plo     ra
            ghi     rd
            str     r2
            ghi     ra
            smb
            phi     ra
            glo     r9
            smbi    0
            plo     r9
            ghi     r9
            smbi    0
            phi     r9                      ; R9:RA = data-region sectors
                                            ; (wraps huge if the VBR is
                                            ; garbage -- rejected below)
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_SPC_SHIFT
            ldn     rf
            plo     rc
mnt_count_shift:
            glo     rc
            lbz     mnt_count_done
            ghi     r9
            shr
            phi     r9
            glo     r9
            shrc
            plo     r9
            ghi     ra
            shrc
            phi     ra
            glo     ra
            shrc
            plo     ra
            dec     rc
            lbr     mnt_count_shift
mnt_count_done:
            ghi     r9
            lbnz    mnt_bad_vbr
            glo     r9
            lbnz    mnt_bad_vbr
            glo     ra
            smi     $F5
            ghi     ra
            smbi    $FF
            lbdf    mnt_bad_vbr             ; count >= 65525: FAT32
            glo     ra
            smi     $F5
            ghi     ra
            smbi    $0F
            lbnf    mnt_not_fat16           ; count < 4085: FAT12
            inc     ra
            mov     rd, ra
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_MAX_CLUST
            call    mnt_put16

            ; ---- Step 8: bpb_dev = the unit this partition is on ----
            ; This is what makes the drive read and write on the right
            ; block device: _switch_drive copies it into the active BPB
            ; and _set_lba_dev (kernel/fat.asm) hands it to the BIOS in
            ; R8.1 on every access from then on.
            ;
            ; krnboot's own scan writes 0 here instead, because it only
            ; ever sees the device it was booted from. (It used to write
            ; fat_csec = $FFFF at this offset; that field left the copied
            ; block when bpb_dev was added, since _switch_drive always
            ; overwrote the copied value anyway.)
            mov     rf, mnt_bpb
            add16   rf, BPBBLK_DEV
            mov     rd, mnt_unit
            ldn     rd
            str     rf

;==================================================================
; Commit. Nothing above this point has modified any kernel state.
;==================================================================
mnt_commit:
            ; *** ORDERING: invalidate BEFORE overwriting the table ***
            mov     rf, mnt_drive
            ldn     rf
            call    K_DRIVE_INVALIDATE

            ; drive_bpb_table[i] = mnt_bpb  (BPBBLK_LEN bytes)
            mov     rf, mnt_drive
            ldn     rf
            call    mnt_entry_addr          ; RF = &drive_bpb_table[i]
            mov     rd, rf                  ; RD = destination
            mov     rf, mnt_bpb             ; RF = source
            ldi     BPBBLK_LEN
            plo     rc
mnt_copy_loop:
            lda     rf
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    mnt_copy_loop

            ; drive_cur_dir[i] = 0 -- a freshly mounted drive starts at
            ; its own root, not at whatever cluster the previous
            ; occupant of this letter was sitting in.
            call    mnt_base                ; R9 = drive_present's address
            mov     rf, mnt_drive
            ldn     rf
            shl                             ; D = i*2 (2 bytes per entry)
            plo     rd
            ldi     0
            phi     rd
            mov     rf, r9
            add16   rf, DRIVE_CUR_DIR_OFF
            add16   rf, rd                  ; RF = &drive_cur_dir[i]
            ldi     0
            str     rf
            inc     rf
            str     rf

            ; drive_letter[i] and drive_present[i] LAST, and together --
            ; they are the two halves of "this slot is live" and nothing
            ; may observe one without the other (see kernel_data.asm's
            ; note on the invariant). Until both are set the slot is
            ; still free as far as every other routine is concerned,
            ; which is what makes a half-written BPB harmless.
            mov     rf, mnt_drive
            ldn     rf
            call    mnt_letter_addr         ; RF = &drive_letter[slot]
            mov     rd, mnt_letter
            ldn     rd
            str     rf

            mov     rf, mnt_drive
            ldn     rf
            call    mnt_present_addr
            ldi     1
            str     rf

            ; ---- report ----
            call    K_INMSG
            db      "Mounted partition ",0
            mov     rf, mnt_part
            ldn     rf
            adi     '0'                     ; mnt_part is the number as
                                            ; typed (0 = whole device)
            call    K_TYPE
            call    K_INMSG
            db      " as ",0
            mov     rf, mnt_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      ":",13,10,0

            ldi     0
            rtn

;==================================================================
; Error exits
;==================================================================
mnt_bad_part:
            call    K_INMSG
            db      "Partition must be 0-4 (0 = whole device).",13,10,0
            ldi     1
            rtn

mnt_bad_drive:
            call    K_INMSG
            db      "Drive letter must be A-Z.",13,10,0
            ldi     1
            rtn

mnt_no_slots:
            call    K_INMSG
            db      "All drive slots are in use; unmount one first.",13,10,0
            ldi     1
            rtn

mnt_bad_unit:
            call    K_INMSG
            db      "Unit must be 0-7.",13,10,0
            ldi     1
            rtn

mnt_is_shell:
            call    K_INMSG
            db      "Cannot remount the drive the shell was loaded from.",13,10,0
            ldi     1
            rtn

mnt_mbr_err:
            call    K_INMSG
            db      "Cannot read the partition table.",13,10,0
            ldi     1
            rtn

mnt_no_mbr:
            call    K_INMSG
            db      "No valid partition table found.",13,10,0
            ldi     1
            rtn

mnt_empty_part:
            call    K_INMSG
            db      "That partition is empty.",13,10,0
            ldi     1
            rtn

mnt_too_far:
            call    K_INMSG
            db      "Partition starts beyond 8GB; not addressable.",13,10,0
            ldi     1
            rtn

mnt_vbr_err:
            call    K_INMSG
            db      "Cannot read the partition's boot sector.",13,10,0
            ldi     1
            rtn

mnt_bad_vbr:
            call    K_INMSG
            db      "That partition is not a FAT16 volume.",13,10,0
            ldi     1
            rtn

mnt_not_fat16:
            call    K_INMSG
            db      "Not a FAT16 volume (ELF-DOS cannot read FAT12).",13,10,0
            ldi     1
            rtn

;==================================================================
; Helpers
;
; All of these are leaf routines making no kernel/BIOS calls of their
; own, so their clobber lists are exactly what they touch.
;==================================================================

;------------------------------------------------------------------
; mnt_argv_at: fetch argv[D]
; Args:    D = index
; Returns: RF = argv[index]
; Modifies: RB, RD, RF, D
;------------------------------------------------------------------
mnt_argv_at:
            shl                             ; D = index*2
            plo     rd
            ldi     0
            phi     rd                      ; RD = index*2

            ; RB is the staging pointer, RF the destination -- never the
            ; same register for both, or the "lda rb / phi rf" pair would
            ; advance the pointer out from under its own second byte.
            mov     rb, mnt_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                      ; RF = argv table base
            add16   rf, rd                  ; RF = &argv[index]

            mov     rb, rf
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                      ; RF = argv[index]
            rtn

;------------------------------------------------------------------
; mnt_slot_of_letter: which slot, if any, is mounted under this letter.
;
; A thin wrapper over lib/drives.asm now that letters are real. Kept as
; its own name so the listing loop reads clearly, and because it was the
; single place the listing needed changing when letters stopped being
; 'C' + slot.
;
; Args:    D = letter (caller has already uppercase-folded it)
; Returns: DF = 0 and D = slot, if that letter names a mounted drive;
;          DF = 1 otherwise (D undefined)
; Modifies: R8, R9, RF, D
;------------------------------------------------------------------
mnt_slot_of_letter:
            lbr     drive_index_of      ; tail call -- its contract is
                                        ; exactly this one's

;------------------------------------------------------------------
; mnt_letter_addr: RF = &drive_letter[D]
; Args:    D = slot
; Modifies: R9, RD, RF, D
;------------------------------------------------------------------
mnt_letter_addr:
            plo     rd
            ldi     0
            phi     rd                      ; RD = slot, zero-extended
            call    mnt_base                ; (leaves RD alone)
            mov     rf, r9
            add16   rf, DRIVE_LETTER_OFF
            add16   rf, rd
            rtn

;------------------------------------------------------------------
; mnt_base: R9 = drive_present's real address (DRIVE_DATA_PTR's target)
; Modifies: R9, RF, D
;------------------------------------------------------------------
mnt_base:
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            rtn

;------------------------------------------------------------------
; mnt_present_addr: RF = &drive_present[D]
; Args:    D = drive index
; Modifies: R9, RD, RF, D
;------------------------------------------------------------------
mnt_present_addr:
            plo     rd
            ldi     0
            phi     rd                      ; RD = index, zero-extended
            call    mnt_base                ; (leaves RD alone)
            mov     rf, r9
            add16   rf, rd
            rtn

;------------------------------------------------------------------
; mnt_entry_addr: RF = &drive_bpb_table[D]
; Args:    D = drive index
; Modifies: R9, RB, RC, RD, RF, D
;------------------------------------------------------------------
mnt_entry_addr:
            plo     rd
            ldi     0
            phi     rd                      ; RD = index, zero-extended
            call    mnt_base                ; (leaves RD alone)

            ; offset = index * BPBBLK_LEN, by repeated addition (index
            ; is always 0..DRIVE_COUNT-1, so this is at most 3 adds --
            ; the same approach _switch_drive itself uses)
            ldi     0
            phi     rb
            plo     rb
            glo     rd
            lbz     mnt_ea_have
            plo     rc
mnt_ea_mul:
            add16   rb, BPBBLK_LEN
            dec     rc
            glo     rc
            lbnz    mnt_ea_mul
mnt_ea_have:
            mov     rf, r9
            add16   rf, DRIVE_BPB_TABLE_OFF
            add16   rf, rb
            rtn

;------------------------------------------------------------------
; mnt_get_lba: load 3 big-endian bytes at [RF] into R7:R8.0
; Returns: R7 = LBA bits 15-0, R8.0 = bits 23-16, R8.1 = 0
; Modifies: R7, R8, RF, D
;------------------------------------------------------------------
mnt_get_lba:
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            rtn

;------------------------------------------------------------------
; mnt_put_lba: store R7:R8.0 as 3 big-endian bytes at [RF]
; Modifies: RF, D
;------------------------------------------------------------------
mnt_put_lba:
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
; mnt_get_le16: load a little-endian word from [RF] (raw disk order)
; Returns: RD = value
; Modifies: RD, RF, D
;------------------------------------------------------------------
mnt_get_le16:
            lda     rf
            plo     rd
            ldn     rf
            phi     rd
            rtn

;------------------------------------------------------------------
; mnt_put16: store RD as 2 big-endian bytes at [RF] (the order every
; multi-byte field in the BPB block uses)
; Modifies: RF, D
;------------------------------------------------------------------
mnt_put16:
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;==================================================================
; Data
;==================================================================
mnt_argv:       dw      0           ; caller's argv table pointer
mnt_argc:       db      0
mnt_unit:       db      0           ; block device unit 0-7
mnt_argbase:    db      1           ; argv index of <partition>
mnt_part:       db      0           ; MBR entry index 0-3
mnt_drive:      db      0           ; target slot
mnt_letter:     db      0           ; the letter it answers to
mnt_i:          db      0           ; listing-mode loop: the LETTER
                                    ; being considered, 'A'..'Z'
mnt_slot:       db      0           ; slot that letter maps to
mnt_shown:      db      0           ; how many rows printed
mnt_fat16_sig:  db      "FAT16",0
mnt_numbuf:     ds      14          ; fmt_size32 destination
mnt_bpb:        ds      BPBBLK_LEN  ; assembled BPB image, committed
                                    ; to drive_bpb_table only at the end
mnt_sector:     ds      512         ; MBR / VBR scratch
