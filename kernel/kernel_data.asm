;
; kernel_data.asm - volatile (RAM-resident) data for kernel.asm
;
; Split out of kernel.asm for the split memory model (volatile RAM data at
; $0100, non-volatile ROM-able code at NVK_BASE). Every symbol here is
; already reached through extrn/public by its owning module, so moving
; the proc between files changes nothing about how it is referenced --
; only where the linker places it.
;
; Do NOT move these back inline: the linker lays procs out sequentially
; in command-line/source order, so a data proc sharing a .prg with code
; would land in the ROM region with that code.
;

#include    include/opcodes.def
#include    include/kernel.inc


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
; Multi-drive state (C:/D:/E:/F: = drive index 0-3, 2026-07-13)
;
; drive_present/drive_bpb_table: populated once at boot by
; boot/krnboot.asm's partition-scan loop via DRIVE_DATA_PTR (see
; kernel_api.inc) -- MUST stay contiguous in exactly this order
; (nothing interleaved), since DRIVE_DATA_PTR is one pointer to
; drive_present's start and krnboot reaches drive_bpb_table through
; it by a fixed offset (DRIVE_COUNT bytes past DRIVE_DATA_PTR), the
; same convention BPB_DATA_PTR already uses for the single active BPB
; block above. _switch_drive (fat.asm) copies one drive's
; drive_bpb_table entry at a time into that active block on demand --
; see kernel_api.inc's own note on why a copy, not direct indexing,
; was chosen.
;
; drive_cur_dir: each drive's own remembered current-directory
; cluster, independent of which drive is active -- classic DOS
; semantics (kernel_setcurdir above never touches cur_drive). Zeroed
; (root) at boot by kernel_init, not by krnboot -- this is session
; state, not disk geometry. Also written from userland by
; progs/mount.asm (a freshly mounted drive starts at its own root) via
; DRIVE_CUR_DIR_OFF -- see kernel_api.inc.
;
; cur_drive: which drive a path with no "X:" prefix resolves against,
; and what the shell prompt/PWD show. Only ever changed by
; kernel_setdrive above.
;
; active_bpb_drive: _switch_drive's own bookkeeping (which drive's
; block is currently copied into the active BPB fields) -- not meant
; to be read by anything else, and deliberately NOT reachable from
; userland: progs/mount.asm and progs/umount.asm go through
; K_DRIVE_INVALIDATE instead, which resets this AND performs the FAT
; flush that resetting it alone would skip. $FF = none yet, forcing a real switch
; on the first path_resolve call of the session; relies on the static
; kernel image itself encoding $FF here (same convention fat_csec's
; own "dw $FFFF" already uses), not on kernel_init.
;
; shell_drive/shell_elba/shell_eoff (2026-07-13): where the shell
; binary's own directory entry lives -- a fixed-size (drive, sector
; LBA, byte offset) reference, the same shape FCB_ELBA/FCB_EOFF
; already use, NOT a path string. Populated once at boot by
; K_SHELL_INIT (kernel_shell_init above) via DRIVE_DATA_PTR's extended
; reach (contiguous right after drive_bpb_table -- see
; kernel_api.inc's own comment). kernel/loader.asm's prog_run_shell
; reads shell_elba's own sector directly on every shell reload instead
; of re-walking a directory scan every command cycle, falling back to
; an ordinary path-based load if that cached location no longer
; describes a live file (see prog_run_shell's own header comment).
; ----------------------------------------------------------------
drive_present:      ds      DRIVE_COUNT             ; 4 bytes
drive_bpb_table:    ds      DRIVE_COUNT*BPBBLK_LEN  ; 92 bytes
shell_drive:        db      0                       ; 1 byte
shell_elba:         ds      LBA_SIZE                ; 3 bytes
shell_eoff:         dw      0                       ; 2 bytes
drive_cur_dir:      ds      DRIVE_COUNT*2           ; 8 bytes
cur_drive:          db      0
active_bpb_drive:   db      $FF
                                        ; (line_buf moved to the fixed
                                        ; address LINE_BUF in kernel.inc,
                                        ; reusing the dead ROM boot stack
                                        ; at $0080-$00FF instead of
                                        ; reserving space here)

; autoexec_path: literal path kernel_init hands to batch_start as its
; own last boot-time act (2026-07-23) -- see kernel_init's own call
; site for the full design. Cross-proc same-file reference (gotcha #6),
; hence the extrn near the top of this file plus the public below.
autoexec_path:      db      "/autoexec.bat",0

                public  drive_present
                public  drive_bpb_table
                public  shell_drive
                public  shell_elba
                public  shell_eoff
                public  drive_cur_dir
                public  cur_drive
                public  active_bpb_drive
                public  autoexec_path

                endp
