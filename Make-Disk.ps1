# Script to create custom primary MBR FAT16 partitions with input validation on Windows
# WARNING: This completely wipes the target drive!

# 1. Select the target disk number (Change this to your target disk, e.g., 1, 2)
$TargetDiskNumber = 2

# 2. Get the number of partitions from the user
while ($true) {
    $TotalParts = Read-Host "How many primary partitions do you want to create? (1-4)"
    if ($TotalParts -match '^[1-4]$') {
        $TotalParts = [int]$TotalParts
        break
    } else {
        Write-Host "Invalid choice. Please enter a number between 1 and 4." -ForegroundColor Red
    }
}

# 3. Completely wipe the disk and convert it to legacy MBR
Write-Host "Wiping disk $TargetDiskNumber and initializing as MBR..." -ForegroundColor Yellow
Clear-Disk -Number $TargetDiskNumber -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $TargetDiskNumber -PartitionStyle MBR

# 4. Loop to gather sizes and create the partitions
for ($i = 1; $i -le $TotalParts; $i++) {
    Write-Host "`n==============================================" -ForegroundColor Cyan
    Write-Host "Configuring Primary Partition #$i of $TotalParts" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan

    # If it is the last partition, let the user size it OR press Enter to use
    # whatever space is left on the disk.
    if ($i -eq $TotalParts) {
        while ($true) {
            $PartSizeStr = Read-Host "Enter size for the final partition $i in MB or GB (e.g., 500MB, 1GB. Max 2GB), or press Enter to use all remaining space"

            if ([string]::IsNullOrWhiteSpace($PartSizeStr)) {
                # Empty: create the partition using the rest of the disk
                Write-Host "Using all remaining space for partition $i." -ForegroundColor Green
                $Partition = New-Partition -DiskNumber $TargetDiskNumber -UseMaximumSize
                break
            }
            elseif ($PartSizeStr -match '^[0-9]+(MB|GB)$') {
                # Convert the text string (like "1GB") into actual computer bytes
                $SizeBytes = [Int64](Invoke-Expression $PartSizeStr)

                # FAT16 safeguard check (Max 2GB safely under Windows standard format rules)
                if ($SizeBytes -gt 2GB) {
                    Write-Host "❌ FAT16 partitions cannot be larger than 2GB on Windows. Try again." -ForegroundColor Red
                } else {
                    $Partition = New-Partition -DiskNumber $TargetDiskNumber -Size $SizeBytes
                    break
                }
            }
            else {
                Write-Host "❌ Invalid format. Please use a number followed by MB or GB (e.g., 500MB or 1GB), or press Enter for remaining space." -ForegroundColor Red
            }
        }
    }
    else {
        # Ask for size for earlier partitions and validate it
        while ($true) {
            $PartSizeStr = Read-Host "Enter size for partition $i in MB or GB (e.g., 500MB, 1GB. Max 2GB)"

            # Validation regex: matches a number followed by MB or GB (case-insensitive)
            if ($PartSizeStr -match '^[0-9]+(MB|GB)$') {
                # Convert the text string (like "1GB") into actual computer bytes
                $SizeBytes = [Int64](Invoke-Expression $PartSizeStr)

                # FAT16 safeguard check (Max 2GB safely under Windows standard format rules)
                if ($SizeBytes -gt 2GB) {
                    Write-Host "❌ FAT16 partitions cannot be larger than 2GB on Windows. Try again." -ForegroundColor Red
                } else {
                    break
                }
            } else {
                Write-Host "❌ Invalid format. Please use a number followed by MB or GB (e.g., 500MB or 1GB)." -ForegroundColor Red
            }
        }

        # Create the sized partition
        $Partition = New-Partition -DiskNumber $TargetDiskNumber -Size $SizeBytes
    }

    # 5. Format the partition immediately as FAT16
    Write-Host "Formatting partition $i as FAT16..." -ForegroundColor Yellow
    # Note: Windows labels FAT16 simply as "FAT" in the formatting command
    Format-Volume -Partition $Partition -FileSystem FAT -NewFileSystemLabel "FAT16_P$i" -Confirm:$false
}

Write-Host "`nDone! $TotalParts FAT16 partition(s) created and formatted successfully." -ForegroundColor Green
