#!/bin/bash
# Arch Linux - Setup /dev/sda as HarleyBox SSD dump drive
# EXT4, SSD optimized, nofail auto-mount
# WARNING: This will erase ALL data on /dev/sda

DRIVE="/dev/sda"
PART="${DRIVE}1"
MOUNTPOINT="/mnt/HarleyBox"
LABEL="HarleyBox"

echo "⚠ Target drive: $DRIVE"
read -r -p "This will erase all data on $DRIVE. Continue? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# 1️⃣ Unmount existing partitions
echo "Unmounting existing partitions on $DRIVE..."
sudo umount "${DRIVE}"?* 2>/dev/null || true

# 2️⃣ Create GPT partition table
echo "Creating GPT partition table on $DRIVE..."
sudo parted "$DRIVE" --script mklabel gpt

# 3️⃣ Create single partition
echo "Creating a single partition on $DRIVE..."
sudo parted -a optimal "$DRIVE" --script mkpart primary ext4 0% 100%

# 4️⃣ Format as EXT4 with SSD optimizations
echo "Formatting $PART as EXT4 (SSD optimized)..."
sudo mkfs.ext4 -F -L "$LABEL" -E stride=128,stripe-width=128 -O ^has_journal -m 0 "$PART"

# 5️⃣ Create mount point and mount
echo "Mounting $PART at $MOUNTPOINT..."
sudo mkdir -p "$MOUNTPOINT"
sudo mount -o rw,discard "$PART" "$MOUNTPOINT"

# 6️⃣ Add to /etc/fstab for auto-mount
FSTAB_ENTRY="LABEL=$LABEL  $MOUNTPOINT  ext4  defaults,nofail,discard  0 2"
if ! grep -Fq "$LABEL" /etc/fstab; then
    echo "Adding to /etc/fstab for auto-mount..."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
fi

echo "✅ HarleyBox setup complete!"
echo "📂 Mounted at $MOUNTPOINT, SSD optimized EXT4 (nofail in /etc/fstab)."
