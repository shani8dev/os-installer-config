#!/usr/bin/env bash

set -o pipefail

# Function to handle errors
quit_on_err() {
    echo "$1" >&2
    exit 1
}

# Constants and directories setup
rootlabel='shani_root'
bootlabel='shani_boot'
btrfs_options='defaults,noatime,compress=zstd'  # Btrfs options
rootfszst_source='/run/archiso/bootmnt/arch/x86_64/rootfs.zst'
squashfs_source='/run/archiso/bootmnt/arch/x86_64/flatpackfs.sfs'
overlaydir='/mnt/deployment/overlay'  # Overlay directory in /mnt
swapfile_size=$(free -m | awk '/^Mem:/{print $2}')  # Size of RAM in MB

# Sanity check for required variables
required_vars=(OSI_LOCALE OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_DEVICE_EFI_PARTITION OSI_USE_ENCRYPTION OSI_ENCRYPTION_PIN)
for var in "${required_vars[@]}"; do
    [[ -z ${!var+x} ]] && quit_on_err "$var not set"
done

# Check if something is already mounted to /mnt
mountpoint -q "/mnt" && quit_on_err "/mnt is already a mountpoint, unmount this directory and try again"

# Write partition table to the disk unless manual partitioning is used
if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
    sudo sfdisk "$OSI_DEVICE_PATH" < "$osidir/bits/part.sfdisk" || quit_on_err 'Failed to write partition table to disk'
fi

# Determine the partition path based on device type
partition_path="$OSI_DEVICE_PATH"
[[ $OSI_DEVICE_IS_PARTITION -eq 0 ]] && partition_path="${OSI_DEVICE_PATH}p"

# Create FAT filesystem on EFI partition
create_fat_filesystem() {
    sudo mkfs.fat -F32 "$1" -n "$bootlabel" || quit_on_err "Failed to create FAT filesystem on $1"
}

# Create LUKS partition
create_luks_partition() {
    echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup -q luksFormat "$1" || quit_on_err "Failed to create LUKS partition on $1"
    echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup open "$1" "$rootlabel" - || quit_on_err 'Failed to unlock LUKS partition'
}

# Create Btrfs filesystem
create_btrfs_filesystem() {
    sudo mkfs.btrfs -f -L "$rootlabel" "$1" || quit_on_err "Failed to create Btrfs partition on $1"
    sudo mount -o "$btrfs_options" "$1" "/mnt" || quit_on_err "Failed to mount Btrfs root partition to /mnt"
}

# Mount the boot partition
mount_boot_partition() {
    sudo mount --mkdir "$1" "/mnt/boot" || quit_on_err 'Failed to mount boot'
}

# Create a Btrfs swapfile with a specified size
create_btrfs_swapfile() {
    local swapfile_path="/mnt/swapfile"
    local swapfile_label="shani_swap"  # Change the label as needed

    # Create the swapfile of size equal to RAM size
    sudo fallocate -l "${swapfile_size}M" "$swapfile_path" || quit_on_err "Failed to create swapfile at $swapfile_path"

    # Enable CoW (Copy-on-Write) for the swapfile
    sudo chattr +C "$swapfile_path" || quit_on_err "Failed to enable CoW for swapfile"

    # Create the Btrfs swapfile with the specified label
    sudo btrfs filesystem mkswap -L "$swapfile_label" "$swapfile_path" || quit_on_err "Failed to create swap on $swapfile_path"

    # Enable the swap
    sudo swapon "$swapfile_path" || quit_on_err "Failed to enable swap on $swapfile_path"
    
    echo "Btrfs swapfile created and enabled at $swapfile_path with label $swapfile_label."
}

# Handle encryption and partitioning
if [[ $OSI_USE_ENCRYPTION -eq 1 ]]; then
    if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
        create_fat_filesystem "${partition_path}1"
        create_luks_partition "${partition_path}2"
    else
        create_fat_filesystem "$OSI_DEVICE_EFI_PARTITION"
        create_luks_partition "$OSI_DEVICE_PATH"
    fi
    create_btrfs_filesystem "/dev/mapper/$rootlabel"
else
    if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
        create_fat_filesystem "${partition_path}1"
        create_btrfs_filesystem "${partition_path}2"
    else
        create_fat_filesystem "$OSI_DEVICE_EFI_PARTITION"
        create_btrfs_filesystem "$OSI_DEVICE_PATH"
    fi
    mount_boot_partition "${partition_path}1"
fi

# Ensure partitions are mounted
for mountpoint in "/mnt" "/mnt/boot"; do
    mountpoint -q "$mountpoint" || quit_on_err "No volume mounted to $mountpoint"
done

# Create OverlayFS directories
sudo mkdir -p "$overlaydir/{work,upper}" || quit_on_err 'Failed to create OverlayFS directories'

# Create Btrfs subvolumes for writable directories
subvolumes=("deployment/shared/home" "deployment/shared/roota" "deployment/shared/rootb" "deployment/shared/flatpak" "deployment/shared/etc-writable" "deployment/shared/swapfile")
for subvolume in "${subvolumes[@]}"; do
    sudo btrfs subvolume create "/mnt/$subvolume" || quit_on_err "Failed to create $subvolume subvolume"
done

# Create the swapfile
create_btrfs_swapfile

############################################
# Extract the System Image and Flatpak FS
############################################

# --- Extract System Image ---
# The system image (*.zst) is extracted into the active root subvolume.
echo "Extracting system image from $rootzst_source to /mnt/deployment/shared/roota..."
sudo mkdir -p /mnt/deployment/shared/roota
sudo zstd -d < $rootzst_source | sudo btrfs receive /mnt/deployment/shared/roota || quit_on_err "Failed to extract system image"

# Unpack the flatpak filesystem from SquashFS into the subvolume
sudo unsquashfs -f -d "/mnt/deployment/shared/flatpak" "$squashfs_source" || quit_on_err "Failed to unpack $squashfs_source"

# Create a snapshot of roota as rootb after unsquashing
sudo btrfs subvolume snapshot "/mnt/deployment/shared/roota" "/mnt/deployment/shared/rootb" || quit_on_err "Failed to create snapshot of roota as rootb"

echo "Setup completed successfully!"

