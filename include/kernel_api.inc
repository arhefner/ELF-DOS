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

PROG_BASE:      equ     $2000       ; user programs load here (see kernel.inc)
LOADER_ARGS:    equ     PROG_BASE-4 ; word 0 = mem_base, word 1 = mem_top

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
DIRENT_LEN:     equ     135         ; total result buffer size
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

; next free slot address: $0148
