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
- File open/read/close, and seek (rewind-to-start only).
- File **write**: extending or overwriting the content of an
  already-existing file, including growing its cluster chain across
  multiple clusters (`fat_alloc`/`fat_set`/`fat_flush`) and rewriting the
  directory entry's size field on close.
- A handful of shell utilities: `VER`, `DIR`, `CD`, `TYPE`, plus `WTEST`
  (a write-support test/exercise tool).

Not yet supported (see `CLAUDE.md` for the fuller running notes):

- Creating a brand-new file (no existing directory entry) or true
  appending (seeking to end-of-file) — today, opening a file for write
  always starts from position 0 and overwrites-and-extends.
- Multi-component / absolute paths (e.g. `TYPE /cfg/env.dat`) — file and
  directory lookups currently only resolve a single name within the
  current directory.
- Multiple partitions / drive letters (`C:`, `D:`, ...).
- More shell utilities: `DEL`, `REN`, `MD`, `RD`, `COPY`, `MEM`, etc.

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
            program loader, shell
include/    Shared headers: BIOS calls, kernel-internal structures,
            the kernel API jump-table contract, opcode macros
progs/      Shell command programs (VER, DIR, CD, TYPE, WTEST, ...)
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
