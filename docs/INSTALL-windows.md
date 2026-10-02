# Installing ELF-DOS from Windows

This guide takes a blank SD or CF card to a bootable ELF-DOS disk, using
the files in the Windows release package. Nothing needs to be built.

There are three steps:

1. Partition and format the card (`Format-ElfDosDisk.ps1`).
2. Install the boot code and the kernel (`Install-ElfDos.ps1`).
3. Copy the programs into `/bin` on the first partition.

## What is in the package

| File | What it is |
|---|---|
| `Format-ElfDosDisk.ps1` | Partitions and formats a card for ELF-DOS |
| `Install-ElfDos.ps1` | Writes the boot code and kernel to a card |
| `mbr.bin` | Boot code for sector 0 |
| `kernel-full.bin` | The kernel and its bootstrap |
| `bin/` | Every ELF-DOS command, including the shell |
| `kernel-rom.bin` | The part of the kernel that can go in ROM (optional) |
| `docs/` | The User's Guide and the Developer's Guide |
| `elfdos-sdk-*.zip` | Headers and libraries for writing your own programs |
| `MANIFEST.txt` | Version, and the address for `kernel-rom.bin` |

## Before you start

Open PowerShell as Administrator: right-click the Start button and choose
"Terminal (Admin)" or "Windows PowerShell (Admin)". Writing to a disk
needs it. Then change to the directory where you unpacked the package:

```
cd C:\path\to\elfdos-1.2
```

Windows blocks scripts that came from a download. Allow these two for
this PowerShell window only:

```
Unblock-File *.ps1
Set-ExecutionPolicy -Scope Process Bypass
```

**Both scripts write straight to a disk, and step 1 erases it.** The
scripts identify the card by its disk number. To see the numbers:

```
Get-Disk
```

Run it once without the card and once with it; the new line is the card.
Check the size as well. The examples below use disk 2.

## Step 1: Partition and format the card

```
.\Format-ElfDosDisk.ps1 -DiskNumber 2
```

Without `-DiskNumber` the script lists the disks and asks. It refuses the
Windows system disk, and refuses a disk that is not removable unless you
add `-Force`.

The script shows the card it found, then asks how many partitions you want
(1 to 4) and the size of each in megabytes. Enter 0 for the last one to
use the rest of the card. It then shows the planned layout and asks you to
type `YES` before it writes anything.

Things to know when choosing sizes:

- Each partition becomes a drive in ELF-DOS: `C:`, `D:`, `E:`, `F:`.
  ELF-DOS boots from the first one.
- ELF-DOS can use only the first 8 GB of a card.
- Keep partitions at 2 GB or under. Windows may not open a larger one,
  and you need Windows to open the first partition in step 3.
- Windows gives every partition its own drive letter once the script has
  run, so you can read and write all of them from Windows.

One 512 MB partition is plenty to start with.

If the script reports "Access is denied", close any Explorer window that
shows the card, then run it again.

When it finishes, the script lists the drive letter Windows gave each
partition. You need the first partition's letter in step 3.

## Step 2: Install the boot code and kernel

```
.\Install-ElfDos.ps1 -DiskNumber 2 -Mbr mbr.bin -Kernel kernel-full.bin
```

The script checks both files and the card, asks before writing, and reads
back what it wrote. It keeps the partition table from step 1. It refuses
a card that has not been partitioned.

## Step 3: Copy the programs

ELF-DOS has no built-in commands. Every command, and the shell itself, is
a file in the `bin` directory of the boot partition. The directory name
must be lowercase.

With the drive letter from step 1 (here `E:`):

```
mkdir E:\bin
copy bin\* E:\bin
```

You can also drag the `bin` folder onto the card in Explorer. If the card
has no drive letter, remove it and put it back in.

Eject the card ("Safely Remove Hardware") before taking it out.

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
