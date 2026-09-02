# ELF-DOS

A FAT16, DOS-like operating system for the RCA CDP1802 processor, targeting
Elf/OS-compatible hardware. It boots from an SD card via an MBR partition
table (up to 4 FAT16 partitions, addressable as drive letters `C:`-`F:`),
brings up a small resident kernel, and hands off to a command shell where
every command - `DIR`, `CD`, `TYPE`, `COPY`, ... - is an ordinary loadable
executable, not a built-in.

## Status

Actively in development. Currently working, confirmed on real hardware
unless noted otherwise. For full day-to-day usage and program-development
documentation, see `docs/USER_GUIDE.md` and `docs/DEVELOPER_GUIDE.md`
(PDF versions of both are also included). `CLAUDE.md` carries the full,
dated project history, architectural rationale, and toolchain gotchas
behind everything summarized here.

### Boot and filesystem

- Boot chain: MBR -> `krnboot` -> kernel init, scanning up to 4 FAT16
  partitions on the boot device and making each one addressable as a drive
  letter (`C:`-`F:`). Current-directory state is tracked per drive (classic
  DOS semantics - `CD D:\games` while `C:` is active updates `D:`'s own
  remembered directory without switching to it).
- FAT16 directory listing, including long file names (LFN) and Windows'
  own NTRes-hint case-folding convention for clean 8.3 names.
- File open/read/close/write/seek, including creating a brand-new file
  (with full LFN generation for names that aren't already clean 8.3 short
  names, including collision-avoidance for names that truncate to the
  same short name), overwrite, and append mode - growing a file's cluster
  chain across multiple clusters and rewriting its directory entry's
  size/cluster fields on close.
- Multi-component, absolute, and cross-drive paths (e.g. `TYPE /cfg/env.dat`,
  `TYPE D:/cfg/env.dat`), resolved centrally by `K_PATH_RESOLVE`
  (`kernel/path.asm`).
- Filename wildcards (`*`/`?`), expanded independently by each
  wildcard-aware command (`COPY`, `DEL`, `MOVE`, `ATTRIB`, `DIR`, `LS`,
  `YS`) via a shared library, not by the shell itself.
- Last-write file timestamps: every create/write records the current time
  (from the RTC when present, a fixed default otherwise), shown by `DIR`/
  `STAT` as an `MM/DD/YYYY HH:MM` column.
- `CHKDSK` for filesystem consistency checking (lost/cross-linked/
  invalid clusters, size/chain-length mismatches, duplicate short names,
  orphaned LFN entries) - check-only for now, no automatic repair yet.

### Shell

- **Zero built-in commands.** Every command is a standalone executable in
  `/bin` (bare-named, no extension); the shell itself is an ordinary
  loadable program (`/bin/shell`), not kernel-resident code - the kernel
  just runs a small, permanently-resident loop that alternately loads and
  runs the shell (which reads one command line, resolves it, and returns)
  and whatever it resolved.
- **Executable search**: a bare command name is looked up in the active
  drive's own `/bin`, falling back to the boot drive's `/bin` if not found
  there (so other drives don't each need their own copy of every command);
  a name containing `/` is loaded directly as a full path.
- **Command-line editing**: arrow keys (Up/Down for command history, Left/
  Right to move within the current line), Emacs/readline-style Ctrl
  shortcuts (Ctrl-A/E home/end, Ctrl-B/F left/right, Ctrl-D/H delete), and
  the Delete key, all backed by a real cursor position and in-place
  insert/delete - not just append-and-backspace.
- **Command-line parsing**: the shell tokenizes each line into an
  argc/argv pair (matching C's `main(argc, argv)` convention) before
  handing off to a program, with shell-style quoting (`"..."` and `'...'`
  both keep embedded spaces in one argument, with `"..."` additionally
  processing backslash-escapes) and backslash-escaping (`\X` for a
  literal `X`, e.g. `\"`, `\\`, or `\ ` for a literal space outside quotes).
- **I/O redirection**: `>`/`>>` for output (truncate/append), `<` for
  input, plus a `NUL` pseudo-device (`>NUL` discards output, `<NUL` is an
  immediate empty input) - works inside batch scripts too, since it's
  handled by the same tokenizing pass.
- **Environment variables**: `EXPORT`/`UNSET`/`PRINTENV` manage a simple
  `NAME=VALUE` store; `$VAR`/`${VAR}` expand inline on
  any command line (single-quoted text is left fully literal, matching
  bash).
- **Batch scripts**: a resolved command path ending in `.bat` runs as a
  flat (non-nested - a batch file naming another `.bat` file is rejected)
  script. Supports `REM`/blank-line comments, `@ECHO OFF`/`ECHO ON` (and
  a bare `ECHO` for status), `%0`-`%9` argument substitution,
  `%ERRORLEVEL%` (also readable via the standalone `ERRORLEVEL` command),
  and `IF [NOT] EXIST <path> <command>` / `IF [NOT] <str1>==<str2>
  <command>` / `GOTO <label>` for simple conditional flow.
- A bare drive letter (`C:`, `D:`, ...) switches the active drive - the one
  narrow exception to "no built-in commands," since it's shell syntax, not
  a program.

### Commands

| Command | Description |
|---|---|
| `DIR [path\|pattern...]` | List a directory (or several), with volume/path header |
| `LS [-laF] [path...]` | Linux-`ls`-style listing (columnar, or long format) |
| `CD <path>` | Change the current directory (per-drive) |
| `PWD` | Print the current directory's full path |
| `TYPE <file>` | Print a file's contents |
| `LESS <file>` | Page through a file's contents, forward and backward, by screen or line, with search |
| `HEXDUMP <file>` | `hexdump -C`-style hex/ASCII dump of a file |
| `COPY [-y] <src> <dst>` | Copy file(s); into a directory, wildcards, overwrite prompt |
| `MOVE <src> <dst>` | Move/rename file(s) (fast rename when possible) |
| `XCOPY [switches] <src> <dst>` | Recursive directory copy (`-s`/`-e`/`-y`/`-d`/`-c`/`-v`/`-h`) |
| `DEL <file...>` | Delete file(s) (wildcards supported) |
| `REN <path> <newname>` | Rename a file or directory |
| `MD <path>` / `RD <path>` | Create / remove an empty subdirectory |
| `STAT <path>` | Show a file or directory's metadata |
| `TOUCH <file...>` | Update a file's last-write time to now |
| `ATTRIB [+H\|-H] <path...>` | Show or set the hidden attribute |
| `LABEL [drive:] [text\|-d]` | Show, set, or clear a volume label |
| `CHKDSK [drive:]` | Check a volume for filesystem consistency errors |
| `EDLIN <file>` | `edlin`-style line editor (list/insert/delete/search/replace/move/copy) |
| `DATE [MM/DD/YYYY]` | Show or set the system date |
| `TIME [HH:MM[:SS]]` | Show or set the system time |
| `ERRORLEVEL` | Print the previous command's exit code |
| `EXPORT [name[=value]...]` | Set (or list) environment variables |
| `UNSET <name...>` | Remove environment variables |
| `PRINTENV [name...]` | Print environment variables |
| `ARGS [args...]` | Print argv, one entry per line (tokenizer test aid) |
| `ECHO [-n] [args...]` | Print arguments, space-separated |
| `MR` / `MS [-u\|-b] <file>` | Receive / send a single file over serial (XMODEM) |
| `YR` / `YS [switches] <file...>` | Receive / send file(s) via YMODEM-CRC batch transfer |
| `SYS <kernel-full.bin>` | Install a new kernel from the running system |
| `BAUD <rate>` | Set the console's baud rate |
| `CLS` | Clear the screen |
| `MON` | Drop into the ROM monitor |
| `VER` | Print the ELF-DOS version |
| `REBOOT` | Warm-reboot (reloads MBR/krnboot/kernel from disk) |

`YR`/`YS` are currently known to be broken (build-verified only, not yet
working on real hardware) - see `CLAUDE.md`'s roadmap notes.

`test/` holds internal regression-test tools (file write/append/seek
exercises, the heap allocator libraries, a deliberate-corruption injector
for exercising `CHKDSK`, etc.) rather than everyday commands - they build
into `test/bin/` via `make test`, kept separate from the real `/bin` set.

### Not yet supported

See `CLAUDE.md` for the fuller running notes and roadmap.

- `CHKDSK -f` (automatic repair) - check-only for now.
- Nested batch scripts (a `.bat` calling another `.bat`).
- An executable-permission bit - attempted and hardware-tested, but the
  user judged it not worth the added complexity in practice; the work is
  preserved on the (unmerged) `exe_flag` branch.
- Further DOS-style file attributes beyond hidden (`ATTRIB` only toggles
  `+H`/`-H` today).

## Architecture

- **Kernel API jump table** at a fixed address (`$0106`), one 3-byte `lbr`
  per call. Slots are append-only pre-release convention going forward
  (the table underwent one deliberate full renumbering before any external
  code depended on it - see `CLAUDE.md`), so a program built against an
  older kernel keeps working after the kernel is rebuilt. Programs include
  `include/kernel_api.inc`, which restates just the constants they need
  (call addresses, program header layout, directory-entry layout) rather
  than sharing the kernel's own internal headers - program code never
  depends on kernel internals that could change across updates. The
  register-level contract for every call is documented in
  `docs/DEVELOPER_GUIDE.md`'s Kernel API Reference.
- **Command-line ABI**: a program receives `RA` = pointer to its argv table
  and `RC` = argc at entry (`argv[0]` is its own invocation name). Both are
  register-passed rather than a fixed address a program's own code would
  have to reference by name, so the kernel is free to relocate the
  underlying storage in a future rebuild without breaking already-built
  programs.
- **Program binaries** are a small custom format: `'EDF'` magic + version
  byte + 2 reserved bytes, then code. Programs load at a fixed `PROG_BASE`
  (`$4300`), kept intentionally below `KERN_LOAD` for extra kernel-resident
  headroom rather than merged with it.
- **Batch-script support (tracking which line of a `.bat` file runs next,
  etc.) lives in a small, dynamically-loaded kernel module**
  (`/bin/batch.mod`), reserved into high memory only while a script is
  actually running, rather than staying permanently kernel-resident -
  freeing that space back for ordinary program use the rest of the time.
- **A general-purpose himem reservation mechanism** (`K_HIMEM_RESERVE`/
  `K_HIMEM_RELEASE`) backs the batch module, I/O redirection needing a
  second simultaneously-open file, and wildcard expansion, all sharing one
  proven, nesting-safe design.
- **Two general-purpose userland heap allocators** (`lib/heap_bump.asm`,
  a scoped bump/arena allocator, and `lib/heap_malloc.asm`, a real
  `malloc`/`free` with coalescing) are available to any program that links
  against them, alongside smaller shared libraries for formatting,
  environment-variable access, path display, and file globbing
  (`lib/fmt32.asm`, `lib/env.asm`, `lib/pathstr.asm`, `lib/file_glob.asm`).
- **Multi-partition support**: up to 4 drives, each with its own BPB/FAT
  cache, swapped in on demand (`_switch_drive`, `kernel/fat.asm`) whenever
  a path names a different drive than the one currently active.

See `CLAUDE.md` for the full architectural contract, toolchain gotchas
specific to Asm/02 1802 assembly, and the conventions for working in this
codebase.

## Repository layout

```
boot/       MBR and second-stage boot loader (krnboot)
kernel/     Kernel proper: BPB/partition init, FAT, directory, file I/O,
            RTC/timestamps, program loader, batch-script module loader,
            I/O redirection
include/    Shared headers: BIOS calls, kernel-internal structures,
            the kernel API jump-table contract, opcode macros
progs/      Shell command programs (DIR, CD, TYPE, COPY, EDLIN, ...),
            including the shell itself (shell.asm, run as /bin/shell)
lib/        Shared userland libraries (heap allocators, file globbing,
            environment variables, 32-bit number formatting, ...),
            linked into whichever progs/*.asm need them
test/       Internal regression-test / diagnostic tools, built separately
            from progs/ into test/bin/
docs/       User's Guide and Developer's Guide (Markdown + PDF)
sys/        Host-side tool for writing images to a target device
```

## Building

Requires the Asm/02 assembler (`asm02`) and Link/02 linker (`link02`) on
`PATH`. Builds cleanly from the same source on Linux (`Makefile`, GNU
Make) and Windows (`Makefile.win`, `nmake` - see its own header comment
for prerequisites).

```
make            # build kernel-full.bin (bootstrap + kernel)
make progs      # build every progs/*.asm into bin/<name> (bare, no
                # extension -- mirrors the on-device /bin layout)
make test       # build every test/*.asm into test/bin/<name>
make clean      # remove all generated build artifacts
```

`make progs`/`make test` auto-discover new files under `progs/`/`test/`
(GNU Make only - `nmake` has no wildcard support, so `Makefile.win` lists
program targets explicitly and needs a new one added by hand).

## Installing / testing

There is no emulator in the development environment. All real testing
happens by writing the built image to an SD card and running it on
physical Elf/OS-compatible hardware:

```
make install DEV=/dev/mmcblkx      # write MBR + kernel (new/blank disk)
make update DEV=/dev/mmcblkx       # refresh kernel only (MBR already installed)
```

On Windows, use `nmake /F Makefile.win install DEV=\\.\PhysicalDriveN` /
`update` instead (no default `DEV` value there - a wrong physical drive
number destroys data irrecoverably, so it's required explicitly every
time).

`bin/` (built via `make progs`) isn't installed by the Makefile - copy its
whole contents onto the FAT16 partition's `/bin` yourself (e.g. with
`mtools`'s `mcopy`). Every file in `bin/` is already bare-named (no
extension), matching the on-device layout exactly, so the directory can
be copied wholesale rather than file-by-file - e.g.
`mcopy -i /dev/sdX@@1M bin/* ::BIN/`. This includes the shell itself
(`bin/shell`) and the batch module (`bin/batch.mod`), which the kernel
loads by their exact `/bin/` paths. A kernel already installed can also
be updated from the *running* system itself via `MR` (receive
`kernel-full.bin` over serial) + `SYS` (install it) + `REBOOT`, with no
card swap needed.
