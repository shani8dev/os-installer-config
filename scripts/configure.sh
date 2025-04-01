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

# Read installer configuration for skip flags
CONFIG_FILE="/etc/os-installer/config.yaml"
if [[ -f "${CONFIG_FILE}" ]]; then
  # Assumes a simple YAML with lines like "skip_user: yes"
  SKIP_USER=$(grep -E '^skip_user:' "${CONFIG_FILE}" | awk '{print $2}')
  SKIP_LOCALE=$(grep -E '^skip_locale:' "${CONFIG_FILE}" | awk '{print $2}')

  if [[ "${SKIP_USER}" == "yes" ]]; then
    export OSI_USER_NAME=""
    export OSI_USER_PASSWORD=""
    export OSI_USER_AUTOLOGIN=""
  fi

  if [[ "${SKIP_LOCALE}" == "yes" ]]; then
    export OSI_LOCALE=""
    export OSI_FORMATS=""
    export OSI_TIMEZONE=""
  fi
fi


# Environment variables (allowed to be not set)
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
    echo "[CONFIG][WARN] Environment variable '$var' is not set" >&2
  fi
done

# Warn if encryption is enabled but no encryption PIN is provided.
if [[ "${OSI_USE_ENCRYPTION:-0}" -eq 1 && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
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
  
  for fs in proc sys dev run sys/firmware/efi/efivars; do
    sudo mount --rbind "/$fs" "${TARGET}/$fs" || die "Failed to mount /$fs"
  done
  sudo mount /dev/disk/by-label/"${BOOTLABEL}" "${TARGET}/boot/efi" || die "EFI partition mount failed"
}

# Function: mount_additional_subvols
# Mount the remaining Btrfs subvolumes to their designated mount points.
mount_additional_subvols() {
  local device="/dev/disk/by-label/${ROOTLABEL}"
  
  # Define the subvolumes with target paths and additional mount options.
  declare -A subvols=(
    ["@home"]="/home|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@data"]="/data|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@cache"]="/var/cache|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
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
  log_info "Configuring overlay for /etc and /var"

  #############################
  # Configure overlay for /etc
  #############################
  # Create necessary overlay directories for /etc in the data subvolume

  sudo mkdir -p "${TARGET}/data/overlay/etc/lower" \
               "${TARGET}/data/overlay/etc/upper" \
               "${TARGET}/data/overlay/etc/work"

  sudo chmod 0755 "${TARGET}/data/overlay/etc/lower" \
              "${TARGET}/data/overlay/etc/upper" \
              "${TARGET}/data/overlay/etc/work"

  # Mount the overlay using the correct lower, upper, and work directories
  log_info "Mounting overlay on /etc"
  sudo mount -t overlay overlay -o "lowerdir=${TARGET}/etc,upperdir=${TARGET}/data/overlay/etc/upper,workdir=${TARGET}/data/overlay/etc/work,index=off,metacopy=off" "${TARGET}/etc" || die "Overlay mount failed"

  #############################
  # Configure overlay for /var
  #############################
  # Create directories for the /var overlay in the data subvolume
  sudo mkdir -p "${TARGET}/data/overlay/var/lower" \
               "${TARGET}/data/overlay/var/upper" \
               "${TARGET}/data/overlay/var/work"
  sudo chmod 0755 "${TARGET}/data/overlay/var/lower" \
                  "${TARGET}/data/overlay/var/upper" \
                  "${TARGET}/data/overlay/var/work"

  # Mount the overlay using the correct lower, upper, and work directories
  log_info "Mounting overlay on /var"
  sudo mount -t overlay overlay -o "lowerdir=${TARGET}/var,upperdir=${TARGET}/data/overlay/var/upper,workdir=${TARGET}/data/overlay/var/work,index=off,metacopy=off" "${TARGET}/var" || die "Overlay mount failed for /var"

}

# Function: run_in_target
# Execute a command in the mounted target environment.
run_in_target() {
  sudo chroot "${TARGET}" /bin/bash -c "$1"
}

# Function: setup_machine_id_target
setup_machine_id_target() {
  # No variable is required for machine-id setup; always execute.
  log_info "Generating new machine-id"
  run_in_target "systemd-machine-id-setup --commit"
}

# Function: setup_hostname_target
setup_hostname_target() {
  if [ -n "${OS_NAME:-}" ]; then
    log_info "Setting hostname to ${OS_NAME}"
    run_in_target "echo \"${OS_NAME}\" > /etc/hostname && hostnamectl set-hostname '${OS_NAME}'"
  else
    log_info "Hostname variable not provided, skipping hostname configuration."
  fi
}

# Function: setup_locale_target
setup_locale_target() {
  if [ -n "${OSI_LOCALE:-}" ]; then
    log_info "Configuring locale to ${OSI_LOCALE}"
    run_in_target "echo \"LANG=${OSI_LOCALE}\" > /etc/locale.conf && localectl set-locale LANG='${OSI_LOCALE}'"
  else
    log_info "Locale variable not provided, skipping locale configuration."
  fi
}

# Function: setup_keyboard_target
setup_keyboard_target() {
  if [ -n "${OSI_KEYBOARD_LAYOUT:-}" ]; then
    log_info "Configuring keyboard layout: ${OSI_KEYBOARD_LAYOUT}"
    run_in_target "echo \"KEYMAP=${OSI_KEYBOARD_LAYOUT}\" > /etc/vconsole.conf && localectl set-keymap '${OSI_KEYBOARD_LAYOUT}' && localectl set-x11-keymap '${OSI_KEYBOARD_LAYOUT}'"
  else
    log_info "Keyboard layout variable not provided, skipping keyboard configuration."
  fi
}

# Function: setup_formats_target
setup_formats_target() {
  if [ -n "${OSI_FORMATS:-}" ]; then
    log_info "Configuring formats: ${OSI_FORMATS}"
    # OSI_FORMATS should contain one or more key=value pairs separated by spaces.
    run_in_target "localectl set-locale ${OSI_FORMATS}"
  else
    log_info "Formats variable not provided, skipping formats configuration."
  fi
}

# Function: setup_timezone_target
setup_timezone_target() {
  if [ -n "${OSI_TIMEZONE:-}" ]; then
    log_info "Setting timezone to ${OSI_TIMEZONE}"
    run_in_target "ln -sf \"/usr/share/zoneinfo/${OSI_TIMEZONE}\" /etc/localtime && echo '${OSI_TIMEZONE}' > /etc/timezone && timedatectl set-timezone '${OSI_TIMEZONE}'"
  else
    log_info "Timezone variable not provided, skipping timezone configuration."
  fi
}

# Function: setup_user_target
setup_user_target() {
  if [ -n "${OSI_USER_NAME:-}" ]; then
    log_info "Creating primary user: ${OSI_USER_NAME}"
    local groups=("wheel" "input" "realtime" "video" "sys" "cups" "lp" "libvirt" "kvm" "scanner")
    for group in "${groups[@]}"; do
      if ! run_in_target "getent group ${group}" >/dev/null; then
        run_in_target "groupadd ${group}" || log_warn "Failed to create group ${group}"
      fi
    done
    run_in_target "useradd -m -s /bin/zsh -G '$(IFS=,; echo "${groups[*]}")' '${OSI_USER_NAME}'" || die "User creation failed"
    if [ -n "${OSI_USER_PASSWORD:-}" ]; then
      printf "%s:%s" "${OSI_USER_NAME}" "${OSI_USER_PASSWORD}" | run_in_target "chpasswd" || die "Failed to set user password"
    else
      log_warn "No user password provided, user account created without a password."
    fi
  else
    log_info "User name variable not provided, skipping user configuration."
  fi
}

# Function: setup_autologin_target
setup_autologin_target() {
  if [ -n "${OSI_USER_AUTOLOGIN:-}" ] && [ -n "${OSI_USER_NAME:-}" ] && [ "${OSI_USER_AUTOLOGIN}" -eq 1 ]; then
    if run_in_target "command -v gdm >/dev/null"; then
      log_info "Configuring GDM autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/gdm && printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=${OSI_USER_NAME}\n' > /etc/gdm/custom.conf"
    elif run_in_target "command -v sddm >/dev/null"; then
      log_info "Configuring SDDM autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/sddm.conf.d && printf '[Autologin]\nUser=${OSI_USER_NAME}\n' > /etc/sddm.conf.d/autologin.conf"
    elif run_in_target "command -v greetd >/dev/null"; then
      log_info "Configuring greetd autologin for ${OSI_USER_NAME}"
      run_in_target "if [ -f /etc/greetd/config.toml ]; then \
          sed -i 's/^user *= *.*/user = \"${OSI_USER_NAME}\"/' /etc/greetd/config.toml; \
        else \
          echo -e '[autologin]\nuser = \"${OSI_USER_NAME}\"' > /etc/greetd/config.toml; \
        fi"
    elif run_in_target "command -v lightdm >/dev/null"; then
      log_info "Configuring LightDM autologin for ${OSI_USER_NAME}"
      run_in_target "sed -i 's/^#*autologin-user=.*/autologin-user=${OSI_USER_NAME}/' /etc/lightdm/lightdm.conf"
    elif run_in_target "command -v lxdm >/dev/null"; then
      log_info "Configuring LXDM autologin for ${OSI_USER_NAME}"
      run_in_target "sed -i 's/^#*autologin=.*/autologin=${OSI_USER_NAME}/' /etc/lxdm/lxdm.conf"
    else
      log_info "Configuring getty autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/systemd/system/getty@tty1.service.d && printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin ${OSI_USER_NAME} --noclear %%I \$TERM\n' > /etc/systemd/system/getty@tty1.service.d/autologin.conf"
    fi
  else
    log_info "Autologin not enabled or required variables not provided, skipping autologin configuration."
  fi
}


# Function: set_root_password
set_root_password() {
  if [ -n "${OSI_USER_PASSWORD:-}" ]; then
    log_info "Setting root password"
    printf "root:%s" "${OSI_USER_PASSWORD}" | run_in_target "chpasswd"
  else
    log_info "No root password provided, skipping root password configuration."
    # Alternatively, you might choose to lock the root account if that is preferred:
    # run_in_target "passwd --lock root"
  fi
}

# Create Plymouth configuration to set the theme to shani-bgrt.
setup_plymouth_theme_target() {
  log_info "Configuring Plymouth theme to bgrt"
  run_in_target "mkdir -p /etc/plymouth && { echo '[Daemon]'; echo 'Theme=bgrt'; } > /etc/plymouth/plymouthd.conf"
}

# Function: generate_mok_keys_target
generate_mok_keys_target() {
  log_info "Generating MOK keys for secure boot"
  run_in_target "mkdir -p /etc/secureboot/keys && \
    if [ ! -f /etc/secureboot/keys/MOK.key ]; then
      openssl req -newkey rsa:2048 -nodes -keyout /etc/secureboot/keys/MOK.key \
        -new -x509 -sha256 -days 3650 -out /etc/secureboot/keys/MOK.crt \
        -subj '/CN=Shani OS Secure Boot Key/' && \
      openssl x509 -in /etc/secureboot/keys/MOK.crt -outform DER -out /etc/secureboot/keys/MOK.der && \
      chmod 0600 /etc/secureboot/keys/MOK.key
    fi"
}

# Function: install_secureboot_components_target
install_secureboot_components_target() {
  log_info "Installing secure boot components"
  run_in_target "mkdir -p /boot/efi/EFI/BOOT && \
    cp /usr/share/shim-signed/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI && \
    cp /usr/share/shim-signed/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi && \
    cp /etc/secureboot/keys/MOK.der /boot/efi/EFI/BOOT/MOK.der && \
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi"

  sign_efi_binary "/boot/efi/EFI/BOOT/grubx64.efi"
}

# Function: sign_efi_binary
sign_efi_binary() {
  local binary="$1"
  log_info "Signing EFI binary ${binary}"
  run_in_target "sbsign --key /etc/secureboot/keys/MOK.key --cert /etc/secureboot/keys/MOK.crt --output ${binary} ${binary} && sbverify --cert /etc/secureboot/keys/MOK.crt ${binary}"
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
    
    # Determine the underlying block device from the LUKS mapping.
    local underlying
    underlying=$(run_in_target "cryptsetup status /dev/mapper/${ROOTLABEL} | sed -n 's/^ *device: //p'" | tr -d '\n')
    if [[ -z "$underlying" ]]; then
      die "Failed to determine underlying device for /dev/mapper/${ROOTLABEL}"
    fi

    # Retrieve the LUKS header UUID from the underlying physical device.
    local luks_uuid
    luks_uuid=$(run_in_target "cryptsetup luksUUID ${underlying}" | tr -d '\n')
    if [[ -z "$luks_uuid" ]]; then
      die "Failed to retrieve LUKS UUID from ${underlying}"
    fi

    # Set keyfile option: use keyfile if it exists, otherwise "none".
    local keyfile_path="/etc/cryptsetup-keys.d/${ROOTLABEL}.bin"
    local keyfile_option
    if run_in_target "[ -f '${keyfile_path}' ]"; then
      keyfile_option="${keyfile_path}"
    else
      keyfile_option="none"
    fi

    local entry="${ROOTLABEL} UUID=${luks_uuid} ${keyfile_option} luks,discard"
    run_in_target "echo '${entry}' > /etc/crypttab"
    log_info "/etc/crypttab generated with entry: ${entry}"
  else
    log_info "Encryption not enabled; skipping /etc/crypttab generation"
  fi
}

# Function: crypt_dracut_conf
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
  fs_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}" | tr -d '\n')
  
  local luks_uuid=""
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    # Determine the underlying block device from the LUKS mapping using cryptsetup status.
    local underlying
    underlying=$(run_in_target "cryptsetup status /dev/mapper/${ROOTLABEL} | sed -n 's/^ *device: //p'" | tr -d '\n')
    if [[ -z "$underlying" ]]; then
      die "Failed to determine underlying device for /dev/mapper/${ROOTLABEL}"
    fi

    # Retrieve the LUKS header UUID from the underlying physical device.
    luks_uuid=$(run_in_target "cryptsetup luksUUID ${underlying}" | tr -d '\n')
    if [[ -z "$luks_uuid" ]]; then
      die "Failed to retrieve LUKS UUID from ${underlying}"
    fi
  fi

  # Determine the root device: if encryption is enabled, use the decrypted mapping;
  # otherwise, use the filesystem UUID.
  local rootdev
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    rootdev="/dev/mapper/${ROOTLABEL}"
  else
    rootdev="UUID=${fs_uuid}"
  fi

  # Build encryption parameters if needed.
  local encryption_params=""
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    encryption_params=" rd.luks.uuid=${luks_uuid} rd.luks.name=${luks_uuid}=${ROOTLABEL} rd.luks.options=${luks_uuid}=tpm2-device=auto"
  fi

  local cmdline="quiet splash systemd.volatile=state ro lsm=landlock,lockdown,yama,integrity,apparmor,bpf rootfstype=btrfs rootflags=subvol=@${slot},ro,noatime,compress=zstd,space_cache=v2,autodefrag${encryption_params} root=${rootdev}"

  # Append keyboard mapping parameter if OSI_KEYBOARD_LAYOUT is provided.
  if [[ -n "${OSI_KEYBOARD_LAYOUT:-}" ]]; then
    cmdline="${cmdline} rd.vconsole.keymap=${OSI_KEYBOARD_LAYOUT}"
  fi

  # For resume settings, choose the appropriate UUID.
  local resume_uuid
  if [[ "${OSI_USE_ENCRYPTION}" -eq 1 ]]; then
    resume_uuid="${luks_uuid}"
  else
    resume_uuid="${fs_uuid}"
  fi

  # If a swapfile exists, determine its offset and append resume parameters.
  if run_in_target "[ -f /swap/swapfile ]"; then
    local swap_offset
    swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print \$NF}'" | tr -d '\n')
    cmdline+=" resume=UUID=${resume_uuid} resume_offset=${swap_offset}"
  fi

  # Determine which cmdline file to update.
  local current_slot
  current_slot=$(run_in_target "cat ${CURRENT_SLOT_FILE}" | tr -d '\n')
  local cmdfile
  if [[ "$slot" == "$current_slot" ]]; then
    cmdfile="${CMDLINE_FILE_CURRENT}"
  else
    cmdfile="${CMDLINE_FILE_CANDIDATE}"
  fi

  run_in_target "echo '${cmdline}' > ${cmdfile}"
  
  # Determine Active or candidate suffix
  local suffix=""
  if [[ "$slot" == "$current_slot" ]]; then
      suffix=" (Active)"
  else
      suffix=" (Candidate)"
  fi

  # Generate the bootable EFI image.
  local kernel_version
  kernel_version=$(get_kernel_version)
  local uki_path="/boot/efi/EFI/${OS_NAME}/${OS_NAME}-${slot}.efi"
  run_in_target "mkdir -p /boot/efi/EFI/${OS_NAME}/"
  run_in_target "dracut --force --uefi --kver ${kernel_version} --kernel-cmdline \"${cmdline}\" ${uki_path}"
  sign_efi_binary "${uki_path}"

  # Create the UEFI boot entry configuration using printf instead of a heredoc.
  run_in_target "mkdir -p ${UKI_BOOT_ENTRY} && printf 'title   ${OS_NAME}-${slot}${suffix}\nefi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi\n' > ${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}.conf"
}

# Function: generate_loader_conf
generate_loader_conf() {
  local slot="$1"
  # Update the loader configuration using printf instead of a heredoc.
  run_in_target "mkdir -p /boot/efi/loader && printf 'default ${OS_NAME}-${slot}.conf\ntimeout 5\nconsole-mode max\neditor 0\n' > /boot/efi/loader/loader.conf"

  # Set the active boot entry as default using bootctl.
  run_in_target "bootctl set-default ${OS_NAME}-${current_slot}.conf" || log_warn "bootctl set-default failed"
}

setup_secureboot() {
    local exit_code=0
    local umount_needed=false
    local mok_key="/etc/secureboot/keys/MOK.der"
    local efivars="/sys/firmware/efi/efivars"
    local secureboot_var="SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    local mok_var="MokSBStateRT-605dab50-e046-4300-abb6-3dd810dd8b23"

    # Step 1: Verify UEFI environment
    if [ ! -d "/sys/firmware/efi" ]; then
        log_warn "Secure Boot setup: System is not UEFI"
        return 0
    fi

    # Step 2: Check Secure Boot status
    if ! command -v efivar >/dev/null; then
        log_warn "Secure Boot setup requires 'efivar' package"
        return 1
    fi

    local sb_state=$(efivar -n "$secureboot_var" -d 2>/dev/null | \
                    awk -F': ' '/Data:/ {print $2}' | tr -d ' ' | head -c2)
    if [ "$sb_state" != "01" ]; then
        log_info "Secure Boot not enabled (State: 0x${sb_state:-unknown})"
        return 0
    fi

    # Step 3: MOK Enrollment
    if [[ -n "${OSI_USER_PASSWORD:-}" && -f "$mok_key" ]]; then
        log_info "Attempting MOK key enrollment"
        if command -v mokutil >/dev/null; then
            if ! printf "%s\n%s\n" "$OSI_USER_PASSWORD" "$OSI_USER_PASSWORD" | \
                 mokutil --import "$mok_key" >/dev/null; then
                log_warn "MOK enrollment failed"
                exit_code=1
            else
                log_info "MOK enrollment completed"
            fi
        else
            log_warn "Skipping MOK enrollment: mokutil not found"
            exit_code=1
        fi
    fi

    # Step 4: Configure Secure Boot bypass
    if ! grep -q " $efivars " /proc/mounts; then
        log_info "Mounting efivarfs"
        if mount -t efivarfs efivarfs "$efivars"; then
            umount_needed=true
        else
            log_warn "Failed to mount efivarfs"
            return 1
        fi
    fi

    log_info "Setting Secure Boot bypass"
    if ! printf '\x01' | efivar -n "$mok_var" -w -t 7 -f - >/dev/null 2>&1; then
        log_warn "Failed to write EFI variable"
        exit_code=1
    fi

    # Step 5: Verification
    if ! dd if="$efivars/$mok_var" bs=1 skip=4 count=1 2>/dev/null | \
         grep -q $'\x01'; then
        log_warn "Bypass verification failed"
        exit_code=1
    else
        log_info "Secure Boot bypass confirmed"
    fi

    # Cleanup
    if $umount_needed; then
        umount "$efivars" || {
            log_warn "Failed to unmount efivarfs"
            exit_code=1
        }
    fi

    return $exit_code
}

# Main configuration function
main() {
  mount_target
  mount_additional_subvols
  mount_overlay
  
  setup_hostname_target
  setup_machine_id_target
  
  # If SKIP_LOCALE is set to "yes", skip locale, keyboard, and timezone configuration.
  if [[ "${SKIP_LOCALE:-}" == "yes" ]]; then
    log_info "Skipping locale, keyboard, and timezone configuration as per config."
  else
    setup_locale_target
    setup_keyboard_target
    setup_formats_target
    setup_timezone_target
  fi

  # If SKIP_USER is set to "yes", skip user configuration.
  if [[ "${SKIP_USER:-}" == "yes" ]]; then
    log_info "Skipping user configuration as per config."
  else
    setup_user_target
    set_root_password
    setup_autologin_target
  fi

  setup_plymouth_theme_target
  generate_mok_keys_target
  install_secureboot_components_target
  move_keyfile_to_systemd
  generate_crypttab_target        
  crypt_dracut_conf             

  local current_slot
  current_slot=$(run_in_target "cat ${CURRENT_SLOT_FILE}" | tr -d '\n')
  local candidate_slot
  if [ "${current_slot}" == "blue" ]; then
      candidate_slot="green"
  else
      candidate_slot="blue"
  fi

  generate_uki_entry "${current_slot}"
  generate_uki_entry "${candidate_slot}"
  generate_loader_conf "${current_slot}"
  setup_secureboot
  log_info "Configuration completed successfully!"
}

main

