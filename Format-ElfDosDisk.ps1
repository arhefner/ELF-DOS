<#
.SYNOPSIS
    Partitions and FAT16-formats a disk (typically an SD/CF card) for ELF-DOS.

.DESCRIPTION
    Creates an MBR with up to 4 primary FAT16 partitions and writes the FAT16
    structures (boot sector, FATs, root directory) for each one.

    WHY THIS DOESN'T USE Clear-Disk/New-Partition/Format-Volume
    -----------------------------------------------------------
    Windows reports most SD/CF card readers as "Removable Media". For such
    devices the partition manager insists on exactly one full-disk partition:
    Clear-Disk appears to succeed but leaves a full-disk partition behind,
    LargestFreeExtent always reads 0, and New-Partition fails with "Not enough
    available capacity" no matter how much room the card really has. Diskpart
    hits the same wall -- the restriction is enforced above those tools.

    So this script writes the MBR and the FAT16 structures directly to
    \\.\PhysicalDriveN, bypassing the partition manager entirely. That is the
    same thing Linux fdisk/mkfs.fat do, and the same raw-device approach
    sys/elfdos-sys.exe already uses successfully on Windows.

    LAYOUT
    ------
    LBA 0                        MBR (partition table written here; the boot
                                 code area is left zeroed for "sys -m")
    LBA 1 .. ReservedSectors-1   Reserved for krnboot (5 sectors) and the
                                 kernel image, which "sys -k" writes from
                                 LBA 1 upward. 2048 sectors (1 MB) is far more
                                 than the kernel needs and gives the first
                                 partition standard 1 MB alignment.
    LBA 2048 onward              Partition 1, then 2, 3, 4.

    Every partition is built so the cluster count lands in [4085, 65524]:
    below 4085 the volume would be FAT12, and 65525 or more is FAT32, which
    krnboot refuses (the drive would simply not appear).

.PARAMETER DiskNumber
    Physical disk number to format. Omit to pick from a list.

.PARAMETER ImagePath
    Write to a disk image file instead of a physical disk. Useful for building
    a card image for the run02 emulator. Needs -ImageSizeMB, and does not
    require Administrator.

.PARAMETER ImageSizeMB
    Total size of the image file, in MB. Only used with -ImagePath.

.PARAMETER SizeMB
    Size of each partition in MB, in order. Use 0 for "all remaining space"
    (only valid as the last entry). Omit to be prompted.

.PARAMETER Label
    Volume label for each partition (max 11 chars). Defaults to ELFDOS1..4.

.PARAMETER Force
    Skip the confirmation prompt. Also required to target a non-removable disk.

.EXAMPLE
    .\Format-ElfDosDisk.ps1
    Interactive: pick a disk, choose partition count and sizes.

.EXAMPLE
    .\Format-ElfDosDisk.ps1 -DiskNumber 2 -SizeMB 512,512,512,0
    Four partitions: three of 512 MB, the last taking the rest of the card.

.EXAMPLE
    .\Format-ElfDosDisk.ps1 -ImagePath card.img -ImageSizeMB 256 -SizeMB 64,0 -Force
    Build a 256 MB disk image with two partitions, no physical disk involved.

.NOTES
    Must be run from an elevated (Administrator) PowerShell session.
    After formatting, install the boot code and kernel with, e.g.:
        nmake /F Makefile.win install DEV=\\.\PhysicalDrive2
#>

[CmdletBinding()]
param(
    [int]      $DiskNumber = -1,
    [string]   $ImagePath,
    [int]      $ImageSizeMB,
    [int[]]    $SizeMB,
    [string[]] $Label,
    [switch]   $Force
)

$UseImage = -not [string]::IsNullOrWhiteSpace($ImagePath)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$SECTOR_SIZE      = 512
$RESERVED_SECTORS = 2048    # space before partition 1: MBR + krnboot + kernel
$MAX_PARTITIONS   = 4       # MBR primaries; also ELF-DOS's MBR_PART_COUNT
$PART_TYPE_FAT16  = 0x0E    # FAT16 LBA. Must be nonzero: MOUNT treats a zero
                            # type byte as "entry unused".
$ROOT_ENTRIES     = 512     # 32 sectors of root directory
$NUM_FATS         = 2
$RESERVED_SEC_CNT = 1       # sectors before the first FAT, within a partition
$MIN_CLUSTERS     = 4085    # below this the volume is FAT12
$MAX_CLUSTERS     = 65524   # 65525+ is FAT32, which krnboot refuses

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-FriendlySize([Int64]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "$Bytes bytes"
}

function Set-LE16([byte[]]$Buf, [int]$Offset, [int]$Value) {
    $Buf[$Offset]     = [byte]( $Value        -band 0xFF)
    $Buf[$Offset + 1] = [byte](($Value -shr 8) -band 0xFF)
}

function Set-LE32([byte[]]$Buf, [int]$Offset, [UInt32]$Value) {
    $Buf[$Offset]     = [byte]( $Value         -band 0xFF)
    $Buf[$Offset + 1] = [byte](($Value -shr 8)  -band 0xFF)
    $Buf[$Offset + 2] = [byte](($Value -shr 16) -band 0xFF)
    $Buf[$Offset + 3] = [byte](($Value -shr 24) -band 0xFF)
}

function Set-Ascii([byte[]]$Buf, [int]$Offset, [string]$Text, [int]$Length) {
    $Padded = $Text.PadRight($Length).Substring(0, $Length)
    $Bytes  = [System.Text.Encoding]::ASCII.GetBytes($Padded)
    [Array]::Copy($Bytes, 0, $Buf, $Offset, $Length)
}

# Classic 255-heads / 63-sectors geometry. ELF-DOS ignores CHS entirely (it
# reads the LBA fields), but real tools still look at it, so fill it in the
# way fdisk does -- including fdisk's 0xFE/0xFF/0xFF sentinel once the
# cylinder number exceeds what CHS can express.
function ConvertTo-Chs([UInt32]$Lba) {
    $HeadsPerCyl = 255
    $SecPerTrack = 63
    $PerCylinder = $HeadsPerCyl * $SecPerTrack

    $Cylinder = [Math]::Floor($Lba / $PerCylinder)
    $Rem      = $Lba % $PerCylinder
    $Head     = [Math]::Floor($Rem / $SecPerTrack)
    $Sector   = ($Rem % $SecPerTrack) + 1

    if ($Cylinder -gt 1023) { return [byte[]]@(0xFE, 0xFF, 0xFF) }

    return [byte[]]@(
        [byte]$Head,
        [byte]((([int]$Cylinder -shr 8) -shl 6) -bor [int]$Sector),
        [byte]([int]$Cylinder -band 0xFF)
    )
}

# Work out a FAT16 geometry for a partition of $TotalSectors sectors.
# Picks the smallest sectors-per-cluster that keeps the cluster count at or
# below 65524; returns $null if no power-of-two cluster size can produce a
# valid FAT16 volume (partition too small or too large).
function Get-Fat16Geometry([UInt32]$TotalSectors) {
    # [Math]::Ceiling, not [int](x + size - 1)/size -- PowerShell's [int] cast
    # ROUNDS rather than truncating, which turned 32.998 into 33 and made every
    # volume come out one cluster short of what the filesystem really has.
    $RootDirSectors = [int][Math]::Ceiling(($ROOT_ENTRIES * 32) / $SECTOR_SIZE)

    # Ascending, so the first cluster size that fits under the 65524-cluster
    # ceiling is also the smallest one that works. 128 (64 KB clusters) is
    # needed for a full 2 GB partition, and ELF-DOS handles it.
    foreach ($Spc in 1, 2, 4, 8, 16, 32, 64, 128) {
        # Sectors-per-FAT, per the Microsoft FAT specification.
        $TmpVal1 = $TotalSectors - ($RESERVED_SEC_CNT + $RootDirSectors)
        if ($TmpVal1 -le 0) { continue }
        $TmpVal2 = (256 * $Spc) + $NUM_FATS
        $FatSize = [int][Math]::Floor(($TmpVal1 + $TmpVal2 - 1) / $TmpVal2)
        if ($FatSize -le 0 -or $FatSize -gt 65535) { continue }

        $Overhead = $RESERVED_SEC_CNT + ($NUM_FATS * $FatSize) + $RootDirSectors
        if ($TotalSectors -le $Overhead) { continue }

        # This mirrors exactly how krnboot derives its own cluster count:
        #   count = (total_sectors - (data_lba - part1_lba)) >> spc_shift
        $Clusters = [int][Math]::Floor(($TotalSectors - $Overhead) / $Spc)

        if ($Clusters -gt $MAX_CLUSTERS) { continue }   # try a bigger cluster
        if ($Clusters -lt $MIN_CLUSTERS) { return $null } # too small for FAT16

        return [pscustomobject]@{
            SectorsPerCluster = $Spc
            SectorsPerFat     = $FatSize
            RootDirSectors    = $RootDirSectors
            ClusterCount      = $Clusters
            TotalSectors      = $TotalSectors
        }
    }
    return $null
}

function New-Fat16Vbr($Geometry, [UInt32]$StartLba, [string]$VolumeLabel) {
    $Vbr = New-Object byte[] $SECTOR_SIZE

    # Jump over the BPB. MOUNT specifically requires $EB or $E9 here as its
    # "this is a volume boot record, not a partition table" test.
    $Vbr[0] = 0xEB; $Vbr[1] = 0x3C; $Vbr[2] = 0x90
    Set-Ascii $Vbr 0x03 'MSWIN4.1' 8

    Set-LE16  $Vbr 0x0B $SECTOR_SIZE                        # bytes per sector
    $Vbr[0x0D] = [byte]$Geometry.SectorsPerCluster          # BPB_SPC
    Set-LE16  $Vbr 0x0E $RESERVED_SEC_CNT                   # BPB_RSVD
    $Vbr[0x10] = [byte]$NUM_FATS                            # BPB_NFAT
    Set-LE16  $Vbr 0x11 $ROOT_ENTRIES                       # BPB_ROOTENT

    # Total sectors goes in the 16-bit field when it fits, otherwise in the
    # 32-bit field with the 16-bit one zeroed -- krnboot reads $13 first and
    # falls back to $20 only when it is zero.
    if ($Geometry.TotalSectors -lt 65536) {
        Set-LE16 $Vbr 0x13 ([int]$Geometry.TotalSectors)
        Set-LE32 $Vbr 0x20 0
    } else {
        Set-LE16 $Vbr 0x13 0
        Set-LE32 $Vbr 0x20 $Geometry.TotalSectors
    }

    $Vbr[0x15] = 0xF8                                       # media: fixed disk
    Set-LE16  $Vbr 0x16 $Geometry.SectorsPerFat             # BPB_SPF
    Set-LE16  $Vbr 0x18 63                                  # sectors per track
    Set-LE16  $Vbr 0x1A 255                                 # heads
    Set-LE32  $Vbr 0x1C $StartLba                           # hidden sectors

    $Vbr[0x24] = 0x80                                       # drive number
    $Vbr[0x25] = 0x00
    $Vbr[0x26] = 0x29                                       # extended boot sig
    Set-LE32  $Vbr 0x27 ([UInt32](Get-Random -Minimum 1 -Maximum ([int]::MaxValue)))
    Set-Ascii $Vbr 0x2B $VolumeLabel.ToUpper() 11
    Set-Ascii $Vbr 0x36 'FAT16' 8

    $Vbr[510] = 0x55; $Vbr[511] = 0xAA
    return $Vbr
}

function New-VolumeLabelEntry([string]$VolumeLabel) {
    # A root-directory volume-label entry, so DIR (and Windows) show the name.
    # ELF-DOS's own LABEL command keeps this and the boot-sector copy in sync.
    $Entry = New-Object byte[] 32
    Set-Ascii $Entry 0 $VolumeLabel.ToUpper() 11
    $Entry[11] = 0x08                                       # ATTR_VOLUME_ID

    $Now  = Get-Date
    # Floor explicitly: FAT stores seconds in 2-second units, and PowerShell's
    # implicit double-to-int conversion would round instead of truncating.
    $Time = (($Now.Hour -shl 11) -bor ($Now.Minute -shl 5) -bor [int][Math]::Floor($Now.Second / 2))
    $Date = ((($Now.Year - 1980) -shl 9) -bor ($Now.Month -shl 5) -bor $Now.Day)
    Set-LE16 $Entry 22 $Time
    Set-LE16 $Entry 24 $Date
    return $Entry
}

function New-Mbr($Layout) {
    $Mbr = New-Object byte[] $SECTOR_SIZE

    # The 446-byte boot code area stays zeroed. "sys -m" fills it in later and
    # preserves the table below -- but only if the $55/$AA signature is
    # present, otherwise sys zeroes the table area, so it must be written.
    foreach ($Part in $Layout) {
        $Offset  = 0x1BE + (($Part.Index - 1) * 16)
        $ChsFrom = ConvertTo-Chs $Part.StartLba
        $ChsTo   = ConvertTo-Chs ([UInt32]($Part.StartLba + $Part.Sectors - 1))

        $BootFlag = if ($Part.Index -eq 1) { 0x80 } else { 0x00 }
        $Mbr[$Offset] = [byte]$BootFlag
        [Array]::Copy($ChsFrom, 0, $Mbr, $Offset + 1, 3)
        $Mbr[$Offset + 4] = [byte]$PART_TYPE_FAT16
        [Array]::Copy($ChsTo, 0, $Mbr, $Offset + 5, 3)
        Set-LE32 $Mbr ($Offset + 8)  $Part.StartLba
        Set-LE32 $Mbr ($Offset + 12) $Part.Sectors
    }

    $Mbr[510] = 0x55; $Mbr[511] = 0xAA
    return $Mbr
}

function Write-Sectors($Stream, [UInt32]$Lba, [byte[]]$Data) {
    $Stream.Position = [Int64]$Lba * $SECTOR_SIZE
    $Stream.Write($Data, 0, $Data.Length)
}

# Read a sector back and compare it against what we meant to write. Worth
# doing because the card may still have mounted volumes over the very sectors
# being written -- better to fail loudly than hand back a half-formatted card.
function Test-SectorMatches($Stream, [UInt32]$Lba, [byte[]]$Expected) {
    $Actual = New-Object byte[] $Expected.Length
    $Stream.Position = [Int64]$Lba * $SECTOR_SIZE
    $Got = 0
    while ($Got -lt $Expected.Length) {
        $N = $Stream.Read($Actual, $Got, $Expected.Length - $Got)
        if ($N -le 0) { return $false }
        $Got += $N
    }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) { return $false }
    }
    return $true
}

function Write-ZeroSectors($Stream, [UInt32]$Lba, [UInt32]$Count) {
    $ChunkSectors = 128                                     # 64 KB at a time
    $Chunk = New-Object byte[] ($ChunkSectors * $SECTOR_SIZE)
    $Stream.Position = [Int64]$Lba * $SECTOR_SIZE
    $Remaining = $Count
    while ($Remaining -gt 0) {
        $ThisPass = [Math]::Min($ChunkSectors, $Remaining)
        $Stream.Write($Chunk, 0, $ThisPass * $SECTOR_SIZE)
        $Remaining -= $ThisPass
    }
}

# Windows refuses raw writes to any sector owned by a MOUNTED volume, so the
# volumes on the target disk have to be dismounted first. Offlining the disk
# would do it, but removable media cannot be set offline -- so go a level down
# and lock/dismount each volume directly.
#
# The volume stays dismounted only while its handle is open, so the caller must
# hold the returned handles for the whole time it needs raw access.
function Dismount-DiskVolumes([int]$Number) {
    if (-not ('ElfDosVolume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ElfDosVolume
{
    const uint GENERIC_READ  = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ  = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint FSCTL_LOCK_VOLUME     = 0x00090018;
    const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf,
        uint inSize, IntPtr outBuf, uint outSize, out uint returned, IntPtr overlapped);

    public static SafeFileHandle LockAndDismount(string volume)
    {
        SafeFileHandle h = CreateFileW(volume, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h.IsInvalid)
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(), "could not open " + volume);

        uint n;
        // Locking is best effort: it fails if anything has a file open on the
        // volume, but a forced dismount still works, which is what we need.
        DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero);

        if (!DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out n, IntPtr.Zero))
        {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new System.ComponentModel.Win32Exception(err, "could not dismount " + volume);
        }
        return h;
    }
}
'@
    }

    $Handles = @()
    foreach ($Part in (Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)) {
        if (-not $Part.DriveLetter) { continue }
        $Vol = "\\.\$($Part.DriveLetter):"
        try {
            $Handles += [ElfDosVolume]::LockAndDismount($Vol)
            Write-Host "  dismounted $($Part.DriveLetter):" -ForegroundColor DarkGray
        } catch {
            Write-Host "  warning: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return ,$Handles
}

# ---------------------------------------------------------------------------
# 1. Work out the target: either a physical disk or an image file
# ---------------------------------------------------------------------------

if ($UseImage) {
    if ($ImageSizeMB -le 0) {
        Write-Host "-ImagePath needs -ImageSizeMB (total image size in MB)." -ForegroundColor Red
        exit 1
    }
    $DiskSizeSectors = [UInt32]($ImageSizeMB * 2048)
    $TargetName      = $ImagePath
    Write-Host "`nTarget: image file $ImagePath" -ForegroundColor Cyan
    Write-Host "        $(Format-FriendlySize ([Int64]$DiskSizeSectors * $SECTOR_SIZE)) total" -ForegroundColor Cyan
}
else {
    # Raw sector writes to a physical disk need Administrator.
    $IsAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $IsAdmin) {
        Write-Host "This script must be run from an elevated PowerShell session." -ForegroundColor Red
        Write-Host "Right-click PowerShell and choose 'Run as Administrator', then try again." -ForegroundColor Yellow
        exit 1
    }

    if ($DiskNumber -lt 0) {
        Write-Host "`nAvailable disks:" -ForegroundColor Cyan
        $AllDrives = Get-CimInstance Win32_DiskDrive
        Get-Disk | Sort-Object Number | ForEach-Object {
            $D     = $_
            $Media = ($AllDrives | Where-Object { $_.Index -eq $D.Number }).MediaType
            $Flag  = if ($D.IsBoot -or $D.IsSystem) { '  <-- SYSTEM DISK' } else { '' }
            "{0,4}  {1,-28} {2,-5} {3,10}  {4}{5}" -f `
                $D.Number, $D.FriendlyName, $D.BusType, (Format-FriendlySize $D.Size), $Media, $Flag
        } | Write-Host

        $DiskNumber = [int](Read-Host "`nEnter the disk number to format")
    }

    $Disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $Disk) {
        Write-Host "Disk $DiskNumber not found." -ForegroundColor Red
        exit 1
    }

    if (($Disk.IsBoot -or $Disk.IsSystem) -and -not $Force) {
        Write-Host "Disk $DiskNumber is the system/boot disk. Refusing to touch it." -ForegroundColor Red
        exit 1
    }

    $Drive = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $DiskNumber }
    $IsRemovable = $Drive -and $Drive.MediaType -like '*Removable*'
    if (-not $IsRemovable -and -not $Force) {
        Write-Host "Disk $DiskNumber is not removable media ($($Drive.MediaType))." -ForegroundColor Red
        Write-Host "Re-run with -Force if you really mean to format this disk." -ForegroundColor Yellow
        exit 1
    }

    $DiskSizeSectors = [UInt32]([Math]::Floor($Disk.Size / $SECTOR_SIZE))
    $TargetName      = "Disk $DiskNumber"

    Write-Host "`nTarget: Disk $DiskNumber -- $($Disk.FriendlyName)" -ForegroundColor Cyan
    Write-Host "        $(Format-FriendlySize $Disk.Size) total, $($Disk.BusType), $($Drive.MediaType)" -ForegroundColor Cyan
}

$UsableSectors = $DiskSizeSectors - $RESERVED_SECTORS
Write-Host "        $(Format-FriendlySize ([Int64]$UsableSectors * $SECTOR_SIZE)) usable for partitions" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 3. Choose the partition layout
# ---------------------------------------------------------------------------

if (-not $SizeMB -or $SizeMB.Count -eq 0) {
    while ($true) {
        $Answer = Read-Host "`nHow many partitions? (1-$MAX_PARTITIONS)"
        if ($Answer -match "^[1-$MAX_PARTITIONS]$") { $Count = [int]$Answer; break }
        Write-Host "Enter a number from 1 to $MAX_PARTITIONS." -ForegroundColor Red
    }

    $SizeMB = @()
    for ($i = 1; $i -le $Count; $i++) {
        $Prompt = if ($i -eq $Count) {
            "Size for partition $i in MB (or press Enter for all remaining space)"
        } else {
            "Size for partition $i in MB"
        }
        while ($true) {
            $Answer = Read-Host $Prompt
            if ([string]::IsNullOrWhiteSpace($Answer) -and $i -eq $Count) { $SizeMB += 0; break }
            if ($Answer -match '^[0-9]+$' -and [int]$Answer -gt 0) { $SizeMB += [int]$Answer; break }
            Write-Host "Enter a whole number of megabytes." -ForegroundColor Red
        }
    }
}

if ($SizeMB.Count -gt $MAX_PARTITIONS) {
    Write-Host "At most $MAX_PARTITIONS primary partitions are supported." -ForegroundColor Red
    exit 1
}

# Build the layout: 1 MB alignment, so every start LBA is a multiple of 2048.
$Layout  = @()
$NextLba = [UInt32]$RESERVED_SECTORS

for ($i = 0; $i -lt $SizeMB.Count; $i++) {
    $Requested = $SizeMB[$i]
    $Available = $DiskSizeSectors - $NextLba

    if ($Requested -eq 0) {
        if ($i -ne $SizeMB.Count - 1) {
            Write-Host "Only the last partition may use 'all remaining space'." -ForegroundColor Red
            exit 1
        }
        $Sectors = $Available
    } else {
        $Sectors = [UInt32]($Requested * 2048)      # 1 MB == 2048 sectors
    }

    if ($Sectors -gt $Available) {
        Write-Host ("Partition {0} needs {1} but only {2} is left on the disk." -f `
            ($i + 1),
            (Format-FriendlySize ([Int64]$Sectors * $SECTOR_SIZE)),
            (Format-FriendlySize ([Int64]$Available * $SECTOR_SIZE))) -ForegroundColor Red
        exit 1
    }

    # ELF-DOS reads a partition's start LBA as a 24-bit value, so everything
    # must live below the 8 GB mark.
    if (([Int64]$NextLba + $Sectors) -gt 0xFFFFFF) {
        Write-Host "Partition $($i + 1) would extend past the 8 GB limit ELF-DOS can address." -ForegroundColor Red
        exit 1
    }

    $Geometry = Get-Fat16Geometry $Sectors
    if (-not $Geometry) {
        Write-Host ("Partition {0} ({1}) cannot be formatted as FAT16." -f `
            ($i + 1), (Format-FriendlySize ([Int64]$Sectors * $SECTOR_SIZE))) -ForegroundColor Red
        Write-Host "FAT16 needs between about 2 MB and 2 GB per partition." -ForegroundColor Yellow
        exit 1
    }

    $ThisLabel = if ($Label -and $Label.Count -gt $i) { $Label[$i] } else { "ELFDOS$($i + 1)" }

    $Layout += [pscustomobject]@{
        Index    = $i + 1
        StartLba = $NextLba
        Sectors  = $Sectors
        Label    = $ThisLabel
        Geometry = $Geometry
    }

    $NextLba += $Sectors
}

Write-Host "`nPlanned layout:" -ForegroundColor Cyan
$Layout | ForEach-Object {
    "  {0}. {1,-10} start LBA {2,-9} {3,10}  {4} sectors/cluster, {5} clusters" -f `
        $_.Index, $_.Label, $_.StartLba,
        (Format-FriendlySize ([Int64]$_.Sectors * $SECTOR_SIZE)),
        $_.Geometry.SectorsPerCluster, $_.Geometry.ClusterCount
} | Write-Host

# A partition over 2 GB needs 64 KB clusters to stay under FAT16's 65524-cluster
# ceiling. ELF-DOS reads that fine, but Windows will not create such a volume
# and may refuse to mount one -- which matters, because mounting it in Windows
# is how files get copied onto the card.
$BigOnes = $Layout | Where-Object { $_.Geometry.SectorsPerCluster -gt 64 }
if ($BigOnes) {
    Write-Host "`nNote: partition(s) $(($BigOnes.Index) -join ', ') use 64 KB clusters because they exceed 2 GB." -ForegroundColor Yellow
    Write-Host "ELF-DOS handles that, but Windows may not mount them, which would stop you" -ForegroundColor Yellow
    Write-Host "copying files onto them from here. Keep partitions at 2 GB or under to avoid it." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4. Confirm
# ---------------------------------------------------------------------------

if (-not $Force) {
    Write-Host "`nEVERYTHING on $TargetName will be destroyed." -ForegroundColor Yellow
    if ((Read-Host "Type YES to continue") -ne 'YES') {
        Write-Host "Aborted -- no changes made." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------------
# 5. Write it
# ---------------------------------------------------------------------------

# Windows blocks raw writes to sectors owned by a mounted volume on a FIXED
# disk, so those get taken offline first to dismount everything.
#
# Removable media is a different story: Windows refuses outright ("Removable
# media cannot be set to offline"), and it turns out not to need it -- raw
# writes to \\.\PhysicalDriveN go through regardless (confirmed on hardware
# 2026-09-12 against an SD card that already held a full-disk FAT16 volume).
# So don't even try, rather than printing an alarming error for nothing.
$WentOffline = $false
if (-not $UseImage -and -not $IsRemovable) {
    try {
        Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
        $WentOffline = $true
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Host "Could not take the disk offline: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Continuing anyway; if writes are refused, close anything using the disk." -ForegroundColor Yellow
    }
}

# Dismount any mounted volumes on the target. Without this, every write that
# lands inside an existing partition is refused with "Access is denied" -- and
# the MBR write at sector 0 still succeeds, so the failure shows up midway.
# These handles must stay open until all the writing is done.
$VolumeHandles = @()
if (-not $UseImage) {
    Write-Host "`nDismounting volumes on disk $DiskNumber..." -ForegroundColor Yellow
    $VolumeHandles = Dismount-DiskVolumes $DiskNumber
    if ($VolumeHandles.Count -eq 0) {
        Write-Host "  (none were mounted)" -ForegroundColor DarkGray
    }
}

$DevicePath = if ($UseImage) { $ImagePath } else { "\\.\PhysicalDrive$DiskNumber" }
$Stream = $null

try {
    # bufferSize 1 disables .NET's buffering, so every Write maps to one
    # sector-aligned WriteFile -- device handles reject unaligned writes.
    $Mode = if ($UseImage) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::Open }
    $Stream = New-Object System.IO.FileStream(
        $DevicePath,
        $Mode,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite,
        1,
        [System.IO.FileOptions]::WriteThrough)

    if ($UseImage) {
        # Size the file up front so seeks behave the way they do on a device.
        # NTFS does this without actually writing the zeros.
        $Stream.SetLength([Int64]$DiskSizeSectors * $SECTOR_SIZE)
    }

    # ---- MBR ----
    Write-Host "`nWriting MBR..." -ForegroundColor Yellow
    $Mbr = New-Mbr $Layout
    Write-Sectors $Stream 0 $Mbr
    $Stream.Flush()
    if (-not (Test-SectorMatches $Stream 0 $Mbr)) {
        throw "The MBR did not read back as written -- the disk rejected the write."
    }

    # Clear the rest of the reserved area so no stale kernel image is left
    # behind for "sys" to be confused by.
    Write-ZeroSectors $Stream 1 ([UInt32]($RESERVED_SECTORS - 1))

    # ---- Each partition ----
    foreach ($Part in $Layout) {
        $Geo = $Part.Geometry
        Write-Host ("Formatting partition {0} ({1}, {2})..." -f `
            $Part.Index, $Part.Label,
            (Format-FriendlySize ([Int64]$Part.Sectors * $SECTOR_SIZE))) -ForegroundColor Yellow

        $Fat1Lba = $Part.StartLba + $RESERVED_SEC_CNT
        $Fat2Lba = $Fat1Lba + $Geo.SectorsPerFat
        $RootLba = $Fat1Lba + ($NUM_FATS * $Geo.SectorsPerFat)

        # Boot sector
        $Vbr = New-Fat16Vbr $Geo $Part.StartLba $Part.Label
        Write-Sectors $Stream $Part.StartLba $Vbr
        $Stream.Flush()
        if (-not (Test-SectorMatches $Stream $Part.StartLba $Vbr)) {
            throw ("Partition $($Part.Index)'s boot sector did not read back as written. " +
                   "Windows may still have a volume mounted over it -- eject the card, " +
                   "reinsert it, and run this again without opening it in Explorer.")
        }

        # Both FATs: zeroed, then entries 0 and 1 seeded in the first sector.
        # FAT[0] = 0xFFF8 (media descriptor), FAT[1] = 0xFFFF (end of chain).
        Write-ZeroSectors $Stream $Fat1Lba ([UInt32]($NUM_FATS * $Geo.SectorsPerFat))
        $FatHead = New-Object byte[] $SECTOR_SIZE
        Set-LE16 $FatHead 0 0xFFF8
        Set-LE16 $FatHead 2 0xFFFF
        Write-Sectors $Stream $Fat1Lba $FatHead
        Write-Sectors $Stream $Fat2Lba $FatHead

        # Root directory: zeroed, with a volume-label entry in the first slot.
        Write-ZeroSectors $Stream $RootLba ([UInt32]$Geo.RootDirSectors)
        $RootHead = New-Object byte[] $SECTOR_SIZE
        [Array]::Copy((New-VolumeLabelEntry $Part.Label), 0, $RootHead, 0, 32)
        Write-Sectors $Stream $RootLba $RootHead
    }

    $Stream.Flush()
    Write-Host "All structures written." -ForegroundColor Green
}
catch {
    Write-Host "`nFailed while writing to $DevicePath :" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nAn 'Access is denied' here means Windows still had a volume mounted over" -ForegroundColor Yellow
    Write-Host "those sectors. Close any Explorer window showing the card, then either" -ForegroundColor Yellow
    Write-Host "re-run this, or eject and reinsert the card first." -ForegroundColor Yellow
    if ($Stream) { $Stream.Dispose(); $Stream = $null }
    foreach ($H in $VolumeHandles) { $H.Dispose() }
    if ($WentOffline) { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue }
    exit 1
}
finally {
    if ($Stream) { $Stream.Dispose() }
    # Releasing these lets Windows remount and pick up the new layout.
    foreach ($H in $VolumeHandles) { $H.Dispose() }
}

# ---------------------------------------------------------------------------
# 6. Bring the disk back and report
# ---------------------------------------------------------------------------

if ($UseImage) {
    Write-Host "`nDone. $ImagePath now has $($Layout.Count) FAT16 partition(s)." -ForegroundColor Green
    exit 0
}

if ($WentOffline) {
    Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
}
Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "`nDone. Disk $DiskNumber now has $($Layout.Count) FAT16 partition(s)." -ForegroundColor Green

$Volumes = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
           Where-Object { $_.Size -gt 0 }
if ($Volumes) {
    Write-Host "`nWindows sees:" -ForegroundColor Cyan
    $Volumes | ForEach-Object {
        $Letter = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { '(no letter)' }
        "  Partition {0}  {1,-12} {2}" -f $_.PartitionNumber, $Letter, (Format-FriendlySize $_.Size)
    } | Write-Host
}

$FirstLetter = ($Volumes | Sort-Object PartitionNumber | Select-Object -First 1).DriveLetter

Write-Host "`nNext step -- install the boot code and kernel:" -ForegroundColor Cyan
Write-Host "  nmake /F Makefile.win install DEV=$DevicePath" -ForegroundColor White
if ($FirstLetter) {
    Write-Host "`nthen copy the programs onto the first partition:" -ForegroundColor Cyan
    Write-Host "  mkdir ${FirstLetter}:\BIN" -ForegroundColor White
    Write-Host "  copy bin\* ${FirstLetter}:\BIN" -ForegroundColor White
} else {
    Write-Host "then copy bin\* to the \BIN directory of the first partition." -ForegroundColor Cyan
}
