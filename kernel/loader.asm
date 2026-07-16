;
; loader.asm - User program loader
;
; Provides:
;   prog_run       -- load a program file (at an exact, already-
;                      resolved path) to PROG_BASE and run it
;   prog_run_shell -- load+run "C:/bin/shell" specifically, via a
;                      cached directory-entry location instead of a
;                      full path search (see its own header comment)
;
; Program binary format (mirrors the kernel's own header convention):
;   $00-$02   magic bytes 'EDF'
;   $03       program major version
;   $04-$05   reserved
;   $06+      code (entry point is always at load_address + $06)
;
; As of the shell-as-a-program move, the loader no longer searches for
; the program itself -- that's progs/shell.asm's job (bare name ->
; "/bin/"+name, falling back to shell_drive if not found on the
; active drive; a name containing '/' -> used as-is), which now also
; confirms existence via K_STAT before ever handing a path to the
; kernel (see kernel/kernel.asm's run_loop). This file just opens the
; exact path it's given (or, for the shell specifically, skips
; straight to a cached location).
;
; K_PROG_LOAD/K_PROG_EXEC REMOVED 2026-07-13 (see kernel_api.inc's own
; removal note): neither could ever be safely called by a program
; while it was running (loading a second program to PROG_BASE
; overwrites the caller's own currently-executing code). Collapsed
; into a single internal routine, prog_run, with no jump-table
; exposure at all -- kernel.asm's run_loop calls it directly, exactly
; as it called prog_load/prog_exec before.
;

#include    include/opcodes.def
#include    include/bios.inc
#include    include/kernel.inc

            extrn   file_open
            extrn   file_close
            extrn   file_read
            extrn   mem_base
            extrn   mem_top
            extrn   _switch_drive
            extrn   fd_table
            extrn   shell_drive
            extrn   shell_elba
            extrn   shell_eoff

; same-file proc references (required even within the same file)
            extrn   _prog_finish_load
            extrn   _prog_exec_now
            extrn   prog_run

; same-file data references (required even within the same file)
            extrn   prog_fcb
            extrn   prog_iobuf
            extrn   prog_handle
            extrn   prog_size
            extrn   prun_argv
            extrn   prun_argc
            extrn   saved_sp

; ----------------------------------------------------------------
; _prog_finish_load: shared tail for both prog_run and
; prog_run_shell, once a handle is already open in prog_handle --
; read the whole file to PROG_BASE, close it, validate the 'EDF'
; magic, and compute/publish mem_base. This is everything the old
; prog_load did AFTER its own file_open call; factored out so
; prog_run_shell's own direct-FCB-population "open" (see below) can
; share it without duplicating this logic.
; Args:    none (prog_handle already set to an open handle)
; Returns: DF = 0 on success (PROG_BASE holds the loaded program,
;          mem_base/LOADER_ARGS updated), DF = 1 on error (read error
;          or bad magic) -- the handle is always closed either way
; Modifies: R7, R8, R9, RB, RC, RD, RF
; ----------------------------------------------------------------
            proc    _prog_finish_load

            ; count = mem_top - PROG_BASE
            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top

            ldi     low PROG_BASE
            str     r2
            glo     rd
            sm                          ; D = mem_top.lo - PROG_BASE.lo
            plo     rc
            ldi     high PROG_BASE
            str     r2
            ghi     rd
            smb                         ; D = mem_top.hi - PROG_BASE.hi - borrow
            phi     rc                  ; RC = available space (mem_top - PROG_BASE)

            mov     rf, prog_handle
            ldn     rf                  ; D = handle
            plo     r9                  ; stash it (mov below clobbers D)
            mov     rf, PROG_BASE       ; RF = destination
            glo     r9                  ; D = handle (reloaded, correct)
            call    file_read           ; RC = bytes read, DF=0/1
            lbdf    pfl_read_err

            mov     rf, prog_size
            ghi     rc
            str     rf
            inc     rf
            glo     rc
            str     rf                  ; prog_size = bytes loaded

            mov     rf, prog_handle
            ldn     rf                  ; D = handle
            call    file_close

            ; validate the 'EDF' magic header
            mov     rf, PROG_BASE
            lda     rf
            xri     'E'
            lbnz    pfl_bad_magic
            lda     rf
            xri     'D'
            lbnz    pfl_bad_magic
            lda     rf
            xri     'F'
            lbnz    pfl_bad_magic

            ; mem_base = PROG_BASE + prog_size, rounded up to 16 bytes
            mov     rf, prog_size
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = prog_size

            glo     rd                  ; round up: (size + 15) & ~15
            adi     15
            plo     rd
            ghi     rd
            adci    0
            phi     rd
            glo     rd
            ani     $F0
            plo     rd

            ghi     rd                  ; PROG_BASE's low byte is 0, so
            adi     high PROG_BASE      ; adding it is just += PROG_BASE's
            phi     rd                  ; own high byte -- RD = mem_base

            mov     rf, mem_base
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; mem_base updated

            ; publish mem_base/mem_top at the fixed LOADER_ARGS address
            ; for the program to read (see kernel.inc)
            mov     rf, LOADER_ARGS
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; LOADER_ARGS+0,1 = mem_base

            mov     rf, mem_top
            lda     rf
            phi     rd
            ldn     rf
            plo     rd                  ; RD = mem_top
            mov     rf, LOADER_ARGS+2
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; LOADER_ARGS+2,3 = mem_top

            clc                         ; DF = 0, success
            rtn

pfl_read_err:
            ; file_read failed: still need to close what was opened
            mov     rf, prog_handle
            ldn     rf
            call    file_close
pfl_bad_magic:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; _prog_exec_now: run the program currently loaded at PROG_BASE.
; Args:    RA = pointer to the argv table, RC = argc (see
;          include/kernel_api.inc) -- both passed straight through
;          untouched, since this proc has no reason to use either
;          itself; the caller must set them immediately before
;          calling, since anything else called in between (like
;          _prog_finish_load) may clobber them.
; Returns: D = program exit code (convention to be defined)
;          DF = 0 normally
;
; Saves/restores R2 (the stack pointer) around the call as a defensive
; measure -- a normal call/rtn pair already balances R2 on its own,
; but this guards against a misbehaving program leaving it corrupted.
; ----------------------------------------------------------------
            proc    _prog_exec_now

            mov     rf, saved_sp
            ghi     r2
            str     rf
            inc     rf
            glo     r2
            str     rf                  ; saved_sp = R2

            call    PROG_BASE+6         ; jump to program entry; D = exit
                                        ; code by convention on return
            plo     rd                  ; save exit code while restoring R2

            mov     rf, saved_sp
            lda     rf
            phi     r2
            ldn     rf
            plo     r2                  ; restore kernel stack pointer

            glo     rd                  ; D = exit code
            clc                         ; DF = 0
            rtn

            endp

; ----------------------------------------------------------------
; prog_run: load a program at an exact path into RAM and run it.
; Args:   RF = pointer to null-terminated path, already fully
;              resolved (and confirmed to exist) by the caller -- no
;              searching is done here
;         RA = pointer to the argv table, RC = argc
; Returns: D = program exit code
;          DF = 0 on success, DF = 1 on error (not found, load error,
;          bad magic) -- nothing is run in that case
; ----------------------------------------------------------------
            proc    prog_run

            ; stash the incoming argv pointer/argc immediately, in
            ; memory -- the load sequence below (file_open/file_read/
            ; file_close) clobbers both (file_open's very first
            ; instruction uses RC as scratch for its own mode
            ; argument, and RA gets reused as prog_run's own I/O
            ; buffer pointer right below), and neither is needed again
            ; until the very end, right before _prog_exec_now
            mov     rb, prun_argv
            ghi     ra
            str     rb
            inc     rb
            glo     ra
            str     rb                  ; prun_argv = RA

            mov     rb, prun_argc
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb                  ; prun_argc = RC

            ; CALLER-ALLOCATED FCBs (2026-07-15): file_open needs the
            ; caller's own FCB/I-O-buffer pointers (RD/RA) -- prog_run
            ; is the kernel's own one caller, so it uses its own
            ; dedicated, permanently kernel-resident prog_fcb/
            ; prog_iobuf. Both movs must happen BEFORE the "ldi 0" mode
            ; load right below, since mov itself clobbers D (gotcha
            ; #4) -- doing them first and the mode load last guarantees
            ; D is correct at the actual call. RF (the path argument)
            ; is untouched by any of this, so it reaches file_open
            ; exactly as prog_run itself received it.
            mov     rd, prog_fcb        ; RD = our own FCB memory
            mov     ra, prog_iobuf      ; RA = our own I/O buffer
                                        ; (safe to overwrite now -- the
                                        ; real tail pointer is already
                                        ; stashed above)
            ldi     0                   ; mode = read
            call    file_open           ; D = handle, DF=0/1
            lbdf    prun_err            ; not found

            ; BUG FIX pattern preserved from the pre-simplification
            ; code: "mov rf, prog_handle" itself clobbers D (gotcha #4),
            ; so the handle file_open just returned in D has to be
            ; stashed in a spare register first, or it doesn't survive
            ; to the "str rf" below.
            plo     r9                  ; stash handle
            mov     rf, prog_handle
            glo     r9                  ; D = handle (reloaded)
            str     rf                  ; prog_handle = handle

            call    _prog_finish_load
            lbdf    prun_err

            mov     rf, prun_argv
            lda     rf                  ; D = argv pointer high byte
            phi     ra
            ldn     rf                  ; D = argv pointer low byte
            plo     ra                  ; RA = argv pointer (reloaded)

            mov     rf, prun_argc
            lda     rf                  ; D = argc high byte
            phi     rc
            ldn     rf                  ; D = argc low byte
            plo     rc                  ; RC = argc (reloaded)

            call    _prog_exec_now      ; D = exit code, DF = 0
            rtn

prun_err:
            stc                         ; DF = 1, error
            rtn

            endp

; ----------------------------------------------------------------
; prog_run_shell: load+run "C:/bin/shell" specifically.
;
; Fast path: reads the shell's own cached directory-entry sector
; directly (shell_drive/shell_elba/shell_eoff, populated once at boot
; by K_SHELL_INIT -- see kernel.asm's own comment on those fields)
; instead of a full path_resolve+directory-scan on every single
; command cycle. Validates what's found there before trusting it
; (rejects a deleted entry or a directory) and populates our own
; prog_fcb directly from the raw on-disk fields, bypassing
; file_open's search entirely -- then reuses the exact same
; _prog_finish_load/_prog_exec_now tail prog_run itself uses.
;
; Falls back to an ordinary prog_run("C:/bin/shell") -- a real
; path_resolve+directory-scan -- if the fast path's own validation
; ever fails (the cached location no longer describes a live file,
; e.g. after a REN or a DEL+recreate-elsewhere moved the entry). A
; stale cache is therefore never a correctness risk, only a lost
; optimization in an already-rare case.
;
; Args:    none (uses shell_drive/shell_elba/shell_eoff; the command
;          tail is NOT set up here -- the shell itself never reads
;          its own command tail, matching this project's own existing
;          convention for invoking it)
; Returns: D = program exit code, DF = 0 on success, DF = 1 if the
;          shell could not be loaded at all (fatal to the caller --
;          see kernel.asm's run_loop)
; ----------------------------------------------------------------
            proc    prog_run_shell

            mov     rd, shell_drive
            ldn     rd
            call    _switch_drive
            lbdf    prsh_fallback       ; drive vanished (shouldn't
                                        ; happen): fallback

            ; read the dirent's own sector into our own I/O scratch
            ; buffer -- not yet needed for the real file read at this
            ; point, and file_open's own analogous first read will
            ; naturally overwrite it once FCB_F_IOVALID (left clear
            ; below) forces a fresh load
            mov     rf, shell_elba
            lda     rf                  ; D = LBA bits 23-16
            plo     r8
            lda     rf                  ; D = LBA bits 15-8
            phi     r7
            ldn     rf                  ; D = LBA bits 7-0
            plo     r7
            ldi     0
            phi     r8                  ; R8.1 = 0 (drive/head)
            mov     rf, prog_iobuf
            call    f_ideread
            lbdf    prsh_fallback

            ; locate the entry within the sector -- kept in R9 (not
            ; recomputed from memory each time) since dir.asm's own
            ; f_ideread/etc calls aren't in the way here
            mov     rf, shell_eoff
            lda     rf
            phi     r9
            ldn     rf
            plo     r9                  ; R9 = byte offset within the
                                        ; sector

            mov     rf, prog_iobuf
            add16   rf, r9
            ldn     rf
            xri     $E5
            lbz     prsh_fallback       ; deleted: fallback

            mov     rf, prog_iobuf
            add16   rf, r9
            add16   rf, DE_ATTR
            ldn     rf
            ani     ATTR_DIR
            lbnz    prsh_fallback       ; a directory: fallback

            ; --- populate our own prog_fcb directly from this raw
            ; entry, bypassing file_open's directory scan entirely ---
            mov     rb, prog_fcb        ; RB = our FCB base, walked
                                        ; sequentially field by field

            ldi     FCB_F_OPEN
            str     rb
            inc     rb                  ; FCB_FLAGS

            ; DE_CLUSTER (2 bytes, LE on disk) -> FCB_SCLUST/FCB_CCLUST
            ; (2 bytes, BIG-endian -- confirmed against file_open's own
            ; DIRENT_CLUST->FCB_SCLUST copy, which writes the high byte
            ; first). Read the on-disk LE bytes into RC in native
            ; register form first (rc.0=low, rc.1=high), then write
            ; them back out high-byte-first to match that convention --
            ; NOT a straight sequential copy, unlike FCB_ELBA/FCB_EOFF
            ; below (whose own source fields are already BE).
            mov     rf, prog_iobuf
            add16   rf, r9
            add16   rf, DE_CLUSTER
            lda     rf                  ; D = cluster low byte
            plo     rc
            ldn     rf                  ; D = cluster high byte
            phi     rc                  ; RC = cluster

            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb
            inc     rb                  ; FCB_SCLUST (2 bytes, high
                                        ; byte first)
            ghi     rc
            str     rb
            inc     rb
            glo     rc
            str     rb
            inc     rb                  ; FCB_CCLUST (2 bytes, same
                                        ; value -- start of chain)

            ldi     0
            str     rb
            inc     rb                  ; FCB_CSECT = 0
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_BOFF = 0 (2 bytes)

            ; DE_SIZE (4 bytes, LE on disk) -> FCB_FSIZE (4 bytes, BE)
            ; -- explicit byte-by-byte reversal (on-disk byte 3 is the
            ; MSB and goes first into FCB_FSIZE, on-disk byte 0 is the
            ; LSB and goes last)
            mov     rf, prog_iobuf
            add16   rf, r9
            add16   rf, DE_SIZE+3       ; RF -> on-disk size byte 3 (MSB)
            ldn     rf
            str     rb
            inc     rb                  ; FCB_FSIZE byte 0 (MSB)
            dec     rf
            ldn     rf
            str     rb
            inc     rb                  ; FCB_FSIZE byte 1
            dec     rf
            ldn     rf
            str     rb
            inc     rb                  ; FCB_FSIZE byte 2
            dec     rf
            ldn     rf
            str     rb
            inc     rb                  ; FCB_FSIZE byte 3 (LSB)

            ldi     0
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb
            str     rb
            inc     rb                  ; FCB_FPOS = 0 (4 bytes)

            mov     rf, shell_elba
            lda     rf
            str     rb
            inc     rb
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_ELBA = shell_elba (3 bytes)

            mov     rf, shell_eoff
            lda     rf
            str     rb
            inc     rb
            ldn     rf
            str     rb
            inc     rb                  ; FCB_EOFF = shell_eoff (2 bytes)

            mov     rf, prog_iobuf
            ghi     rf
            str     rb
            inc     rb
            glo     rf
            str     rb
            inc     rb                  ; FCB_IOBUF = &prog_iobuf

            mov     rf, shell_drive
            ldn     rf
            str     rb                  ; FCB_DRIVE

            ; --- register into a free fd_table slot, exactly as
            ; file_open's own fopen_found does ---
            ldi     0
            plo     rc                  ; RC.0 = index = 0
            mov     rf, fd_table

prsh_scan:
            glo     rc
            xri     FD_COUNT
            lbz     prsh_fallback       ; no free slot: fallback (very
                                        ; unlikely -- the previous
                                        ; command's own FCBs should
                                        ; already be closed by now)
            lda     rf
            lbnz    prsh_next
            ldn     rf
            lbz     prsh_found
prsh_next:
            inc     rf
            glo     rc
            adi     1
            plo     rc
            lbr     prsh_scan

prsh_found:
            dec     rf
            ; BUG FIX: file_open's own analogous fopen_found copies a
            ; caller's FCB pointer OUT of fo_fcb, a 2-byte variable
            ; that HOLDS a pointer value (via lda/ldn, dereferencing
            ; it) -- prog_fcb here is not that shape at all, it IS the
            ; FCB struct itself (ds FCB_LEN). The fix is to take RD's
            ; own value after "mov rd, prog_fcb" (the struct's
            ; address) directly via ghi/glo, NOT to dereference it --
            ; the original lda/ldn version instead copied the FCB's
            ; own first two content bytes (FCB_FLAGS and half of
            ; FCB_SCLUST) into fd_table, leaving the handle resolving
            ; to garbage memory ever after.
            mov     rd, prog_fcb        ; RD = &prog_fcb (the address
                                        ; itself)
            ghi     rd
            str     rf
            inc     rf
            glo     rd
            str     rf                  ; fd_table[index] = &prog_fcb

            mov     rf, prog_handle
            glo     rc
            str     rf                  ; prog_handle = index

            call    _prog_finish_load
            lbdf    prsh_fallback

            call    _prog_exec_now      ; RA passed through as-is --
                                        ; the shell itself never reads
                                        ; its own command tail
            rtn

prsh_fallback:
            mov     rf, kshell_path
            call    prog_run            ; RA passed through as-is,
                                        ; same reasoning
            rtn

kshell_path:    db      "C:/bin/shell",0

            endp

;------------------------------------------------------------------
; Loader scratch data
;
; prog_fcb/prog_iobuf: this kernel's own dedicated, permanently
; resident FCB + 512-byte I/O buffer, used only for loading program
; binaries (see prog_run's own comment on why it can't use a
; program-supplied FCB the way ordinary file I/O does). prog_handle
; is the fd_table index file_open (or prog_run_shell's own direct
; registration) returned for prog_fcb. prun_argv/prun_argc are
; prog_run's own stash for the caller's argv pointer/argc across the
; load sequence (see its own comment).
;------------------------------------------------------------------
            proc    _loader_data

prog_fcb:       ds      FCB_LEN
prog_iobuf:     ds      SECTOR_SIZE
prog_handle:    db      0
prog_size:      dw      0           ; bytes actually loaded (for mem_base calc)
prun_argv:      dw      0           ; prog_run's own argv-pointer stash
prun_argc:      dw      0           ; prog_run's own argc stash
saved_sp:       dw      0           ; kernel's R2 across _prog_exec_now's call

                public  prog_fcb
                public  prog_iobuf
                public  prog_handle
                public  prog_size
                public  prun_argv
                public  prun_argc
                public  saved_sp

            endp
