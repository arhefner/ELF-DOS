;
; krnboot.asm - Kernel bootstrap sectors
;
; This is the kernel bootstrap, occupying disk sectors 1-3
; (KRNBOOT_SECTORS = 3, as of the multi-sector expansion below).
; The MBR loads all 3 sectors to $4400 and enters at $4406.
;
; KERN_BASE ($0100, where the kernel proper loads to) has stayed put;
; it's THIS bootstrap's own load address (KERN_LOAD, in mbr.asm) that
; has moved as the kernel grew -- $3000 originally, then $3800, then
; $4600, then $4200, then $4400 (see mbr.asm's header comment for the
; full story). Growing this bootstrap from 1 sector to 3 does not move
; KERN_LOAD itself -- it's still the same starting address, just now MBR reads 3
; consecutive sectors into it instead of 1.
;
; It reads the kernel sector count from its own header at $4404,
; then loads the kernel proper (sectors 4..N, shifted from 2..N now
; that this bootstrap itself spans 3 sectors instead of 1) sequentially
; into RAM starting at $0100, and jumps to the kernel entry at $0106.
;
; By loading the kernel to $0100 the bootstrap overwrites itself
; in RAM as the kernel grows, but that is fine -- this code is
; only needed once and is never called again after the jump to
; $0106. (This is a DIFFERENT overwrite than the one described
; above: this one is intentional and harmless, since nothing needs
; this code anymore once KERN_ENTRY is reached; the $3000 one was
; the load loop overwriting itself mid-flight, before reaching that
; point.)
;
; Header layout (6 bytes at $4400-$4405):
;   $4400-$4402  'KRN'  3-byte magic signature
;   $4403        $01    kernel major version
;   $4404-$4405  word   number of sectors to load (big-endian)
;                       patched by the 'sys' install utility
;   $4406        ...    entry point (code starts here)
;
; The 'sys' utility computes the sector count as:
;   (file_size_in_bytes - KRNBOOT_SECTORS*512) / 512
; rounded up, where the subtraction accounts for this bootstrap's own
; sectors, which have already been loaded by the time this header
; field is consulted.
;
; Krnboot slack-space reclaim, extended (multi-sector expansion): the
; original 2b pass reclaimed sector 1's own ~330 bytes of dead padding
; for the one-time init code below (baud rate config, both startup
; banners, the bpb_init/fat_init/file_init calls). This later pass
; goes further: bpb_init's own BODY (not just the call to it) is now
; inlined directly below too, which needed 2 more sectors of room
; (997 bytes generated, verified 2026-07-12) -- still free real estate
; by the same reasoning as 2b, since this whole region is dead the
; instant KERN_ENTRY is reached, exactly like the load loop itself.
;
; The one thing that couldn't move here: kernel_init's mem_top/
; mem_base/drive_cur_dir/cur_drive writes. Those touch kernel-
; resident, relocatable-address data -- this file is linked completely
; separately from kernel.bin (its own link02 invocation, boot/
; krnboot.prg only), so it has no way to reach a relocatable kernel
; symbol directly, only fixed, absolute addresses. The K_FAT_INIT/
; K_FILE_INIT calls below work because a jump-table slot IS a fixed
; address (same mechanism every program already uses to call into the
; kernel) -- there's no equivalent fixed-address path for writing to a
; data label whose own position shifts across kernel rebuilds.
; bpb_init's own fields (part1_lba etc.) are the exception: BPB_DATA_PTR
; (see kernel_api.inc) is a SECOND fixed-address mechanism, a pointer
; rather than a jump-table slot, purpose-built so this file's own
; inlined bpb_init body (below) can write those specific fields
; directly without needing a K_BPB_INIT call at all -- K_BPB_INIT's
; jump-table slot itself is now a harmless stub (kernel.asm), since
; this is the only place that ever called it. DRIVE_DATA_PTR
; (2026-07-13) is a THIRD such pointer, same mechanism, for the
; multi-partition drive_present/drive_bpb_table arrays this file's
; boot-time scan (below) now populates for every drive, not just the
; boot partition.
;

#include    include/bios.inc
#include    include/opcodes.def
#include    include/kernel_api.inc
#include    include/memmap.inc

#define     KERN_BASE   $0100           ; kernel proper loads here
#define     KERN_ENTRY  $0106           ; kernel proper entry point
#define     SECTOR_SIZE $0200           ; 512 bytes per sector
#define     CNT_ADDR    $4404           ; volatile sector count in header
#define     NV_CNT_ADDR $4409           ; non-volatile sector count in header
#define     LAST_ADDR   $440B           ; bytes used in the last NV sector

            org         $4400

;--------------------------------------------------------------
; Header ($4400-$440A)
;
; MBR enters at $4406 unconditionally, so the entry point CANNOT move.
; The split memory model needs a second sector count (the non-volatile
; image), which is therefore placed AFTER a 3-byte "lbr boot_main" at
; the entry rather than before it -- that keeps $4406 valid and leaves
; boot/mbr.asm completely untouched (no MBR reinstall needed for this
; change).
;
;   $4400-$4402  'KRN'  magic
;   $4403        $01    kernel major version
;   $4404-$4405  word   VOLATILE sector count   -- patched by sys
;   $4406-$4408  lbr boot_main  <- KERN_ENTRY, must stay here
;   $4409-$440A  word   NON-VOLATILE sector count -- patched by sys
;   $440B-$440C  word   bytes used in the LAST non-volatile sector,
;                       1..512 -- patched by tools/split_kernel.py
;--------------------------------------------------------------
            db          'K','R','N'     ; 3-byte magic signature
            db          1               ; kernel major version
            dw          0               ; volatile sectors -- patched by sys
            lbr         boot_main       ; $4406 -- MBR's entry point
            dw          0               ; non-volatile sectors -- ditto
            dw          0               ; bytes in last NV sector -- ditto

;--------------------------------------------------------------
; Bootstrap entry point (reached via the lbr at $4406)
; On entry: SCRT initialized, stack at top of RAM (set by the MBR)
;--------------------------------------------------------------
boot_main:
            ; read kernel sector count from our own header
            ldi         CNT_ADDR.1
            phi         rf
            ldi         CNT_ADDR.0
            plo         rf              ; RF = $4404
            lda         rf              ; D = high byte of sector count
            phi         rc
            lda         rf              ; D = low byte of sector count
            plo         rc              ; RC = total sectors to load

            ; sanity check -- if count is zero there is no kernel
            ghi         rc
            lbnz        boot_go
            glo         rc
            lbz         load_err        ; RC=0 means no kernel installed

            ; ---- load the VOLATILE image to $0100 ----
            ; LBA 6 (sector 0 = MBR, sectors 1-5 = this bootstrap)
boot_go:    ldi         6
            plo         r7              ; R7.0 = 6
            ldi         0
            phi         r7              ; R7.1 = 0
            plo         r8              ; R8.0 = 0
            phi         r8              ; R8.1 = 0
            mov         ra,KERN_BASE
            call        load_sectors    ; RC sectors -> [RA]; R7 advances
                                        ; past them, ready for the
                                        ; non-volatile image below

;--------------------------------------------------------------
; Find the top of usable RAM and move the stack there.
;
; Done BEFORE loading the non-volatile image, deliberately. The MBR
; leaves the stack at f_freemem's top of RAM, which on a RAM-only
; machine can sit INSIDE the region we are about to load the
; non-volatile kernel into -- loading it would then overwrite the very
; stack the load loop's own call/return is using. Searching first and
; moving the stack below NVK_BASE removes that overlap entirely.
;
; The highest RAM byte a program may use is the first RAM byte BELOW
; NVK_BASE (the non-volatile kernel is ROM on a 32K/32K machine, or
; loaded RAM on a RAM-only one -- either way it is off limits), so walk
; down from there testing each address until one reads back what we
; wrote. Two complementary patterns, because a single pattern can be
; matched by chance by a ROM byte that happens to equal it. Every byte
; tested is restored, so this is non-destructive.
;--------------------------------------------------------------
            mov         rf,NVK_BASE
            dec         rf              ; first candidate, just below it

boot_ram_try:
            ldn         rf
            plo         r9              ; save the original byte
            ldi         $A5
            str         rf
            ldn         rf
            xri         $A5
            lbnz        boot_ram_next
            ldi         $5A
            str         rf
            ldn         rf
            xri         $5A
            lbnz        boot_ram_next
            glo         r9
            str         rf              ; RAM: put the original byte back
            lbr         boot_ram_found

boot_ram_next:
            glo         r9
            str         rf              ; restore whatever was there
            dec         rf
            ; Refuse to search down into the kernel itself. Reaching
            ; here means there is no usable RAM below NVK_BASE at all --
            ; hang loudly rather than boot with a nonsense memory map.
            ghi         rf
            smi         high PROG_BASE
            lbnf        ram_err
            lbr         boot_ram_try

boot_ram_found:
            ; RF = highest usable RAM byte. Setting the stack here is
            ; ALSO how that value reaches the kernel: kernel_init reads
            ; R2 and derives mem_top from it (R2 - STACK_RESERVE_LEN),
            ; so no fixed handoff address is needed. Switching stacks is
            ; safe at this exact point -- boot_main was reached by a
            ; branch, not a call, so no return address is pending on the
            ; old stack, and SCRT balances every call made after this.
            mov         r2,rf

;--------------------------------------------------------------
; Non-volatile kernel: already resident, or load it?
;
; On a ROM machine the signature is burned in at NVK_BASE and there is
; nothing to do. On a RAM-only machine it is absent, and we load the
; same image to the same address from disk -- so one disk image boots
; both. R7 already points at the first non-volatile sector.
;--------------------------------------------------------------
            ; Is NVK_BASE writable? That, not the signature, is the
            ; question that matters.
            ;
            ; A signature only proves SOME non-volatile kernel is here,
            ; never that it is THIS one. RAM survives a warm reset, so
            ; after any reset the previous build's image is still sitting
            ; at NVK_BASE with a perfectly valid 'NVK' and version --
            ; and krnboot would skip the disk load and run it, while the
            ; VOLATILE half (jump table included) had just been reloaded
            ; fresh from disk. New table, old code, different layout:
            ; the first jump through the table lands in the middle of
            ; some unrelated routine. That is a wild jump, and on this
            ; hardware a wild jump writes to arbitrary LBAs and destroys
            ; the disk. It cost three cards before Tony spotted it.
            ;
            ; So: if the region is RAM its contents cannot be trusted,
            ; whatever they say, and we always load from disk. Only a
            ; genuinely unwritable region (ROM) can vouch for itself,
            ; and there the signature is meaningful. Two complementary
            ; patterns, since one could match a ROM byte by chance; the
            ; original byte is restored either way.
            mov         rf,NVK_BASE
            ldn         rf
            plo         r9                  ; save whatever is there
            ldi         $A5
            str         rf
            ldn         rf
            xri         $A5
            lbnz        boot_nv_is_rom      ; write did not take -> ROM
            ldi         $5A
            str         rf
            ldn         rf
            xri         $5A
            lbnz        boot_nv_is_rom
            glo         r9
            str         rf                  ; RAM: put the byte back and
            lbr         boot_load_nv        ; load unconditionally

boot_nv_is_rom:
            glo         r9
            str         rf                  ; harmless on ROM; correct if
                                            ; the first pattern did take
            call        check_nvk_sig
            lbz         boot_init0          ; genuine ROM copy, right version
            lbr         load_err            ; ROM present but not ours

boot_load_nv:
            mov         rf,NV_CNT_ADDR
            lda         rf
            phi         rc
            ldn         rf
            plo         rc              ; RC = non-volatile sector count
            ghi         rc
            lbnz        boot_nv_go
            glo         rc
            lbz         load_err        ; none in ROM and none on disk
boot_nv_go: mov         ra,NVK_BASE

            ; Load every sector but the last one straight to memory...
            dec         rc                  ; RC = full sectors (>= 0)
            call        load_sectors        ; a no-op if that leaves 0

            ; ...and the last one through a buffer, copying out only the
            ; bytes the image really occupies.
            ;
            ; WHY: a sector read always writes a full 512 bytes, so
            ; loading the last one directly would scribble up to 511
            ; bytes PAST the image. Those bytes are not merely wasted --
            ; on this hardware the non-volatile kernel sits just below an
            ; EEPROM, and a write into an EEPROM's address range starts
            ; an internal write cycle that takes the whole chip offline
            ; for milliseconds. The BIOS lives in that chip, so the very
            ; next SCRT return (fetched through R5, which points into
            ; BIOS ROM) reads a busy chip, executes garbage, and hangs
            ; with no output at all. That is exactly what NVK_BASE=$BD00
            ; did. Copying out an exact byte count makes it structurally
            ; impossible to write outside the image, so NVK_BASE no
            ; longer has to be hand-placed to dodge the overrun.
            ;
            ; boot_scratch is free here: every one of its other uses is
            ; inside boot_init2, which does not run until the load is
            ; finished.
            ;
            ; RA survives f_ideread -- load_sectors above already relies
            ; on exactly that, so it is established behaviour, not a new
            ; assumption. RC is NOT trusted across the call; it is
            ; reloaded from the header afterwards.
            mov         rf,boot_scratch
            call        f_ideread
            lbdf        load_err

            mov         rf,LAST_ADDR
            lda         rf
            phi         rc
            ldn         rf
            plo         rc                  ; RC = bytes in the last sector
            mov         rf,boot_scratch

            ; Test-before-copy, so a zero count copies nothing rather
            ; than wrapping to 65536 (DEC sets no flags on this CPU, so
            ; the check has to be explicit either way).
nv_copy:    ghi         rc
            lbnz        nv_copy_go
            glo         rc
            lbz         nv_copy_done
nv_copy_go: lda         rf                  ; D = byte, RF++
            str         ra                  ; store it, RA++ below
            inc         ra
            dec         rc
            lbr         nv_copy
nv_copy_done:

            ; It must really be there now. A silent miss here would hand
            ; control to whatever happens to occupy NVK_BASE -- exactly
            ; the kind of zero-output failure this project has hit
            ; before with boot code.
            call        check_nvk_sig
            lbnz        nv_err
boot_init0: lbr         boot_init2

;--------------------------------------------------------------
; check_nvk_sig: is the non-volatile kernel present at NVK_BASE?
; Returns D=0 (and the Z flag set) when the 'NVK' magic and version
; both match, non-zero otherwise. Clobbers D and RF.
;--------------------------------------------------------------
check_nvk_sig:
            mov         rf,NVK_BASE
            lda         rf
            xri         'N'
            lbnz        cns_no
            lda         rf
            xri         'V'
            lbnz        cns_no
            lda         rf
            xri         'K'
            lbnz        cns_no
            ldn         rf
            xri         NVK_SIG_VER     ; D=0 here means "present"
            rtn
cns_no:     ldi         1               ; any non-zero = "not present"
            rtn

;--------------------------------------------------------------
; load_sectors: read RC sectors from LBA R7:R8 into memory at RA.
; Advances RA and R7, leaves RC = 0. Branches to load_err on a read
; error rather than returning failure -- there is nothing useful a
; caller could do about it this early in the boot.
;--------------------------------------------------------------
load_sectors:
            ghi         rc              ; any sectors left?
            lbnz        ls_read
            glo         rc
            lbz         ls_done
ls_read:    mov         rf,ra           ; RF = current load address
            call        f_ideread       ; read sector into [RF]
            lbdf        load_err        ; DF=1 means read error
            add16       ra,SECTOR_SIZE  ; advance load address by 512
            inc         r7              ; advance to next LBA sector
            dec         rc              ; one fewer sector remaining
            lbr         load_sectors
ls_done:    rtn

;--------------------------------------------------------------
; Load error handler
;--------------------------------------------------------------
ram_err:    call        f_inmsg
            db          "No RAM below the non-volatile kernel",13,10,0
            lbr         load_halt

nv_err:     call        f_inmsg
            db          "Non-volatile kernel load failed",13,10,0
            lbr         load_halt

load_err:   call        f_inmsg
            db          "Kernel load error",13,10,0
load_halt:  lbr         load_halt       ; hang -- nothing to return to

;--------------------------------------------------------------
; boot_init2: one-time kernel init code relocated from kernel_init --
; see this file's own header comment for the full reasoning. Runs
; immediately after the sector load loop above, in the exact same
; SCRT/stack environment that loop already runs in (nothing here
; needs anything more than that).
;--------------------------------------------------------------
boot_init2:
            call        f_setbd             ; configure serial baud rate

            ; Print "ELF-DOS v<major>.<minor>" read live from the
            ; kernel's own header bytes at KERNEL_HDR_VER, rather than
            ; a hand-maintained literal -- mirrors progs/ver.asm's own
            ; already-proven approach exactly (same KERNEL_HDR_VER
            ; read, same f_uintout formatting), just via direct BIOS
            ; calls (f_inmsg/f_msg, not K_INMSG/K_MSG) since this is
            ; boot code, not a loaded program. Safe to read here: the
            ; entire kernel image, including its own header at $0100,
            ; has already been loaded into RAM by the sector loop
            ; above by the time load_done reaches boot_init2. RD is
            ; set to the destination first in each pair below, since
            ; "mov" itself clobbers D -- reading it afterward via
            ; lda/ldn is safe either way (see project notes).
            mov         rd, boot_ver_major
            mov         rf, KERNEL_HDR_VER
            lda         rf                  ; D = major version byte, RF++
            str         rd                  ; boot_ver_major = major byte
            inc         rd
            ldn         rf                  ; D = minor version byte
            str         rd                  ; boot_ver_minor = minor byte

            call        f_inmsg
            db          "ELF-DOS v",0

            mov         rf, boot_ver_major
            ldn         rf
            plo         rd
            ldi         0
            phi         rd
            mov         rf, boot_ver_buf
            call        f_uintout           ; writes decimal ASCII into *rf, advances rf
            ldi         0
            str         rf                  ; null-terminate
            mov         rf, boot_ver_buf
            call        f_msg

            call        f_inmsg
            db          ".",0

            mov         rf, boot_ver_minor
            ldn         rf
            plo         rd
            ldi         0
            phi         rd
            mov         rf, boot_ver_buf
            call        f_uintout
            ldi         0
            str         rf
            mov         rf, boot_ver_buf
            call        f_msg

            call        f_inmsg
            db          13,10,0

;--------------------------------------------------------------
; Inlined, multi-partition bpb_init (relocated from kernel/bpb.asm,
; then extended 2026-07-13 for up to MBR_PART_COUNT partitions -- see
; this file's own header comment for the original single-partition
; reasoning, still valid for why this lives here at all). Now a real
; LOOP over partition-table entries 0..MBR_PART_COUNT-1 (drives C..F),
; not unrolled -- four copies of the original ~700-byte Phase 1/
; Phase 2 body would never fit in this bootstrap's own sector budget.
; Three phases per iteration:
;
; Phase 1 (through the fat_csec write) computes one drive's BPB
; fields into LOCAL, krnboot-resident scratch variables
; (boot_part1_lba etc.) using the EXACT same register logic as the
; original single-partition bpb_init -- this part touches nothing
; kernel-resident. The MBR (sector 0) is re-read at the top of EVERY
; iteration, not just once, since each iteration's own VBR read
; (Step 3, present drives only) overwrites boot_scratch -- a fresh
; MBR read is the simplest way to recover the next entry's own
; partition-table bytes without a second buffer.
;
; A drive with a zero LBA-start field is treated as absent: Steps 3-8
; are skipped entirely, and every OTHER local scratch field (not
; boot_part1_lba, which is already 0 -- that's how absence is
; detected) is explicitly zeroed before Phase 2 runs, so an absent
; drive's drive_bpb_table entry ends up all-zero rather than carrying
; over stale values from a previous iteration. No partition-type-byte
; or VBR-signature validation, matching this project's own existing
; rigor level (the single-partition version never validated beyond
; "LBA-start nonzero" either).
;
; Phase 2 (the "copy into the real kernel-resident block" section
; further below) is UNCHANGED from the single-partition version except
; for what boot_bpb_base points at: it reads DRIVE_DATA_PTR (the fixed
; pointer kernel.asm populates at its own link time -- see
; kernel_api.inc's own header comment on it) once, before the loop, to
; find drive_present[0]'s real address; each iteration then computes
; &drive_present[idx] and &drive_bpb_table[idx] (the latter stashed
; into boot_bpb_base, exactly the variable name/role Phase 2's copy
; code already expects) from that one base pointer plus the loop
; index. Every one of Phase 2's per-field copy instructions is
; byte-identical to the single-partition version -- only the
; preamble that computes where boot_bpb_base points changed.
;--------------------------------------------------------------

            mov         rf,DRIVE_DATA_PTR
            lda         rf
            phi         rd
            ldn         rf
            plo         rd                  ; RD = drive_present[0]'s
                                            ; real, link-time-resolved
                                            ; address
            mov         rf,boot_drive_base
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf                  ; boot_drive_base =
                                            ; drive_present's address

            mov         rf,boot_drive_idx
            ldi         0
            str         rf                  ; boot_drive_idx = 0

boot_drive_loop:

; ---- Step 1: read MBR (sector 0) fresh every iteration -- see
; header comment above for why ----
            ldi         0
            plo         r7
            phi         r7
            plo         r8
            phi         r8                  ; LBA = 0

            mov         rf,boot_scratch
            call        f_ideread
            lbdf        boot_kern_err       ; read error

; ---- Step 2: extract THIS entry's start LBA. Offset within the MBR
; sector = PT_OFFSET + idx*PT_ENTRY_LEN + PT_LBA_OFF = $01BE +
; idx*16 + 8 = $01C6 + idx*16 -- low byte only (idx 0-3 keeps the
; result in $C6-$F6, never crossing into the high byte) ----
            mov         rf,boot_drive_idx
            ldn         rf                  ; D = idx (0-3)
            shl
            shl
            shl
            shl                             ; D = idx * PT_ENTRY_LEN (16)
            adi         $C6
            plo         rd
            ldi         $01
            phi         rd                  ; RD = this entry's LBA-
                                            ; start field offset

            mov         rf,boot_scratch
            add16       rf,rd               ; RF = boot_scratch + offset
            lda         rf
            plo         r7
            lda         rf
            phi         r7
            lda         rf
            plo         r8
            ldi         0
            phi         r8

            mov         rf,boot_part1_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- resolve this iteration's two destination addresses:
; &drive_present[idx] (-> boot_present_addr) and &drive_bpb_table[idx]
; (-> boot_bpb_base, the same variable Phase 2 below already expects)
; -- both derived from boot_drive_base plus idx (see
; kernel_api.inc's own DRIVE_DATA_PTR comment: drive_present[0..3] is
; followed immediately by drive_bpb_table[0..3]) ----
            mov         rf,boot_drive_idx
            ldn         rf
            plo         r9
            ldi         0
            phi         r9                  ; R9 = idx, zero-extended

            mov         rf,boot_drive_base
            lda         rf
            phi         rd
            ldn         rf
            plo         rd                  ; RD = drive_present's
                                            ; real address
            add16       rd,r9               ; RD = &drive_present[idx]
            mov         rf,boot_present_addr
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf

            mov         rf,boot_drive_base
            lda         rf
            phi         rd
            ldn         rf
            plo         rd                  ; RD = drive_present's
                                            ; real address (again)
            add16       rd,DRIVE_COUNT      ; RD = drive_bpb_table's
                                            ; real address

            glo         r9
            lbz         boot_bpb_off_done   ; idx 0: no offset to add
            plo         rc                  ; RC.0 = remaining count
boot_bpb_off_loop:
            add16       rd,BPBBLK_LEN
            dec         rc
            glo         rc
            lbnz        boot_bpb_off_loop
boot_bpb_off_done:
            mov         rf,boot_bpb_base
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf                  ; boot_bpb_base =
                                            ; &drive_bpb_table[idx]

; ---- presence check: is this entry's LBA-start nonzero? ----
            mov         rf,boot_part1_lba
            lda         rf
            lbnz        boot_drive_present
            lda         rf
            lbnz        boot_drive_present
            ldn         rf
            lbnz        boot_drive_present

; ---- absent: drive_present[idx] = 0; zero every OTHER local
; scratch field (boot_part1_lba is already 0) so Phase 2 below
; writes an all-zero drive_bpb_table entry, then skip straight to
; Phase 2 -- no VBR read, no Steps 4-8 ----
            mov         rf,boot_present_addr
            lda         rf
            phi         rd
            ldn         rf
            plo         rd
            mov         rf,rd
            ldi         0
            str         rf                  ; drive_present[idx] = 0

            mov         rf,boot_fat_lba
            ldi         18                  ; boot_fat_lba..boot_max_clust,
                                            ; contiguous, 18 bytes (see
                                            ; the scratch declarations
                                            ; below). Was 20 while
                                            ; boot_fat_csec still existed.
            plo         rc
boot_absent_zero:
            ldi         0
            str         rf
            inc         rf
            dec         rc
            glo         rc
            lbnz        boot_absent_zero

            lbr         boot_drive_copy

boot_drive_present:
            mov         rf,boot_present_addr
            lda         rf
            phi         rd
            ldn         rf
            plo         rd
            mov         rf,rd
            ldi         1
            str         rf                  ; drive_present[idx] = 1

; ---- Step 3: read VBR (this partition's first sector) ----
            mov         rf,boot_scratch
            call        f_ideread
            lbdf        boot_kern_err       ; read error

; ---- Step 4: sectors-per-cluster, spc_shift ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_SPC
            plo         rd
            add16       rf,rd
            ldn         rf                  ; D = sectors_per_cluster
            plo         r9

            mov         rf,boot_spc
            glo         r9
            str         rf

            ldi         0
            plo         rc
            glo         r9
boot_spc_loop:
            shr
            lbdf        boot_spc_done
            inc         rc
            lbr         boot_spc_loop
boot_spc_done:
            mov         rf,boot_spc_shift
            glo         rc
            str         rf

; ---- Phase 1, Step 5: fat_lba = part1_lba + reserved_sectors ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_RSVD
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = reserved_sector_count

            mov         rf,boot_part1_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = fat_lba

            mov         rf,boot_fat_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 6: root_lba = fat_lba + num_fats*spf; also
; num_fats, spf, max_clust ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_NFAT
            plo         rd
            add16       rf,rd
            ldn         rf
            phi         r9                  ; R9.1 = num_fats

            mov         rf,boot_num_fats
            ghi         r9
            str         rf

            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_SPF
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = sectors_per_fat

            mov         rf,boot_spf
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf

            ; max_clust = spf.lo - 1, $FF (re-read spf.lo from memory,
            ; matching the original bpb_init's own pattern)
            mov         rf,boot_spf
            inc         rf
            ldn         rf
            smi         1
            phi         rb
            ldi         $FF
            plo         rb

            mov         rf,boot_max_clust
            ghi         rb
            str         rf
            inc         rf
            glo         rb
            str         rf

            ; f_mul16: RF * RD -> RB
            mov         rf,rd               ; RF = sectors_per_fat
            ldi         0
            phi         rd
            ghi         r9
            plo         rd                  ; RD = num_fats (zero-extended)
            call        f_mul16             ; RB = num_fats * sectors_per_fat
            mov         rd,rb               ; RD = fat_sectors

            mov         rf,boot_fat_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = root_lba

            mov         rf,boot_root_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

; ---- Phase 1, Step 7: data_lba = root_lba + root_dir_sectors; also
; root_ents ----
            mov         rf,boot_scratch
            ldi         0
            phi         rd
            ldi         BPB_ROOTENT
            plo         rd
            add16       rf,rd
            lda         rf
            plo         rd
            ldn         rf
            phi         rd                  ; RD = root_entry_count

            mov         rf,boot_root_ents
            ghi         rd
            str         rf
            inc         rf
            glo         rd
            str         rf

            shr16       rd
            shr16       rd
            shr16       rd
            shr16       rd                  ; RD = root_dir_sectors

            mov         rf,boot_root_lba
            lda         rf
            plo         r8
            lda         rf
            phi         r7
            lda         rf
            plo         r7
            ldi         0
            phi         r8

            add16       r7,rd
            glo         r8
            adci        0
            plo         r8                  ; R7:R8.0 = data_lba

            mov         rf,boot_data_lba
            glo         r8
            str         rf
            inc         rf
            ghi         r7
            str         rf
            inc         rf
            glo         r7
            str         rf

;--------------------------------------------------------------
; Phase 2: copy every field computed above into drive_bpb_table[idx]
; -- boot_bpb_base was already set to that entry's real address by
; the per-iteration preamble earlier in the loop (both the present
; and absent branches set it before reaching here). Every instruction
; from here through the fat_csec copy is byte-identical to the
; original single-partition version; only what boot_bpb_base points
; at has changed.
;--------------------------------------------------------------
boot_drive_copy:

            ; part1_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_PART1_LBA
            mov         ra,boot_part1_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; fat_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_FAT_LBA
            mov         ra,boot_fat_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; root_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_ROOT_LBA
            mov         ra,boot_root_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; data_lba (3 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_DATA_LBA
            mov         ra,boot_data_lba
            lda         ra
            str         rf
            inc         rf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; spc (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPC
            mov         ra,boot_spc
            ldn         ra
            str         rf

            ; spc_shift (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPC_SHIFT
            mov         ra,boot_spc_shift
            ldn         ra
            str         rf

            ; root_ents (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_ROOT_ENTS
            mov         ra,boot_root_ents
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; num_fats (1 byte)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_NUM_FATS
            mov         ra,boot_num_fats
            ldn         ra
            str         rf

            ; spf (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_SPF
            mov         ra,boot_spf
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; max_clust (2 bytes)
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_MAX_CLUST
            mov         ra,boot_max_clust
            lda         ra
            str         rf
            inc         rf
            ldn         ra
            str         rf

            ; bpb_dev (1 byte) -- the block device this partition lives
            ; on. Always 0 here: every BIOS this runs on boots from unit
            ; 0 (MiniROM's own anyboot zeroes R7/R8.0 and never touches
            ; R8.1), and krnboot only ever scans the device it was
            ; itself loaded from. MOUNT is what sets a nonzero unit.
            ;
            ; Written explicitly rather than left to the zero-filled
            ; image: _switch_drive copies this into the active block and
            ; _set_lba_dev feeds it to the BIOS on EVERY disk access, so
            ; a garbage value here would misdirect every read and write
            ; on the system. Too load-bearing to rest on the linker's
            ; gap-fill behaviour.
            mov         rd,boot_bpb_base
            lda         rd
            phi         rf
            ldn         rd
            plo         rf
            add16       rf,BPBBLK_DEV
            ldi         0
            str         rf

            ; drive_letter[idx] = BOOT_DRIVE_FIRST + idx, giving C:, D:,
            ; E:, F: exactly as before letters became assignable. Slots
            ; past MBR_PART_COUNT keep the image's zero (= free) and are
            ; MOUNT's to hand out.
            ;
            ; C: must land on slot 0: kinit.asm's kshell_path is the
            ; literal "C:/bin/shell", and K_SHELL_INIT resolves it a few
            ; instructions after this loop finishes.
            ;
            ; drive_letter is NOT inside drive_bpb_table, so this walks
            ; from boot_drive_base (drive_present[0]) instead of
            ; boot_bpb_base: DRIVE_LETTER_OFF is relative to the former.
            mov         rf,boot_drive_idx
            ldn         rf
            plo         r9
            ldi         0
            phi         r9                  ; R9 = idx, zero-extended

            mov         rf,boot_drive_base
            lda         rf
            phi         rd
            ldn         rf
            plo         rd                  ; RD = drive_present's address
            add16       rd,DRIVE_LETTER_OFF
            add16       rd,r9               ; RD = &drive_letter[idx]

            glo         r9
            adi         BOOT_DRIVE_FIRST
            str         rd

; ---- advance to the next drive; loop while idx < MBR_PART_COUNT ----
            mov         rf,boot_drive_idx
            ldn         rf
            adi         1
            str         rf
            smi         MBR_PART_COUNT
            lbnf        boot_drive_loop     ; DF=0: still < MBR_PART_COUNT
                                            ; NOT DRIVE_COUNT: this loop
                                            ; walks the MBR's four primary
                                            ; entries, and its own offset
                                            ; arithmetic (idx*16 + $C6)
                                            ; only survives idx 0-3.

;--------------------------------------------------------------
; end of inlined, multi-partition bpb_init
;--------------------------------------------------------------

            call        K_FAT_INIT          ; invalidate FAT cache, clear dirty flag
            call        K_FILE_INIT         ; no-op (kept for symmetry
                                            ; with the other _INIT
                                            ; slots -- no kernel-
                                            ; resident file-layer state
                                            ; left to clear, see
                                            ; file.asm's own header)

            ; K_SHELL_INIT (2026-07-13): locate "C:/bin/shell"'s own
            ; directory entry and cache its (drive, sector LBA, byte
            ; offset) into shell_drive/shell_elba/shell_eoff -- see
            ; kernel.asm's own kernel_shell_init for the full mechanism
            ; and why (run_loop's own reload of the shell every command
            ; cycle reads that cached location directly instead of a
            ; full directory scan each time). kernel_shell_init calls
            ; _find_dirent directly, never file_open, so it has no
            ; dependency on K_FILE_INIT above -- works correctly this
            ; early -- before kernel_init's own cur_drive/
            ; drive_cur_dir zero-init has run -- only because the path
            ; it searches always has an explicit "C:" prefix (see
            ; kernel_shell_init's own header comment).
            call        K_SHELL_INIT
            lbdf        boot_no_shell_err   ; "C:/bin/shell" missing or
                                            ; invalid: fatal, same
                                            ; severity as any other
                                            ; boot-time failure here

;--------------------------------------------------------------
; IO_TYPE_TARGET/IO_READ_TARGET detection (see kernel.inc's own header
; comment on these two fixed words for the full design/motivation).
; mBIOS stores a rewritable 3-byte lbr vector at $003C (type)/$003F
; (read), already pointing at the correct real routine by the time
; anything else runs -- if the byte there is $C0 (the LBR opcode), the
; 2 bytes right after it ARE the real target, copy them directly.
; Classic BIOS has no such vector, so a non-$C0 byte falls back to
; checking RE's high byte the SAME WAY classic BIOS's own type:/read:
; entry points do: GHI RE / SHR / branch-on-zero -- deliberately NOT a
; raw comparison of RE.1 against 0, since bit 0 of RE.1 is the
; unrelated local-echo flag and must be shifted off first (confirmed
; directly against classic BIOS's own real source by the user). The
; shifted value is computed once, into boot_re_shifted, and reused for
; both the type and read fallback checks, since classic BIOS uses the
; same RE.1 flag for both directions.
;
; Also, unconditionally, force RE's own local-echo bit OFF here (bit 0
; of RE.1) -- confirmed on hardware 2026-08-26 (bit-bang UART): left
; however mBIOS/the ROM monitor happens to leave it, it can come up
; SET, which makes the BIOS's own read routine echo each character
; back itself, doubling up with this shell's own K_TYPE-based echo in
; read_line_with_history (progs/shell.asm) -- and tripling up if the
; terminal's own local echo is ALSO on. We only ever want ONE echo
; source (the shell's own), so this bit is cleared here, once, before
; any interactive read ever happens, regardless of which BIOS/UART
; scheme ends up detected below. Bits 1-7 (the real baud-rate timing
; constant used by the very check right after this) are completely
; unaffected by this single-bit AND mask -- ordering relative to the
; boot_re_shifted computation below doesn't matter either way, since
; GHI RE is a nondestructive read and SHR always discards bit 0
; regardless of its value.
;--------------------------------------------------------------
            ghi         re
            ani         $FE                 ; clear bit 0 (echo), leave
                                            ; bits 1-7 (baud/UART-select
                                            ; timing constant) untouched
            phi         re                  ; write back -- permanent
                                            ; for the rest of this boot
                                            ; session

            mov         rf, boot_re_shifted ; RF = dest, set BEFORE
                                            ; reading RE (mov itself
                                            ; clobbers D -- gotcha #4)
            ghi         re
            shr
            str         rf                  ; boot_re_shifted = RE.1
                                            ; >> 1 (echo bit discarded)

            ldi         high $003C
            phi         rf
            ldi         low $003C
            plo         rf
            ldn         rf                  ; D = byte at $003C
            xri         $C0
            lbnz        boot_io_type_fallback

            mov         r8, IO_TYPE_TARGET  ; R8 = dest, set BEFORE the
                                            ; reads below (gotcha #4)
            inc         rf                  ; RF = $003D
            lda         rf                  ; D = vector's high byte,
                                            ; RF -> $003E
            str         r8
            inc         r8
            lda         rf                  ; D = vector's low byte
            str         r8
            lbr         boot_io_read_check

boot_io_type_fallback:
            mov         r8, IO_TYPE_TARGET  ; R8 = dest, set BEFORE
                                            ; reading boot_re_shifted
            mov         rf, boot_re_shifted
            ldn         rf                  ; D = shifted RE.1
            lbnz        boot_io_type_bitbang

            ldi         high f_utype
            str         r8
            inc         r8
            ldi         low f_utype
            str         r8
            lbr         boot_io_read_check

boot_io_type_bitbang:
            ldi         high f_btype
            str         r8
            inc         r8
            ldi         low f_btype
            str         r8

boot_io_read_check:
            ldi         high $003F
            phi         rf
            ldi         low $003F
            plo         rf
            ldn         rf                  ; D = byte at $003F
            xri         $C0
            lbnz        boot_io_read_fallback

            mov         r8, IO_READ_TARGET  ; R8 = dest, set BEFORE the
                                            ; reads below (gotcha #4)
            inc         rf                  ; RF = $0040
            lda         rf                  ; D = vector's high byte,
                                            ; RF -> $0041
            str         r8
            inc         r8
            lda         rf                  ; D = vector's low byte
            str         r8
            lbr         boot_io_done

boot_io_read_fallback:
            mov         r8, IO_READ_TARGET  ; R8 = dest, set BEFORE
                                            ; reading boot_re_shifted
            mov         rf, boot_re_shifted
            ldn         rf                  ; D = shifted RE.1
            lbnz        boot_io_read_bitbang

            ldi         high f_uread
            str         r8
            inc         r8
            ldi         low f_uread
            str         r8
            lbr         boot_io_done

boot_io_read_bitbang:
            ldi         high f_bread
            str         r8
            inc         r8
            ldi         low f_bread
            str         r8

boot_io_done:
            ; Phase 2: self-modify K_TYPE's/K_READ's own jump-table slots
            ; (kernel/kernel.asm, $011E/$0157) to a bare "LBR <real
            ; routine>", using the SAME value just computed into
            ; IO_TYPE_TARGET/IO_READ_TARGET above -- see kernel.inc's own
            ; header comment on those two words, and kernel/redir.asm's
            ; module header, for the full design. The slot's own opcode
            ; byte ($C0) is already correct at link time (kernel.asm
            ; declares a self-referencing placeholder LBR there); only
            ; the 2-byte operand is written here. Runs after all 4
            ; detection branches above have converged, so this one block
            ; covers every case uniformly.
            mov         rf, IO_TYPE_TARGET  ; RF = dest, set BEFORE
                                            ; reading it (gotcha #4)
            lda         rf
            phi         r9
            ldn         rf
            plo         r9                  ; R9 = the real TYPE target

            ldi         high (K_TYPE+1)
            phi         rf
            ldi         low (K_TYPE+1)
            plo         rf                  ; RF = &K_TYPE's slot operand
            ghi         r9
            str         rf
            inc         rf
            glo         r9
            str         rf                  ; K_TYPE's slot now reads
                                            ; "LBR <real TYPE routine>"

            mov         rf, IO_READ_TARGET
            lda         rf
            phi         r9
            ldn         rf
            plo         r9                  ; R9 = the real READ target

            ldi         high (K_READ+1)
            phi         rf
            ldi         low (K_READ+1)
            plo         rf                  ; RF = &K_READ's slot operand
            ghi         r9
            str         rf
            inc         rf
            glo         r9
            str         rf                  ; K_READ's slot now reads
                                            ; "LBR <real READ routine>"

            lbr         KERN_ENTRY          ; continue into kernel_init proper

;--------------------------------------------------------------
; boot_init2 error handlers -- relocated from kernel.asm's kern_err,
; same message and behavior, just physically moved here along with
; the checks that reach them.
;--------------------------------------------------------------
boot_kern_err:
            call        f_inmsg
            db          "Kernel init failed",13,10,0
boot_kern_halt:
            lbr         boot_kern_halt

boot_no_shell_err:
            call        f_inmsg
            db          "No shell on C:.",13,10,0
            lbr         boot_kern_halt

;--------------------------------------------------------------
; Local scratch for the inlined bpb_init above (Phase 1's working
; variables plus its own 512-byte MBR/VBR read buffer). Deliberately
; NOT the kernel's own fat_cache -- keeps BPB_DATA_PTR's reach limited
; to exactly the 23-byte block it's meant for (see kernel_api.inc's
; own header comment on this), not a byte more. Field sizes match
; BPBBLK_* exactly, though these are plain local labels, not accessed
; via offsets themselves -- only the real, kernel-resident copies are.
;--------------------------------------------------------------
boot_part1_lba:     ds      3
boot_fat_lba:       ds      3
boot_root_lba:      ds      3
boot_data_lba:      ds      3
boot_spc:           db      0
boot_spc_shift:     db      0
boot_root_ents:     dw      0
boot_num_fats:      db      0
boot_spf:           dw      0
boot_max_clust:     dw      0
boot_bpb_base:      dw      0
boot_drive_idx:     db      0           ; loop counter, 0..MBR_PART_COUNT-1
boot_drive_base:    dw      0           ; DRIVE_DATA_PTR's resolved
                                        ; address (drive_present[0]),
                                        ; read once before the loop
boot_present_addr:  dw      0           ; this iteration's own
                                        ; &drive_present[idx]

; Scratch for boot_init2's own dynamic version-banner print, above --
; unrelated to the partition-scan fields just above, grouped here only
; to keep this file's single data-declaration area intact.
boot_ver_major:     db      0
boot_ver_minor:     db      0
boot_ver_buf:       ds      6           ; decimal scratch (max "65535"+null)

; Scratch for the IO_TYPE_TARGET/IO_READ_TARGET detection above --
; RE.1 with the local-echo bit (bit 0) shifted off, computed once and
; reused for both the type and read fallback checks.
boot_re_shifted:    db      0

boot_scratch:       ds      512

;--------------------------------------------------------------
; Pad to exactly 2560 bytes = 5 sectors (KRNBOOT_SECTORS). Grown from
; 3 sectors (1536 bytes) for the split memory model: this bootstrap now
; loads TWO images instead of one, checks the non-volatile signature,
; and searches for the top of usable RAM. Content measured at 2214
; bytes, so 4 sectors (2048) would not fit at all and 5 leaves 346
; bytes of real headroom, matching this project's own margin bar.
;
; Growing this MOVES THE KERNEL'S FIRST SECTOR (LBA 4 -> 6) and must
; stay in lockstep with boot/mbr.asm's KRNBOOT_SECTORS, sys/sys.c's
; KRNBOOT_SECTORS, and progs/sys.asm's own copy of the same math.
;
; NOTE (gotcha, hit once already on a different branch, 2026-07-20):
; this pad target is a HARDCODED ABSOLUTE ADDRESS, computed as
; origin+1536-1 -- it does NOT move automatically when the file's own
; leading "org" above changes. Recompute by hand every time PROG_BASE/
; KERN_LOAD moves, or krnboot.bin comes out the wrong size (silently,
; with no assembler error).
;--------------------------------------------------------------
            org         $4DFF
            db          0

            end         boot_main
