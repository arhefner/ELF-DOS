;
; fdisk.asm - create and change the partition table of a block device
;
; FDISK [unit]
;
; A menu-driven program modelled on MS-DOS's FDISK, cut down to what
; ELF-DOS uses: up to four PRIMARY partitions per device (MOUNT and the
; boot-time scan read MBR entries 1-4 only; there is no support for
; extended partitions or logical drives, so FDISK does not make them).
;
;   1. Create a FAT16 partition
;   2. Set active partition
;   3. Delete partition
;   4. Display partition information
;   5. Change current unit
;
; With no argument FDISK starts on the unit ELF-DOS booted from. Together
; with FORMAT and SYS it can build a bootable disk from nothing:
;   FDISK 1                  create partition(s) on unit 1
;   SYS 1 MBR.BIN            install the MBR boot code
;   SYS 1 KERNEL-FULL.BIN    install the kernel
;   MOUNT 1 1 W:             mount, then
;   FORMAT W:                make a filesystem, and copy /bin across
;
; Layout rules, the same as ELF-DOS's own card scripts (mkdisk.sh,
; Format-ElfDosDisk.ps1):
;   - sectors 0-2047 (the first megabyte) are never given to a partition:
;     LBA 0 is the MBR and SYS writes krnboot and the kernel from LBA 1
;   - partitions start and are sized on 1MB (2048-sector) boundaries
;   - partition type $0E (FAT16, LBA addressing)
;   - sizes 3MB to 4095MB, what FORMAT can put a FAT16 filesystem on
;   - nothing past sector 2^24 (8GB): ELF-DOS addresses 24-bit LBAs
; A new partition goes at the start of the largest free block.
;
; The device's size is found by reading: Elf/OS BIOSes have no call that
; reports it (f_idesize is a stub returning an error in every MBIOS), and
; FDISK must work with any Elf/OS-compatible BIOS. Partitions are whole
; megabytes, so only the size in MB is needed: FDISK reads the last
; sector of the 8GB range, then binary-searches for the largest megabyte
; whose last sector reads -- 14 reads in all (probe_size). This relies on
; the BIOS reporting DF=1 for a read past the end of the device, which an
; SD card (OUT_OF_RANGE) and an IDE/CF drive (IDNF) both signal. When it
; cannot tell -- everything up to 8GB reads, which is either a disk of
; 8GB or more or a BIOS that never reports such an error -- FDISK asks,
; offering 8GB; it also asks if nothing past sector 0 reads.
;
; A disk with no partition table gets a new, empty one when the first
; partition is created, with no boot code in it: run SYS <unit> MBR.BIN
; to make it bootable. SYS refuses a disk without a table, so FDISK has
; to come first. Existing boot code is kept whenever the table is edited.
;
; Deleting a partition that is mounted under any letter is refused, and
; that covers the shell's own partition too (it can never be unmounted).
; The table is written as one sector and read back to check it; the
; kernel keeps no copy of it, so no invalidate is needed. A partition
; created or changed here can be mounted straight away; the boot-time
; mapping (C:-F:) picks it up at the next restart.
;
; The active flag is kept for compatibility -- MS-DOS made the first
; partition active and other systems read it -- but ELF-DOS's own MBR
; does not look at it.
;
; Every value that must outlive a kernel or BIOS call lives in memory.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc
#include    include/lineedit.inc

            extrn   fmt_size32
            extrn   read_line_ex
            extrn   add32
            extrn   sub32
            extrn   shl32
            extrn   zero4bytes

PT_OFF:           equ   $1BE        ; first partition table entry
PT_TYPE_FAT16:    equ   $0E         ; FAT16, LBA addressing
MIN_MB:           equ   3           ; FORMAT's minimum is 4150 sectors
MAX_MB:           equ   4095        ; FORMAT's maximum is 8,387,744
MAX_DISK_MB:      equ   8192        ; 2^24 sectors
INBUF_MAX:        equ   32

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
            mov     rf, BOOT_UNIT           ; default: the boot unit
            ldn     rf
            plo     rb
            mov     rf, f_unit
            glo     rb
            str     rf

            glo     rc
            smi     2
            lbnf    have_unit               ; no argument
            glo     rc
            smi     3
            lbdf    usage                   ; more than one
            inc     ra                      ; RA -> argv[1]
            inc     ra
            lda     ra
            phi     rf
            ldn     ra
            plo     rf
            lda     rf
            smi     '0'
            lbnf    usage
            plo     rb
            smi     8
            lbdf    usage
            ldn     rf
            lbnz    usage
            mov     rf, f_unit
            glo     rb
            str     rf
have_unit:
            call    K_INMSG
            db      13,10,"ELF-DOS Fixed Disk Setup Program",13,10,0
            call    load_unit
            lbnf    menu
            call    unit_error
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: FDISK [unit 0-7]",13,10,0
            ldi     1
            rtn

;==================================================================
; The menu
;==================================================================
menu:
            call    K_INMSG
            db      13,10,"Current unit: ",0
            call    print_unit
            mov     rf, f_sizeknown
            ldn     rf
            lbz     menu_nosize
            call    K_INMSG
            db      " (",0
            call    disk_mb                 ; RD = disk size in MB
            call    print16
            call    K_INMSG
            db      " MB)",0
            lbr     menu_list
menu_nosize:
            call    K_INMSG
            db      " (size unknown)",0
menu_list:
            call    K_INMSG
            db      13,10,13,10
            db      "1. Create a FAT16 partition",13,10
            db      "2. Set active partition",13,10
            db      "3. Delete partition",13,10
            db      "4. Display partition information",13,10
            db      "5. Change current unit",13,10,13,10
            db      "Enter choice, or Q to quit: ",0
            call    read_answer
            lbdf    quit
            call    first_char              ; D = first non-space, folded
            lbz     menu
            plo     rb
            xri     '1'
            lbz     do_create
            glo     rb
            xri     '2'
            lbz     do_active
            glo     rb
            xri     '3'
            lbz     do_delete
            glo     rb
            xri     '4'
            lbz     do_display
            glo     rb
            xri     '5'
            lbz     do_unit
            glo     rb
            xri     'Q'
            lbz     quit
            call    K_INMSG
            db      "Choose 1-5, or Q.",13,10,0
            lbr     menu

quit:
            ldi     0
            rtn

do_display:
            call    display
            lbr     menu

;==================================================================
; 5. Change current unit
;==================================================================
do_unit:
            call    K_INMSG
            db      "Enter unit number (0-7): ",0
            call    read_answer
            lbdf    menu
            call    parse_number            ; RD = value, DF=1 if none
            lbdf    du_bad
            ghi     rd
            lbnz    du_bad
            glo     rd
            smi     8
            lbdf    du_bad
            ; keep the old unit in case the new one cannot be read
            mov     rf, f_unit
            ldn     rf
            plo     rb
            mov     rf, f_oldunit
            glo     rb
            str     rf
            mov     rf, f_unit
            glo     rd
            str     rf
            call    load_unit
            lbnf    menu
            call    unit_error
            mov     rf, f_oldunit
            ldn     rf
            plo     rb
            mov     rf, f_unit
            glo     rb
            str     rf
            call    load_unit               ; back to the old one
            lbr     menu
du_bad:
            call    K_INMSG
            db      "Unit must be 0-7.",13,10,0
            lbr     menu

;==================================================================
; 2. Set active partition
;==================================================================
do_active:
            call    need_table
            lbdf    menu
            call    K_INMSG
            db      "Enter the number of the partition you want to make active (1-4): ",0
            call    ask_partition           ; D = index 0-3, DF=1 = none
            lbdf    menu
            plo     rb
            mov     rf, f_idx
            glo     rb
            str     rf
            ; status $80 on it, $00 on the other three
            ldi     0
            plo     rc
da_loop:
            glo     rc
            call    entry_addr              ; RF = the entry (keeps RC)
            mov     rd, f_idx
            ldn     rd
            str     r2
            glo     rc
            sm
            lbz     da_this
            ldi     0
            lbr     da_put
da_this:
            ldi     $80
da_put:
            str     rf
            inc     rc
            glo     rc
            smi     4
            lbnf    da_loop
            call    write_mbr
            lbdf    menu
            call    K_INMSG
            db      "Partition ",0
            call    print_idx
            call    K_INMSG
            db      " made active.",13,10,0
            lbr     menu

;==================================================================
; 3. Delete partition
;==================================================================
do_delete:
            call    need_table
            lbdf    menu
            call    K_INMSG
            db      "Delete which partition (1-4)? ",0
            call    ask_partition
            lbdf    menu
            plo     rb
            mov     rf, f_idx
            glo     rb
            str     rf

            ; refuse while any letter is mounted on it
            mov     rf, f_idx
            ldn     rf
            call    mounted_letter          ; D = letter, 0 if none
            lbz     dd_free
            plo     rb
            mov     rf, f_letter
            glo     rb
            str     rf
            call    K_INMSG
            db      "Partition ",0
            call    print_idx
            call    K_INMSG
            db      " is mounted as ",0
            mov     rf, f_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      ": -- UMOUNT it first.",13,10,0
            lbr     menu
dd_free:
            call    K_INMSG
            db      13,10,"WARNING! Data in partition ",0
            call    print_idx
            call    K_INMSG
            db      " (",0
            mov     rf, f_idx
            ldn     rf
            call    size_ptr
            call    print_mb                ; the size, in MB
            call    K_INMSG
            db      " MB) will be lost.",13,10
            db      "Do you wish to continue (Y/N)? ",0
            call    ask_yes
            lbdf    menu
            mov     rf, f_idx
            ldn     rf
            call    entry_addr
            ldi     16
            plo     rc
dd_zero:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    dd_zero
            call    write_mbr
            lbdf    menu
            call    K_INMSG
            db      "Partition ",0
            call    print_idx
            call    K_INMSG
            db      " deleted.",13,10,0
            lbr     menu

;==================================================================
; 1. Create a FAT16 partition
;==================================================================
do_create:
            ; ---- a partition table to put it in ----
            mov     rf, f_isvol
            ldn     rf
            lbz     dc_not_vol
            ; a whole-device volume: only if no letter is using it
            ldi     4                       ; "whole device": start LBA 0
            call    mounted_letter
            lbz     dc_vol_free
            plo     rb
            mov     rf, f_letter
            glo     rb
            str     rf
            call    K_INMSG
            db      "Unit ",0
            call    print_unit
            call    K_INMSG
            db      " is mounted as ",0
            mov     rf, f_letter
            ldn     rf
            call    K_TYPE
            call    K_INMSG
            db      ": with no partition table -- UMOUNT it first.",13,10,0
            lbr     menu
dc_vol_free:
            call    K_INMSG
            db      13,10,"Unit ",0
            call    print_unit
            call    K_INMSG
            db      " holds a volume with no partition table.",13,10
            db      "WARNING! All data on it will be lost.",13,10
            db      "Replace it with a partition table (Y/N)? ",0
            call    ask_yes
            lbdf    menu
            call    new_table
            lbr     dc_have_table
dc_not_vol:
            mov     rf, f_hastable
            ldn     rf
            lbnz    dc_have_table
            call    K_INMSG
            db      13,10,"Unit ",0
            call    print_unit
            call    K_INMSG
            db      " has no partition table. Create one (Y/N)? ",0
            call    ask_yes
            lbdf    menu
            call    new_table
dc_have_table:
            ; (new_table changed only the copy in memory; every way out
            ; below that does not write reloads the unit to discard it)

            ; ---- a free entry ----
            ldi     0
            plo     rc
dc_find_entry:
            glo     rc
            call    type_of                 ; D = type (keeps RC)
            lbz     dc_have_entry
            inc     rc
            glo     rc
            smi     4
            lbnf    dc_find_entry
            call    K_INMSG
            db      "The partition table is full (4 partitions).",13,10,0
            lbr     dc_abandon
dc_have_entry:
            mov     rf, f_idx
            glo     rc
            str     rf

            ; ---- the disk's size ----
            call    need_size
            lbdf    dc_abandon

            ; ---- where, and how big at most ----
            call    find_free               ; f_best_s, f_best_len
            mov     rf, f_best_len          ; MB = sectors >> 11
            call    mb_of                   ; RD = MB (16-bit)
            mov     rf, f_maxmb
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            ; cap at MAX_MB
            glo     rd
            smi     low (MAX_MB+1)
            ghi     rd
            smbi    high (MAX_MB+1)
            lbnf    dc_max_ok
            mov     rf, f_maxmb
            ldi     high MAX_MB
            str     rf
            inc     rf
            ldi     low MAX_MB
            str     rf
dc_max_ok:
            mov     rf, f_maxmb
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            glo     rd
            smi     MIN_MB
            ghi     rd
            smbi    0
            lbdf    dc_ask_size
            call    K_INMSG
            db      "Not enough free space for a partition (",0
            ldi     MIN_MB + '0'
            call    K_TYPE
            call    K_INMSG
            db      " MB minimum).",13,10,0
            lbr     dc_abandon

dc_ask_size:
            call    K_INMSG
            db      13,10,"Enter partition size in MB or percent of disk space (%)",13,10
            db      "to create a FAT16 partition [",0
            mov     rf, f_maxmb
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    print16
            call    K_INMSG
            db      "]: ",0
            call    read_answer
            lbdf    dc_abandon
            call    first_char
            lbnz    dc_parse
            mov     rf, f_maxmb             ; Enter: the maximum
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            lbr     dc_check
dc_parse:
            call    parse_number            ; RD, RF at the next character
            lbdf    dc_bad_size
            ldn     rf
            xri     '%'
            lbnz    dc_mb_given
            inc     rf
            call    rest_blank
            lbnz    dc_bad_size
            ; percent of the whole disk: MB = disk_mb * pct / 100
            ghi     rd
            lbnz    dc_bad_size
            glo     rd
            lbz     dc_bad_size
            smi     101
            lbdf    dc_bad_size
            call    percent_mb              ; RD = pct -> RD = MB
            lbr     dc_check
dc_mb_given:
            call    rest_blank
            lbnz    dc_bad_size
dc_check:
            ; MIN_MB <= RD <= max
            mov     rf, f_newmb
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            glo     rd
            smi     MIN_MB
            ghi     rd
            smbi    0
            lbnf    dc_bad_size
            mov     rf, f_maxmb+1
            glo     rd
            str     r2
            ldn     rf
            sm                              ; max - size
            dec     rf
            ghi     rd
            str     r2
            ldn     rf
            smb
            lbnf    dc_bad_size
            lbr     dc_make
dc_bad_size:
            call    K_INMSG
            db      "Enter a size from ",0
            ldi     MIN_MB + '0'
            call    K_TYPE
            call    K_INMSG
            db      " to ",0
            mov     rf, f_maxmb
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    print16
            call    K_INMSG
            db      " MB, or a percentage.",13,10,0
            lbr     dc_ask_size

dc_make:
            ; size in sectors = MB * 2048
            mov     rf, f_newmb
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_tmp
            call    set16
            ldi     11
            plo     rc
dc_mul:
            mov     rf, f_tmp
            call    shl32                   ; keeps RC
            dec     rc
            glo     rc
            lbnz    dc_mul

            ; active if no other partition already is
            ldi     0
            plo     rc
            ldi     0
            plo     r9                      ; R9.0 = an active one seen
dc_act_scan:
            glo     rc
            call    entry_addr              ; keeps RC, R9
            ldn     rf
            ani     $80
            lbz     dc_act_next
            ldi     1
            plo     r9
dc_act_next:
            inc     rc
            glo     rc
            smi     4
            lbnf    dc_act_scan
            glo     r9
            plo     rb                      ; RB.0 = 1 if one is active

            mov     rf, f_idx
            ldn     rf
            call    entry_addr              ; keeps RB
            glo     rb
            lbnz    dc_inactive
            ldi     $80
            lbr     dc_status
dc_inactive:
            ldi     0
dc_status:
            str     rf                      ; +0 status
            inc     rf
            ldi     $FE                     ; +1 CHS start: "use LBA"
            str     rf
            inc     rf
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            inc     rf
            ldi     PT_TYPE_FAT16           ; +4 type
            str     rf
            inc     rf
            ldi     $FE                     ; +5 CHS end: "use LBA"
            str     rf
            inc     rf
            ldi     $FF
            str     rf
            inc     rf
            str     rf
            inc     rf
            mov     rd, f_best_s            ; +8 start LBA, little-endian
            call    put_le32
            mov     rd, f_tmp               ; +12 sector count
            call    put_le32

            call    write_mbr
            lbdf    menu
            call    K_INMSG
            db      "Partition ",0
            call    print_idx
            call    K_INMSG
            db      " created (",0
            mov     rf, f_newmb
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    print16
            call    K_INMSG
            db      " MB).",13,10
            db      "Use MOUNT ",0
            call    print_unit
            ldi     ' '
            call    K_TYPE
            call    print_idx
            call    K_INMSG
            db      " <letter>: and then FORMAT to use it.",13,10,0
            lbr     menu

dc_abandon:
            call    load_table              ; drop any unwritten change
            lbr     menu

;==================================================================
; Display partition information
;==================================================================
display:
            call    K_INMSG
            db      13,10,"Unit ",0
            call    print_unit
            call    K_INMSG
            db      ":",13,10,0
            mov     rf, f_isvol
            ldn     rf
            lbz     dp_not_vol
            call    K_INMSG
            db      "A volume with no partition table (a whole-device disk).",13,10,0
            rtn
dp_not_vol:
            mov     rf, f_hastable
            ldn     rf
            lbnz    dp_table
            call    K_INMSG
            db      "No partition table.",13,10,0
            lbr     dp_size
dp_table:
            call    K_INMSG
            db      "Partition Status Type          Start LBA       Size  Mounted",13,10,0
            mov     rf, f_i
            ldi     0
            str     rf
            mov     rf, f_shown
            ldi     0
            str     rf
dp_loop:
            mov     rf, f_i
            ldn     rf
            call    type_of
            lbz     dp_next
            mov     rf, f_shown
            ldi     1
            str     rf
            call    K_INMSG
            db      "    ",0
            mov     rf, f_i
            ldn     rf
            adi     '1'
            call    K_TYPE
            call    K_INMSG
            db      "      ",0
            mov     rf, f_i
            ldn     rf
            call    entry_addr
            ldn     rf
            ani     $80
            lbz     dp_inact
            ldi     'A'
            lbr     dp_stat
dp_inact:
            ldi     ' '
dp_stat:
            call    K_TYPE
            call    K_INMSG
            db      "    ",0
            mov     rf, f_i
            ldn     rf
            call    type_of
            call    print_type              ; 11 columns
            mov     rf, f_i
            ldn     rf
            call    start_ptr
            ldi     12
            call    print32w
            mov     rf, f_i
            ldn     rf
            call    size_ptr
            call    mb32                    ; f_mbv = size in MB
            mov     rf, f_mbv
            ldi     8
            call    print32w
            call    K_INMSG
            db      " MB",0
            mov     rf, f_i
            ldn     rf
            call    mounted_letter
            lbz     dp_eol
            plo     rb
            mov     rf, f_letter
            glo     rb
            str     rf
            call    K_INMSG
            db      "  ",0
            mov     rf, f_letter
            ldn     rf
            call    K_TYPE
            ldi     ':'
            call    K_TYPE
dp_eol:
            call    K_INMSG
            db      13,10,0
dp_next:
            mov     rf, f_i
            ldn     rf
            adi     1
            str     rf
            smi     4
            lbnf    dp_loop
            mov     rf, f_shown
            ldn     rf
            lbnz    dp_size
            call    K_INMSG
            db      "No partitions defined.",13,10,0
dp_size:
            mov     rf, f_sizeknown
            ldn     rf
            lbnz    dp_known
            call    K_INMSG
            db      13,10,"Disk size unknown (FDISK asks for it when creating a partition).",13,10,0
            rtn
dp_known:
            call    K_INMSG
            db      13,10,"Total disk space is ",0
            call    disk_mb
            call    print16
            call    K_INMSG
            db      " MB; largest free block ",0
            call    find_free
            mov     rf, f_best_len
            call    mb_of
            call    print16
            call    K_INMSG
            db      " MB.",13,10,0
            rtn

;==================================================================
; Reading and writing the table
;==================================================================

;------------------------------------------------------------------
; load_unit: load_table, then ask the BIOS for the disk's size.
; Used when the unit changes; after a write only the table is reread,
; so a size typed in by hand is kept. DF=1 if sector 0 cannot be read.
;------------------------------------------------------------------
load_unit:
            call    load_table
            lbdf    lu_fail
            call    probe_size
            clc
lu_fail:
            rtn

;------------------------------------------------------------------
; probe_size: find the unit's size in MB by reading (see the header).
; Sets f_disk and f_sizeknown = 1; or leaves f_sizeknown = 0 with
; f_reachtop = 1 if every sector up to 8GB reads (cannot tell) or 0 if
; nothing past sector 0 did.
;------------------------------------------------------------------
probe_size:
            mov     rf, f_sizeknown
            ldi     0
            str     rf
            mov     rf, f_reachtop
            ldi     0
            str     rf
            mov     rd, MAX_DISK_MB         ; the very last sector
            call    probe_mb
            lbdf    ps_search
            mov     rf, f_reachtop
            ldi     1
            str     rf
            rtn
ps_search:
            ; invariant: megabyte lo reads (0 = only sector 0 known),
            ; megabyte hi does not
            mov     rf, f_lo
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, f_hi
            ldi     high MAX_DISK_MB
            str     rf
            inc     rf
            ldi     low MAX_DISK_MB
            str     rf
ps_loop:
            mov     rf, f_lo                ; RD = lo, R9 = hi
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, f_hi
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rb, r9                  ; done when hi - lo <= 1
            sub16   rb, rd
            ghi     rb
            lbnz    ps_mid
            glo     rb
            smi     2
            lbnf    ps_done
ps_mid:
            add16   rd, r9                  ; mid = (lo + hi) / 2
            shr16   rd
            mov     rf, f_mid
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            call    probe_mb
            lbdf    ps_bad
            mov     rf, f_lo                ; it reads: lo = mid
            lbr     ps_set
ps_bad:
            mov     rf, f_hi                ; it does not: hi = mid
ps_set:
            mov     rd, f_mid
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf
            lbr     ps_loop
ps_done:
            ghi     rd                      ; RD = lo
            str     r2
            glo     rd
            or
            lbz     ps_unknown              ; not even the first MB
            mov     rf, f_disk              ; f_disk = lo * 2048
            call    set16
            ldi     11
            plo     rc
ps_mul:
            mov     rf, f_disk
            call    shl32
            dec     rc
            glo     rc
            lbnz    ps_mul
            mov     rf, f_sizeknown
            ldi     1
            str     rf
ps_unknown:
            rtn

;------------------------------------------------------------------
; probe_mb: try to read the last sector of megabyte RD (1-8192), i.e.
; LBA RD*2048-1 = ((RD-1) << 11) + 2047. DF=0 if it reads.
;------------------------------------------------------------------
probe_mb:
            dec     rd                      ; RD = m - 1 (0-8191)
            glo     rd                      ; bits 15-8: ((m-1)&31)<<3 | 7
            ani     31
            shl
            shl
            shl
            ori     7
            phi     r7
            ldi     $FF                     ; bits 7-0
            plo     r7
            shr16   rd                      ; bits 23-16: (m-1) >> 5
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd
            glo     rd
            plo     r8
            mov     rf, f_unit
            ldn     rf
            phi     r8
            mov     rf, ver_buf
            lbr     K_SECREAD

;------------------------------------------------------------------
; load_table: read f_unit's sector 0 into mbr_buf, classify it and
; parse the four entries. DF=1 if sector 0 cannot be read.
;------------------------------------------------------------------
load_table:
            mov     rf, f_hastable
            ldi     0
            str     rf
            mov     rf, f_isvol
            ldi     0
            str     rf
            mov     rf, mbr_buf
            call    read_lba0
            lbnf    lu_read
            stc
            rtn
lu_read:
            ; $55 $AA at the end: a table, or a volume's boot sector
            mov     rf, mbr_buf+510
            lda     rf
            xri     $55
            lbnz    lu_parse                ; neither: blank or garbage
            ldn     rf
            xri     $AA
            lbnz    lu_parse
            ; a volume boot sector opens with a jump; a table does not
            mov     rf, mbr_buf
            ldn     rf
            xri     $EB
            lbz     lu_vol
            ldn     rf
            xri     $E9
            lbz     lu_vol
            mov     rf, f_hastable
            ldi     1
            str     rf
            lbr     lu_parse
lu_vol:
            mov     rf, f_isvol
            ldi     1
            str     rf
lu_parse:
            call    parse_entries
            clc
            rtn

;------------------------------------------------------------------
; parse_entries: p_start/p_end (4-byte big-endian) for each entry
; from mbr_buf. With no table every entry reads as unused.
;------------------------------------------------------------------
parse_entries:
            mov     rf, f_i
            ldi     0
            str     rf
pe_loop:
            mov     rf, f_hastable
            ldn     rf
            lbnz    pe_real
            mov     rf, f_i                 ; no table: type 0
            ldn     rf
            call    entry_addr
            add16   rf, 4
            ldi     0
            str     rf
pe_real:
            mov     rf, f_i
            ldn     rf
            call    entry_addr
            add16   rf, 8                   ; start, little-endian
            mov     rd, f_tmp
            call    get_le32
            mov     rf, f_i
            ldn     rf
            call    start_ptr
            mov     rd, rf
            mov     rf, f_tmp
            call    copy4
            mov     rf, f_i
            ldn     rf
            call    entry_addr
            add16   rf, 12                  ; sector count
            mov     rd, f_tmp2
            call    get_le32
            mov     rf, f_i
            ldn     rf
            call    size_ptr
            mov     rd, rf
            mov     rf, f_tmp2
            call    copy4
            ; end = start + count
            mov     rf, f_i
            ldn     rf
            call    end_ptr
            mov     rd, rf
            mov     rf, f_tmp
            call    copy4
            mov     rf, f_i
            ldn     rf
            call    end_ptr
            mov     rd, f_tmp2
            call    add32
            mov     rf, f_i
            ldn     rf
            adi     1
            str     rf
            smi     4
            lbnf    pe_loop
            rtn

;------------------------------------------------------------------
; new_table: an empty partition table in mbr_buf (memory only):
; zero boot code, zero entries, the $55 $AA signature.
;------------------------------------------------------------------
new_table:
            mov     rf, mbr_buf
            call    zero_sector
            mov     rf, mbr_buf+510
            ldi     $55
            str     rf
            inc     rf
            ldi     $AA
            str     rf
            mov     rf, f_hastable
            ldi     1
            str     rf
            mov     rf, f_isvol
            ldi     0
            str     rf
            lbr     parse_entries

;------------------------------------------------------------------
; write_mbr: write mbr_buf to sector 0, read it back and compare, then
; reparse. DF=1 (message printed) on failure.
;------------------------------------------------------------------
write_mbr:
            mov     rf, f_unit
            ldn     rf
            phi     r8
            ldi     0
            plo     r8
            plo     r7
            phi     r7
            mov     rf, mbr_buf
            call    K_SECWRITE
            lbdf    wm_error
            mov     rf, ver_buf
            call    read_lba0
            lbdf    wm_error
            mov     rf, mbr_buf
            mov     rd, ver_buf
            mov     rc, 512
wm_cmp:
            lda     rd
            str     r2
            lda     rf
            sm
            lbnz    wm_error
            dec     rc
            glo     rc
            lbnz    wm_cmp
            ghi     rc
            lbnz    wm_cmp
            call    load_table
            clc
            rtn
wm_error:
            call    K_INMSG
            db      "Error writing the partition table of unit ",0
            call    print_unit
            call    K_INMSG
            db      ".",13,10,0
            call    load_table              ; show what is really there
            stc
            rtn

;------------------------------------------------------------------
; read_lba0: read f_unit's sector 0 into the buffer at RF. DF=1 on error.
;------------------------------------------------------------------
read_lba0:
            mov     rd, rf                  ; keep the buffer
            mov     rf, f_unit
            ldn     rf
            phi     r8
            ldi     0
            plo     r8
            plo     r7
            phi     r7
            mov     rf, rd
            lbr     K_SECREAD

unit_error:
            call    K_INMSG
            db      "Cannot read unit ",0
            call    print_unit
            call    K_INMSG
            db      ".",13,10,0
            rtn

;==================================================================
; Questions
;==================================================================

;------------------------------------------------------------------
; need_table: DF=1 (message printed) if there is no partition table
;------------------------------------------------------------------
need_table:
            mov     rf, f_hastable
            ldn     rf
            lbz     nt_none
            clc
            rtn
nt_none:
            call    K_INMSG
            db      "Unit ",0
            call    print_unit
            call    K_INMSG
            db      " has no partition table.",13,10,0
            stc
            rtn

;------------------------------------------------------------------
; need_size: make sure f_disk is known, asking if the BIOS could not
; say. DF=1 if the question was abandoned (end of input).
;------------------------------------------------------------------
need_size:
            mov     rf, f_sizeknown
            ldn     rf
            lbz     ns_ask
            clc
            rtn
ns_ask:
            mov     rf, f_reachtop
            ldn     rf
            lbz     ns_ask_plain
            call    K_INMSG
            db      "Every sector of unit ",0
            call    print_unit
            call    K_INMSG
            db      " up to the 8GB limit reads. It is either 8GB or larger,",13,10
            db      "or this BIOS does not report reads past the end of a disk.",13,10
            db      "Enter its size in MB [8192]: ",0
            call    read_answer
            lbdf    ns_eof
            call    first_char
            lbnz    ns_parse
            mov     rd, MAX_DISK_MB         ; Enter: 8GB
            lbr     ns_have
ns_ask_plain:
            call    K_INMSG
            db      "FDISK could not find the size of unit ",0
            call    print_unit
            call    K_INMSG
            db      ".",13,10,"Enter its size in MB: ",0
            call    read_answer
            lbdf    ns_eof
ns_parse:
            call    parse_number
            lbdf    ns_bad
            call    rest_blank
            lbnz    ns_bad
            ghi     rd                      ; 1 to MAX_DISK_MB
            str     r2
            glo     rd
            or
            lbz     ns_bad
            glo     rd
            smi     low (MAX_DISK_MB+1)
            ghi     rd
            smbi    high (MAX_DISK_MB+1)
            lbdf    ns_bad
ns_have:
            mov     rf, f_disk
            call    set16
            ldi     11
            plo     rc
ns_mul:
            mov     rf, f_disk
            call    shl32
            dec     rc
            glo     rc
            lbnz    ns_mul
            mov     rf, f_sizeknown
            ldi     1
            str     rf
            clc
            rtn
ns_bad:
            call    K_INMSG
            db      "Enter a size from 1 to 8192 MB.",13,10,0
            lbr     ns_ask
ns_eof:
            stc
            rtn

;------------------------------------------------------------------
; ask_partition: read a partition number 1-4 naming a USED entry.
; Returns D = index 0-3, DF=0; DF=1 (message printed) otherwise.
;------------------------------------------------------------------
ask_partition:
            call    read_answer
            lbdf    ap_none
            call    parse_number
            lbdf    ap_bad
            call    rest_blank
            lbnz    ap_bad
            ghi     rd
            lbnz    ap_bad
            glo     rd
            lbz     ap_bad
            smi     5
            lbdf    ap_bad
            glo     rd
            smi     1
            plo     rb
            call    type_of                 ; keeps RB
            lbz     ap_unused
            glo     rb
            clc
            rtn
ap_unused:
            call    K_INMSG
            db      "That partition does not exist.",13,10,0
            stc
            rtn
ap_bad:
            call    K_INMSG
            db      "Enter a partition number, 1-4.",13,10,0
ap_none:
            stc
            rtn

;------------------------------------------------------------------
; ask_yes: read a Y/N answer. DF=0 for Y; DF=1 for N or end of input.
; Anything else asks again.
;------------------------------------------------------------------
ask_yes:
            call    read_answer
            lbdf    ay_no
            call    first_char
            plo     rb
            xri     'Y'
            lbz     ay_check
            glo     rb
            xri     'N'
            lbz     ay_checkn
            call    K_INMSG
            db      "Please answer Y or N: ",0
            lbr     ask_yes
ay_check:
            inc     rf
            call    rest_blank
            lbnz    ay_retry
            clc
            rtn
ay_checkn:
            inc     rf
            call    rest_blank
            lbnz    ay_retry
ay_no:
            stc
            rtn
ay_retry:
            call    K_INMSG
            db      "Please answer Y or N: ",0
            lbr     ask_yes

;------------------------------------------------------------------
; read_answer: a line into f_inbuf, then a newline (the line editor
; echoes none). Redirect-aware. DF=1 at end of redirected input.
;------------------------------------------------------------------
read_answer:
            mov     rf, f_inbuf
            ldi     INBUF_MAX
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

;==================================================================
; Text parsing (f_inbuf). Leaf routines.
;==================================================================

;------------------------------------------------------------------
; first_char: RF -> the first non-space character of f_inbuf; D = it,
; with a-z folded to upper case (0 at end of line).
;------------------------------------------------------------------
first_char:
            mov     rf, f_inbuf
fc_loop:
            ldn     rf
            xri     ' '
            lbnz    fc_have
            inc     rf
            lbr     fc_loop
fc_have:
            ldn     rf
            smi     'a'
            lbnf    fc_plain
            ldn     rf
            smi     'z'+1
            lbdf    fc_plain
            ldn     rf
            ani     $DF
            rtn
fc_plain:
            ldn     rf
            rtn

;------------------------------------------------------------------
; rest_blank: D = 0 if [RF] holds nothing but spaces to the end
;------------------------------------------------------------------
rest_blank:
            lda     rf
            lbz     rb_yes
            xri     ' '
            lbz     rest_blank
            ldi     1
            rtn
rb_yes:
            ldi     0
            rtn

;------------------------------------------------------------------
; parse_number: a decimal number of 1-4 digits after optional spaces,
; starting at f_inbuf. RD = the value, RF = the first character after
; it; DF=1 if there is no number or more than 4 digits.
; Modifies R9, RC, RD, RF, D
;------------------------------------------------------------------
parse_number:
            call    first_char
            ldi     0
            phi     rd
            plo     rd
            plo     rc                      ; RC.0 = digits
pn_loop:
            ldn     rf
            smi     '0'
            lbnf    pn_end
            smi     10
            lbdf    pn_end
            glo     rc
            xri     4
            lbz     pn_bad                  ; a fifth digit
            inc     rc
            mov     r9, rd                  ; RD = RD*10 + digit
            shl16   r9                      ; R9 = RD*2
            shl16   rd
            shl16   rd
            shl16   rd                      ; RD = RD*8
            add16   rd, r9
            lda     rf
            smi     '0'
            str     r2
            glo     rd
            add
            plo     rd
            ghi     rd
            adci    0
            phi     rd
            lbr     pn_loop
pn_end:
            glo     rc
            lbz     pn_bad
            clc
            rtn
pn_bad:
            stc
            rtn

;==================================================================
; Arithmetic on the table
;==================================================================

;------------------------------------------------------------------
; find_free: the largest free block, aligned to 1MB, never below
; sector 2048 and never past f_disk. f_best_s = its start, f_best_len
; = its length in sectors (0 if none).
;
; Candidate starts are sector 2048 and the end of every partition, each
; rounded up to a 1MB boundary; a candidate inside a partition is
; skipped, and each runs to the next partition start or the disk's end.
;------------------------------------------------------------------
find_free:
            mov     rf, f_best_len
            call    zero4bytes
            mov     rf, f_best_s
            call    zero4bytes
            mov     rf, f_c
            ldi     0
            str     rf
ff_cand:
            mov     rf, f_c
            ldn     rf
            xri     4
            lbnz    ff_part
            mov     rf, f_s                 ; candidate 4: sector 2048
            mov     rd, c_2048
            call    copy4_from
            lbr     ff_align
ff_part:
            mov     rf, f_c
            ldn     rf
            call    type_of
            lbz     ff_next
            mov     rf, f_c
            ldn     rf
            call    end_ptr
            mov     rd, rf
            mov     rf, f_s
            call    copy4_from
ff_align:
            ; round up to a 1MB boundary
            mov     rf, f_s
            mov     rd, c_2047
            call    add32
            mov     rf, f_s+3
            ldi     0
            str     rf
            dec     rf
            ldn     rf
            ani     $F8
            str     rf
            ; and to the reserved area's end, for a partition ending
            ; below sector 2048
            mov     rf, f_s
            mov     rd, c_2048
            call    ge32
            lbdf    ff_min_ok
            mov     rf, f_s
            mov     rd, c_2048
            call    copy4_from
ff_min_ok:
            ; past the end of the disk?
            mov     rf, f_s
            mov     rd, f_disk
            call    ge32
            lbdf    ff_next
            ; inside a partition?
            mov     rf, f_j
            ldi     0
            str     rf
ff_in:
            mov     rf, f_j
            ldn     rf
            call    type_of
            lbz     ff_in_next
            mov     rf, f_j
            ldn     rf
            call    start_ptr
            mov     rd, rf
            mov     rf, f_s
            call    ge32                    ; s >= start ?
            lbnf    ff_in_next
            mov     rf, f_j
            ldn     rf
            call    end_ptr
            mov     rd, rf
            mov     rf, f_s
            call    ge32                    ; s >= end ?
            lbnf    ff_next                 ; no: s is inside
ff_in_next:
            mov     rf, f_j
            ldn     rf
            adi     1
            str     rf
            smi     4
            lbnf    ff_in
            ; the block ends at the nearest start at or above s
            mov     rf, f_e
            mov     rd, f_disk
            call    copy4_from
            mov     rf, f_j
            ldi     0
            str     rf
ff_end:
            mov     rf, f_j
            ldn     rf
            call    type_of
            lbz     ff_end_next
            mov     rf, f_j
            ldn     rf
            call    start_ptr               ; start >= s ?
            mov     rd, f_s
            call    ge32
            lbnf    ff_end_next
            mov     rf, f_j
            ldn     rf
            call    start_ptr               ; start < e ?
            mov     rd, f_e
            call    ge32
            lbdf    ff_end_next
            mov     rf, f_j
            ldn     rf
            call    start_ptr
            mov     rd, rf
            mov     rf, f_e
            call    copy4_from
ff_end_next:
            mov     rf, f_j
            ldn     rf
            adi     1
            str     rf
            smi     4
            lbnf    ff_end
            ; len = e - s; keep it if it beats the best so far
            mov     rf, f_len
            mov     rd, f_e
            call    copy4_from
            mov     rf, f_len
            mov     rd, f_s
            call    sub32
            mov     rf, f_best_len
            mov     rd, f_len
            call    ge32                    ; best >= len ?
            lbdf    ff_next
            mov     rf, f_best_len
            mov     rd, f_len
            call    copy4_from
            mov     rf, f_best_s
            mov     rd, f_s
            call    copy4_from
ff_next:
            mov     rf, f_c
            ldn     rf
            adi     1
            str     rf
            smi     5
            lbnf    ff_cand
            rtn

;------------------------------------------------------------------
; percent_mb: RD = a percentage 1-100 -> RD = that share of the disk,
; in MB (disk_mb * pct / 100, rounded down).
;------------------------------------------------------------------
percent_mb:
            glo     rd
            plo     rc                      ; RC.0 = pct
            call    disk_mb                 ; RD = disk MB (keeps RC)
            mov     rf, f_k
            call    set16
            mov     rf, f_tmp
            call    zero4bytes
pm_mul:
            mov     rf, f_tmp               ; tmp += disk_mb, pct times
            mov     rd, f_k
            call    add32                   ; (keeps RC)
            dec     rc
            glo     rc
            lbnz    pm_mul
            ; divide by 100 by repeated subtraction (at most 8192 times)
            ldi     0
            phi     r9
            plo     r9                      ; R9 = quotient
pm_div:
            mov     rf, f_tmp
            mov     rd, c_100
            call    ge32                    ; (keeps R9)
            lbnf    pm_done
            mov     rf, f_tmp
            mov     rd, c_100
            call    sub32
            inc     r9
            lbr     pm_div
pm_done:
            mov     rd, r9
            rtn

;------------------------------------------------------------------
; disk_mb: RD = f_disk in MB. mb_of: RD = [RF] (sectors) in MB.
; Both keep RB, RC, R9.
;------------------------------------------------------------------
disk_mb:
            mov     rf, f_disk
mb_of:
            ; Only ever given a disk size or a free block, both at most
            ; 2^24 sectors (8192 MB). The top byte is therefore set only
            ; for exactly 2^24, whose bytes below it are all zero.
            ; BUG FIX: this used to ignore the top byte, so an 8GB disk
            ; (the size offered when every read succeeds) showed 0 MB.
            lda     rf                      ; bits 31-24
            lbnz    mb_8gb
            lda     rf                      ; sectors >> 8 ...
            phi     rd
            lda     rf
            plo     rd
            shr16   rd                      ; ... >> 3 more = >> 11
            shr16   rd
            shr16   rd
            rtn
mb_8gb:
            ldi     high MAX_DISK_MB
            phi     rd
            ldi     low MAX_DISK_MB
            plo     rd
            rtn

;------------------------------------------------------------------
; ge32: DF = 1 if the 4-byte big-endian [RF] >= [RD], else 0.
; Leaves both values alone. Modifies R7, R8, D.
;------------------------------------------------------------------
ge32:
            mov     r7, rf
            inc     r7
            inc     r7
            inc     r7
            mov     r8, rd
            inc     r8
            inc     r8
            inc     r8
            ldn     r8
            str     r2
            ldn     r7
            sm
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            dec     r7
            dec     r8
            ldn     r8
            str     r2
            ldn     r7
            smb
            rtn

;==================================================================
; The table in memory
;==================================================================

;------------------------------------------------------------------
; entry_addr: RF = mbr_buf + PT_OFF + D*16. Keeps RB, RC, R9.
;------------------------------------------------------------------
entry_addr:
            shl
            shl
            shl
            shl
            adi     low (mbr_buf + PT_OFF)
            plo     rf
            ldi     high (mbr_buf + PT_OFF)
            adci    0
            phi     rf
            rtn

;------------------------------------------------------------------
; type_of: D = entry D's type byte (0 = unused). Keeps RB, RC, R9.
;------------------------------------------------------------------
type_of:
            call    entry_addr
            inc     rf
            inc     rf
            inc     rf
            inc     rf
            ldn     rf
            rtn

;------------------------------------------------------------------
; start_ptr / size_ptr / end_ptr: RF = &p_start[D] etc., 4-byte
; big-endian values filled by parse_entries. Keep RB, RC, R9.
;------------------------------------------------------------------
start_ptr:
            shl
            shl
            adi     low p_start
            plo     rf
            ldi     high p_start
            adci    0
            phi     rf
            rtn
size_ptr:
            shl
            shl
            adi     low p_size
            plo     rf
            ldi     high p_size
            adci    0
            phi     rf
            rtn
end_ptr:
            shl
            shl
            adi     low p_end
            plo     rf
            ldi     high p_end
            adci    0
            phi     rf
            rtn

;------------------------------------------------------------------
; mounted_letter: D = the letter of a mounted drive on this unit whose
; partition starts where entry D does (D = 4 means start LBA 0, a
; whole-device volume), or 0 if none.
;------------------------------------------------------------------
mounted_letter:
            plo     rb
            mov     rf, f_want
            ldi     0
            str     rf
            inc     rf
            str     rf
            inc     rf
            str     rf
            glo     rb
            xri     4
            lbz     ml_have_want
            glo     rb
            call    start_ptr
            ldn     rf                      ; above 24 bits: never mounted
            lbnz    ml_none
            inc     rf
            mov     rd, f_want
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
ml_have_want:
            mov     rf, f_j
            ldi     0
            str     rf
ml_loop:
            mov     rf, f_j                 ; a lettered slot?
            ldn     rf
            call    letter_addr
            ldn     rf
            lbz     ml_next
            mov     rf, f_j
            ldn     rf
            call    bpb_addr                ; RF = drive_bpb_table[j]
            mov     rd, f_want
            ldi     3
            plo     rc
ml_cmp:
            lda     rd
            str     r2
            lda     rf
            sm
            lbnz    ml_next
            dec     rc
            glo     rc
            lbnz    ml_cmp
            add16   rf, BPBBLK_DEV - 3
            ldn     rf
            str     r2
            mov     rf, f_unit
            ldn     rf
            sm
            lbnz    ml_next
            mov     rf, f_j                 ; found: its letter
            ldn     rf
            call    letter_addr
            ldn     rf
            rtn
ml_next:
            mov     rf, f_j
            ldn     rf
            adi     1
            str     rf
            smi     DRIVE_COUNT
            lbnf    ml_loop
ml_none:
            ldi     0
            rtn

;------------------------------------------------------------------
; letter_addr / bpb_addr: RF = &drive_letter[D] / &drive_bpb_table[D]
; Modify R9, RB, RC, RD, RF, D
;------------------------------------------------------------------
letter_addr:
            plo     rd
            ldi     0
            phi     rd
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            add16   rf, DRIVE_LETTER_OFF
            add16   rf, rd
            rtn
bpb_addr:
            plo     rd
            ldi     0
            phi     rb
            plo     rb
            glo     rd
            lbz     ba_have
            plo     rc
ba_mul:
            add16   rb, BPBBLK_LEN
            dec     rc
            glo     rc
            lbnz    ba_mul
ba_have:
            mov     rf, DRIVE_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            add16   rf, DRIVE_BPB_TABLE_OFF
            add16   rf, rb
            rtn

;==================================================================
; Small helpers
;==================================================================

;------------------------------------------------------------------
; copy4 / copy4_from: 4 bytes. copy4: [RF] -> [RD]. copy4_from:
; [RD] -> [RF]. Modify RD, RF, D.
;------------------------------------------------------------------
copy4_from:
            glo     rf                      ; swap RF and RD
            plo     r7
            ghi     rf
            phi     r7
            mov     rf, rd
            mov     rd, r7
copy4:
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            rtn

;------------------------------------------------------------------
; set16: [RF] = RD, zero-extended to 4 bytes. Modifies RF, D.
;------------------------------------------------------------------
set16:
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
; is_zero: D = OR of the 4 bytes at RF. Modifies RF, D.
;------------------------------------------------------------------
is_zero:
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
; get_le32: 4 little-endian bytes at RF -> big-endian at RD.
; put_le32: 4-byte big-endian [RD] -> little-endian at RF, RF advanced.
; Both modify RD, RF, D.
;------------------------------------------------------------------
get_le32:
            inc     rd
            inc     rd
            inc     rd
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
            rtn
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
            inc     rf
            rtn

;------------------------------------------------------------------
; zero_sector: 512 zero bytes at RF. Modifies RC, RF, D.
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
; Output
;==================================================================
print_unit:
            mov     rf, f_unit
            ldn     rf
            adi     '0'
            lbr     K_TYPE

print_idx:
            mov     rf, f_idx
            ldn     rf
            adi     '1'
            lbr     K_TYPE

;------------------------------------------------------------------
; print_mb: the sector count at [RF], in MB. print16: RD, in decimal.
;------------------------------------------------------------------
print_mb:
            call    mb32
            mov     rf, f_mbv
            ldi     0
            lbr     print32w
print16:
            mov     rf, f_p16
            call    set16
            mov     rf, f_p16
            ldi     0
            lbr     print32w

;------------------------------------------------------------------
; mb32: f_mbv = the 4-byte sector count at [RF] >> 11, in full 32 bits
; (display only: a foreign table can hold sizes past 8GB).
; Modifies RD, RF, D
;------------------------------------------------------------------
mb32:
            mov     rd, f_mbv               ; >> 8: move the bytes down
            ldi     0
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            ldi     3                       ; >> 3
            plo     rc
m32_sh:
            mov     rf, f_mbv
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
            dec     rc
            glo     rc
            lbnz    m32_sh
            rtn

;------------------------------------------------------------------
; print32w: the 4-byte big-endian value at RF, with thousands commas,
; right-justified in D columns (0 = no padding).
;------------------------------------------------------------------
print32w:
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
            plo     r8
            mov     rf, f_numbuf
            call    fmt_size32
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
            sm
            lbnf    p32_out
            str     rf
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

;------------------------------------------------------------------
; print_type: a name for partition type D, padded to 11 columns
;------------------------------------------------------------------
print_type:
            plo     rb
            mov     rf, type_names
pt_scan:
            lda     rf                      ; type byte, 0 ends the table
            lbz     pt_other
            str     r2
            glo     rb
            sm
            lbz     pt_found
            add16   rf, 12                  ; skip this name and its NUL
            lbr     pt_scan
pt_found:
            lbr     K_MSG                   ; the 11-column name
pt_other:
            call    K_INMSG
            db      "Type ",0
            mov     rf, f_hexbuf
            glo     rb
            call    hex_byte
            ldi     0
            str     rf
            mov     rf, f_hexbuf
            call    K_MSG
            call    K_INMSG
            db      "    ",0
            rtn

;------------------------------------------------------------------
; hex_byte: two hex digits of D at [RF], RF advanced. Leaf.
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
; Constants
;==================================================================
c_100:          db      0,0,0,100
c_2047:         db      0,0,$07,$FF
c_2048:         db      0,0,$08,$00

; type byte, then an 11-column name and its NUL
type_names:
            db      $01,"FAT12      ",0
            db      $04,"FAT16      ",0
            db      $06,"FAT16      ",0
            db      $0E,"FAT16      ",0
            db      $0B,"FAT32      ",0
            db      $0C,"FAT32      ",0
            db      $05,"Extended   ",0
            db      $0F,"Extended   ",0
            db      $07,"NTFS       ",0
            db      $83,"Linux      ",0
            db      0

;==================================================================
; Data
;==================================================================
f_unit:         db      0
f_oldunit:      db      0
f_hastable:     db      0           ; sector 0 holds a partition table
f_isvol:        db      0           ; sector 0 is a volume boot sector
f_sizeknown:    db      0
f_reachtop:     db      0           ; the probe read all the way to 8GB
f_lo:           dw      0           ; probe_size's search bounds, in MB
f_hi:           dw      0
f_mid:          dw      0
f_disk:         ds      4           ; the unit's size in sectors
f_idx:          db      0           ; the partition being worked on
f_letter:       db      0
f_i:            db      0
f_j:            db      0
f_c:            db      0
f_shown:        db      0
f_maxmb:        dw      0
f_newmb:        dw      0
f_want:         ds      3           ; a start LBA, as the BPB block has it
f_s:            ds      4
f_e:            ds      4
f_len:          ds      4
f_best_s:       ds      4
f_best_len:     ds      4
f_tmp:          ds      4
f_tmp2:         ds      4
f_k:            ds      4
f_width:        db      0
f_p16:          ds      4
f_mbv:          ds      4
f_numbuf:       ds      14
f_hexbuf:       ds      3
f_inbuf:        ds      INBUF_MAX+1
p_start:        ds      16          ; per entry: start LBA
p_size:         ds      16          ; per entry: sector count
p_end:          ds      16          ; per entry: start + count
mbr_buf:        ds      512
ver_buf:        ds      512
