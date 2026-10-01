<#
.SYNOPSIS
    Installs the ELF-DOS boot code and kernel on a disk (typically an SD/CF card).

.DESCRIPTION
    Windows counterpart of elfdos-sys.sh; both make the same checks and write
    the same bytes.

    -Mbr     installs the MBR boot code: bytes 0-445 of sector 0. The
             partition table and the 55 AA signature are kept.
    -Kernel  installs the kernel image from LBA 1 onward.

    At least one of the two must be given. Order of work: partition and
    format the card first (Format-ElfDosDisk.ps1), then run this, then copy
    bin\* to \BIN on the first partition.

    WHAT IS CHECKED BEFORE ANYTHING IS WRITTEN
    ------------------------------------------
    - The MBR file begins "MBR" and is at most 446 bytes.
    - The kernel begins "KRN", and the sector counts in its header (written
      by tools/split_kernel.py) add up to the file's size.
    - Sector 0 of the disk is not a FAT boot sector. A volume formatted
      without a partition table also ends in 55 AA, and its FAT starts at
      LBA 1, exactly where the kernel goes.
    - The kernel does not reach the start of any partition.

    Everything written is read back and compared.

    WHY NO VOLUMES ARE DISMOUNTED
    -----------------------------
    Windows refuses raw writes only to sectors that belong to a mounted
    volume. This script writes LBA 0 and the sectors before the first
    partition, which belong to none, and it refuses to run if the kernel
    would reach a partition.

.PARAMETER Device
    The disk to write: \\.\PhysicalDriveN, or the path of a disk image file.

.PARAMETER DiskNumber
    The physical disk number, instead of -Device (2 means \\.\PhysicalDrive2).

.PARAMETER Mbr
    The boot code file to install (mbr.bin).

.PARAMETER Kernel
    The kernel image to install (kernel-full.bin).

.PARAMETER Force
    Do not ask before writing.

.EXAMPLE
    .\Install-ElfDos.ps1 -DiskNumber 2 -Mbr mbr.bin -Kernel kernel-full.bin
    A new card: boot code and kernel.

.EXAMPLE
    .\Install-ElfDos.ps1 -DiskNumber 2 -Kernel kernel-full.bin
    Replace only the kernel.

.EXAMPLE
    .\Install-ElfDos.ps1 -Device card.img -Mbr mbr.bin -Kernel kernel-full.bin -Force
    Install into a disk image file. Does not need Administrator.

.NOTES
    Writing to a physical disk needs an elevated (Administrator) PowerShell
    session. Use Get-Disk to find the disk number. The wrong disk means
    immediate, unrecoverable data loss.

    If scripts are blocked on this machine, run it as:
        powershell -ExecutionPolicy Bypass -File Install-ElfDos.ps1 ...
#>

[CmdletBinding()]
param(
    [string] $Device,
    [int]    $DiskNumber = -1,
    [string] $Mbr,
    [string] $Kernel,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$SECTOR_SIZE     = 512
$KRNBOOT_SECTORS = 5        # must match boot/mbr.asm, boot/krnboot.asm,
                            # progs/sys.asm and tools/split_kernel.py
$MBR_CODE_SIZE   = 446      # boot code area; the partition table follows it
$KVOL_CNT_OFFSET = 4        # volatile sector count, big-endian word
$KNV_CNT_OFFSET  = 9        # non-volatile sector count, big-endian word

function Stop-WithError([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

function Test-Magic([byte[]]$Data, [string]$Magic) {
    if ($Data.Length -lt $Magic.Length) { return $false }
    for ($i = 0; $i -lt $Magic.Length; $i++) {
        if ($Data[$i] -ne [byte][char]$Magic[$i]) { return $false }
    }
    return $true
}

function Read-Sectors($Stream, [UInt32]$Lba, [int]$Count) {
    $Buf = New-Object byte[] ($Count * $SECTOR_SIZE)
    $Stream.Position = [Int64]$Lba * $SECTOR_SIZE
    $Got = 0
    while ($Got -lt $Buf.Length) {
        $N = $Stream.Read($Buf, $Got, $Buf.Length - $Got)
        if ($N -le 0) { return $null }
        $Got += $N
    }
    return ,$Buf
}

# $Data must be a whole number of sectors: device handles reject anything else.
function Write-AndVerify($Stream, [UInt32]$Lba, [byte[]]$Data, [string]$What) {
    $Stream.Position = [Int64]$Lba * $SECTOR_SIZE
    $Stream.Write($Data, 0, $Data.Length)
    $Stream.Flush()
    $Back = Read-Sectors $Stream $Lba ($Data.Length / $SECTOR_SIZE)
    $Same = ($null -ne $Back)
    if ($Same) {
        for ($i = 0; $i -lt $Data.Length; $i++) {
            if ($Back[$i] -ne $Data[$i]) { $Same = $false; break }
        }
    }
    if (-not $Same) {
        throw "The $What did not read back as written. The disk is in an unknown state."
    }
}

# ---------------------------------------------------------------------------
# 1. Arguments
# ---------------------------------------------------------------------------

if ($DiskNumber -ge 0) {
    if ($Device) { Stop-WithError "Give -Device or -DiskNumber, not both." }
    $Device = "\\.\PhysicalDrive$DiskNumber"
}
if (-not $Device -or (-not $Mbr -and -not $Kernel)) {
    Write-Host "ELF-DOS disk installer"
    Write-Host ""
    Write-Host "Usage: .\Install-ElfDos.ps1 [-Mbr mbr.bin] [-Kernel kernel-full.bin] [-Force]"
    Write-Host "                            (-DiskNumber N | -Device \\.\PhysicalDriveN | -Device image-file)"
    Write-Host ""
    Write-Host "At least one of -Mbr and -Kernel must be given. Use Get-Disk to find the"
    Write-Host "disk number."
    Write-Host ""
    Write-Host "CAUTION: this writes directly to the disk. The wrong disk means immediate,"
    Write-Host "         unrecoverable data loss."
    exit 1
}

$IsPhysical = $Device.StartsWith('\\.\')

if ($IsPhysical) {
    $IsAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Host "Writing to a physical disk needs an elevated PowerShell session." -ForegroundColor Red
        Write-Host "Right-click PowerShell and choose 'Run as Administrator', then try again." -ForegroundColor Yellow
        exit 1
    }
}
else {
    # .NET resolves relative paths against the process directory, which is
    # not always PowerShell's current location.
    if (-not (Test-Path -LiteralPath $Device -PathType Leaf)) {
        Stop-WithError "$Device does not exist."
    }
    $Device = (Resolve-Path -LiteralPath $Device).ProviderPath
}

# ---------------------------------------------------------------------------
# 2. Check the files
# ---------------------------------------------------------------------------

$MbrBytes = $null
if ($Mbr) {
    if (-not (Test-Path -LiteralPath $Mbr -PathType Leaf)) { Stop-WithError "Cannot read $Mbr." }
    $MbrBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Mbr).ProviderPath)
    if ($MbrBytes.Length -lt 6 -or -not (Test-Magic $MbrBytes 'MBR')) {
        Stop-WithError "$Mbr does not begin with the 'MBR' signature. Is this the right file?"
    }
    if ($MbrBytes.Length -gt $MBR_CODE_SIZE) {
        Stop-WithError "$Mbr is $($MbrBytes.Length) bytes; the boot code area holds only $MBR_CODE_SIZE."
    }
}

$KernBytes = $null
$Total = 0
if ($Kernel) {
    if (-not (Test-Path -LiteralPath $Kernel -PathType Leaf)) { Stop-WithError "Cannot read $Kernel." }
    $KernBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Kernel).ProviderPath)
    if ($KernBytes.Length -lt ($KRNBOOT_SECTORS * $SECTOR_SIZE) -or -not (Test-Magic $KernBytes 'KRN')) {
        Stop-WithError ("$Kernel does not begin with the 'KRN' signature, or is smaller than " +
                        "$($KRNBOOT_SECTORS * $SECTOR_SIZE) bytes. Is this the right file?")
    }
    $Total = [int][Math]::Floor(($KernBytes.Length + $SECTOR_SIZE - 1) / $SECTOR_SIZE)
    $Vol   = $KernBytes[$KVOL_CNT_OFFSET] * 256 + $KernBytes[$KVOL_CNT_OFFSET + 1]
    $Nv    = $KernBytes[$KNV_CNT_OFFSET]  * 256 + $KernBytes[$KNV_CNT_OFFSET + 1]
    if ($Vol -eq 0 -or $Nv -eq 0 -or ($KRNBOOT_SECTORS + $Vol + $Nv) -ne $Total) {
        Stop-WithError ("${Kernel}: the header's sector counts (volatile $Vol, non-volatile $Nv) do not " +
                        "add up with the $KRNBOOT_SECTORS-sector bootstrap to the file's $Total sectors. " +
                        "Was it built by tools/split_kernel.py?")
    }
}

# ---------------------------------------------------------------------------
# 3. Open the disk and check it
# ---------------------------------------------------------------------------

$Stream = $null
$Failed = $false
try {
    try {
        # bufferSize 1 disables .NET's buffering, so every Write maps to one
        # sector-aligned WriteFile -- device handles reject unaligned writes.
        $Stream = New-Object System.IO.FileStream(
            $Device,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite,
            1,
            [System.IO.FileOptions]::WriteThrough)
    } catch {
        Stop-WithError "Cannot open ${Device}: $($_.Exception.InnerException.Message)"
    }

    $Old0 = Read-Sectors $Stream 0 1
    if ($null -eq $Old0) { Stop-WithError "Cannot read sector 0 of $Device." }

    $HasTable = ($Old0[510] -eq 0x55 -and $Old0[511] -eq 0xAA)

    if ($HasTable) {
        if ($Old0[0] -eq 0xEB -or $Old0[0] -eq 0xE9) {
            Stop-WithError ("Sector 0 of $Device is a FAT boot sector, not a partition table: the disk " +
                            "holds one volume with no partitions, and its FAT starts where the kernel " +
                            "would go. Nothing written. Partition the disk first (Format-ElfDosDisk.ps1).")
        }
        if ($KernBytes) {
            for ($i = 0; $i -lt 4; $i++) {
                $E = 446 + 16 * $i
                if ($Old0[$E + 4] -eq 0) { continue }
                $Start = [BitConverter]::ToUInt32($Old0, $E + 8)
                if ($Start -le $Total) {
                    Stop-WithError ("Partition $($i + 1) starts at LBA $Start, but the kernel needs LBA " +
                                    "1-$Total. Nothing written. Repartition the disk with the first " +
                                    "partition at LBA 2048 (Format-ElfDosDisk.ps1).")
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # 4. Confirm
    # -----------------------------------------------------------------------

    Write-Host "ELF-DOS installer"
    Write-Host "  Device : $Device"
    if ($Mbr)    { Write-Host "  MBR    : $Mbr" }
    if ($Kernel) { Write-Host "  Kernel : $Kernel" }
    Write-Host ""
    if (-not $HasTable) {
        Write-Host "Note: sector 0 of $Device has no partition table. The disk will not be"
        Write-Host "      usable until it is partitioned and formatted (Format-ElfDosDisk.ps1),"
        Write-Host "      and that erases the boot code, so this install must be repeated."
        Write-Host ""
    }

    if (-not $Force) {
        Write-Host "WARNING: This will write directly to $Device." -ForegroundColor Yellow
        $Ans = Read-Host "Proceed? [y/N]"
        if ($Ans -notmatch '^[yY]') {
            Write-Host "Aborted."
            exit 1
        }
        Write-Host ""
    }

    # -----------------------------------------------------------------------
    # 5. Write
    # -----------------------------------------------------------------------

    if ($MbrBytes) {
        Write-Host "--- Installing MBR ---"
        # Start from zeros, add the boot code, then the old table if there is one.
        $New0 = New-Object byte[] $SECTOR_SIZE
        [Array]::Copy($MbrBytes, 0, $New0, 0, $MbrBytes.Length)
        if ($HasTable) {
            Write-Host "  Partition table found; it is kept."
            [Array]::Copy($Old0, $MBR_CODE_SIZE, $New0, $MBR_CODE_SIZE, 64)
        } else {
            Write-Host "  No partition table; an empty one is written."
        }
        $New0[510] = 0x55; $New0[511] = 0xAA
        Write-Host "  Writing boot code ($($MbrBytes.Length) bytes)..."
        Write-AndVerify $Stream 0 $New0 'MBR'
        Write-Host "  MBR installed."
        Write-Host ""
    }

    if ($KernBytes) {
        Write-Host "--- Installing kernel ---"
        Write-Host "  File size    : $($KernBytes.Length) bytes"
        Write-Host "  Total sectors: $Total (bootstrap $KRNBOOT_SECTORS + volatile $Vol + non-volatile $Nv)"
        $Padded = New-Object byte[] ($Total * $SECTOR_SIZE)     # zero-filled
        [Array]::Copy($KernBytes, 0, $Padded, 0, $KernBytes.Length)
        Write-Host "  Writing LBA 1-$Total..."
        Write-AndVerify $Stream 1 $Padded 'kernel'
        Write-Host "  Kernel installed."
        Write-Host ""
    }
}
catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    $Failed = $true
}
finally {
    if ($Stream) { $Stream.Close() }
}

if ($Failed) {
    Write-Host "Installation FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "Done."
