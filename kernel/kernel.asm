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
            extrn   batch_start
            extrn   batch_readline
            extrn   dir_open
            extrn   dir_read
            extrn   path_resolve
            extrn   prog_run
            extrn   prog_run_shell
            extrn   _find_dirent
            extrn   file_dirent
            extrn   dir_cur_lba
            extrn   dir_last_off
            extrn   _redir_setup
            extrn   _redir_teardown
            extrn   _redir_type
            extrn   _redir_msg
            extrn   _redir_inmsg
            extrn   _redir_read
            extrn   _redir_inputl

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
; K_TYPE/K_MSG/K_INMSG/K_INPUTL (below) and K_READ (further down) are no
; longer bare BIOS passthroughs -- each now targets a small redirect-
; aware dispatcher in kernel/redir.asm that falls straight through to
; the original BIOS call when I/O redirection isn't active (see
; redir.asm's own module header for the full design). Still a plain
; lbr each -- not a nested call -- so the target address is the only
; thing that changed; every existing caller's own calling convention
; is untouched.
k_type:         lbr     _redir_type         ; $011E
k_msg:          lbr     _redir_msg          ; $0121
k_inmsg:        lbr     _redir_inmsg        ; $0124
k_getdev:       lbr     f_getdev            ; $0127 (BIOS passthrough)
k_gettod:       lbr     f_gettod            ; $012A (BIOS passthrough)
k_settod:       lbr     f_settod            ; $012D (BIOS passthrough)
k_inputl:       lbr     _redir_inputl       ; $0130
k_boot:         lbr     f_boot              ; $0133 (BIOS passthrough)
k_tty:          lbr     f_tty               ; $0136 (BIOS passthrough)
k_setbd:        lbr     f_setbd             ; $0139 (BIOS passthrough)
k_getcurdir:    lbr     kernel_getcurdir    ; $013C
k_setcurdir:    lbr     kernel_setcurdir    ; $013F

; K_SETDRIVE: the only call that ever changes cur_drive -- see
; kernel_setdrive's own header comment and kernel_api.inc's note on
; the DOS-style CD/drive-switch decoupling.
k_setdrive:     lbr     kernel_setdrive     ; $0142

; K_GETSHELLDRIVE: see kernel_getshelldrive's own header comment below.
k_getshelldrive: lbr    kernel_getshelldrive ; $0145

k_path_resolve: lbr     path_resolve        ; $0148
k_file_delete:  lbr     file_delete         ; $014B
k_dir_create:   lbr     dir_create          ; $014E
k_dir_remove:   lbr     dir_remove          ; $0151
k_file_rename:  lbr     file_rename         ; $0154
k_read:         lbr     _redir_read         ; $0157

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
k_fat_init:     lbr     fat_init            ; $015A
k_file_init:    lbr     file_init           ; $015D
k_shell_init:   lbr     kernel_shell_init   ; $0160

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

; DRIVE_DATA_PTR: same DATA-slot mechanism as BPB_DATA_PTR above, for
; the multi-partition boot-time scan (2026-07-13). Points at
; drive_present[0..DRIVE_COUNT-1], drive_bpb_table[0..DRIVE_COUNT-1],
; and shell_drive/shell_elba/shell_eoff, all contiguous -- see
; kernel_api.inc's own DRIVE_DATA_PTR comment. boot/krnboot.asm's
; relocated partition-scan loop and K_SHELL_INIT both reach their own
; piece of this through the one pointer.
                dw      drive_present       ; $016E: DRIVE_DATA_PTR

; K_BATCH_START/K_BATCH_READLINE: minimal flat batch-script execution
; (2026-07-14) -- see kernel_api.inc's own comment and kernel/batch.asm
; for the full design (state has to live here, not in the shell, since
; the shell is reloaded fresh from disk every command cycle).
k_batch_start:  lbr     batch_start         ; $0170
k_batch_readline: lbr   batch_readline      ; $0173
                ; next free jump-table address: $0176

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

            ; current directory (every drive) = root; active drive = C:
            ; (cluster 0 is the FAT16 root sentinel, drive index 0 is
            ; C: -- see kernel.inc's DRIVE_COUNT and the "Multi-drive
            ; state" data section below). Explicitly zeroed here even
            ; though the static image already encodes 0, matching this
            ; routine's existing practice for mem_base above.
            mov     rf, drive_cur_dir
            ldi     DRIVE_COUNT*2
            plo     rc                  ; RC.0 = bytes to zero
kinit_dcd_zero:
            ldi     0
            str     rf
            inc     rf
            dec     rc
            glo     rc
            lbnz    kinit_dcd_zero

            mov     rf, cur_drive
            ldi     0
            str     rf                  ; cur_drive = C: (0)

;------------------------------------------------------------------
; run_loop: alternately load+run the shell (which resolves one
; command line and returns) and whatever it resolved. Lives entirely
; here, in kernel memory, so it's safe regardless of what's currently
; sitting at PROG_BASE -- see kernel.inc's RUN_PATH/RUN_ARGC/
; RUN_ARGV_TABLE comment for why the shell can't do this hand-off
; itself. Never returns.
;
; As of 2026-07-13, the shell no longer hands back a bare, possibly-
; not-found path: progs/shell.asm now confirms a command exists
; (trying the active drive, then shell_drive as a fallback for a bare
; name) via K_STAT before ever writing RUN_PATH, printing its own
; "File not found." and re-prompting itself if nothing matched. So
; the only way prog_run below can still fail is "exists but isn't a
; valid program" -- a genuinely different, rarer case than before.
;------------------------------------------------------------------
run_loop:
            ; clear the redirect relay slots BEFORE reloading the
            ; shell -- prog_run_shell's own rare fallback path (used
            ; when its cached shell_elba/eoff sector read fails
            ; validation) calls prog_run directly to reload "C:/bin/
            ; shell" by path, and prog_run now always calls
            ; _redir_setup internally (see kernel/loader.asm). Without
            ; this, that reload would run BEFORE the shell has had any
            ; chance to tokenize the new line and (re)write these
            ; slots itself, so they'd still hold whatever the
            ; PREVIOUS command's redirect left behind, and the
            ; shell's own reload could spuriously "redirect" itself.
            ; progs/shell.asm's own tokenizer also clears these at the
            ; top of every pass (fixing the separate uninitialized-RAM
            ; bug found 2026-07-16), but that happens only after the
            ; shell is already loaded and running -- this covers the
            ; earlier window the tokenizer's own fix can't reach.
            mov     rf, RUN_REDIR_OUT
            ldi     0
            str     rf
            inc     rf
            str     rf
            mov     rf, RUN_REDIR_IN
            ldi     0
            str     rf
            inc     rf
            str     rf

            call    prog_run_shell      ; loads+runs "C:/bin/shell" --
                                        ; see kernel/loader.asm: reads
                                        ; the cached shell_elba/eoff
                                        ; sector directly instead of a
                                        ; full directory scan, falling
                                        ; back to a real path-based
                                        ; load if that cached location
                                        ; is no longer valid. Always
                                        ; returns with RUN_PATH/
                                        ; RUN_ARGC/RUN_ARGV_TABLE/
                                        ; RUN_REDIR_OUT/RUN_REDIR_IN
                                        ; filled in on success.
            lbdf    kern_shell_err      ; shell itself missing/corrupt/
                                        ; unloadable: fatal

            ; NOTE: redirect target(s) are opened INSIDE prog_run
            ; (kernel/loader.asm's own call to _redir_setup), not here.
            ; prog_run's own internal load of the child's binary uses
            ; prog_fcb/prog_iobuf too -- opening a redirect target
            ; against those same addresses here, before prog_run runs,
            ; would get silently overwritten the moment prog_run loads
            ; the child (hardware-found bug, 2026-07-16: "dir
            ; >dir1.txt" created a 0-byte file -- prog_fcb/prog_iobuf
            ; are only genuinely idle again AFTER the child's binary
            ; has finished loading, not from the moment _redir_setup
            ; runs). See kernel/redir.asm's own module header.

            mov     ra, RUN_ARGV_TABLE  ; RA = argv table's address --
                                        ; a fixed constant (the shell
                                        ; always builds the table here),
                                        ; so unlike argc below there's
                                        ; no dynamic relay slot to read,
                                        ; just the address itself

            mov     rf, RUN_ARGC
            lda     rf                  ; D = argc high byte
            phi     rc
            ldn     rf                  ; D = argc low byte
            plo     rc                  ; RC = argc

            mov     rf, RUN_PATH        ; RF = resolved path (RA/RC
                                        ; already set above -- mov
                                        ; only touches RF/D)
            call    prog_run            ; D = exit code (unused), DF=0/1
            lbdf    run_bad_program     ; exists (the shell already
                                        ; confirmed that) but isn't a
                                        ; valid EDF program, OR its own
                                        ; internal _redir_setup call
                                        ; failed (bad output/input
                                        ; path, disk full, or -- rare
                                        ; -- not enough RAM headroom
                                        ; for a dual redirect) -- both
                                        ; share this one exit and
                                        ; message for now, a minor
                                        ; imprecision accepted in favor
                                        ; of not needing a second
                                        ; memory flag just to tell them
                                        ; apart

            call    _redir_teardown     ; close whatever prog_run's own
                                        ; _redir_setup call opened/
                                        ; reserved, always -- checked
                                        ; AFTER prog_run's own DF, since
                                        ; this call would otherwise
                                        ; clobber it before the check
                                        ; above ever ran
            lbr     run_loop

run_bad_program:
            ; safe to call unconditionally even when _redir_setup was
            ; never reached (_prog_finish_load failed first) or already
            ; cleaned up after its own failure -- redir_*_active/
            ; redir_stack_reserved are already clear in both cases, so
            ; this is a no-op then, not a double-release
            call    _redir_teardown
            call    f_inmsg
            db      "Invalid program file.",13,10,0
            lbr     run_loop

kern_shell_err:
            call    f_inmsg
            db      "Shell not found or invalid.",13,10,0
kern_halt:  lbr     kern_halt

;------------------------------------------------------------------
; kernel_getcurdir: return the ACTIVE drive's current directory
;
; BUG FIX (2026-07-15): must activate cur_drive's own BPB/FAT cache
; via _switch_drive BEFORE returning -- the cluster this hands back is
; only meaningful relative to whichever drive's BPB is currently
; active, and nothing guaranteed that matched cur_drive by the time a
; caller got here. In particular, prog_run_shell's own fast-path
; reload (kernel/loader.asm) ALWAYS reactivates shell_drive
; (hardcoded C) on every single shell reload regardless of cur_drive,
; and a program can itself be loaded from a drive other than
; cur_drive via the shell's own shell_drive fallback search
; (progs/shell.asm) -- so by the time execution reaches, say,
; print_prompt's or PWD's own K_GETCURDIR call, the active drive could
; easily be C even though cur_drive is D. Every known caller
; (print_prompt in progs/shell.asm, progs/pwd.asm, progs/dir.asm's own
; bare-listing path) calls K_GETCURDIR first and then K_DIR_OPEN/
; K_DIR_READ directly -- neither of which switches drives itself
; (only path_resolve does) -- so a stale active drive here silently
; corrupts every one of them, surfacing as "Error reading directory
; structure" (PWD) or the prompt's own pp_ioerr fallback. Fixing it
; once, here, transparently fixes all three (and any future caller)
; with no changes needed on their end.
;
; REGRESSION FIX (2026-07-15, same day): the fix above initially called
; _switch_drive directly, with no register protection -- but
; _switch_drive's own documented clobber list (R7, R8, R9, RA, RB, RC,
; RD, RF) is far broader than this routine's own historical, never-
; formally-documented-but-real footprint (only R8/R9/RD/RF). Two real
; callers depend on the old narrow footprint: progs/dir.asm calls
; K_GETCURDIR as its very first instruction, BEFORE reading its own
; command tail out of RA -- with RA now clobbered by _switch_drive,
; dir.asm treated garbage as a path argument and printed its own
; "Directory not found." for a bare "DIR" with no argument at all
; (confirmed on hardware, 2026-07-14). progs/shell.asm's own
; shell_drive-fallback comparison (resolving a bare command name) also
; keeps a value alive in RB across this exact call, corrupting the
; fallback candidate path. Fixed by saving/restoring every register
; _switch_drive might touch that this routine doesn't already need as
; scratch (R8/R9/RD/RF are already fully overwritten by this routine's
; own logic either way, so only RA/RB/RC/R7 need protecting) --
; restores this routine's external behavior to exactly what callers
; were already (silently) relying on, while still getting the new
; BPB-activation side effect.
;
; Args:    none
; Returns: RD = drive_cur_dir[cur_drive] (0 = that drive's root)
;          D  = cur_drive (0-3, 0=C..3=F)
; Modifies: R8, R9, RD, RF only (RA/RB/RC/R7 explicitly protected, same
;          footprint as before this whole fix)
;------------------------------------------------------------------
kernel_getcurdir:
            push    ra
            push    rb
            push    rc
            push    r7

            mov     rf, cur_drive
            ldn     rf                  ; D = cur_drive
            call    _switch_drive       ; make the active BPB/FAT cache
                                        ; actually match cur_drive
                                        ; before handing back a cluster
                                        ; number that's only meaningful
                                        ; relative to it. DF ignored --
                                        ; cur_drive is only ever set to
                                        ; an already-present drive (see
                                        ; kernel_setdrive's own
                                        ; drive_present check), so this
                                        ; should never fail in practice.
                                        ; Cheap when already active (a
                                        ; documented no-op check in
                                        ; _switch_drive itself), so this
                                        ; costs nothing in the common
                                        ; case.

            pop     r7
            pop     rc
            pop     rb
            pop     ra

            mov     rf, cur_drive
            ldn     rf
            plo     r9                  ; R9.0 = cur_drive (reloaded
                                        ; fresh -- _switch_drive above
                                        ; documents R9 among its
                                        ; clobbers, and the mov here
                                        ; would clobber D regardless,
                                        ; gotcha #4)
            ldi     0
            phi     r9                  ; R9 = cur_drive, zero-extended
                                        ; (needed as a clean 16-bit
                                        ; add16 operand below)

            glo     r9
            shl                         ; D = cur_drive * 2 (entry size)
            plo     r8
            ldi     0
            phi     r8                  ; R8 = cur_drive * 2

            mov     rf, drive_cur_dir
            add16   rf, r8              ; RF = &drive_cur_dir[cur_drive]
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = drive_cur_dir[cur_drive]

            glo     r9                  ; D = cur_drive (return value)
            rtn

;------------------------------------------------------------------
; kernel_setcurdir: set a drive's OWN remembered current directory.
; Deliberately does NOT change which drive is active, even if D names
; a drive other than cur_drive -- classic DOS semantics: "CD D:\foo"
; while C: is active updates D:'s own directory without switching to
; it. The only way the active drive changes is kernel_setdrive, below.
; Args:    D = drive index (0-3), RD = new directory cluster for
;          that drive
; Returns: nothing
;------------------------------------------------------------------
kernel_setcurdir:
            plo     r9                  ; R9.0 = drive index (mov
                                        ; below clobbers D, gotcha #4)
            ldi     0
            phi     r9

            glo     r9
            shl                         ; D = drive * 2 (entry size)
            plo     r8
            ldi     0
            phi     r8

            mov     rf, drive_cur_dir
            add16   rf, r8              ; RF = &drive_cur_dir[drive]
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf
            rtn

;------------------------------------------------------------------
; kernel_setdrive: change the active drive. The ONLY place cur_drive
; is ever written -- kernel_setcurdir/CD never touch it (see above).
; Rejects a drive with no mounted partition rather than silently
; activating an empty/garbage BPB block; the caller (the shell's own
; bare "C:"/"D:"/"E:"/"F:" dispatch, see progs/shell.asm) is expected
; to report that as an error.
; Args:    D = drive index (0-3) to make active
; Returns: DF = 0 on success, DF = 1 if that drive is not present
;          (drive_present[D] = 0) -- cur_drive is left unchanged
;------------------------------------------------------------------
kernel_setdrive:
            plo     r9                  ; R9.0 = drive index
            ldi     0
            phi     r9

            mov     rf, drive_present
            add16   rf, r9              ; RF = &drive_present[drive]
            ldn     rf
            lbz     ksd_absent          ; 0 = not present: error

            mov     rf, cur_drive
            glo     r9
            str     rf                  ; cur_drive = drive
            clc
            rtn

ksd_absent:
            stc
            rtn

;------------------------------------------------------------------
; kernel_getshelldrive: return which drive the shell binary was found
; on at boot (see kernel_shell_init below) -- almost always 0 (C:) in
; practice. Used by progs/shell.asm to build a fallback
; "<shell_drive>:/bin/<name>" search candidate for a bare command name
; not found on the active drive.
; Args:    none
; Returns: D = shell_drive (0-3)
;------------------------------------------------------------------
kernel_getshelldrive:
            mov     rf, shell_drive
            ldn     rf
            rtn

;------------------------------------------------------------------
; kernel_shell_init: locate "C:/bin/shell"'s own directory entry and
; cache its (drive, sector LBA, byte offset within that sector) for
; run_loop's fast reload path (see kernel/loader.asm's
; prog_run_shell) -- boot-only, called once by boot/krnboot.asm via
; K_SHELL_INIT, before kernel_init's own zero-init has run (safe: the
; literal path below has an explicit "C:" prefix, so path_resolve
; never needs cur_drive/drive_cur_dir to resolve it -- the same
; reasoning boot_init2's other init calls already rely on).
; Args:    none
; Returns: DF = 0 on success (shell_drive/shell_elba/shell_eoff
;          populated), DF = 1 if "C:/bin/shell" doesn't exist or
;          isn't a file
;------------------------------------------------------------------
kernel_shell_init:
            mov     rf, kshell_path
            call    _find_dirent        ; RD = parent cluster (unused
                                        ; here), file_dirent = matched
                                        ; entry, dir_cur_lba/
                                        ; dir_last_off = its own
                                        ; on-disk location
            lbdf    kshell_init_err

            ; reject a directory (shouldn't happen for a real file
            ; named "shell", but stay consistent with every other
            ; "must be a file" check in this project)
            mov     rf, file_dirent+DIRENT_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    kshell_init_err

            mov     rf, shell_drive
            ldi     0                   ; always C: -- the only drive
                                        ; kshell_path ever names
            str     rf

            mov     rf, shell_elba
            mov     rd, dir_cur_lba
            lda     rd
            str     rf
            inc     rf
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; shell_elba = dir_cur_lba
                                        ; (3 bytes)

            mov     rf, shell_eoff
            mov     rd, dir_last_off
            lda     rd
            str     rf
            inc     rf
            ldn     rd
            str     rf                  ; shell_eoff = dir_last_off
                                        ; (2 bytes)

            clc
            rtn

kshell_init_err:
            stc
            rtn

kshell_path:    db      "C:/bin/shell",0

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
; fd_table -- FD_COUNT pointers into caller-allocated FCB memory
; (2026-07-15). Replaces the old fixed-size fcb_table (FCB_COUNT=3
; full 32-byte FCBs) and the single shared io_buf (arbitrated by a
; global io_owner byte) -- FCB storage AND each FCB's own 512-byte
; I/O buffer now live in the caller's own memory (a program, or this
; kernel's own prog_run for its one internal need, see loader.asm).
; file_open registers a caller's FCB pointer into a free (zero) slot
; here and returns the slot index as the handle, exactly as before;
; file_close/file_read/file_write/file_seek resolve that same index
; back through this table to the real FCB pointer. A free slot holds
; 0, which a real FCB address never is.
; ----------------------------------------------------------------
fd_table:       ds      FD_COUNT * 2

                public  fd_table

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
; state, not disk geometry.
;
; cur_drive: which drive a path with no "X:" prefix resolves against,
; and what the shell prompt/PWD show. Only ever changed by
; kernel_setdrive above.
;
; active_bpb_drive: _switch_drive's own bookkeeping (which drive's
; block is currently copied into the active BPB fields) -- not meant
; to be read by anything else. $FF = none yet, forcing a real switch
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

                public  drive_present
                public  drive_bpb_table
                public  shell_drive
                public  shell_elba
                public  shell_eoff
                public  drive_cur_dir
                public  cur_drive
                public  active_bpb_drive

                endp

                end     kernel_main
