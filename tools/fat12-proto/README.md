# FAT12 prototype test tools

Throwaway verification tools for the FAT12 prototype on branch `fat12-plan`.
See `docs/FAT12_PLAN.md` for what they showed. Run everything from the repo
root after `make` (the kernel build only has to link; it does not have to
pass the margin check).

    objs=$(make -pn | grep -E "^(KVOL|KNV) :?=" | sed 's/.*= *//' | tr '\n' ' ')
    link02 -b -be -r -o /tmp/k.bin -s $objs > syms.txt   # must match kernel.bin (cmp)
    python3 tools/fat12-proto/sim12.py         # fat_get/fat_set vs reference FAT12
    FAT16=1 python3 tools/fat12-proto/sim12.py # FAT16 path through the dispatch
    PATCH=c00d=ff ITER=3000 python3 tools/fat12-proto/sim12.py  # a mutant must FAIL
    python3 tools/fat12-proto/simswd.py        # _switch_drive's bpb_fat16 flag
    python3 tools/fat12-proto/simperf.py       # instruction counts per path
    link02 -b -be -r -o kb.bin boot/krnboot.prg  # simb7.py reads kb.bin here

- `sim12.py`: instruction-level 1802 simulator executing the linked
  `kernel.bin`; only `_fat_load_sector` is mocked (disk + one-sector cache
  with flush-on-evict). Mutant addresses in the example are for the
  committed build; find new ones in the listing after any change.
- `simb7.py`: krnboot's exact cluster count against real `mkfs.fat`
  volumes. Needs `link02 -b -be -r -o kb.bin boot/krnboot.prg`; its label
  addresses are hardcoded from `boot/krnboot.lst` and must be re-read after
  any krnboot change.
- `mkdisk_f12.sh <outdir> <repo>`: the FAT12 battery's disks -- a boot
  disk whose second partition is FAT12, plus a partitionless FAT12
  floppy-geometry disk on unit 1. Needs the `RUN02_UNITS` emulator copy
  described above.
- `mkdisk12.sh <outdir> <repo>`: Run/02 disk with C: FAT16 and D: FAT12
  (1.44MB geometry) seeded with a 300KB file crossing straddling cluster 341.
  Needs `make everything`, `make mbr`, `make -C sys`, and the emulator tools
  in `~/projects/elf/EDOS-zrun3/tools/emu`.
- `fatx.py`: host-side FAT12/FAT16 reader (with LFNs) and root-file writer,
  for seeding and checking disks.
