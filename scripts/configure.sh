#!/bin/bash
# configure.sh – Post-installation configuration for Shani OS.
# This script configures system settings (locale, keyboard, timezone, hostname,
# machine-id, user accounts, secure boot, and bootloader entries) in the installed system.
# It also mounts all required Btrfs subvolumes to establish the full system hierarchy.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[CONFIG][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

### Configuration variables
OS_NAME="shanios"
OSIDIR="/etc/os-installer"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
CMDLINE_FILE_CURRENT="/etc/kernel/install_cmdline_blue"
CMDLINE_FILE_CANDIDATE="/etc/kernel/install_cmdline_green"
UKI_BOOT_ENTRY="/boot/efi/loader/entries"
CURRENT_SLOT_FILE="/data/current-slot"  # Within the installed system

# Required environment variables
required_vars=(
  OSI_LOCALE
  OSI_DEVICE_PATH
  OSI_DEVICE_IS_PARTITION
  OSI_DEVICE_EFI_PARTITION
  OSI_USE_ENCRYPTION
  OSI_USER_NAME
  OSI_USER_AUTOLOGIN
  OSI_FORMATS
  OSI_TIMEZONE
  OSI_KEYBOARD_LAYOUT
)
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[CONFIG][ERROR] Environment variable '$var' is not set" >&2
    exit 1
  fi
done

# Warn if encryption is enabled but no encryption PIN is provided.
if [[ "${OSI_USE_ENCRYPTION}" -eq 1 && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
  echo "[CONFIG][WARN] OSI_USE_ENCRYPTION is enabled, but OSI_ENCRYPTION_PIN is not provided. Proceeding without it." >&2
fi

# Logging functions (consistent with install.sh)
log_info() { echo "[CONFIG][INFO] $*"; }
log_warn() { echo "[CONFIG][WARN] $*" >&2; }
log_error() { echo "[CONFIG][ERROR] $*" >&2; }
die() { log_error "$*"; exit 1; }

TARGET="/mnt"

# Function: mount_target
# Mount the active system subvolume and necessary pseudo-filesystems.
mount_target() {
  local temp_root
  temp_root=$(mktemp -d)
  log_info "Determining active slot from @data"
  sudo mount -o subvolid=5 /dev/disk/by-label/"${ROOTLABEL}" "$temp_root" || die "Root mount failed"
  
  if [[ -f "$temp_root/@data/current-slot" ]]; then
    ACTIVE_SLOT=$(< "$temp_root/@data/current-slot")
  else
    ACTIVE_SLOT="blue"
    echo "$ACTIVE_SLOT" | sudo tee "$temp_root/@data/current-slot" >/dev/null
  fi
  sudo umount "$temp_root" && rmdir "$temp_root"

  log_info "Mounting active system subvolume (@${ACTIVE_SLOT}) at ${TARGET}"
  sudo mount -o "subvol=@${ACTIVE_SLOT}" /dev/disk/by-label/"${ROOTLABEL}" "${TARGET}" || die "Active slot mount failed"
  
  for fs in proc sys dev run; do
    sudo mount --rbind "/$fs" "${TARGET}/$fs" || die "Failed to mount /$fs"
  done
  sudo mount --mkdir /dev/disk/by-label/"${BOOTLABEL}" "${TARGET}/boot/efi" || die "EFI partition mount failed"
}

# Function: mount_additional_subvols
# Mount the remaining Btrfs subvolumes to their designated mount points.
mount_additional_subvols() {
  local device="/dev/disk/by-label/${ROOTLABEL}"
  
  # Define the subvolumes with target paths and additional mount options.
  declare -A subvols=(
    ["@home"]="/home|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@data"]="/data|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@log"]="/var/log|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@flatpak"]="/var/lib/flatpak|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@containers"]="/var/lib/containers|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@swap"]="/swap|rw,noatime,nodatacow,nospace_cache"
  )

  # Loop through each subvolume in the associative array.
  for subvol in "${!subvols[@]}"; do
    # Split the array value into target path and mount options using the '|' delimiter.
    IFS='|' read -r target options <<< "${subvols[$subvol]}"
    log_info "Mounting subvolume ${subvol} to ${TARGET}${target} with options: ${options}"
    sudo mkdir -p "${TARGET}${target}"
    sudo mount -t btrfs -o "subvol=${subvol},${options}" "$device" "${TARGET}${target}" \
      || die "Failed to mount subvolume ${subvol} to ${TARGET}${target}"
  done
}

# Function: mount_overlay
# Configure an overlay mount for /etc.
mount_overlay() {
  log_info "Configuring overlay for /etc"

  # Create necessary overlay directories in the data subvolume (matching fstab paths)
  sudo mkdir -p "${TARGET}/data/overlay/etc/lower" \
               "${TARGET}/data/overlay/etc/upper" \
               "${TARGET}/data/overlay/etc/work"

  # Bind mount the original /etc to the overlay lower directory
  log_info "Bind mounting original /etc to ${TARGET}/data/overlay/etc/lower"
  sudo mount --bind "${TARGET}/etc" "${TARGET}/data/overlay/etc/lower" || die "Bind mount of /etc failed"
  sudo mount -o remount,ro,bind "${TARGET}/data/overlay/etc/lower" || die "Remounting lower overlay directory as read-only failed"

  # Mount the overlay using the correct lower, upper, and work directories
  log_info "Mounting overlay on /etc"
  sudo mount -t overlay overlay -o "lowerdir=${TARGET}/data/overlay/etc/lower,upperdir=${TARGET}/data/overlay/etc/upper,workdir=${TARGET}/data/overlay/etc/work,index=off,metacopy=off" "${TARGET}/etc" || die "Overlay mount failed"
}

# Function: run_in_target
# Execute a command in the mounted target environment.
run_in_target() {
  sudo chroot "${TARGET}" /bin/bash -c "$1"
}

# Function: setup_locale_target
setup_locale_target() {
  log_info "Configuring locale to ${OSI_LOCALE}"
  run_in_target "echo \"LANG=${OSI_LOCALE}\" > /etc/locale.conf && localectl set-locale LANG='${OSI_LOCALE}'"
  [ -n "${OSI_FORMATS}" ] && run_in_target "localectl set-locale '${OSI_FORMATS}'"
}

# Function: setup_keyboard_target
setup_keyboard_target() {
  log_info "Configuring keyboard layout: ${OSI_KEYBOARD_LAYOUT}"
  run_in_target "echo \"KEYMAP=${OSI_KEYBOARD_LAYOUT}\" > /etc/vconsole.conf && localectl set-keymap '${OSI_KEYBOARD_LAYOUT}' && localectl set-x11-keymap '${OSI_KEYBOARD_LAYOUT}'"
}

# Function: setup_timezone_target
setup_timezone_target() {
  log_info "Setting timezone to ${OSI_TIMEZONE}"
  run_in_target "ln -sf \"/usr/share/zoneinfo/${OSI_TIMEZONE}\" /etc/localtime && echo '${OSI_TIMEZONE}' > /etc/timezone && timedatectl set-timezone '${OSI_TIMEZONE}'"
}

# Function: setup_hostname_target
setup_hostname_target() {
  log_info "Setting hostname to ${OS_NAME}"
  run_in_target "echo \"${OS_NAME}\" > /etc/hostname && hostnamectl set-hostname '${OS_NAME}'"
}

# Function: setup_machine_id_target
setup_machine_id_target() {
  log_info "Generating new machine-id"
  run_in_target "systemd-machine-id-setup --commit"
}

# Function: setup_user_target
setup_user_target() {
  log_info "Creating primary user: ${OSI_USER_NAME}"
  local groups=("wheel" "input" "realtime" "video" "sys" "cups" "lp" "libvirt" "kvm" "scanner")
  run_in_target "useradd -m -s /bin/zsh -G '$(IFS=,; echo "${groups[*]}")' '${OSI_USER_NAME}'" || die "User creation failed"
  if [[ -n "${OSI_USER_PASSWORD:-}" ]]; then
    printf "%s:%s" "${OSI_USER_NAME}" "${OSI_USER_PASSWORD}" | run_in_target "chpasswd" || die "Failed to set user password"
  else
    log_warn "No user password provided, user account created without a password."
  fi
  # Create a sudoers drop-in file for the wheel group granting full sudo privileges.
  run_in_target "echo -e '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/99_wheel && chmod 0440 /etc/sudoers.d/99_wheel" \
    || die "Failed to configure sudoers for wheel group"
}

# Function: setup_autologin_target
setup_autologin_target() {
  if [[ "${OSI_USER_AUTOLOGIN}" -eq 1 ]]; then
    if run_in_target "command -v gdm >/dev/null"; then
      log_info "Configuring GDM autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/gdm && printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=${OSI_USER_NAME}\n' > /etc/gdm/custom.conf"
    else
      log_info "Configuring getty autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/systemd/system/getty@tty1.service.d && printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin ${OSI_USER_NAME} --noclear %%I \$TERM\n' > /etc/systemd/system/getty@tty1.service.d/autologin.conf"
    fi
  fi
}

# Function: set_root_password
set_root_password() {
  if [[ -n "${OSI_USER_PASSWORD:-}" ]]; then
    log_info "Setting root password"
    printf "root:%s" "${OSI_USER_PASSWORD}" | run_in_target "chpasswd"
  else
    log_info "No root password provided; locking root account"
    run_in_target "passwd --lock root"
  fi
}

# Create Plymouth configuration to set the theme to shani-bgrt.
setup_plymouth_theme_target() {
  log_info "Configuring Plymouth theme to shani-bgrt"
  run_in_target "mkdir -p /etc/plymouth && { echo '[Daemon]'; echo 'Theme=bgrt'; } > /etc/plymouth/plymouthd.conf"
}

# Function: generate_mok_keys_target
generate_mok_keys_target() {
  log_info "Generating MOK keys for secure boot"
  run_in_target "mkdir -p /usr/share/secureboot/keys && \
    if [ ! -f /usr/share/secureboot/keys/MOK.key ]; then
      openssl req -newkey rsa:4096 -nodes -keyout /usr/share/secureboot/keys/MOK.key \
        -new -x509 -sha256 -days 3650 -out /usr/share/secureboot/keys/MOK.crt \
        -subj '/CN=Shani OS Secure Boot Key/' && \
      openssl x509 -in /usr/share/secureboot/keys/MOK.crt -outform DER -out /usr/share/secureboot/keys/MOK.der && \
      chmod 0600 /usr/share/secureboot/keys/MOK.key
    fi"
}

# Function: install_secureboot_components_target
install_secureboot_components_target() {
  log_info "Installing secure boot components"
  run_in_target "mkdir -p /boot/efi/EFI/BOOT && \
    cp /usr/share/shim-signed/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI && \
    cp /usr/share/shim-signed/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi && \
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi"
}

# Function: sign_efi_binary
sign_efi_binary() {
  local binary="$1"
  log_info "Signing EFI binary ${binary}"
  run_in_target "sbsign --key /usr/share/secureboot/keys/MOK.key --cert /usr/share/secureboot/keys/MOK.crt --output ${binary} ${binary} && sbverify --cert /usr/share/secureboot/keys/MOK.crt ${binary}"
}

# Function: enroll_mok_key_target
enroll_mok_key_target() {
  if [[ -n "${OSI_USER_PASSWORD:-}" ]]; then
    log_info "Enrolling MOK key for secure boot"
    run_in_target "printf '%s\n%s\n' '${OSI_USER_PASSWORD}' '${OSI_USER_PASSWORD}' | mokutil --import /usr/share/secureboot/keys/MOK.der"
  else
    log_warn "Skipping MOK key enrollment because OSI_USER_PASSWORD is not provided"
  fi
}

bypass_mok_prompt_target() {
  log_info "Attempting to bypass MOK prompt"
  run_in_target "mkdir -p /sys/firmware/efi/efivars"
  run_in_target "mount --bind /sys/firmware/efi/efivars /sys/firmware/efi/efivars"
  run_in_target 'bash -c "
    if [[ -f /usr/share/secureboot/keys/MOK.der ]]; then
      efivar -n MOKList -w -d /usr/share/secureboot/keys/MOK.der  || true;
    fi
  "'
  # Pipe the password (twice, as required) into mokutil --disable-validation.
  run_in_target "printf '%s\n%s\n' '${OSI_USER_PASSWORD}' '${OSI_USER_PASSWORD}' | mokutil --disable-validation"
  run_in_target "umount /sys/firmware/efi/efivars"
}

# Function: get_kernel_version
get_kernel_version() {
  run_in_target "ls -1 /usr/lib/modules | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1"
}

# Function: generate_uki_entry
# Generate a Unified Kernel Image (UKI) and bootloader entry for a given slot.
generate_uki_entry() {
  local slot="$1"

  # Retrieve the filesystem UUID from the partition labeled with ROOTLABEL.
  local fs_uuid
  fs_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}")

  # Retrieve the LUKS UUID only if encryption is enabled.
  local luks_uuid
  luks_uuid=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && run_in_target "blkid -s UUID -o value /dev/mapper/${ROOTLABEL}" || echo "" )

  # Determine the root device and additional encryption parameters.
  local rootdev
  rootdev=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo "/dev/mapper/${ROOTLABEL}" || echo "UUID=${fs_uuid}" )
  local encryption_params
  encryption_params=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo " rd.luks.uuid=${luks_uuid} rd.luks.name=${luks_uuid}=${ROOTLABEL} rd.luks.options=${luks_uuid}=tpm2-device=auto" || echo "" )

  # Build the kernel command line.
  local cmdline="quiet splash rootfstype=btrfs rootflags=subvol=@${slot},ro,compress=zstd,space_cache=v2,autodefrag${encryption_params} root=${rootdev}"

  # Set the resume UUID (LUKS UUID if encrypted, otherwise filesystem UUID).
  local resume_uuid
  resume_uuid=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo "${luks_uuid}" || echo "${fs_uuid}" )

  # Append swap parameters if a swap file exists.
  if run_in_target "[ -f /swap/swapfile ]"; then
      local swap_offset
      swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print \$NF}'")
      cmdline+=" resume=UUID=${resume_uuid} resume_offset=${swap_offset}"
  fi

  # Determine the appropriate command line file based on the current slot.
  local current_slot
  current_slot=$(run_in_target "cat ${CURRENT_SLOT_FILE}")
  local cmdfile
  cmdfile=$( [[ "$slot" == "$current_slot" ]] && echo "${CMDLINE_FILE_CURRENT}" || echo "${CMDLINE_FILE_CANDIDATE}" )
  run_in_target "echo '${cmdline}' > ${cmdfile}"

  # Build the EFI binary using dracut.
  local kernel_version
  kernel_version=$(get_kernel_version)
  local uki_path="/boot/efi/EFI/${OS_NAME}/${OS_NAME}-${slot}.efi"
  run_in_target "mkdir -p /boot/efi/EFI/${OS_NAME}/"
  run_in_target "dracut --force --uefi --kver ${kernel_version} --kernel-cmdline \"${cmdline}\" ${uki_path}"
  sign_efi_binary "${uki_path}"

  # Create the boot entry file for the loader.
  run_in_target "mkdir -p ${UKI_BOOT_ENTRY} && cat > ${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}.conf <<EOF
title   ${OS_NAME}-${slot}
efi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi
EOF"

}

generate_loader_conf() {
  local slot="$1"
  # Update the loader configuration.
  run_in_target "mkdir -p /boot/efi/loader && cat > /boot/efi/loader/loader.conf <<EOF
default ${OS_NAME}-${slot}.conf
timeout 5
console-mode max
editor 0
EOF"
}

# Main configuration function
main() {
  mount_target
  mount_additional_subvols
  mount_overlay

  setup_locale_target
  setup_keyboard_target
  setup_timezone_target
  setup_hostname_target
  setup_machine_id_target
  setup_user_target
  set_root_password
  setup_autologin_target
  setup_plymouth_theme_target
  generate_mok_keys_target
  install_secureboot_components_target

  local current_slot
  current_slot=$(run_in_target "cat ${CURRENT_SLOT_FILE}")
  local candidate_slot
  if [ "${current_slot}" == "blue" ]; then
    candidate_slot="green"
  else
    candidate_slot="blue"
  fi

  generate_uki_entry "${current_slot}"
  generate_uki_entry "${candidate_slot}"
  generate_loader_conf "${current_slot}"
  enroll_mok_key_target
  log_info "Configuration completed successfully!"
}

main

