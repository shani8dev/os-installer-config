#!/bin/bash
# install.sh – Disk partitioning, filesystem creation, and blue–green layout.
#
# This script partitions the disk, creates filesystems, and sets up a dual-root
# immutable system using Btrfs with a blue–green deployment strategy.
# It creates subvolumes, extracts system images, sets up data directories,
# and creates a swapfile.
#
# It expects the PART_LAYOUT file to contain:
#
#   label: gpt
#   unit: sectors
#   sector-size: 512
#
#   # Create a FAT32 partition for the EFI system (1GB)
#   start=2048, size=2048000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
#
#   # Create a Btrfs partition for root (uses all remaining space)
#   start=2050048, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
#
# Partition 1 is for EFI; partition 2 (root) will be used for Btrfs.
#
# Expected environment variables:
#   OSI_DEVICE_PATH         – Device path (e.g. /dev/sda or /dev/nvme0n1)
#   OSI_DEVICE_IS_PARTITION – 0 for whole device, 1 if a partition is provided
#   OSI_DEVICE_EFI_PARTITION– (Required when OSI_DEVICE_IS_PARTITION=1) EFI partition path.
#   OSI_USE_ENCRYPTION      – 1 to enable encryption, 0 otherwise.
#   OSI_ENCRYPTION_PIN      – (Optional) PIN for encryption. If absent and encryption is enabled,
#                              a keyfile will be generated (only works when an EFI partition is available).
#
# The PART_LAYOUT file is expected at: ${OSIDIR}/bits/part.sfdisk
#
# When OSI_DEVICE_IS_PARTITION=0 (using a whole disk), the script derives EFI_PARTITION
# (assumed to be partition 1) and ROOT_PARTITION (partition 2) from the layout.
# When OSI_DEVICE_IS_PARTITION=1, OSI_DEVICE_EFI_PARTITION is used directly later.
#
# IMPORTANT: After the script completes, update /mnt/etc/fstab and configure your bootloader.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[INSTALL][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# Logging functions for consistent messaging
log_info() { echo "[INSTALL][INFO] $*"; }
log_warn() { echo "[INSTALL][WARN] $*" >&2; }
log_error() { echo "[INSTALL][ERROR] $*" >&2; }

# --- Improved Function: get_efi_disk_info ---
# Better logic to derive disk and partition number from EFI partition path
get_efi_disk_info() {
  local efi_partition="$1"
  local efi_disk=""
  local efi_part_num=""
  
  # Handle different partition naming schemes
  if [[ "${efi_partition}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    # NVMe: /dev/nvme0n1p1 -> disk=/dev/nvme0n1, part=1
    efi_disk="${BASH_REMATCH[1]}"
    efi_part_num="${BASH_REMATCH[2]}"
  elif [[ "${efi_partition}" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
    # MMC/eMMC: /dev/mmcblk0p1 -> disk=/dev/mmcblk0, part=1
    efi_disk="${BASH_REMATCH[1]}"
    efi_part_num="${BASH_REMATCH[2]}"
  elif [[ "${efi_partition}" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
    # SATA/IDE: /dev/sda1 -> disk=/dev/sda, part=1
    efi_disk="${BASH_REMATCH[1]}"
    efi_part_num="${BASH_REMATCH[2]}"
  else
    log_warn "Unable to parse EFI partition path: ${efi_partition}"
    return 1
  fi
  
  log_info "Derived EFI disk: ${efi_disk}, partition: ${efi_part_num}"
  echo "${efi_disk}" "${efi_part_num}"
}

# --- Improved Function: create_efi_boot_entry ---
# Creates a UEFI boot entry using efibootmgr with better error handling.
create_efi_boot_entry() {
  local efi_disk="$1"      # Disk containing the EFI System Partition (e.g., /dev/sda)
  local efi_part="$2"      # Partition number of the EFI System Partition (e.g., 1)
  local boot_label="$3"    # Label for the new boot entry (e.g., "shanios")
  local efi_loader="$4"    # Path to the EFI loader relative to the EFI partition (e.g., '\EFI\shanios\grubx64.efi')

  log_info "Attempting to create EFI boot entry..."
  
  # Check if we're in a UEFI environment
  if [ ! -d "/sys/firmware/efi" ]; then
    log_warn "Not running in UEFI mode - skipping EFI boot entry creation"
    return 0
  fi
  
  # Check if efibootmgr is available and working
  if ! sudo efibootmgr >/dev/null 2>&1; then
    log_warn "efibootmgr not working (possibly no EFI variables access) - skipping EFI boot entry creation"
    return 0
  fi

  log_info "Looking for an existing UEFI boot entry labeled '${boot_label}'..."
  
  # List current entries and search for an exact match of the boot label
  local existing_entry
  existing_entry=$(sudo efibootmgr 2>/dev/null | grep -wF "${boot_label}" || true)
  
  if [ -n "$existing_entry" ]; then
    # Extract the boot number using sed (matches a hexadecimal after 'Boot')
    local bootnum
    bootnum=$(echo "$existing_entry" | sed -n 's/^Boot\([0-9A-Fa-f]\+\).*/\1/p')
    if [ -n "$bootnum" ]; then
      log_info "Existing entry Boot${bootnum} found. Attempting to delete it..."
      if sudo efibootmgr --delete-bootnum --bootnum "${bootnum}" 2>/dev/null; then
        log_info "Successfully deleted existing entry Boot${bootnum}"
      else
        log_warn "Failed to delete existing EFI boot entry Boot${bootnum} - continuing anyway"
      fi
    else
      log_info "Entry found, but unable to extract boot number. Proceeding to create new entry."
    fi
  else
    log_info "No existing entry with label '${boot_label}' found."
  fi

  log_info "Creating new UEFI boot entry with label '${boot_label}'"
  log_info "  Disk: ${efi_disk}"
  log_info "  Partition: ${efi_part}"
  log_info "  Loader: ${efi_loader}"
  
  if sudo efibootmgr --create --disk "${efi_disk}" --part "${efi_part}" \
    --label "${boot_label}" --loader "${efi_loader}" 2>/dev/null; then
    log_info "EFI boot entry '${boot_label}' created successfully."
  else
    log_warn "Failed to create EFI boot entry - this may not be critical for system functionality"
    log_warn "You can manually create the boot entry later using:"
    log_warn "  sudo efibootmgr --create --disk '${efi_disk}' --part '${efi_part}' --label '${boot_label}' --loader '${efi_loader}'"
  fi
}

# Check for required commands.
for cmd in sudo sfdisk mkfs.fat cryptsetup mkfs.btrfs mount btrfs zstd swapon free awk parted; do
  command -v "$cmd" &>/dev/null || { log_error "Required command '$cmd' not found."; exit 1; }
done

# efibootmgr is optional - only warn if not available
if ! command -v efibootmgr &>/dev/null; then
  log_warn "efibootmgr not found - EFI boot entry creation will be skipped"
fi

# Environment check: OSI_DEVICE_EFI_PARTITION is required only when OSI_DEVICE_IS_PARTITION is 1.
check_env() {
  local missing_vars=()
  local required_vars=(OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_USE_ENCRYPTION)
  if [[ "${OSI_DEVICE_IS_PARTITION:-0}" -eq 1 ]]; then
    if [[ -z "${OSI_DEVICE_EFI_PARTITION+x}" ]]; then
      log_warn "OSI_DEVICE_EFI_PARTITION is not set. Will be assuming 1st partition as EFI."
    fi
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
SNAPFS_SOURCE="/run/archiso/bootmnt/${OS_NAME}/x86_64/snapfs.zst"

SWAPFILE_PATH="@swap/swapfile"  # Under the @swap subvolume
SWAPFILE_SIZE=$(free -m | awk '/^Mem:/{print $2}')

# Pre-check critical files
[[ ! -f "${PART_LAYOUT}" ]] && { log_error "Partition layout file not found at ${PART_LAYOUT}"; exit 1; }
[[ ! -f "${ROOTFSZST_SOURCE}" ]] && { log_error "System image not found at ${ROOTFSZST_SOURCE}"; exit 1; }
[[ ! -f "${FLATPAKFS_SOURCE}" ]] && { log_error "Flatpak image not found at ${FLATPAKFS_SOURCE}"; exit 1; }

# Function: get_partition_prefix
# If the device is NVMe or MMC/eMMC, append a "p" (e.g., /dev/nvme0n1 becomes /dev/nvme0n1p)
get_partition_prefix() {
  if [[ "${OSI_DEVICE_PATH}" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]] || [[ "${OSI_DEVICE_PATH}" =~ ^/dev/mmcblk[0-9]+$ ]]; then
    echo "${OSI_DEVICE_PATH}p"
  else
    echo "${OSI_DEVICE_PATH}"
  fi
}

# Determine partition prefix if using a whole disk.
if [[ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]]; then
  PARTITION_PREFIX=$(get_partition_prefix)
else
  PARTITION_PREFIX=""
fi

# Function: normalize_partition
# Ensures that if a partition is specified as a simple number it is prefixed with PARTITION_PREFIX.
normalize_partition() {
  local part="$1"
  if [[ "$part" =~ ^[0-9]+$ ]] && [ -n "${PARTITION_PREFIX}" ]; then
    echo "${PARTITION_PREFIX}${part}"
  else
    echo "$part"
  fi
}

# Function: extract_image
# Decompress an image with zstd and pipe it into btrfs receive.
extract_image() {
  local src="$1"
  local dest="$2"
  log_info "Extracting image from ${src} into ${dest}"
  sudo zstd -d --long=31 -T0 "${src}" -c | sudo btrfs receive "${dest}" \
    || { log_error "Image extraction from ${src} failed"; exit 1; }
}

log_info "Starting disk setup..."

# Function: do_partitioning
# If using a whole disk, partition it using PART_LAYOUT, derive EFI and root partitions,
# and set boot/esp flags; if using a pre-partitioned device, assign EFI_PARTITION from OSI_DEVICE_EFI_PARTITION.
do_partitioning() {
  log_info "Setting ${OSI_DEVICE_PATH} to read-write mode."
  sudo blockdev --setrw "${OSI_DEVICE_PATH}" || log_warn "Could not force device to read-write mode; proceeding anyway."
  
  if [[ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]]; then
    log_info "Partitioning whole device ${OSI_DEVICE_PATH}"
    sudo sfdisk "${OSI_DEVICE_PATH}" < "${PART_LAYOUT}" || { log_error "Disk partitioning failed"; exit 1; }
    # For whole disk, derive partitions: Partition 1 (EFI), Partition 2 (root).
    EFI_PARTITION=$(normalize_partition "1")
    ROOT_PARTITION=$(normalize_partition "2")
    # Set boot and esp flags on the EFI partition
    log_info "Setting boot and esp flags on EFI partition"
    sudo parted --script "${OSI_DEVICE_PATH}" set 1 boot on || log_warn "Could not set boot flag on partition 1"
    sudo parted --script "${OSI_DEVICE_PATH}" set 1 esp on || log_warn "Could not set esp flag on partition 1"
  else
    log_info "Using pre-partitioned device."
    # Use provided EFI partition; normalize if it is a simple number.
    EFI_PARTITION=$(normalize_partition "${OSI_DEVICE_EFI_PARTITION:-1}")
    ROOT_PARTITION="${OSI_DEVICE_PATH}"
  fi
  log_info "EFI partition: ${EFI_PARTITION}"
  log_info "Root partition: ${ROOT_PARTITION}"
}

# Function: mount_boot_partition
# Mount the EFI partition at /mnt/boot/efi. The function takes the EFI device as a parameter.
mount_boot_partition() {
  local efi_device="$1"
  log_info "Mounting EFI partition (${efi_device}) at /mnt/boot/efi"
  sudo mount --mkdir /dev/disk/by-label/"${BOOTLABEL}" /mnt/boot/efi \
    || { log_error "EFI partition mount failed"; exit 1; }
}

# Function: create_filesystems
# Format and mount the EFI partition and create the Btrfs filesystem on the root partition.
create_filesystems() {
  # Format and mount the EFI partition using the global EFI_PARTITION variable.
  log_info "Formatting EFI partition (${EFI_PARTITION}) as FAT32 with label ${BOOTLABEL}"
  sudo mkfs.fat -F32 "${EFI_PARTITION}" -n "${BOOTLABEL}" || { log_error "EFI partition formatting failed"; exit 1; }
  mount_boot_partition "${EFI_PARTITION}"

  # Set up encryption on the root partition if requested.
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    if [ -n "${OSI_ENCRYPTION_PIN:-}" ]; then
      log_info "Setting up LUKS encryption on ${ROOT_PARTITION} using provided encryption PIN"
      echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup -q luksFormat "${ROOT_PARTITION}" || exit 1
      echo "${OSI_ENCRYPTION_PIN}" | sudo cryptsetup open "${ROOT_PARTITION}" "${ROOTLABEL}" || exit 1
    else
      log_info "No encryption PIN provided; generating keyfile in EFI partition"
      sudo dd if=/dev/urandom of=/mnt/boot/efi/crypto_keyfile.bin bs=4096 count=1
      sudo chmod 0400 /mnt/boot/efi/crypto_keyfile.bin
      sudo cryptsetup -q luksFormat "${ROOT_PARTITION}" --key-file /mnt/boot/efi/crypto_keyfile.bin
      sudo cryptsetup open "${ROOT_PARTITION}" "${ROOTLABEL}" --key-file /mnt/boot/efi/crypto_keyfile.bin
      export OSI_KEYFILE="/boot/efi/crypto_keyfile.bin"
    fi
    BTRFS_TARGET="/dev/mapper/${ROOTLABEL}"
  else
    BTRFS_TARGET="${ROOT_PARTITION}"
  fi

  log_info "Creating Btrfs filesystem on ${BTRFS_TARGET} with label ${ROOTLABEL}"
  sudo mkfs.btrfs -f -L "${ROOTLABEL}" "${BTRFS_TARGET}" || { log_error "Btrfs filesystem creation failed"; exit 1; }
}

# Function: mount_top_level
# Mount the newly created Btrfs filesystem at /mnt with the given options.
mount_top_level() {
  log_info "Mounting Btrfs top-level filesystem on /mnt"
  sudo mount -o "${BTRFS_TOP_OPTS}" "${BTRFS_TARGET}" /mnt || { log_error "Mounting top-level filesystem failed"; exit 1; }
}

# Function: create_subvolumes
# Create the necessary Btrfs subvolumes and additional directories.
create_subvolumes() {
  log_info "Creating required Btrfs subvolumes and directories"
  local subvolumes=( "@home" "@data" "@cache" "@log" "@waydroid" "@containers" "@machines" "@lxc" "@libvirt" "@swap" )
  for subvol in "${subvolumes[@]}"; do
    if ! sudo btrfs subvolume list /mnt | grep -q "path ${subvol}\$"; then
      log_info "Creating subvolume ${subvol}"
      sudo btrfs subvolume create "/mnt/${subvol}" || { log_error "Failed to create subvolume ${subvol}"; exit 1; }
    else
      log_info "Subvolume ${subvol} already exists"
    fi
  done

  # Create overlay directories
  local overlay_dirs=( 
    "overlay/etc/lower" 
    "overlay/etc/upper" 
    "overlay/etc/work" 
    "overlay/var/lower" 
    "overlay/var/upper" 
    "overlay/var/work"
  )
  for dir in "${overlay_dirs[@]}"; do
    local full_dir="/mnt/@data/${dir}"
    if [ ! -d "${full_dir}" ]; then
      log_info "Creating overlay directory ${full_dir}"
      sudo mkdir -p "${full_dir}" || { log_error "Failed to create directory ${full_dir}"; exit 1; }
    else
      log_info "Overlay directory ${full_dir} already exists"
    fi
  done

  # Create persistent service state directories in @data/varlib
  log_info "Creating persistent service state directories"
  local varlib_dirs=(
    # Core System Services (Required)
    "varlib/dbus"
    "varlib/systemd"
    # Network & Connectivity
    "varlib/NetworkManager"
    "varlib/bluetooth"
    # Authentication & User Management
    "varlib/fprint"
    "varlib/AccountsService"
    "varlib/boltd"
    # Display Managers
    "varlib/gdm"
    "varlib/sddm"
    # Hardware & Peripherals
    "varlib/colord"
    "varlib/upower"
    "varlib/cups"
    "varlib/sane"
    "varlib/firewalld"
    "varlib/geoclue"
    # Network Services
    "varlib/samba"
    "varlib/nfs"
    # spool
    "varspool/anacron"
    "varspool/cron"
    "varspool/cups"
    "varspool/samba"
    # snap
    "snap/data"
    "snap/root"
    # User data directory
    "downloads"
  )
  
  for dir in "${varlib_dirs[@]}"; do
    local full_dir="/mnt/@data/${dir}"
    if [ ! -d "${full_dir}" ]; then
      log_info "Creating service directory ${full_dir}"
      sudo mkdir -p "${full_dir}" || { log_error "Failed to create directory ${full_dir}"; exit 1; }
    else
      log_info "Service directory ${full_dir} already exists"
    fi
  done
  
  # Set restrictive permissions for root's snap directory
  # CRITICAL: /root/snap inherits these permissions via bind mount
  log_info "Setting permissions for /data/snap/root"
  sudo chmod 700 "/mnt/@data/snap/root" || \
  log_warn "Failed to set 700 permissions on /data/snap/root"
  
  log_info "All required directories created successfully"
}

# Function: extract_system_image
# Decompress and load the system image into /mnt, then create snapshots for blue–green deployment.
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
# Decompress and load the Flatpak image, then create a snapshot.
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

# Function: extract_snap_image
# Decompress and load the Snap image, then create a snapshot.
extract_snap_image() {
  log_info "Extracting Snap image into /mnt"
  extract_image "${SNAPFS_SOURCE}" "/mnt"
  if sudo btrfs subvolume show "/mnt/snapd_subvol" &>/dev/null; then
    log_info "Subvolume 'snapd_subvol' detected"
  else
    log_error "Subvolume 'snapd_subvol' not found after extraction"
    exit 1
  fi
  log_info "Creating snapshot @snapd from snapd_subvol"
  sudo btrfs subvolume snapshot "/mnt/snapd_subvol" "/mnt/@snapd" || { log_error "Snapshot creation for @snapd failed"; exit 1; }
  log_info "Deleting original subvolume snapd_subvol"
  sudo btrfs subvolume delete "/mnt/snapd_subvol" || log_warn "Could not delete snap_subvol; please remove manually later"
}

# Function: create_swapfile
# Create a swapfile within the @swap subvolume and activate it.
create_swapfile() {
  local available_mb=$(df -BM /mnt | awk 'NR==2 {print $4}' | sed 's/M//')
  
  if (( available_mb < SWAPFILE_SIZE )); then
    log_warn "Insufficient space for swapfile. Available: ${available_mb}MB, Required: ${SWAPFILE_SIZE}MB"
    log_info "Skipping swapfile creation. System will use zram for swap."
    return 0
  fi
  
  log_info "Creating swapfile at /mnt/@swap/swapfile"
  sudo btrfs filesystem mkswapfile --size "${SWAPFILE_SIZE}M" "/mnt/@swap/swapfile" || { log_error "Swapfile creation failed"; exit 1; }
  sudo swapon "/mnt/@swap/swapfile" || { log_error "Swapfile activation failed"; exit 1; }
}

# Main setup function: run all steps sequentially.
do_setup() {
  do_partitioning
  create_filesystems
  mount_top_level
  create_subvolumes
  extract_system_image
  extract_flatpak_image
  extract_snap_image
  create_swapfile

  # --- Create UEFI boot entry with improved error handling ---
  log_info "Setting up UEFI boot entry..."
  
  # Get disk and partition info
  local efi_info
  if efi_info=$(get_efi_disk_info "${EFI_PARTITION}"); then
    local efi_disk efi_part_num
    read -r efi_disk efi_part_num <<< "${efi_info}"
    
    # Create the boot entry (won't fail the script if it doesn't work)
    create_efi_boot_entry "${efi_disk}" "${efi_part_num}" "${OS_NAME}" '\EFI\BOOT\BOOTX64.EFI'
  else
    log_warn "Could not derive EFI disk information - skipping boot entry creation"
    log_warn "You may need to manually create a boot entry later"
  fi
  # --- End boot entry creation ---

  log_info "Syncing data to disk..."
  sync

  log_info "Installation complete: Disk setup and blue-green configuration finished."
  log_info "IMPORTANT: Update /mnt/etc/fstab and configure your bootloader."
}

do_setup
