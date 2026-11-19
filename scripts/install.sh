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
#
#   # Create a FAT32 partition for the EFI System (1 GiB)
#   # - Type: UEFI (GPT)
#   # - Filesystem: FAT32
#   # - Label: shani_boot
#   size=1G, type=uefi, name="shani_boot"
#
#   # Create a Linux root partition (uses all remaining space)
#   # - Type: Linux (GPT)
#   # - Filesystem: Btrfs
#   # - Label: shani_root
#   type=linux-root-x86-64, name="shani_root"
#
# Partition 1 is EFI; Partition 2 is used for the Btrfs root filesystem.
# sfdisk handles alignment automatically (compatible with 512/512e/4Kn disks).
#
# Expected environment variables:
#   OSI_DEVICE_PATH         – Device path (e.g. /dev/sda or /dev/nvme0n1)
#   OSI_DEVICE_IS_PARTITION – 0 for whole device, 1 if a partition is provided
#   OSI_DEVICE_EFI_PARTITION– (Required when OSI_DEVICE_IS_PARTITION=1) EFI partition path.
#   OSI_USE_ENCRYPTION      – 1 to enable encryption, 0 otherwise.
#   OSI_ENCRYPTION_PIN      – Passphrase for LUKS encryption. Required when OSI_USE_ENCRYPTION=1.
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

# Logging functions for consistent messaging
log_info() { echo "[INSTALL][INFO] $*"; }
log_warn() { echo "[INSTALL][WARN] $*" >&2; }
log_error() { echo "[INSTALL][ERROR] $*" >&2; }
die() { log_error "$*"; run_cleanup_stack; exit 1; }

# --- Cleanup stack for unwinding mounts/mapper devices on failure ----------
# Every mount (and cryptsetup open) performed by this script pushes its own
# undo command here immediately on success (see mount_tracked() below). On
# any die()/ERR-trap failure, run_cleanup_stack() unwinds everything *this
# run* actually set up, in reverse (LIFO) order — since mounts/opens are
# pushed in the same chronological order they were created, unwinding in
# reverse naturally unmounts children before parents, and closes the LUKS
# mapper only after whatever was mounted on top of it is gone. A normal
# successful exit never calls this — install.sh intentionally leaves /mnt
# mounted (and the mapper open) for configure.sh to build on next.
declare -a _CLEANUP_STACK=()
_push_cleanup() { _CLEANUP_STACK+=("$1"); }
run_cleanup_stack() {
  local i
  for (( i=${#_CLEANUP_STACK[@]}-1; i>=0; i-- )); do
    log_warn "Cleanup: ${_CLEANUP_STACK[i]}"
    eval "${_CLEANUP_STACK[i]}" || true
  done
  _CLEANUP_STACK=()
}
# Run a mount command; on success, remember how to undo it.
#   mount_tracked <mountpoint-to-unmount-on-cleanup> <mount command...>
mount_tracked() {
  local mountpoint="$1"; shift
  "$@" || return 1
  _push_cleanup "sudo umount -R '${mountpoint}' 2>/dev/null || sudo umount -Rl '${mountpoint}' 2>/dev/null || true"
}

trap 'ec=$?; echo "[INSTALL][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; run_cleanup_stack; exit "$ec"' ERR

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
for cmd in sudo sfdisk mkfs.fat cryptsetup mkfs.btrfs mount btrfs zstd swapon free awk parted mktemp shred; do
  command -v "$cmd" &>/dev/null || die "Required command '$cmd' not found."
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
    if [[ -z "${OSI_DEVICE_EFI_PARTITION:-}" ]]; then
      log_warn "OSI_DEVICE_EFI_PARTITION is not set. Will be assuming 1st partition as EFI."
    fi
  fi
  for var in "${required_vars[@]}"; do
    [ -z "${!var:-}" ] && missing_vars+=("$var")
  done
  if [ "${OSI_USE_ENCRYPTION:-0}" -eq 1 ] && [ -z "${OSI_ENCRYPTION_PIN:-}" ]; then
    log_error "OSI_USE_ENCRYPTION is enabled but OSI_ENCRYPTION_PIN is not set — a passphrase is required"
    exit 1
  fi
  if [ ${#missing_vars[@]} -gt 0 ]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    exit 1
  fi
}

check_env

### Configuration variables
# The installer owns the distro's install policy (config: install_policy) and
# exports it; the ${VAR:-default} keeps this script working with an installer
# that predates the export (and with a direct, non-installer run).
OS_NAME="${OSI_OS_NAME:-shanios}"
OSIDIR="${OSIDIR:-/etc/os-installer}"

# Repair mode: never partition or extract — hand over to repair.sh, which
# re-runs the configuration and the boot chain on the existing install.
#
# repair.sh runs as root (it mounts, chroots and rebuilds the boot chain) and
# this script runs as the live user: it used to be exec'd as that user and
# stopped at its "must run as root" line, so Repair never worked from the
# installer. And an encrypted disk has to be unlocked first - its shani_root
# label is only visible inside the LUKS container - with the passphrase the
# disk already has (the installer's encryption page asks for it on repair).
if [[ "${OSI_REPAIR:-0}" == "1" ]]; then
    if [[ "${OSI_USE_ENCRYPTION:-0}" == "1" ]]; then
        luks_part=$(lsblk -lnpo NAME,FSTYPE "${OSI_DEVICE_PATH}" 2>/dev/null | awk '$2 == "crypto_LUKS" { print $1; exit }')
        [[ -n "${luks_part}" ]] || die "No encrypted partition found on ${OSI_DEVICE_PATH} to repair"
        if ! printf '%s' "${OSI_ENCRYPTION_PIN}" \
            | sudo cryptsetup open --key-file=- "${luks_part}" "${OSI_ROOT_LABEL:-shani_root}"; then
            die "The disk passphrase is not right - it is the one typed at every boot of this machine."
        fi
    fi
    exec sudo --preserve-env /bin/bash "${OSIDIR}/scripts/repair.sh"
fi
PART_LAYOUT="${OSI_PARTITION_LAYOUT:-${OSIDIR}/bits/part.sfdisk}"
ROOTLABEL="${OSI_ROOT_LABEL:-shani_root}"
BOOTLABEL="${OSI_BOOT_LABEL:-shani_boot}"
BTRFS_TOP_OPTS="${OSI_BTRFS_TOP_OPTS:-defaults,noatime,compress=zstd,space_cache=v2,autodefrag}"

# Source image paths (Btrfs send streams)
IMAGE_DIR="${OSI_IMAGE_DIR:-/run/archiso/bootmnt/${OS_NAME}/x86_64}"
ROOTFSZST_SOURCE="${IMAGE_DIR}/${OSI_ROOTFS_IMAGE:-rootfs.zst}"
FLATPAKFS_SOURCE="${IMAGE_DIR}/${OSI_FLATPAK_IMAGE:-flatpakfs.zst}"
SNAPFS_SOURCE="${IMAGE_DIR}/${OSI_SNAP_IMAGE:-snapfs.zst}"
AIMODELSFS_SOURCE="${IMAGE_DIR}/${OSI_AI_MODELS_IMAGE:-aimodelsfs.zst}"

KEEP_DATA="${OSI_KEEP_DATA:-0}"
SWAPFILE_PATH="${OSI_SWAPFILE_PATH:-@swap/swapfile}"  # Under the @swap subvolume
SWAPFILE_SIZE=$(free -m | awk '/^Mem:/{print $2}')

# Subvolumes to create (space separated; the installer exports the list).
BTRFS_SUBVOLUMES="${OSI_BTRFS_SUBVOLUMES:-@root @home @data @nix @cache @log @flatpak @snapd @waydroid @containers @machines @lxc @lxd @libvirt @qemu @swap @shani-chronoa}"

# Pre-check critical files
[[ ! -f "${PART_LAYOUT}" ]] && die "Partition layout file not found at ${PART_LAYOUT}"
[[ ! -f "${ROOTFSZST_SOURCE}" ]] && die "System image not found at ${ROOTFSZST_SOURCE}"
[[ ! -f "${FLATPAKFS_SOURCE}" ]] && log_info "Flatpak image not found at ${FLATPAKFS_SOURCE} — Flatpak install will be skipped."
[[ ! -f "${SNAPFS_SOURCE}" ]] && log_info "Snap image not found at ${SNAPFS_SOURCE} — Snap install will be skipped."
[[ ! -f "${AIMODELSFS_SOURCE}" ]] && log_info "AI models image not found at ${AIMODELSFS_SOURCE} — AI models install will be skipped."

# Function: get_partition_prefix
# If the device is NVMe or MMC/eMMC, append a "p" (e.g., /dev/nvme0n1 becomes /dev/nvme0n1p)
get_partition_prefix() {
  # The kernel's rule, not a list of names: a disk whose name ends in a digit
  # numbers its partitions after a "p" (nvme0n1p2, mmcblk0p2, loop0p2, nbd0p2,
  # pmem0p2); any other gets the number straight on (sda2, vda2, xvda2). Only
  # nvme and mmcblk were known before.
  if [[ "${OSI_DEVICE_PATH}" =~ [0-9]$ ]]; then
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
# ── Progress for the installer's bar (OSI_PROGRESS_FILE) ─────────────────────
# Extracting the images is nearly all of an install's time, so the percentage is
# the bytes of them read so far, out of all of them present (pv), up to 95; the
# swapfile and boot entry take it to 100. No file given, or no pv: no number,
# and the installer's bar pulses as before.
PROGRESS_TOTAL=0
PROGRESS_DONE=0
_progress() {
  [[ -n "${OSI_PROGRESS_FILE:-}" ]] || return 0
  printf '%d\n' "$1" > "${OSI_PROGRESS_FILE}.tmp" 2>/dev/null \
    && mv -f "${OSI_PROGRESS_FILE}.tmp" "${OSI_PROGRESS_FILE}" 2>/dev/null
  return 0
}
_progress_total() {
  local f
  PROGRESS_TOTAL=0
  ISO_ROOTFS_SIZE=$(stat -c %s "$1" 2>/dev/null || echo 0)
  for f in "$@"; do
    [[ -f "$f" ]] && PROGRESS_TOTAL=$(( PROGRESS_TOTAL + $(stat -c %s "$f") ))
  done
  _progress 0
}

# ── The newest image from the web, when online ───────────────────────────────
# The ISO carries the image it was built around; online, the channel a new
# install follows (stable) may have a newer one. Installing that saves the
# update the first boot would do at once, and it lands in /data/downloads,
# where shani-deploy keeps images. Verified like every update - SHA-256 and a
# signature by a key shani-keyring trusts - and anything short of that (no
# network, an older or equal image, a bad download or signature) installs the
# ISO's own image instead. OSI_UPDATE_FROM_WEB=0 turns it off.
fetch_newer_image() {
  [[ "${OSI_UPDATE_FROM_WEB:-1}" == "1" ]] || return 0
  local base="${OSI_IMAGE_URL_BASE:-https://downloads.shani.dev}"
  local channel="${OSI_UPDATE_CHANNEL:-stable}"
  local keyring="${OSI_IMAGE_KEYRING:-/usr/share/pacman/keyrings/shani.gpg}"
  local trusted="${OSI_IMAGE_TRUSTED:-/usr/share/pacman/keyrings/shani-trusted}"
  local iso_img="" remote="" iso_date profile r_date dir gpghome fpr
  [[ -r "${IMAGE_DIR}/image.txt" ]] && iso_img=$(tr -d '[:space:]' < "${IMAGE_DIR}/image.txt")
  if [[ ! "${iso_img}" =~ ^shanios-([0-9]{8})-([a-z0-9_-]+)\.zst$ ]]; then
    log_info "Web update: the ISO does not say which image it carries - installing its own"
    return 0
  fi
  iso_date="${BASH_REMATCH[1]}"; profile="${BASH_REMATCH[2]}"
  remote=$(curl -fsSL --connect-timeout 5 --max-time 15 "${base}/${profile}/${channel}.txt" 2>/dev/null | tr -d '[:space:]') || true
  if [[ ! "${remote}" =~ ^shanios-([0-9]{8})-${profile}\.zst$ ]]; then
    log_info "Web update: no ${channel} image reachable (offline?) - installing the ISO's ${iso_date}"
    return 0
  fi
  r_date="${BASH_REMATCH[1]}"
  if (( 10#${r_date} <= 10#${iso_date} )); then
    log_info "Web update: the ISO's ${iso_date} is current for ${channel} (${r_date})"
    return 0
  fi
  log_info "Web update: ${channel} has ${r_date}, newer than the ISO's ${iso_date} - downloading it"
  dir="/mnt/@data/downloads"
  sudo mkdir -p "${dir}"
  local url="${base}/${profile}/${r_date}/${remote}" ok=0
  if sudo curl -fL --progress-bar --retry 3 --connect-timeout 10 -C - -o "${dir}/${remote}" "${url}" \
     && sudo curl -fsSL --retry 3 -o "${dir}/${remote}.sha256" "${url}.sha256" \
     && sudo curl -fsSL --retry 3 -o "${dir}/${remote}.asc" "${url}.asc" \
     && (cd "${dir}" && sudo sha256sum -c --status "${remote}.sha256"); then
    gpghome=$(mktemp -d)
    if gpg --homedir "${gpghome}" --batch --quiet --import "${keyring}" 2>/dev/null; then
      fpr=$(gpg --homedir "${gpghome}" --batch --status-fd 1 --verify "${dir}/${remote}.asc" "${dir}/${remote}" 2>/dev/null \
              | awk '$2 == "VALIDSIG" { print $3; exit }')
      [[ -n "${fpr}" ]] && grep -q "^${fpr}:" "${trusted}" 2>/dev/null && ok=1
    fi
    rm -rf "${gpghome}"
  fi
  if (( ok )); then
    log_info "Web update: ${remote} verified (SHA-256, signed by ${fpr}) - installing it"
    ROOTFSZST_SOURCE="${dir}/${remote}"
    PROGRESS_TOTAL=$(( PROGRESS_TOTAL - ISO_ROOTFS_SIZE + $(stat -c %s "${ROOTFSZST_SOURCE}") ))
  else
    log_warn "Web update: ${remote} did not download or verify - installing the ISO's ${iso_date}"
    sudo rm -f "${dir}/${remote}" "${dir}/${remote}.sha256" "${dir}/${remote}.asc"
  fi
  return 0
}

extract_image() {
  local src="$1"
  local dest="$2"
  local size
  size=$(stat -c %s "${src}" 2>/dev/null || echo 0)
  log_info "Extracting image from ${src} into ${dest}"
  if [[ -n "${OSI_PROGRESS_FILE:-}" ]] && command -v pv >/dev/null && (( PROGRESS_TOTAL > 0 )); then
    # pv -n prints a percentage of this file per second on stderr
    if pv -n -i 1 "${src}" 2> >(while read -r p; do
          _progress $(( (PROGRESS_DONE + size * p / 100) * 95 / PROGRESS_TOTAL ))
        done) \
       | sudo zstd -d --long=31 -T0 -c | sudo btrfs receive "${dest}"; then
      PROGRESS_DONE=$(( PROGRESS_DONE + size ))
      return 0
    fi
  elif sudo zstd -d --long=31 -T0 "${src}" -c | sudo btrfs receive "${dest}"; then
    PROGRESS_DONE=$(( PROGRESS_DONE + size ))
    return 0
  fi
  # Failed. zstd checks every frame's checksum, so a damaged USB stick or a
  # bad download shows here - say that, not just "failed": the fix is to
  # write the stick again, not to retry the install.
  if ! zstd -t --long=31 -q "${src}" 2>/dev/null; then
    die "The installation media is damaged: ${src##*/} does not read back correctly. Download the ISO again (check its SHA-256) and write the USB stick again."
  fi
  die "Image extraction from ${src} failed (the image itself reads back fine - see the log above)"
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
    # Optional secure erase before partitioning (default: quick).
    if [[ "${OSI_DISK_ERASE:-quick}" == "secure" ]]; then
      log_info "Secure erase: blkdiscard ${OSI_DEVICE_PATH}"
      sudo blkdiscard -f "${OSI_DEVICE_PATH}" \
        || log_warn "blkdiscard failed — continuing with a normal wipe"
    fi

    sudo sfdisk --wipe always --force "${OSI_DEVICE_PATH}" < "${PART_LAYOUT}" || die "Disk partitioning failed"
    sudo partprobe "${OSI_DEVICE_PATH}" || true
    sudo udevadm settle
    # For whole disk, derive partitions: Partition 1 (EFI), Partition 2 (root).
    EFI_PARTITION=$(normalize_partition "1")
    ROOT_PARTITION=$(normalize_partition "2")
    # Set boot and esp flags on the EFI partition
    log_info "Setting boot and esp flags on EFI partition"
    sudo parted --script "${OSI_DEVICE_PATH}" set 1 boot on || log_warn "Could not set boot flag on partition 1"
    sudo parted --script "${OSI_DEVICE_PATH}" set 1 esp on || log_warn "Could not set esp flag on partition 1"
  else
    log_info "Using pre-partitioned device."
    if [[ -z "${OSI_DEVICE_EFI_PARTITION:-}" ]]; then
      # No EFI partition given. PARTITION_PREFIX is empty in this branch (it's
      # only derived for whole-disk installs), so normalize_partition("1")
      # would return the bare string "1", not a device path — derive the
      # sibling EFI partition from the chosen root partition's own disk instead.
      if [[ "${OSI_DEVICE_PATH}" =~ ^(/dev/nvme[0-9]+n[0-9]+|/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
        EFI_PARTITION="${BASH_REMATCH[1]}p1"
      elif [[ "${OSI_DEVICE_PATH}" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
        EFI_PARTITION="${BASH_REMATCH[1]}1"
      else
        log_error "OSI_DEVICE_EFI_PARTITION not set and could not derive an EFI partition from ${OSI_DEVICE_PATH}"
        exit 1
      fi
      log_warn "OSI_DEVICE_EFI_PARTITION not set — assuming ${EFI_PARTITION} is the EFI partition."
    else
      EFI_PARTITION=$(normalize_partition "${OSI_DEVICE_EFI_PARTITION}")
    fi
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
  # mkfs.fat wrote the volume label into the FAT superblock but does NOT emit a
  # block-device uevent, so udev only creates /dev/disk/by-label/<label> from
  # the on-disk label on its next (re)scan. Force that scan and wait for it
  # before mounting by label — otherwise the symlink can be missing and mount
  # fails with "Can't lookup blockdev". Where no udevd is running (this repo's
  # container test harness), these are harmless no-ops: the by-label symlink is
  # created there by other means (see shani-testbed/lib/disk.sh).
  sudo udevadm trigger --action=change "${efi_device}" 2>/dev/null || true
  sudo udevadm settle 2>/dev/null || sleep 3
  mount_tracked /mnt/boot/efi sudo mount --mkdir "/dev/disk/by-label/${BOOTLABEL}" /mnt/boot/efi \
    || die "EFI partition mount failed"
}

# Function: check_label_clash
# fstab, configure.sh and the initramfs hooks find root and the ESP by label
# (shani_root / shani_boot). Another disk that already carries one - an earlier
# ShaniOS install, e.g. on the internal disk while installing to an external
# SSD - makes each of those lookups pick either disk, at install and at every
# boot. Refuse before formatting, and name the device. Never relabel it: it may
# be someone's working system. Labels this install overwrites don't count: the
# whole target disk, or in partition mode the two partitions it formats.
check_label_clash() {
  local label dev t own="" clashes=()
  # Everything this install overwrites: the target (whole disk, or the two
  # partitions) and every device inside it - partitions, an open LUKS mapper.
  # By lsblk's tree, not by TYPE: a loop or dm parent is not TYPE "disk".
  if [[ "${OSI_DEVICE_IS_PARTITION:-0}" -eq 1 ]]; then t="${ROOT_PARTITION} ${EFI_PARTITION}"
  else t="${OSI_DEVICE_PATH}"; fi
  for dev in ${t}; do
    own+=" $(lsblk -nlpo NAME "$(readlink -f "${dev}")" 2>/dev/null | tr '\n' ' ')"
  done
  for label in "${ROOTLABEL}" "${BOOTLABEL}"; do
    while read -r dev; do
      [[ -n "${dev}" ]] || continue
      [[ " ${own} " == *" $(readlink -f "${dev}") "* ]] && continue
      clashes+=("${dev} (LABEL=${label})")
    # blkid exits 2 on no match - the normal case; without || true the ERR
    # trap fired in the substitution's subshell (and ran the cleanup stack)
    done < <(sudo blkid -o device -t "LABEL=${label}" 2>/dev/null || true)
  done
  (( ${#clashes[@]} == 0 )) && return 0
  log_error "Another disk already has a ShaniOS label: ${clashes[*]}"
  log_error "ShaniOS finds its disks by these labels, so with both connected either one could be used."
  die "Disconnect that disk (or remove the old ShaniOS install on it), then run the installer again."
}

# Function: create_filesystems
# Format and mount the EFI partition and create the Btrfs filesystem on the root partition.
create_filesystems() {
  check_label_clash
  # Format and mount the EFI partition using the global EFI_PARTITION variable.
  log_info "Formatting EFI partition (${EFI_PARTITION}) as FAT32 with label ${BOOTLABEL}"
  sudo mkfs.fat -F32 "${EFI_PARTITION}" -n "${BOOTLABEL}" || die "EFI partition formatting failed"
  mount_boot_partition "${EFI_PARTITION}"

  # Set up encryption on the root partition if requested.
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    log_info "Setting up LUKS encryption on ${ROOT_PARTITION} (argon2id KDF)"

    # Write the passphrase to a private (mode 600, mktemp-created) temp file
    # instead of piping it through `echo`. `echo "$PIN" | cryptsetup ...`
    # spawns a sibling `echo` process whose argv — and therefore the
    # passphrase — is visible to any local user via `ps aux` /
    # /proc/<pid>/cmdline for as long as that process runs, and again in any
    # `set -x` trace. cryptsetup's own argv never contains the secret either
    # way; --key-file=<path> keeps it out of every process's argv entirely.
    # mktemp creates the file with mode 0600 up front (no window where a
    # broader mode is briefly in effect); chmod again defensively.
    local luks_key_file
    luks_key_file=$(mktemp) || die "Failed to create temporary LUKS key file"
    chmod 600 "${luks_key_file}"

    # Writing the passphrase as a literal argument (even to a builtin like
    # printf) is still shown verbatim by `set -x`/BASH_XTRACEFD — xtrace
    # prints a simple command's expanded words regardless of whether the
    # command is a builtin or external, so this alone wouldn't close that
    # leak vector. Suspend xtrace for this one assignment (restoring it
    # immediately after) so the plaintext passphrase is never written to the
    # trace stream even if the caller invoked this script with -x.
    case $- in *x*) _oic_had_xtrace=1 ;; *) _oic_had_xtrace=0 ;; esac
    set +x
    printf '%s' "${OSI_ENCRYPTION_PIN}" > "${luks_key_file}"
    [[ "${_oic_had_xtrace}" -eq 1 ]] && set -x
    unset _oic_had_xtrace

    if ! sudo cryptsetup -q luksFormat --pbkdf argon2id --key-file="${luks_key_file}" "${ROOT_PARTITION}"; then
      shred -u "${luks_key_file}" 2>/dev/null || rm -f "${luks_key_file}"
      die "LUKS format failed on ${ROOT_PARTITION}"
    fi
    if ! sudo cryptsetup open --key-file="${luks_key_file}" "${ROOT_PARTITION}" "${ROOTLABEL}"; then
      shred -u "${luks_key_file}" 2>/dev/null || rm -f "${luks_key_file}"
      die "LUKS open failed on ${ROOT_PARTITION}"
    fi
    _push_cleanup "sudo cryptsetup close '${ROOTLABEL}' 2>/dev/null || true"
    shred -u "${luks_key_file}" 2>/dev/null || rm -f "${luks_key_file}"

    BTRFS_TARGET="/dev/mapper/${ROOTLABEL}"
  else
    BTRFS_TARGET="${ROOT_PARTITION}"
  fi

  log_info "Creating Btrfs filesystem on ${BTRFS_TARGET} with label ${ROOTLABEL}"
  sudo mkfs.btrfs -f -L "${ROOTLABEL}" "${BTRFS_TARGET}" || die "Btrfs filesystem creation failed"
}

# Function: mount_top_level
# Mount the newly created Btrfs filesystem at /mnt with the given options.
mount_top_level() {
  log_info "Mounting Btrfs top-level filesystem on /mnt"
  mount_tracked /mnt sudo mount -o "${BTRFS_TOP_OPTS}" "${BTRFS_TARGET}" /mnt || die "Mounting top-level filesystem failed"
}

# Function: create_subvolumes
# Create the necessary Btrfs subvolumes and additional directories.
create_subvolumes() {
  log_info "Creating required Btrfs subvolumes and directories"
  # BTRFS_SUBVOLUMES is a space-separated list, but the script's global IFS is
  # newline/tab (so filenames with spaces survive elsewhere). Inheriting that
  # IFS here makes the array one element — literally "@/root @home @data ..." —
  # so @swap is never created and swapfile creation fails. Split on whitespace
  # explicitly; the local IFS is restored when the function returns.
  local IFS=$' \t\n'
  local subvolumes=( ${BTRFS_SUBVOLUMES} )
  for subvol in "${subvolumes[@]}"; do
    if ! sudo btrfs subvolume list /mnt | grep -q "path ${subvol}\$"; then
      log_info "Creating subvolume ${subvol}"
      sudo btrfs subvolume create "/mnt/${subvol}" || die "Failed to create subvolume ${subvol}"
      # @swap must have no-COW set — Btrfs requires it for swapfiles and for
      # nodatacow mount option to take effect. Set it immediately after creation
      # before any data is written.
      if [[ "${subvol}" == "@swap" ]]; then
        sudo chattr +C "/mnt/${subvol}" 2>/dev/null \
          || log_warn "Could not set no-COW on @swap — swapfile creation may fail"
      fi
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
      sudo mkdir -p "${full_dir}" || die "Failed to create directory ${full_dir}"
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
    "varlib/extensions"
    "varlib/fontconfig"
    # Network & Connectivity
    "varlib/NetworkManager"
    "varlib/bluetooth"
    "varlib/firewalld"
    # File Sharing & Network Services
    "varlib/samba"
    "varlib/nfs"
    # Remote Access & VPN Services
    "varlib/caddy"
    "varlib/tailscale"
    "varlib/cloudflared"
    "varlib/geoclue"
    # Display Managers
    "varlib/gdm"
    "varlib/sddm"
    "varlib/plasmalogin"
    # Audio & Peripherals
    "varlib/colord"
    "varlib/pipewire"
    "varlib/rtkit"
    "varlib/cups"
    "varlib/sane"
    "varlib/upower"
    # User Authentication & Security
    "varlib/fprint"
    "varlib/AccountsService"
    "varlib/boltd"
    "varlib/sudo"
    "varlib/sshd"
    "varlib/polkit-1"
    # Hardware & Firmware
    "varlib/fwupd"
    "varlib/tpm2-tss"
    # Data Protection & Persistence
    "varlib/fail2ban"
    "varlib/restic"
    "varlib/rclone"
    "varlib/appimage"
    # Job Scheduling Spool
    "varspool/anacron"
    "varspool/cron"
    "varspool/at"
    # Print & Mail Spools
    "varspool/cups"
    "varspool/samba"
    "varspool/postfix"
    # User Downloads
    "downloads"
  )

  for dir in "${varlib_dirs[@]}"; do
    local full_dir="/mnt/@data/${dir}"
    if [ ! -d "${full_dir}" ]; then
      log_info "Creating service directory ${full_dir}"
      sudo mkdir -p "${full_dir}" || die "Failed to create directory ${full_dir}"
    else
      log_info "Service directory ${full_dir} already exists"
    fi
  done

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
  sudo btrfs subvolume snapshot -r "/mnt/shanios_base" "/mnt/@blue" || die "Snapshot creation for @blue failed"
  log_info "Creating snapshot @green from @blue"
  sudo btrfs subvolume snapshot -r "/mnt/@blue" "/mnt/@green" || die "Snapshot creation for @green failed"
  log_info "Deleting original subvolume shanios_base"
  sudo btrfs subvolume delete "/mnt/shanios_base" || log_warn "Could not delete shanios_base; please remove manually later"
  log_info "Setting active slot marker to 'blue'"
  echo "blue" | sudo tee "/mnt/@data/current-slot" > /dev/null || die "Failed to set active slot marker"
  log_info "Setting previous slot marker to 'green'"
  echo "green" | sudo tee "/mnt/@data/previous-slot" > /dev/null || die "Failed to set previous slot marker"
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

  # Delete existing @flatpak if present (idempotent install safety)
  if sudo btrfs subvolume show "/mnt/@flatpak" &>/dev/null; then
    log_info "Existing @flatpak detected — deleting before reseeding"
    sudo btrfs subvolume delete "/mnt/@flatpak" \
      || die "Failed to delete existing @flatpak"
  fi

  log_info "Creating snapshot @flatpak from flatpak_subvol"
  sudo btrfs subvolume snapshot "/mnt/flatpak_subvol" "/mnt/@flatpak" || die "Snapshot creation for @flatpak failed"
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

  # Delete existing @snapd if present (idempotent install safety)
  if sudo btrfs subvolume show "/mnt/@snapd" &>/dev/null; then
    log_info "Existing @snapd detected — deleting before reseeding"
    sudo btrfs subvolume delete "/mnt/@snapd" \
      || die "Failed to delete existing @snapd"
  fi

  log_info "Creating snapshot @snapd from snapd_subvol"
  sudo btrfs subvolume snapshot "/mnt/snapd_subvol" "/mnt/@snapd" || die "Snapshot creation for @snapd failed"
  log_info "Deleting original subvolume snapd_subvol"
  sudo btrfs subvolume delete "/mnt/snapd_subvol" || log_warn "Could not delete snap_subvol; please remove manually later"
}

# Function: extract_aimodels_image
# Decompress and load the AI models image, then create a snapshot.
extract_aimodels_image() {
  log_info "Extracting AI models image into /mnt"
  extract_image "${AIMODELSFS_SOURCE}" "/mnt"
  if sudo btrfs subvolume show "/mnt/shani-chronoa_subvol" &>/dev/null; then
    log_info "Subvolume 'shani-chronoa_subvol' detected"
  else
    log_error "Subvolume 'shani-chronoa_subvol' not found after extraction"
    exit 1
  fi

  # Delete existing @shani-chronoa if present (idempotent install safety)
  if sudo btrfs subvolume show "/mnt/@shani-chronoa" &>/dev/null; then
    log_info "Existing @shani-chronoa detected — deleting before reseeding"
    sudo btrfs subvolume delete "/mnt/@shani-chronoa" \
      || die "Failed to delete existing @shani-chronoa"
  fi

  log_info "Creating snapshot @shani-chronoa from shani-chronoa_subvol"
  sudo btrfs subvolume snapshot "/mnt/shani-chronoa_subvol" "/mnt/@shani-chronoa" || die "Snapshot creation for @shani-chronoa failed"
  log_info "Deleting original subvolume shani-chronoa_subvol"
  sudo btrfs subvolume delete "/mnt/shani-chronoa_subvol" || log_warn "Could not delete shani-chronoa_subvol; please remove manually later"
}

# Function: create_swapfile
# Create a swapfile within the @swap subvolume and activate it.
create_swapfile() {
  local available_mb size_mb
  available_mb=$(df -BM /mnt | awk 'NR==2 {print $4}' | sed 's/M//')

  # Sized to RAM (what hibernation needs), but never into the space updates
  # need: shani-deploy refuses to update with less than 10 GB free, and a
  # RAM-sized swapfile on a small disk (16 GB RAM, 32 GB disk) left 1-5 GB -
  # no update could ever install. Keep UPDATE_RESERVE_MB (10 GB + 2 GB
  # headroom) free; below 1 GB of swap, skip it (zram covers swap).
  local reserve_mb="${UPDATE_RESERVE_MB:-12288}"
  size_mb=$(( available_mb - reserve_mb ))
  (( size_mb > SWAPFILE_SIZE )) && size_mb=${SWAPFILE_SIZE}
  if (( size_mb < 1024 )); then
    log_warn "No room for a swapfile after keeping ${reserve_mb}MB free for updates (available: ${available_mb}MB)"
    log_info "Skipping swapfile creation. System will use zram for swap."
    return 0
  fi
  if (( size_mb < SWAPFILE_SIZE )); then
    log_warn "Swapfile ${size_mb}MB, smaller than RAM (${SWAPFILE_SIZE}MB) to keep ${reserve_mb}MB free for updates - hibernation needs swap >= RAM and may not be available"
  fi

  log_info "Creating ${size_mb}MB swapfile at /mnt/${SWAPFILE_PATH} (${available_mb}MB free before)"
  sudo btrfs filesystem mkswapfile --size "${size_mb}M" "/mnt/${SWAPFILE_PATH}" || die "Swapfile creation failed"
  sudo swapon "/mnt/${SWAPFILE_PATH}" || die "Swapfile activation failed"
}

# Main setup function: run all steps sequentially.
# Reinstall keeping /data: the disk is not re-partitioned and the btrfs is
# not mkfs'd. The system subvolumes are replaced; @home and @data (the user's
# data) are left alone. The ESP is reformatted and the bootloader reinstalled.
keep_data_setup() {
  log_info "Reinstall keeping /data: reusing the existing filesystem"

  # Open the existing LUKS, as create_filesystems does for a fresh install.
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    local luks_key_file
    luks_key_file=$(mktemp) || die "Failed to create temporary LUKS key file"
    chmod 600 "${luks_key_file}"
    case $- in *x*) _oic_had_xtrace=1 ;; *) _oic_had_xtrace=0 ;; esac
    set +x
    printf '%s' "${OSI_ENCRYPTION_PIN}" > "${luks_key_file}"
    [[ "${_oic_had_xtrace}" -eq 1 ]] && set -x
    if ! sudo cryptsetup open --key-file="${luks_key_file}" "${ROOT_PARTITION}" "${ROOTLABEL}"; then
      shred -u "${luks_key_file}" 2>/dev/null || rm -f "${luks_key_file}"
      die "The disk passphrase is not right - it is the one typed at every boot of this machine (keep /data)."
    fi
    shred -u "${luks_key_file}" 2>/dev/null || rm -f "${luks_key_file}"
  fi

  mount_boot_partition "${EFI_PARTITION}"
  mount_top_level

  # Drop the system subvolumes; @home and @data are the user's.
  local sub
  for sub in @root @nix @cache @log @flatpak @snapd @waydroid @containers \
             @machines @lxc @lxd @libvirt @qemu @swap; do
    if [[ -d "/mnt/${sub}" ]]; then
      sudo btrfs subvolume delete "/mnt/${sub}" \
        || die "Could not delete /mnt/${sub} (keep /data)"
    fi
  done

  create_subvolumes
  fetch_newer_image
  extract_system_image
}

# Function: check_target_not_in_use
# Refuse a target that is mounted, used as swap, or holds the live medium this
# installer is running from - before anything is partitioned or formatted.
# Partitioning a disk in use destroys the running live system or another
# system's mounted files, and the os-installer page that picks the disk is not
# the last line of defence: this script is what runs sfdisk. (The check is
# Ananta OS's SysApp-Test-1: "the live medium and mounted disks - refuses those
# disks".) Whole-disk mode checks the disk and everything on it; partition mode
# checks the two partitions it formats.
check_target_not_in_use() {
  local targets dev name mps live_src live_disk busy=()
  if [[ "${OSI_DEVICE_IS_PARTITION:-0}" -eq 1 ]]; then targets="${ROOT_PARTITION} ${EFI_PARTITION}"
  else targets="${OSI_DEVICE_PATH}"; fi
  for dev in ${targets}; do
    dev=$(readlink -f "${dev}")
    while read -r name mps; do
      [[ -n "${mps}" ]] && busy+=("${name} (${mps//$'\n'/, })")
    done < <(lsblk -nlpo NAME,MOUNTPOINTS "${dev}" 2>/dev/null || true)
  done
  # The live medium: whatever disk holds the mounted ISO (archiso's bootmnt).
  live_src=$(findmnt -nvo SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ -n "${live_src}" ]]; then
    live_disk=$(lsblk -nlpo PKNAME "${live_src}" 2>/dev/null | head -1)
    live_disk=${live_disk:-${live_src}}
    for dev in ${targets}; do
      dev=$(readlink -f "${dev}")
      if [[ "${dev}" == "${live_disk}" || "${dev}" == "${live_src}" \
            || "$(lsblk -nlpo PKNAME "${dev}" 2>/dev/null | head -1)" == "${live_disk}" ]]; then
        busy+=("${dev} (the live medium this installer started from)")
      fi
    done
  fi
  (( ${#busy[@]} == 0 )) && return 0
  log_error "The install target is in use - nothing was changed:"
  local b; for b in "${busy[@]}"; do log_error "  ${b}"; done
  die "Choose another disk, or unmount it first."
}

do_setup() {
  _progress_total "${ROOTFSZST_SOURCE}" "${FLATPAKFS_SOURCE}" "${SNAPFS_SOURCE}" "${AIMODELSFS_SOURCE}"
  check_target_not_in_use
  if [[ "${KEEP_DATA}" == "1" ]]; then
    keep_data_setup
  else
    do_partitioning
    create_filesystems
    mount_top_level
    create_subvolumes
    fetch_newer_image
    extract_system_image
  fi

  if [[ -f "${FLATPAKFS_SOURCE}" ]]; then
    extract_flatpak_image
  else
    log_info "Skipping Flatpak image extraction (flatpakfs.zst not present on ISO)."
  fi

  if [[ -f "${SNAPFS_SOURCE}" ]]; then
    extract_snap_image
  else
    log_info "Skipping Snap image extraction (snapfs.zst not present on ISO)."
  fi

  if [[ -f "${AIMODELSFS_SOURCE}" ]]; then
    extract_aimodels_image
  else
    log_info "Skipping AI models image extraction (aimodelsfs.zst not present on ISO)."
  fi

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

  _progress 100
  log_info "Installation complete: Disk setup and blue-green configuration finished."
  log_info "IMPORTANT: Update /mnt/etc/fstab and configure your bootloader."
}

do_setup
