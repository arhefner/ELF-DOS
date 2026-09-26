;
; ksave.asm - save the installed kernel to a file (the reverse of SYS)
;
; Usage: KSAVE [unit] [filename]
;          unit      block device unit 0-7 (default: the boot unit)
;          filename  file to write (default kernel-full.bak)
;
; Reads the kernel image that SYS (or host-side elfdos-sys -k) wrote to
; LBA 1 onward of a block device, and writes it to a file in exactly
; the kernel-full.bin format -- the result can be fed straight back
; into SYS (or elfdos-sys -k) to restore that kernel.
;
; The argument is a UNIT, not a drive letter, because the kernel belongs
; to a device: it lives in the reserved sectors between the MBR and the
; first partition, so every letter on one card names the same kernel.
; A unit needs no partition to be mounted. It is a single digit 0-7, so
; a file literally named with one digit needs a path (./3).
;
; How much to read comes from the kernel's own bootstrap header, which
; tools/split_kernel.py fills in at build time (see boot/krnboot.asm):
;   offset 0-2   'KRN'
;   offset 4-5   volatile sector count     (big-endian)
;   offset 9-10  non-volatile sector count (big-endian)
;   offset 11-12 bytes used in the LAST non-volatile sector (1..512)
; Total = KRNBOOT_SECTORS + volatile + non-volatile sectors. The final
; sector is written only up to its used byte count, so the output is
; byte-for-byte the kernel-full.bin the build produced (split_kernel.py
; does not pad the non-volatile image's tail). SYS and elfdos-sys both
; accept it: their check is that ceil(size/512) equals that same total.
;
; Sanity checks before anything is written: sector 0 must be a
; partition table ($55 $AA, at least one used entry -- a partitionless
; volume has no room for a kernel), LBA 1 must carry the 'KRN'
; signature, both counts must be nonzero, the last-sector count in
; 1..512, and the whole image must end BELOW the start of every used
; partition. A header claiming otherwise is garbage.
;
; Read-only with respect to the device: only K_SECREAD is used. The
; file is written through the normal filesystem, so it may safely live
; on the same drive being read.
;
; Every value that must outlive a kernel call lives in memory and is
; reloaded right before use -- nothing is trusted to survive K_SECREAD
; (documented to clobber R7/R8) or the K_FILE_* calls.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

KRNBOOT_SECTORS:    equ     5       ; must match boot/mbr.asm, sys/sys.c,
                                    ; tools/split_kernel.py

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            db      0                   ; program minor version
            db      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RC.0 = argc (never above ARGV_MAX_ARGS). Stash argv/argc
            ; before anything else.
            glo     rc
            smi     4
            lbdf    usage               ; argc >= 4: too many arguments

            mov     rf, ks_argc
            glo     rc
            str     rf
            mov     rf, ks_argv
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf

            ; Default unit: the one the system booted from.
            mov     rf, BOOT_UNIT
            ldn     rf
            plo     r9
            mov     rf, ks_unit
            glo     r9
            str     rf

            mov     rf, ks_argidx
            ldi     1
            str     rf                  ; next argv index to examine

            ; ---- optional unit argument: exactly one digit 0-7 ----
            call    ks_next_arg         ; DF=1: no more args; else RF=arg
            lbdf    args_done

            ldn     rf                  ; first char
            smi     '0'
            lbnf    arg_is_name         ; below '0'
            smi     8
            lbdf    arg_is_name         ; above '7'
            inc     rf
            ldn     rf
            lbnz    arg_is_name         ; longer than one character
            dec     rf
            ldn     rf
            smi     '0'
            plo     r9                  ; R9.0 = unit
            mov     rf, ks_unit
            glo     r9
            str     rf

            call    ks_consume_arg
            call    ks_next_arg
            lbdf    args_done

arg_is_name:
            ; RF was advanced while testing for "X:" -- reload it
            call    ks_cur_arg
            mov     rb, ks_name_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            call    ks_consume_arg
            call    ks_next_arg
            lbnf    usage               ; anything left over is an error

args_done:
;------------------------------------------------------------------
; Read the unit's partition table (LBA 0) and keep each used entry's
; start LBA, so the kernel image can be checked against all of them.
;------------------------------------------------------------------
            ldi     0
            phi     r7
            plo     r7
            plo     r8                  ; LBA = 0
            mov     rf, ks_unit
            ldn     rf
            phi     r8                  ; R8.1 = unit
            mov     rf, ks_buf
            call    K_SECREAD
            lbdf    read_error

            mov     rf, ks_buf+510
            lda     rf
            xri     $55
            lbnz    no_ptable
            ldn     rf
            xri     $AA
            lbnz    no_ptable

            ; A FAT boot sector (partitionless volume) also ends in
            ; $55 $AA, with boot code where the entries would be. It
            ; always starts with a jump opcode; a partition table's
            ; sector does not (ELF-DOS's own MBR begins "MBR").
            mov     rf, ks_buf
            ldn     rf
            xri     $EB
            lbz     no_ptable
            ldn     rf
            xri     $E9
            lbz     no_ptable

            ; ks_parts[i] = entry i's 4-byte start LBA (little-endian,
            ; as on disk), or 0 if the entry is unused (type 0) or
            ; claims to start at LBA 0.
            mov     rf, ks_buf+446
            mov     rd, ks_parts
            ldi     4
            plo     r9                  ; R9.0 = entries left
            ldi     0
            plo     rc                  ; RC.0 = used entries seen
pt_loop:
            add16   rf, 4               ; RF -> partition type
            ldn     rf
            plo     rb                  ; RB.0 = type
            add16   rf, 4               ; RF -> start LBA byte 0
            ldi     0
            phi     rb                  ; RB.1 = OR of the LBA bytes
            lda     rf
            str     rd
            inc     rd
            str     r2
            ghi     rb
            or
            phi     rb
            lda     rf
            str     rd
            inc     rd
            str     r2
            ghi     rb
            or
            phi     rb
            lda     rf
            str     rd
            inc     rd
            str     r2
            ghi     rb
            or
            phi     rb
            lda     rf
            str     rd
            inc     rd
            str     r2
            ghi     rb
            or
            phi     rb
            add16   rf, 4               ; RF -> next entry (16 bytes each)

            glo     rb
            lbz     pt_unused
            ghi     rb
            lbz     pt_unused
            glo     rc
            adi     1
            plo     rc
            lbr     pt_next
pt_unused:
            dec     rd
            dec     rd
            dec     rd
            dec     rd
            ldi     0
            str     rd
            inc     rd
            str     rd
            inc     rd
            str     rd
            inc     rd
            str     rd
            inc     rd
pt_next:
            dec     r9
            glo     r9
            lbnz    pt_loop

            glo     rc
            lbz     no_ptable           ; a table with nothing in it

;------------------------------------------------------------------
; Read the bootstrap's first sector (LBA 1) and validate its header
;------------------------------------------------------------------
            ldi     0
            phi     r7
            plo     r8                  ; LBA bits 23-8 = 0
            ldi     1
            plo     r7                  ; LBA = 1
            mov     rf, ks_unit
            ldn     rf
            phi     r8                  ; R8.1 = unit
            mov     rf, ks_buf
            call    K_SECREAD
            lbdf    read_error

            mov     rf, ks_buf
            lda     rf
            xri     'K'
            lbnz    no_kernel
            lda     rf
            xri     'R'
            lbnz    no_kernel
            ldn     rf
            xri     'N'
            lbnz    no_kernel

            ; copy the three header words out of the buffer
            mov     rf, ks_buf+4
            mov     rd, ks_vol
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd
            mov     rf, ks_buf+9
            mov     rd, ks_nv
            lda     rf
            str     rd
            inc     rd
            lda     rf
            str     rd
            inc     rd                  ; RD = ks_last (follows ks_nv)
            lda     rf
            str     rd
            inc     rd
            ldn     rf
            str     rd

            ; volatile count nonzero
            mov     rf, ks_vol
            lda     rf
            str     r2
            ldn     rf
            or
            lbz     bad_header
            ; non-volatile count nonzero
            mov     rf, ks_nv
            lda     rf
            str     r2
            ldn     rf
            or
            lbz     bad_header

            ; last-sector count in 1..512
            mov     rf, ks_last
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = last
            ghi     r9
            lbnz    last_hi_nonzero
            glo     r9
            lbz     bad_header          ; 0
            lbr     last_ok
last_hi_nonzero:
            xri     2
            lbnz    bad_header          ; >= $0300, or $01xx
            glo     r9
            lbnz    bad_header          ; $02xx other than $0200
last_ok:

            ; total = KRNBOOT_SECTORS + vol + nv, carry = too big
            mov     rf, ks_vol
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = vol
            mov     rf, ks_nv
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = nv
            glo     rd
            str     r2
            glo     r9
            add
            plo     r9
            ghi     rd
            str     r2
            ghi     r9
            adc
            phi     r9                  ; R9 = vol + nv
            lbdf    bad_header
            glo     r9
            adi     KRNBOOT_SECTORS
            plo     r9
            ghi     r9
            adci    0
            phi     r9                  ; R9 = total sectors
            lbdf    bad_header

            mov     rf, ks_total
            ghi     r9
            str     rf
            inc     rf
            glo     r9
            str     rf

            ; The image occupies LBA 1..total, so every used partition
            ; must start above it: total < start for each entry.
            mov     rb, ks_parts
            ldi     4
            plo     r9                  ; R9.0 = entries left
ov_loop:
            lda     rb
            plo     r8                  ; R8.0 = start bits 7-0
            lda     rb
            phi     r8                  ; R8.1 = start bits 15-8
            lda     rb
            str     r2
            ldn     rb
            or                          ; D = bits 31-16, ORed together
            inc     rb                  ; RB -> next entry
            lbnz    ov_next             ; starts past LBA 65535: clear
            ghi     r8
            str     r2
            glo     r8
            or
            lbz     ov_next             ; unused entry
            glo     r8
            str     r2
            mov     rf, ks_total+1
            ldn     rf                  ; D = total.lo
            sm                          ; D = total.lo - start.lo
            ghi     r8
            str     r2                  ; (ghi/str/mov/ldn leave DF alone)
            mov     rf, ks_total
            ldn     rf                  ; D = total.hi
            smb                         ; D = total.hi - start.hi - borrow
            lbdf    overlaps            ; no borrow: total >= start
ov_next:
            dec     r9
            glo     r9
            lbnz    ov_loop

;------------------------------------------------------------------
; Open the output file and copy LBA 1..total into it
;------------------------------------------------------------------
            mov     rb, ks_name_ptr
            lda     rb
            phi     rf
            ldn     rb
            plo     rf                  ; RF = filename
            mov     rd, ks_fcb
            mov     ra, ks_iobuf
            ldi     1                   ; mode = create/overwrite
            call    K_FILE_OPEN
            lbdf    open_error

            mov     rf, ks_remain
            mov     rd, ks_total
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; remain = total
            mov     rf, ks_lba
            ldi     0
            str     rf
            inc     rf
            ldi     1
            str     rf                  ; lba = 1

copy_loop:
            ldi     0
            plo     r8                  ; LBA bits 23-16
            mov     rf, ks_lba
            lda     rf
            phi     r7
            ldn     rf
            plo     r7
            mov     rf, ks_unit
            ldn     rf
            phi     r8                  ; R8.1 = unit
            mov     rf, ks_buf
            call    K_SECREAD
            lbdf    copy_read_error

            ; count = 512, or ks_last for the final sector
            ldi     2
            phi     rc
            ldi     0
            plo     rc
            mov     rf, ks_remain
            lda     rf
            lbnz    count_ready
            ldn     rf
            xri     1
            lbnz    count_ready
            mov     rf, ks_last
            lda     rf
            phi     rc
            ldn     rf
            plo     rc
count_ready:
            mov     rd, ks_fcb
            mov     rf, ks_buf
            call    K_FILE_WRITE
            lbdf    write_error

            ; lba++
            mov     rf, ks_lba+1
            ldn     rf
            adi     1
            str     rf
            lbnf    lba_done
            dec     rf
            ldn     rf
            adi     1
            str     rf
lba_done:
            ; remain--, loop while nonzero
            mov     rf, ks_remain+1
            ldn     rf
            smi     1
            str     rf
            lbdf    remain_done
            dec     rf
            ldn     rf
            smi     1
            str     rf
remain_done:
            mov     rf, ks_remain
            lda     rf
            lbnz    copy_loop
            ldn     rf
            lbnz    copy_loop

            mov     rd, ks_fcb
            call    K_FILE_CLOSE
            lbdf    close_error

            ; "Saved N sectors from X: to <file>."
            call    K_INMSG
            db      "Saved ",0
            mov     rf, ks_total
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, ks_num_buf
            call    f_uintout
            ldi     0
            str     rf
            mov     rf, ks_num_buf
            call    K_MSG
            call    K_INMSG
            db      " kernel sectors from unit ",0
            mov     rf, ks_unit
            ldn     rf
            adi     '0'
            call    K_TYPE
            call    K_INMSG
            db      " to ",0
            mov     rb, ks_name_ptr
            lda     rb
            phi     rf
            ldn     rb
            plo     rf
            call    K_MSG
            call    K_INMSG
            db      ".",13,10,0
            ldi     0
            rtn

;------------------------------------------------------------------
; Errors
;------------------------------------------------------------------
copy_read_error:
            call    close_quietly
read_error:
            call    K_INMSG
            db      "Error reading the device.",13,10,0
            ldi     1
            rtn

write_error:
            call    close_quietly
close_error:
            call    K_INMSG
            db      "Error writing the file.",13,10,0
            ldi     1
            rtn

open_error:
            call    K_INMSG
            db      "Cannot create the file.",13,10,0
            ldi     1
            rtn

no_ptable:
            call    K_INMSG
            db      "No partition table on that unit -- no kernel to save.",13,10,0
            ldi     1
            rtn

overlaps:
            call    K_INMSG
            db      "Kernel header runs into a partition -- nothing saved.",13,10,0
            ldi     1
            rtn

no_kernel:
            call    K_INMSG
            db      "No kernel on that unit ('KRN' not found).",13,10,0
            ldi     1
            rtn

bad_header:
            call    K_INMSG
            db      "Kernel header is not valid -- nothing saved.",13,10,0
            ldi     1
            rtn

usage:
            call    K_INMSG
            db      "Usage: KSAVE [unit] [filename]",13,10
            db      "  unit 0-7 (default: the boot unit), file default kernel-full.bak",13,10,0
            ldi     1
            rtn

; Close the output after a mid-copy failure. The partial file is left
; in place; its size shows it is incomplete (and SYS rejects it).
close_quietly:
            mov     rd, ks_fcb
            call    K_FILE_CLOSE
            rtn

;------------------------------------------------------------------
; Argument helpers. ks_argidx is the next argv index to look at.
;------------------------------------------------------------------
; ks_next_arg: DF=1 if argidx >= argc; else DF=0, RF = argv[argidx]
ks_next_arg:
            mov     rf, ks_argc
            ldn     rf
            str     r2
            mov     rf, ks_argidx
            ldn     rf
            sm                          ; D = argidx - argc
            lbdf    kna_none            ; no borrow: argidx >= argc
            call    ks_cur_arg
            clc
            rtn
kna_none:
            stc
            rtn

; ks_cur_arg: RF = argv[argidx]
ks_cur_arg:
            mov     rf, ks_argidx
            ldn     rf
            shl                         ; D = argidx*2 (argidx < 4)
            str     r2
            mov     rf, ks_argv+1
            ldn     rf
            add
            plo     r9
            mov     rf, ks_argv
            ldn     rf
            adci    0
            phi     r9                  ; R9 = &argv[argidx]
            lda     r9
            phi     rf
            ldn     r9
            plo     rf
            rtn

; ks_consume_arg: argidx++
ks_consume_arg:
            mov     rf, ks_argidx
            ldn     rf
            adi     1
            str     rf
            rtn

;------------------------------------------------------------------
; Data
;------------------------------------------------------------------
ks_default_name: db     "kernel-full.bak",0
ks_name_ptr:    dw      ks_default_name
ks_argc:        db      0
ks_argidx:      db      0
ks_argv:        dw      0
ks_unit:        db      0
ks_parts:       ds      16              ; 4 partition start LBAs (LE)
ks_vol:         dw      0
ks_nv:          dw      0
ks_last:        dw      0               ; must directly follow ks_nv
ks_total:       dw      0
ks_remain:      dw      0
ks_lba:         dw      0
ks_num_buf:     ds      6

.align  32                  ; FCB must not straddle a page --
                            ; file_open rejects one that does
ks_fcb:         ds      FCB_LEN
#if (ks_fcb & $FF) > (256 - FCB_LEN)
#error ks_fcb crosses a page boundary
#endif
ks_iobuf:       ds      FCB_IOBUF_LEN
ks_buf:         ds      512

            end     start
