#!/bin/bash
# install.sh – Disk partitioning, filesystem creation, and blue–green layout.
# This script partitions the disk, creates filesystems, and sets up a dual-root
# immutable system using Btrfs with a blue–green deployment strategy.
#
# When OSI_DEVICE_IS_PARTITION=0 (whole device), the EFI partition is derived from the
# partition layout file (assumed to be partition 1). When OSI_DEVICE_IS_PARTITION=1 (a partition),
# you must supply OSI_DEVICE_EFI_PARTITION, and it is used later.
#
# Expected environment variables:
#   OSI_DEVICE_PATH        – Path to the device (e.g. /dev/sda or /dev/nvme0n1)
#   OSI_DEVICE_IS_PARTITION – 0 if whole device, 1 if a partition is selected
#   OSI_DEVICE_EFI_PARTITION – Required only if OSI_DEVICE_IS_PARTITION=1; the EFI partition path.
#   OSI_USE_ENCRYPTION     – 1 to enable encryption, 0 otherwise.
#   OSI_ENCRYPTION_PIN     – (Optional) PIN for encryption (if not provided, keyfile will be generated)
#
# The PART_LAYOUT file is expected at: ${OSIDIR}/bits/part.sfdisk

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[INSTALL][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# Logging functions
log_info() { echo "[INSTALL][INFO] $*"; }
log_warn() { echo "[INSTALL][WARN] $*" >&2; }
log_error() { echo "[INSTALL][ERROR] $*" >&2; }

# Validate required commands.
for cmd in sudo sfdisk mkfs.fat cryptsetup mkfs.btrfs mount btrfs zstd swapon free awk; do
  command -v "$cmd" &>/dev/null || { log_error "Required command '$cmd' not found."; exit 1; }
done

# Environment check: OSI_DEVICE_EFI_PARTITION is required only when OSI_DEVICE_IS_PARTITION is 1.
check_env() {
  local missing_vars=()
  local required_vars=(OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_USE_ENCRYPTION)
  if [ "${OSI_DEVICE_IS_PARTITION:-0}" -eq 1 ]; then
    required_vars+=(OSI_DEVICE_EFI_PARTITION)
  fi
  for var in "${required_vars[@]}"; do
    [ -z "${!var:-}" ] && missing_vars+=("$var")
  done
  if [ "${OSI_USE_ENCRYPTION:-0}" -eq 1 ] && [ -z "${OSI_ENCRYPTION_PIN:-}" ]; then
    log_info "No OSI_ENCRYPTION_PIN provided; keyfile-based unlocking will be used."
  fi
  if [ ${#missing_vars[@]} -gt 0 ]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    exit 1
  fi
}
check_env

### Configuration variables
OS_NAME="shanios"
OSIDIR="/etc/os-installer"
PART_LAYOUT="${OSIDIR}/bits/part.sfdisk"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
BTRFS_TOP_OPTS="defaults,noatime,compress=zstd,space_cache=v2,autodefrag"

# Source image paths (Btrfs send streams)
ROOTFSZST_SOURCE="/run/archiso/bootmnt/${OS_NAME}/x86_64/rootfs.zst"
FLATPAKFS_SOURCE="/run/archiso/bootmnt/${OS_NAME}/x86_64/flatpakfs.zst"

SWAPFILE_PATH="@swap/swapfile"  # Under the @swap subvolume
# Calculate swapfile size equal to total RAM (in MB)
SWAPFILE_SIZE=$(free -m | awk '/^Mem:/{print $2}')

# Pre-check critical files
[[ ! -f "${PART_LAYOUT}" ]] && { log_error "Partition layout file not found at ${PART_LAYOUT}"; exit 1; }
[[ ! -f "${ROOTFSZST_SOURCE}" ]] && { log_error "System image not found at ${ROOTFSZST_SOURCE}"; exit 1; }
[[ ! -f "${FLATPAKFS_SOURCE}" ]] && { log_error "Flatpak image not found at ${FLATPAKFS_SOURCE}"; exit 1; }

# Function: get_partition_prefix
# Appends "p" to OSI_DEVICE_PATH if it is an NVMe or MMC/eMMC device.
get_partition_prefix() {
  if [[ "${OSI_DEVICE_PATH}" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]] || [[ "${OSI_DEVICE_PATH}" =~ ^/dev/mmcblk[0-9]+$ ]]; then
    echo "${OSI_DEVICE_PATH}p"
  else
    echo "${OSI_DEVICE_PATH}"
  fi
}

# Determine partition prefix if applicable.
if [[ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]]; then
  PARTITION_PREFIX=$(get_partition_prefix)
else
  PARTITION_PREFIX=""
fi

# Function: do_partitioning
do_partitioning() {
  log_info "Setting ${OSI_DEVICE_PATH} to read-write mode."
  sudo blockdev --setrw "${OSI_DEVICE_PATH}" || { log_warn "Could not force device to read-write mode; proceeding anyway."; }
  
  if [[ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]]; then
    log_info "Partitioning whole device ${OSI_DEVICE_PATH}"
    sudo sfdisk "${OSI_DEVICE_PATH}" < "${PART_LAYOUT}" || { log_error "Disk partitioning failed"; exit 1; }
    # Derive partitions from layout: Partition 1 is EFI, Partition 2 is root.
    EFI_PARTITION="${PARTITION_PREFIX}1"
    ROOT_PARTITION="${PARTITION_PREFIX}2"
  else
    log_info "Using pre-partitioned device. Using OSI_DEVICE_EFI_PARTITION for EFI and OSI_DEVICE_PATH for root."
    EFI_PARTITION="${OSI_DEVICE_EFI_PARTITION}"
    ROOT_PARTITION="${OSI_DEVICE_PATH}"
  fi
  log_info "EFI partition set to ${EFI_PARTITION}"
  log_info "Root partition set to ${ROOT_PARTITION}"
}

# Function: mount_boot_partition
mount_boot_partition() {
  log_info "Mounting EFI partition (${EFI_PARTITION}) at /mnt/boot/efi"
  sudo mount --mkdir /dev/disk/by-label/"${BOOTLABEL}" /mnt/boot/efi \
    || { log_error "EFI partition mount failed"; exit 1; }
}

# Function: create_filesystems
create_filesystems() {
  # Format and mount the EFI partition (if provided)
  if [ -n "${EFI_PARTITION:-}" ]; then
    log_info "Formatting EFI partition (${EFI_PARTITION}) as FAT32 with label ${BOOTLABEL}"
    sudo mkfs.fat -F32 "${EFI_PARTITION}" -n "${BOOTLABEL}" || { log_error "EFI partition formatting failed"; exit 1; }
    mount_boot_partition
  else
    log_info "No EFI partition provided; skipping EFI partition formatting."
  fi

  # Set up encryption if requested.
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    if [ -n "${OSI_ENCRYPTION_PIN:-}" ]; then
      log_info "Setting up LUKS encryption on ${ROOT_PARTITION} using provided encryption PIN"
      echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup -q luksFormat "${ROOT_PARTITION}" || exit 1
      echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup open "${ROOT_PARTITION}" "${ROOTLABEL}" || exit 1
    else
      if [ -n "${EFI_PARTITION:-}" ]; then
        log_info "No encryption PIN provided; generating keyfile in EFI partition"
        sudo dd if=/dev/urandom of=/mnt/boot/efi/crypto_keyfile.bin bs=4096 count=1
        sudo chmod 0400 /mnt/boot/efi/crypto_keyfile.bin
        sudo cryptsetup -q luksFormat "${ROOT_PARTITION}" --key-file /mnt/boot/efi/crypto_keyfile.bin
        sudo cryptsetup open "${ROOT_PARTITION}" "${ROOTLABEL}" --key-file /mnt/boot/efi/crypto_keyfile.bin
        export OSI_KEYFILE="/boot/efi/crypto_keyfile.bin"
      else
        log_error "Encryption PIN not provided and no EFI partition available for keyfile generation."
        exit 1
      fi
    fi
    BTRFS_TARGET="/dev/mapper/${ROOTLABEL}"
  else
    BTRFS_TARGET="${ROOT_PARTITION}"
  fi
  log_info "Creating Btrfs filesystem on ${BTRFS_TARGET} with label ${ROOTLABEL}"
  sudo mkfs.btrfs -f -L "${ROOTLABEL}" "${BTRFS_TARGET}" || { log_error "Btrfs filesystem creation failed"; exit 1; }
}

# Function: mount_top_level
mount_top_level() {
  log_info "Mounting Btrfs top-level filesystem on /mnt"
  sudo mount -o "${BTRFS_TOP_OPTS}" "${BTRFS_TARGET}" /mnt || { log_error "Mounting top-level filesystem failed"; exit 1; }
}

# Function: create_subvolumes
create_subvolumes() {
  log_info "Creating required Btrfs subvolumes and directories"
  local subvolumes=( "@home" "@data" "@cache" "@log" "@containers" "@swap" )
  for subvol in "${subvolumes[@]}"; do
    if ! sudo btrfs subvolume list /mnt | grep -q "path ${subvol}\$"; then
      log_info "Creating subvolume ${subvol}"
      sudo btrfs subvolume create "/mnt/${subvol}" || { log_error "Failed to create subvolume ${subvol}"; exit 1; }
    else
      log_info "Subvolume ${subvol} already exists"
    fi
  done

  local data_dirs=( "overlay/etc/lower" "overlay/etc/upper" "overlay/etc/work" "overlay/var/lower" "overlay/var/upper" "overlay/var/work" "downloads" )
  for dir in "${data_dirs[@]}"; do
    local full_dir="/mnt/@data/${dir}"
    if [ ! -d "${full_dir}" ]; then
      log_info "Creating directory ${full_dir}"
      sudo mkdir -p "${full_dir}" || { log_error "Failed to create directory ${full_dir}"; exit 1; }
    else
      log_info "Directory ${full_dir} already exists"
    fi
  done
}

# Function: extract_system_image
extract_system_image() {
  log_info "Extracting system image into /mnt"
  extract_image "${ROOTFSZST_SOURCE}" "/mnt"
  if sudo btrfs subvolume show "/mnt/shanios_base" &>/dev/null; then
    log_info "Subvolume 'shanios_base' detected"
  else
    log_error "Subvolume 'shanios_base' not found after extraction"
    exit 1
  fi
  log_info "Creating snapshot @blue from shanios_base"
  sudo btrfs subvolume snapshot -r "/mnt/shanios_base" "/mnt/@blue" || { log_error "Snapshot creation for @blue failed"; exit 1; }
  log_info "Creating snapshot @green from @blue"
  sudo btrfs subvolume snapshot -r "/mnt/@blue" "/mnt/@green" || { log_error "Snapshot creation for @green failed"; exit 1; }
  log_info "Deleting original subvolume shanios_base"
  sudo btrfs subvolume delete "/mnt/shanios_base" || log_warn "Could not delete shanios_base; please remove manually later"
  log_info "Setting active slot marker to 'blue'"
  echo "blue" | sudo tee "/mnt/@data/current-slot" > /dev/null || { log_error "Failed to set active slot marker"; exit 1; }
}

# Function: extract_flatpak_image
extract_flatpak_image() {
  log_info "Extracting Flatpak image into /mnt"
  extract_image "${FLATPAKFS_SOURCE}" "/mnt"
  if sudo btrfs subvolume show "/mnt/flatpak_subvol" &>/dev/null; then
    log_info "Subvolume 'flatpak_subvol' detected"
  else
    log_error "Subvolume 'flatpak_subvol' not found after extraction"
    exit 1
  fi
  log_info "Creating snapshot @flatpak from flatpak_subvol"
  sudo btrfs subvolume snapshot "/mnt/flatpak_subvol" "/mnt/@flatpak" || { log_error "Snapshot creation for @flatpak failed"; exit 1; }
  log_info "Deleting original subvolume flatpak_subvol"
  sudo btrfs subvolume delete "/mnt/flatpak_subvol" || log_warn "Could not delete flatpak_subvol; please remove manually later"
}

# Function: create_swapfile
create_swapfile() {
  log_info "Creating swapfile at /mnt/@swap/swapfile"
  sudo btrfs filesystem mkswapfile --size "${SWAPFILE_SIZE}M" "/mnt/@swap/swapfile" || { log_error "Swapfile creation failed"; exit 1; }
  sudo swapon "/mnt/@swap/swapfile" || { log_error "Swapfile activation failed"; exit 1; }
}

# Main setup function
do_setup() {
  do_partitioning
  create_filesystems
  mount_top_level
  create_subvolumes
  extract_system_image
  extract_flatpak_image
  create_swapfile

  log_info "Syncing data to disk..."
  sync

  log_info "Installation complete: Disk setup and blue-green configuration finished."
  log_info "IMPORTANT: Update /mnt/etc/fstab and configure your bootloader."
}

do_setup

