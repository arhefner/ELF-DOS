;
; kernel.inc - ELF-DOS kernel shared definitions
;
; Include in every kernel source file with:
;   #include include/kernel.inc
;

; ----------------------------------------------------------------
; Memory layout
; ----------------------------------------------------------------
; Moved $2000 -> $3000 -> $4000 -> $3E00 over time as the kernel has
; grown (and, for this last move, shrunk). The first move (to $3000)
; was forced reactively: the kernel had already grown past $2000 (to
; $2073) and was silently corrupting its own tail on every prog_load --
; confirmed as the cause of "DIR"/etc. crashing partway through on a
; freshly-formatted test card. The second move (to $4000) was
; preemptive, made right after adding file creation/append/LFN-writing
; support pushed the kernel from $2245 to $2a27 in one session.
;
; The move to $3E00 (2026-07-10) is different in kind: it's not a
; growth response, it's reclaiming dead space. PROG_BASE used to sit
; exactly one 512-byte sector above KERN_LOAD (boot/mbr.asm) --
; krnboot's own load address -- leaving krnboot's sector ($3E00-$3FFF)
; permanently unused by anything once boot completes (krnboot's own
; header comment confirms this: "this code is only needed once and is
; never called again after the jump to $0106"). Nothing in the kernel
; or any program ever jumps back into that sector, so PROG_BASE can
; simply BE KERN_LOAD now -- the first program load of any session
; (the initial /bin/shell load in kernel_init's run_loop) overwrites
; krnboot's dead bytes with real program code, for free. This also
; collapses what used to be two separately-tracked boundaries (the
; PROG_BASE margin and the KERN_LOAD margin) into a single address --
; one fewer thing to check after future kernel growth, not just fewer
; wasted bytes. If KERN_LOAD ever moves again (see boot/mbr.asm), this
; must move with it, and vice versa; they are the same address by
; design now, not by coincidence.
;
; Check the kernel's actual "Highest address" from a build against
; this any time the kernel grows substantially, and move both PROG_BASE
; and KERN_LOAD together (keeping kernel_api.inc's copy of PROG_BASE
; and boot/mbr.asm's/boot/krnboot.asm's copies of KERN_LOAD/KERN_ENTRY
; all in sync) well before it gets close. Note this trades directly
; against RAM available to programs (mem_base..mem_top).
PROG_BASE:      equ     $3E00       ; user programs load here; == KERN_LOAD
                                    ; (boot/mbr.asm) by design, see above

; $0080-$00FF: the ROM's small boot-time stack lives here (see
; boot/mbr.asm) but is dead once the kernel sets up its own stack at
; himem during boot, so it's free scratch RAM for the kernel's own
; use afterward. Used for the shell's line buffer instead of
; reserving 128 bytes in the kernel's own data area.
;
; NOW ALSO restated in kernel_api.inc (as of the shell-as-a-program
; move): the shell used to be kernel-internal code with direct access
; to this via #include, but it's now progs/shell.asm, a separately
; assembled program -- it still needs to read/write LINE_BUF directly
; (f_inputl into it, tokenizing the command line in place), so this is
; no longer purely kernel-only.
LINE_BUF:       equ     $0080       ; shell command input buffer (128 bytes)

; Fixed, well-known address for the loader to pass mem_base/mem_top to
; a loaded program: word 0 = mem_base, word 1 = mem_top. Fixed (rather
; than the kernel's own mem_base/mem_top symbols) so a separately
; assembled program can read it without knowing the kernel's layout,
; which shifts across builds. Consulted anytime during a program's
; run (e.g. by a heap allocator), unlike the command line below,
; which is only needed once at entry -- so it's passed in a register
; instead (RA at program entry; see include/kernel_api.inc).
;
; NOTE: PROG_BASE and LOADER_ARGS are restated (not #included) in
; kernel_api.inc, which is deliberately kept independent of this
; file's internal kernel structures -- keep both definitions in sync
; if this ever changes.
LOADER_ARGS:    equ     PROG_BASE-4

; RUN_ARGC/RUN_ARGV_TABLE/RUN_PATH: the shell-as-a-program handoff
; protocol. The kernel can't let the shell load and run a child command
; itself -- the shell runs FROM PROG_BASE, so loading a child there
; would overwrite the shell's own currently-executing code before the
; child's own "rtn" could ever return into it (the same reason the
; collapsed prog_run/prog_run_shell, kernel/loader.asm, have no
; jump-table slot at all -- nothing could ever call them safely except
; the kernel's own run_loop). Instead, the shell's only job each round
; is: read a command line, tokenize it (quoting/escapes-aware -- see
; progs/shell.asm), resolve argv[0] to a path AND CONFIRM IT EXISTS
; (bare name -> "/bin/"+name on the active drive, falling back to the
; shell's own drive if not found there; a name containing '/' -> used
; as-is, checked once, no fallback), write that path + the argument
; count + the argument table here, and return normally -- the KERNEL's
; own small run_loop (kernel_init, see kernel.asm) is what actually
; calls prog_run for the real command, staying safely in kernel memory
; throughout. Fixed addresses, not normal linked symbols, for the same
; reason LOADER_ARGS is fixed: progs/shell.asm is assembled and linked
; completely separately from the kernel and needs an address stable
; across kernel rebuilds.
;
; IMPORTANT: these three are kernel/shell-internal plumbing ONLY.
; Ordinary programs never reference RUN_ARGC/RUN_ARGV_TABLE/RUN_PATH by
; name -- they only ever see the RA (argv pointer)/RC (argc) register
; values built from them at entry (see the "Command line" section
; below). This is deliberate: a fixed address baked into a program's
; own compiled code breaks every already-deployed copy of that program
; the moment the address ever needs to move (this project has been
; burned by that twice already -- see the toolchain-gotchas history in
; /CLAUDE.md for the PROG_BASE moves and the kernel jump-table
; renumber). Routing argc/argv through registers instead means a
; future kernel rebuild can freely relocate any of these three without
; requiring a single program to be rebuilt.
RUN_ARGC:       equ     PROG_BASE-6     ; word: argument count (argv[0]
                                        ; is the program name, so this
                                        ; is always >= 1 on success)
RUN_ARGV_TABLE: equ     PROG_BASE-38    ; ARGV_MAX_ARGS 2-byte pointers,
                                        ; argv[0..argc-1], each pointing
                                        ; to a null-terminated token
                                        ; inside LINE_BUF
ARGV_MAX_ARGS:  equ     16              ; RUN_ARGV_TABLE's own capacity,
                                        ; for bounds-checking writes to it
RUN_PATH:       equ     PROG_BASE-102   ; 64-byte buffer: resolved path
                                        ; to load next
RUN_PATH_LEN:   equ     64              ; RUN_PATH's own size, for
                                        ; bounds-checking writes to it

; RUN_REDIR_OUT/RUN_REDIR_OUT_APPEND/RUN_REDIR_IN: I/O redirection relay,
; same mechanism and reasoning as RUN_ARGC/RUN_ARGV_TABLE/RUN_PATH above
; (kernel/shell-internal only, never referenced by ordinary programs).
; Unlike RUN_PATH, these are NOT copied buffers -- each is just a pointer
; into LINE_BUF at the (already tokenized, NUL-terminated) redirect
; target filename, same "raw pointer into the shell's own scratch, valid
; until the next line is read" convention every argv[N] entry already
; relies on. 0 means "no redirect of that kind." Set by progs/shell.asm's
; tokenizer when it recognizes a `>`/`>>`/`<` operator instead of an
; ordinary token; read by kernel_init's run_loop (kernel/kernel.asm),
; which opens/closes the real files around the child's run (see
; kernel/redir.asm).
RUN_REDIR_OUT:      equ     PROG_BASE-105   ; word: 0 = no output
                                            ; redirect, else -> filename
RUN_REDIR_OUT_APPEND: equ   PROG_BASE-106   ; byte: 0 = truncate (`>`),
                                            ; 1 = append (`>>`) --
                                            ; meaningless if
                                            ; RUN_REDIR_OUT is 0
RUN_REDIR_IN:       equ     PROG_BASE-108   ; word: 0 = no input
                                            ; redirect, else -> filename

; ----------------------------------------------------------------
; Disk geometry
; ----------------------------------------------------------------
SECTOR_SIZE:    equ     $0200       ; 512 bytes per sector

; ----------------------------------------------------------------
; FAT16 cluster values
; ----------------------------------------------------------------
FAT_FREE:       equ     $0000       ; cluster is free
FAT_BAD:        equ     $FFF7       ; bad cluster marker
FAT_EOC:        equ     $FFF8       ; end-of-chain threshold (>= means EOC)

; ----------------------------------------------------------------
; FAT16 VBR / BPB field offsets
; All multi-byte BPB fields are little-endian on disk.
; ----------------------------------------------------------------
BPB_SPC:        equ     $0D         ; sectors per cluster (byte)
BPB_RSVD:       equ     $0E         ; reserved sector count (word)
BPB_NFAT:       equ     $10         ; number of FATs (byte)
BPB_ROOTENT:    equ     $11         ; root directory entry count (word)
BPB_SPF:        equ     $16         ; sectors per FAT (word)

; ----------------------------------------------------------------
; MBR partition table
; ----------------------------------------------------------------
PT_OFFSET:      equ     $01BE       ; partition table offset within MBR
PT_ENT_LEN:     equ     16          ; bytes per partition entry
PT_LBA_OFF:     equ     8           ; LBA start within entry (4 bytes, LE)

; ----------------------------------------------------------------
; LBA storage format (3 bytes, big-endian)
;
; LBAs are stored in memory as three consecutive bytes:
;   [0] = bits 23-16  -> loads into R8.0
;   [1] = bits 15-8   -> loads into R7.1
;   [2] = bits  7-0   -> loads into R7.0
;
; After loading, R8.1 must be set to 0 (drive/head) before
; calling f_ideread or f_idewrite.
;
; To load an LBA from [RF] into R7/R8:
;   lda  rf          ; D = bits 23-16
;   plo  r8          ;   -> R8.0
;   lda  rf          ; D = bits 15-8
;   phi  r7          ;   -> R7.1
;   lda  rf          ; D = bits 7-0
;   plo  r7          ;   -> R7.0
;   ldi  0
;   phi  r8          ; R8.1 = 0 (drive/head)
;
; To add a 16-bit offset (in RD) to an LBA already in R7/R8:
;   add16  r7, rd    ; R7 += RD, DF = carry out
;   glo    r8
;   adci   0         ; R8.0 += carry (ADCI 0 = D + 0 + DF)
;   plo    r8
; ----------------------------------------------------------------
LBA_SIZE:       equ     3           ; bytes per stored LBA

; ----------------------------------------------------------------
; BPB data block offsets -- the 11 fields bpb_init populates, always
; contiguous at the top of kernel.asm's _kernel_data block (part1_lba
; through fat_csec, nothing interleaved). Exists so a fixed pointer to
; the block's start (BPB_DATA_PTR, see kernel_api.inc) plus these
; offsets can reach any individual field without needing a relocatable
; symbol -- the mechanism boot/krnboot.asm's own separately-linked
; bpb_init body needs, since it can't reference kernel.bin's normal
; symbols directly (see kernel_api.inc's own header comment on this).
; Deliberately narrow: does NOT cover fat_dirty or fat_cache (the
; 512-byte MBR/VBR scratch buffer), which come immediately after this
; block in kernel.asm but are not part of it -- krnboot's own relocated
; bpb_init uses a local scratch buffer instead, so the fixed pointer's
; reach stays limited to exactly the fields that need to cross the
; link-unit boundary, not the kernel's wider FCB/directory state.
; ----------------------------------------------------------------
BPBBLK_PART1_LBA:   equ     0           ; 3 bytes
BPBBLK_FAT_LBA:     equ     3           ; 3 bytes
BPBBLK_ROOT_LBA:    equ     6           ; 3 bytes
BPBBLK_DATA_LBA:    equ     9           ; 3 bytes
BPBBLK_SPC:         equ     12          ; 1 byte
BPBBLK_SPC_SHIFT:   equ     13          ; 1 byte
BPBBLK_ROOT_ENTS:   equ     14          ; 2 bytes
BPBBLK_NUM_FATS:    equ     16          ; 1 byte
BPBBLK_SPF:         equ     17          ; 2 bytes
BPBBLK_MAX_CLUST:   equ     19          ; 2 bytes
BPBBLK_FAT_CSEC:    equ     21          ; 2 bytes
BPBBLK_LEN:         equ     23          ; total block size

; DRIVE_COUNT: number of possible drives (C:/D:/E:/F:), i.e. the size
; of drive_present/drive_bpb_table/drive_cur_dir in kernel.asm and the
; bound of boot/krnboot.asm's own partition-scan loop (see
; kernel_api.inc's DRIVE_DATA_PTR comment for the boot-time mechanism).
DRIVE_COUNT:        equ     4

; ----------------------------------------------------------------
; FCB (File Control Block) structure offsets
;
; Each FCB is FCB_LEN bytes. CALLER-ALLOCATED (2026-07-15): the
; kernel no longer maintains a fixed-size table of full FCBs -- the
; caller (a program, or the kernel's own prog_run for its one
; internal need) owns the memory and passes a pointer to file_open.
; Handles stay small integers, exactly as before (needed for the
; future ELFC C library's own low-level I/O convention): file_open
; registers the caller's FCB pointer into a small kernel-resident
; table of just POINTERS (fd_table, FD_COUNT slots, see below) and
; returns the slot index; file_close/file_read/file_write/file_seek
; still take that same index, now resolved via one extra pointer
; dereference instead of a direct fcb_table-relative computation.
; This raises the old hard 3-concurrent-file ceiling to FD_COUNT (8)
; while making the kernel-resident table itself smaller (FD_COUNT*2
; bytes of pointers vs. the old FCB_COUNT*32 bytes of full FCBs).
;
; File size and position are stored as 4-byte big-endian values.
; On this 16K-64K machine the high words will normally be zero,
; but the full 32-bit fields keep the code correct for FAT16.
; ----------------------------------------------------------------
FCB_FLAGS:      equ     0           ; status byte (1 byte)
FCB_SCLUST:     equ     1           ; start cluster (2 bytes)
FCB_CCLUST:     equ     3           ; current cluster (2 bytes)
FCB_CSECT:      equ     5           ; sector index within current cluster (1 byte)
FCB_BOFF:       equ     6           ; byte offset within current sector (2 bytes)
FCB_FSIZE:      equ     8           ; file size in bytes (4 bytes, big-endian)
FCB_FPOS:       equ     12          ; current file position (4 bytes, big-endian)
FCB_ELBA:       equ     16          ; directory entry's sector LBA (3 bytes,
                                    ; big-endian) -- see dir.asm's
                                    ; dir_cur_lba/dir_last_off, populated
                                    ; by file_open from the same values
FCB_EOFF:       equ     19          ; entry's byte offset within that
                                    ; sector (2 bytes, big-endian, 0-511)
FCB_IOBUF:      equ     21          ; pointer (2 bytes) to this FCB's own
                                    ; caller-supplied 512-byte sector
                                    ; buffer -- set by file_open from its
                                    ; RA argument. Replaces the old single
                                    ; shared io_buf/io_owner mechanism:
                                    ; each FCB now has its own buffer, so
                                    ; two FCBs alternating access (e.g.
                                    ; COPY's src read / dst write loop)
                                    ; no longer evict each other's cached
                                    ; sector.
FCB_DRIVE:      equ     23          ; drive index (1 byte, 0=C..3=F) this
                                    ; FCB was opened against -- set by
                                    ; file_open from path_resolve's
                                    ; resolved drive. file_read/write/
                                    ; seek/close each call _switch_drive
                                    ; on this before touching any BPB/FAT
                                    ; state, so two FCBs on different
                                    ; drives can be interleaved correctly
                                    ; (e.g. COPY between drives) -- see
                                    ; fat.asm's _switch_drive.
FCB_LEN:        equ     32          ; total FCB size (21 original bytes +
                                    ; 2 for FCB_IOBUF + 1 for FCB_DRIVE =
                                    ; 24, still comfortably inside the
                                    ; power-of-2 padding to 32 -- no
                                    ; growth needed)

; FCB flag bits
FCB_F_OPEN:     equ     $01         ; slot is in use
FCB_F_WRITE:    equ     $02         ; opened for writing
FCB_F_DIRTY:    equ     $04         ; io_buf holds data not yet written to disk
                                    ; (reserved for a future write-back
                                    ; optimization -- file_write currently
                                    ; writes through immediately instead)
FCB_F_SIZECHG:  equ     $08         ; FCB_FSIZE grew since open; the
                                    ; directory entry's size field needs
                                    ; rewriting at file_close (see FCB_ELBA)
FCB_F_IOVALID:  equ     $10         ; this FCB's own IOBUF currently holds
                                    ; a real, current sector (set after a
                                    ; real disk read; cleared on open,
                                    ; on any cluster/sector wrap, and on
                                    ; seek). Per-FCB replacement for the
                                    ; old global io_owner comparison.

; fd_table: kernel-resident array of FD_COUNT pointers (see
; kernel/kernel.asm) -- file_open registers a caller's FCB pointer
; into a free (zero) slot here and returns the slot index; a real
; FCB's address is never 0, so 0 unambiguously means "free."
FD_COUNT:       equ     8

; ----------------------------------------------------------------
; Path and drive conventions
; ----------------------------------------------------------------
PATH_SEP:       equ     '/'         ; directory separator character
DRIVE_FIRST:    equ     'C'         ; first hard-disk drive letter

; ----------------------------------------------------------------
; Directory entry result buffer (caller-provided, DIRENT_LEN bytes)
; ----------------------------------------------------------------
DIRENT_NAME:    equ     0           ; null-terminated filename (LFN_BUFLEN bytes)
DIRENT_ATTR:    equ     128         ; FAT attribute byte
DIRENT_CLUST:   equ     129         ; first cluster (2 bytes, big-endian)
DIRENT_SIZE:    equ     131         ; file size (4 bytes, big-endian)
DIRENT_WRTTIME: equ     135         ; last-write time (2 bytes, big-endian,
                                    ; packed FAT format -- see DE_WRTTIME)
DIRENT_WRTDATE: equ     137         ; last-write date (2 bytes, big-endian,
                                    ; packed FAT format -- see DE_WRTDATE)
DIRENT_LEN:     equ     139         ; total result buffer size

; ----------------------------------------------------------------
; FAT16 file attribute bits
; ----------------------------------------------------------------
ATTR_RDONLY:    equ     $01
ATTR_HIDDEN:    equ     $02
ATTR_SYSTEM:    equ     $04
ATTR_VOLID:     equ     $08
ATTR_DIR:       equ     $10
ATTR_ARCHIVE:   equ     $20
ATTR_LFN:       equ     $0F         ; combination that marks an LFN entry

; ----------------------------------------------------------------
; Raw 32-byte directory entry field offsets
; ----------------------------------------------------------------
DE_NAME:        equ     0           ; 8.3 name (11 bytes, space-padded)
DE_ATTR:        equ     11          ; attribute byte
DE_WRTTIME:     equ     22          ; last-write time (2 bytes, LE, packed:
                                    ; bits 15-11=hour, 10-5=minute, 4-0=sec/2)
DE_WRTDATE:     equ     24          ; last-write date (2 bytes, LE, packed:
                                    ; bits 15-9=year-1980, 8-5=month, 4-0=day)
DE_CLUSTER:     equ     26          ; first cluster low word (2 bytes, LE)
DE_SIZE:        equ     28          ; file size (4 bytes, LE)

; ----------------------------------------------------------------
; LFN entry field offsets (within the same 32-byte slot)
; ----------------------------------------------------------------
LFN_SEQ:        equ     0           ; sequence number
LFN_NAME1:      equ     1           ; chars 1-5  (10 bytes, UTF-16LE)
LFN_ATTR:       equ     11          ; attribute  (always ATTR_LFN = $0F)
LFN_CHKSUM:     equ     13          ; 8.3 short-name checksum
LFN_NAME2:      equ     14          ; chars 6-11 (12 bytes, UTF-16LE)
LFN_NAME3:      equ     28          ; chars 12-13 (4 bytes, UTF-16LE)

; ----------------------------------------------------------------
; LFN constants
; ----------------------------------------------------------------
LFN_LAST:       equ     $40         ; flag OR'd into seq# of last LFN entry
LFN_CHARS:      equ     13          ; Unicode chars per LFN entry
LFN_BUFLEN:     equ     128         ; max LFN chars we support (incl. null)

; ----------------------------------------------------------------
; Directory layout
; ----------------------------------------------------------------
DIR_ENT_SIZE:       equ     32      ; bytes per directory entry
DIR_ENT_PER_SEC:    equ     16      ; entries per 512-byte sector
