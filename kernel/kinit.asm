;
; kinit.asm - ELF-DOS non-volatile (ROM-able) kernel code from kernel.asm
;
; Split out of kernel/kernel.asm for the split memory model. kernel.asm
; now holds ONLY the volatile, RAM-resident pieces that must live at
; fixed low addresses: the EDF header and the K_* jump table at $0100
; (the table is self-modified at boot -- _patch_io_vector rewrites
; K_TYPE/K_READ -- so it can never be in ROM).
;
; Everything here is ordinary relocatable proc code, placed by the
; linker in the non-volatile region at NVK_BASE. It used to be plain
; top-level (absolute) code following the jump table, which is exactly
; why it had to be wrapped in procs to move: only proc-wrapped code is
; relocatable.
;
; The seven routines below are independent -- none calls another (they
; are reached only through the jump table), so each is its own proc.
; The one exception is kernel_init, which deliberately FALLS THROUGH
; into run_loop; those two plus run_bad_program/kern_shell_err/
; kern_halt are one control-flow unit and share a single proc.
;

#include    include/bios.inc
#include    include/opcodes.def
#include    include/kernel.inc
#include    include/memmap.inc

            extrn   fat_init
            extrn   file_init
            extrn   mem_top
            extrn   mem_base
            extrn   drive_present
            extrn   drive_cur_dir
            extrn   cur_drive
            extrn   autoexec_path
            extrn   _switch_drive
            extrn   fat_flush
            extrn   active_bpb_drive
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

            proc    kernel_init
            ; record top of RAM in mem_top
            ; f_freemem returns in RF; save it before RF is reused
            ; RAM top comes from the stack pointer, not f_freemem.
            ; krnboot probed for the highest RAM byte BELOW NVK_BASE and
            ; set R2 to it (see boot/krnboot.asm's boot_ram_found), so
            ; R2 already carries exactly the value we need -- and using
            ; it means there is no fixed handoff address to keep in sync.
            ;
            ; f_freemem would be WRONG here: on a RAM-only machine it
            ; reports the true top of RAM, which is ABOVE the loaded
            ; non-volatile kernel, so mem_top would let programs grow
            ; straight through it.
            ;
            ; Safe to read R2 this late: SCRT balances every call made
            ; between krnboot setting it and this instruction, so its
            ; value is unchanged.
            ghi     r2
            phi     r9
            glo     r2
            plo     r9                  ; R9 = highest usable RAM byte

            ; permanently reserve STACK_RESERVE_LEN bytes at the very
            ; top of RAM for the hardware stack (R2), which lives
            ; there for the whole session and is NEVER relocated --
            ; see kernel.inc's own STACK_RESERVE_LEN comment for the
            ; full 2026-07-22 redesign history. Immediate-form sub16
            ; (compile-time constant) -- no register-register risk.
            sub16   r9, STACK_RESERVE_LEN

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

            ; Run /autoexec.bat automatically at boot, if it exists --
            ; reuses the existing batch machinery wholesale rather than
            ; inventing a parallel mechanism (2026-07-23, the user's own
            ; realization mid-design-discussion, after an earlier
            ; "prime LINE_BUF and have the shell detect it" proposal
            ; turned out to have real one-shot-correctness edge cases).
            ; batch_start just opens the file and marks the kernel-
            ; resident batch state active; if the file doesn't exist it
            ; fails silently (DF=1, "couldn't be opened" -- the exact
            ; same outcome an ordinary missing .bat already produces),
            ; and DF is deliberately not checked here since either way
            ; execution falls straight into run_loop below with no
            ; special-casing needed: progs/shell.asm's start: already
            ; calls K_BATCH_READLINE as the very first thing it does,
            ; every cycle, including its first ever -- an already-
            ; active batch is picked up completely transparently,
            ; identical to a user having just typed "autoexec.bat" and
            ; the shell's own .bat-extension detection having started
            ; it (same echo behavior, same empty-file EOF handling, no
            ; new code paths in the shell at all). Must run AFTER
            ; cur_drive is set (just above), since the leading '/' in
            ; "/autoexec.bat" resolves from the root of whatever drive
            ; is currently active.
            mov     rf, autoexec_path
            call    batch_start

            ; ERRORLEVEL starts at 0 for a fresh boot, before any
            ; command has ever run -- run_loop below is the only other
            ; place RUN_ERRORLEVEL is ever written, once per resolved
            ; command, so this boot-time init is the sole reason
            ; %ERRORLEVEL% reads 0 rather than garbage on first use.
            mov     rf, RUN_ERRORLEVEL
            ldi     0
            str     rf

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
            call    prog_run            ; D = exit code, DF=0/1
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

            ; capture the real exit code into RUN_ERRORLEVEL -- D is
            ; still exactly what prog_run left it as (the intervening
            ; lbdf doesn't touch D whether taken or not), but the mov
            ; below would clobber it (gotcha #4), so stash it in RC's
            ; low byte first: RC's own argc value was already consumed
            ; by prog_run's own RA/RC arguments above and is never
            ; read again before run_loop reloads it fresh next cycle.
            plo     rc
            mov     rf, RUN_ERRORLEVEL
            glo     rc
            str     rf

            call    _redir_teardown     ; close whatever prog_run's own
                                        ; _redir_setup call opened/
                                        ; reserved, always -- checked
                                        ; AFTER prog_run's own DF, since
                                        ; this call would otherwise
                                        ; clobber it before the check
                                        ; above ever ran
            lbr     run_loop

run_bad_program:
            ; prog_run's own D value isn't a meaningful exit code here
            ; (its own header: "DF = 1 on error... nothing is run in
            ; that case") -- write a fixed sentinel instead
            mov     rf, RUN_ERRORLEVEL
            ldi     1
            str     rf

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
;          D  = cur_drive
;
;          If cur_drive names a drive that is no longer mounted, it is
;          reset to shell_drive first and THAT is what comes back -- see
;          the 2026-09-09 fix below. The pair returned is always usable.
; Modifies: R8, R9, RD, RF only (RA/RB/RC/R7 explicitly protected, same
;          footprint as before this whole fix)
;------------------------------------------------------------------
            endp

            proc    kernel_getcurdir
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
                                        ; relative to it. Cheap when
                                        ; already active (a documented
                                        ; no-op check inside
                                        ; _switch_drive itself).
            lbnf    kgcd_active         ; DF=0: cur_drive is live

            ; BUG FIX (2026-09-09): this used to ignore DF, on the
            ; grounds that cur_drive is only ever SET to a present drive
            ; (kernel_setdrive checks drive_present). True, and not
            ; enough: a drive can go absent AFTER cur_drive was pointed
            ; at it, which is exactly what UMOUNT does. UMOUNT moves
            ; cur_drive away first to avoid it -- but that is userland
            ; upholding a kernel invariant, and a stale or simply
            ; different UMOUNT does not.
            ;
            ; Ignoring the failure was not harmless. The active BPB
            ; stayed whatever it happened to be, so the caller got a
            ; cluster number belonging to one drive and then read it
            ; against another's geometry: "dir" listed C:'s root while
            ; the prompt and header both said E:. Path-based access has
            ; always failed safely here (path_resolve checks this same
            ; DF), so the hole was exactly the K_GETCURDIR +
            ; K_DIR_OPEN/K_DIR_READ callers -- the prompt, PWD, and a
            ; bare DIR.
            ;
            ; Repair it rather than report it. Every caller wants a
            ; USABLE (drive, cluster) pair, none of them check DF today,
            ; and shell_drive is the one slot guaranteed live: it is set
            ; at boot from a shell that actually loaded, and MOUNT and
            ; UMOUNT both refuse to touch it. The user sees the prompt
            ; change to that drive, which is the correct and honest
            ; outcome for "the drive you were on is gone".
            mov     rf, shell_drive
            ldn     rf
            call    _switch_drive
            lbdf    kgcd_active         ; even that failed: nothing sane
                                        ; is left to do, so fall through
                                        ; with whatever is active rather
                                        ; than loop

            ; Re-read shell_drive from memory rather than carrying it in
            ; a register across the call above: _switch_drive's clobber
            ; list covers every register this routine could have used.
            mov     rf, cur_drive
            mov     rd, shell_drive
            ldn     rd
            str     rf                  ; cur_drive = shell_drive

kgcd_active:

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
            endp

            proc    kernel_setcurdir
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
            endp

            proc    kernel_setdrive
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
            endp

            proc    kernel_getshelldrive
            mov     rf, shell_drive
            ldn     rf
            rtn

; kernel_get_errorlevel: read the last command's exit code -- see
; K_GET_ERRORLEVEL's own kernel_api.inc doc comment.
            endp

            proc    kernel_get_errorlevel
            mov     rf, RUN_ERRORLEVEL
            ldn     rf
            clc
            rtn

;------------------------------------------------------------------
; kernel_drive_invalidate: drop any cached kernel state that refers to
; a given drive, so its drive_bpb_table entry can be safely replaced
; (MOUNT) or its drive_present flag cleared (UMOUNT).
;
; Two jobs, and only these two -- everything else MOUNT/UMOUNT need
; they can already do for themselves through DRIVE_DATA_PTR:
;   1. If the drive is the currently ACTIVE one, flush its dirty FAT
;      sector to disk. This must happen while the active BPB block
;      still describes the OLD partition, because fat_flush derives
;      its LBAs from bpb_fat_lba/bpb_spf/bpb_num_fats.
;   2. Force active_bpb_drive to $FF, so the next _switch_drive does a
;      real reload from drive_bpb_table instead of its no-op fast path.
;      Without this a MOUNT onto the active drive would be invisible.
;
; *** ORDERING CONTRACT -- READ BEFORE CHANGING A CALLER ***
; Call this BEFORE overwriting drive_bpb_table[i] or clearing
; drive_present[i]. Calling it afterwards would flush the cached FAT
; sector to an LBA computed from the NEW partition's geometry, which is
; silent cross-partition corruption, not a recoverable error.
;
; A drive that is not currently active has nothing cached (the FAT
; cache only ever holds one drive's sector, and _switch_drive already
; flushed the outgoing drive on its way out), so the whole routine is
; a cheap no-op in that case.
;
; Args:    D = drive index (0..DRIVE_COUNT-1)
; Returns: DF = 0 always (a flush failure is not reported -- see below)
; Modifies: D, R7, R8, RB, RC, RD, RF -- the union of this routine's
;           own scratch (RC, RF) and fat_flush's documented clobber
;           list (R7, R8, RB, RC, RD, RF). Spelled out rather than
;           deferred to fat_flush, so a caller does not have to chase
;           it (gotcha #10).
;------------------------------------------------------------------
            endp

            proc    kernel_drive_invalidate
            plo     rc                  ; stash the index before any mov
                                        ; can clobber D (gotcha #4)
            mov     rf, active_bpb_drive
            ldn     rf
            str     r2                  ; M(X) = currently active drive
            glo     rc
            sm                          ; D = target - active
            lbnz    kdi_done            ; not the active drive: nothing
                                        ; of this drive's is cached

            call    fat_flush           ; uses the OLD (still correct)
                                        ; active BPB fields -- see the
                                        ; ordering contract above. Its
                                        ; DF is deliberately ignored:
                                        ; there is nothing useful a
                                        ; caller could do about a failed
                                        ; flush at this point, and
                                        ; reporting it would leave the
                                        ; stale active_bpb_drive in
                                        ; place, which is worse.

            mov     rf, active_bpb_drive
            ldi     $FF
            str     rf                  ; force a real reload on the
                                        ; next _switch_drive

kdi_done:
            clc
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
            endp

            proc    kernel_shell_init
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
            endp
