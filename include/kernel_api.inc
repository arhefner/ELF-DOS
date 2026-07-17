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
; slot is a 3-byte 'lbr' to the real routine. Once this project
; releases, these addresses become a stable contract (new entries only
; ever APPENDED, never reordered or removed, so a program built
; against an older kernel keeps working after a rebuild) -- but until
; then, EVERY program in this repo is rebuilt from source on every
; `make progs`, so nothing external depends on today's addresses.
; 2026-07-13's pre-release cleanup pass (removing K_BPB_INIT/
; K_PROG_LOAD/K_PROG_EXEC, adding K_SHELL_INIT/K_GETSHELLDRIVE, and
; renumbering the whole table sequentially rather than leaving gaps)
; deliberately used this last mutable window; don't repeat that kind
; of full renumber after release.
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
; Command line: at program entry, RA holds a pointer to the argument
; table (argv) and RC holds the argument count (argc). argv is an
; array of RC 16-bit big-endian pointers, argv[0..argc-1], each
; pointing to a null-terminated string. argv[0] is the program's own
; invocation name (matching real C's main(argc, argv) convention, so
; the eventual ELFC C startup code needs no special-casing); argc is
; therefore always >= 1 on a successful hand-off. Arguments are
; tokenized by the shell with quoting ("..." keeps embedded spaces in
; one token) and backslash-escaping (\X produces a literal X, inside or
; outside quotes -- covers \" for a literal quote, \\ for a literal
; backslash, and \<space> for a literal space in an unquoted token).
;
; Both RA and RC are passed in registers rather than fixed addresses
; since they're only needed once, at entry -- unlike mem_base/mem_top
; below, which a program may need to consult at any point during its
; run (e.g. from within a heap allocator), and so use a fixed address
; instead. Like any register, neither is guaranteed to survive a
; kernel/BIOS call -- stash to memory (or another register) immediately
; if either is needed after the first such call (see
; progs/template.asm's own header comment for the canonical example).
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

; LINE_BUF/RUN_ARGC/RUN_ARGV_TABLE/RUN_PATH: the shell-as-a-program
; handoff protocol (see kernel.inc's own copy of this comment for the
; full reasoning). Only progs/shell.asm has a real reason to touch
; these -- ordinary programs should not, and never reference them by
; name; they only ever see the RA/RC register values built from them
; at entry (see the "Command line" section above) -- but they're
; restated here rather than given a separate include file, matching
; this file's existing precedent for PROG_BASE/LOADER_ARGS.
LINE_BUF:       equ     $0080       ; shell command input buffer (128 bytes)
RUN_ARGC:       equ     PROG_BASE-6     ; word: argument count
RUN_ARGV_TABLE: equ     PROG_BASE-38    ; ARGV_MAX_ARGS 2-byte pointers,
                                        ; argv[0..argc-1]
ARGV_MAX_ARGS:  equ     16              ; RUN_ARGV_TABLE's own capacity
RUN_PATH:       equ     PROG_BASE-102   ; 64-byte buffer: resolved path
                                        ; to load next
RUN_PATH_LEN:   equ     64              ; RUN_PATH's own size, for
                                        ; bounds-checking writes to it

; RUN_REDIR_OUT/RUN_REDIR_OUT_APPEND/RUN_REDIR_IN: I/O redirection relay
; -- same mechanism as RUN_PATH above (kernel/shell-internal only, see
; kernel.inc's own copy of this comment for the full reasoning). Each is
; a pointer into LINE_BUF (not a copied buffer), 0 = no redirect of that
; kind.
RUN_REDIR_OUT:      equ     PROG_BASE-105
RUN_REDIR_OUT_APPEND: equ   PROG_BASE-106
RUN_REDIR_IN:       equ     PROG_BASE-108

K_INIT:         equ     $0106       ; reserved -- kernel boot entry, do not call

; FCB_LEN/FCB_IOBUF_LEN: sizes only, not the field layout (which stays
; kernel-internal, see kernel.inc's own FCB_* offsets) -- same
; "publish a size, not the struct" precedent as DIRENT_LEN below.
; CALLER-ALLOCATED FCBs (2026-07-15): a program declares its own
; `ds FCB_LEN` (the FCB itself) and `ds FCB_IOBUF_LEN` (that FCB's own
; private 512-byte sector buffer) per file it wants open at once, and
; passes both pointers to K_FILE_OPEN. The kernel still hands back a
; plain small-integer handle (same as always -- needed for the future
; ELFC C library's own low-level I/O convention), now backed by an
; 8-slot table of pointers instead of a 3-slot table of full FCBs, so
; the real per-file storage lives in the (much larger) caller's own
; RAM rather than the kernel's.
FCB_LEN:        equ     32
FCB_IOBUF_LEN:  equ     512

; ---- ELF-DOS kernel calls (see kernel/file.asm, kernel/dir.asm, kernel/loader.asm) ----
; K_FILE_OPEN:  Args: RF = path, D = mode (0=read, 1=read/write),
;               RD = pointer to caller's FCB_LEN-byte FCB (need not be
;               pre-zeroed -- file_open initializes every field),
;               RA = pointer to caller's FCB_IOBUF_LEN-byte I/O buffer.
;               Returns: D = handle (small integer, same convention
;               as before), DF = 0/1.
; K_FILE_CLOSE/K_FILE_SEEK: Args: D = handle. Returns: DF = 0/1.
; K_FILE_READ/K_FILE_WRITE: Args: D = handle, RF = data buffer,
;               RC = byte count. Returns: RC = bytes actually
;               transferred (read only), DF = 0/1.
K_FILE_OPEN:    equ     $0109
K_FILE_CLOSE:   equ     $010C
K_FILE_READ:    equ     $010F
K_FILE_WRITE:   equ     $0112
K_FILE_SEEK:    equ     $0115
K_DIR_OPEN:     equ     $0118
K_DIR_READ:     equ     $011B

; K_PROG_LOAD/K_PROG_EXEC: REMOVED 2026-07-13 (pre-release jump-table
; cleanup). Neither could ever be safely called by a program while it
; was running -- loading a second program to PROG_BASE overwrites the
; caller's own currently-executing code, the exact constraint that
; already forced the shell hand-off protocol (RUN_PATH/RUN_ARGC/
; RUN_ARGV_TABLE) in the first place. Confirmed via repo-wide grep that the only
; callers were kernel.asm's own run_loop, via direct same-link-unit
; calls, never through this table. Collapsed internally into a single
; kernel-private routine (prog_run, kernel/loader.asm) with no
; jump-table exposure at all, since nothing external could ever call
; it. Safe to remove outright (not just leave a stub) because nothing
; in this repo depends on today's addresses yet -- see K_BPB_INIT's
; own removal note below for the same reasoning. (See the "BIOS
; passthroughs" section further down for K_TYPE through K_SETBD,
; which now start at $011E, immediately after K_DIR_READ, instead of
; $0124.)

; K_GETCURDIR/K_SETCURDIR/K_SETDRIVE/K_GETSHELLDRIVE: multi-drive
; current-directory state (2026-07-13). Classic MS-DOS semantics,
; adopted deliberately: CD-style directory changes and drive switches
; are two separate operations. K_SETCURDIR sets a given drive's OWN
; remembered directory and never changes which drive is active --
; "CD D:\games" while C: is active updates D's directory without
; switching to it. The ONLY way the active drive itself changes is
; K_SETDRIVE, which the shell calls directly from a bare "C:"/"D:"/
; "E:"/"F:" command line (see progs/shell.asm) -- never from CD.
;
; K_GETCURDIR: no args.
;   Returns: RD = the ACTIVE drive's current directory cluster
;            (0 = that drive's root), D = cur_drive (0-3, 0=C..3=F)
; K_SETCURDIR: Args: D = drive index (0-3), RD = new directory
;   cluster for THAT drive. Returns: nothing. Does not touch which
;   drive is active, even if D != the active drive.
; K_SETDRIVE: Args: D = drive index (0-3) to make active.
;   Returns: DF = 0 on success, DF = 1 if that drive has no mounted
;   partition (drive_present[D]=0) -- nothing changes in that case.
; K_GETSHELLDRIVE: no args. Returns: D = shell_drive (0-3), the drive
;   the shell binary itself was found on at boot (see K_SHELL_INIT
;   below) -- almost always 0 (C:) in practice. Used by progs/shell.asm
;   to build a fallback "<shell_drive>:/bin/<name>" candidate when a
;   bare command name isn't found on the active drive, so ordinary
;   commands work from any drive without needing /bin duplicated
;   everywhere.
K_GETCURDIR:    equ     $013C
K_SETCURDIR:    equ     $013F
K_SETDRIVE:     equ     $0142
K_GETSHELLDRIVE: equ    $0145

; K_PATH_RESOLVE: resolve a '/'-separated path, optionally prefixed
; with a drive letter, to (parent directory cluster, final path
; component, resolved drive). An optional 2-character "X:" prefix
; (C:-F:, case-insensitive) names the target drive; absent, the
; target drive is cur_drive. After any prefix, a leading '/' resolves
; from that drive's FAT16 root; otherwise resolution starts from that
; drive's OWN remembered current directory (drive_cur_dir[target] --
; NOT necessarily the active drive's directory, per the K_SETCURDIR
; semantics above). Internally switches the active BPB/FAT-cache to
; the target drive (see _switch_drive, kernel-internal) before doing
; any lookup that depends on it -- a no-op if that drive is already
; active. Every component except the last is looked up as a directory
; ('.' and '..' work automatically -- real FAT entries, no special-
; casing needed); the last component is NOT looked up here -- the
; caller decides what to do with it (e.g. search for a file vs. a
; directory).
;
; Args:    RF = pointer to null-terminated path string (not modified)
; Returns: RD = resolved parent directory cluster
;          RF = pointer to the final path component, null-terminated.
;               Points into kernel scratch memory -- same convention
;               as the command-tail pointer in RA at program entry,
;               valid until the next K_PATH_RESOLVE call reuses it.
;               Empty string if the path was empty, "/", or ended in
;               a separator (the resolved RD cluster IS the target
;               in that case -- e.g. CD should skip straight to
;               K_SETCURDIR rather than searching for an empty name).
;          RC.0 = resolved drive index (0-3, 0=C..3=F)
;          DF = 0 on success, DF = 1 if an intermediate component
;               was not found, was found but is not a directory, or
;               an explicit "X:" prefix named a drive with no mounted
;               partition
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
K_TYPE:         equ     $011E       ; -> f_type
K_MSG:          equ     $0121       ; -> f_msg
K_INMSG:        equ     $0124       ; -> f_inmsg
K_GETDEV:       equ     $0127       ; -> f_getdev
K_GETTOD:       equ     $012A       ; -> f_gettod
K_SETTOD:       equ     $012D       ; -> f_settod
K_INPUTL:       equ     $0130       ; -> f_inputl (RF=buffer, RC=max
                                    ; length; returns DF=0 with a real
                                    ; line in RF, or DF=1 if input has
                                    ; been redirected from a now-
                                    ; exhausted source -- e.g. `<NUL`,
                                    ; or a real file fully read -- in
                                    ; which case RF is still an empty
                                    ; string but the caller now has a
                                    ; way to tell that apart from a
                                    ; genuine blank line. Always DF=0
                                    ; for live console input -- there's
                                    ; no "EOF" from a keyboard. Check
                                    ; DF if looping on this could
                                    ; otherwise spin forever once input
                                    ; redirection is exhausted.)
K_BOOT:         equ     $0133       ; -> f_boot
K_TTY:          equ     $0136       ; -> f_tty
K_SETBD:        equ     $0139       ; -> f_setbd
K_READ:         equ     $0157       ; -> f_read: blocking read of a single
                                    ; character from the console, returned
                                    ; in D. Standard Elf/OS BIOS contract,
                                    ; confirmed on hardware 2026-07-10 via
                                    ; COPY's overwrite-confirmation prompt.

; K_FAT_INIT/K_FILE_INIT/K_SHELL_INIT: reserved -- boot-only one-time
; init, called exactly once each by boot/krnboot.asm's relocated init
; code (see that file's own header comment), not meant to be called by
; ordinary programs (re-running them mid-session would reset live BPB/
; FAT-cache/FCB state out from under whatever's currently using it).
; Exist as jump-table slots at all only because krnboot.asm is linked
; completely separately from kernel.bin, so this fixed-address table is
; the only way it can reach these kernel-resident routines -- same
; reasoning as every other slot in this file, just with a boot-code
; caller instead of a program.
;
; K_BPB_INIT REMOVED 2026-07-13 (pre-release cleanup): its own
; jump-table slot had already been a no-op stub since the multi-sector
; krnboot expansion (bpb_init's real body moved into krnboot.asm
; itself, which reaches the BPB fields directly via BPB_DATA_PTR
; instead) -- grep confirmed zero remaining callers, so the dead stub
; is now removed outright rather than kept as a stub forever.
;
; K_SHELL_INIT (new): locates the shell binary's own directory entry
; once at boot (always "C:/bin/shell" -- see kernel.inc's own
; shell_drive/shell_elba/shell_eoff comment) via _find_dirent, and
; records its (drive, sector LBA, byte offset within that sector) into
; those three kernel-resident fields, rather than a path string --
; run_loop's own reload of the shell every command cycle then reads
; that ONE known sector directly instead of re-walking a directory
; scan every time (see kernel/loader.asm's prog_run_shell). Args:
; none. Returns: DF = 0 on success (shell_drive/shell_elba/shell_eoff
; populated), DF = 1 if "C:/bin/shell" doesn't exist or isn't a file
; -- boot/krnboot.asm treats DF = 1 as a fatal boot error.
K_FAT_INIT:     equ     $015A       ; -> fat_init
K_FILE_INIT:    equ     $015D       ; -> file_init
K_SHELL_INIT:   equ     $0160       ; -> kernel_shell_init

; K_SECWRITE/K_SECREAD: raw 512-byte sector read/write by LBA, bypassing
; the FAT16 filesystem entirely -- direct passthroughs to the same BIOS
; routines this project's own fat.asm uses for FAT/directory sector I/O.
; Args: R7/R8 = 24-bit LBA (R8.0 = bits 23-16, R7.1 = bits 15-8, R7.0 =
; bits 7-0, R8.1 = 0, the drive/head byte), RF = pointer to a 512-byte
; buffer (source for K_SECWRITE, destination for K_SECREAD). Returns:
; DF = 0/1 (success/error); R7/R8 are clobbered by the call. DANGEROUS
; if misused -- a wrong LBA can silently corrupt the running filesystem
; or the boot sectors themselves. Added specifically for progs/sys.asm
; (target-side kernel/MBR installer); not intended for casual use.
K_SECWRITE:     equ     $0163       ; -> f_idewrite
K_SECREAD:      equ     $0166       ; -> f_ideread

; K_STAT: resolve a (possibly multi-component) path to its own
; directory entry, filling the caller's buffer with the same format
; K_DIR_READ itself returns (DIRENT_NAME/ATTR/CLUST/SIZE/WRTTIME/
; WRTDATE below). Works on either a file or a directory -- unlike
; K_FILE_DELETE (files only) or K_DIR_REMOVE (directories only), the
; caller decides what to do with DIRENT_ATTR's ATTR_DIR bit.
;
; Args:    RF = pointer to null-terminated path string
;          RD = pointer to a caller-provided DIRENT_LEN-byte buffer
; Returns: DF = 0 on success (buffer filled), DF = 1 on error (not
;          found, an intermediate path component is invalid, or the
;          path names the root/a directory via a trailing separator --
;          see K_PATH_RESOLVE's own comment on that case; there's no
;          real directory entry describing the root itself)
K_STAT:         equ     $0169       ; -> file_stat

; BPBBLK_*/BPB_DATA_PTR: restated from kernel.inc (not #included, per
; the note above) for krnboot's own relocated bpb_init body, which
; reaches these 11 kernel-resident fields (part1_lba through
; fat_csec, 23 bytes, always contiguous -- see kernel.inc's own
; header comment on this block for the full reasoning) via a fixed
; pointer instead of a normal relocatable symbol, since krnboot.asm is
; linked completely separately from kernel.bin. BPB_DATA_PTR's own
; VALUE (the block's real address) is populated at kernel *link* time,
; not by krnboot -- krnboot only ever reads it. This is a DATA slot,
; not a call target (2 bytes, not a 3-byte lbr), sitting at the jump
; table's own tail by design -- the next real K_* call slot starts
; 2 bytes later than it otherwise would.
BPBBLK_PART1_LBA:  equ  0          ; 3 bytes
BPBBLK_FAT_LBA:    equ  3          ; 3 bytes
BPBBLK_ROOT_LBA:   equ  6          ; 3 bytes
BPBBLK_DATA_LBA:   equ  9          ; 3 bytes
BPBBLK_SPC:        equ  12         ; 1 byte
BPBBLK_SPC_SHIFT:  equ  13         ; 1 byte
BPBBLK_ROOT_ENTS:  equ  14         ; 2 bytes
BPBBLK_NUM_FATS:   equ  16         ; 1 byte
BPBBLK_SPF:        equ  17         ; 2 bytes
BPBBLK_MAX_CLUST:  equ  19         ; 2 bytes
BPBBLK_FAT_CSEC:   equ  21         ; 2 bytes
BPBBLK_LEN:        equ  23         ; total block size

BPB_DATA_PTR:      equ  $016C      ; 2-byte pointer to the block's
                                    ; start (part1_lba's real address)

; DRIVE_DATA_PTR: same mechanism as BPB_DATA_PTR above, for the
; multi-partition boot-time scan (2026-07-13). Points at
; drive_present[0..DRIVE_COUNT-1] (1 byte each, presence flags)
; immediately followed by drive_bpb_table[0..DRIVE_COUNT-1]
; (BPBBLK_LEN bytes each, contiguous, same "point at the block's
; start" convention) -- krnboot's own relocated partition-scan loop
; writes both regions through this one pointer, one drive at a time.
; Its reach extends 6 more bytes past drive_bpb_table (still
; contiguous) to shell_drive/shell_elba/shell_eoff -- boot-discovered
; facts in the same spirit as drive_present, populated once by
; K_SHELL_INIT (see below) rather than the partition-scan loop itself,
; but reusing this same pointer rather than adding a second one. Does
; NOT reach drive_cur_dir/cur_drive/active_bpb_drive -- those are
; session state, not boot-time facts, and are initialized by
; kernel_init instead (see kernel.asm).
DRIVE_COUNT:       equ  4          ; C:, D:, E:, F:
DRIVE_DATA_PTR:    equ  $016E      ; 2-byte pointer to drive_present's
                                    ; real address
DRIVE_PRESENT_LEN: equ  DRIVE_COUNT            ; 4 bytes
DRIVE_BPB_TABLE_OFF: equ DRIVE_COUNT           ; drive_bpb_table starts
                                                ; this many bytes after
                                                ; DRIVE_DATA_PTR's target
SHELL_DATA_OFF: equ     DRIVE_COUNT + DRIVE_COUNT*BPBBLK_LEN
                                                ; shell_drive (then
                                                ; shell_elba, then
                                                ; shell_eoff) starts
                                                ; this many bytes after
                                                ; DRIVE_DATA_PTR's target

; K_BATCH_START/K_BATCH_READLINE: minimal flat (non-nested) batch
; script execution (2026-07-14). The shell (progs/shell.asm) is
; reloaded fresh from disk every command cycle, so it has no memory of
; its own that survives from one line to the next -- these two calls
; let the KERNEL hold that state instead (a dedicated FCB+I/O buffer,
; the same reason cur_dir/cur_drive live in the kernel too), giving
; the shell a trivial contract: call K_BATCH_READLINE once at the top
; of every cycle; DF=0 means a batch line is ready in LINE_BUF (use it
; instead of prompting the console), DF=1 means read from the console
; as normal (no batch active, or one just ended).
;
; K_BATCH_START: begin executing a batch script.
; Args:    RF = pointer to a null-terminated path, already resolved
;          (and confirmed to exist) by the caller -- see
;          progs/shell.asm's own K_STAT-based existence check.
; Returns: DF = 0 on success, DF = 1 if a batch is already active
;          (nesting isn't supported) or the file couldn't be opened.
;
; K_BATCH_READLINE: fetch the next line of the active batch script.
; Args:    none
; Returns: DF = 0 with LINE_BUF holding the next line (null-terminated,
;          CR/LF stripped) if a line was available; DF = 1 if no batch
;          is active, or the batch just reached EOF (auto-closed, so
;          the very next call also returns DF=1 until a new
;          K_BATCH_START).
K_BATCH_START:      equ     $0170       ; -> batch_start
K_BATCH_READLINE:   equ     $0173       ; -> batch_readline

; Raw FAT16 VBR/BPB and MBR partition-table field offsets, restated
; from kernel.inc for the same reason as BPBBLK_*/BPB_DATA_PTR above --
; krnboot's own relocated bpb_init body needs these to parse the raw
; MBR/VBR sector bytes it reads directly (kernel.inc's own copy, used
; by every other BPB/FAT-adjacent kernel file, is unaffected).
BPB_SPC:        equ     $0D         ; sectors per cluster (byte)
BPB_RSVD:       equ     $0E         ; reserved sector count (word)
BPB_NFAT:       equ     $10         ; number of FATs (byte)
BPB_ROOTENT:    equ     $11         ; root directory entry count (word)
BPB_SPF:        equ     $16         ; sectors per FAT (word)
PT_OFFSET:      equ     $01BE       ; partition table entry 0 (drive C)
                                    ; offset within the MBR
PT_ENTRY_LEN:   equ     16          ; bytes between successive MBR
                                    ; partition-table entries -- entry i
                                    ; (drive C+i) starts at
                                    ; PT_OFFSET + i*PT_ENTRY_LEN
PT_LBA_OFF:     equ     8           ; LBA start within entry (4 bytes, LE)

; next free jump-table slot address: $0176
