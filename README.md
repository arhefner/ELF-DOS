# ELF-DOS

A FAT16, DOS-like operating system for the RCA CDP1802 processor, targeting
Elf/OS-compatible hardware. It boots from an SD card via an MBR partition
table, brings up a small resident kernel, and hands off to a command shell
where every command — `VER`, `DIR`, `CD`, `TYPE`, ... — is an ordinary
loadable `.EXE`, not a built-in.

## Status

Actively in development. Currently working, confirmed on real hardware:

- Boot chain: MBR -> `krnboot` -> kernel init (BPB/partition parsing).
- FAT16 directory listing, including long file names (LFN).
- File open/read/close/write, including creating a brand-new file (with
  full long file name (LFN) generation for names that aren't already
  clean 8.3 short names) and append mode -- extending or overwriting an
  existing file, growing its cluster chain across multiple clusters via
  `fat_alloc`/`fat_set`/`fat_flush`, and rewriting the directory entry's
  size/cluster fields on close -- confirmed on hardware.
- Multi-component and absolute paths (e.g. `TYPE /cfg/env.dat`), via
  `K_PATH_RESOLVE` (`kernel/path.asm`), used by `file_open`, `CD`, and
  `DIR` (which can now list a directory without changing into it) --
  confirmed on hardware.
- `PWD`: prints the current directory's full path from root, by walking
  up via each level's `..` entry and recovering its own name from its
  parent's listing (the reverse of path resolution).
- A handful of shell utilities: `VER`, `DIR`, `CD`, `TYPE`, `PWD`, plus
  `WTEST`/`ATEST` (write/append-mode test/exercise tools).
- Last-write file timestamps: every file create/write records the current
  time (from the RTC when present, via `kernel/rtc.asm`; a fixed default
  otherwise), and `DIR` shows it as an `MM/DD/YYYY HH:MM` column --
  confirmed on hardware.
- `COPY <source> <destination>`: single file to single file (no
  wildcards/trees), composed entirely from existing `file_open`/
  `file_read`/`file_write`/`file_close` -- no new kernel primitive needed.
  Confirmed on hardware (surfaced and led to fixing three real `file_open`/
  `prog_load` bugs -- see `CLAUDE.md`).
- `DEL <filename>`: deletes a file (refuses directories) via the new
  `K_FILE_DELETE` kernel call (`kernel/file.asm`'s `file_delete`), which
  marks the directory entry deleted on disk *before* freeing its cluster
  chain, so an interruption mid-delete leaves at worst a recoverable
  cluster leak rather than a live entry pointing at freed clusters, and
  cleans up the file's LFN entries alongside its short entry. Confirmed
  on hardware.
- `MD <path>`: creates an empty subdirectory (single-level only -- the
  parent must already exist). Confirmed on hardware.
- `RD <path>`: removes an empty subdirectory (refuses non-empty
  directories, `.`/`..`, and the root). Confirmed on hardware.
- `REN <path> <newname>`: renames a file or directory within its own
  parent directory (no cross-directory move). Implemented, not yet
  confirmed on hardware.

Not yet supported (see `CLAUDE.md` for the fuller running notes):

- `SETTIME` (or similar) to set/correct the clock -- deliberately deferred
  alongside the rest of the small-utility-command backlog below.
- Multiple partitions / drive letters (`C:`, `D:`, ...).
- More shell utilities: `MEM`, `ATTRIB`, etc.
- Batch/script support.

## Architecture

- **Kernel API jump table** at a fixed address (`$0106`), one 3-byte `lbr`
  per call. Slots are append-only, so a program built against an older
  kernel keeps working after the kernel is rebuilt. Programs include
  `include/kernel_api.inc`, which restates just the constants they need
  (call addresses, program header layout, directory-entry layout) rather
  than sharing the kernel's own internal headers — program code never
  depends on kernel internals that could change across updates.
- **Shell has zero built-in commands.** Every command is a standalone
  `.EXE` in `progs/`, loaded and run via the kernel's loader
  (`prog_load`/`prog_exec`).
- **Program binaries** are a small custom format: `'EDF'` magic + version
  byte + 2 reserved bytes, then code. Programs load at a fixed
  `PROG_BASE` above the kernel's own memory, and receive their command-
  line tail via a register at entry (DOS-PSP style).

See `CLAUDE.md` for the full architectural contract, toolchain gotchas
specific to Asm/02 1802 assembly, and the conventions for working in this
codebase.

## Repository layout

```
boot/       MBR and second-stage boot loader (krnboot)
kernel/     Kernel proper: BPB/partition init, FAT, directory, file I/O,
            RTC/timestamps, program loader, shell
include/    Shared headers: BIOS calls, kernel-internal structures,
            the kernel API jump-table contract, opcode macros
progs/      Shell command programs (VER, DIR, CD, TYPE, PWD, WTEST, ...)
sys/        Host-side tool for writing images to a target device
```

## Building

Requires the Asm/02 assembler (`asm02`) and Link/02 linker (`link02`) on
`PATH`.

```
make            # build kernel-full.bin (bootstrap + kernel)
make progs      # build every progs/*.asm into a loadable progs/*.exe
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

`progs/*.exe` files aren't installed by the Makefile — copy them onto the
FAT16 partition yourself (e.g. with `mtools`'s `mcopy`).
