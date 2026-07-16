# ELF-DOS

A FAT16, DOS-like operating system for the RCA CDP1802 processor, targeting
Elf/OS-compatible hardware. It boots from an SD card via an MBR partition
table (up to 4 FAT16 partitions, addressable as drive letters `C:`-`F:`),
brings up a small resident kernel, and hands off to a command shell where
every command — `DIR`, `CD`, `TYPE`, `COPY`, ... — is an ordinary loadable
executable, not a built-in.

## Status

Actively in development. Currently working, confirmed on real hardware
unless noted otherwise.

### Boot and filesystem

- Boot chain: MBR -> `krnboot` -> kernel init, scanning up to 4 FAT16
  partitions on the boot device and making each one addressable as a drive
  letter (`C:`-`F:`). Current-directory state is tracked per drive (classic
  DOS semantics — `CD D:\games` while `C:` is active updates `D:`'s own
  remembered directory without switching to it).
- FAT16 directory listing, including long file names (LFN).
- File open/read/close/write, including creating a brand-new file (with
  full LFN generation for names that aren't already clean 8.3 short names),
  overwrite, and append mode — growing a file's cluster chain across
  multiple clusters and rewriting its directory entry's size/cluster fields
  on close.
- Multi-component, absolute, and cross-drive paths (e.g. `TYPE /cfg/env.dat`,
  `TYPE D:/cfg/env.dat`), resolved centrally by `K_PATH_RESOLVE`
  (`kernel/path.asm`).
- Last-write file timestamps: every create/write records the current time
  (from the RTC when present, a fixed default otherwise), shown by `DIR`/
  `STAT` as an `MM/DD/YYYY HH:MM` column.

### Shell

- **Zero built-in commands.** Every command is a standalone executable in
  `/bin` (bare-named, no extension); the shell itself is an ordinary
  loadable program (`/bin/shell`), not kernel-resident code — the kernel
  just runs a small, permanently-resident loop that alternately loads and
  runs the shell (which reads one command line, resolves it, and returns)
  and whatever it resolved.
- **Executable search**: a bare command name is looked up in the active
  drive's own `/bin`, falling back to the boot drive's `/bin` if not found
  there (so other drives don't each need their own copy of every command);
  a name containing `/` is loaded directly as a full path.
- **Command-line parsing**: the shell tokenizes each line into an
  argc/argv pair (matching C's `main(argc, argv)` convention) before
  handing off to a program, with shell-style quoting (`"..."` keeps
  embedded spaces in one argument) and backslash-escaping (`\X` for a
  literal `X`, e.g. `\"`, `\\`, or `\ ` for a literal space outside quotes).
- **Batch scripts**: a resolved command path ending in `.bat` runs as a
  flat (non-nested) batch script — each line executed and echoed in turn,
  same as typing it interactively.
- A bare drive letter (`C:`, `D:`, ...) switches the active drive — the one
  narrow exception to "no built-in commands," since it's shell syntax, not
  a program.

### Commands

| Command | Description |
|---|---|
| `DIR [path]` | List a directory (defaults to current) |
| `CD <path>` | Change the current directory (per-drive) |
| `PWD` | Print the current directory's full path |
| `TYPE <file>` | Print a file's contents |
| `MORE <file>` | Page through a file's contents, screen at a time |
| `HEXDUMP <file>` | `hexdump -C`-style hex/ASCII dump of a file |
| `COPY <src> <dst>` | Copy a file (into a directory, or with overwrite prompt) |
| `DEL <file>` | Delete a file |
| `REN <path> <newname>` | Rename a file or directory |
| `MD <path>` / `RD <path>` | Create / remove an empty subdirectory |
| `STAT <path>` | Show a file or directory's metadata |
| `EDLIN <file>` | Minimal `edlin`-style line editor (`L`/`I`/`A`/`D`/`E`/`Q`) |
| `ARGS [args...]` | Print argv, one entry per line (tokenizer test aid) |
| `ECHO [-n] [args...]` | Print arguments, space-separated |
| `MR` / `MS [-u\|-b] <file>` | Receive / send a file over the serial port |
| `SYS <kernel-full.bin>` | Install a new kernel from the running system |
| `MON` | Drop into the ROM monitor |
| `VER` | Print the ELF-DOS version |
| `REBOOT` | Warm-reboot (reloads MBR/krnboot/kernel from disk) |

`WTEST`/`ATEST`/`WBTEST` are internal regression-test tools (write/append/
large-write exercise) rather than everyday commands, but build and install
the same as everything else in `progs/`.

### Not yet supported

See `CLAUDE.md` for the fuller running notes and roadmap.

- I/O redirection (`>`, `>>`, `<`).
- Enhanced batch scripting (argument substitution, comments, labels/`GOTO`).
- Command history (needs a raw-input replacement for the console's
  line-read routine to handle arrow-key escape sequences).
- Filename wildcards.
- `SETTIME`/`SETDATE` to set/correct the clock.
- More shell utilities (`MEM`, `ATTRIB`, etc).

## Architecture

- **Kernel API jump table** at a fixed address (`$0106`), one 3-byte `lbr`
  per call. Slots are append-only pre-release convention going forward
  (the table underwent one deliberate full renumbering before any external
  code depended on it — see `CLAUDE.md`), so a program built against an
  older kernel keeps working after the kernel is rebuilt. Programs include
  `include/kernel_api.inc`, which restates just the constants they need
  (call addresses, program header layout, directory-entry layout) rather
  than sharing the kernel's own internal headers — program code never
  depends on kernel internals that could change across updates.
- **Command-line ABI**: a program receives `RA` = pointer to its argv table
  and `RC` = argc at entry (`argv[0]` is its own invocation name). Both are
  register-passed rather than a fixed address a program's own code would
  have to reference by name, so the kernel is free to relocate the
  underlying storage in a future rebuild without breaking already-built
  programs.
- **Program binaries** are a small custom format: `'EDF'` magic + version
  byte + 2 reserved bytes, then code. Programs load at a fixed `PROG_BASE`
  above the kernel's own memory (chosen to double as the boot loader's own
  load address, since that sector is dead once boot completes).
- **Batch script state lives in the kernel**, not the shell: the shell is
  reloaded from disk on every single command cycle and has no memory of
  its own between lines, so "which file, how far in" is tracked in a
  small kernel-resident FCB instead.
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
            RTC/timestamps, program loader, batch-script execution
include/    Shared headers: BIOS calls, kernel-internal structures,
            the kernel API jump-table contract, opcode macros
progs/      Shell command programs (DIR, CD, TYPE, COPY, EDLIN, ...),
            including the shell itself (shell.asm, run as /bin/shell)
sys/        Host-side tool for writing images to a target device
```

## Building

Requires the Asm/02 assembler (`asm02`) and Link/02 linker (`link02`) on
`PATH`.

```
make            # build kernel-full.bin (bootstrap + kernel)
make progs      # build every progs/*.asm into bin/<name> (bare, no
                # extension -- mirrors the on-device /bin layout)
make clean      # remove all generated build artifacts
```

`make progs` auto-discovers new files under `progs/` — add a `.asm` file
there and it's picked up on the next build.

## Installing / testing

There is no emulator or local hardware access in the development
environment. All real testing happens by writing the built image to an SD
card and running it on physical Elf/OS-compatible hardware:

```
make install DEV=/dev/sdX   # write MBR + kernel (new/blank disk)
make update DEV=/dev/sdX    # refresh kernel only (MBR already installed)
```

`bin/` (built via `make progs`) isn't installed by the Makefile — copy its
whole contents onto the FAT16 partition's `/bin` yourself (e.g. with
`mtools`'s `mcopy`). Every file in `bin/` is already bare-named (no
extension), matching the on-device layout exactly, so the directory can
be copied wholesale rather than file-by-file — e.g.
`mcopy -i /dev/sdX@@1M bin/* ::BIN/`. This includes the shell itself
(`bin/shell`), which the kernel loads by the exact path `/bin/shell` at
boot. A kernel already installed can also be updated from the *running*
system itself via `MR` (receive `kernel-full.bin` over serial) + `SYS`
(install it) + `REBOOT`, with no card swap needed.
