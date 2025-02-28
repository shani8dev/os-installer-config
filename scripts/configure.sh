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

  sudo chmod 0755 "${TARGET}/data/overlay/etc/lower" \
              "${TARGET}/data/overlay/etc/upper" \
              "${TARGET}/data/overlay/etc/work"

  # Mount the overlay using the correct lower, upper, and work directories
  log_info "Mounting overlay on /etc"
  sudo mount -t overlay overlay -o "lowerdir=${TARGET}/etc,upperdir=${TARGET}/data/overlay/etc/upper,workdir=${TARGET}/data/overlay/etc/work,index=off,metacopy=off" "${TARGET}/etc" || die "Overlay mount failed"
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
    for group in "${groups[@]}"; do
    		if ! run_in_target "getent group ${group}" >/dev/null; then
      		run_in_target "groupadd ${group}" || log_warn "Failed to create group ${group}"
    		fi
  	done
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
      openssl req -newkey rsa:2048 -nodes -keyout /usr/share/secureboot/keys/MOK.key \
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

move_keyfile_to_systemd() {
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
  	log_info "Relocating keyfile to systemd directory"
  	local src_keyfile="/boot/efi/crypto_keyfile.bin"
  	local dest_dir="/etc/cryptsetup-keys.d"
  
	  if run_in_target "[ -f ${src_keyfile} ]"; then
		# Move keyfile to systemd's cryptsetup directory
		run_in_target "mkdir -p ${dest_dir} && \
		  mv ${src_keyfile} ${dest_dir}/${ROOTLABEL}.bin && \
		  chmod 0400 ${dest_dir}/${ROOTLABEL}.bin"
	  else
		log_warn "No keyfile found in EFI partition; assuming manual unlock"
	  fi
  else
    log_info "Encryption not enabled; skipping the cryptfile relocation"
  fi
}

# Function: generate_crypttab_target
# Updated to dynamically derive the LUKS UUID from the underlying block device.
generate_crypttab_target() {
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    log_info "Generating /etc/crypttab in the target system"
    local parent
    parent=$(run_in_target "lsblk -no PKNAME /dev/mapper/${ROOTLABEL} | head -n1" | tr -d '\n')
    [[ -z "$parent" ]] && die "Failed to determine underlying device for /dev/mapper/${ROOTLABEL}"
    local underlying="/dev/${parent}"
    local luks_uuid
    luks_uuid=$(run_in_target "cryptsetup luksUUID ${underlying}" | tr -d '\n')
    [[ -z "$luks_uuid" ]] && die "Failed to retrieve LUKS UUID from ${underlying}"
    
    local keyfile_path="/etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
    local keyfile_option=""
    if run_in_target "[ -f '${keyfile_path}' ]"; then
      keyfile_option="${keyfile_path}"
    fi

    local entry="luks-${luks_uuid} UUID=${luks_uuid} ${keyfile_option} luks,discard"
    run_in_target "echo '${entry}' > /etc/crypttab"
    log_info "/etc/crypttab generated with entry: ${entry}"
  else
    log_info "Encryption not enabled; skipping /etc/crypttab generation"
  fi
}

# Function: crypt_dracut_conf function:
crypt_dracut_conf() {
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
  log_info "Configuring dracut for encryption"
  local install_items="/etc/crypttab"
  	if run_in_target "[ -f /etc/cryptsetup-keys.d/${ROOTLABEL}.bin ]"; then
    		install_items+=" /etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
  	fi
  	run_in_target "echo 'install_items+=\" ${install_items} \"' > /etc/dracut.conf.d/99-crypt-key.conf"
  else
    log_info "Encryption not enabled; skipping dracut for encryption config generation"
  fi
}

# Function: get_kernel_version
get_kernel_version() {
  run_in_target "ls -1 /usr/lib/modules | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1"
}

# Function: generate_uki_entry
# Generate a Unified Kernel Image (UKI) and bootloader entry for a given slot.
# Updated to derive the LUKS UUID from the underlying block device.
generate_uki_entry() {
  local slot="$1"

  # Retrieve the filesystem UUID from the partition labeled with ROOTLABEL.
  local fs_uuid
  fs_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}")
  
  local luks_uuid=""
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    # Get the parent device for the decrypted mapping.
    local parent
    parent=$(run_in_target "lsblk -no PKNAME /dev/mapper/${ROOTLABEL} | head -n1" | tr -d '\n')
    if [[ -z "$parent" ]]; then
      die "Failed to determine underlying device for /dev/mapper/${ROOTLABEL}"
    fi
    local underlying="/dev/${parent}"
    # Retrieve the LUKS header UUID from the underlying device.
    luks_uuid=$(run_in_target "cryptsetup luksUUID ${underlying}" | tr -d '\n')
    if [[ -z "$luks_uuid" ]]; then
      die "Failed to retrieve LUKS UUID from ${underlying}"
    fi
  fi

  # Determine the root device: if encryption is enabled, use the decrypted mapping;
  # otherwise, use the filesystem UUID.
  local rootdev
  rootdev=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo "/dev/mapper/${ROOTLABEL}" || echo "UUID=${fs_uuid}" )
  local encryption_params
  encryption_params=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo " rd.luks.uuid=${luks_uuid} rd.luks.name=${luks_uuid}=${ROOTLABEL} rd.luks.options=${luks_uuid}=tpm2-device=auto" || echo "" )

  local cmdline="quiet splash systemd.volatile=state rootfstype=btrfs rootflags=subvol=@${slot},ro,noatime,compress=zstd,space_cache=v2,autodefrag${encryption_params} root=${rootdev}"

  local resume_uuid
  resume_uuid=$( [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]] && echo "${luks_uuid}" || echo "${fs_uuid}" )

  if run_in_target "[ -f /swap/swapfile ]"; then
      local swap_offset
      swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print \$NF}'")
      cmdline+=" resume=UUID=${resume_uuid} resume_offset=${swap_offset}"
  fi

  local current_slot
  current_slot=$(run_in_target "cat ${CURRENT_SLOT_FILE}")
  local cmdfile
  cmdfile=$( [[ "$slot" == "$current_slot" ]] && echo "${CMDLINE_FILE_CURRENT}" || echo "${CMDLINE_FILE_CANDIDATE}" )
  run_in_target "echo '${cmdline}' > ${cmdfile}"

  local kernel_version
  kernel_version=$(get_kernel_version)
  local uki_path="/boot/efi/EFI/${OS_NAME}/${OS_NAME}-${slot}.efi"
  run_in_target "mkdir -p /boot/efi/EFI/${OS_NAME}/"
  run_in_target "dracut --force --uefi --kver ${kernel_version} --kernel-cmdline \"${cmdline}\" ${uki_path}"
  sign_efi_binary "${uki_path}"

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
  local efivars="/sys/firmware/efi/efivars"
  local mok_var="MokSBStateRT-605dab50-e046-4300-abb6-3dd810dd8b23"
  local umount_needed=false

  # Exit if system is not UEFI
  if ! run_in_target "[ -d /sys/firmware/efi ]"; then
    log_warn "Skipping MOK bypass: Non-UEFI system"
    return 0
  fi

  log_info "Configuring Secure Boot validation bypass"

  # Mount efivarfs if not already mounted
  if ! run_in_target "grep -q ' ${efivars} ' /proc/mounts"; then
    run_in_target "mount -t efivarfs efivarfs '${efivars}'" || {
      log_warn "Failed to mount efivarfs"
      return 1
    }
    umount_needed=true
  fi

  # Write EFI variable with correct attributes (NV+BS+RT)
  local success=false
  if run_in_target "command -v efivar >/dev/null"; then
    if run_in_target "printf '\x01' | efivar -n '${mok_var}' -w -t 7 -f - >/dev/null 2>&1"; then
      success=true
    else
      log_warn "Failed to set MokSBStateRT variable"
    fi
  else
    log_warn "efivar tool not found in target system"
  fi

  # Verify the variable's data (skip 4-byte attributes)
  if [[ "$success" == true ]]; then
    if run_in_target "[ -f '${efivars}/${mok_var}' ] && \
       [ \"\$(od -An -t u1 -j4 -N1 '${efivars}/${mok_var}' | tr -d ' \n')\" = '1' ]"; then
      log_info "Secure Boot bypass confirmed"
    else
      log_warn "Bypass verification failed"
      success=false
    fi
  fi

  # Unmount efivarfs if mounted by this function
  if [[ "$umount_needed" == true ]]; then
    run_in_target "umount '${efivars}'" || log_warn "Failed to unmount efivarfs"
  fi

  [[ "$success" == true ]] || return 1
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
  move_keyfile_to_systemd
  generate_crypttab_target        
  crypt_dracut_conf             
  setup_dracut_conf_target
  generate_fstab_target  

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
  bypass_mok_prompt_target
  log_info "Configuration completed successfully!"
}

main

