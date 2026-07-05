;
; kernel.asm - ELF-DOS kernel entry point and global data
;
; Assembled at org $0100.  The 6-byte header at $0100-$0105 is
; skipped by the bootstrap; kernel_main at $0106 is the true entry.
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

            org     $0100

;------------------------------------------------------------------
; 6-byte header ($0100-$0105)
; Never executed -- bootstrap enters at $0106.
;------------------------------------------------------------------
            db      'E','D','F'         ; ELF-DOS kernel magic
            db      1                   ; kernel major version
            dw      0                   ; kernel minor version / reserved

;------------------------------------------------------------------
; Kernel entry point - $0106
;
; On entry:
;   SCRT initialized (R3=PC, R4=call, R5=ret)
;   R2 = stack at top of RAM (set by bootstrap)
;   All other registers: undefined
;------------------------------------------------------------------
kernel_main:
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

                public  part1_lba
                public  bpb_fat_lba
                public  bpb_root_lba
                public  bpb_data_lba

                public  bpb_spc
                public  bpb_spc_shift
                public  bpb_root_ents
                
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
