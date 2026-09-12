#!/bin/sh
# FAT12 test disks for Run/02 (needs the RUN02_UNITS-patched emulator).
#   disk1.ide (unit 0): P1 FAT16 31MB with /bin, P2 FAT12 8MB (mounted at boot)
#   disk2.ide (unit 1): partitionless FAT12 in 1.44MB floppy geometry
set -e
OUT="$1"; EDOS="$2"; SC=$(cd "$(dirname "$0")" && pwd)
EMU=$HOME/projects/elf/EDOS-zrun3/tools/emu
rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
dd if=/dev/zero of=disk1.ide bs=1M count=48 status=none
sfdisk -q disk1.ide >/dev/null <<'PT'
label: dos
unit: sectors
start=2048,  size=63488, type=6, bootable
start=65536, size=16384, type=1
PT
dd if=/dev/zero of=p.img bs=512 count=63488 status=none
mkfs.fat -F 16 -n ELFDOS -s 4 p.img >/dev/null
dd if=p.img of=disk1.ide bs=512 seek=2048 conv=notrunc status=none
dd if=/dev/zero of=p.img bs=512 count=16384 status=none
mkfs.fat -F 12 -n PART2FAT12 p.img >/dev/null
dd if=p.img of=disk1.ide bs=512 seek=65536 conv=notrunc status=none
rm -f p.img
mkfs.fat -F 12 -n FLOPPY -C disk2.ide 1440 >/dev/null

yes y | "$EDOS/sys/elfdos-sys" -m "$EDOS/mbr.bin" -k "$EDOS/kernel-full.bin" disk1.ide >/dev/null
set -- $(for f in "$EDOS"/bin/*; do echo "$f=/bin/$(basename "$f")"; done) \
       $(for f in "$EDOS"/test/bin/*; do echo "$f=/bin/$(basename "$f")"; done)
python3 "$EMU/fatput.py" disk1.ide 2048 "$@" >/dev/null

# seed the floppy with a file whose chain crosses a straddling cluster
python3 - "$SC" <<'EOF'
import sys, random; sys.path.insert(0, sys.argv[1]); import fatx
v = fatx.Vol('disk2.ide', 0); assert v.fat12, v.count
random.seed(11)
data = bytes(random.getrandbits(8) for _ in range(200000))
open('flop.bin', 'wb').write(data)
ch = v.putroot('flop.bin', data)
print('floppy: %d clusters, chain %d..%d, straddling in chain: %s'
      % (v.count, ch[0], ch[-1], [c for c in ch if (c + c//2) % 512 == 511]))
v.putroot('hello.txt', b'floppy via MOUNT 1 0 A:\r\n')
EOF
echo built
