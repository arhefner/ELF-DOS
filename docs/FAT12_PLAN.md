# FAT12 support plan

Status: **implemented on branch `fat12-plan`** (2026-09-11).
Phases 0-3 are done: Phase 0 is on `main`, the rest on this branch, rebased
on it. Verified by instruction-level simulation and under the Run/02
emulator against real `mkfs.fat -F 12` volumes, including a partitionless
floppy-geometry disk on a second unit. **Not hardware-tested.** Phase 4
(floppy write speed) is deliberately not done: it trades crash safety for
speed, which is the user's call.

Target media: floppies on the new interface (1.44MB, 720K, 360K), plus small
RAM, flash and serial disks, which `mkfs.fat` formats as FAT12 below roughly
16MB.

## What FAT12 changes, and what it does not

The only structural difference from FAT16 is the width of a FAT entry:

- A 12-bit entry for cluster N starts at byte `N + N/2` of the FAT. Even
  clusters use the low 12 bits of that 16-bit little-endian pair; odd
  clusters use the high 12 bits.
- End of chain is `$FF8-$FFF`, bad is `$FF7`.
- **An entry can straddle two FAT sectors.** When its first byte is at
  offset 511, the second byte is the next sector's first byte. That happens
  at 2 of every 3 sector boundaries: a 1.44MB disk (9 FAT sectors) has 6
  such clusters, at 341, 682, 1365, 1706, 2389 and 2730.

Everything else already works: the fixed root directory region, the BPB
layout (FAT12 and FAT16 share offsets `$0B-$3D`, including the volume label
LABEL writes), directory entries, LFNs, `_cluster_to_lba`, `.`/`..`, and
timestamps. MOUNT already mounts a volume with no partition table
(`MOUNT <unit> 0 A:`), which is how a floppy is laid out.

**FAT type is decided by cluster count, as the spec requires**: fewer than
4085 clusters is FAT12. The filesystem-type string and the partition type
byte are not reliable. That puts the whole design on one number,
`max_clust`, which was not computed correctly until Phase 0b.

## Design

1. **All FAT12 handling lives in `fat_get`/`fat_set` (`kernel/fat.asm`).**
   Every other FAT access in the kernel (15 call sites in `dir.asm` and
   `file.asm`) goes through those two routines and compares 16-bit values
   against `$FFF8`/`$FFF7`. `fat_get` widens `$FF7-$FFF` to `$FFF7-$FFFF`,
   and `fat_set` stores only the low 12 bits (so `$FFF8` lands as `$FF8`).
   No caller changes.
2. **FAT type is derived, not stored.** `_switch_drive` sets a 1-byte
   `bpb_fat16` flag from `bpb_max_clust >= $0FF6` (i.e. count >= 4085)
   whenever a drive becomes active. `drive_bpb_table`'s layout and every
   published offset (`BPBBLK_*`, `DRIVE_*_OFF`) are unchanged, so this is not
   an ABI change and nothing needs rebuilding for it.
3. **Straddling entries use the existing one-sector cache.** Read or write
   the first byte, then load the next sector (which flushes the first if it
   is dirty) for the second byte. This avoids a second 512-byte cache in
   volatile RAM. Cost: occasional extra I/O at the six boundaries, and a
   write to a straddling entry is not atomic (MS-DOS has the same property).
4. **`max_clust` becomes exact:** `count + 1`, where
   `count = (total_sectors - (data_lba - part1_lba)) >> spc_shift`. This is
   computed in krnboot for boot-time partitions and in MOUNT for mounted
   ones. A count of 65525 or more (FAT32, or not FAT) leaves the drive
   absent.

## Phases

### Phase 0: prerequisites -- DONE, on `main` (not hardware-tested)

These were live bugs independent of FAT12. Commits `6406eac` and `bc28c26`.

**0a. Raw-sector tools ignored the block-device unit.**
`K_SECREAD`/`K_SECWRITE` are bare BIOS passthroughs, and `lib/vollabel.asm`
(LABEL, and DIR's volume header), `progs/chkdsk.asm` and `test/corrupt.asm`
all set `R8.1 = 0`. For a drive mounted from another unit they used the boot
device at that drive's addresses. Reproduced under Run/02 with a second disk:
the old `LABEL G:` wrote its label into the boot disk's MBR boot code, and
the old `CHKDSK G:` reported every cluster lost. Each now captures
`BPBBLK_DEV` with the other BPB fields it reads and loads it into R8.1.

**0b. `max_clust` was wrong, on FAT16 too.** krnboot and MOUNT estimated it
as `spf*256-1`, from the FAT's size rather than the volume's:

| Volume | Real `max_clust` | Old estimate |
|---|---|---|
| FAT16 32MB | 16,344 | 16,383 (+39) |
| FAT16 64MB | 32,696 | 32,767 (+71) |
| FAT16 499MB | 63,930 | 65,535 (**+1,605**) |
| FAT12 720K | 714 | 767 (+53) |
| FAT12 1.44MB | 2,848 | 2,303 (-545) |

A FAT beyond the last real cluster is zero-filled, so `fat_alloc` saw those
phantom clusters as free and could write file data past the end of the
partition. Both now compute `count + 1` exactly (krnboot Step 7b, and the
same code in MOUNT), and refuse FAT32 (65525+ clusters). On `main`, krnboot
also leaves a FAT12 partition absent (fewer than 4085 clusters), since that
kernel cannot read one. **This branch removes that one check**, because its
kernel can. MOUNT already refused FAT12 by its `FAT16` type string, now also
checks the count, and refuses a bytes-per-sector other than 512.

**0c. CHKDSK's total space** multiplied `max_clust` instead of
`max_clust - 1` by the cluster size.

**0d (found while testing 0b). krnboot gave every MBR slot a drive letter**
even when the slot was absent, breaking the rule that a slot has a letter
exactly when it is present. MOUNT listed empty or refused partitions as
mounted. Absent slots now get no letter.

Verified under Run/02 (a copy patched so unit N maps to `disk<N+1>.ide`,
which stock Run/02 cannot do): every CHKDSK total and used figure matched
the host's own count on four FAT16 volumes and a partitionless volume on
unit 1; MOUNT and krnboot computed identical geometry for the same
partition; LABEL/CHKDSK/CORRUPT on unit 1 left the boot disk's MBR
byte-identical; `fsck.fat` clean. The same run on the old build reproduced
every bug above.

### Phase 1: kernel FAT12 -- DONE

Design points 1-3 are implemented in `kernel/fat.asm`/`kernel/fat_data.asm`.
Also done:

- `fat_set` keeps its documented "RB unchanged" contract: its FAT12 path
  rewrites RB into the on-disk bit pattern, so it pushes and pops it,
  including on the error exit. Cheaper than amending a contract some future
  caller might rely on.
- `_fat_load_sector`'s header now states what the FAT12 path depends on
  (RD.0 carried through, RB preserved) and that RC is clobbered on its
  flush path -- it claimed only "R7, R8, RF", while `fat_flush` uses RC as
  its FAT-copy counter. Every caller already protected RC.
- `NVK_BASE` is `$BC40` on this branch (see Costs).

### Phase 2: userland -- DONE

- **MOUNT** accepts FAT12: the `FAT16` type-string test and the
  `count < 4085` refusal are gone; FAT32 is still refused. That string test
  was also what stopped `MOUNT <unit> 0` mounting a partition TABLE as a
  volume, so a VBR sanity check replaces it -- a jump opcode (`$EB`/`$E9`)
  at offset 0, which every formatter writes and no partition table has
  (ELF-DOS's own MBR begins "MBR"), plus the `$55 $AA` signature.
- **CHKDSK** reads the whole FAT into RAM once (`chk_load_fat12`, at most
  12 sectors = 6,128 bytes) and decodes from there, which also avoids its
  uncached per-hop sector read -- a seek per cluster on a floppy.
  `$FF7-$FFF` widen to `$FFF7-$FFFF`, so its end-of-chain and bad-cluster
  tests are untouched, and the lost-cluster pass walks clusters straight
  out of RAM instead of sector by sector.
- **CORRUPT** decodes and writes FAT12 too. Each byte of a 12-bit entry
  shares a nibble with a neighbour, so a write is read-modify-write per
  byte, per FAT copy; doing the two bytes independently also handles a
  straddling entry at no extra cost.
- Docs updated: USER_GUIDE (both formats are read; how to swap a floppy),
  `include/kernel_api.inc` (`BPBBLK_MAX_CLUST` is also the FAT type).

### Phase 3: removable media -- DONE (option 1)

The User's Guide now tells the reader to mount a disk again after swapping
it, and why: nothing detects a swap, and the prompt is a safe point because
no write is ever left half-finished. Options 2 and 3 below remain open, and
remain optional.


Nothing notices a disk swap. After a swap the drive's BPB, current
directory and (if active) FAT cache describe the old disk, and a write
corrupts the new one. The FAT is always flushed promptly, so the shell
prompt is a safe point to swap. Options, cheapest first:

1. Rule: re-run `MOUNT` after changing disks. It re-reads the BPB, resets
   the current directory and calls `K_DRIVE_INVALIDATE`. No code needed.
2. A short form, e.g. `MOUNT -r A:`, that re-reads the BPB from the unit
   and start LBA already recorded in A:'s table entry.
3. A BIOS "media changed on unit N" query, checked in `_switch_drive` for
   removable units (discussed 2026-09-10, not designed yet).

### Phase 4 (optional): floppy write and cross-drive speed

These are not FAT12 problems, but a floppy is where they will dominate:

- **`file_write` flushes the FAT after every cluster allocation**, a
  deliberate crash-safety choice. At 1 sector per cluster (1.44MB), every
  512 bytes written costs a data write plus two FAT writes on cylinder 0,
  so the head seeks on every sector. MS-DOS defers FAT writes until close.
  The option is to defer flushes on FAT12 volumes until `file_close`, which
  trades crash safety for speed and is your call.
- **A real drive switch discards the FAT cache.** `file_read` and
  `file_write` switch drives on entry, so `COPY` between C: and A: (512-byte
  chunks) re-reads A:'s FAT sector for nearly every chunk. Tagging the cache
  with its owning drive keeps it valid across a switch when the other drive
  did not touch its FAT. That is about 20 bytes, and helps partially. A
  second cache would cost 512 volatile bytes.

These two items are from reading the code. They have not been measured.

## Costs

Measured from the prototype build, with this baseline: volatile
`$0100-$0B4E`, non-volatile 12,793 bytes at `$BE00` (7 bytes below
`NVK_TOP`), relay-floor margin 320 bytes.

| Where | Cost |
|---|---|
| Non-volatile (ROM-able) kernel code | **+284 bytes** linked (`fat_get` +73, `fat_set` +121, `_f12_locate` 53, `_f12_second` 38, `_switch_drive` +23, pre-relaxation), plus ~17 to keep `fat_set`'s RB contract |
| Volatile kernel RAM | **+2 bytes declared, 0 measured.** They fit in existing alignment padding; `kvol_end` and the 320-byte margin are unchanged. |
| krnboot (boot sectors only, not resident) | Phase 0 (on `main`) already spent 136 bytes (241 -> 105 spare); this branch then frees a few by dropping the FAT12 refusal |
| Program RAM, 60K RAM-only machine | **-160 bytes**: `NVK_BASE` `$BCE0` -> `$BC40`, measured to leave 95 bytes under `NVK_TOP` |
| Userland | MOUNT -46 bytes (the type-string test cost more than the VBR check); CHKDSK and CORRUPT grow by their FAT12 decode plus, for CHKDSK, a 6,144-byte buffer while it runs |

**Paying for it.** `main` had already lowered `NVK_BASE` to `$BCE0` for
buffered output redirection, which left too little for FAT12, so this branch
lowers it again to `$BC40`: 160 bytes of program RAM on a RAM-only machine,
with 95 bytes of headroom left. On a machine with real ROM and room above
the kernel it costs nothing. If that 160 bytes is ever wanted back: a
size-reduction pass (surveyed candidates `_file_create` ~85 bytes,
`_gen_short_name` ~40, `file_open`/`file_seek` ~35 -- such estimates have run
optimistic here before), or a build-time `#ifdef FAT12` so a machine with no
floppy pays nothing, at the cost of maintaining two kernel images.

Relaxation means size depends on placement: the prototype measured
13,076-13,089 bytes across bases `$BCC0-$BCF8`. Always use the built figure.

## Performance

Instruction counts come from the simulator running the linked bytes with a
warm cache. SCRT costs are from the BIOS source: 18 instructions per call,
15 per return.

| Path | Instructions per call |
|---|---|
| FAT16 `fat_get`, before -> after | 109 -> 115 (+6, the dispatch) |
| FAT16 `fat_set`, before -> after | 127 -> 134 |
| FAT12 `fat_get` / `fat_set` | 229 / 269 (about 2x FAT16) |
| FAT12 straddling entry | + one sector read (+ one flush when writing) |

- **FAT16 volumes:** no extra I/O. The 6 extra instructions are noise next
  to a sector transfer, whose byte loop alone is thousands of instructions.
  The one CPU-bound FAT loop, `fat_alloc`'s free-cluster scan, gets about
  4% slower per candidate. A real drive switch costs about 8 more
  instructions. Separately, the exact `max_clust` removes the phantom-cluster
  allocations described in 0b (now fixed on `main`).
- **FAT12 volumes:** about twice the CPU per FAT access, still insignificant
  against floppy I/O. Straddling entries: in a forward chain walk the extra
  read loads a sector the walk needs next anyway, so the net cost is about
  zero. A write to one of the six straddling clusters costs one extra flush
  and one read. The real floppy costs are the Phase 4 items, which exist
  with or without FAT12.

## Verification done on the prototype

- **Instruction-level 1802 simulation of the linked `kernel.bin`**
  (`tools/fat12-proto/sim12.py`), with `_fat_load_sector` mocked as a disk
  plus a one-sector cache:
  - 62,000 random `fat_get`/`fat_set` calls against a reference FAT12
    encoder, 20% of them on straddling clusters, including I/O-error
    propagation and stack balance: 0 failures.
  - Three mutant binaries (wrong mask, no straddle load, bad-cluster
    boundary off by one) were all caught.
  - FAT16 regression through the new dispatch: 22,000 calls, 0 failures.
  - `_switch_drive`'s flag at 11 boundary values of `max_clust`, including
    `$0FF5`/`$0FF6`: all correct.
- **krnboot Step 7b** (`simb7.py`): exact `max_clust` for FAT12 360K-8MB
  and FAT16 16MB-2GB (32-bit sector count included), each at partition
  starts 0, 2048 and `$7FFFF0`. FAT32 is refused.
- **Emulator** (Run/02, `mkdisk12.sh`): C: FAT16 plus D: FAT12 in 1.44MB
  geometry. On D: this ran `DIR`, `TYPE`, `COPY` both ways, `MD`, `DEL`,
  `RWBOUNDTEST` and `BIG64TEST` (all checks pass). Every file read back from
  the host byte-matches, and chains crossed all four straddling clusters
  that were reached (341, 682, 1365, 1706), including a fragmented chain
  reusing a freed cluster. `fsck.fat -n` is clean on both partitions.
- **FAT16 differential** against unmodified HEAD (13 commands): transcripts
  identical except CHKDSK's space lines, which are the 0b fix. `fsck.fat`
  is clean on both images.

## Hardware test plan (when implementing)

1. Phase 0 (on `main`): FAT16 cards boot, `MOUNT` lists only real
   partitions, CHKDSK totals match `fsck.fat`, and `LABEL` on a unit-1 drive
   writes unit 1 (check unit 0's MBR afterwards).
2. Phase 1+2: a FAT12 partition on the boot card (a small flash disk), then a
   real 1.44MB floppy via `MOUNT 1 0 A:`: `DIR`, `COPY` both ways,
   `RWBOUNDTEST`, `BIG64TEST`, `CHKDSK A:`, then `fsck.fat` on the host.
3. A 720K floppy (2 sectors per cluster, the size where the old estimate
   overshoots).
4. Swap a floppy and re-run `MOUNT`; confirm the new disk's directory.

Test on scratch media only. On this system a kernel hang can write anywhere.
