;
; sys.asm - target-side kernel installer
;
; Usage: SYS <kernel-full.bin>
;
; Writes a kernel-full.bin (the same file this project's own Makefile
; produces, and which host-side elfdos-sys writes with its "-k" flag)
; directly to the boot device's raw sectors, from ON the running
; ELF-DOS system -- letting a new kernel be installed after receiving
; it over serial via MR, with no SD card swap to a host machine.
; Companion feature to progs/mr.asm/progs/ms.asm; MBR installation
; (elfdos-sys's "-m") is deliberately NOT implemented here -- kernel-
; only covers the routine "make update"-style iteration case this was
; actually built for, and MBR writes are rarer and higher-risk (get
; that as a separate, deliberate addition later if actually needed).
;
; DANGER: this writes directly to the SAME disk the running system is
; booted from. A bad write to LBA 1+ can make the system unable to
; boot, at which point recovery needs exactly the card-swap-to-host
; process this tool exists to avoid. Mitigations built in:
;   - Requires the 'KRN' magic signature at the start of the file
;     (same check host-side elfdos-sys does) before touching anything.
;   - Refuses a file under KRNBOOT_SECTORS*512 = 1536 bytes (can't
;     even hold a valid bootstrap, let alone a real kernel proper).
;   - Prints the sector count and an explicit warning, then requires
;     an explicit Y/N confirmation (same K_READ-based pattern as
;     COPY's own overwrite prompt) before the first byte is written.
;   - Every sector is read back via K_SECREAD immediately after being
;     written via K_SECWRITE and byte-compared against what was meant
;     to be there; any mismatch aborts immediately rather than
;     continuing to write a possibly-compromised kernel image.
;
; Single-pass design -- the file's total sector count comes directly
; from its directory entry's DIRENT_SIZE field (resolved via
; K_PATH_RESOLVE + K_DIR_OPEN + K_DIR_READ + f_strcmp, the same pattern
; COPY already uses to check whether its destination is a directory --
; see sys_install's own header comment for why reading through the
; whole file first, as an earlier version of this program did, is
; unnecessary: the size is already sitting in the directory entry).
; The only file content actually needed before the write pass begins is
; the first 512 bytes, read once to check the 'KRN' magic and then
; reused as the first sector written -- no throwaway read, and no
; rewind until just before the real write pass starts (which does need
; one, since the magic-check read already consumed sector 0).
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel_api.inc

            extrn   sys_install

; sys_install result codes (returned in D; 0 = success)
SYSERR_READ:        equ     1   ; magic-check read error
SYSERR_MAGIC:       equ     2   ; missing 'KRN' signature
SYSERR_TOOSMALL:    equ     3   ; file under KRNBOOT_SECTORS*512 bytes
SYSERR_CANCELLED:   equ     4   ; user declined the confirmation prompt
SYSERR_SEEK:        equ     5   ; K_FILE_SEEK (rewind before the write
                                ; pass) failed
SYSERR_READ2:       equ     6   ; write-pass read error, or file shorter
                                ; than its own directory entry claimed
SYSERR_WRITE:       equ     7   ; K_SECWRITE failed
SYSERR_VERIFY_READ: equ     8   ; K_SECREAD (post-write verify) failed
SYSERR_MISMATCH:    equ     9   ; written sector doesn't read back the same
SYSERR_STAT:        equ     10  ; directory-entry lookup failed (not
                                ; found, or is a directory) -- shouldn't
                                ; happen given K_FILE_OPEN already
                                ; opened this same path as a file;
                                ; defensive only

            org     PROG_BASE

            db      'E','D','F'         ; ELF-DOS program magic
            db      1                   ; program major version
            dw      0                   ; reserved

;------------------------------------------------------------------
; Program entry point - PROG_BASE + $06
;------------------------------------------------------------------
start:
            ; RA = command tail = the kernel-full.bin filename
            ldn     ra
            lbnz    have_name

            call    K_INMSG
            db      "Usage: SYS <kernel-full.bin>",13,10,0
            ldi     1                   ; exit code 1 = error
            rtn

have_name:
            ; stash the filename pointer for sys_install's own later
            ; directory-entry lookup -- RA is not guaranteed to survive
            ; the K_FILE_OPEN call below (gotcha #8: assume clobbered
            ; unless proven otherwise), so it has to be saved before
            ; that call, not read back out afterward.
            mov     rf, sys_path_ptr
            ghi     ra
            str     rf
            inc     rf
            glo     ra
            str     rf                  ; sys_path_ptr = filename pointer

            mov     rf, ra              ; RF = filename
            mov     rd, sys_fcb_struct  ; RD = our FCB struct
            mov     ra, sys_iobuf       ; RA = our I/O buffer -- movs
                                        ; before the mode load below,
                                        ; since mov clobbers D (this is
                                        ; safe even though sys_path_ptr
                                        ; already captured RA's INCOMING
                                        ; value above, since that capture
                                        ; already happened before this
                                        ; point)
            ldi     0                   ; mode = read
            call    K_FILE_OPEN         ; D = handle, DF=0/1
            lbdf    open_error

            ; BUG-CLASS GUARD: stash the handle before "mov rf, ..."
            ; clobbers D -- saved_handle is what K_FILE_CLOSE uses below,
            ; after sys_install (a leaf worker that clobbers everything)
            ; has long since destroyed D's original value.
            plo     r8                  ; R8.0 = handle (temp)
            mov     rf, saved_handle
            glo     r8
            str     rf                  ; saved_handle = handle

            glo     r8                  ; D = handle again, for sys_install
            call    sys_install         ; D = result code (0 = success)
            ; BUG-CLASS GUARD (see progs/type.asm/wtest.asm): stash the
            ; result before "mov rf, ..." for K_FILE_CLOSE's own arg
            ; setup clobbers D.
            plo     r8                  ; R8.0 = sys_install's result

            mov     rd, saved_handle
            ldn     rd
            call    K_FILE_CLOSE        ; result/DF here intentionally
                                        ; ignored -- sys_install's own
                                        ; result is what we report

            glo     r8
            lbz     xfer_success
            smi     SYSERR_CANCELLED
            lbz     xfer_cancelled

            ; some other, real failure -- reload the code (the smi
            ; above clobbered D) and report it
            glo     r8
            lbr     xfer_failed

xfer_success:
            call    K_INMSG
            db      "Kernel installed. Run REBOOT to load it.",13,10,0
            ldi     0                   ; exit code 0 = success
            rtn

xfer_cancelled:
            call    K_INMSG
            db      "Cancelled -- nothing was written.",13,10,0
            ldi     0                   ; exit code 0 -- user's own
                                        ; choice, not an error
            rtn

xfer_failed:
            ; D = sys_install's numeric result code; print it alongside
            ; a generic message rather than maintaining a separate
            ; string per code -- see the equ's above for what each
            ; code means, and sys_install's own header comment for
            ; where each one is actually detected.
            adi     '0'
            plo     r8
            call    K_INMSG
            db      "Install failed (error ",0
            glo     r8
            call    K_TYPE
            call    K_INMSG
            db      ").",13,10
            db      "Boot device not confirmed consistent --",13,10
            db      "do not reboot without checking from a host.",13,10,0
            ldi     1
            rtn

open_error:
            call    K_INMSG
            db      "File not found.",13,10,0
            ldi     1
            rtn

sys_fcb_struct: ds      FCB_LEN
sys_iobuf:      ds      FCB_IOBUF_LEN
saved_handle:   db      0
sys_path_ptr:   dw      0

;==================================================================
; sys_install: given an already-open kernel-full.bin file, resolve its
; size from its own directory entry, validate it, confirm with the
; user, then write it to the boot device's raw sectors, patching the
; bootstrap header's sector-count field along the way. See this file's
; own top-of-file header comment for the full protocol/safety
; rationale.
;
; Why a directory-entry lookup instead of reading through the file:
; the total sector count is needed up front to patch the bootstrap
; header (which lives in the very first sector -- a chicken-and-egg
; problem an earlier version of this program solved by reading the
; whole file once just to count sectors, then rewinding via
; K_FILE_SEEK and doing the real work in a second pass). But the
; file's exact size is already sitting in its own directory entry
; (DIRENT_SIZE) -- the same field progs/dir.asm's own size column
; already reads -- so a small, fixed-cost directory scan (mirroring
; COPY's own K_PATH_RESOLVE/K_DIR_OPEN/K_DIR_READ destination-directory
; check) replaces an O(file size) read-through with an O(directory
; size) lookup. The only file content genuinely needed before the
; write pass is the very first 512 bytes, for the 'KRN' magic check --
; read once here and reused as the first sector written, not
; discarded and re-read.
;
; Args:    D = handle of an already-open file (mode 0 -- read);
;          also reads sys_path_ptr (memory, set by the caller in
;          progs/sys.asm's own "have_name" before K_FILE_OPEN clobbers
;          RA) for this routine's own directory-entry lookup -- the
;          same "caller sets a memory location before calling, callee
;          reads it" convention already used for mr_io_mode/ms_io_mode.
; Returns: D  = 0 on success, SYSERR_* on failure (see equ's above)
;          DF = 0 on success, DF = 1 on failure (redundant with D,
;               kept for consistency with this project's other calls)
; Clobbers: everything except the FCB itself and whatever the caller
;          separately preserved -- this is a leaf worker, not a
;          register-preserving subroutine. Does not close the FCB;
;          the caller does that once, after this returns, regardless
;          of success or failure -- see progs/mr.asm's start/have_name
;          for the identical pattern this mirrors.
;
; No hand-written short branches or page-alignment needed here (unlike
; mr_receive/ms_send) -- nothing in this routine is a per-byte hot
; loop; correctness matters far more than raw speed for a one-time
; install, so every branch here is an ordinary lbz/lbnz left for -r to
; shrink normally.
;
; Every 16-bit value that must survive more than one call keeps both
; halves in separate memory bytes, read/written via two independent
; instructions rather than relying on their adjacency in the data
; section below (see progs/ms.asm's own header comment for why this
; project doesn't rely on that) -- purely a consistency choice here,
; not a response to any hardware finding specific to this file.
;==================================================================

            proc    sys_install
            plo     rc                  ; RC.0 = handle (temp)
            mov     rf, sys_handle
            glo     rc
            str     rf                  ; sys_handle = handle

;------------------------------------------------------------------
; Resolve the file's size from its own directory entry -- see this
; proc's header comment above for why this replaces a read-through.
;------------------------------------------------------------------
            mov     rf, sys_path_ptr
            lda     rf
            phi     rc
            ldn     rf
            plo     rc                  ; RC = filename string pointer

            mov     rf, rc              ; RF = filename path
            call    K_PATH_RESOLVE      ; RD = parent cluster, RF = final
                                        ; component, RC.0 = resolved
                                        ; drive (unused here -- SYS's
                                        ; install target is always the
                                        ; fixed boot sectors regardless
                                        ; of drive, see this file's own
                                        ; header comment), DF = 0/1
            lbdf    sys_stat_err        ; bad intermediate component, or
                                        ; an "X:" prefix named an
                                        ; unmounted drive

            ; an empty final component would mean the path names a
            ; directory, not a file -- shouldn't happen (K_FILE_OPEN
            ; already opened this same path as a file), guarded anyway
            ldn     rf
            lbz     sys_stat_err

            ; save the final-component pointer: K_DIR_READ clobbers
            ; registers internally (R9/RA/RB/RC/RD/RF per COPY's own
            ; note), so nothing survives in a register across the scan
            ; loop below
            mov     rb, sys_statname_ptr
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb

            ; RD is still the resolved parent cluster from
            ; K_PATH_RESOLVE
            call    K_DIR_OPEN

sys_stat_loop:
            mov     rf, sys_dirent_buf
            call    K_DIR_READ
            lbdf    sys_stat_err        ; end of directory: no match
                                        ; (shouldn't happen -- see above)

            mov     rf, sys_statname_ptr
            lda     rf
            phi     rd
            ldn     rf
            plo     rd
            mov     rf, sys_dirent_buf
            call    f_strcmp
            lbnz    sys_stat_loop       ; no match: keep looking

            ; found it -- must not be a directory
            mov     rf, sys_dirent_buf
            add16   rf, DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    sys_stat_err

            ; extract DIRENT_SIZE's low 16 bits (bytes DIRENT_SIZE+2,
            ; DIRENT_SIZE+3 -- same "low word only" convention already
            ; used by progs/dir.asm's own size column; a kernel file is
            ; nowhere near the 64K this would start truncating)
            mov     rf, sys_dirent_buf
            add16   rf, DIRENT_SIZE
            add16   rf, 2               ; RF = &dirent[DIRENT_SIZE+2]
            lda     rf                  ; D = size byte (low word MSB),
                                        ; RF++
            phi     r7
            ldn     rf                  ; D = size byte (low word LSB) --
                                        ; fresh read, RF not advanced
                                        ; further
            plo     r7                  ; R7 = file size (16-bit)

            mov     rd, sys_size_hi
            ghi     r7
            str     rd
            mov     rd, sys_size_lo
            glo     r7
            str     rd

;------------------------------------------------------------------
; "Too small" = under KRNBOOT_SECTORS*512 = 1536 bytes (can't even
; hold a full bootstrap, let alone a real kernel proper) -- checked
; directly against the exact size now that it's known, no short-read
; ambiguity to resolve the way an earlier, read-through version of
; this proc had to.
;------------------------------------------------------------------
            mov     rf, sys_size_hi
            ldn     rf
            smi     6                   ; DF=1 iff size.hi >= 6, i.e.
                                        ; size >= 1536 ($0600) -- 1536
                                        ; is an exact multiple of 256,
                                        ; same "compare just the high
                                        ; byte" trick as the original
                                        ; 512-byte check
            lbnf    sys_toosmall_err

;------------------------------------------------------------------
; sys_sectors = ceil(size / 512).
;   floor(size/512) = size.hi >> 1 -- since 512 = 0x200, dividing the
;   whole 16-bit value by 512 is the same as shifting its high byte
;   right by 1 bit (verified by hand: size=512 -> hi=2 -> 2>>1=1;
;   size=1023 -> hi=3 -> 3>>1=1; size=1024 -> hi=4 -> 4>>1=2).
;   Remainder check: nonzero iff size.hi was odd (the bit shr shifts
;   into DF) OR size.lo != 0; either one means round up for the
;   ceiling.
;------------------------------------------------------------------
            mov     rf, sys_size_hi
            ldn     rf
            shr                          ; D = size.hi >> 1, DF = the
                                        ; bit shifted out
            plo     r7
            ldi     0
            phi     r7                  ; R7 = floor(size/512)

            lbdf    sys_sectors_ceil    ; size.hi was odd: remainder,
                                        ; round up
            mov     rf, sys_size_lo
            ldn     rf
            lbz     sys_sectors_done    ; size.lo == 0 too: exact
                                        ; multiple of 512, no remainder
sys_sectors_ceil:
            glo     r7
            adi     1
            plo     r7
            lbnf    sys_sectors_done
            ghi     r7
            adi     1
            phi     r7
sys_sectors_done:
            mov     rd, sys_sectors_hi
            ghi     r7
            str     rd
            mov     rd, sys_sectors_lo
            glo     r7
            str     rd

;------------------------------------------------------------------
; Read the first 512 bytes to check the 'KRN' magic -- the one piece
; of validation that genuinely needs file content rather than just
; directory-entry metadata. This same chunk is reused as the first
; sector written in the write pass below (no throwaway read); a
; rewind only happens after the user confirms, right before that pass
; starts, since this read has already consumed sector 0.
;------------------------------------------------------------------
            mov     rf, sys_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc                  ; RC = 512
            mov     rd, sys_handle
            ldn     rd
            call    K_FILE_READ         ; RC = bytes actually read, DF=0/1
            lbdf    sys_magic_read_err

            ghi     rc
            lbnz    sys_check_magic     ; high byte nonzero: definitely
                                        ; >= 3 bytes
            glo     rc
            smi     3
            lbnf    sys_magic_err       ; < 3 bytes: can't hold 'KRN'
sys_check_magic:
            mov     rf, sys_buf
            ldn     rf
            xri     'K'
            lbnz    sys_magic_err
            inc     rf
            ldn     rf
            xri     'R'
            lbnz    sys_magic_err
            inc     rf
            ldn     rf
            xri     'N'
            lbnz    sys_magic_err

;------------------------------------------------------------------
; extra_sectors = sys_sectors - KRNBOOT_SECTORS (3) -- the value that
; gets patched into the bootstrap header, matching host-side
; elfdos-sys's own "total_sectors - KRNBOOT_SECTORS" exactly (both
; sides must stay in lockstep with boot/krnboot.asm's own sector
; count -- see that file's header comment for the multi-sector
; krnboot expansion this constant is part of).
; BUG-CLASS GUARD: caught on review before ever building (in this
; proc's original read-through version) -- an earlier draft computed
; each half into D via smi, then immediately did "mov rd,
; sys_extra_hi/lo" (which clobbers D, gotcha #4) right before the str
; that was supposed to save it, silently storing the mov's own address
; byte instead of the computed result. Fixed by stashing both halves
; in R7 (free at this point in the proc) before either destination
; mov, reloading via glo/ghi immediately before each str.
;------------------------------------------------------------------
            mov     rf, sys_sectors_lo
            ldn     rf
            smi     3                   ; D = sectors_lo - 3, DF = borrow
            plo     r7                  ; stash low result

            mov     rf, sys_sectors_hi
            ldn     rf                  ; D = sectors_hi (DF from the
                                        ; smi above is unaffected by
                                        ; mov/ldn, still valid here)
            lbdf    sys_extra_no_borrow
            smi     1                   ; only if the low byte borrowed
                                        ; (a borrow is always exactly 1,
                                        ; independent of the subtrahend)
sys_extra_no_borrow:
            phi     r7                  ; stash high result -- R7 now
                                        ; holds the full 16-bit result

            mov     rd, sys_extra_lo
            glo     r7
            str     rd                  ; sys_extra_lo = low result
            mov     rd, sys_extra_hi
            ghi     r7
            str     rd                  ; sys_extra_hi = high result

            call    sys_confirm         ; D = 0 (go) or 1 (cancelled)
            lbnz    sys_cancelled_err

            ; rewind before the write pass -- the magic-check read
            ; above already consumed the first 512 bytes
            mov     rd, sys_handle
            ldn     rd
            call    K_FILE_SEEK
            lbdf    sys_seek_err

;------------------------------------------------------------------
; Write pass: re-read the file from the start, patching the bootstrap
; header (sector 0 only) and writing+verifying every sector against
; the boot device. Bounded by sys_remain (copied from sys_sectors,
; counted down to zero) rather than by re-detecting EOF, so an
; unexpectedly short read here is treated as an error rather than
; silently truncating the install to fewer sectors than the directory
; entry claimed.
;------------------------------------------------------------------
            mov     rf, sys_remain_hi
            mov     rd, sys_sectors_hi
            ldn     rd
            str     rf
            mov     rf, sys_remain_lo
            mov     rd, sys_sectors_lo
            ldn     rd
            str     rf

            mov     rf, sys_lba_hi
            ldi     0
            str     rf
            mov     rf, sys_lba_lo
            ldi     1
            str     rf                  ; LBA starts at 1 -- LBA 0 is
                                        ; the MBR, never touched here

            mov     rf, sys_is_first_sector
            ldi     1
            str     rf

write_loop:
            ; pre-zero the buffer before every read: a short final read
            ; then just leaves its own untouched tail as zero, with no
            ; need to compute how many bytes to pad -- see this proc's
            ; own header comment
            mov     rf, sys_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc
            dec     rc                  ; RC = 511 (loop runs 512 times
                                        ; when seeded with 511)
sys_zero_loop:
            ldi     0
            str     rf
            inc     rf

            dec     rc
            ghi     rc
            xri     $ff
            lbnz    sys_zero_loop

            mov     rf, sys_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc                  ; RC = 512 again, the request
                                        ; size (independent of what the
                                        ; zero loop above did to it)
            mov     rd, sys_handle
            ldn     rd
            call    K_FILE_READ
            lbdf    w_read_err

            ; RC == 0 while sectors remain expected is an unexpected
            ; shrink relative to what the directory entry claimed --
            ; treat as an error rather than silently writing an
            ; all-zero sector
            glo     rc
            lbnz    w_have_bytes
            ghi     rc
            lbz     w_read_err
w_have_bytes:

            mov     rf, sys_is_first_sector
            ldn     rf
            lbz     w_not_first
            ldi     0
            str     rf

            ; patch sys_buf[4] = extra_sectors_hi, sys_buf[5] =
            ; extra_sectors_lo (big-endian, matching host-side
            ; elfdos-sys's own KERN_CNT_OFFSET convention)
            mov     rf, sys_buf
            add16   rf, 4               ; RF = &sys_buf[4]
            mov     rd, sys_extra_hi
            ldn     rd
            str     rf                  ; sys_buf[4] = extra_sectors_hi
            inc     rf
            mov     rd, sys_extra_lo
            ldn     rd
            str     rf                  ; sys_buf[5] = extra_sectors_lo

w_not_first:
            ; --- write ---
            ; BUG-CLASS GUARD: R8.0 is LBA bits 23-16, which our 16-bit
            ; sys_lba counter never sets -- it must be a literal 0, NOT
            ; a load from sys_lba_hi (sys_lba_hi is bits 15-8, i.e.
            ; R7.1's value, not R8.0's).
            ldi     0
            plo     r8                  ; R8.0 = 0 (LBA bits 23-16)
            mov     rf, sys_lba_hi
            ldn     rf
            phi     r7                  ; R7.1 = LBA bits 15-8
            mov     rf, sys_lba_lo
            ldn     rf
            plo     r7                  ; R7.0 = LBA bits 7-0
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head, per
                                        ; K_SECWRITE/K_SECREAD's contract)
            mov     rf, sys_buf
            call    K_SECWRITE
            lbdf    sys_write_err

            ; --- read back and verify ---
            ; K_SECWRITE clobbers R7/R8 (same as f_idewrite itself),
            ; so the LBA must be reloaded from memory before the next
            ; call, exactly like every FCB index in this project is
            ; reloaded before each call that needs it rather than
            ; trusted to survive in a register. Same R8.0-is-a-literal-
            ; 0 guard as the write above.
            ldi     0
            plo     r8
            mov     rf, sys_lba_hi
            ldn     rf
            phi     r7
            mov     rf, sys_lba_lo
            ldn     rf
            plo     r7
            ldi     0
            phi     r8
            mov     rf, sys_verify_buf
            call    K_SECREAD
            lbdf    sys_verify_read_err

            ; --- compare sys_buf against sys_verify_buf, 512 bytes ---
            ; stxd/irx to hold the sys_buf byte across the sys_verify_buf
            ; load, same established pattern as progs/ms.asm's own
            ; header-field echo verification (safe regardless of
            ; whether any register survives a call, since the value
            ; lives on the hardware stack, not in a register, across
            ; nothing here anyway -- no call happens inside this loop)
            mov     rf, sys_buf
            mov     r8, sys_verify_buf
            ldi     2
            phi     rc
            ldi     0
            plo     rc
            dec     rc                  ; RC = 511
verify_loop:
            lda     rf                  ; D = sys_buf[i], RF++
            stxd
            lda     r8                  ; D = sys_verify_buf[i], R8++
            irx
            xor
            lbnz    sys_mismatch_err

            dec     rc
            ghi     rc
            xri     $ff
            lbnz    verify_loop

            ; --- advance LBA (16-bit increment) ---
            mov     rf, sys_lba_lo
            ldn     rf
            adi     1
            str     rf
            lbnf    w_lba_no_carry
            mov     rf, sys_lba_hi
            ldn     rf
            adi     1
            str     rf
w_lba_no_carry:

            ; --- decrement sys_remain (16-bit), loop while nonzero ---
            mov     rf, sys_remain_lo
            ldn     rf
            smi     1
            str     rf
            lbdf    w_remain_no_borrow
            mov     rf, sys_remain_hi
            ldn     rf
            smi     1
            str     rf
w_remain_no_borrow:
            mov     rf, sys_remain_hi
            ldn     rf
            lbnz    write_loop
            mov     rf, sys_remain_lo
            ldn     rf
            lbnz    write_loop

            ldi     0                   ; success
            lbr     sys_exit

sys_stat_err:
            ldi     SYSERR_STAT
            lbr     sys_exit
sys_toosmall_err:
            ldi     SYSERR_TOOSMALL
            lbr     sys_exit
sys_magic_read_err:
            ldi     SYSERR_READ
            lbr     sys_exit
sys_magic_err:
            ldi     SYSERR_MAGIC
            lbr     sys_exit
sys_cancelled_err:
            ldi     SYSERR_CANCELLED
            lbr     sys_exit
sys_seek_err:
            ldi     SYSERR_SEEK
            lbr     sys_exit
w_read_err:
            ldi     SYSERR_READ2
            lbr     sys_exit
sys_write_err:
            ldi     SYSERR_WRITE
            lbr     sys_exit
sys_verify_read_err:
            ldi     SYSERR_VERIFY_READ
            lbr     sys_exit
sys_mismatch_err:
            ldi     SYSERR_MISMATCH

sys_exit:   ; D = result code (0 = success); set DF to match
            lbz     sys_ok
            stc
            lbr     sys_ret
sys_ok:     clc
sys_ret:    rtn

;------------------------------------------------------------------
; sys_confirm: print the sector count and a clear warning, then
; require an explicit Y/N answer before the write pass is allowed to
; touch the disk. Same K_READ/K_TTY-based pattern as COPY's own
; overwrite prompt -- only 'Y'/'y' confirms; anything else, including
; a bare Enter, cancels (this project's own deliberate choice for
; COPY, reused here since the stakes are at least as high).
;
; Args: none (reads sys_sectors_hi/lo directly)
; Returns: D = 0 to proceed, D = 1 if the user declined
; Clobbers: everything -- same leaf-worker convention as the rest of
;          this file.
;------------------------------------------------------------------
sys_confirm:
            call    K_INMSG
            db      "Kernel file is ",0

            mov     rf, sys_sectors_hi
            ldn     rf
            phi     rd
            mov     rf, sys_sectors_lo
            ldn     rf
            plo     rd                  ; RD = sys_sectors (16-bit)
            mov     rf, sys_num_buf
            call    f_uintout           ; writes decimal ASCII into
                                        ; *rf, advances rf, does NOT
                                        ; null-terminate itself
            ldi     0
            str     rf                  ; null-terminate

            mov     rf, sys_num_buf
            call    K_MSG
            call    K_INMSG
            db      " sector(s).",13,10
            db      "This will OVERWRITE the boot device starting at",13,10
            db      "LBA 1. A failed or interrupted write can leave",13,10
            db      "the system unable to boot.",13,10
            db      "Continue? (Y/N) ",0

            call    K_READ              ; D = character read (blocking)
            ; BUG-CLASS GUARD: stash in memory, not a register, across
            ; the K_TTY/K_INMSG calls below -- see progs/copy.asm's own
            ; overwrite prompt for the identical reasoning (only R9's
            ; survival across f_msg/f_inmsg is confirmed; K_TTY hasn't
            ; been separately audited for any register). RC is only
            ; used here as a very short-lived stash to survive "mov rf,
            ; sys_answer_char"'s own D-clobber (gotcha #4) -- not
            ; across any call.
            plo     rc
            mov     rf, sys_answer_char
            glo     rc
            str     rf                  ; sys_answer_char = character

            call    K_TTY               ; echo it back to the console
            call    K_INMSG
            db      13,10,0

            mov     rf, sys_answer_char
            ldn     rf                  ; D = the character read
            ani     $DF                 ; fold lowercase to uppercase
            xri     'Y'
            lbnz    sys_confirm_no

            ldi     0                   ; proceed
            rtn
sys_confirm_no:
            ldi     1                   ; declined
            rtn

sys_handle:             db      0
sys_statname_ptr:       dw      0
sys_dirent_buf:         ds      DIRENT_LEN
sys_size_hi:            db      0
sys_size_lo:            db      0
sys_sectors_hi:         db      0
sys_sectors_lo:         db      0
sys_extra_hi:           db      0
sys_extra_lo:           db      0
sys_remain_hi:          db      0
sys_remain_lo:          db      0
sys_lba_hi:              db      0
sys_lba_lo:              db      0
sys_is_first_sector:    db      0
sys_answer_char:        db      0
sys_num_buf:            ds      6       ; up to 5 decimal digits + null
sys_buf:                ds      512
sys_verify_buf:         ds      512
            endp

            end     start
