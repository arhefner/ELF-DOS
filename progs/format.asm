;
; format.asm - write a new, empty FAT16 filesystem onto a mounted drive
;
; FORMAT <drive>: [-s] [-q] [-v:label]
;
;   -s          surface scan: read every sector first, marking any that
;               fail as bad
;   -q          quick format, no scan -- the default, accepted so MS-DOS
;               habits (FORMAT D: /Q) still work. The last of -s/-q wins.
;   -v:label    set the volume label without asking (-v: = no label)
;
; Quick is the default, unlike MS-DOS: the scan is one K_SECREAD per
; sector, which on this machine is hours for a large partition, and
; flash media rarely report a read error for it to find anyway.
;
; Modelled on MS-DOS 6's FORMAT for a fixed disk:
;
;   1. If the drive already holds a filesystem with a volume label,
;      ask for that label and stop unless it is typed correctly -- the
;      same "are you sure it is THIS disk" check MS-DOS used.
;   2. Warn that every file on the drive will be lost, ask Y/N.
;   3. With -s, read every sector of the data area ("NN percent
;      completed.") and remember the clusters that fail; they are
;      marked bad ($FFF7) in the new FAT, as MS-DOS did.
;   4. Write both FAT copies, an empty root directory, and the boot
;      sector LAST -- until that final write the partition does not
;      look like a FAT volume to MOUNT, so an interrupted format never
;      leaves something that mounts with a half-written FAT.
;   5. Ask for a new volume label (unless -v was given), then bring the
;      drive live and print the MS-DOS style summary.
;
; The drive must already be MOUNTed. An unformatted partition can be:
; MOUNT gives it a letter but leaves drive_present at 0 (see
; progs/mount.asm's header), and this program sets drive_present once
; the new filesystem is on disk. Nothing here needs kernel support
; beyond K_SECREAD/K_SECWRITE and K_DRIVE_INVALIDATE; the drive tables
; are reached through DRIVE_DATA_PTR exactly as MOUNT does it.
;
; Size comes from the partition table entry whose start LBA matches
; the drive's (so the MBR is the authority, not an old boot sector),
; or, for a whole-device mount (start LBA 0), from the existing boot
; sector. FAT16 needs 4085-65524 clusters, which with the cluster
; sizes below means 4,150-8,387,744 sectors (about 2MB-4GB). Cluster
; size follows Microsoft's FAT16 table (2 sectors under 16MB, 4 to
; 128MB, 8 to 256MB, 16 to 512MB, 32 to 1GB, 64 to 2GB, 128 above),
; stepped down or up when the cluster count would fall outside that
; range. The FAT size formula is Microsoft's, plus a correction step
; (it undersizes the FAT by a sector at one sector per cluster).
; Every size in the range was checked in a Python model before this
; was written; the loop order here matches the model.
;
; Fixed layout: 1 reserved sector (the boot sector), 2 FATs, 512 root
; entries (32 sectors), media $F8. The MBR partition type byte is left
; alone -- MS-DOS FORMAT never touched it either (that was FDISK's job).
;
; Refused outright:
;   - the drive the shell was loaded from (it would strand the system)
;   - a partition also mounted under another letter (that letter would
;     keep the old geometry and corrupt the new filesystem)
;   - a partition overlapping the kernel image at LBA 1 on its unit
;   - a partition reaching past sector 2^24 (ELF-DOS's LBAs are 24-bit)
;
; Exit codes: 0 formatted, 1 error, 5 the user answered N (MS-DOS's
; own code for that).
;
; Every value that must outlive a kernel call lives in memory. K_SECREAD
; and K_SECWRITE clobber R7/R8 at least, and nothing else is trusted.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

            extrn   drive_index_of
            extrn   fmt_size32
            extrn   read_line_ex

KRNBOOT_SECTORS:  equ   5           ; must match boot/mbr.asm, sys/sys.c,
                                    ; progs/sys.asm and progs/ksave.asm
FMT_ROOT_SECS:    equ   32          ; 512 entries * 32 bytes / 512
FMT_MIN_CLUST:    equ   4085        ; fewer is FAT12 by definition
FMT_MAX_CLUST:    equ   65525       ; this many or more is FAT32
FMT_INBUF_MAX:    equ   32          ; typed-answer buffer length
BITMAP_LEN:       equ   8192        ; one bit per possible cluster
VBR_TEMPLATE_LEN: equ   $42         ; bytes of vbr_template ($00-$41)

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
            mov     rf, f_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf
            mov     rf, f_argc
            glo     rc
            str     rf

            ; ---- parse arguments: one drive, any number of options ----
            mov     rf, f_argi
            ldi     1
            str     rf
arg_loop:
            mov     rf, f_argi
            ldn     rf
            str     r2
            mov     rf, f_argc
            ldn     rf
            sm                              ; D = argc - i
            lbz     arg_done
            lbnf    arg_done

            mov     rf, f_argi
            ldn     rf
            call    argv_at                 ; RF = argv[i]
            ldn     rf
            xri     '-'
            lbz     arg_option

            ; --- the drive: "X" or "X:" ---
            mov     rd, f_letter
            ldn     rd
            lbnz    usage                   ; a second drive
            lda     rf
            ani     $DF                     ; uppercase-fold (A-Z safe)
            plo     rb
            smi     DRIVE_LETTER_MIN
            lbnf    usage
            glo     rb
            smi     DRIVE_LETTER_MAX+1
            lbdf    usage
            lda     rf
            lbz     arg_letter_ok
            xri     ':'
            lbnz    usage
            ldn     rf
            lbnz    usage
arg_letter_ok:
            mov     rf, f_letter
            glo     rb
            str     rf
            lbr     arg_next

arg_option:
            inc     rf
            lda     rf
            ani     $DF
            plo     rb
            xri     'Q'
            lbz     arg_q
            glo     rb
            xri     'S'
            lbz     arg_s
            glo     rb
            xri     'V'
            lbnz    usage
            ; -v alone means "ask" (the default); -v:<text> sets it
            ldn     rf
            lbz     arg_next
            xri     ':'
            lbnz    usage
            inc     rf                      ; RF = label text (may be "")
            call    lbl_norm                ; -> f_lbl_tmp, D = nonblank
            lbdf    arg_bad_label
            plo     r9                      ; keep D past the mov/ldi
            mov     rf, f_vgiven
            ldi     1
            str     rf
            glo     r9
            call    take_label              ; f_newlabel = f_lbl_tmp
            lbr     arg_next
arg_s:
            ldn     rf
            lbnz    usage
            mov     rf, f_quick
            ldi     0
            str     rf
            lbr     arg_next
arg_q:
            ldn     rf
            lbnz    usage
            mov     rf, f_quick
            ldi     1
            str     rf

arg_next:
            mov     rf, f_argi
            ldn     rf
            adi     1
            str     rf
            lbr     arg_loop

arg_bad_label:
            call    print_label_error
            ldi     1
            rtn

arg_done:
            mov     rf, f_letter
            ldn     rf
            lbz     usage

            ; ---- the letter must name a mounted slot ----
            call    drive_index_of
            lbdf    bad_drive
            plo     rc                      ; stash across the mov
            mov     rf, f_slot
            glo     rc
            str     rf

            ; ---- never the shell's own drive ----
            call    K_GETSHELLDRIVE
            str     r2
            mov     rf, f_slot
            ldn     rf
            sm
            lbz     is_shell

            ; ---- snapshot this slot's table entry ----
            mov     rf, f_slot
            ldn     rf
            call    entry_addr              ; RF = &drive_bpb_table[slot]
            mov     rd, f_oldbpb
            ldi     BPBBLK_LEN
            plo     rc
snap_loop:
            lda     rf
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    snap_loop

            mov     rf, f_slot
            ldn     rf
            call    present_addr
            ldn     rf
            plo     rc
            mov     rf, f_was_present
            glo     rc
            str     rf

            mov     rf, f_oldbpb+BPBBLK_DEV
            ldn     rf
            plo     rc
            mov     rf, f_unit
            glo     rc
            str     rf

            mov     rf, f_start             ; f_start = 0:part1_lba
            ldi     0
            str     rf
            inc     rf
            mov     rd, f_oldbpb+BPBBLK_PART1_LBA
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf

            ; ---- no other letter may name the same partition ----
            call    alias_check
            lbdf    exit_quiet

            ; ---- how big is it? ----
            mov     rf, f_start
            call    m32_is_zero
            lbz     size_whole_device
            call    size_from_mbr
            lbr     size_have
size_whole_device:
            call    size_from_vbr
size_have:
            lbdf    exit_quiet              ; the message is already out

            ; ---- size limits ----
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, c_min_total
            call    m32_sub
            lbnf    too_small               ; borrow: total < 4150
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, c_max_total1
            call    m32_sub
            lbdf    too_large               ; total >= 8387745

            ; ---- last LBA (start + total - 1) must stay below 2^24 ----
            mov     rf, f_tmp
            mov     rd, f_start
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_add
            mov     rf, f_tmp
            mov     rd, c_one
            call    m32_sub
            mov     rf, f_tmp
            ldn     rf
            lbnz    too_far

            ; ---- a partition must not overlap the kernel image ----
            mov     rf, f_start
            call    m32_is_zero
            lbz     kernel_ok               ; whole device: no kernel
            call    kernel_check
            lbdf    exit_quiet
kernel_ok:

            ; ---- FAT16 layout ----
            call    geometry
            lbdf    no_layout

            ; ---- current volume label, if there is one ----
            mov     rf, f_was_present
            ldn     rf
            lbz     no_old_label
            call    read_old_label
            mov     rf, f_hascur
            ldn     rf
            lbz     no_old_label

            call    K_INMSG
            db      13,10,"Enter current volume label for drive ",0
            call    print_letter
            call    K_INMSG
            db      ": ",0
            call    read_answer
            lbdf    bad_volid               ; EOF: cannot confirm
            mov     rf, f_lbl_strict        ; any characters: an existing
            ldi     0                       ; label may hold ones FORMAT
            str     rf                      ; would not write itself
            mov     rf, f_inbuf
            call    lbl_norm
            lbdf    bad_volid               ; over 11 characters: mismatch
            mov     rf, f_lbl_strict
            ldi     1
            str     rf
            ; compare f_lbl_tmp with the stored label, letters folded
            mov     rf, f_lbl_tmp
            mov     rd, f_curlabel
            ldi     11
            plo     rc
volid_cmp:
            ldn     rd
            call    fold_upper
            str     r2
            ldn     rf
            sm
            lbnz    bad_volid
            inc     rf
            inc     rd
            dec     rc
            glo     rc
            lbnz    volid_cmp
no_old_label:

            ; ---- a full format needs room for the bad-cluster bitmap ----
            mov     rf, f_quick
            ldn     rf
            lbnz    mem_ok
            mov     rf, LOADER_ARGS         ; mem_top - mem_base
            lda     rf
            phi     rd
            lda     rf
            plo     rd                      ; RD = mem_base
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                      ; R9 = mem_top
            glo     rd
            str     r2
            glo     r9
            sm
            ghi     rd
            str     r2
            ghi     r9
            smb                             ; D = high byte of the free space
            lbnf    no_memory               ; mem_top below mem_base
            smi     high BITMAP_LEN
            lbnf    no_memory
mem_ok:

            ; ---- the warning ----
            call    K_INMSG
            db      13,10,"WARNING, ALL DATA ON NON-REMOVABLE DISK",13,10
            db      "DRIVE ",0
            call    print_letter
            call    K_INMSG
            db      ": WILL BE LOST!",13,10,0
ask_again:
            call    K_INMSG
            db      "Proceed with Format (Y/N)?",0
            call    read_answer
            lbdf    declined                ; EOF counts as N
            mov     rf, f_inbuf
            call    yes_no                  ; D = 'Y', 'N', or 0
            lbz     ask_again
            xri     'N'
            lbz     declined

            ; ---- date, time and serial number ----
            call    get_time

            ; ---- "Formatting N bytes" ----
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_copy
            mov     rf, f_tmp
            ldi     9
            call    m32_shln                ; bytes = sectors * 512
            call    K_INMSG
            db      13,10,"Formatting ",0
            mov     rf, f_tmp
            call    print32
            call    K_INMSG
            db      " bytes",13,10,0

            ; ---- surface scan (read-only, before anything is written) ----
            mov     rf, f_quick
            ldn     rf
            lbnz    scan_done
            call    verify_scan
scan_done:
            ; every cluster unreadable: the device is not really there
            mov     rf, f_bad
            lda     rf
            str     r2
            mov     rd, f_cl
            lda     rd
            xor
            lbnz    not_all_bad
            ldn     rf
            str     r2
            ldn     rd
            xor
            lbz     all_bad
not_all_bad:

            ; ==== from here on the disk is being changed ====
            ; Drop anything cached for the drive (flushing it into the
            ; OLD filesystem, which is harmless), then take the slot out
            ; of service until the new filesystem is complete. Its
            ; letter stays, exactly like a MOUNTed unformatted partition.
            mov     rf, f_slot
            ldn     rf
            call    K_DRIVE_INVALIDATE
            mov     rf, f_slot
            ldn     rf
            call    present_addr
            ldi     0
            str     rf

            call    write_fats
            lbdf    write_error
            call    write_root
            lbdf    write_error
            call    build_vbr
            call    write_vbr
            lbdf    write_error

            call    K_INMSG
            db      "Format complete.",13,10,0

            ; ---- volume label ----
            mov     rf, f_vgiven
            ldn     rf
            lbnz    label_known
label_ask:
            call    K_INMSG
            db      13,10,"Volume label (11 characters, ENTER for none)? ",0
            call    read_answer
            lbdf    label_known             ; EOF: no label
            mov     rf, f_inbuf
            call    lbl_norm
            lbnf    label_typed
            call    print_label_error
            lbr     label_ask
label_typed:
            call    take_label
label_known:
            mov     rf, f_newlabel_set
            ldn     rf
            lbz     label_done
            call    build_vbr               ; now with the label in it
            call    write_vbr
            lbdf    write_error
            call    write_label_entry
            lbdf    write_error
label_done:

            ; ---- bring the drive live ----
            call    commit

            ; ---- summary ----
            call    summary
            ldi     0
            rtn

;==================================================================
; Error exits
;==================================================================
exit_quiet:
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: FORMAT <drive>: [-s] [-v:label]",13,10
            db      "  -s        surface scan: read every sector first (slow)",13,10
            db      "  -v:label  volume label (-v: for none)",13,10,0
            ldi     1
            rtn

bad_drive:
            call    K_INMSG
            db      "Invalid drive specification (MOUNT it first).",13,10,0
            ldi     1
            rtn

is_shell:
            call    K_INMSG
            db      "Cannot format the drive the shell was loaded from.",13,10,0
            ldi     1
            rtn

too_small:
            call    K_INMSG
            db      "Drive is too small for FAT16 (minimum 4,150 sectors).",13,10,0
            ldi     1
            rtn

too_large:
            call    K_INMSG
            db      "Drive is too large for FAT16 (maximum 8,387,744 sectors).",13,10,0
            ldi     1
            rtn

too_far:
            call    K_INMSG
            db      "Partition reaches past the 8GB addressing limit.",13,10,0
            ldi     1
            rtn

no_layout:
            call    K_INMSG
            db      "Cannot fit a FAT16 layout to this drive.",13,10,0
            ldi     1
            rtn

bad_volid:
            call    K_INMSG
            db      13,10,"Invalid Volume ID",13,10
            db      "Format terminated.",13,10,0
            ldi     1
            rtn

declined:
            call    K_INMSG
            db      "Format terminated.",13,10,0
            ldi     5
            rtn

all_bad:
            call    K_INMSG
            db      "Every cluster failed to read; nothing was written.",13,10
            db      "Format terminated.",13,10,0
            ldi     1
            rtn

no_memory:
            call    K_INMSG
            db      "Not enough memory for a surface scan; omit -s.",13,10,0
            ldi     1
            rtn

write_error:
            call    K_INMSG
            db      "Error writing to drive ",0
            call    print_letter
            call    K_INMSG
            db      ":. Format failed; the drive is left unformatted.",13,10,0
            ldi     1
            rtn

read_error:
            call    K_INMSG
            db      "Error reading drive ",0
            call    print_letter
            call    K_INMSG
            db      ":. Nothing was written.",13,10,0
            ldi     1
            rtn

;==================================================================
; alias_check: refuse if another mounted letter names the same
; partition (same unit, same start LBA). If that other letter is the
; shell's, report it as the shell drive -- formatting it would be
; formatting the shell's own partition. DF=1 (message printed) if one
; does, DF=0 if not.
;==================================================================
alias_check:
            mov     rf, f_j
            ldi     0
            str     rf
ac_loop:
            mov     rf, f_j
            ldn     rf
            str     r2
            mov     rf, f_slot
            ldn     rf
            sm
            lbz     ac_next                 ; ourselves
            mov     rf, f_j
            ldn     rf
            call    letter_addr
            ldn     rf
            lbz     ac_next                 ; free slot
            mov     rf, f_j
            ldn     rf
            call    entry_addr              ; RF = &drive_bpb_table[j]
            ; compare PART1_LBA (3 bytes at offset 0) and DEV
            mov     rd, f_oldbpb
            ldi     3
            plo     rc
ac_cmp:
            lda     rd
            str     r2
            lda     rf
            sm
            lbnz    ac_next
            dec     rc
            glo     rc
            lbnz    ac_cmp
            add16   rf, BPBBLK_DEV - 3
            ldn     rf
            str     r2
            mov     rf, f_unit
            ldn     rf
            sm
            lbnz    ac_next

            ; same partition
            call    K_GETSHELLDRIVE
            str     r2
            mov     rf, f_j
            ldn     rf
            sm
            lbz     ac_shell
            call    K_INMSG
            db      "That partition is also mounted as ",0
            mov     rf, f_j
            ldn     rf
            call    letter_addr
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      ": -- UMOUNT it first.",13,10,0
            lbr     nested_fail
ac_shell:
            call    K_INMSG
            db      "That partition holds the shell (as ",0
            mov     rf, f_j
            ldn     rf
            call    letter_addr
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      ":); it cannot be formatted.",13,10,0
            lbr     nested_fail

ac_next:
            mov     rf, f_j
            ldn     rf
            adi     1
            str     rf
            smi     DRIVE_COUNT
            lbnf    ac_loop
            clc
            rtn

;------------------------------------------------------------------
; nested_fail: the error return shared by alias_check, size_from_mbr,
; size_from_vbr and kernel_check, each of which has already printed
; its message. The main line tests DF after each call and exits.
;
; Deliberately NOT a jump straight back to the kernel by popping this
; level's return address off the stack: that depends on how SCRT lays
; out the saved R6, and the two SCRTs this program meets disagree --
; the mBIOS pushes the low byte first, Run/02's emulated one the high
; byte first. A version that did it worked on neither consistently.
;------------------------------------------------------------------
nested_fail:
            stc
            rtn

;==================================================================
; size_from_mbr: find the partition table entry starting at f_start
; on f_unit and put its sector count in f_total. DF=1 on error, with
; the message printed.
;==================================================================
size_from_mbr:
            mov     rf, f_lba
            call    m32_zero
            call    rd_sector
            lbdf    sfm_read_err
            mov     rf, sec_buf+510
            lda     rf
            xri     $55
            lbnz    sfm_none
            ldn     rf
            xri     $AA
            lbnz    sfm_none

            mov     rf, f_j
            ldi     0
            str     rf
sfm_loop:
            ; RF = entry j = sec_buf + $1BE + j*16
            mov     rf, f_j
            ldn     rf
            shl
            shl
            shl
            shl
            plo     rd
            ldi     0
            phi     rd
            mov     rf, sec_buf+$1BE
            add16   rf, rd
            mov     rd, rf                  ; RD = entry base
            add16   rf, 4
            ldn     rf
            lbz     sfm_next                ; unused entry
            ; start LBA at +8, little-endian; compare against f_start
            mov     rf, rd
            add16   rf, 8
            ldn     rf                      ; LSB
            str     r2
            mov     rd, f_start+3
            ldn     rd
            sm
            lbnz    sfm_next_rf
            inc     rf
            ldn     rf
            str     r2
            dec     rd
            ldn     rd
            sm
            lbnz    sfm_next_rf
            inc     rf
            ldn     rf
            str     r2
            dec     rd
            ldn     rd
            sm
            lbnz    sfm_next_rf
            inc     rf
            ldn     rf
            lbnz    sfm_next_rf             ; top byte must be 0
            ; match: sector count at +12 (RF is at +11)
            inc     rf
            mov     rd, f_total+3
            lda     rf
            str     rd
            dec     rd
            lda     rf
            str     rd
            dec     rd
            lda     rf
            str     rd
            dec     rd
            ldn     rf
            str     rd
            clc
            rtn
sfm_next_rf:
sfm_next:
            mov     rf, f_j
            ldn     rf
            adi     1
            str     rf
            smi     4
            lbnf    sfm_loop
sfm_none:
            call    K_INMSG
            db      "Cannot find this partition in the partition table.",13,10,0
            lbr     nested_fail
sfm_read_err:
            call    K_INMSG
            db      "Cannot read the partition table.",13,10,0
            lbr     nested_fail

;==================================================================
; size_from_vbr: a whole-device mount has no partition table, so the
; size can only come from the existing boot sector. DF=1 on error,
; with the message printed.
;==================================================================
size_from_vbr:
            mov     rf, f_lba
            call    m32_zero
            call    rd_sector
            lbdf    sfv_read_err
            mov     rf, sec_buf
            ldn     rf
            xri     $EB
            lbz     sfv_jump_ok
            ldn     rf
            xri     $E9
            lbnz    sfv_bad
sfv_jump_ok:
            mov     rf, sec_buf+510
            lda     rf
            xri     $55
            lbnz    sfv_bad
            ldn     rf
            xri     $AA
            lbnz    sfv_bad
            mov     rf, sec_buf+$0B
            lda     rf
            lbnz    sfv_bad
            ldn     rf
            xri     2
            lbnz    sfv_bad
            ; 16-bit total at $13, else 32-bit at $20
            mov     rf, f_total
            call    m32_zero
            mov     rf, sec_buf+$13
            lda     rf
            plo     rd
            ldn     rf
            phi     rd
            glo     rd
            lbnz    sfv_16
            ghi     rd
            lbnz    sfv_16
            mov     rf, sec_buf+$20
            mov     rd, f_total+3
            lda     rf
            str     rd
            dec     rd
            lda     rf
            str     rd
            dec     rd
            lda     rf
            str     rd
            dec     rd
            ldn     rf
            str     rd
            clc
            rtn
sfv_16:
            mov     rf, f_total
            call    m32_set16
            clc
            rtn
sfv_bad:
            call    K_INMSG
            db      "No partition table and no valid boot sector: the size is unknown.",13,10,0
            lbr     nested_fail
sfv_read_err:
            call    K_INMSG
            db      "Cannot read the device.",13,10,0
            lbr     nested_fail

;==================================================================
; kernel_check: if LBA 1 of the unit carries a kernel image ('KRN',
; see progs/ksave.asm for the header), the partition must start after
; it. DF=1 (message printed) on overlap.
;==================================================================
kernel_check:
            mov     rf, f_lba
            mov     rd, c_one
            call    m32_copy
            call    rd_sector
            lbdf    kc_done                 ; unreadable: no kernel there
            mov     rf, sec_buf
            lda     rf
            xri     'K'
            lbnz    kc_done
            lda     rf
            xri     'R'
            lbnz    kc_done
            ldn     rf
            xri     'N'
            lbnz    kc_done
            ; total = KRNBOOT_SECTORS + vol (offset 4) + nv (offset 9)
            mov     rf, sec_buf+4
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, sec_buf+9
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   r9, rd
            add16   r9, KRNBOOT_SECTORS     ; image = LBA 1..R9
            ; overlap unless start > R9. start is 24-bit; if its top
            ; byte is set it is far past any kernel.
            mov     rf, f_start+1
            ldn     rf
            lbnz    kc_done
            mov     rf, f_start+2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                      ; RD = start (low 16)
            glo     rd
            str     r2
            glo     r9
            sm
            ghi     rd
            str     r2
            ghi     r9
            smb                             ; R9 - start: no borrow means
            lbnf    kc_done                 ; start <= R9, an overlap
            call    K_INMSG
            db      "That partition overlaps the kernel image; not formatted.",13,10,0
            lbr     nested_fail
kc_done:
            clc
            rtn

;==================================================================
; geometry: choose sectors per cluster and FAT size for f_total.
; Returns DF=0 with f_spc, f_shift, f_fsz, f_cl, f_maxcl, f_fatlba,
; f_rootlba and f_datalba set, or DF=1 if no FAT16 layout fits.
; Mirrors geom_asm.py (see the header).
;==================================================================
geometry:
            ; --- starting cluster size from Microsoft's table ---
            mov     rf, f_total+1
            lda     rf                      ; bits 23-16
            lbnz    geo_big
            lda     rf
            plo     rd
            ldn     rf                      ; D = bits 7-0
            smi     $A8
            glo     rd
            smbi    $7F                     ; total - 32680
            lbdf    geo_big
            ldi     2
            lbr     geo_have_spc
geo_big:
            mov     rf, f_total+1
            ldn     rf
            shr
            shr                             ; D = total >> 18 (0-31)
            plo     r9
            ldi     4
            plo     r7
geo_tbl:
            glo     r9
            lbz     geo_tbl_done
            shr
            plo     r9
            glo     r7
            shl
            plo     r7
            lbr     geo_tbl
geo_tbl_done:
            glo     r7
geo_have_spc:
            plo     r7
            mov     rf, f_spc
            glo     r7
            str     rf
            mov     rf, f_giter
            ldi     8
            str     rf

geo_loop:
            ; --- shift = log2(spc) ---
            mov     rf, f_spc
            ldn     rf
            plo     r9
            ldi     0
            plo     r7
geo_sh:
            glo     r9
            shr
            plo     r9
            lbdf    geo_sh_done
            inc     r7
            lbr     geo_sh
geo_sh_done:
            mov     rf, f_shift
            glo     r7
            str     rf

            ; --- v2 = 256*spc + 2 ---
            mov     rf, f_spc
            ldn     rf
            phi     rd
            ldi     2
            plo     rd
            mov     rf, f_v2
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            ; --- fsz = (total - 33 + v2 - 1) / v2 ---
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, c_33
            call    m32_sub
            mov     rf, f_v2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd                      ; v2 - 1
            mov     rf, f_k
            call    m32_set16
            mov     rf, f_tmp
            mov     rd, f_k
            call    m32_add
            mov     rf, f_v2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_tmp
            call    m32_div16
            mov     rf, f_tmp+2
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_fsz
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

geo_fix:
            ; --- cl = (total - 33 - 2*fsz) >> shift ---
            mov     rf, f_fsz
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            add16   rd, 33
            mov     rf, f_k
            call    m32_set16
            mov     rf, f_tmp
            mov     rd, f_total
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, f_k
            call    m32_sub
            mov     rf, f_shift
            ldn     rf
            plo     rc
geo_cl_sh:
            glo     rc
            lbz     geo_cl_done
            mov     rf, f_tmp
            call    m32_shr1
            dec     rc
            lbr     geo_cl_sh
geo_cl_done:
            mov     rf, f_tmp
            lda     rf
            lbnz    geo_too_many
            lda     rf
            lbnz    geo_too_many
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                      ; RD = cl
            mov     rf, f_cl
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            ; cl >= 65525?
            glo     rd
            smi     low FMT_MAX_CLUST
            ghi     rd
            smbi    high FMT_MAX_CLUST
            lbdf    geo_too_many

            ; --- the FAT must hold cl+2 entries: cl+2 <= fsz*256 ---
            mov     rf, f_fsz
            ldn     rf
            lbnz    geo_fat_ok              ; fsz >= 256: always enough
            add16   rd, 2                   ; RD = cl + 2
            mov     rf, f_fsz+1
            glo     rd
            str     r2
            ldi     0
            sm                              ; (fsz<<8).lo - RD.lo
            ghi     rd
            str     r2
            ldn     rf
            smb                             ; fsz - RD.hi - borrow
            lbdf    geo_fat_ok              ; no borrow: fsz*256 >= cl+2
            mov     rf, f_fsz               ; fsz++
            call    inc16m
            lbr     geo_fix

geo_fat_ok:
            ; cl < 4085?
            mov     rf, f_cl
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            glo     rd
            smi     low FMT_MIN_CLUST
            ghi     rd
            smbi    high FMT_MIN_CLUST
            lbnf    geo_too_few

            ; --- success: derived values ---
            inc     rd
            mov     rf, f_maxcl
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, f_fatlba            ; fat_lba = start + 1
            mov     rd, f_start
            call    m32_copy
            mov     rf, f_fatlba
            mov     rd, c_one
            call    m32_add

            mov     rf, f_fsz               ; root_lba = fat_lba + 2*fsz
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            mov     rf, f_k
            call    m32_set16
            mov     rf, f_rootlba
            mov     rd, f_fatlba
            call    m32_copy
            mov     rf, f_rootlba
            mov     rd, f_k
            call    m32_add

            mov     rf, f_datalba           ; data_lba = root_lba + 32
            mov     rd, f_rootlba
            call    m32_copy
            mov     rf, f_datalba
            mov     rd, c_32
            call    m32_add
            clc
            rtn

geo_too_many:
            mov     rf, f_spc
            ldn     rf
            xri     128
            lbz     geo_fail
            ldn     rf
            shl
            str     rf
            lbr     geo_retry
geo_too_few:
            mov     rf, f_spc
            ldn     rf
            xri     1
            lbz     geo_fail
            ldn     rf
            shr
            str     rf
geo_retry:
            mov     rf, f_giter
            ldn     rf
            smi     1
            str     rf
            lbnz    geo_loop
geo_fail:
            stc
            rtn

;==================================================================
; read_old_label: look for a volume-label entry in the old root
; directory (geometry from f_oldbpb). Sets f_hascur and f_curlabel.
; An unreadable sector just ends the search.
;==================================================================
read_old_label:
            mov     rf, f_hascur
            ldi     0
            str     rf
            mov     rf, f_lba
            ldi     0
            str     rf
            inc     rf
            mov     rd, f_oldbpb+BPBBLK_ROOT_LBA
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            mov     rf, f_oldbpb+BPBBLK_ROOT_ENTS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                      ; RD = root sectors
            mov     rf, f_cnt
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
rol_sector:
            mov     rf, f_cnt
            lda     rf
            str     r2
            ldn     rf
            or
            lbz     rol_done
            call    rd_sector
            lbdf    rol_done
            mov     rb, sec_buf
            ldi     16
            plo     rc
rol_entry:
            ldn     rb
            lbz     rol_done                ; end of directory
            xri     $E5
            lbz     rol_next                ; deleted
            mov     rf, rb
            add16   rf, 11
            ldn     rf                      ; attribute byte
            ani     $0F
            xri     $0F
            lbz     rol_next                ; long-name piece
            ldn     rf
            ani     $08
            lbz     rol_next
            ; a label: copy its 11 bytes
            mov     rd, f_curlabel
            ldi     11
            plo     rc
rol_copy:
            lda     rb
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    rol_copy
            mov     rf, f_hascur
            ldi     1
            str     rf
            rtn
rol_next:
            add16   rb, 32
            dec     rc
            glo     rc
            lbnz    rol_entry
            mov     rf, f_lba
            call    m32_inc
            mov     rf, f_cnt
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd
            dec     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            lbr     rol_sector
rol_done:
            rtn

;==================================================================
; verify_scan: read every sector of every cluster, 2..max_clust,
; recording the clusters that fail in f_bitmap and f_bad. Prints the
; MS-DOS percentage counter.
;==================================================================
verify_scan:
            ; clear the bitmap (at mem_base, see the data section)
            mov     rb, LOADER_ARGS
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            mov     rc, BITMAP_LEN
vs_clear:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    vs_clear
            ghi     rc
            lbnz    vs_clear

            ; step = cl / 100 (at least 40, as cl >= 4085)
            mov     rf, f_cl
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            ldi     0
            plo     r9
            phi     r9
vs_div:
            glo     rd
            smi     100
            plo     r7
            ghi     rd
            smbi    0
            lbnf    vs_div_done
            phi     rd
            glo     r7
            plo     rd
            inc     r9
            lbr     vs_div
vs_div_done:
            mov     rf, f_step
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, f_sub
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf
            mov     rf, f_pct
            ldi     0
            str     rf
            call    print_pct

            mov     rf, f_lba
            mov     rd, f_datalba
            call    m32_copy
            mov     rf, f_vc
            ldi     0
            str     rf
            inc     rf
            ldi     2
            str     rf
            mov     rf, f_cl
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_vleft
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

vs_cluster:
            mov     rf, f_cbad
            ldi     0
            str     rf
            mov     rf, f_spc
            ldn     rf
            plo     rc
            mov     rf, f_scnt
            glo     rc
            str     rf
vs_sector:
            call    rd_sector
            lbnf    vs_ok
            mov     rf, f_cbad
            ldi     1
            str     rf
vs_ok:
            mov     rf, f_lba
            call    m32_inc
            mov     rf, f_scnt
            ldn     rf
            smi     1
            str     rf
            lbnz    vs_sector

            mov     rf, f_cbad
            ldn     rf
            lbz     vs_cl_ok
            call    mark_bad
vs_cl_ok:
            mov     rf, f_vc
            call    inc16m
            ; progress
            mov     rf, f_sub
            call    dec16m                  ; D = 0 when it reaches 0
            lbnz    vs_no_tick
            mov     rf, f_step
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_sub
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, f_pct
            ldn     rf
            adi     1
            str     rf
            smi     100
            lbdf    vs_no_tick              ; hold at 99 until the end
            call    print_pct
vs_no_tick:
            mov     rf, f_vleft
            call    dec16m
            lbnz    vs_cluster

            mov     rf, f_pct
            ldi     100
            str     rf
            call    print_pct
            call    K_INMSG
            db      13,10,0
            rtn

;------------------------------------------------------------------
; mark_bad: set cluster f_vc's bit in f_bitmap and count it in f_bad
;------------------------------------------------------------------
mark_bad:
            mov     rf, f_vc
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            glo     rd
            ani     7
            plo     r9                      ; bit number
            shr16   rd
            shr16   rd
            shr16   rd                      ; RD = byte index
            mov     rb, LOADER_ARGS         ; RF = the bitmap (mem_base)
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            add16   rf, rd
            ldi     1
            plo     r7
mb_mask:
            glo     r9
            lbz     mb_set
            glo     r7
            shl
            plo     r7
            dec     r9
            lbr     mb_mask
mb_set:
            glo     r7
            str     r2
            ldn     rf
            or
            str     rf
            mov     rf, f_bad
            lbr     inc16m                  ; tail call

;------------------------------------------------------------------
; print_pct: CR, then f_pct right-justified in 3 columns, then
; " percent completed."
;------------------------------------------------------------------
print_pct:
            mov     rf, f_pct
            ldn     rf
            plo     r9                      ; R9.0 = value
            ldi     0
            plo     r7                      ; R7.0 = hundreds
            phi     r7                      ; R7.1 = tens
pp_h:
            glo     r9
            smi     100
            lbnf    pp_t
            plo     r9
            inc     r7
            lbr     pp_h
pp_t:
            glo     r9
            smi     10
            lbnf    pp_build
            plo     r9
            ghi     r7
            adi     1
            phi     r7
            lbr     pp_t
pp_build:
            mov     rf, f_pctbuf
            ldi     13
            str     rf
            inc     rf
            glo     r7
            lbz     pp_h_sp
            adi     '0'
            lbr     pp_h_put
pp_h_sp:
            ldi     ' '
pp_h_put:
            str     rf
            inc     rf
            glo     r7
            lbnz    pp_t_digit              ; hundreds shown: tens too
            ghi     r7
            lbnz    pp_t_digit
            ldi     ' '
            lbr     pp_t_put
pp_t_digit:
            ghi     r7
            adi     '0'
pp_t_put:
            str     rf
            inc     rf
            glo     r9
            adi     '0'
            str     rf
            inc     rf
            ldi     0
            str     rf
            mov     rf, f_pctbuf
            call    K_MSG
            call    K_INMSG
            db      " percent completed.",0
            rtn

;==================================================================
; write_fats: both FAT copies, back to back from f_fatlba.
; Returns DF=1 on a write error.
;==================================================================
write_fats:
            mov     rf, f_lba
            mov     rd, f_fatlba
            call    m32_copy
            mov     rf, f_copy
            ldi     2
            str     rf
wf_copy:
            mov     rf, f_s
            ldi     0
            str     rf
            inc     rf
            str     rf
wf_sector:
            call    build_fat
            mov     rb, sec_buf
            call    wr_sector
            lbdf    wf_err
            mov     rf, f_lba
            call    m32_inc
            mov     rf, f_s
            call    inc16m
            ; f_s == f_fsz ?
            mov     rf, f_s
            mov     rd, f_fsz
            lda     rf
            str     r2
            lda     rd
            xor
            lbnz    wf_sector
            ldn     rf
            str     r2
            ldn     rd
            xor
            lbnz    wf_sector
            mov     rf, f_copy
            ldn     rf
            smi     1
            str     rf
            lbnz    wf_copy
            clc
            rtn
wf_err:
            stc
            rtn

;------------------------------------------------------------------
; build_fat: FAT sector f_s into sec_buf. Entries 0 and 1 are $FFF8
; (media byte) and $FFFF; clusters marked in f_bitmap become $FFF7;
; everything else is free (0). Makes no calls after zeroing, so its
; loop state lives in registers.
;------------------------------------------------------------------
build_fat:
            mov     rf, sec_buf
            call    zero_sector
            mov     rf, f_s
            lda     rf
            str     r2
            ldn     rf
            or
            lbnz    bf_no_head
            mov     rf, sec_buf
            ldi     $F8
            str     rf
            inc     rf
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
bf_no_head:
            mov     rf, f_bad
            lda     rf
            str     r2
            ldn     rf
            or
            lbz     bf_done                 ; no bad clusters (or -q)

            mov     rf, f_s
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd
            shl16   rd                      ; RD = s * 32
            mov     rb, LOADER_ARGS         ; R7 = the bitmap (mem_base)
            lda     rb
            phi     r7
            ldn     rb
            plo     r7
            add16   r7, rd                  ; R7 -> this sector's 32 bytes
            mov     rb, sec_buf
            ldi     32
            plo     rc
bf_byte:
            lda     r7
            plo     r9
            ldi     8
            phi     r9
bf_bit:
            glo     r9
            shr
            plo     r9
            lbnf    bf_nob
            ldi     $F7
            str     rb
            inc     rb
            ldi     $FF
            str     rb
            dec     rb
bf_nob:
            inc     rb
            inc     rb
            ghi     r9
            smi     1
            phi     r9
            lbnz    bf_bit
            dec     rc
            glo     rc
            lbnz    bf_byte
bf_done:
            rtn

;==================================================================
; write_root: 32 empty sectors from f_rootlba. DF=1 on error.
;==================================================================
write_root:
            mov     rf, sec_buf
            call    zero_sector
            mov     rf, f_lba
            mov     rd, f_rootlba
            call    m32_copy
            mov     rf, f_cnt
            ldi     0
            str     rf
            inc     rf
            ldi     FMT_ROOT_SECS
            str     rf
wr_loop:
            mov     rb, sec_buf
            call    wr_sector
            lbdf    wr_err
            mov     rf, f_lba
            call    m32_inc
            mov     rf, f_cnt
            call    dec16m
            lbnz    wr_loop
            clc
            rtn
wr_err:
            stc
            rtn

;==================================================================
; build_vbr: the boot sector, into vbr_buf, from the template plus
; this drive's values. Uses f_newlabel if one is set, else "NO NAME".
;==================================================================
build_vbr:
            mov     rf, vbr_buf
            call    zero_sector
            mov     rf, vbr_buf
            mov     rd, vbr_template
            ldi     VBR_TEMPLATE_LEN
            plo     rc
bv_tpl:
            lda     rd
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    bv_tpl

            mov     rf, f_spc               ; $0D sectors per cluster
            ldn     rf
            plo     rc
            mov     rf, vbr_buf+$0D
            glo     rc
            str     rf

            ; total sectors: 16-bit field at $13 when it fits, else the
            ; 32-bit field at $20 (the other one stays 0)
            mov     rf, f_total
            lda     rf
            lbnz    bv_total32
            ldn     rf
            lbnz    bv_total32
            mov     rf, vbr_buf+$13
            mov     rd, f_total
            call    put_le32
            mov     rf, vbr_buf+$15         ; put_le32 wrote 4 bytes; the
            ldi     $F8                     ; upper two were 0 but $15 is
            str     rf                      ; the media byte -- restore it
            lbr     bv_fsz
bv_total32:
            mov     rf, vbr_buf+$20
            mov     rd, f_total
            call    put_le32
bv_fsz:
            mov     rf, f_fsz               ; $16 sectors per FAT
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, vbr_buf+$16
            glo     rd
            str     rf
            inc     rf
            ghi     rd
            str     rf

            mov     rf, vbr_buf+$1C         ; hidden sectors = start LBA
            mov     rd, f_start
            call    put_le32

            mov     rf, vbr_buf+$27         ; serial number
            mov     rd, f_serial
            call    put_le32

            mov     rf, vbr_buf+$2B         ; volume label
            mov     rd, f_newlabel
            ldi     11
            plo     rc
bv_label:
            lda     rd
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    bv_label

            mov     rf, vbr_buf+510
            ldi     $55
            str     rf
            inc     rf
            ldi     $AA
            str     rf
            rtn

;------------------------------------------------------------------
; write_vbr: vbr_buf to the partition's first sector. DF=1 on error.
;------------------------------------------------------------------
write_vbr:
            mov     rf, f_lba
            mov     rd, f_start
            call    m32_copy
            mov     rb, vbr_buf
            lbr     wr_sector               ; tail call

;------------------------------------------------------------------
; write_label_entry: root sector 0 with just the volume-label entry.
; The root was written empty moments ago, so nothing else is lost.
; DF=1 on error.
;------------------------------------------------------------------
write_label_entry:
            mov     rf, sec_buf
            call    zero_sector
            mov     rf, sec_buf
            mov     rd, f_newlabel
            ldi     11
            plo     rc
wl_name:
            lda     rd
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    wl_name
            ldi     $08                     ; ATTR_VOLUME
            str     rf
            mov     rf, sec_buf+22          ; write time, little-endian
            mov     rd, f_ftime+1
            ldn     rd
            str     rf
            inc     rf
            dec     rd
            ldn     rd
            str     rf
            inc     rf
            mov     rd, f_fdate+1           ; write date
            ldn     rd
            str     rf
            inc     rf
            dec     rd
            ldn     rd
            str     rf
            mov     rf, f_lba
            mov     rd, f_rootlba
            call    m32_copy
            mov     rb, sec_buf
            lbr     wr_sector

;==================================================================
; commit: install the new geometry in drive_bpb_table[slot], reset
; the slot's current directory to the root, and mark it present.
;==================================================================
commit:
            ; the new BPB block (big-endian, BPBBLK_* layout)
            mov     rd, f_newbpb
            mov     rf, f_start+1
            call    copy3
            mov     rf, f_fatlba+1
            call    copy3
            mov     rf, f_rootlba+1
            call    copy3
            mov     rf, f_datalba+1
            call    copy3
            mov     rf, f_spc
            ldn     rf
            str     rd
            inc     rd
            mov     rf, f_shift
            ldn     rf
            str     rd
            inc     rd
            ldi     high 512                ; root entries
            str     rd
            inc     rd
            ldi     low 512
            str     rd
            inc     rd
            ldi     2                       ; number of FATs
            str     rd
            inc     rd
            mov     rf, f_fsz
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            inc     rd
            mov     rf, f_maxcl
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            inc     rd
            mov     rf, f_unit
            ldn     rf
            str     rd

            ; invalidate BEFORE the table entry changes (see MOUNT)
            mov     rf, f_slot
            ldn     rf
            call    K_DRIVE_INVALIDATE

            mov     rf, f_slot
            ldn     rf
            call    entry_addr
            mov     rd, f_newbpb
            ldi     BPBBLK_LEN
            plo     rc
cm_copy:
            lda     rd
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    cm_copy

            ; drive_cur_dir[slot] = 0 (the root)
            call    data_base               ; R9 = drive_present's address
            mov     rf, f_slot
            ldn     rf
            shl
            plo     rd
            ldi     0
            phi     rd
            mov     rf, r9
            add16   rf, DRIVE_CUR_DIR_OFF
            add16   rf, rd
            ldi     0
            str     rf
            inc     rf
            str     rf

            ; and live
            mov     rf, f_slot
            ldn     rf
            call    present_addr
            ldi     1
            str     rf
            rtn

;==================================================================
; summary: the MS-DOS closing report
;==================================================================
summary:
            ; cluster size in bytes = 1 << (shift + 9)
            mov     rf, f_shift
            ldn     rf
            adi     9
            plo     rc
            mov     rf, f_scale
            glo     rc
            str     rf

            mov     rf, f_clbytes
            mov     rd, c_one
            call    m32_copy
            mov     rf, f_scale
            ldn     rf
            plo     rc
            mov     rf, f_clbytes
            glo     rc
            call    m32_shln

            mov     rf, f_cl                ; total = cl << scale
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_sum_total
            call    m32_set16
            mov     rf, f_scale
            ldn     rf
            plo     rc
            mov     rf, f_sum_total
            glo     rc
            call    m32_shln

            mov     rf, f_bad               ; bad = bad << scale
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_sum_bad
            call    m32_set16
            mov     rf, f_scale
            ldn     rf
            plo     rc
            mov     rf, f_sum_bad
            glo     rc
            call    m32_shln

            mov     rf, f_tmp               ; available = total - bad
            mov     rd, f_sum_total
            call    m32_copy
            mov     rf, f_tmp
            mov     rd, f_sum_bad
            call    m32_sub

            call    K_INMSG
            db      13,10,0
            mov     rf, f_sum_total
            call    print32w
            call    K_INMSG
            db      " bytes total disk space",13,10,0

            mov     rf, f_sum_bad
            call    m32_is_zero
            lbz     sm_no_bad
            mov     rf, f_sum_bad
            call    print32w
            call    K_INMSG
            db      " bytes in bad sectors",13,10,0
sm_no_bad:
            mov     rf, f_tmp
            call    print32w
            call    K_INMSG
            db      " bytes available on disk",13,10,13,10,0

            mov     rf, f_clbytes
            call    print32w
            call    K_INMSG
            db      " bytes in each allocation unit.",13,10,0

            ; units available = cl - bad
            mov     rf, f_bad
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, f_cl
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            sub16   rd, r9
            mov     rf, f_tmp
            call    m32_set16
            mov     rf, f_tmp
            call    print32w
            call    K_INMSG
            db      " allocation units available on disk.",13,10,13,10
            db      "Volume Serial Number is ",0

            mov     rf, f_hexbuf
            mov     rd, f_serial
            lda     rd
            call    hex_byte
            lda     rd
            call    hex_byte
            ldi     '-'
            str     rf
            inc     rf
            lda     rd
            call    hex_byte
            ldn     rd
            call    hex_byte
            ldi     0
            str     rf
            mov     rf, f_hexbuf
            call    K_MSG
            call    K_INMSG
            db      13,10,0
            rtn

;------------------------------------------------------------------
; hex_byte: two hex digits of D at [RF], RF advanced. Leaf.
; Modifies: R9.0, RF, D
;------------------------------------------------------------------
hex_byte:
            plo     r9
            shr
            shr
            shr
            shr
            call    hex_nib
            glo     r9
hex_nib:
            ani     $0F
            smi     10
            lbnf    hn_digit
            adi     'A'
            lbr     hn_put
hn_digit:
            adi     10 + '0'
hn_put:
            str     rf
            inc     rf
            rtn

;==================================================================
; Time, date and serial number
;==================================================================
get_time:
            call    K_GETDEV                ; RF = device flags
            glo     rf
            ani     $10                     ; bit 4 = RTC present
            lbz     gt_have                 ; none: keep the 1/1/2000 default
            mov     rf, f_time
            push    rc                      ; f_gettod's RC.1 bug (see
            call    K_GETTOD                ; kernel/rtc.asm)
            pop     rc
gt_have:
            ; FAT date: hi = (year-1980)<<1 | month>>3,
            ;           lo = (month&7)<<5 | day
            mov     rf, f_time+2
            ldn     rf                      ; year, 0 = 1972
            smi     8
            lbdf    gt_year_ok
            ldi     0
gt_year_ok:
            shl
            plo     r9
            mov     rf, f_time
            ldn     rf                      ; month
            shr
            shr
            shr
            str     r2
            glo     r9
            or
            plo     r9
            mov     rf, f_fdate
            glo     r9
            str     rf
            mov     rf, f_time
            ldn     rf
            ani     7
            shl
            shl
            shl
            shl
            shl
            plo     r9
            mov     rf, f_time+1
            ldn     rf                      ; day
            str     r2
            glo     r9
            or
            plo     r9
            mov     rf, f_fdate+1
            glo     r9
            str     rf

            ; FAT time: hi = hour<<3 | minute>>3,
            ;           lo = (minute&7)<<5 | second>>1
            mov     rf, f_time+3
            ldn     rf
            shl
            shl
            shl
            plo     r9
            mov     rf, f_time+4
            ldn     rf
            shr
            shr
            shr
            str     r2
            glo     r9
            or
            plo     r9
            mov     rf, f_ftime
            glo     r9
            str     rf
            mov     rf, f_time+4
            ldn     rf
            ani     7
            shl
            shl
            shl
            shl
            shl
            plo     r9
            mov     rf, f_time+5
            ldn     rf
            shr
            str     r2
            glo     r9
            or
            plo     r9
            mov     rf, f_ftime+1
            glo     r9
            str     rf

            ; serial: hi = (hour<<8 | minute) + year,
            ;         lo = ((month + second)<<8) | day
            mov     rf, f_time+3
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1972
            mov     rf, f_time+2
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            add16   rd, r9
            mov     rf, f_serial
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, f_time+5
            ldn     rf
            str     r2
            mov     rf, f_time
            ldn     rf
            add
            plo     r9
            mov     rf, f_serial+2
            glo     r9
            str     rf
            inc     rf
            mov     rd, f_time+1
            ldn     rd
            str     rf
            rtn

;==================================================================
; Volume labels
;==================================================================

;------------------------------------------------------------------
; lbl_norm: turn typed text into an 11-byte, space-padded, uppercase
; label in f_lbl_tmp. Rejects more than 11 characters and the
; characters MS-DOS rejected: * ? / \ | . , ; : + = < > [ ] "
; Args:    RF = text (NUL-terminated)
; Returns: DF=0, D = 1 if the label has any non-space character
;          (0 = no label); DF=1 on bad input, with f_lbl_err set
;          (1 = too long, 2 = bad character)
; Modifies: R9, RB, RC, RD, RF, D
;------------------------------------------------------------------
lbl_norm:
            mov     rd, f_lbl_tmp
            ldi     11
            plo     rc
ln_fill:
            ldi     ' '
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    ln_fill
            mov     rd, f_lbl_tmp
            ldi     0
            plo     rc                      ; RC.0 = characters stored
            plo     r9                      ; R9.0 = any non-space seen
ln_loop:
            lda     rf
            lbz     ln_done
            plo     rb                      ; RB.0 = the character
            glo     rc
            xri     11
            lbz     ln_too_long
            mov     r7, f_lbl_strict
            ldn     r7
            lbz     ln_char_ok              ; lenient: take it as typed
            glo     rb
            smi     ' '
            lbnf    ln_bad                  ; control character
            mov     r7, lbl_bad_chars
ln_scan:
            lda     r7
            lbz     ln_char_ok
            str     r2
            glo     rb
            sm
            lbz     ln_bad
            lbr     ln_scan
ln_char_ok:
            glo     rb
            call    fold_upper
            str     rd
            inc     rd
            inc     rc
            xri     ' '
            lbz     ln_loop
            ldi     1
            plo     r9
            lbr     ln_loop
ln_done:
            glo     r9
            clc
            rtn
ln_too_long:
            ldi     1
            lbr     ln_err
ln_bad:
            ldi     2
ln_err:
            plo     rb
            mov     rf, f_lbl_err
            glo     rb
            str     rf
            stc
            rtn

;------------------------------------------------------------------
; take_label: D (from lbl_norm) = nonblank flag. Copies f_lbl_tmp to
; f_newlabel when nonblank, else restores "NO NAME", and records
; which in f_newlabel_set.
;------------------------------------------------------------------
take_label:
            plo     r9
            mov     rf, f_newlabel_set
            glo     r9
            str     rf
            mov     rd, f_newlabel
            mov     rf, f_lbl_tmp
            glo     r9
            lbnz    tl_copy
            mov     rf, no_name
tl_copy:
            ldi     11
            plo     rc
tl_loop:
            lda     rf
            str     rd
            inc     rd
            dec     rc
            glo     rc
            lbnz    tl_loop
            rtn

print_label_error:
            mov     rf, f_lbl_err
            ldn     rf
            xri     1
            lbz     ple_long
            call    K_INMSG
            db      "Invalid characters in volume label",13,10,0
            rtn
ple_long:
            call    K_INMSG
            db      "Too many characters in volume label",13,10,0
            rtn

;------------------------------------------------------------------
; fold_upper: D = D with a-z folded to A-Z; anything else unchanged.
; Leaf, touches only D and M(R2).
;------------------------------------------------------------------
fold_upper:
            str     r2
            smi     'a'
            lbnf    fu_same
            ldn     r2
            smi     'z'+1
            lbdf    fu_same
            ldn     r2
            ani     $DF
            rtn
fu_same:
            ldn     r2
            rtn

;------------------------------------------------------------------
; yes_no: D = 'Y' or 'N' if the text at RF is one of those letters
; (either case, surrounding spaces allowed), else 0.
;------------------------------------------------------------------
yes_no:
            lda     rf
            xri     ' '
            lbz     yes_no
            dec     rf
            lda     rf
            call    fold_upper
            plo     r9
            xri     'Y'
            lbz     yn_rest
            glo     r9
            xri     'N'
            lbnz    yn_no
yn_rest:
            lda     rf
            lbz     yn_ok
            xri     ' '
            lbz     yn_rest
yn_no:
            ldi     0
            rtn
yn_ok:
            glo     r9
            rtn

;------------------------------------------------------------------
; read_answer: a line of input into f_inbuf, then a newline (the line
; editor does not echo one). Redirect-aware, so FORMAT can be driven
; from a file. Returns DF=1 at end of redirected input.
;------------------------------------------------------------------
read_answer:
            mov     rf, f_inbuf
            ldi     FMT_INBUF_MAX
            plo     rc
            ldi     0
            phi     rc
            ldi     LE_MODE_REDIR
            call    read_line_ex
            lbdf    ra_eof
            call    K_INMSG
            db      13,10,0
            clc
            rtn
ra_eof:
            call    K_INMSG
            db      13,10,0
            stc
            rtn

print_letter:
            mov     rf, f_letter
            ldn     rf
            call    K_TYPE                  ; NOT a tail jump: the BIOS
            rtn                             ; takes the character from RE.0,
                                            ; which only a call sets

;==================================================================
; Sector I/O. The LBA always comes from f_lba (4 bytes, big-endian,
; top byte 0) and the unit from f_unit.
;==================================================================

;------------------------------------------------------------------
; rd_sector: read f_lba into sec_buf. DF=1 on error.
;------------------------------------------------------------------
rd_sector:
            call    set_lba
            mov     rf, sec_buf
            lbr     K_SECREAD               ; tail call; DF passes back

;------------------------------------------------------------------
; wr_sector: write the buffer at RB to f_lba. DF=1 on error.
;------------------------------------------------------------------
wr_sector:
            call    set_lba                 ; leaves RB alone
            mov     rf, rb
            lbr     K_SECWRITE

;------------------------------------------------------------------
; set_lba: R7:R8.0 = f_lba's low 24 bits, R8.1 = f_unit.
; Modifies: R7, R8, RF, D
;------------------------------------------------------------------
set_lba:
            mov     rf, f_lba+1
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, f_unit
            ldn     rf
            phi     r8
            rtn

;------------------------------------------------------------------
; zero_sector: 512 zero bytes at RF. Modifies RC, RF, D
;------------------------------------------------------------------
zero_sector:
            ldi     0
            plo     rc
            ldi     2
            phi     rc
zs_loop:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    zs_loop
            ghi     rc
            lbnz    zs_loop
            rtn

;==================================================================
; Drive-table addressing (as in progs/mount.asm)
;==================================================================

;------------------------------------------------------------------
; data_base: R9 = DRIVE_DATA_PTR's target. Modifies R9, RF, D
;------------------------------------------------------------------
data_base:
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            rtn

;------------------------------------------------------------------
; present_addr: RF = &drive_present[D]. Modifies R9, RD, RF, D
;------------------------------------------------------------------
present_addr:
            plo     rd
            ldi     0
            phi     rd
            call    data_base
            mov     rf, r9
            add16   rf, rd
            rtn

;------------------------------------------------------------------
; letter_addr: RF = &drive_letter[D]. Modifies R9, RD, RF, D
;------------------------------------------------------------------
letter_addr:
            plo     rd
            ldi     0
            phi     rd
            call    data_base
            mov     rf, r9
            add16   rf, DRIVE_LETTER_OFF
            add16   rf, rd
            rtn

;------------------------------------------------------------------
; entry_addr: RF = &drive_bpb_table[D]. Modifies R9, RB, RC, RD, RF, D
;------------------------------------------------------------------
entry_addr:
            plo     rd
            ldi     0
            phi     rd
            call    data_base
            ldi     0
            phi     rb
            plo     rb
            glo     rd
            lbz     ea_have
            plo     rc
ea_mul:
            add16   rb, BPBBLK_LEN
            dec     rc
            glo     rc
            lbnz    ea_mul
ea_have:
            mov     rf, r9
            add16   rf, DRIVE_BPB_TABLE_OFF
            add16   rf, rb
            rtn

;------------------------------------------------------------------
; argv_at: RF = argv[D]. Modifies RB, RD, RF, D
;------------------------------------------------------------------
argv_at:
            shl
            plo     rd
            ldi     0
            phi     rd
            mov     rb, f_argv
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            add16   rf, rd
            mov     rb, rf
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            rtn

;==================================================================
; 32-bit helpers on 4-byte big-endian variables in memory.
; All are leaf routines (m32_shln and m32_div16 call only m32_shl1,
; which touches nothing but D and DF).
;==================================================================

;------------------------------------------------------------------
; m32_zero: [RF] = 0. Modifies RF, D
;------------------------------------------------------------------
m32_zero:
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            rtn

;------------------------------------------------------------------
; m32_is_zero: D = OR of the four bytes at RF (0 = zero).
; Modifies RF, D
;------------------------------------------------------------------
m32_is_zero:
            lda     rf
            str     r2
            lda     rf
            or
            str     r2
            lda     rf
            or
            str     r2
            ldn     rf
            or
            rtn

;------------------------------------------------------------------
; m32_copy: [RF] = [RD]. Modifies RD, RF, D
;------------------------------------------------------------------
m32_copy:
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            rtn

;------------------------------------------------------------------
; m32_set16: [RF] = RD, zero-extended. Modifies RF, D
;------------------------------------------------------------------
m32_set16:
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; m32_add: [RF] += [RD]. Modifies RD, RF, D, DF (= carry out)
;------------------------------------------------------------------
m32_add:
            inc     rf
            inc     rf
            inc     rf
            inc     rd
            inc     rd
            inc     rd
            ldn     rd
            str     r2
            ldn     rf
            add
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            adc
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            adc
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            adc
            str     rf
            rtn

;------------------------------------------------------------------
; m32_sub: [RF] -= [RD]. DF=0 on borrow (the result went negative).
; SM/SMB compute D - M(X): the subtrahend is staged, the minuend is
; loaded last. Modifies RD, RF, D
;------------------------------------------------------------------
m32_sub:
            inc     rf
            inc     rf
            inc     rf
            inc     rd
            inc     rd
            inc     rd
            ldn     rd
            str     r2
            ldn     rf
            sm
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            smb
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            smb
            str     rf
            dec     rf
            dec     rd
            ldn     rd
            str     r2
            ldn     rf
            smb
            str     rf
            rtn

;------------------------------------------------------------------
; m32_inc: [RF] += 1. Modifies RF, D
;------------------------------------------------------------------
m32_inc:
            inc     rf
            inc     rf
            inc     rf
            ldn     rf
            adi     1
            str     rf
            dec     rf
            ldn     rf
            adci    0
            str     rf
            dec     rf
            ldn     rf
            adci    0
            str     rf
            dec     rf
            ldn     rf
            adci    0
            str     rf
            rtn

;------------------------------------------------------------------
; m32_shl1: [RF] <<= 1, RF left unchanged. DF = the bit shifted out.
; Modifies D only
;------------------------------------------------------------------
m32_shl1:
            inc     rf
            inc     rf
            inc     rf
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
            rtn

;------------------------------------------------------------------
; m32_shr1: [RF] >>= 1. Modifies RF, D
;------------------------------------------------------------------
m32_shr1:
            ldn     rf
            shr
            str     rf
            inc     rf
            ldn     rf
            shrc
            str     rf
            inc     rf
            ldn     rf
            shrc
            str     rf
            inc     rf
            ldn     rf
            shrc
            str     rf
            rtn

;------------------------------------------------------------------
; m32_shln: [RF] <<= D. Modifies RC, D
;------------------------------------------------------------------
m32_shln:
            plo     rc
msn_loop:
            glo     rc
            lbz     msn_done
            call    m32_shl1
            dec     rc
            lbr     msn_loop
msn_done:
            rtn

;------------------------------------------------------------------
; m32_div16: [RF] = [RF] / RD (unsigned, RD nonzero; the remainder is
; discarded). Restoring division: the remainder needs 17 bits, the
; 17th held in DF right after it is shifted.
; Modifies R9, RB, D
;------------------------------------------------------------------
m32_div16:
            ldi     0
            phi     r9
            plo     r9                      ; R9 = remainder
            ldi     32
            plo     rb
md_loop:
            call    m32_shl1                ; DF = dividend's top bit
            glo     r9
            shlc
            plo     r9
            ghi     r9
            shlc
            phi     r9                      ; DF = remainder bit 16
            lbdf    md_sub                  ; >= 65536 > divisor
            glo     rd
            str     r2
            glo     r9
            sm
            ghi     rd
            str     r2
            ghi     r9
            smb                             ; remainder - divisor
            lbnf    md_next                 ; borrow: remainder < divisor
md_sub:
            glo     rd
            str     r2
            glo     r9
            sm
            plo     r9
            ghi     rd
            str     r2
            ghi     r9
            smb
            phi     r9
            inc     rf                      ; quotient bit = 1 (the
            inc     rf                      ; dividend's LSB, just
            inc     rf                      ; vacated by the shift)
            ldn     rf
            ori     1
            str     rf
            dec     rf
            dec     rf
            dec     rf
md_next:
            dec     rb
            glo     rb
            lbnz    md_loop
            rtn

;------------------------------------------------------------------
; put_le32: store the 4-byte big-endian value at RD, little-endian,
; at RF. Modifies RD, RF, D
;------------------------------------------------------------------
put_le32:
            inc     rd
            inc     rd
            inc     rd
            ldn     rd
            str     rf
            inc     rf
            dec     rd
            ldn     rd
            str     rf
            inc     rf
            dec     rd
            ldn     rd
            str     rf
            inc     rf
            dec     rd
            ldn     rd
            str     rf
            rtn

;------------------------------------------------------------------
; copy3: 3 bytes [RF] -> [RD], both advanced. Modifies RD, RF, D
;------------------------------------------------------------------
copy3:
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            inc     rd
            rtn

;------------------------------------------------------------------
; inc16m / dec16m: 16-bit big-endian word at RF, +1 or -1.
; dec16m returns D = high|low of the result (0 when it reached 0).
; Modifies RD, RF, D
;------------------------------------------------------------------
inc16m:
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            inc     rd
            lbr     st16m
dec16m:
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            dec     rd
st16m:
            dec     rf
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            ghi     rd
            str     r2
            glo     rd
            or
            rtn

;------------------------------------------------------------------
; print32: the 4-byte big-endian value at RF, with thousands commas
; print32w: the same, right-justified in 13 columns
;------------------------------------------------------------------
print32w:
            ldi     13
            lbr     p32_go
print32:
            ldi     0
p32_go:
            plo     rc
            mov     rd, f_width
            glo     rc
            str     rd
            lda     rf
            phi     rd
            lda     rf
            plo     rd
            lda     rf
            phi     r8
            ldn     rf
            plo     r8                      ; RD:R8 = value
            mov     rf, f_numbuf
            call    fmt_size32
            ; pad = width - length (width 0 means none)
            mov     rf, f_numbuf
            ldi     0
            plo     rc
p32_len:
            lda     rf
            lbz     p32_pad
            inc     rc
            lbr     p32_len
p32_pad:
            mov     rf, f_width
            glo     rc
            str     r2
            ldn     rf
            sm                              ; width - length
            lbnf    p32_out                 ; longer than the field
            str     rf                      ; f_width = spaces to print
p32_sp:
            mov     rf, f_width
            ldn     rf
            lbz     p32_out
            smi     1
            str     rf
            ldi     ' '
            call    K_TYPE
            lbr     p32_sp
p32_out:
            mov     rf, f_numbuf
            lbr     K_MSG

;==================================================================
; Constants
;==================================================================
c_one:          db      0,0,0,1
c_32:           db      0,0,0,32
c_33:           db      0,0,0,33
c_min_total:    db      0,0,$10,$36     ; 4150
c_max_total1:   db      0,$7F,$FC,$A1   ; 8387745 (one past the maximum)

no_name:        db      "NO NAME    "
lbl_bad_chars:  db      "*?/",$5C,"|.,",';',":+=<>[]",$22,0

; Boot sector bytes $00-$3D; build_vbr patches the variable fields
; ($0D, $13/$20, $16, $1C, $27, $2B) and adds the $55 $AA signature.
vbr_template:
            db      $EB,$3C,$90             ; jump over the BPB
            db      "ELFDOS  "              ; OEM name
            db      $00,$02                 ; $0B bytes per sector
            db      0                       ; $0D sectors per cluster
            db      $01,$00                 ; $0E reserved sectors
            db      2                       ; $10 number of FATs
            db      $00,$02                 ; $11 root entries (512)
            db      0,0                     ; $13 total sectors (16-bit)
            db      $F8                     ; $15 media: fixed disk
            db      0,0                     ; $16 sectors per FAT
            db      63,0                    ; $18 sectors per track
            db      255,0                   ; $1A heads
            db      0,0,0,0                 ; $1C hidden sectors
            db      0,0,0,0                 ; $20 total sectors (32-bit)
            db      $80                     ; $24 drive number
            db      0                       ; $25 reserved
            db      $29                     ; $26 extended boot signature
            db      0,0,0,0                 ; $27 serial number
            db      "NO NAME    "           ; $2B volume label
            db      "FAT16   "              ; $36 file system type
            db      $FA,$F4,$EB,$FD         ; $3E x86: cli / hlt / jmp $-1

;==================================================================
; Data
;==================================================================
f_argv:         dw      0
f_argc:         db      0
f_argi:         db      0
f_letter:       db      0
f_quick:        db      1           ; 1 = no surface scan (the default)
f_vgiven:       db      0           ; -v:<text> given
f_newlabel_set: db      0           ; a real (non-blank) label chosen
f_newlabel:     db      "NO NAME    "
f_lbl_tmp:      ds      11
f_lbl_err:      db      0
f_lbl_strict:   db      1           ; 0 while matching an old label
f_curlabel:     ds      11
f_hascur:       db      0
f_slot:         db      0
f_j:            db      0
f_was_present:  db      0
f_unit:         db      0
f_oldbpb:       ds      BPBBLK_LEN
f_newbpb:       ds      BPBBLK_LEN

f_start:        ds      4           ; partition start LBA
f_total:        ds      4           ; sectors in the partition
f_tmp:          ds      4
f_k:            ds      4
f_lba:          ds      4           ; the sector being read or written
f_fatlba:       ds      4
f_rootlba:      ds      4
f_datalba:      ds      4
f_clbytes:      ds      4
f_sum_total:    ds      4
f_sum_bad:      ds      4

f_spc:          db      0
f_shift:        db      0
f_giter:        db      0
f_v2:           dw      0
f_fsz:          dw      0           ; sectors per FAT
f_cl:           dw      0           ; cluster count
f_maxcl:        dw      0           ; cl + 1, the highest cluster number
f_scale:        db      0

f_bad:          dw      0           ; bad clusters found by the scan
f_vc:           dw      0           ; cluster being scanned
f_vleft:        dw      0
f_step:         dw      0
f_sub:          dw      0
f_pct:          db      0
f_cbad:         db      0
f_scnt:         db      0
f_s:            dw      0           ; FAT sector index
f_copy:         db      0
f_cnt:          dw      0

f_time:         db      1,1,28,0,0,0    ; month/day/year(0=1972)/h/m/s
f_fdate:        dw      0
f_ftime:        dw      0
f_serial:       ds      4

f_width:        db      0
f_numbuf:       ds      14
f_hexbuf:       ds      10
f_pctbuf:       ds      6
f_inbuf:        ds      FMT_INBUF_MAX+1
sec_buf:        ds      512
vbr_buf:        ds      512

; The 8K bad-cluster bitmap is not ds'd (ds writes its zeros into the
; binary): it lives at mem_base, the first byte past the loaded image
; (LOADER_ARGS word 0), which also covers the libraries linked after
; this file's own bytes. A label placed at the end of THIS file would
; not -- they come after it.
