;
; kernel_api.inc - ELF-DOS kernel API jump table addresses
;
; #include this file in any program built to run under ELF-DOS
; (loaded via prog_load to PROG_BASE) to call kernel and BIOS
; functionality without depending on the kernel's internal layout,
; which shifts across kernel builds/versions.
;
; The table itself lives at a fixed address ($0106, the same address
; the boot chain has always jumped to) in kernel/kernel.asm. Each
; slot is a 3-byte 'lbr' to the real routine, so these addresses are
; a stable contract: new entries are only ever APPENDED here, never
; reordered or removed, so a program built against an older kernel
; keeps working after the kernel is rebuilt.
;
; Calling convention for every slot: identical to the real routine it
; forwards to (see kernel/file.asm, kernel/dir.asm, kernel/loader.asm,
; and include/bios.inc for each routine's args/returns/clobbers).
; Call like any other subroutine, e.g.:
;   ldi     0
;   call    K_FILE_OPEN
;
; K_INIT (slot 0, $0106) is the kernel's own boot entry, pinned here
; by the boot chain itself -- it is not meant to be called by
; programs (calling it would re-run kernel boot init while a program
; is already running).
;
; Command line: at program entry, RA holds a pointer to the null-
; terminated command tail (everything typed after the program name,
; trimmed -- NOT including the name itself, same convention as a DOS
; PSP command tail; empty string, not a null pointer, if no arguments
; were given). Passed in a register rather than a fixed address since
; it's only needed once, at entry -- unlike mem_base/mem_top below,
; which a program may need to consult at any point during its run
; (e.g. from within a heap allocator), and so use a fixed address.
;
; This file is deliberately independent of kernel.inc (which is for
; the kernel's own internal structures -- FCB/BPB/directory-entry
; layout, etc.) so that program code never has a reason to reach into
; kernel internals that could change across kernel updates. PROG_BASE
; and LOADER_ARGS are restated below rather than shared by #include;
; keep them in sync with kernel.inc if they ever change.
;

PROG_BASE:      equ     $3E00       ; user programs load here (see kernel.inc;
                                    ; == KERN_LOAD in boot/mbr.asm by design --
                                    ; krnboot's own sector is dead once boot
                                    ; completes, so program loads reuse it)
LOADER_ARGS:    equ     PROG_BASE-4 ; word 0 = mem_base, word 1 = mem_top

; LINE_BUF/RUN_TAIL_PTR/RUN_PATH: the shell-as-a-program handoff
; protocol (see kernel.inc's own copy of this comment for the full
; reasoning). Only progs/shell.asm has a real reason to touch these --
; ordinary programs should not -- but they're restated here rather than
; given a separate include file, matching this file's existing
; precedent for PROG_BASE/LOADER_ARGS.
LINE_BUF:       equ     $0080       ; shell command input buffer (128 bytes)
RUN_TAIL_PTR:   equ     PROG_BASE-6     ; 2 bytes: pointer into LINE_BUF
                                        ; where the command tail starts
RUN_PATH:       equ     PROG_BASE-70    ; 64-byte buffer: resolved path
                                        ; to load next
RUN_PATH_LEN:   equ     64              ; RUN_PATH's own size, for
                                        ; bounds-checking writes to it

K_INIT:         equ     $0106       ; reserved -- kernel boot entry, do not call

; ---- ELF-DOS kernel calls (see kernel/file.asm, kernel/dir.asm, kernel/loader.asm) ----
K_FILE_OPEN:    equ     $0109
K_FILE_CLOSE:   equ     $010C
K_FILE_READ:    equ     $010F
K_FILE_WRITE:   equ     $0112
K_FILE_SEEK:    equ     $0115
K_DIR_OPEN:     equ     $0118
K_DIR_READ:     equ     $011B
K_PROG_LOAD:    equ     $011E
K_PROG_EXEC:    equ     $0121
K_GETCURDIR:    equ     $0142       ; RD = current directory cluster (no args)
K_SETCURDIR:    equ     $0145       ; args: RD = new current directory cluster

; K_PATH_RESOLVE: resolve a '/'-separated path to (parent directory
; cluster, final path component). A leading '/' resolves from the
; FAT16 root; otherwise resolution starts from RD (get the current
; directory via K_GETCURDIR first). Every component except the last
; is looked up as a directory ('.' and '..' work automatically --
; real FAT entries, no special-casing needed); the last component is
; NOT looked up here -- the caller decides what to do with it (e.g.
; search for a file vs. a directory).
;
; Args:    RF = pointer to null-terminated path string (not modified)
;          RD = base cluster for relative paths (ignored if the path
;               has a leading '/')
; Returns: RD = resolved parent directory cluster
;          RF = pointer to the final path component, null-terminated.
;               Points into kernel scratch memory -- same convention
;               as the command-tail pointer in RA at program entry,
;               valid until the next K_PATH_RESOLVE call reuses it.
;               Empty string if the path was empty, "/", or ended in
;               a separator (the resolved RD cluster IS the target
;               in that case -- e.g. CD should skip straight to
;               K_SETCURDIR rather than searching for an empty name).
;          DF = 0 on success, DF = 1 if an intermediate component
;               was not found, or was found but is not a directory
K_PATH_RESOLVE: equ     $0148

; K_FILE_DELETE: delete a file (not a directory -- rejected).
; Crash-safe ordering: the directory entry is marked deleted on disk
; BEFORE the cluster chain is freed, so an interruption partway
; through leaves at worst a recoverable cluster leak (via fsck), not
; a live entry pointing at clusters the FAT has already freed.
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (not found, is a
;          directory, or an intermediate path component is invalid)
K_FILE_DELETE:  equ     $014B

; K_DIR_CREATE: create a new, empty subdirectory (MD). Single-level
; only -- the parent must already exist (no implicit intermediate
; directory creation, matching classic DOS MD).
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (already exists, an
;          intermediate path component is invalid, or disk full)
K_DIR_CREATE:   equ     $014E

; K_DIR_REMOVE: remove an EMPTY subdirectory (RD). Refuses non-empty
; directories (no recursive delete), "."/".."  and the root itself.
;
; Args:    RF = pointer to null-terminated path string
; Returns: DF = 0 on success, DF = 1 on error (not found, not a
;          directory, not empty, is "."/".."/root, or an intermediate
;          path component is invalid)
K_DIR_REMOVE:   equ     $0151

; K_FILE_RENAME: rename a file or directory within the SAME parent
; directory (no cross-directory move). Works on either files or
; directories.
;
; Args:    RF = pointer to null-terminated OLD path string
;          RD = pointer to null-terminated NEW name (bare name, no
;          path separator -- always applies within the OLD path's
;          own parent directory)
; Returns: DF = 0 on success, DF = 1 on error (old not found, new
;          name already exists or is invalid, old or new name is
;          "."/"..", or an intermediate component of the old path is
;          invalid)
K_FILE_RENAME:  equ     $0154

; ---- Kernel version (read directly, no call needed) ----
; $0100's 6-byte header layout is a stable, never-shifting contract
; (same reasoning as PROG_BASE/LOADER_ARGS above), so the version
; bytes are just read directly rather than through a jump-table call.
KERNEL_HDR_VER: equ     $0103       ; major version byte; minor follows at +1

; ---- K_DIR_READ result buffer format (DIRENT_LEN bytes, caller-provided) ----
; Restated from kernel.inc (not #included, per the note above) since any
; program calling K_DIR_READ needs to know how to parse what it returns.
DIRENT_NAME:    equ     0           ; null-terminated filename (up to 127 chars)
DIRENT_ATTR:    equ     128         ; FAT attribute byte
DIRENT_CLUST:   equ     129         ; first cluster, 2 bytes, big-endian
DIRENT_SIZE:    equ     131         ; file size, 4 bytes, big-endian
DIRENT_WRTTIME: equ     135         ; last-write time, 2 bytes, big-endian,
                                    ; packed FAT format: bits 15-11=hour,
                                    ; 10-5=minute, 4-0=seconds/2
DIRENT_WRTDATE: equ     137         ; last-write date, 2 bytes, big-endian,
                                    ; packed FAT format: bits 15-9=year-1980,
                                    ; 8-5=month, 4-0=day
DIRENT_LEN:     equ     139         ; total result buffer size
ATTR_DIR:       equ     $10         ; DIRENT_ATTR bit set for subdirectories

; ---- BIOS passthroughs (see include/bios.inc for each one's convention) ----
; Calling through here rather than directly into BIOS means a program
; has no dependency on the raw BIOS vector table, and gives ELF-DOS a
; hook point for future I/O redirection.
K_TYPE:         equ     $0124       ; -> f_type
K_MSG:          equ     $0127       ; -> f_msg
K_INMSG:        equ     $012A       ; -> f_inmsg
K_GETDEV:       equ     $012D       ; -> f_getdev
K_GETTOD:       equ     $0130       ; -> f_gettod
K_SETTOD:       equ     $0133       ; -> f_settod
K_INPUTL:       equ     $0136       ; -> f_inputl
K_BOOT:         equ     $0139       ; -> f_boot
K_TTY:          equ     $013C       ; -> f_tty
K_SETBD:        equ     $013F       ; -> f_setbd
K_READ:         equ     $0157       ; -> f_read: blocking read of a single
                                    ; character from the console, returned
                                    ; in D. Standard Elf/OS BIOS contract,
                                    ; confirmed on hardware 2026-07-10 via
                                    ; COPY's overwrite-confirmation prompt.

; K_BPB_INIT/K_FAT_INIT/K_FILE_INIT: reserved -- boot-only one-time init,
; called exactly once each by boot/krnboot.asm's relocated init code
; (see that file's own header comment), not meant to be called by
; ordinary programs (re-running them mid-session would reset live BPB/
; FAT-cache/FCB state out from under whatever's currently using it).
; Exist as jump-table slots at all only because krnboot.asm is linked
; completely separately from kernel.bin, so this fixed-address table is
; the only way it can reach these kernel-resident routines -- same
; reasoning as every other slot in this file, just with a boot-code
; caller instead of a program.
K_BPB_INIT:     equ     $015A       ; -> bpb_init
K_FAT_INIT:     equ     $015D       ; -> fat_init
K_FILE_INIT:    equ     $0160       ; -> file_init

; next free slot address: $0163
