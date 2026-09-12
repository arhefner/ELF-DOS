#!/bin/sh
# Two-partition emulator disk: C: FAT16 (2048, 40000 sectors) with /bin,
# D: FAT12 in 1.44MB floppy geometry (42048, 2880 sectors).
set -e
OUT="$1"; EDOS="$2"; SC=$(cd "$(dirname "$0")" && pwd)
EMU=$HOME/projects/elf/EDOS-zrun3/tools/emu
rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
dd if=/dev/zero of=disk1.ide bs=1M count=32 status=none
sfdisk -q disk1.ide >/dev/null <<'PT'
label: dos
unit: sectors
start=2048, size=40000, type=6, bootable
start=42048, size=2880, type=1
PT
dd if=/dev/zero of=p1.img bs=512 count=40000 status=none
mkfs.fat -F 16 -n ELFDOS -s 4 p1.img >/dev/null
dd if=p1.img of=disk1.ide bs=512 seek=2048 conv=notrunc status=none
rm -f p1.img p2.img
mkfs.fat -F 12 -n FLOPPY -C p2.img 1440 >/dev/null
dd if=p2.img of=disk1.ide bs=512 seek=42048 conv=notrunc status=none
rm -f p2.img
yes y | "$EDOS/sys/elfdos-sys" -m "$EDOS/mbr.bin" -k "$EDOS/kernel-full.bin" disk1.ide >/dev/null
set -- $(for f in "$EDOS"/bin/*; do echo "$f=/bin/$(basename "$f")"; done) \
       $(for f in "$EDOS"/test/bin/*; do echo "$f=/bin/$(basename "$f")"; done)
python3 "$EMU/fatput.py" disk1.ide 2048 "$@"
python3 - "$SC" <<'EOF'
import sys, random; sys.path.insert(0, sys.argv[1]); import fatx
v = fatx.Vol('disk1.ide', 42048); assert v.fat12, v.count
random.seed(7)
big = bytes(random.getrandbits(8) for _ in range(300000))
open('big.bin', 'wb').write(big)
print('big.bin clusters', v.putroot('big.bin', big)[0], '..', v.count)
v.putroot('small.txt', b'hello from a FAT12 volume\r\n' * 3)
EOF
echo built
