#!/bin/bash
#
# mkdisk.sh - partition and FAT16-format a card for ELF-DOS (Linux)
#
#   sudo ./mkdisk.sh [device]          device defaults to /dev/mmcblk0
#
# Linux counterpart of Format-ElfDosDisk.ps1: the same layout and the same
# rules, so a card made on either system comes out the same.
#
# LAYOUT
#   LBA 0            MBR -- the partition table ("sys -m" adds boot code)
#   LBA 1 .. 2047    reserved for krnboot and the kernel, which "sys -k"
#                    (make install) writes from LBA 1 upward
#   LBA 2048 ...     partition 1, then 2, 3, 4, each 1 MiB aligned
#
# WHY sfdisk AND NOT fdisk: the first version of this script fed keystrokes
# to fdisk, and fdisk's prompts change with the state of the disk. With a
# single partition "t" selects it without asking which, so the partition
# number was read as the TYPE (partition 1 came out FAT12) and the real
# type became "6: unknown command". With one slot left "n" skips the
# number prompt, so the number was read as the first sector ("Value out of
# range"). Worse, "-c=dos" started partition 1 at sector 16 (63 on some
# readers) -- inside the 37 sectors "make install" writes, so installing
# the kernel would have overwritten partition 1's boot sector and FATs.
# sfdisk takes the layout as data, so there are no prompts to fall out of
# step with, and every number below is decided and checked before the disk
# is touched.

set -uo pipefail

TARGET=${1:-/dev/mmcblk0}

RESERVED_SECTORS=2048   # 1 MiB: MBR + krnboot + kernel (37 sectors today)
SECTORS_PER_MIB=2048
MAX_PARTS=4             # MBR primaries; also ELF-DOS's MBR_PART_COUNT
MIN_MIB=16              # mkfs.fat will not make a smaller FAT16 volume
MAX_MIB=4095            # 4 GiB needs more than 65524 clusters even at 64 KB
WINDOWS_MIB=2048        # from here mkfs.fat picks 64 KB clusters (see below)
LBA_LIMIT=16777216      # ELF-DOS addresses sectors in 24 bits: below 8 GiB
PART_TYPE=e             # FAT16 (LBA). Must be nonzero -- MOUNT treats a zero
                        # type byte as an unused entry.

die() { echo "error: $*" >&2; exit 1; }

mib_of() { echo $(( $1 / SECTORS_PER_MIB )); }

# "512M", "512m" or "512" -> 512; "1G" -> 1024. Prints nothing if invalid.
parse_mib() {
    local s=${1^^}
    if [[ $s =~ ^([0-9]+)M?$ ]]; then
        echo $(( 10#${BASH_REMATCH[1]} ))
    elif [[ $s =~ ^([0-9]+)G$ ]]; then
        echo $(( 10#${BASH_REMATCH[1]} * 1024 ))
    fi
}

# The kernel names a partition with a "p" when the disk's name ends in a
# digit: mmcblk0p1, nvme0n1p1, loop0p1 -- but sda1.
part_dev() {
    case "$TARGET" in
        *[0-9]) echo "${TARGET}p$1" ;;
        *)      echo "${TARGET}$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Preflight -- nothing here touches the disk
# ---------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 $TARGET"

for tool in sfdisk mkfs.fat wipefs blockdev lsblk findmnt umount; do
    command -v "$tool" >/dev/null ||
        die "$tool not found (it comes with util-linux or dosfstools)"
done

[ -b "$TARGET" ] || die "$TARGET is not a block device"

case "$(lsblk -dno TYPE "$TARGET" 2>/dev/null)" in
    disk|loop) ;;
    *) die "$TARGET is not a whole disk -- give the disk itself (e.g. /dev/mmcblk0), not a partition" ;;
esac

# Refuse if anything on the target is part of the running system. On a
# Raspberry Pi /dev/mmcblk0 is often the Pi's OWN boot card rather than a
# card in a reader, which is exactly the mistake this has to catch.
while read -r name mnt; do
    case "$mnt" in
        /|/boot|/boot/*|/usr|/usr/*|/var|/var/*|/home|/home/*|\[SWAP\])
            die "$name is in use by this system (mounted at $mnt). Refusing to touch $TARGET." ;;
    esac
done < <(lsblk -lnpo NAME,MOUNTPOINT "$TARGET")

root_src=$(findmnt -no SOURCE / 2>/dev/null)
if [ -b "$root_src" ]; then
    root_parent=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)
    root_disk=${root_parent:+/dev/$root_parent}
    root_disk=${root_disk:-$root_src}
    if [ "$(readlink -f "$root_disk")" = "$(readlink -f "$TARGET")" ]; then
        die "$TARGET holds this system's root filesystem. Refusing."
    fi
fi

TOTAL_SECTORS=$(blockdev --getsz "$TARGET") || die "cannot read the size of $TARGET"
if [ "$TOTAL_SECTORS" -lt $(( RESERVED_SECTORS + MIN_MIB * SECTORS_PER_MIB )) ]; then
    die "$TARGET is too small ($(mib_of "$TOTAL_SECTORS") MiB) for even one partition"
fi

echo
echo "Target: $TARGET  $(lsblk -dno SIZE,MODEL "$TARGET" | sed 's/  */ /g; s/^ //; s/ *$//')"
echo "        $(( (TOTAL_SECTORS - RESERVED_SECTORS) / SECTORS_PER_MIB )) MiB usable for partitions"
if [ -n "$(lsblk -lno NAME "$TARGET" | tail -n +2)" ]; then
    echo "Currently on it:"
    lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET" | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# Choose the layout -- still nothing written
# ---------------------------------------------------------------------------

echo
while true; do
    read -rp "How many partitions? (1-$MAX_PARTS): " COUNT || die "no input -- nothing was changed"
    [[ $COUNT =~ ^[1-4]$ ]] && break
    echo "  Enter a number from 1 to $MAX_PARTS."
done

STARTS=()
SIZES=()
next=$RESERVED_SECTORS

for (( i = 1; i <= COUNT; i++ )); do
    room=$(( TOTAL_SECTORS - next ))
    if [ "$room" -lt $(( MIN_MIB * SECTORS_PER_MIB )) ]; then
        die "no room left for partition $i ($(mib_of "$room") MiB remain, $MIN_MIB needed). Nothing was changed."
    fi

    while true; do
        if [ "$i" -eq "$COUNT" ]; then
            read -rp "Size of partition $i (e.g. 512M, 1G), or Enter for the remaining $(mib_of "$room") MiB: " answer ||
                die "no input -- nothing was changed"
        else
            read -rp "Size of partition $i (e.g. 512M, 1G; $(mib_of "$room") MiB left): " answer ||
                die "no input -- nothing was changed"
        fi

        if [ -z "$answer" ] && [ "$i" -eq "$COUNT" ]; then
            sectors=$room
        else
            mib=$(parse_mib "$answer")
            if [ -z "$mib" ]; then
                echo "  '$answer' is not a size. Use a number of MiB, optionally with M or G (512M, 1G)."
                continue
            fi
            sectors=$(( mib * SECTORS_PER_MIB ))
        fi

        # Compare sectors, not rounded MiB: a remainder a few sectors short of
        # 4096 MiB still rounds down to 4095 but would not fit FAT16.
        if [ "$sectors" -lt $(( MIN_MIB * SECTORS_PER_MIB )) ]; then
            echo "  $(mib_of "$sectors") MiB is too small: mkfs.fat will not make a FAT16 volume under $MIN_MIB MiB."
        elif [ "$sectors" -gt $(( MAX_MIB * SECTORS_PER_MIB )) ]; then
            echo "  $(mib_of "$sectors") MiB is too big for one FAT16 partition (at most $MAX_MIB MiB)."
        elif [ "$sectors" -gt "$room" ]; then
            echo "  $(mib_of "$sectors") MiB won't fit: only $(mib_of "$room") MiB remain."
        elif [ $(( next + sectors )) -gt "$LBA_LIMIT" ]; then
            echo "  That runs past 8 GiB, beyond what ELF-DOS can address (24-bit sector numbers)."
            echo "  At most $(mib_of $(( LBA_LIMIT - next ))) MiB fits here."
        else
            break
        fi
    done

    STARTS+=("$next")
    SIZES+=("$sectors")
    next=$(( next + sectors ))
done

echo
echo "Planned layout for $TARGET:"
big=()
for (( i = 1; i <= COUNT; i++ )); do
    printf '  %d. ELFDOS%d  start LBA %-9s %5d MiB\n' \
        "$i" "$i" "${STARTS[i-1]}" "$(mib_of "${SIZES[i-1]}")"
    if [ "${SIZES[i-1]}" -ge $(( WINDOWS_MIB * SECTORS_PER_MIB )) ]; then
        big+=("$i")
    fi
done

if [ "${#big[@]}" -gt 0 ]; then
    echo
    echo "Note: partition(s) ${big[*]} are $WINDOWS_MIB MiB or more, so mkfs.fat will use 64 KB"
    echo "clusters. ELF-DOS reads that fine, but Windows may refuse to mount them."
fi

echo
echo "EVERYTHING on $TARGET will be destroyed."
read -rp "Type YES to continue: " answer || die "no input -- nothing was changed"
if [ "$answer" != "YES" ]; then
    echo "Aborted -- nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Write it
# ---------------------------------------------------------------------------

# A desktop session usually auto-mounts a card, and a mounted partition
# stops the kernel re-reading the new table.
while read -r name mnt; do
    if [ -n "$mnt" ]; then
        echo "Unmounting $name ($mnt)"
        umount -A "$name" ||
            die "could not unmount $name -- close anything using it and try again. Nothing was changed."
    fi
done < <(lsblk -lnpo NAME,MOUNTPOINT "$TARGET")

# Re-formatting a card that already has partitions makes sfdisk print
# "Partition #N contains a vfat signature" on stderr. It is harmless --
# sfdisk removes the signature itself -- but it reads like an error, and
# stderr can't just be silenced because a real sfdisk failure goes there
# too. Clearing the old signatures first leaves sfdisk nothing to report.
while read -r name type; do
    if [ "$type" = part ]; then
        wipefs -a -q "$name" ||
            die "could not clear the old filesystem signature from $name"
    fi
done < <(lsblk -lnpo NAME,TYPE "$TARGET")

echo "Writing partition table..."
{
    echo "label: dos"
    for (( i = 1; i <= COUNT; i++ )); do
        line="start=${STARTS[i-1]}, size=${SIZES[i-1]}, type=$PART_TYPE"
        if [ "$i" -eq 1 ]; then
            line="$line, bootable"
        fi
        echo "$line"
    done
} | sfdisk --quiet --wipe always --wipe-partitions always "$TARGET" ||
    die "sfdisk could not write the partition table to $TARGET"

# sfdisk already asks the kernel to re-read; this is harmless if it's busy.
blockdev --rereadpt "$TARGET" 2>/dev/null
command -v udevadm >/dev/null && udevadm settle

for (( i = 1; i <= COUNT; i++ )); do
    p=$(part_dev "$i")
    tries=0
    while [ ! -b "$p" ] && [ "$tries" -lt 50 ]; do
        sleep 0.2
        tries=$(( tries + 1 ))
    done
    [ -b "$p" ] ||
        die "$p did not appear after partitioning -- remove and reinsert the card, then run: mkfs.fat -F 16 $p"
done

for (( i = 1; i <= COUNT; i++ )); do
    p=$(part_dev "$i")
    echo "Formatting $p as FAT16 (ELFDOS$i)..."
    mkfs.fat -F 16 -n "ELFDOS$i" "$p" >/dev/null || die "mkfs.fat failed on $p"
    # Check each one straight away, before a desktop can auto-mount it.
    if command -v fsck.fat >/dev/null; then
        fsck.fat -n "$p" >/dev/null 2>&1 ||
            die "$p does not check clean straight after formatting (see: fsck.fat -n $p)"
    fi
done
sync
command -v udevadm >/dev/null && udevadm settle

echo
echo "Done. $TARGET now has $COUNT FAT16 partition(s):"
lsblk -no NAME,SIZE,FSTYPE,LABEL "$TARGET" | sed 's/^/  /'

p1=$(part_dev 1)
echo
echo "Next -- install the boot code and kernel:"
echo "  make install DEV=$TARGET"
echo "then put the programs in \\BIN on the first partition, e.g. with mtools:"
echo "  mmd   -i $p1 ::BIN"
echo "  mcopy -i $p1 bin/* ::BIN/"
