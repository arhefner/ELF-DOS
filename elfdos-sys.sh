#!/bin/bash
#
# elfdos-sys.sh - install the ELF-DOS boot code and kernel on a disk
#                 (Linux, Raspberry Pi, macOS)
#
#   sudo ./elfdos-sys.sh [-m mbr.bin] [-k kernel-full.bin] [-y] <device>
#
#   -m <mbr.bin>          install the MBR boot code (sector 0, bytes 0-445;
#                         the partition table is kept)
#   -k <kernel-full.bin>  install the kernel (LBA 1 onward)
#   -y                    do not ask before writing
#
# <device> is the whole disk (/dev/sdb, /dev/mmcblk0), not a partition, or
# a disk image file. At least one of -m and -k must be given. "make
# install" and "make update" run this script; Install-ElfDos.ps1 is the
# Windows counterpart and makes the same checks.
#
# Order of work: partition and format the card first (mkdisk.sh), then
# run this, then copy bin/* to /BIN on the first partition.
#
# WHAT IS CHECKED BEFORE ANYTHING IS WRITTEN
#   - mbr.bin begins "MBR" and is at most 446 bytes.
#   - The kernel begins "KRN", and the sector counts in its header (written
#     by tools/split_kernel.py) add up to the file's size.
#   - Sector 0 of the disk is not a FAT boot sector. A volume formatted
#     without a partition table also ends in 55 AA, and its FAT starts at
#     LBA 1, exactly where the kernel goes.
#   - The kernel does not reach the start of any partition.
# Everything written is read back and compared.
#
# Needs only dd, od, head, cmp and mktemp.

set -uo pipefail

SECTOR=512
KRNBOOT_SECTORS=5       # must match boot/mbr.asm, boot/krnboot.asm,
                        # progs/sys.asm and tools/split_kernel.py
MBR_CODE_SIZE=446       # boot code area; the partition table follows it
KVOL_CNT_OFFSET=4       # volatile sector count, big-endian word
KNV_CNT_OFFSET=9        # non-volatile sector count, big-endian word

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
ELF-DOS disk installer

Usage: $0 [-m mbr.bin] [-k kernel-full.bin] [-y] <device>

  -m <mbr.bin>          install the MBR boot code (keeps the partition table)
  -k <kernel-full.bin>  install the kernel (written from LBA 1)
  -y                    do not ask before writing

At least one of -m and -k must be given. <device> is the whole disk
(for example /dev/sdb or /dev/mmcblk0) or a disk image file.

CAUTION: this writes directly to the device. The wrong device means
immediate, unrecoverable data loss. Check it with lsblk first.
EOF
    exit 1
}

# byte_at <file> <offset>: one byte, in decimal
byte_at() { od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' \n'; }

# be16_at <file> <offset>: big-endian word, in decimal
be16_at() {
    local hi lo
    hi=$(byte_at "$1" "$2"); lo=$(byte_at "$1" $(( $2 + 1 )))
    echo $(( hi * 256 + lo ))
}

# le32_at <file> <offset>: little-endian 32-bit value, in decimal
le32_at() {
    local b
    b=($(od -An -tu1 -j "$2" -N 4 "$1"))
    echo $(( b[0] + b[1] * 256 + b[2] * 65536 + b[3] * 16777216 ))
}

file_size() { wc -c < "$1" | tr -d ' '; }

MBR=""; KERN=""; DEV=""; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -m) [ $# -ge 2 ] || usage; MBR=$2; shift 2 ;;
        -k) [ $# -ge 2 ] || usage; KERN=$2; shift 2 ;;
        -y) YES=1; shift ;;
        -*) echo "Unknown option: $1" >&2; echo >&2; usage ;;
        *)  [ -z "$DEV" ] || { echo "Error: more than one device given." >&2; echo >&2; usage; }
            DEV=$1; shift ;;
    esac
done
[ -n "$DEV" ] || usage
[ -n "$MBR" ] || [ -n "$KERN" ] || usage

[ -e "$DEV" ] || die "$DEV does not exist"
[ -r "$DEV" ] && [ -w "$DEV" ] || die "cannot read and write $DEV (run with sudo?)"

TMP=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT

# ---- Check the files -------------------------------------------------------

if [ -n "$MBR" ]; then
    [ -r "$MBR" ] || die "cannot read $MBR"
    MBR_SIZE=$(file_size "$MBR")
    [ "$MBR_SIZE" -ge 6 ] && [ "$(head -c 3 "$MBR")" = "MBR" ] \
        || die "$MBR does not begin with the 'MBR' signature. Is this the right file?"
    [ "$MBR_SIZE" -le $MBR_CODE_SIZE ] \
        || die "$MBR is $MBR_SIZE bytes; the boot code area holds only $MBR_CODE_SIZE"
fi

if [ -n "$KERN" ]; then
    [ -r "$KERN" ] || die "cannot read $KERN"
    KERN_SIZE=$(file_size "$KERN")
    [ "$KERN_SIZE" -ge $(( KRNBOOT_SECTORS * SECTOR )) ] && [ "$(head -c 3 "$KERN")" = "KRN" ] \
        || die "$KERN does not begin with the 'KRN' signature, or is smaller than $(( KRNBOOT_SECTORS * SECTOR )) bytes. Is this the right file?"
    TOTAL=$(( (KERN_SIZE + SECTOR - 1) / SECTOR ))
    VOL=$(be16_at "$KERN" $KVOL_CNT_OFFSET)
    NV=$(be16_at "$KERN" $KNV_CNT_OFFSET)
    [ "$VOL" -ne 0 ] && [ "$NV" -ne 0 ] && [ $(( KRNBOOT_SECTORS + VOL + NV )) -eq "$TOTAL" ] \
        || die "$KERN: the header's sector counts (volatile $VOL, non-volatile $NV) do not add up with the $KRNBOOT_SECTORS-sector bootstrap to the file's $TOTAL sectors. Was it built by tools/split_kernel.py?"
fi

# ---- Check the disk --------------------------------------------------------

OLD0=$TMP/old0
dd if="$DEV" of="$OLD0" bs=$SECTOR count=1 2>/dev/null
[ "$(file_size "$OLD0")" -eq $SECTOR ] || die "cannot read sector 0 of $DEV"

HAS_TABLE=0
[ "$(byte_at "$OLD0" 510)" -eq 85 ] && [ "$(byte_at "$OLD0" 511)" -eq 170 ] && HAS_TABLE=1

if [ $HAS_TABLE -eq 1 ]; then
    B0=$(byte_at "$OLD0" 0)
    if [ "$B0" -eq 235 ] || [ "$B0" -eq 233 ]; then
        die "sector 0 of $DEV is a FAT boot sector, not a partition table: the disk holds one volume with no partitions, and its FAT starts where the kernel would go. Nothing written. Partition the disk first (mkdisk.sh)."
    fi
    if [ -n "$KERN" ]; then
        for i in 0 1 2 3; do
            E=$(( 446 + 16 * i ))
            [ "$(byte_at "$OLD0" $(( E + 4 )))" -ne 0 ] || continue
            START=$(le32_at "$OLD0" $(( E + 8 )))
            [ "$START" -gt "$TOTAL" ] \
                || die "partition $(( i + 1 )) starts at LBA $START, but the kernel needs LBA 1-$TOTAL. Nothing written. Repartition the disk with the first partition at LBA 2048 (mkdisk.sh)."
        done
    fi
fi

# ---- Confirm ---------------------------------------------------------------

echo "ELF-DOS installer"
echo "  Device : $DEV"
[ -n "$MBR" ]  && echo "  MBR    : $MBR"
[ -n "$KERN" ] && echo "  Kernel : $KERN"
echo
if [ $HAS_TABLE -eq 0 ]; then
    echo "Note: sector 0 of $DEV has no partition table. The disk will not be"
    echo "      usable until it is partitioned and formatted (mkdisk.sh), and"
    echo "      that erases the boot code, so this install must be repeated."
    echo
fi

if [ $YES -eq 0 ]; then
    echo "WARNING: This will write directly to $DEV."
    printf "Proceed? [y/N] "
    read -r ANS || ANS=""
    case "$ANS" in
        y*|Y*) echo ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

# write_and_verify <file> <first LBA> <sector count> <what>
# <file> must already be a whole number of sectors.
write_and_verify() {
    dd if="$1" of="$DEV" bs=$SECTOR seek="$2" count="$3" conv=notrunc 2>"$TMP/dderr" \
        || { cat "$TMP/dderr" >&2; die "writing the $4 failed"; }
    sync
    dd if="$DEV" of="$TMP/back" bs=$SECTOR skip="$2" count="$3" 2>/dev/null
    cmp -s "$1" "$TMP/back" \
        || die "the $4 did not read back as written. The disk is in an unknown state."
}

# ---- MBR -------------------------------------------------------------------

if [ -n "$MBR" ]; then
    echo "--- Installing MBR ---"
    NEW0=$TMP/new0
    {
        cat "$MBR"
        head -c $(( MBR_CODE_SIZE - MBR_SIZE )) /dev/zero
        if [ $HAS_TABLE -eq 1 ]; then
            echo "  Partition table found; it is kept." >&2
            dd if="$OLD0" bs=1 skip=$MBR_CODE_SIZE count=64 2>/dev/null
        else
            echo "  No partition table; an empty one is written." >&2
            head -c 64 /dev/zero
        fi
        printf '\125\252'
    } > "$NEW0"
    [ "$(file_size "$NEW0")" -eq $SECTOR ] || die "internal error building sector 0"
    echo "  Writing boot code ($MBR_SIZE bytes)..."
    write_and_verify "$NEW0" 0 1 "MBR"
    echo "  MBR installed."
    echo
fi

# ---- Kernel ----------------------------------------------------------------

if [ -n "$KERN" ]; then
    echo "--- Installing kernel ---"
    echo "  File size    : $KERN_SIZE bytes"
    echo "  Total sectors: $TOTAL (bootstrap $KRNBOOT_SECTORS + volatile $VOL + non-volatile $NV)"
    PADDED=$TMP/kern
    dd if="$KERN" of="$PADDED" bs=$SECTOR conv=sync 2>/dev/null
    [ "$(file_size "$PADDED")" -eq $(( TOTAL * SECTOR )) ] || die "internal error padding the kernel"
    echo "  Writing LBA 1-$TOTAL..."
    write_and_verify "$PADDED" 1 "$TOTAL" "kernel"
    echo "  Kernel installed."
    echo
fi

echo "Done."
