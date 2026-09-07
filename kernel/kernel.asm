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
; kernel.inc's RUN_PATH/RUN_ARGC/RUN_ARGV_TABLE comment for the full
; handoff protocol and why the shell can't do this itself.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   fat_init
            extrn   file_init
            extrn   mem_top
            extrn   mem_base
            extrn   drive_present
            extrn   drive_cur_dir
            extrn   cur_drive
            extrn   autoexec_path
            extrn   _switch_drive
            extrn   shell_drive
            extrn   shell_elba
            extrn   shell_eoff
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
            extrn   file_setattr
            extrn   file_touch
            extrn   kernel_himem_reserve
            extrn   kernel_himem_release
            extrn   batch_start
            extrn   batch_readline
            extrn   batch_goto
            extrn   kernel_batch_args_reserve
            extrn   kernel_batch_args_getarg
            extrn   dir_open
            extrn   dir_read
            extrn   dir_save_state
            extrn   dir_restore_state
            extrn   path_resolve
            extrn   prog_run
            extrn   prog_run_shell
            extrn   _find_dirent
            extrn   file_dirent
            extrn   dir_cur_lba
            extrn   dir_last_off
            extrn   _redir_setup
            extrn   _redir_teardown
            extrn   _redir_msg
            extrn   _redir_inmsg
            extrn   kernel_init
            extrn   kernel_getcurdir
            extrn   kernel_setcurdir
            extrn   kernel_setdrive
            extrn   kernel_getshelldrive
            extrn   kernel_get_errorlevel
            extrn   kernel_shell_init

; Kernel version -- single source of truth for the header bytes below,
; which programs read directly at the fixed KERNEL_HDR_VER address (see
; kernel_api.inc) rather than through a jump-table call, since $0100's
; layout is already a stable, never-shifting contract (same reasoning
; as PROG_BASE/LOADER_ARGS). Keep in sync with kernel_init's boot
; banner string below, which is a separate literal for simplicity (not
; worth generating dynamically at boot).
KERNEL_VER_MAJOR:   equ     1
KERNEL_VER_MINOR:   equ     0

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
;
; Pre-release exception (see kernel_api.inc's own header comment):
; 2026-07-13 renumbered this whole table from scratch (removed
; K_BPB_INIT/K_PROG_LOAD/K_PROG_EXEC, added K_SHELL_INIT/
; K_GETSHELLDRIVE) rather than only appending, since every program in
; this repo is rebuilt from source and nothing external depends on
; today's addresses yet. Don't repeat a full renumber after release.
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

; K_PROG_LOAD/K_PROG_EXEC REMOVED 2026-07-13 (see kernel_api.inc's own
; removal note) -- collapsed into the internal-only prog_run
; (kernel/loader.asm), called directly by run_loop below, never
; through this table.
;
; K_TYPE/K_READ (PHASE 2, self-modifying vectors): these two slots are
; no longer a fixed "lbr <dispatcher>" like every other entry in this
; table -- their own 2-byte operand is self-modified at RUNTIME.
; boot/krnboot.asm writes a bare "LBR <real console routine>" here once
; at boot (see kernel.inc's own IO_TYPE_TARGET/IO_READ_TARGET comment);
; kernel/redir.asm's _redir_setup/_redir_teardown repatch the SAME
; operand, per command, to point at a file-I/O routine while output/
; input is redirected, then restore it afterward. The source-level
; targets below ("lbr k_type"/"lbr k_read", i.e. each slot pointing at
; itself) are placeholders ONLY -- an infinite spin if somehow ever
; reached before krnboot's own patch step runs, matching this project's
; own preference for a visible hang over a silent wild jump. See
; kernel/redir.asm's own module header for the full design.
;
; K_MSG/K_INMSG are NOT self-modified -- they stay ordinary,
; permanent "lbr <dispatcher>" entries. K_MSG/K_INMSG's own dispatchers
; are now trivial byte-loops that simply "call K_TYPE" per character --
; since K_TYPE's own vector already does the right thing (console,
; file, or discard) depending on what's currently patched into it,
; K_MSG/K_INMSG need no redirect-awareness of their own at all anymore.
k_type:         lbr     k_type              ; $011E -- placeholder, see
                                            ; above; self-modified by
                                            ; boot/krnboot.asm
k_msg:          lbr     _redir_msg          ; $0121
k_inmsg:        lbr     _redir_inmsg        ; $0124
k_getdev:       lbr     f_getdev            ; $0127 (BIOS passthrough)
k_gettod:       lbr     f_gettod            ; $012A (BIOS passthrough)
k_settod:       lbr     f_settod            ; $012D (BIOS passthrough)

; K_INPUTL and K_SETBD REMOVED (this pass, dead-code cleanup after a
; full-repo audit -- see kernel_api.inc's own removal note for the
; full story on both): K_INPUTL's own _redir_inputl had zero real
; callers anywhere, fully superseded by lib/lineedit.asm's
; read_line_ex; K_SETBD (a bare "lbr f_setbd" passthrough) never had a
; real caller at all -- f_setbd is a bare-metal auto-baud-detection
; routine for pre-OS boot code, irrelevant once ELF-DOS is running.
k_boot:         lbr     f_boot              ; $0130 (BIOS passthrough)
k_tty:          lbr     f_tty               ; $0133 (BIOS passthrough)
k_getcurdir:    lbr     kernel_getcurdir    ; $0136
k_setcurdir:    lbr     kernel_setcurdir    ; $0139

; K_SETDRIVE: the only call that ever changes cur_drive -- see
; kernel_setdrive's own header comment and kernel_api.inc's note on
; the DOS-style CD/drive-switch decoupling.
k_setdrive:     lbr     kernel_setdrive     ; $013C

; K_GETSHELLDRIVE: see kernel_getshelldrive's own header comment below.
k_getshelldrive: lbr    kernel_getshelldrive ; $013F

k_path_resolve: lbr     path_resolve        ; $0142
k_file_delete:  lbr     file_delete         ; $0145
k_dir_create:   lbr     dir_create          ; $0148
k_dir_remove:   lbr     dir_remove          ; $014B
k_file_rename:  lbr     file_rename         ; $014E
k_read:         lbr     k_read              ; $0151 -- placeholder, see
                                            ; k_type's own comment above;
                                            ; self-modified by
                                            ; boot/krnboot.asm

; K_FAT_INIT/K_FILE_INIT/K_SHELL_INIT: boot-only, called exactly once
; each by boot/krnboot.asm's relocated init code (see kernel_init's
; own header comment below, and krnboot.asm's, for the full story) --
; exist as jump-table slots only because krnboot.asm is linked
; completely separately from kernel.bin and has no other way to reach
; these kernel-resident routines. Not meant to be called by ordinary
; programs. K_BPB_INIT REMOVED 2026-07-13 (see kernel_api.inc's own
; removal note) -- its slot's k_bpb_init_stub had already been a
; no-op for a while; grep confirmed zero remaining callers, so it's
; now gone outright rather than kept as a stub forever.
k_fat_init:     lbr     fat_init            ; $0154
k_file_init:    lbr     file_init           ; $0157
k_shell_init:   lbr     kernel_shell_init   ; $015A

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
k_secwrite:     lbr     f_idewrite          ; $015D (BIOS passthrough)
k_secread:      lbr     f_ideread           ; $0160 (BIOS passthrough)

; K_STAT: resolve a path to its own directory entry without opening it
; as a file -- works on either a file or a directory. See
; kernel/file.asm's file_stat for the full contract (args/returns) and
; the motivation (a third caller, progs/stat.asm, was about to
; hand-roll the same path_resolve+dir_open/dir_read+f_strcmp scan
; progs/copy.asm and progs/sys.asm already each do inline).
k_stat:         lbr     file_stat           ; $0163

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
                dw      part1_lba           ; $0166: BPB_DATA_PTR

; DRIVE_DATA_PTR: same DATA-slot mechanism as BPB_DATA_PTR above, for
; the multi-partition boot-time scan (2026-07-13). Points at
; drive_present[0..DRIVE_COUNT-1], drive_bpb_table[0..DRIVE_COUNT-1],
; and shell_drive/shell_elba/shell_eoff, all contiguous -- see
; kernel_api.inc's own DRIVE_DATA_PTR comment. boot/krnboot.asm's
; relocated partition-scan loop and K_SHELL_INIT both reach their own
; piece of this through the one pointer.
                dw      drive_present       ; $0168: DRIVE_DATA_PTR

; K_BATCH_START/K_BATCH_READLINE: minimal flat batch-script execution
; (2026-07-14) -- see kernel_api.inc's own comment and kernel/batch.asm
; for the full design (state has to live here, not in the shell, since
; the shell is reloaded fresh from disk every command cycle).
k_batch_start:  lbr     batch_start         ; $016A
k_batch_readline: lbr   batch_readline      ; $016D

; K_GLOB_RESERVE REMOVED (this pass, dead-code cleanup -- see
; kernel_api.inc's own removal note for the full story): the shell's
; own tokenizer-level glob expansion that used to call
; kernel_glob_reserve (kernel/glob.asm, deleted along with this slot)
; was completely removed 2026-07-27 in favor of lib/file_glob.asm's
; per-program glob approach. Nothing called this slot anymore.

; K_FILE_SETATTR: change an existing directory entry's attribute byte
; (2026-07-22) -- see kernel/file.asm's file_setattr for the full
; design. General set/clear-mask primitive; ATTRIB currently only
; exposes +H/-H, but this needs no kernel change to grow further.
k_file_setattr: lbr     file_setattr        ; $0170

; K_GET_ERRORLEVEL: read the last command's exit code (2026-07-25) --
; ERRORLEVEL prelude to batch IF/GOTO. RUN_ERRORLEVEL (kernel.inc) is
; kernel/shell-internal plumbing, same category as RUN_PATH -- this is
; the real jump-table entry point for an ORDINARY program to read it
; (progs/errorlevel.asm), rather than baking the fixed relay address
; directly into its own compiled binary.
k_get_errorlevel: lbr   kernel_get_errorlevel ; $0173

; K_BATCH_GOTO: reposition the active batch script to just after a
; labeled line (2026-07-25, IF/GOTO batch scripting) -- see
; kernel_api.inc's own doc comment and kernel/batch.asm's batch_goto
; for the full design.
k_batch_goto:   lbr     batch_goto          ; $0176

; K_BATCH_ARGS_RESERVE/K_BATCH_ARGS_GETARG: %0-%9 batch-argument
; substitution (2026-07-25) -- see kernel_api.inc's own doc comments
; and kernel/batch.asm's own module header for the full design.
k_batch_args_reserve: lbr kernel_batch_args_reserve  ; $0179
k_batch_args_getarg:  lbr kernel_batch_args_getarg   ; $017C

; K_DIR_SAVE_STATE/K_DIR_RESTORE_STATE: snapshot/restore the
; directory iterator's own scan position (2026-07-27), added so
; lib/file_glob.asm's glob_next can resume a directory scan exactly
; where it left off instead of re-scanning from the start on every
; call -- see kernel/dir.asm's own dir_save_state/dir_restore_state
; headers for the full design and kernel_api.inc's own doc comments.
k_dir_save_state:    lbr     dir_save_state      ; $017F
k_dir_restore_state: lbr     dir_restore_state   ; $0182

; K_FILE_TOUCH: update an existing directory entry's last-write date/
; time to the current time, touching nothing else (2026-07-30) -- see
; kernel/file.asm's file_touch for the full design.
k_file_touch:   lbr     file_touch          ; $0185

; K_HIMEM_RESERVE/K_HIMEM_RELEASE: general-purpose himem reservation,
; exposed to ordinary programs for the first time (2026-07-31) -- see
; kernel/redir.asm's own kernel_himem_reserve/kernel_himem_release for
; the full design. First real consumer: lib/modload.asm.
k_himem_reserve: lbr    kernel_himem_reserve ; $0188
k_himem_release: lbr    kernel_himem_release ; $018B
                ; next free jump-table address: $018E

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
; fixed-address way to reach (unlike the K_FAT_INIT/K_FILE_INIT/
; K_SHELL_INIT calls above, which only needed a stable jump-table
; address, not a data address).
;
; On entry:
;   SCRT initialized (R3=PC, R4=call, R5=ret)
;   R2 = stack at top of RAM (set by bootstrap)
;   All other registers: undefined (the multi-partition scan, fat_init,
;   file_init, and kernel_shell_init have already run, via krnboot.asm's
;   own K_FAT_INIT/K_FILE_INIT/K_SHELL_INIT calls, by the time this
;   point is reached)
;------------------------------------------------------------------

                end     kernel_main
