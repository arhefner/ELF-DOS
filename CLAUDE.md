# ELF-DOS

A FAT16 DOS-like OS for the CDP1802 (Elf/OS-compatible hardware). No local emulator or hardware access exists in the development environment — all hardware testing is done by the user reflashing an SD card and reporting console output back.

## Build

```
make            # kernel.bin / kernel-full.bin
make progs      # all progs/*.asm -> progs/*.exe (auto-discovers new files)
make clean
```

Toolchain: `asm02 -L -C -I .. <file>.asm` produces a `.prg`; `link02 -b -be -o <out> <files.prg...>` links them. Link order for the kernel matters and is fixed in the Makefile: `kernel bpb fat dir file loader shell`.

To verify a build's symbol table without a full relink: `link02 -b -be -o /tmp/x.bin -s <files.prg...> 2>&1 | grep <symbol>`.

## Architecture

- **Kernel API jump table** at fixed address `$0106` (`include/kernel_api.inc`, `K_*` constants). Each slot is a 3-byte `lbr`. Entries are **append-only** — never reorder or remove — so a program built against an older kernel keeps working after a kernel rebuild. After touching `kernel/kernel.asm`'s table, verify every slot is still `0xC0` (`lbr`) pointing at the expected target by decoding the built `kernel.bin` directly (see any recent session for the verification script) — don't just trust that the assembler "did the right thing."
- **`kernel_api.inc` is deliberately decoupled from `kernel.inc`** (no `#include` between them). Programs get `K_*` call addresses, `PROG_BASE`/`LOADER_ARGS`, `DIRENT_*`/`ATTR_DIR`, and `KERNEL_HDR_VER` — restated, not shared — so program code never depends on internal kernel structures that could change across updates. Fixed, never-shifting addresses (`PROG_BASE`, `KERNEL_HDR_VER`, etc.) are read directly rather than through a kernel call; only real subroutines get a jump-table slot.
- **Shell has zero built-in commands.** Every command (`VER`, `DIR`, `CD`, `TYPE`, ...) is a standalone `.EXE` in `progs/`, loaded via `prog_load`/`prog_exec`. New shell functionality should default to a new `.EXE`, not a shell built-in.
- **Program binary format**: `'EDF'` magic + version byte + 2 reserved bytes, code at `PROG_BASE+6` (`PROG_BASE = $2000`). Command-line tail is passed in **RA** at entry (pointer to null-terminated string, DOS-PSP style — everything after the program name, not including it, trimmed). `mem_base`/`mem_top` are passed via the fixed `LOADER_ARGS = PROG_BASE-4` instead, since a program may need to consult them at any point (e.g. a heap allocator), unlike the command tail which is only needed once at entry.
- File I/O is currently **read-only** (`file_open`/`file_read`/`file_close`/`file_seek`). `file_write` and the FAT-write primitives (`fat_set`/`fat_alloc`/`fat_flush`) are stubs — this is the next major piece of work.

## Toolchain gotchas (Asm/02) — check for these by hand when reviewing 1802 code

1. **Every `proc` needs a matching `endp`.** Without it, a new `proc` resets the fixup count and silently drops all relocation entries for the *previous* proc, breaking every cross-proc `call`/`lbr` reference into it.
2. **`mov reg, symbol+CONST` compound expressions silently drop the symbol's address**, keeping only the constant. Split into a plain `mov reg, symbol` plus a separate `add16 reg, CONST`.
3. **Comma-separated `extrn a, b, c` on one line only registers the first name.** One `extrn` per line.
4. **`mov` and `add16` both clobber D as a side effect**, unrelated to whatever was in D before them (`mov` leaves D = source's low byte; `add16 reg,CONST` leaves D = the computed address's final high byte). If a value needs to survive a `mov`/`add16`, stash it in a spare register first and reload immediately before the instruction that needs it. This bug has recurred at least four times in this codebase (DIR's attribute/checksum bugs, `file_read`'s FCB-index capture) — treat "does D need to survive a mov/add16 here?" as a standing review question for any 1802 code in this project.
5. **`f_hexout2`/`f_hexout4` write ASCII hex digits into the buffer at `*RF`** (advancing RF) — they do not print to console. To print, point RF at a scratch buffer, call the routine, null-terminate, then separately call `f_msg`/`K_MSG` on that buffer. `f_uintout` follows the same convention for decimal (and does *not* null-terminate itself — you must add the null after it).
6. Same-file cross-`proc` references (a label defined in one `proc`, used in another, in the *same* source file) still need `extrn` + `public`, exactly as if they were in a different file.
7. On the 1802, `ADD`/`ADC`/`SD`/`SDB`/`SM`/`SMB` operate against `M(R(X))`, the *currently selected* X register — normally `R2` by convention throughout this codebase (no code here calls `SEX`). Don't assume a raw BIOS routine leaves X on R2 after return without checking its source, though in practice the SCRT return path (`sep sret`) resets X=2, so this hasn't bitten us yet.
8. Register-preservation across a call is otherwise *unconfirmed by default* — verified so far: `R9` survives `f_msg`/`f_inmsg`. Don't assume any other register survives a BIOS or kernel call without checking the routine's actual source or testing it; when in doubt, stash the value in memory rather than a register across calls whose internals you haven't audited.
9. A shared, index-keyed cache (e.g. `file.asm`'s `io_owner`/`io_buf`) needs invalidation on **both** acquire and release if the index can be reassigned to a different logical resource (FCB slots get reused across different files). Invalidate-on-release alone isn't sufficient.

## Working with the user

No hardware access from this environment — every real test is the user reflashing and pasting console output back. When diagnosing a hardware bug, prefer targeted temporary instrumentation (clearly marked `; TEMPORARY DIAGNOSTIC` / `; END TEMPORARY DIAGNOSTIC`) over guessing, and always remove it once the root cause is confirmed (verify with `grep -rn "TEMPORARY\|DIAGNOSTIC"` before calling a fix done). Ask the user for BIOS routine source when its exact register/side-effect contract matters and isn't already documented here — they have it and have provided it before (`f_strcpy`, `f_uintout`).
