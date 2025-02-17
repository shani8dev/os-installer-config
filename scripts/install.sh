#!/bin/bash
# install.sh – Disk partitioning, filesystem creation, and blue-green layout.
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

### Configuration
OS_NAME="shanios"
BUILD_VERSION="$(date +%Y%m%d)"
OSIDIR="/etc/os-installer"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
BTRFS_TOP_OPTS="defaults,noatime"
BTRFS_MOUNT_OPTS="defaults,noatime,compress=zstd,space_cache=v2,autodefrag"
ROOTFSZST_SOURCE="/run/archiso/bootmnt/arch/x86_64/rootfs.zst"
FLATPAKFS_SOURCE="/run/archiso/bootmnt/arch/x86_64/flatpakfs.zst"
SWAPFILE_REL_PATH="swap/swapfile"  # Under /deployment/data
SWAPFILE_SIZE=$(free -m | awk '/^Mem:/{printf "%dM", int($2 * 1.5)}')
BTRFS_TARGET=""

# Subvolume paths
DATA_SUBVOL="deployment/data"
SYSTEM_SUBVOL="deployment/system"
BLUE_SLOT="${SYSTEM_SUBVOL}/blue"
GREEN_SLOT="${SYSTEM_SUBVOL}/green"

echo "[SETUP] Starting disk setup..."

do_partitioning() {
  echo "[SETUP] Partitioning disk at $OSI_DEVICE_PATH"
  if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
    if [[ $OSI_DEVICE_PATH =~ nvme[0-9]n[0-9]$ ]]; then
      partition_prefix="${OSI_DEVICE_PATH}p"
    else
      partition_prefix="$OSI_DEVICE_PATH"
    fi
    sudo sfdisk "$OSI_DEVICE_PATH" < "$OSIDIR/bits/part.sfdisk" || { echo "Partitioning failed"; exit 1; }
    ROOT_PARTITION="${partition_prefix}2"
  else
    ROOT_PARTITION="$OSI_DEVICE_PATH"
  fi
}

create_filesystems() {
  echo "[SETUP] Creating FAT32 on EFI partition $OSI_DEVICE_EFI_PARTITION"
  sudo mkfs.fat -F32 "$OSI_DEVICE_EFI_PARTITION" -n "$BOOTLABEL" || { echo "FAT creation failed"; exit 1; }
  if [[ $OSI_USE_ENCRYPTION -eq 1 ]]; then
    echo "[SETUP] Setting up LUKS on $ROOT_PARTITION"
    echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup -q luksFormat "$ROOT_PARTITION" || exit 1
    echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup open "$ROOT_PARTITION" "$ROOTLABEL" || exit 1
    BTRFS_TARGET="/dev/mapper/$ROOTLABEL"
  else
    BTRFS_TARGET="$ROOT_PARTITION"
  fi
  echo "[SETUP] Creating Btrfs on $BTRFS_TARGET"
  sudo mkfs.btrfs -f -L "$ROOTLABEL" "$BTRFS_TARGET" || { echo "Btrfs creation failed"; exit 1; }
}

mount_top_level() {
  echo "[SETUP] Mounting Btrfs top-level on /mnt"
  sudo mount -o "$BTRFS_TOP_OPTS" "$BTRFS_TARGET" /mnt || { echo "Mounting failed"; exit 1; }
}

create_common_subvolumes() {
  local subs=("home" "etc-writable" "flatpak" "overlay" "downloads" "swap" "containers")
  sudo mkdir -p "/mnt/${DATA_SUBVOL}"
  for sub in "${subs[@]}"; do
    echo "[SETUP] Creating data subvolume: $sub"
    sudo btrfs subvolume create "/mnt/${DATA_SUBVOL}/$sub" || { echo "Creation of $sub failed"; exit 1; }
  done
}

extract_system_image() {
  echo "[SETUP] Extracting system image into blue slot (active)"
  sudo mkdir -p "/mnt/${SYSTEM_SUBVOL}"
  sudo zstdcat "$ROOTFSZST_SOURCE" | sudo btrfs receive "/mnt/${BLUE_SLOT}" || { echo "Extraction failed"; exit 1; }
  echo "blue" | sudo tee "/mnt/deployment/current-slot" || { echo "Failed to set active slot"; exit 1; }
}

receive_flatpak() {
  echo "[SETUP] Receiving Flatpak image into data/flatpak"
  sudo mkdir -p "/mnt/${DATA_SUBVOL}/flatpak"
  zstd -d --long -T0 "$FLATPAKFS_SOURCE" -c | sudo btrfs receive "/mnt/${DATA_SUBVOL}/flatpak" || { echo "Flatpak receiving failed"; exit 1; }
}

snapshot_blue_to_green() {
  echo "[SETUP] Creating snapshot of blue slot to initialize green slot"
  sudo btrfs subvolume snapshot "/mnt/${BLUE_SLOT}" "/mnt/${GREEN_SLOT}" || { echo "Snapshot failed"; exit 1; }
}

mount_boot_partition() {
  echo "[SETUP] Mounting EFI partition at /mnt/boot/efi"
  sudo mount --mkdir "$OSI_DEVICE_EFI_PARTITION" /mnt/boot/efi || { echo "EFI mount failed"; exit 1; }
}

create_swapfile() {
  echo "[SETUP] Creating Btrfs swapfile in data/swap"
  sudo mkdir -p "/mnt/${DATA_SUBVOL}/${SWAPFILE_REL_PATH%/*}"
  sudo btrfs filesystem mkswapfile --size "${SWAPFILE_SIZE}M" "/mnt/${DATA_SUBVOL}/${SWAPFILE_REL_PATH}" || { echo "Swapfile creation failed"; exit 1; }
  sudo swapon "/mnt/${DATA_SUBVOL}/${SWAPFILE_REL_PATH}" || { echo "Swap activation failed"; exit 1; }
}

do_setup() {
  do_partitioning
  create_filesystems
  mount_top_level
  create_common_subvolumes
  extract_system_image
  receive_flatpak
  snapshot_blue_to_green
  mount_boot_partition
  create_swapfile
  echo "[SETUP] Disk setup and blue-green configuration completed successfully!"
}

do_setup
