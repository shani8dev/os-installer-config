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
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
CMDLINE_FILE_CURRENT="/etc/kernel/install_cmdline_blue"
CMDLINE_FILE_CANDIDATE="/etc/kernel/install_cmdline_green"
UKI_BOOT_ENTRY="/boot/efi/loader/entries"

# Read installer configuration for skip flags
CONFIG_FILE="/etc/os-installer/config.yaml"
if [[ -f "${CONFIG_FILE}" ]]; then
  # Assumes a simple YAML with lines like "skip_user: yes"
  SKIP_USER=$(grep -E '^skip_user:' "${CONFIG_FILE}" | awk '{print $2}')
  SKIP_REGION=$(grep -E '^skip_region:' "${CONFIG_FILE}" | awk '{print $2}')

  if [[ "${SKIP_USER}" == "yes" ]]; then
    export OSI_USER_NAME=""
    export OSI_USER_PASSWORD=""
    export OSI_USER_AUTOLOGIN=""
  fi

  if [[ "${SKIP_REGION}" == "yes" ]]; then
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
if [[ "${OSI_USE_ENCRYPTION:-}" == "1" && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
  echo "[CONFIG][WARN] OSI_USE_ENCRYPTION is enabled, but OSI_ENCRYPTION_PIN is not provided. Proceeding without it." >&2
fi

# Logging functions (consistent with install.sh)
log_info() { echo "[CONFIG][INFO] $*"; }
log_warn() { echo "[CONFIG][WARN] $*" >&2; }
log_error() { echo "[CONFIG][ERROR] $*" >&2; }
die() { log_error "$*"; exit 1; }


TARGET="/mnt"
ACTIVE_SLOT="blue"  # Default; mount_target() confirms this — declared global for set -u

# Function: mount_target
# Mount the active system subvolume and necessary pseudo-filesystems.
mount_target() {
  # configure.sh is the installer — blue is always the initial active slot.
  # Never read a stale current-slot from a previous install on @data; always
  # start fresh with blue. shani-deploy owns slot switching after first boot.
  ACTIVE_SLOT="blue"

  log_info "Mounting active system subvolume (@${ACTIVE_SLOT}) at ${TARGET}"
  sudo mount -o "subvol=@${ACTIVE_SLOT}" /dev/disk/by-label/"${ROOTLABEL}" "${TARGET}" || die "Active slot mount failed"

  for fs in proc sys dev run; do
    sudo mount --rbind "/$fs" "${TARGET}/$fs" || die "Failed to mount /$fs"
  done
  if [[ -d "/sys/firmware/efi/efivars" ]]; then
    sudo mount --rbind "/sys/firmware/efi/efivars" "${TARGET}/sys/firmware/efi/efivars" \
      || log_warn "Failed to bind-mount efivars — Secure Boot features will be unavailable"
  fi
  sudo mount /dev/disk/by-label/"${BOOTLABEL}" "${TARGET}/boot/efi" || die "EFI partition mount failed"
}

# Function: mount_additional_subvols
# Mount the remaining Btrfs subvolumes to their designated mount points.
mount_additional_subvols() {
  local device="/dev/disk/by-label/${ROOTLABEL}"

  # Define the subvolumes with target paths and additional mount options.
  declare -A subvols=(
    ["@root"]="/root|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@home"]="/home|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@data"]="/data|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@nix"]="/nix|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@cache"]="/var/cache|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@log"]="/var/log|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@flatpak"]="/var/lib/flatpak|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@snapd"]="/var/lib/snapd|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@waydroid"]="/var/lib/waydroid|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@containers"]="/var/lib/containers|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@machines"]="/var/lib/machines|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@lxc"]="/var/lib/lxc|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@lxd"]="/var/lib/lxd|rw,noatime,compress=zstd,autodefrag,space_cache=v2"
    ["@qemu"]="/var/lib/qemu|rw,noatime,nodatacow,nospace_cache"
    ["@libvirt"]="/var/lib/libvirt|rw,noatime,nodatacow,nospace_cache"
    ["@swap"]="/swap|rw,noatime,nodatacow,nospace_cache"
  )

  local target=""
  local options=""
  # Loop through each subvolume in the associative array.
  for subvol in "${!subvols[@]}"; do
    # Split the array value into target path and mount options using the '|' delimiter.
    IFS='|' read -r target options <<< "${subvols[$subvol]}"
    log_info "Mounting subvolume ${subvol} to ${TARGET}${target} with options: ${options}"
    sudo mkdir -p "${TARGET}${target}" 2>/dev/null || true
    sudo mount -t btrfs -o "subvol=${subvol},${options}" "$device" "${TARGET}${target}" \
      || log_warn "Failed to mount subvolume ${subvol} to ${TARGET}${target}"
  done
}

# Function: mount_overlay
# Configure an overlay mount for /etc and /var, then setup bind mounts for persistent service state.
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
  # /var on the read-only root is not writable. An overlay is required here so
  # that chroot commands during install (localectl, timedatectl, dracut, etc.)
  # can write to /var. This is an install-time chroot mount only — at runtime
  # systemd.volatile=state in the kernel cmdline provides a tmpfs for /var
  # instead, so this overlay is never active on the booted system.
  sudo mkdir -p "${TARGET}/data/overlay/var/upper" \
               "${TARGET}/data/overlay/var/lower" \
               "${TARGET}/data/overlay/var/work"
  sudo chmod 0755 "${TARGET}/data/overlay/var/upper" \
                  "${TARGET}/data/overlay/var/lower" \
                  "${TARGET}/data/overlay/var/work"

  log_info "Mounting overlay on /var (install-time chroot only)"
  sudo mount -t overlay overlay -o "lowerdir=${TARGET}/var,upperdir=${TARGET}/data/overlay/var/upper,workdir=${TARGET}/data/overlay/var/work,index=off,metacopy=off" "${TARGET}/var" || die "Overlay mount failed for /var"
  #############################
  # Setup bind mounts for persistent service state
  #############################
  log_info "Setting up bind mounts for persistent service state"

  # /var/lib service directories should already exist from install.sh
  local varlib_dirs=(
    # Core System Services (Required)
    "dbus"
    "systemd"
    "fontconfig"
    # Network & Connectivity
    "NetworkManager"
    "bluetooth"
    "firewalld"
    # File Sharing & Network Services
    "samba"
    "nfs"
    # Remote Access & VPN Services
    "caddy"
    "tailscale"
    "cloudflared"
    "geoclue"
    # Display Managers
    "gdm"
    "sddm"
    # Audio & Peripherals
    "colord"
    "pipewire"
    "rtkit"
    "cups"
    "sane"
    "upower"
    # User Authentication & Security
    "fprint"
    "AccountsService"
    "boltd"
    "sudo"
    "sshd"
    "polkit-1"
    # Hardware & Firmware
    "fwupd"
    "tpm2-tss"
    # Data Protection & Persistence
    "fail2ban"
    "restic"
    "rclone"
    "appimage"
  )

  local source=""
  local target=""

  for service in "${varlib_dirs[@]}"; do
    source="${TARGET}/data/varlib/${service}"
    target="${TARGET}/var/lib/${service}"

    # Only proceed if source exists (created by install.sh)
    if [[ ! -d "${source}" ]]; then
      log_info "Skipping /var/lib/${service}: source directory not found (created by install.sh but may be optional)"
      continue
    fi

    # Check if target exists in the root filesystem
    # Some services may not be installed (e.g., sddm in GNOME, gdm in KDE)
    if [[ ! -d "${target}" ]]; then
      log_info "Skipping /var/lib/${service}: not present in root filesystem (service not installed)"
      continue
    fi

    # Both source and target exist, create bind mount
    log_info "Bind mounting /var/lib/${service}"
    sudo mount --bind "${source}" "${target}" || log_warn "Failed to bind mount /var/lib/${service}"
  done

  # /var/spool service directories should already exist from install.sh
  local varspool_dirs=(
    # Job Scheduling Spool
    "anacron"
    "cron"
    "at"
    # Print & Mail Spools
    "cups"
    "samba"
    "postfix"
  )

  for service in "${varspool_dirs[@]}"; do
    source="${TARGET}/data/varspool/${service}"
    target="${TARGET}/var/spool/${service}"

    # Only proceed if source exists (created by install.sh)
    if [[ ! -d "${source}" ]]; then
      log_info "Skipping /var/spool/${service}: source directory not found (created by install.sh but may be optional)"
      continue
    fi

    # Check if target exists in the root filesystem
    if [[ ! -d "${target}" ]]; then
      log_info "Skipping /var/spool/${service}: not present in root filesystem (service not installed)"
      continue
    fi

    # Both source and target exist, create bind mount
    log_info "Bind mounting /var/spool/${service}"
    sudo mount --bind "${source}" "${target}" || log_warn "Failed to bind mount /var/spool/${service}"
  done
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

# Function: setup_keyboard_target
setup_keyboard_target() {
  if [ -n "${OSI_KEYBOARD_LAYOUT:-}" ] && [ "${OSI_KEYBOARD_LAYOUT,,}" != "none" ]; then
    log_info "Configuring keyboard layout: ${OSI_KEYBOARD_LAYOUT}"
    run_in_target "echo \"KEYMAP=${OSI_KEYBOARD_LAYOUT}\" > /etc/vconsole.conf && localectl set-keymap '${OSI_KEYBOARD_LAYOUT}' && localectl set-x11-keymap '${OSI_KEYBOARD_LAYOUT}'"
  else
    log_info "Keyboard layout variable not provided or set to 'none', skipping keyboard configuration."
  fi
}

# Function: setup_locale_target
setup_locale_target() {
  if [ -n "${OSI_LOCALE:-}" ] && [ "${OSI_LOCALE,,}" != "none" ]; then
    log_info "Configuring locale to ${OSI_LOCALE}"
    run_in_target "echo \"LANG=${OSI_LOCALE}\" > /etc/locale.conf && localectl set-locale LANG='${OSI_LOCALE}'"
  else
    log_info "Locale variable not provided or set to 'none', skipping locale configuration."
  fi
}



# Function: setup_formats_target
setup_formats_target() {
  if [ -n "${OSI_FORMATS:-}" ] && [ "${OSI_FORMATS,,}" != "none" ]; then
    log_info "Configuring formats: ${OSI_FORMATS}"
    run_in_target "localectl set-locale ${OSI_FORMATS}"
  else
    log_info "Formats variable not provided or set to 'none', skipping formats configuration."
  fi
}

# Function: setup_timezone_target
setup_timezone_target() {
  if [ -n "${OSI_TIMEZONE:-}" ] && [ "${OSI_TIMEZONE,,}" != "none" ]; then
    log_info "Setting timezone to ${OSI_TIMEZONE}"
    run_in_target "ln -sf \"/usr/share/zoneinfo/${OSI_TIMEZONE}\" /etc/localtime && echo '${OSI_TIMEZONE}' > /etc/timezone && timedatectl set-timezone '${OSI_TIMEZONE}'"
  else
    log_info "Timezone variable not provided or set to 'none', skipping timezone configuration."
  fi
}

# Function: setup_user_target
setup_user_target() {
  if [ -n "${OSI_USER_NAME:-}" ]; then
    log_info "Creating primary user: ${OSI_USER_NAME}"

    # Read the canonical group list from the image — single source of truth
    # shared with shani-user-setup and the useradd/adduser wrappers.
    local extra_groups
    extra_groups=$(run_in_target "cat /etc/shani-extra-groups 2>/dev/null | tr -d '[:space:]'")
    if [[ -z "$extra_groups" ]]; then
      log_warn "setup_user_target: /etc/shani-extra-groups is missing or empty — adding wheel only"
    fi

    # wheel is installer-specific (sudo access); it is intentionally absent from
    # shani-extra-groups because shani-user-setup must not grant sudo to users
    # added post-install. Add it here only, for the primary installer-created user.
    local groups_str="wheel${extra_groups:+,${extra_groups}}"

    # Ensure every group exists before useradd — some may be absent on minimal profiles.
    IFS=',' read -ra groups_arr <<< "$groups_str"
    for group in "${groups_arr[@]}"; do
      if ! run_in_target "getent group ${group} >/dev/null 2>&1"; then
        run_in_target "groupadd ${group}" || log_warn "Failed to create group ${group}"
      fi
    done

    # Call useradd via the ShaniOS wrapper so group-merging logic is consistent.
    run_in_target "PATH=/usr/local/bin:\$PATH useradd -m -s /bin/zsh -G '${groups_str}' '${OSI_USER_NAME}'" \
      || die "User creation failed"

    if [ -n "${OSI_USER_PASSWORD:-}" ]; then
      printf "%s:%s" "${OSI_USER_NAME}" "${OSI_USER_PASSWORD}" | run_in_target "chpasswd" \
        || die "Failed to set user password"
    else
      log_warn "No user password provided, user account created without a password."
    fi
  else
    log_info "User name variable not provided, skipping user configuration."
  fi
}

# Function: setup_autologin_target
setup_autologin_target() {
  if [ -n "${OSI_USER_AUTOLOGIN:-}" ] && [ -n "${OSI_USER_NAME:-}" ] && [ "${OSI_USER_AUTOLOGIN}" == "1" ]; then
    if run_in_target "command -v gdm >/dev/null"; then
      log_info "Configuring GDM autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/gdm && printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=${OSI_USER_NAME}\n' > /etc/gdm/custom.conf"
    elif run_in_target "command -v sddm >/dev/null"; then
      log_info "Configuring SDDM autologin for ${OSI_USER_NAME}"
      run_in_target "mkdir -p /etc/sddm.conf.d && printf '[Autologin]\nUser=${OSI_USER_NAME}\nSession=plasma\n' > /etc/sddm.conf.d/autologin.conf"
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
  if [ -n "${OSI_ROOT_PASSWORD:-}" ]; then
    log_info "Setting root password"
    printf "root:%s" "${OSI_ROOT_PASSWORD}" | run_in_target "chpasswd"
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

# Function: setup_firewall_kdeconnect
setup_firewall_kdeconnect() {
  log_info "Configuring offline firewall for KDE Connect (compatible with GSConnect)"
  run_in_target "firewall-offline-cmd --zone=public --add-service=kdeconnect"
  log_info "Offline firewall rules added. They will apply when firewalld is started."
}

# Function: setup_firewall_waydroid
setup_firewall_waydroid() {
  log_info "Configuring offline firewall rules for Waydroid networking"

  # DNS ports required by Waydroid's internal network
  run_in_target "firewall-offline-cmd --zone=trusted --add-port=53/udp"
  run_in_target "firewall-offline-cmd --zone=trusted --add-port=67/udp"

  # Allow packet forwarding in the trusted zone
  run_in_target "firewall-offline-cmd --zone=trusted --add-forward"

  # Add Waydroid virtual interface to the trusted zone
  run_in_target "firewall-offline-cmd --zone=trusted --add-interface=waydroid0"

  log_info 'Offline Waydroid firewall rules added (DNS, forwarding, interface "waydroid0").'
}

# Function: generate_mok_keys_target
generate_mok_keys_target() {
  log_info "Verifying MOK keys"
  # Keys are normally baked into the image by build-base-image.sh.
  # If they are missing (custom build, keys wiped, etc.) generate a fresh set.
  # NOTE: if the image's EFI binaries were already signed with build-time keys,
  # generating new keys here will produce a mismatch — sbverify will fail in
  # sign_efi_binary. In that case the image must be rebuilt with the new keys.
  if run_in_target "test -f /etc/secureboot/keys/MOK.key && \
                    test -f /etc/secureboot/keys/MOK.crt && \
                    test -f /etc/secureboot/keys/MOK.der" 2>/dev/null; then
    log_info "Build-time MOK keys present — skipping generation"
    return 0
  fi

  log_warn "MOK keys not found — generating new keys (image EFI binaries will be re-signed)"
  run_in_target "
    mkdir -p /etc/secureboot/keys
    openssl req -newkey rsa:2048 -nodes \
      -keyout /etc/secureboot/keys/MOK.key \
      -new -x509 -sha256 -days 3650 \
      -out /etc/secureboot/keys/MOK.crt \
      -subj '/CN=Shani OS Secure Boot Key/' || exit 1
    openssl x509 \
      -in  /etc/secureboot/keys/MOK.crt \
      -outform DER \
      -out /etc/secureboot/keys/MOK.der  || exit 1
    chmod 0600 /etc/secureboot/keys/MOK.key
  " || die "MOK key generation failed"
  log_info "MOK keys generated"
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
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
    log_info "Relocating keyfile to systemd directory"
    local src_keyfile="/boot/efi/crypto_keyfile.bin"
    local dest_dir="/etc/cryptsetup-keys.d"

    if run_in_target "[ -f ${src_keyfile} ]"; then
      # Move keyfile to systemd's cryptsetup directory
      run_in_target "mkdir -p ${dest_dir} && \
        cp ${src_keyfile} ${dest_dir}/${ROOTLABEL}.bin && \
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
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
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
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
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
# Args: $1 = slot (blue|green), $2 = active_slot (blue|green)
# active_slot is passed in from main() — do not re-read from the chroot here
# because the slot file may not be written yet when this function is called.
generate_uki_entry() {
  local slot="$1"
  local active_slot="$2"

  # Retrieve the filesystem UUID from the partition labeled with ROOTLABEL.
  local fs_uuid
  fs_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}" | tr -d '\n')

  local luks_uuid=""
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
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
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
    rootdev="/dev/mapper/${ROOTLABEL}"
  else
    rootdev="UUID=${fs_uuid}"
  fi

  # Build encryption parameters if needed.
  local encryption_params=""
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
    encryption_params=" rd.luks.uuid=${luks_uuid} rd.luks.name=${luks_uuid}=${ROOTLABEL} rd.luks.options=${luks_uuid}=tpm2-device=auto"
  fi

  local cmdline="quiet splash systemd.volatile=state ro lsm=landlock,lockdown,yama,integrity,apparmor,bpf rootfstype=btrfs rootflags=subvol=@${slot},ro,noatime,compress=zstd,space_cache=v2,autodefrag${encryption_params} root=${rootdev}"

  # Append keyboard mapping parameter if OSI_KEYBOARD_LAYOUT is provided.
  if [[ -n "${OSI_KEYBOARD_LAYOUT:-}" ]]; then
    cmdline="${cmdline} rd.vconsole.keymap=${OSI_KEYBOARD_LAYOUT}"
  fi

  # For resume settings, choose the appropriate UUID.
  local resume_uuid
  if [[ "${OSI_USE_ENCRYPTION:-}" == "1" ]]; then
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
  local cmdfile
  if [[ "$slot" == "$active_slot" ]]; then
    cmdfile="${CMDLINE_FILE_CURRENT}"
  else
    cmdfile="${CMDLINE_FILE_CANDIDATE}"
  fi

  run_in_target "echo '${cmdline}' > ${cmdfile}"

  # active_slot   = blue, boots first, Active label, +3-0 tries
  # candidate_slot = green, mirror, Candidate label, plain .conf
  local suffix=""
  if [[ "$slot" == "$active_slot" ]]; then
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

  # Write the boot entry — active slot gets +3-0 tries suffix so systemd-boot
  # automatically falls back if the new installation fails to boot.
  # Candidate slot gets a plain entry (no tries) as the stable fallback.
  # This matches exactly what shani-deploy's finalize_boot_entries produces
  # so there are no orphaned plain .conf files after the first deploy.
  # Clean up any stale entries for this slot before writing — matches
  # the cleanup shani-deploy's finalize_boot_entries performs.
  run_in_target "rm -f ${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}+*.conf ${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}.conf" 2>/dev/null || true

  # active_slot gets +3-0 tries — systemd-boot falls back automatically
  # if installation fails to reach multi-user.target on first boot.
  # candidate_slot gets plain .conf — stable fallback, no tries needed.
  local entry_filename
  if [[ "$slot" == "$active_slot" ]]; then
    entry_filename="${OS_NAME}-${slot}+3-0.conf"
  else
    entry_filename="${OS_NAME}-${slot}.conf"
  fi
  run_in_target "mkdir -p ${UKI_BOOT_ENTRY} && printf 'title   ${OS_NAME}-${slot}${suffix}\nefi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi\n' > ${UKI_BOOT_ENTRY}/${entry_filename}"
}

# Function: generate_loader_conf
generate_loader_conf() {
  local slot="$1"
  # Use a glob pattern for the default entry so systemd-boot matches the active
  # slot regardless of the current tries counter value (+3-0, +2-1, +1-2, +0-3).
  # A hardcoded +3-0 suffix would stop matching after the first successful boot
  # decrements the counter, causing systemd-boot to fall back to its own heuristics.
  # bootctl set-default is intentionally omitted — it requires efivarfs which
  # is unreliable inside a chroot, and loader.conf already sets the default.
  run_in_target "mkdir -p /boot/efi/loader && printf 'default ${OS_NAME}-${slot}+*.conf\ntimeout 5\nconsole-mode max\neditor 0\nauto-entries 0\nbeep 0\n' > /boot/efi/loader/loader.conf"
}

# Helper: _mokutil_stage_via_hash
# Stage MOK enrollment via mokutil --import --hash-file.
# Generates a hash of 'shanios' inside the chroot and passes it to mokutil.
# MokManager will prompt the user to confirm with password 'shanios' on first boot.
_mokutil_stage_via_hash() {
    local der_file="$1"
    local tmp_hash="/tmp/.mok-enroll-hash"
    log_info "Staging MOK enrollment via generated password hash (password: shanios)"
    if run_in_target "
        set -e
        mokutil --generate-hash=shanios > '${tmp_hash}' 2>/dev/null
        mokutil --import '${der_file}' --hash-file '${tmp_hash}' >/dev/null 2>&1
        rm -f '${tmp_hash}'
    "; then
        log_info "MOK enrollment staged — confirm with password 'shanios' in MokManager on first boot"
    else
        run_in_target "rm -f '${tmp_hash}'" 2>/dev/null || true
        log_warn "mokutil hash-file staging failed — MOK.der is present in EFI partition for manual enrollment on first boot"
    fi
}

setup_secureboot() {
    local mok_der="/etc/secureboot/keys/MOK.der"
    local efivars="/sys/firmware/efi/efivars"

    # Check for UEFI system
    if [[ ! -d "/sys/firmware/efi" ]]; then
        log_warn "Secure Boot setup skipped: not a UEFI system"
        return 0
    fi

    # efivarfs is rbind-mounted from the host into the chroot by mount_target(),
    # so mokutil calls here talk to the live EFI variable store.
    if ! run_in_target "mountpoint -q '${efivars}'" >/dev/null 2>&1; then
        log_warn "efivarfs not accessible in chroot — Secure Boot setup skipped"
        return 0
    fi

    local sb_state=""
    sb_state=$(run_in_target "mokutil --sb-state" 2>&1) || true
    log_info "Secure Boot state: ${sb_state}"

    # Always stage MOK enrollment regardless of whether Secure Boot is currently
    # enabled. If the user installs with SB off and enables it later, the key must
    # already be enrolled — otherwise the system will not boot.
    if [[ -f "${TARGET}${mok_der}" ]]; then
        _mokutil_stage_via_hash "${mok_der}"
        log_info "MOK enrollment staged — user will confirm in MokManager on first boot"
    else
        log_warn "MOK.der not found at ${TARGET}${mok_der} — skipping MOK enrollment"
    fi

    return 0
}


# Main configuration function
main() {
  mount_target
  mount_additional_subvols
  mount_overlay

  setup_hostname_target
  setup_machine_id_target
  setup_keyboard_target

  # If SKIP_REGION is set to "yes", skip locale, formats, and timezone configuration.
  if [[ "${SKIP_REGION:-}" == "yes" ]]; then
    log_info "Skipping locale, keyboard, and timezone configuration as per config."
  else
    setup_locale_target
    setup_formats_target
    setup_timezone_target
  fi

  # If SKIP_USER is set to "yes", skip user configuration.
  if [[ "${SKIP_USER:-}" == "yes" ]]; then
    log_info "Skipping user configuration as per config."
  else
    setup_user_target
    setup_autologin_target
  fi

  set_root_password
  setup_plymouth_theme_target
  setup_firewall_kdeconnect
  setup_firewall_waydroid
  generate_mok_keys_target
  install_secureboot_components_target
  move_keyfile_to_systemd
  generate_crypttab_target
  crypt_dracut_conf

  # active_slot is already known from mount_target() via $ACTIVE_SLOT — use it
  # directly rather than re-reading from the chroot, which may not have the
  # slot file written yet at this point.
  local active_slot="${ACTIVE_SLOT}"
  local candidate_slot
  if [ "${active_slot}" == "blue" ]; then
      candidate_slot="green"
  else
      candidate_slot="blue"
  fi

  # Write slot markers BEFORE generating UKIs — generate_uki_entry needs
  # active_slot to select the correct cmdline file and boot entry filename.
  run_in_target "echo '${active_slot}' > /data/current-slot"
  run_in_target "echo '${candidate_slot}' > /data/previous-slot"
  # Signal shani-user-setup.service to run on first boot — same marker that
  # shani-deploy writes on every slot switch. Install is the first slot activation.
  run_in_target "touch /data/user-setup-needed"
  log_info "Slot markers written: current=${active_slot}, previous=${candidate_slot}"

  # Pass active_slot explicitly — generate_uki_entry must not re-read it from
  # the chroot since that code path has now been removed.
  generate_uki_entry "${active_slot}" "${active_slot}"
  generate_uki_entry "${candidate_slot}" "${active_slot}"
  generate_loader_conf "${active_slot}"

  setup_secureboot
  log_info "Configuration completed successfully!"
}

main
