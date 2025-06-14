#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <qcow2-image-path>"
    exit 1
fi

QCOW2_IMAGE="$1"
MOUNT_DIR="/mnt/qcow2_mount"

# Ensure nbd module is loaded
if ! lsmod | grep -q nbd; then
    sudo modprobe nbd max_part=8
fi

# Connect the qcow2 image to the first available network block device
sudo qemu-nbd --connect=/dev/nbd0 "$QCOW2_IMAGE"

# Give the system some time to mount
sleep 2

# List partitions
sudo fdisk -l /dev/nbd0

echo "Enter the partition number to mount (e.g., 1 for /dev/nbd0p1):"
read PARTITION_NUMBER
PARTITION="/dev/nbd0p$PARTITION_NUMBER"

# Create mount directory if not exists
sudo mkdir -p "$MOUNT_DIR"

# Mount the partition
sudo mount "$PARTITION" "$MOUNT_DIR"
echo "Partition mounted at $MOUNT_DIR"

echo "Press any key to unmount and disconnect..."
read -n 1 -s

# Unmount and disconnect
sudo umount "$MOUNT_DIR"
sudo qemu-nbd --disconnect /dev/nbd0
sudo rmdir "$MOUNT_DIR"

echo "Unmounted and disconnected."

