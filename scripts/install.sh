#!/bin/bash
# install.sh – Disk partitioning, filesystem creation, and blue–green layout.
#
# This script partitions the disk, creates filesystems, and sets up a dual‑root
# immutable system using Btrfs. It now includes additional checks (for critical files,
# image sources, and partition layout), creates a dedicated “deployment” subvolume
# to hold both system and data subvolumes, extracts the system image (via a btrfs send stream)
# into the blue slot (active), and extracts the Flatpak image (via a btrfs send stream)
# into a stable “flatpak” subvolume, then snapshots blue to create green, mounts the EFI partition,
# creates a swapfile, and finally flushes writes with a sync.
#
# REQUIRED ENVIRONMENT VARIABLES:
#   OSI_DEVICE_PATH           - e.g. /dev/sda or /dev/nvme0n1
#   OSI_DEVICE_EFI_PARTITION  - e.g. /dev/sda1
#   OSI_DEVICE_IS_PARTITION   - 0 if whole device; 1 if already a partition
#   OSI_USE_ENCRYPTION        - 1 to enable encryption; 0 otherwise
#   OSI_ENCRYPTION_PIN        - Encryption passphrase (if encryption is enabled)
#
# Ensure these variables are defined in your environment or configuration file.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[INSTALL][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# Logging functions
log_info() { echo "[INSTALL][INFO] $*"; }
log_error() { echo "[INSTALL][ERROR] $*" >&2; }
log_warn() { echo "[INSTALL][WARN] $*" >&2; }

# Check required commands
check_command() {
  command -v "$1" &>/dev/null || { log_error "Command '$1' not found."; exit 1; }
}
for cmd in sudo sfdisk mkfs.fat cryptsetup mkfs.btrfs mount btrfs zstd swapon free awk; do
  check_command "$cmd"
done

# Check required environment variables
check_env() {
  local missing=()
  for var in OSI_DEVICE_PATH OSI_DEVICE_EFI_PARTITION OSI_DEVICE_IS_PARTITION OSI_USE_ENCRYPTION; do
    [[ -z "${!var:-}" ]] && missing+=("$var")
  done
  (( OSI_USE_ENCRYPTION == 1 && -z "${OSI_ENCRYPTION_PIN:-}" )) && missing+=("OSI_ENCRYPTION_PIN")
  (( ${#missing[@]} > 0 )) && { log_error "Missing required variables: ${missing[*]}"; exit 1; }
}
check_env

### Configuration variables
OS_NAME="shanios"
OSIDIR="/etc/os-installer"
PART_LAYOUT="${OSIDIR}/bits/part.sfdisk"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"       # EFI partition label
BTRFS_TOP_OPTS="defaults,noatime"

# Source image paths (btrfs send streams)
ROOTFSZST_SOURCE="/run/archiso/bootmnt/${OS_NAME}/x86_64/rootfs.zst"
FLATPAKFS_SOURCE="/run/archiso/bootmnt/${OS_NAME}/x86_64/flatpakfs.zst"

SWAPFILE_REL_PATH="swap/swapfile"  # Under the data subvolume
SWAPFILE_SIZE=$(free -m | awk '/^Mem:/{printf "%d", int($2 * 1.5)}')

# Deployment subvolume (container for system and data subvolumes)
DEPLOYMENT_MNT="/mnt/deployment"
# These paths are relative to the Btrfs top‐level
SYSTEM_SUBVOL="${DEPLOYMENT_MNT}/system"
DATA_SUBVOL="${DEPLOYMENT_MNT}/data"

# Active system slots (inside SYSTEM_SUBVOL)
BLUE_SLOT="${SYSTEM_SUBVOL}/blue"
GREEN_SLOT="${SYSTEM_SUBVOL}/green"

# Active slot marker file (stored in the deployment subvolume)
CURRENT_SLOT_FILE="${DEPLOYMENT_MNT}/current-slot"

# Pre-check critical files
[[ ! -f "${PART_LAYOUT}" ]] && { log_error "Partition layout file not found at ${PART_LAYOUT}"; exit 1; }
[[ ! -f "${ROOTFSZST_SOURCE}" ]] && { log_error "System image not found at ${ROOTFSZST_SOURCE}"; exit 1; }
[[ ! -f "${FLATPAKFS_SOURCE}" ]] && { log_error "Flatpak image not found at ${FLATPAKFS_SOURCE}"; exit 1; }

# Common extraction function using btrfs receive.
extract_image() {
  # Usage: extract_image <source_file> <destination_parent>
  local src="$1"
  local dest="$2"
  log_info "Extracting image from $src into $dest"
  sudo zstd -d --long=31 -T0 "$src" -c | sudo btrfs receive "$dest" \
    || { log_error "Image extraction failed"; exit 1; }
}

log_info "Starting disk setup..."

do_partitioning() {
  log_info "Partitioning disk at ${OSI_DEVICE_PATH}"
  local partition_prefix
  if [[ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]]; then
    if [[ "${OSI_DEVICE_PATH}" =~ nvme[0-9]+n[0-9]+$ ]]; then
      partition_prefix="${OSI_DEVICE_PATH}p"
    else
      partition_prefix="${OSI_DEVICE_PATH}"
    fi
    sudo sfdisk "${OSI_DEVICE_PATH}" < "${PART_LAYOUT}" || { log_error "Partitioning failed"; exit 1; }
    ROOT_PARTITION="${partition_prefix}2"
  else
    ROOT_PARTITION="${OSI_DEVICE_PATH}"
  fi
  log_info "Root partition: ${ROOT_PARTITION}"
}

create_filesystems() {
  log_info "Formatting EFI partition (${OSI_DEVICE_EFI_PARTITION}) as FAT32 with label ${BOOTLABEL}"
  sudo mkfs.fat -F32 "${OSI_DEVICE_EFI_PARTITION}" -n "${BOOTLABEL}" || { log_error "EFI FAT creation failed"; exit 1; }
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    log_info "Setting up LUKS on ${ROOT_PARTITION}"
    echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup -q luksFormat "${ROOT_PARTITION}" || exit 1
    echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup open "${ROOT_PARTITION}" "${ROOTLABEL}" || exit 1
    BTRFS_TARGET="/dev/mapper/${ROOTLABEL}"
  else
    BTRFS_TARGET="${ROOT_PARTITION}"
  fi
  log_info "Creating Btrfs filesystem on ${BTRFS_TARGET} with label ${ROOTLABEL}"
  sudo mkfs.btrfs -f -L "${ROOTLABEL}" "${BTRFS_TARGET}" || { log_error "Btrfs creation failed"; exit 1; }
}

mount_top_level() {
  log_info "Mounting Btrfs top‐level on /mnt"
  sudo mount -o "${BTRFS_TOP_OPTS}" "${BTRFS_TARGET}" /mnt || { log_error "Mounting failed"; exit 1; }
}

create_deployment_subvol() {
  # Create a dedicated deployment subvolume to hold system and data subvolumes
  if sudo btrfs subvolume list /mnt | grep -q "path deployment\$"; then
    log_info "Deployment subvolume already exists."
  else
    log_info "Creating deployment subvolume at /mnt/deployment"
    sudo btrfs subvolume create /mnt/deployment || { log_error "Failed to create deployment subvolume"; exit 1; }
  fi
}

create_common_subvolumes() {
  # Create system and data subvolumes (if not already present)
  if ! sudo btrfs subvolume list "${DEPLOYMENT_MNT}" | grep -q "path system\$"; then
    log_info "Creating system subvolume at ${SYSTEM_SUBVOL}"
    sudo btrfs subvolume create "${SYSTEM_SUBVOL}" || { log_error "Creation of system subvolume failed"; exit 1; }
  else
    log_info "System subvolume already exists."
  fi

  if ! sudo btrfs subvolume list "${DEPLOYMENT_MNT}" | grep -q "path data\$"; then
    log_info "Creating data subvolume at ${DATA_SUBVOL}"
    sudo btrfs subvolume create "${DATA_SUBVOL}" || { log_error "Creation of data subvolume failed"; exit 1; }
  else
    log_info "Data subvolume already exists."
  fi

  # Create other persistent subvolumes under data.
  for sub in home etc-writable overlay downloads swap containers; do
    if ! sudo btrfs subvolume list "${DATA_SUBVOL}" | grep -q "path ${sub}\$"; then
      log_info "Creating persistent data subvolume: ${sub}"
      sudo btrfs subvolume create "${DATA_SUBVOL}/${sub}" || { log_error "Creation of ${sub} failed"; exit 1; }
    else
      log_info "Data subvolume ${sub} already exists."
    fi
  done
}

extract_system_image() {
  log_info "Extracting system image (subvolume shanios_base) from ${ROOTFSZST_SOURCE}"
  sudo mkdir -p "${SYSTEM_SUBVOL}"
  extract_image "$ROOTFSZST_SOURCE" "${SYSTEM_SUBVOL}"
  
  if sudo btrfs subvolume show "${SYSTEM_SUBVOL}/shanios_base" &>/dev/null; then
    log_info "Subvolume 'shanios_base' detected."
  else
    log_error "'shanios_base' not found after extraction."
    exit 1
  fi

  log_info "Creating snapshot 'blue' from 'shanios_base'"
  sudo btrfs subvolume snapshot "${SYSTEM_SUBVOL}/shanios_base" "${BLUE_SLOT}" || { log_error "Snapshot creation failed"; exit 1; }
  
  log_info "Removing original subvolume 'shanios_base'"
  sudo btrfs subvolume delete "${SYSTEM_SUBVOL}/shanios_base" || log_warn "Could not delete 'shanios_base'; please remove manually later."
  
  log_info "Setting active slot marker to 'blue'"
  echo "blue" | sudo tee "${CURRENT_SLOT_FILE}" > /dev/null || { log_error "Setting active slot failed"; exit 1; }
  
  log_info "System image is set up in slot 'blue'"
}

extract_flatpak_image() {
  log_info "Extracting Flatpak image (subvolume flatpak_subvol) from ${FLATPAKFS_SOURCE}"
  sudo mkdir -p "${DATA_SUBVOL}"
  extract_image "$FLATPAKFS_SOURCE" "${DATA_SUBVOL}"
  
  if sudo btrfs subvolume show "${DATA_SUBVOL}/flatpak_subvol" &>/dev/null; then
    log_info "Subvolume 'flatpak_subvol' detected."
  else
    log_error "'flatpak_subvol' not found after extraction."
    exit 1
  fi

  log_info "Creating snapshot 'flatpak' from 'flatpak_subvol'"
  sudo btrfs subvolume snapshot "${DATA_SUBVOL}/flatpak_subvol" "${DATA_SUBVOL}/flatpak" || { log_error "Snapshot for flatpak failed"; exit 1; }
  
  log_info "Removing original subvolume 'flatpak_subvol'"
  sudo btrfs subvolume delete "${DATA_SUBVOL}/flatpak_subvol" || log_warn "Could not delete 'flatpak_subvol'; please remove manually later."
  
  log_info "Flatpak image is set up in subvolume 'flatpak'"
}

snapshot_blue_to_green() {
  log_info "Creating snapshot of blue slot to form green slot"
  sudo mkdir -p "${SYSTEM_SUBVOL}"
  sudo btrfs subvolume snapshot "${BLUE_SLOT}" "${GREEN_SLOT}" || { log_error "Snapshot creation from blue to green failed"; exit 1; }
}

mount_boot_partition() {
  log_info "Mounting EFI partition (label ${BOOTLABEL}) at /mnt/boot/efi"
  sudo mount --mkdir /dev/disk/by-label/"${BOOTLABEL}" /mnt/boot/efi || { log_error "EFI mount failed"; exit 1; }
}

create_swapfile() {
  log_info "Creating swapfile at ${DATA_SUBVOL}/${SWAPFILE_REL_PATH}"
  local swapfile_dir
  swapfile_dir="$(dirname "${DATA_SUBVOL}/${SWAPFILE_REL_PATH}")"
  sudo mkdir -p "${swapfile_dir}"
  sudo btrfs filesystem mkswapfile --size "${SWAPFILE_SIZE}M" "${DATA_SUBVOL}/${SWAPFILE_REL_PATH}" || { log_error "Swapfile creation failed"; exit 1; }
  sudo swapon "${DATA_SUBVOL}/${SWAPFILE_REL_PATH}" || { log_error "Swap activation failed"; exit 1; }
}

do_setup() {
  do_partitioning
  create_filesystems
  mount_top_level
  create_deployment_subvol
  create_common_subvolumes
  extract_system_image
  extract_flatpak_image
  snapshot_blue_to_green
  mount_boot_partition
  create_swapfile
  
  log_info "Syncing data to disk..."
  sync
  
  log_info "Installation complete: Disk setup and blue–green configuration finished."
  log_info "IMPORTANT: Update /mnt/etc/fstab and configure your bootloader to properly mount your subvolumes."
}

do_setup

