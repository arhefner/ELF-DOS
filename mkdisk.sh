#!/bin/bash
# Script to create custom primary FAT16 partitions with input validation
# WARNING: This completely wipes the target drive!

TARGET_DISK="/dev/mmcblk0"  # Change this to your target drive

# 1. Automatically check if the disk needs a "p" before the partition number
if [[ "$TARGET_DISK" =~ "nvme" || "$TARGET_DISK" =~ "mmcblk" ]]; then
    PART_PREFIX="${TARGET_DISK}p"
else
    PART_PREFIX="${TARGET_DISK}"
fi

# 2. Ask the user how many partitions they want to create
while true; do
    echo "How many primary partitions do you want to create? (1-4):"
    read -r TOTAL_PARTS
    if [[ "$TOTAL_PARTS" =~ ^[1-4]$ ]]; then
        break
    else
        echo "Invalid choice. Please enter a number between 1 and 4."
    fi
done

# 3. Initialize the fdisk command string by wiping the disk ('o' creates a new MBR)
FDISK_COMMANDS="o"

# 4. Loop to gather sizes and build the fdisk commands
for ((i=1; i<=TOTAL_PARTS; i++))
do
    echo "=============================================="
    echo "Configuring Primary Partition #$i of $TOTAL_PARTS"
    echo "=============================================="

    # If it is the last partition, let the user size it OR press Enter to use
    # whatever space is left on the disk.
    if [ "$i" -eq "$TOTAL_PARTS" ]; then
        while true; do
            echo "Enter size for the final partition $i (e.g., 500M, 1G), or press Enter to use all remaining space:"
            read -r PART_SIZE

            if [ -z "$PART_SIZE" ]; then
                echo "Partition $i will use all remaining space."
                SIZE_ARG=""          # blank last sector = rest of the disk
                break
            elif [[ "$PART_SIZE" =~ ^[0-9]+[kKmMgGtT]$ ]]; then
                PART_SIZE=$(echo "$PART_SIZE" | tr '[:lower:]' '[:upper:]')
                SIZE_ARG="+$PART_SIZE"
                break
            else
                echo "❌ Invalid format. Use a number followed by K, M, G or T (e.g., 500M or 1G), or press Enter for remaining space."
            fi
        done

        # Blank first sector (default), then either +size or a blank last
        # sector (fdisk defaults that to the end of the disk).
        FDISK_COMMANDS="${FDISK_COMMANDS}
n
p
$i

$SIZE_ARG
t
$i
6"
    else
        # Ask for sizes for the earlier partitions and validate the input
        while true; do
            echo "Enter size for partition $i (e.g., 500M, 1G, 256m):"
            read -r PART_SIZE

            # Validation regex: matches numbers followed by K, M, G (case-insensitive)
            if [[ "$PART_SIZE" =~ ^[0-9]+[kKmMgGtT]$ ]]; then
                # Convert the size string to uppercase so fdisk understands it perfectly
                PART_SIZE=$(echo "$PART_SIZE" | tr '[:lower:]' '[:upper:]')
                break
            else
                echo "❌ Invalid format. Please use a number followed by M or G (e.g., 500M or 1G)."
            fi
        done

        # Build the fdisk keystrokes for a sized partition
        FDISK_COMMANDS="${FDISK_COMMANDS}
n
p
$i

+$PART_SIZE
t
$i
6"
    fi
done

# Add the final write command to save the layout changes
FDISK_COMMANDS="${FDISK_COMMANDS}
w"

# 5. Run fdisk using a Here Document
echo "Applying partition table to $TARGET_DISK..."
fdisk -u=sectors -c=dos "$TARGET_DISK" <<EOF
$FDISK_COMMANDS
EOF

# 6. Format only the partitions that were actually created
echo "Formatting partitions..."
for ((i=1; i<=TOTAL_PARTS; i++))
do
    mkfs.vfat -F 16 "${PART_PREFIX}$i"
done

echo "Done! $TOTAL_PARTS FAT16 partition(s) created and formatted successfully."
