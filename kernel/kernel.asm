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
;   kernel.asm  bpb.asm  fat.asm  file.asm  loader.asm  shell.asm
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   bpb_init
            extrn   fat_init
            extrn   file_init
            extrn   shell_main
            extrn   mem_top
            extrn   mem_base
            extrn   cur_dir

            extrn   file_open
            extrn   file_close
            extrn   file_read
            extrn   file_write
            extrn   file_seek
            extrn   dir_open
            extrn   dir_read
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
                ; next free address: $0148

;------------------------------------------------------------------
; kernel_init: the original boot sequence (formerly "kernel_main"
; itself, before the jump table above took over that address).
;
; On entry:
;   SCRT initialized (R3=PC, R4=call, R5=ret)
;   R2 = stack at top of RAM (set by bootstrap)
;   All other registers: undefined
;------------------------------------------------------------------
kernel_init:
            call    f_setbd             ; configure serial baud rate

            call    f_inmsg
            db      "ELF-DOS v0.1",13,10,0

            call    bpb_init            ; read MBR + VBR, populate BPB cache
            lbdf    kern_err            ; DF=1 on disk or format error

            call    fat_init            ; invalidate FAT cache, clear dirty flag
            call    file_init           ; mark all FCB slots as free

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

            call    shell_main          ; start the command shell (never returns)

kern_err:   call    f_inmsg
            db      "Kernel init failed",13,10,0
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
line_buf:       ds      128             ; shell command input buffer

                public  cur_dir
                public  line_buf

                endp

                end     kernel_main
