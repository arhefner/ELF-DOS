;
; kernel.asm - ELF-DOS kernel entry point, API jump table, and global data
;
; Assembled at org $0100.  The 6-byte header at $0100-$0105 is
; skipped by the bootstrap; kernel_main at $0106 is the true entry --
; it is now the first slot of the kernel API jump table (see below).
;
; Global data (static buffers, BPB cache, FCB table, etc.) lives
; at the END of this file so it links after all kernel code.
; Other modules declare what they need with 'extrn'.
;
; Link order:
;   kernel.asm  bpb.asm  fat.asm  dir.asm  path.asm  rtc.asm  file.asm
;   loader.asm
;
; As of the shell-as-a-program move, the shell is no longer part of
; the kernel image at all -- it's progs/shell.asm, an ordinary program
; loaded at /bin/shell. kernel_init's own run_loop (see below) does
; nothing but alternately load+run the shell (which resolves one
; command line and returns) and whatever it resolved -- see
; kernel.inc's RUN_PATH/RUN_TAIL_PTR comment for the full handoff
; protocol and why the shell can't do this itself.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   fat_init
            extrn   file_init
            extrn   mem_top
            extrn   mem_base
            extrn   cur_dir
            extrn   part1_lba

            extrn   file_open
            extrn   file_close
            extrn   file_read
            extrn   file_write
            extrn   file_seek
            extrn   file_delete
            extrn   dir_create
            extrn   dir_remove
            extrn   file_rename
            extrn   file_stat
            extrn   dir_open
            extrn   dir_read
            extrn   path_resolve
            extrn   prog_load
            extrn   prog_exec

; Kernel version -- single source of truth for the header bytes below,
; which programs read directly at the fixed KERNEL_HDR_VER address (see
; kernel_api.inc) rather than through a jump-table call, since $0100's
; layout is already a stable, never-shifting contract (same reasoning
; as PROG_BASE/LOADER_ARGS). Keep in sync with kernel_init's boot
; banner string below, which is a separate literal for simplicity (not
; worth generating dynamically at boot).
KERNEL_VER_MAJOR:   equ     0
KERNEL_VER_MINOR:   equ     1

            org     $0100

;------------------------------------------------------------------
; 6-byte header ($0100-$0105)
; Never executed -- bootstrap enters at $0106.
;------------------------------------------------------------------
            db      'E','D','F'         ; ELF-DOS kernel magic
            db      KERNEL_VER_MAJOR    ; kernel major version
            db      KERNEL_VER_MINOR    ; kernel minor version
            db      0                   ; reserved

;==================================================================
; Kernel API jump table - starts at $0106
;
; Fixed addresses for programs to call into, listed symbolically in
; include/kernel_api.inc (K_xxx equ's) for program code to #include.
; Each slot is exactly one 3-byte 'lbr' instruction, so slot N's
; address never changes as long as entries are only ever APPENDED
; here, never reordered or removed -- that stability is the entire
; point: a program built against an older kernel keeps working
; after the kernel is rebuilt, since it only ever calls through
; these fixed addresses, never the real (address-shifting) label.
;
; Slot 0 (kernel_main / K_INIT) is pinned by the boot chain itself
; (krnboot jumps to $0106) and isn't meant to be called by programs.
;
; Verify this table's actual addresses against kernel_api.inc after
; any change here with: link02 -s ... | grep '^k_'
;==================================================================
kernel_main:            ; $0106 - K_INIT (boot entry, reserved)
            lbr     kernel_init

k_file_open:    lbr     file_open           ; $0109
k_file_close:   lbr     file_close          ; $010C
k_file_read:    lbr     file_read           ; $010F
k_file_write:   lbr     file_write          ; $0112
k_file_seek:    lbr     file_seek           ; $0115
k_dir_open:     lbr     dir_open            ; $0118
k_dir_read:     lbr     dir_read            ; $011B
k_prog_load:    lbr     prog_load           ; $011E
k_prog_exec:    lbr     prog_exec           ; $0121
k_type:         lbr     f_type              ; $0124 (BIOS passthrough)
k_msg:          lbr     f_msg               ; $0127 (BIOS passthrough)
k_inmsg:        lbr     f_inmsg             ; $012A (BIOS passthrough)
k_getdev:       lbr     f_getdev            ; $012D (BIOS passthrough)
k_gettod:       lbr     f_gettod            ; $0130 (BIOS passthrough)
k_settod:       lbr     f_settod            ; $0133 (BIOS passthrough)
k_inputl:       lbr     f_inputl            ; $0136 (BIOS passthrough)
k_boot:         lbr     f_boot              ; $0139 (BIOS passthrough)
k_tty:          lbr     f_tty               ; $013C (BIOS passthrough)
k_setbd:        lbr     f_setbd             ; $013F (BIOS passthrough)
k_getcurdir:    lbr     kernel_getcurdir    ; $0142
k_setcurdir:    lbr     kernel_setcurdir    ; $0145
k_path_resolve: lbr     path_resolve        ; $0148
k_file_delete:  lbr     file_delete         ; $014B
k_dir_create:   lbr     dir_create          ; $014E
k_dir_remove:   lbr     dir_remove          ; $0151
k_file_rename:  lbr     file_rename         ; $0154
k_read:         lbr     f_read              ; $0157 (BIOS passthrough)

; K_FAT_INIT/K_FILE_INIT: boot-only, called exactly once each by
; boot/krnboot.asm's relocated init code (see kernel_init's own header
; comment below, and krnboot.asm's, for the full story) -- exist as
; jump-table slots only because krnboot.asm is linked completely
; separately from kernel.bin and has no other way to reach these
; kernel-resident routines. Not meant to be called by ordinary
; programs. K_BPB_INIT (still at $015A, the same append-only slot)
; no longer calls a real bpb_init -- see k_bpb_init_stub's own header
; comment (further down in this file) for why.
k_bpb_init:     lbr     k_bpb_init_stub     ; $015A
k_fat_init:     lbr     fat_init            ; $015D
k_file_init:    lbr     file_init           ; $0160

; K_SECWRITE/K_SECREAD: raw 512-byte sector read/write by LBA, bypassing
; the FAT16 filesystem entirely -- direct passthroughs to the same BIOS
; routines fat.asm itself uses for FAT/directory sector I/O. Args: R7/R8
; = 24-bit LBA (R8.0 = bits 23-16, R7.1 = bits 15-8, R7.0 = bits 7-0,
; R8.1 = 0, the drive/head byte -- see include/kernel.inc's own LBA
; storage format comment), RF = pointer to a 512-byte buffer (source for
; K_SECWRITE, destination for K_SECREAD). Returns: DF = 0/1 (success/
; error); R7/R8 are clobbered by the call, same as calling f_idewrite/
; f_ideread directly. DANGEROUS if misused -- a wrong LBA can silently
; corrupt the running filesystem or the boot sectors themselves; added
; specifically for progs/sys.asm (target-side kernel/MBR installer) and
; not intended for casual use by other programs.
k_secwrite:     lbr     f_idewrite          ; $0163 (BIOS passthrough)
k_secread:      lbr     f_ideread           ; $0166 (BIOS passthrough)

; K_STAT: resolve a path to its own directory entry without opening it
; as a file -- works on either a file or a directory. See
; kernel/file.asm's file_stat for the full contract (args/returns) and
; the motivation (a third caller, progs/stat.asm, was about to
; hand-roll the same path_resolve+dir_open/dir_read+f_strcmp scan
; progs/copy.asm and progs/sys.asm already each do inline).
k_stat:         lbr     file_stat           ; $0169

; BPB_DATA_PTR: a DATA slot (2 bytes, not a 3-byte lbr call target),
; sitting at the jump table's own tail by design (the user's own
; earlier proposal). Holds the real, link-time-resolved address of the
; BPB data block (part1_lba..fat_csec, 23 bytes, see kernel.inc's own
; BPBBLK_* offsets) -- boot/krnboot.asm's own separately-linked,
; relocated bpb_init body reads this fixed address to reach these
; kernel-resident fields, since it has no way to reference kernel.bin's
; normal relocatable symbols directly. Populated here, not by krnboot --
; this line is part of kernel.bin's own link, so "dw part1_lba" resolves
; to the block's real address automatically, same as any other
; relocatable reference.
                dw      part1_lba           ; $016C: BPB_DATA_PTR
                ; next free jump-table address: $016E

;------------------------------------------------------------------
; kernel_init: the original boot sequence (formerly "kernel_main"
; itself, before the jump table above took over that address).
;
; As of the krnboot slack-space reclaim, the one-time-only parts of
; the original boot sequence (baud rate config, both startup banners,
; and the bpb_init/fat_init/file_init calls with bpb_init's own error
; check) have moved to boot/krnboot.asm's relocated init code, which
; runs immediately before this point and falls through to KERN_ENTRY
; ($0106, this routine) once it's done -- see that file's own header
; comment for the full reasoning (that code is dead weight in the
; permanently-resident kernel image, since it never runs again after
; the first boot, but is free real estate in krnboot's own sector,
; which has 400+ bytes of unused padding after its own load loop).
; What's left here is only the part that genuinely can't move: writes
; to kernel-resident (relocatable) data, which krnboot.asm has no
; fixed-address way to reach (unlike the K_BPB_INIT/K_FAT_INIT/
; K_FILE_INIT calls above, which only needed a stable jump-table
; address, not a data address).
;
; On entry:
;   SCRT initialized (R3=PC, R4=call, R5=ret)
;   R2 = stack at top of RAM (set by bootstrap)
;   All other registers: undefined (bpb_init/fat_init/file_init have
;   already run, via krnboot.asm's own K_BPB_INIT/K_FAT_INIT/
;   K_FILE_INIT calls, by the time this point is reached)
;------------------------------------------------------------------
kernel_init:
            ; record top of RAM in mem_top
            ; f_freemem returns in RF; save it before RF is reused
            call    f_freemem           ; RF = address of last RAM byte
            mov     r9, rf              ; keep a copy in R9

            mov     rf, mem_top
            ghi     r9
            str     rf                  ; mem_top.hi
            inc     rf
            glo     r9
            str     rf                  ; mem_top.lo

            ; mem_base is set by loader at program load time
            mov     rf, mem_base
            ldi     0
            str     rf
            inc     rf
            str     rf                  ; mem_base = 0 until first program loads

            ; current directory = root (cluster 0 is the FAT16 root sentinel)
            mov     rf, cur_dir
            ldi     0
            str     rf
            inc     rf
            str     rf

;------------------------------------------------------------------
; run_loop: alternately load+run the shell (which resolves one
; command line and returns) and whatever it resolved. Lives entirely
; here, in kernel memory, so it's safe regardless of what's currently
; sitting at PROG_BASE -- see kernel.inc's RUN_PATH/RUN_TAIL_PTR
; comment for why the shell can't do this hand-off itself. Never
; returns.
;------------------------------------------------------------------
run_loop:
            mov     rf, shell_path
            call    prog_load
            lbdf    kern_shell_err      ; shell itself missing/corrupt: fatal

            call    prog_exec           ; runs the shell; it always
                                        ; returns with RUN_PATH/
                                        ; RUN_TAIL_PTR filled in

            mov     rf, RUN_PATH
            call    prog_load
            lbdf    run_bad_command     ; not found / bad magic

            mov     rf, RUN_TAIL_PTR
            lda     rf                  ; D = tail pointer high byte
            phi     ra
            ldn     rf                  ; D = tail pointer low byte
            plo     ra                  ; RA = command tail pointer
            call    prog_exec           ; D = exit code (unused for now)
            lbr     run_loop

run_bad_command:
            call    f_inmsg
            db      "Bad command.",13,10,0
            lbr     run_loop

; local literal, placed after every reachable path above already
; terminates via a branch, so control flow never falls through into
; it (same convention used for local literals elsewhere in this
; project, e.g. file_rename's ren_dot/ren_dotdot)
shell_path: db      "/bin/shell",0

kern_shell_err:
            call    f_inmsg
            db      "Shell not found or invalid.",13,10,0
kern_halt:  lbr     kern_halt

;------------------------------------------------------------------
; kernel_getcurdir: return the current directory cluster
; Args:    none
; Returns: RD = cur_dir (0 = FAT16 root)
;------------------------------------------------------------------
kernel_getcurdir:
            mov     rf, cur_dir
            lda     rf                  ; D = cur_dir high byte
            phi     rd
            ldn     rf                  ; D = cur_dir low byte
            plo     rd
            rtn

;------------------------------------------------------------------
; kernel_setcurdir: set the current directory cluster
; Args:    RD = new current directory cluster
; Returns: nothing
;------------------------------------------------------------------
kernel_setcurdir:
            mov     rf, cur_dir
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; k_bpb_init_stub: K_BPB_INIT's jump-table slot no longer points at a
; real routine -- bpb_init's body moved to boot/krnboot.asm's own
; inlined copy as part of the multi-sector krnboot expansion, and
; krnboot itself (the only caller K_BPB_INIT ever had) now reaches
; those fields directly via BPB_DATA_PTR instead of this call. Per
; this project's append-only jump-table rule (slots are never removed,
; so any future code that somehow still calls $015A gets defined
; behavior, not garbage), the slot stays and points here instead: a
; trivial always-succeeds no-op.
;------------------------------------------------------------------
k_bpb_init_stub:
            clc
            rtn

;==================================================================
; Global kernel data
;
; All static buffers and variables are defined here.  Placing data
; at the end keeps code addresses stable as variables are added.
; Other modules reference these via 'extrn'.
;==================================================================

; ----------------------------------------------------------------
; Disk geometry -- populated by bpb_init, read-only thereafter
;
; LBAs stored as 3 bytes: [bits 23-16, bits 15-8, bits 7-0]
; See LBA storage format in kernel.inc.
; ----------------------------------------------------------------
                proc    _kernel_data

part1_lba:      ds      LBA_SIZE        ; partition 1 start LBA
bpb_fat_lba:    ds      LBA_SIZE        ; LBA of FAT 1
bpb_root_lba:   ds      LBA_SIZE        ; LBA of root directory region
bpb_data_lba:   ds      LBA_SIZE        ; LBA of cluster 2 (first data cluster)

bpb_spc:        db      0               ; sectors per cluster (power of 2)
bpb_spc_shift:  db      0               ; log2(spc) -- use shifts instead of multiply
bpb_root_ents:  dw      0               ; root directory entry count (big-endian)

bpb_num_fats:   db      0               ; number of FAT copies (e.g. 2)
bpb_spf:        dw      0               ; sectors per FAT (big-endian) --
                                        ; needed to locate FAT copy 2, 3, ...
bpb_max_clust:  dw      0               ; highest valid cluster number
                                        ; (big-endian) -- bounds fat_alloc's
                                        ; scan; derived as spf*256-1 rather
                                        ; than from the BPB's total-sector
                                        ; field, so it's a slight
                                        ; over-estimate if the FAT was
                                        ; sized looser than the true data
                                        ; area (rare in practice, but a
                                        ; known simplification -- see
                                        ; bpb.asm)

                public  part1_lba
                public  bpb_fat_lba
                public  bpb_root_lba
                public  bpb_data_lba

                public  bpb_spc
                public  bpb_spc_shift
                public  bpb_root_ents
                public  bpb_num_fats
                public  bpb_spf
                public  bpb_max_clust

; ----------------------------------------------------------------
; FAT sector cache -- one 512-byte FAT sector held in RAM
;
; fat_csec: which sector within the FAT is cached ($FFFF = none)
; fat_dirty: non-zero means cache must be written back before eviction
; ----------------------------------------------------------------
fat_csec:       dw      $FFFF           ; initially invalid
fat_dirty:      db      0
fat_cache:      ds      SECTOR_SIZE     ; 512-byte FAT sector cache

                public  fat_csec
                public  fat_dirty
                public  fat_cache

; ----------------------------------------------------------------
; Directory sector buffer -- one directory sector at a time
; ----------------------------------------------------------------
dir_buf:        ds      SECTOR_SIZE

                public  dir_buf

; ----------------------------------------------------------------
; Shared file I/O sector buffer
;
; One 512-byte buffer shared across all FCBs.  This limits true
; simultaneous sector-level access to one file at a time, which
; is sufficient for a single-tasking shell.
; ----------------------------------------------------------------
io_buf:         ds      SECTOR_SIZE

                public  io_buf

; ----------------------------------------------------------------
; FCB table -- FCB_COUNT slots of FCB_LEN bytes each
; ----------------------------------------------------------------
fcb_table:      ds      FCB_COUNT * FCB_LEN

                public  fcb_table

; ----------------------------------------------------------------
; Memory map -- exported to user programs at load time
;
; mem_top: last usable RAM byte (set once at boot from f_freemem)
; mem_base: first byte after the loaded program (set by loader)
;
; A program wanting dynamic memory passes [mem_base..mem_top] to
; its heap library init function.  Programs not needing a heap
; ignore both values entirely.
; ----------------------------------------------------------------
mem_top:        dw      0
mem_base:       dw      0

                public  mem_top
                public  mem_base

; ----------------------------------------------------------------
; Shell state
; ----------------------------------------------------------------
cur_dir:        dw      0               ; current directory cluster (0 = root)
                                        ; (line_buf moved to the fixed
                                        ; address LINE_BUF in kernel.inc,
                                        ; reusing the dead ROM boot stack
                                        ; at $0080-$00FF instead of
                                        ; reserving space here)

                public  cur_dir

                endp

                end     kernel_main
