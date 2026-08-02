;
; corrupt.asm - deliberately corrupt a FAT16 volume in controlled,
; specific ways, to test CHKDSK against real, known corruption
; scenarios (and cross-check against fsck.fat's own detection/repair
; of the same scenarios).
;
; Usage: CORRUPT <mode> <args...>
;
; Always operates on the CURRENT directory (K_GETCURDIR) -- no path
; support, no wildcards. Filenames must already be typed in uppercase,
; already-valid 8.3 form (e.g. TEST1.TXT, up to 8 name characters and
; 3 extension characters) -- this tool does no case-folding and no LFN
; handling, only a raw 11-byte short-name compare, matching exactly
; what CHKDSK's own duplicate-short-name check looks at.
;
; Modes (all mode/keyword arguments are case-sensitive, must be typed
; in UPPERCASE):
;
;   CORRUPT SIZE <name> <newsize>
;       Rewrite <name>'s own directory-entry size field directly,
;       without touching its real cluster chain -- creates a file
;       size/cluster-chain-length mismatch. <newsize> is a plain
;       decimal byte count.
;
;   CORRUPT LOST <name>
;       Mark <name>'s own directory entry deleted ($E5) but leave its
;       FAT chain fully allocated and untouched -- every cluster that
;       chain used becomes a lost cluster (allocated, but no directory
;       entry references it any more).
;
;   CORRUPT XLINK <nameA> <nameB>
;       Point <nameB>'s own first cluster at <nameA>'s first cluster
;       -- both files now share (at least) that one cluster, a
;       cross-link.
;
;   CORRUPT DUPNAME <nameA> <nameB>
;       Overwrite <nameB>'s own raw 11-byte short name with <nameA>'s
;       -- both directory entries now carry the identical short name
;       (their own cluster/size fields are untouched), a duplicate
;       directory entry.
;
;   CORRUPT TRUNC <name> <hops>
;       Walk <name>'s cluster chain <hops> hops from its own first
;       cluster (hops=0 means the first cluster itself), then mark
;       that cluster's own FAT entry end-of-chain ($FFF8) -- the chain
;       is now shorter than the directory entry's own recorded size
;       claims, the exact shape of this project's own real >64K bug
;       history and of fsck.fat's own "cluster chain length is N
;       bytes, truncating" report.
;
;   CORRUPT BADSECTOR <name> <hops>
;       Same walk as TRUNC, but marks the target cluster's own FAT
;       entry as a bad-sector marker ($FFF7) instead of end-of-chain.
;
; IMPORTANT -- reboot before running CHKDSK (or fsck) after using this
; tool. The kernel keeps an in-RAM FAT-sector cache (kernel/fat.asm's
; fat_csec) that this tool's own raw K_SECREAD/K_SECWRITE writes
; bypass entirely -- if a later, unrelated file operation in the SAME
; boot session happens to flush a stale cached copy of the exact
; sector this tool just corrupted, it could silently overwrite the
; injected corruption with the original, correct value before CHKDSK
; (or anything else) ever sees it. This is the identical reboot-first
; caution CHKDSK's own deferred -f fix mode already documents needing,
; for the same reason.
;
; DANGEROUS BY DESIGN -- this tool intentionally corrupts real on-disk
; structures via K_SECREAD/K_SECWRITE (see kernel_api.inc's own
; warning on those two primitives: "a wrong LBA can silently corrupt
; the running filesystem or the boot sectors themselves"). Use only on
; a disposable test volume/directory you don't mind losing, never on
; anything you can't afford to re-flash from a backup.
;
; Zero kernel changes -- built entirely on the existing K_GETCURDIR/
; K_SECREAD/K_SECWRITE/BPB_DATA_PTR/f_strcmp primitives, plus
; lib/ymodem.asm's already-proven ym_parse_uint32 for the decimal
; arguments. The BPB read, cluster-to-LBA conversion, FAT-entry read,
; and raw directory-sector-walk routines below are hand-traced copies
; of progs/chkdsk.asm's own already-independently-verified equivalents
; (chk_read_bpb/chk_cluster_to_lba/chk_fat_read/chk_read_next_dir_sector/
; chk_lba_inc), reused rather than re-derived, per this project's own
; standing practice. No hardware or emulator access exists in this
; environment -- build-verified only, to be exercised for the first
; time by the exact CHKDSK/fsck comparison this tool exists to enable.
;
; This is a flat file (no proc/endp) -- gotcha #20 (a bare top-level
; label between proc/endp blocks corrupting the linked base address)
; does not apply here.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   ym_parse_uint32

; ---- raw on-disk constants (kernel.inc is not includable from progs/) ----
DE_NAME:        equ     0           ; 11 bytes, space-padded
DE_ATTR:        equ     11          ; 1 byte
DE_CLUSTER:     equ     26          ; 2 bytes, LE
DE_SIZE:        equ     28          ; 4 bytes, LE
DIR_ENT_SIZE:   equ     32

ATTR_LFN:       equ     $0F
ATTR_VOLID:     equ     $08

FAT_EOC:        equ     $FFF8
FAT_BAD:        equ     $FFF7

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

start:
            ; argc must be >= 2 (mode word present) for anything below
            ; to be worth reading at all
            ghi     rc
            lbnz    have_argc
            glo     rc
            smi     2
            lbnf    usage
have_argc:
            call    crp_argv1           ; RF = argv[1] (mode string)
            mov     r9, rf              ; stash across the read_bpb/
                                        ; getcurdir calls below

            call    crp_read_bpb

            call    K_GETCURDIR         ; RD = active drive's cur dir
                                        ; cluster (0 = root)
            mov     rf, crp_parent
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, r9              ; RF = mode string again
            mov     rd, crp_mode_size
            call    f_strcmp
            lbz     mode_size

            mov     rf, r9
            mov     rd, crp_mode_lost
            call    f_strcmp
            lbz     mode_lost

            mov     rf, r9
            mov     rd, crp_mode_xlink
            call    f_strcmp
            lbz     mode_xlink

            mov     rf, r9
            mov     rd, crp_mode_dupname
            call    f_strcmp
            lbz     mode_dupname

            mov     rf, r9
            mov     rd, crp_mode_trunc
            call    f_strcmp
            lbz     mode_trunc

            mov     rf, r9
            mov     rd, crp_mode_badsector
            call    f_strcmp
            lbz     mode_badsector

usage:
            call    K_INMSG
            db      "Usage: CORRUPT <mode> <args...>",13,10
            db      "  SIZE <name> <newsize>",13,10
            db      "  LOST <name>",13,10
            db      "  XLINK <nameA> <nameB>",13,10
            db      "  DUPNAME <nameA> <nameB>",13,10
            db      "  TRUNC <name> <hops>",13,10
            db      "  BADSECTOR <name> <hops>",13,10
            db      "Reboot before running CHKDSK/fsck afterward.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; mode_size: CORRUPT SIZE <name> <newsize>
;------------------------------------------------------------------
mode_size:
            ghi     rc
            lbnz    ms_argc_ok
            glo     rc
            smi     4
            lbnf    usage
ms_argc_ok:
            call    crp_argv2
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            call    crp_argv3           ; RF = argv[3] (decimal size)
            call    ym_parse_uint32     ; RD:R8 = value (hi:lo)

            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = byte offset into secbuf
            mov     rf, crp_secbuf
            add16   rf, r9
            add16   rf, DE_SIZE         ; RF -> the 4-byte size field

            ; DE_SIZE is little-endian on disk: [lsb of R8, msb of R8,
            ; lsb of RD, msb of RD]
            glo     r8
            str     rf
            inc     rf
            ghi     r8
            str     rf
            inc     rf
            glo     rd
            str     rf
            inc     rf
            ghi     rd
            str     rf

            call    crp_write_found_sector
            lbdf    err_io

            call    K_INMSG
            db      "Size field rewritten.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; mode_lost: CORRUPT LOST <name>
;------------------------------------------------------------------
mode_lost:
            ghi     rc
            lbnz    ml_argc_ok
            glo     rc
            smi     3
            lbnf    usage
ml_argc_ok:
            call    crp_argv2
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9              ; RF -> the entry's own first byte
            ldi     $E5
            str     rf

            call    crp_write_found_sector
            lbdf    err_io

            call    K_INMSG
            db      "Directory entry marked deleted -- its own cluster",13,10
            db      "chain is now lost.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; mode_xlink: CORRUPT XLINK <nameA> <nameB>
;------------------------------------------------------------------
mode_xlink:
            ghi     rc
            lbnz    mx_argc_ok
            glo     rc
            smi     4
            lbnf    usage
mx_argc_ok:
            call    crp_argv2           ; RF = nameA
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            ; capture nameA's own DE_CLUSTER (2 bytes) before the
            ; second crp_find call overwrites crp_secbuf/crp_found_*
            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9
            add16   rf, DE_CLUSTER
            lda     rf
            plo     rb
            ldn     rf
            phi     rb                  ; RB = nameA's own low:high
                                        ; cluster bytes, ON-DISK order
                                        ; (low byte first) -- kept as
                                        ; two raw bytes, not a real
                                        ; 16-bit value, so no byte-
                                        ; order confusion below
            mov     rf, crp_saved
            glo     rb
            str     rf
            inc     rf
            ghi     rb
            str     rf                  ; crp_saved[0..1] = nameA's
                                        ; raw on-disk DE_CLUSTER bytes

            call    crp_argv3           ; RF = nameB
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9
            add16   rf, DE_CLUSTER      ; RF -> nameB's own DE_CLUSTER

            mov     r8, crp_saved
            lda     r8
            str     rf
            inc     rf
            ldn     r8
            str     rf

            call    crp_write_found_sector
            lbdf    err_io

            call    K_INMSG
            db      "nameB's own first cluster now matches nameA's --",13,10
            db      "the two files are cross-linked.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; mode_dupname: CORRUPT DUPNAME <nameA> <nameB>
;------------------------------------------------------------------
mode_dupname:
            ghi     rc
            lbnz    md_argc_ok
            glo     rc
            smi     4
            lbnf    usage
md_argc_ok:
            call    crp_argv2           ; RF = nameA
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            ; capture nameA's own raw 11-byte DE_NAME before the
            ; second crp_find call overwrites crp_secbuf/crp_found_*
            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9              ; RF -> nameA's own entry start
                                        ; (DE_NAME is offset 0)
            mov     rb, crp_saved
            ldi     11
            plo     r8
dn_save_loop:
            lda     rf
            str     rb
            inc     rb
            dec     r8
            glo     r8
            lbnz    dn_save_loop

            call    crp_argv3           ; RF = nameB
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9              ; RF -> nameB's own entry start

            mov     rb, crp_saved
            ldi     11
            plo     r8
dn_copy_loop:
            lda     rb
            str     rf
            inc     rf
            dec     r8
            glo     r8
            lbnz    dn_copy_loop

            call    crp_write_found_sector
            lbdf    err_io

            call    K_INMSG
            db      "nameB's own short name now matches nameA's --",13,10
            db      "the directory has a duplicate entry.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; mode_trunc / mode_badsector: share everything except the final
; FAT-entry value written.
;------------------------------------------------------------------
mode_trunc:
            ldi     0
            plo     rb
            lbr     do_trunc_common

mode_badsector:
            ldi     1
            plo     rb

do_trunc_common:
            mov     rf, crp_trunc_is_badsector
            glo     rb
            str     rf                  ; 0 = TRUNC (write EOC), 1 =
                                        ; BADSECTOR (write $FFF7)

            ghi     rc
            lbnz    mt_argc_ok
            glo     rc
            smi     4
            lbnf    usage
mt_argc_ok:
            call    crp_argv2           ; RF = name
            call    crp_pack_name
            call    crp_find
            lbdf    err_not_found

            ; capture the file's own starting cluster (DE_CLUSTER)
            mov     rf, crp_found_off
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, crp_secbuf
            add16   rf, r9
            add16   rf, DE_CLUSTER
            lda     rf                  ; D = low byte (on-disk LE)
            plo     rd
            ldn     rf                  ; D = high byte
            phi     rd                  ; RD = starting cluster (real
                                        ; 16-bit value now, not raw
                                        ; disk bytes -- cluster numbers
                                        ; have no endianness concern
                                        ; once loaded into a register)
            mov     rf, crp_walk_current
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            call    crp_argv3           ; RF = hops (decimal)
            call    ym_parse_uint32     ; RD:R8 = value (hi:lo) --
                                        ; only R8 (low word) is used;
                                        ; a realistic hop count never
                                        ; approaches 65536
            mov     rf, crp_walk_remaining
            ghi     r8
            str     rf
            inc     rf
            glo     r8
            str     rf

walk_loop:
            mov     rf, crp_walk_remaining
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            ghi     r9
            lbnz    walk_step
            glo     r9
            lbnz    walk_step
            lbr     walk_done           ; remaining == 0 -- current
                                        ; cluster is the target

walk_step:
            mov     rf, crp_walk_current
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    crp_fat_read
            lbdf    err_io

            ; validate: must be a real, still-allocated, non-terminal
            ; cluster (2 <= value < FAT_EOC, value != FAT_BAD) for the
            ; chain to genuinely have another hop -- otherwise the
            ; file's own real chain is shorter than the requested hop
            ; count
            ghi     rd
            lbnz    walk_high_nonzero
            glo     rd
            lbz     err_chain_short     ; value == 0 (free cluster)
            glo     rd
            smi     2
            lbnf    err_chain_short     ; value == 1 (never valid)
walk_high_nonzero:
            mov     r9, rd
            sub16   r9, FAT_EOC
            lbdf    err_chain_short     ; value >= FAT_EOC
            mov     r9, rd
            sub16   r9, FAT_BAD
            ghi     r9
            lbnz    walk_not_badsector  ; sub16's own D result after
                                        ; completing is only the HIGH
                                        ; byte of the subtraction, NOT
                                        ; a full 16-bit zero test --
                                        ; lbz/lbnz here would wrongly
                                        ; match any value whose
                                        ; (value-FAT_BAD) high byte
                                        ; happens to be zero, not just
                                        ; value==FAT_BAD itself (caught
                                        ; by this file's own D-clobber
                                        ; sweep)
            glo     r9
            lbz     err_chain_short     ; value == FAT_BAD
walk_not_badsector:

            mov     rf, crp_walk_current
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, crp_walk_remaining
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            sub16   r9, 1
            mov     rf, crp_walk_remaining
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            lbr     walk_loop

walk_done:
            mov     rf, crp_walk_current
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = target cluster

            mov     rf, crp_trunc_is_badsector
            ldn     rf
            lbnz    walk_use_badsector
            mov     r8, FAT_EOC
            lbr     walk_do_write
walk_use_badsector:
            mov     r8, FAT_BAD
walk_do_write:
            call    crp_fat_write       ; RD = cluster, R8 = new value
            lbdf    err_io

            mov     rf, crp_trunc_is_badsector
            ldn     rf
            lbnz    walk_report_badsector
            call    K_INMSG
            db      "Target cluster's own FAT entry marked end-of-chain --",13,10
            db      "the file's real chain is now shorter than its own",13,10
            db      "recorded size.",13,10,0
            ldi     0
            rtn
walk_report_badsector:
            call    K_INMSG
            db      "Target cluster's own FAT entry marked bad-sector.",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
err_not_found:
            call    K_INMSG
            db      "File not found (in the current directory).",13,10,0
            ldi     1
            rtn

err_io:
            call    K_INMSG
            db      "Disk I/O error.",13,10,0
            ldi     1
            rtn

err_chain_short:
            call    K_INMSG
            db      "File's real cluster chain is shorter than the",13,10
            db      "requested hop count -- nothing changed.",13,10,0
            ldi     1
            rtn

;------------------------------------------------------------------
; crp_argv1/2/3: RF = argv[1]/[2]/[3] (RA/RC = argv/argc per program
; entry convention). Offsets are small fixed constants (2/4/6 bytes),
; so plain INC (which never touches D) is used to reach each slot
; rather than an add16-based computation -- sidesteps gotcha #4
; entirely for this one, deliberately simple case.
; Modifies: R9, RF (and D)
;------------------------------------------------------------------
crp_argv1:
            mov     rf, ra
            inc     rf
            inc     rf
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            rtn

crp_argv2:
            mov     rf, ra
            inc     rf
            inc     rf
            inc     rf
            inc     rf
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            rtn

crp_argv3:
            mov     rf, ra
            inc     rf
            inc     rf
            inc     rf
            inc     rf
            inc     rf
            inc     rf
            lda     rf
            phi     r9
            ldn     rf
            plo     r9
            mov     rf, r9
            rtn

;------------------------------------------------------------------
; crp_pack_name: split an argv string on '.' into an 8.3 raw short
; name, left-justified, space-padded. No case-folding (caller must
; already type uppercase); name/extension parts longer than 8/3
; characters are silently truncated (this is a deliberately unchecked
; developer tool, not general-purpose input validation).
; Args:    RF = null-terminated source string
; Returns: crp_target[0..10] filled
; Modifies: R7, R8, R9, RF (and D)
;------------------------------------------------------------------
crp_pack_name:
            mov     r9, rf              ; R9 = source pointer

            mov     r8, crp_target
            ldi     11
            plo     r7
cpn_blank_loop:
            ldi     ' '
            str     r8
            inc     r8
            dec     r7
            glo     r7
            lbnz    cpn_blank_loop

            mov     r8, crp_target      ; R8 -> name field write cursor
            ldi     8
            plo     r7                  ; R7.0 = name chars remaining
cpn_name_loop:
            glo     r7
            lbz     cpn_skip_to_dot
            ldn     r9
            lbz     cpn_done            ; end of string, no extension
            xri     '.'
            lbz     cpn_have_dot
            ldn     r9
            str     r8
            inc     r8
            inc     r9
            dec     r7
            lbr     cpn_name_loop

cpn_skip_to_dot:
            ldn     r9
            lbz     cpn_done
            xri     '.'
            lbz     cpn_have_dot
            inc     r9
            lbr     cpn_skip_to_dot

cpn_have_dot:
            inc     r9                  ; skip the '.' itself
            mov     r8, crp_target
            add16   r8, 8               ; R8 -> extension field
            ldi     3
            plo     r7
cpn_ext_loop:
            glo     r7
            lbz     cpn_done
            ldn     r9
            lbz     cpn_done
            str     r8
            inc     r8
            inc     r9
            dec     r7
            lbr     cpn_ext_loop

cpn_done:
            rtn

;------------------------------------------------------------------
; crp_read_bpb: read the active drive's own BPB fields via
; BPB_DATA_PTR into crp_* memory. Hand-traced copy of progs/chkdsk.asm's
; own chk_read_bpb (already independently verified there), plus
; crp_num_fats which chkdsk itself never needed.
; Modifies: everything (R7-R9, RB, RF) -- treat as fully clobbering
;------------------------------------------------------------------
crp_read_bpb:
            mov     rf, BPB_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = BPB block's real address

            mov     rf, r9
            add16   rf, BPBBLK_FAT_LBA
            mov     rb, crp_fat_lba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            mov     rf, r9
            add16   rf, BPBBLK_SPC
            mov     rb, crp_spc
            ldn     rf
            str     rb

            mov     rf, r9
            add16   rf, BPBBLK_SPC_SHIFT
            mov     rb, crp_spc_shift
            ldn     rf
            str     rb

            mov     rf, r9
            add16   rf, BPBBLK_NUM_FATS
            mov     rb, crp_num_fats
            ldn     rf
            str     rb

            mov     rf, r9
            add16   rf, BPBBLK_SPF
            mov     rb, crp_spf
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb

            rtn

;------------------------------------------------------------------
; crp_cluster_to_lba: convert a cluster number to its starting LBA.
; Hand-traced copy of progs/chkdsk.asm's own chk_cluster_to_lba
; (itself a userland mirror of kernel/dir.asm's _cluster_to_lba).
; Args:    RD = cluster number (>= 2)
; Returns: R7/R8 set for K_SECREAD/K_SECWRITE
; Modifies: R7, R8, RA, RC, RD, RF (and D)
;------------------------------------------------------------------
crp_cluster_to_lba:
            dec     rd
            dec     rd                  ; RD = cluster - 2

            ghi     rd
            phi     r7
            glo     rd
            plo     r7
            ldi     0
            plo     r8

            mov     rf, crp_spc_shift
            ldn     rf
            plo     rc
            glo     rc
            lbz     cctl2_done

cctl2_shift:
            shl16   r7
            glo     r8
            shlc
            plo     r8
            dec     rc
            glo     rc
            lbnz    cctl2_shift

cctl2_done:
            ; there is no chk_data_lba equivalent here -- this tool
            ; only ever reads/writes FAT sectors and directory
            ; sectors, never cluster DATA sectors, so no data-area
            ; base needs adding; callers that walk a subdirectory's
            ; own cluster chain (crp_read_next_dir_sector) DO need the
            ; real data-area base, so it is added there via the same
            ; add-with-carry shape chk_cluster_to_lba itself uses --
            ; duplicated here rather than shared, since only ONE
            ; caller in this file needs it (see crp_dpb_lba's own
            ; setup in crp_read_next_dir_sector below)
            rtn

;------------------------------------------------------------------
; crp_fat_read: read the raw 16-bit FAT16 entry for a cluster, from
; FAT copy 0 only (reading additional copies would be redundant --
; they're expected to already match). Hand-traced copy of
; progs/chkdsk.asm's own chk_fat_read.
; Args:    RD = cluster number
; Returns: DF = 0 with RD = raw 16-bit FAT entry; DF = 1 on I/O error
; Modifies: R7, R8, R9, RB, RF (and D) -- treat as fully clobbering
;------------------------------------------------------------------
crp_fat_read:
            mov     rb, crp_fr_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb

            mov     rf, crp_fat_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            lda     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, crp_fr_cluster
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

            mov     rf, crp_fr_secbuf
            call    K_SECREAD
            lbdf    cfr_ioerr

            mov     rf, crp_fr_cluster
            inc     rf
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9

            mov     rf, crp_fr_secbuf
            add16   rf, r9
            lda     rf
            plo     rb
            ldn     rf
            phi     rb

            ghi     rb
            phi     rd
            glo     rb
            plo     rd
            clc
            rtn

cfr_ioerr:
            stc
            rtn

;------------------------------------------------------------------
; crp_fat_write: write a raw 16-bit value into a cluster's own FAT
; entry, mirrored into every FAT copy (bpb_num_fats), matching
; kernel/fat.asm's own fat_flush convention -- writing only one copy
; would itself create an unrelated FAT-copy mismatch, muddying the
; specific corruption this tool means to inject.
; Args:    RD = cluster number, R8 = new 16-bit value
; Returns: DF = 0/1
; Modifies: everything (R7-R9, RA-RD, RF) -- treat as fully clobbering
;------------------------------------------------------------------
crp_fat_write:
            mov     rb, crp_fw_cluster
            ghi     rd
            str     rb
            inc     rb
            glo     rd
            str     rb
            ; crp_fw_value is stored LOW byte first, matching on-disk
            ; LE order directly, since the read-back-and-write code
            ; below below copies these two bytes straight to disk with
            ; no register reconstruction in between (unlike
            ; crp_fw_cluster above, which is only ever read back via
            ; lda/phi + ldn/plo into a real register, where 1802's own
            ; low/high-byte convention already matches LE order) --
            ; storing high-then-low here (matching crp_fw_cluster's
            ; own order by pattern-matching, an earlier draft's actual
            ; mistake) would silently byte-swap the value written to
            ; disk
            mov     rb, crp_fw_value
            glo     r8
            str     rb
            inc     rb
            ghi     r8
            str     rb

            mov     rf, crp_fw_copy_idx
            ldi     0
            str     rf

fw_copy_loop:
            mov     rf, crp_fat_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            lda     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, crp_fw_copy_idx
            ldn     rf
            lbz     fw_no_copy_off
            plo     rb                  ; RB.0 = remaining copies to add
fw_copy_off_loop:
            mov     rf, crp_spf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8

            dec     rb
            glo     rb
            lbnz    fw_copy_off_loop
fw_no_copy_off:

            mov     rf, crp_fw_cluster
            ldn     rf                  ; D = cluster's high byte
                                        ; (sector index within FAT)
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

            mov     rf, crp_fw_secbuf
            call    K_SECREAD
            lbdf    fw_ioerr

            mov     rf, crp_fw_cluster
            inc     rf
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            shl16   r9

            mov     rf, crp_fw_secbuf
            add16   rf, r9

            mov     r8, crp_fw_value
            ldn     r8
            str     rf                  ; low byte (on-disk LE)
            inc     rf
            inc     r8
            ldn     r8
            str     rf                  ; high byte

            ; re-derive the same LBA fresh (K_SECREAD clobbers R7/R8)
            ; rather than trusting either to have survived
            mov     rf, crp_fat_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            lda     rf
            plo     r7
            ldi     0
            phi     r8

            mov     rf, crp_fw_copy_idx
            ldn     rf
            lbz     fw_no_copy_off2
            plo     rb
fw_copy_off_loop2:
            mov     rf, crp_spf
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            add16   r7, rd
            glo     r8
            adci    0
            plo     r8

            dec     rb
            glo     rb
            lbnz    fw_copy_off_loop2
fw_no_copy_off2:

            mov     rf, crp_fw_cluster
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

            mov     rf, crp_fw_secbuf
            call    K_SECWRITE
            lbdf    fw_ioerr

            mov     rf, crp_fw_copy_idx
            ldn     rf
            adi     1
            str     rf
            mov     r8, crp_num_fats
            ldn     r8
            str     r2
            mov     rf, crp_fw_copy_idx
            ldn     rf
            sm
            lbnf    fw_copy_loop        ; copy_idx < num_fats -- more
                                        ; copies to write

            clc
            rtn

fw_ioerr:
            stc
            rtn

;------------------------------------------------------------------
; crp_find: locate crp_target[0..10]'s own directory entry within
; crp_parent, by a raw sector-by-sector walk (root's fixed area, or a
; subdirectory's own cluster chain) -- deliberately bypasses
; K_DIR_READ's own LFN resolution, matching exactly what CHKDSK's own
; duplicate-short-name check compares against (dir_read's LFN
; preference would hide a raw short-name-only match).
; Returns: DF = 0 with crp_secbuf holding the matched sector's current
;          content and crp_found_lba/crp_found_off set to its own
;          location; DF = 1 if not found (terminator reached first) or
;          on I/O error
; Modifies: everything -- treat as fully clobbering
;------------------------------------------------------------------
crp_find:
            call    crp_init_dir_walk

cf_sector_loop:
            call    crp_read_next_dir_sector
            lbdf    cf_not_found

            ldi     0
            plo     r9                  ; R9.0 = entry_idx within
                                        ; this sector (0-15)
cf_entry_loop:
            call    crp_get_entry_ptr  ; RF = entry address
            ldn     rf
            lbz     cf_not_found        ; $00 terminator -- stop
            xri     $E5
            lbz     cf_next_entry       ; deleted -- skip

            call    crp_get_entry_ptr
            add16   rf, DE_ATTR
            ldn     rf
            xri     ATTR_LFN
            lbz     cf_next_entry       ; LFN continuation -- skip

            call    crp_get_entry_ptr
            add16   rf, DE_ATTR
            ldn     rf
            ani     ATTR_VOLID
            lbnz    cf_next_entry       ; volume label -- skip

            ; compare this entry's raw 11-byte DE_NAME against
            ; crp_target
            call    crp_get_entry_ptr
            mov     rb, crp_target
            ldi     11
            plo     r7
cf_name_cmp:
            lda     rb
            str     r2
            lda     rf
            xor
            lbnz    cf_next_entry
            dec     r7
            glo     r7
            lbnz    cf_name_cmp

            ; match -- record this entry's own location
            mov     rf, crp_dpb_lba
            mov     r8, crp_found_lba
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8

            ldi     0
            phi     r9                  ; zero-extend entry_idx (R9.0,
                                        ; 0-15) to a full 16-bit value
                                        ; before the multiply -- R9.1
                                        ; is NOT otherwise guaranteed
                                        ; zero here (crp_read_next_
                                        ; dir_sector's own root-path
                                        ; writes R9's high byte from
                                        ; root_sector_idx, which is
                                        ; usually but not provably 0)
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9
            shl16   r9                  ; R9 = entry_idx * 32 (max
                                        ; 15*32=480, needs both bytes)
            mov     rf, crp_found_off
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            clc
            rtn

cf_next_entry:
            glo     r9
            adi     1
            plo     r9
            smi     16
            lbnf    cf_entry_loop       ; still within this sector
                                        ; (0-15)
            lbr     cf_sector_loop

cf_not_found:
            stc
            rtn

;------------------------------------------------------------------
; crp_write_found_sector: write crp_secbuf back to crp_found_lba --
; the single point every mode uses to commit its own edit.
; Returns: DF = 0/1
; Modifies: R7, R8, RF (and D)
;------------------------------------------------------------------
crp_write_found_sector:
            mov     rf, crp_found_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, crp_secbuf
            call    K_SECWRITE
            rtn

;------------------------------------------------------------------
; crp_get_entry_ptr: RF = crp_secbuf + (entry_idx-currently-in-R9.0)*32
; Args:    R9.0 = entry_idx (0-15) -- NOT modified
; Returns: RF = entry address
; Modifies: R8, RF (and D)
;------------------------------------------------------------------
crp_get_entry_ptr:
            glo     r9
            plo     r8
            ldi     0
            phi     r8
            shl16   r8
            shl16   r8
            shl16   r8
            shl16   r8
            shl16   r8                  ; R8 = entry_idx * 32
            mov     rf, crp_secbuf
            add16   rf, r8
            rtn

;------------------------------------------------------------------
; crp_init_dir_walk / crp_read_next_dir_sector / crp_lba_inc: raw,
; sector-by-sector walk of crp_parent (root's fixed area, or a
; subdirectory's own cluster chain). Hand-traced copies of
; progs/chkdsk.asm's own chk_scan_dir_raw's init code and
; chk_read_next_dir_sector/chk_lba_inc.
;------------------------------------------------------------------
crp_init_dir_walk:
            mov     rf, crp_parent
            lda     rf
            phi     rd
            ldn     rf
            plo     rd

            ghi     rd
            lbnz    cidw_subdir_init
            glo     rd
            lbnz    cidw_subdir_init

            ; ---- root init: fixed area, no cluster chain ----
            mov     rf, crp_dpb_is_root
            ldi     1
            str     rf

            mov     rf, BPB_DATA_PTR
            lda     rf
            phi     r9
            ldn     rf
            plo     r9

            mov     rf, r9
            add16   rf, BPBBLK_ROOT_LBA
            mov     r8, crp_dpb_lba
            lda     rf
            str     r8
            inc     r8
            lda     rf
            str     r8
            inc     r8
            ldn     rf
            str     r8

            mov     rf, r9
            add16   rf, BPBBLK_ROOT_ENTS
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = root_ents
            shr16   rd
            shr16   rd
            shr16   rd
            shr16   rd                  ; RD = root_ents >> 4 (16
                                        ; entries/sector)
            mov     rf, crp_dpb_root_sectors
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, crp_dpb_root_sector_idx
            ldi     0
            str     rf
            inc     rf
            str     rf

            rtn

cidw_subdir_init:
            mov     rf, crp_dpb_is_root
            ldi     0
            str     rf

            mov     rf, crp_dpb_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf

            mov     rf, crp_dpb_sector_in_cluster
            ldi     0
            str     rf

            call    crp_cluster_to_lba ; RD still = starting cluster
            ; add the data-area base (BPBBLK_DATA_LBA) -- see
            ; crp_cluster_to_lba's own header comment for why this
            ; addition lives here rather than inside that routine.
            ; DATA_LBA is 3 bytes, big-endian (bits23-16 first) --
            ; stage all 3 into temp registers BEFORE adding, then add
            ; LSB-first for correct carry propagation. Reading and
            ; adding in the SAME (MSB-first, sequential-read) order,
            ; as this exact block's first draft did, silently adds
            ; each byte to the WRONG bit-significance position (found
            ; by re-deriving this against progs/chkdsk.asm's own
            ; already-proven chk_cluster_to_lba tail, which stages
            ; into RA.1/RC.1/D for exactly this reason).
            mov     r9, BPB_DATA_PTR
            lda     r9
            phi     rb
            ldn     r9
            plo     rb
            mov     r9, rb
            add16   r9, BPBBLK_DATA_LBA
            lda     r9                  ; D = DATA_LBA bits 23-16
            phi     ra
            lda     r9                  ; D = DATA_LBA bits 15-8
            phi     rc
            ldn     r9                  ; D = DATA_LBA bits 7-0

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

            mov     rf, crp_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

            rtn

crp_read_next_dir_sector:
            mov     rf, crp_dpb_is_root
            ldn     rf
            lbz     crnds2_subdir

            mov     r7, crp_dpb_root_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            mov     r7, crp_dpb_root_sectors
            lda     r7
            phi     r8
            ldn     r7
            plo     r8
            mov     r7, r9
            sub16   r7, r8
            lbdf    crnds2_eof

            mov     rf, crp_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, crp_secbuf
            call    K_SECREAD
            lbdf    crnds2_eof

            mov     r7, crp_dpb_root_sector_idx
            lda     r7
            phi     r9
            ldn     r7
            plo     r9
            add16   r9, 1
            mov     r7, crp_dpb_root_sector_idx
            ghi     r9
            str     r7
            inc     r7
            glo     r9
            str     r7

            call    crp_lba_inc
            clc
            rtn

crnds2_subdir:
            mov     rf, crp_dpb_sector_in_cluster
            ldn     rf
            plo     r9
            ldi     0
            phi     r9
            mov     rf, crp_spc
            ldn     rf
            plo     r8
            ldi     0
            phi     r8
            mov     r7, r9
            sub16   r7, r8
            lbnf    crnds2_read

            mov     rf, crp_dpb_cluster
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            call    crp_fat_read
            lbdf    crnds2_eof

            ghi     rd
            lbnz    crnds2_check_eoc
            glo     rd
            lbz     crnds2_eof
crnds2_check_eoc:
            mov     r9, rd
            sub16   r9, FAT_EOC
            lbdf    crnds2_eof

            mov     rf, crp_dpb_cluster
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            mov     rf, crp_dpb_sector_in_cluster
            ldi     0
            str     rf

            call    crp_cluster_to_lba ; RD already = the new cluster
            ; DATA_LBA is 3 bytes, big-endian -- stage all 3 into temp
            ; registers before adding, then add LSB-first for correct
            ; carry propagation (same fix, same reasoning, as
            ; crp_init_dir_walk's own identical block above)
            mov     r9, BPB_DATA_PTR
            lda     r9
            phi     rb
            ldn     r9
            plo     rb
            mov     r9, rb
            add16   r9, BPBBLK_DATA_LBA
            lda     r9                  ; D = DATA_LBA bits 23-16
            phi     ra
            lda     r9                  ; D = DATA_LBA bits 15-8
            phi     rc
            ldn     r9                  ; D = DATA_LBA bits 7-0

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

            mov     rf, crp_dpb_lba
            glo     r8
            str     rf
            inc     rf
            ghi     r7
            str     rf
            inc     rf
            glo     r7
            str     rf

crnds2_read:
            mov     rf, crp_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, crp_secbuf
            call    K_SECREAD
            lbdf    crnds2_eof

            mov     rf, crp_dpb_sector_in_cluster
            ldn     rf
            adi     1
            str     rf

            call    crp_lba_inc
            clc
            rtn

crnds2_eof:
            stc
            rtn

crp_lba_inc:
            mov     rf, crp_dpb_lba
            lda     rf
            plo     r8
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            add16   rd, 1
            ghi     rd
            lbnz    cli2_no_carry
            glo     rd
            lbnz    cli2_no_carry
            glo     r8
            adi     1
            plo     r8
cli2_no_carry:
            mov     rf, crp_dpb_lba
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
; data
;------------------------------------------------------------------
crp_mode_size:      db      "SIZE",0
crp_mode_lost:      db      "LOST",0
crp_mode_xlink:     db      "XLINK",0
crp_mode_dupname:   db      "DUPNAME",0
crp_mode_trunc:     db      "TRUNC",0
crp_mode_badsector: db      "BADSECTOR",0

crp_parent:             ds  2
crp_target:             ds  11
crp_saved:              ds  11
crp_found_lba:          ds  3
crp_found_off:          ds  2
crp_secbuf:             ds  512

crp_fat_lba:            ds  3
crp_spc:                ds  1
crp_spc_shift:          ds  1
crp_num_fats:           ds  1
crp_spf:                ds  2

crp_fr_cluster:         ds  2
crp_fr_secbuf:          ds  512

crp_fw_cluster:         ds  2
crp_fw_value:           ds  2
crp_fw_copy_idx:        ds  1
crp_fw_secbuf:          ds  512

crp_dpb_is_root:            ds  1
crp_dpb_root_sector_idx:    ds  2
crp_dpb_root_sectors:       ds  2
crp_dpb_cluster:            ds  2
crp_dpb_sector_in_cluster:  ds  1
crp_dpb_lba:                ds  3

crp_walk_current:       ds  2
crp_walk_remaining:     ds  2
crp_trunc_is_badsector: ds  1
