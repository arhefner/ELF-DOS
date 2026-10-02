# Installing ELF-DOS from Linux

This guide takes a blank SD or CF card to a bootable ELF-DOS disk, using
the files in the Linux release package. It also works on a Raspberry Pi.
Nothing needs to be built.

There are three steps:

1. Partition and format the card (`mkdisk.sh`).
2. Install the boot code and the kernel (`elfdos-sys.sh`).
3. Copy the programs into `/bin` on the first partition.

## What is in the package

| File | What it is |
|---|---|
| `mkdisk.sh` | Partitions and formats a card for ELF-DOS |
| `elfdos-sys.sh` | Writes the boot code and kernel to a card |
| `mbr.bin` | Boot code for sector 0 |
| `kernel-full.bin` | The kernel and its bootstrap |
| `bin/` | Every ELF-DOS command, including the shell |
| `kernel-rom.bin` | The part of the kernel that can go in ROM (optional) |
| `docs/` | The User's Guide and the Developer's Guide |
| `elfdos-sdk-*.tar.gz` | Headers and libraries for writing your own programs |
| `MANIFEST.txt` | Version, and the address for `kernel-rom.bin` |

## Before you start

You need `sfdisk`, `mkfs.fat` and the other tools from the `util-linux`
and `dosfstools` packages. Most systems already have them; on Debian,
Ubuntu or Raspberry Pi OS, `sudo apt install dosfstools` adds the one that
is sometimes missing.

**Both scripts write straight to a disk, and step 1 erases it.** Find the
card's device name before you begin:

```
lsblk
```

Run it once without the card and once with it; the new entry is the card.
It is usually `/dev/sdb` (a USB reader) or `/dev/mmcblk0` (a built-in
slot). Give the scripts the whole disk, not a partition: `/dev/sdb`, not
`/dev/sdb1`. On a Raspberry Pi, `/dev/mmcblk0` is normally the Pi's own
system card. `mkdisk.sh` refuses a disk that holds the running system,
but check anyway.

The examples below use `/dev/sdX`. Open a terminal in the directory where
you unpacked the package.

## Step 1: Partition and format the card

```
sudo ./mkdisk.sh /dev/sdX
```

The script shows the card it found, then asks how many partitions you want
(1 to 4) and how big each should be. Sizes are in megabytes, or with a
suffix: `512M`, `1G`. Press Enter at the last one to use the rest of the
card. It then shows the planned layout and asks you to type `YES` before
it writes anything.

Things to know when choosing sizes:

- Each partition becomes a drive in ELF-DOS: `C:`, `D:`, `E:`, `F:`.
  ELF-DOS boots from the first one.
- A partition can be from 16 MB to 4095 MB.
- ELF-DOS can use only the first 8 GB of a card.
- Keep partitions under 2 GB if you also want to read the card on Windows.

One 512 MB partition is plenty to start with.

## Step 2: Install the boot code and kernel

```
sudo ./elfdos-sys.sh -m mbr.bin -k kernel-full.bin /dev/sdX
```

The script checks both files and the card, asks before writing, and reads
back what it wrote. It keeps the partition table from step 1. It refuses
a card that has not been partitioned.

## Step 3: Copy the programs

ELF-DOS has no built-in commands. Every command, and the shell itself, is
a file in the `bin` directory of the boot partition. The directory name
must be lowercase.

Mount the first partition, copy the files, and unmount it. The first
partition is `/dev/sdX1`, or `/dev/mmcblk0p1` for a built-in slot.

```
sudo mount /dev/sdX1 /mnt
sudo mkdir /mnt/bin
sudo cp bin/* /mnt/bin/
sudo umount /mnt
```

If your desktop mounts the card by itself, you can copy the `bin`
directory onto it with the file manager instead. Eject the card before
removing it.

With `mtools` installed, the same thing without mounting:

```
sudo mmd   -i /dev/sdX1 ::bin
sudo mcopy -i /dev/sdX1 bin/* ::bin/
```

## First boot

Put the card in the computer and boot from it as your BIOS or monitor
requires. ELF-DOS prints its banner and a prompt:

```
ELF-DOS v1.2
C:/>
```

Type `ver` or `dir` to check that commands run. The User's Guide in
`docs/` takes over from here.

If something goes wrong:

| What you see | Likely cause |
|---|---|
| `Boot error: cannot read the disk` | The BIOS could not read the card |
| `Boot error: no ELF-DOS kernel on this disk` | Step 2 was not done on this card |
| `No shell on C:.` | Step 3 was not done, or the directory is not named `bin` |
| Nothing at all | The card does not have the boot code (step 2), or the computer is not booting from it |

## Updating later

To install a newer kernel, repeat step 2 with the new files, and replace
the contents of `/bin` with the new `bin/`. Always update both together;
programs are built for the kernel they ship with. Your own files on the
card are not touched.

You do not need to repeat step 1.

## Putting the kernel in ROM (optional)

`kernel-rom.bin` is the part of the kernel that never changes while it
runs. If you burn it into ROM at the address given in `MANIFEST.txt`,
ELF-DOS finds it there and does not load it from the card, which leaves
that much more RAM free. The card is prepared the same way in either
case, and a computer without the ROM boots normally.

The ROM must match the kernel on the card. Burn a new one whenever you
install a new kernel.
