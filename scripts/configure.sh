#!/bin/bash
# configure.sh – Post-installation configuration for Shani OS.
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

### Configuration
OS_NAME="shanios"
BASE_VERSION="$(date +%Y%m%d)"
OSIDIR="/etc/os-installer"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"
CMDLINE_FILE_CURRENT="/etc/kernel/install_cmdline_current"
CMDLINE_FILE_CANDIDATE="/etc/kernel/install_cmdline_candidate"
UKI_BOOT_ENTRY="/boot/loader/entries"
CURRENT_SLOT_FILE="/deployment/current-slot"

required_vars=(OSI_LOCALE OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_DEVICE_EFI_PARTITION OSI_USE_ENCRYPTION OSI_ENCRYPTION_PIN OSI_USER_NAME OSI_USER_AUTOLOGIN OSI_USER_PASSWORD OSI_FORMATS OSI_TIMEZONE OSI_ADDITIONAL_SOFTWARE OSI_ADDITIONAL_FEATURES OSI_DESKTOP OSI_HOSTNAME OSI_SSH_PORT)
for var in "${required_vars[@]}"; do
  [[ -z "${!var:-}" ]] && { echo "[ERROR] $var is not set"; exit 1; }
done

log() { echo "[CONFIG] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

TARGET="/mnt"

mount_target() {
  if [[ -f "$TARGET/$CURRENT_SLOT_FILE" ]]; then
    ACTIVE_SLOT=$(< "$TARGET/$CURRENT_SLOT_FILE")
  else
    ACTIVE_SLOT="blue"
    echo "$ACTIVE_SLOT" | sudo tee "$TARGET/$CURRENT_SLOT_FILE" >/dev/null
  fi
  log "Mounting active system (slot ${ACTIVE_SLOT}) from ${SYSTEM_SUBVOL}/${ACTIVE_SLOT} to ${TARGET}..."
  sudo mount -o subvol=deployment/system/${ACTIVE_SLOT} /dev/disk/by-label/"$ROOTLABEL" "$TARGET" || die "Failed to mount active system"
  for fs in proc sys dev run; do
    sudo mount --rbind "/$fs" "$TARGET/$fs" || die "Failed to mount /$fs"
  done
  sudo mount --mkdir /dev/disk/by-label/"$BOOTLABEL" "$TARGET/boot/efi" || die "Failed to mount EFI partition"
}

mount_overlay() {
  log "Mounting overlay for /etc"
  sudo mkdir -p "$TARGET/deployment/data/etc-writable" "$TARGET/deployment/data/overlay/upper" "$TARGET/deployment/data/overlay/work"
  sudo mount -t overlay overlay -o lowerdir="$TARGET/deployment/data/etc-writable",upperdir="$TARGET/deployment/data/overlay/upper",workdir="$TARGET/deployment/data/overlay/work" "$TARGET/etc" || die "Overlay mount failed"
}

run_in_target() {
  sudo arch-chroot "$TARGET" /bin/bash -c "$1"
}

setup_locale_target() {
  log "Configuring locale: ${OSI_LOCALE}"
  echo "${OSI_LOCALE} UTF-8" | sudo tee -a "$TARGET/etc/locale.gen" >/dev/null
  run_in_target "locale-gen" || die "Locale generation failed"
  [[ -n "${OSI_FORMATS}" ]] && run_in_target "localectl set-locale \"${OSI_FORMATS}\""
}

setup_timezone_target() {
  log "Setting timezone to ${OSI_TIMEZONE}"
  run_in_target "ln -sf /usr/share/zoneinfo/${OSI_TIMEZONE} /etc/localtime"
  run_in_target "timedatectl set-timezone \"${OSI_TIMEZONE}\""
}

setup_hostname_target() {
  log "Setting hostname to ${OSI_HOSTNAME}"
  echo "${OSI_HOSTNAME}" | sudo tee "$TARGET/etc/hostname" >/dev/null
  run_in_target "hostnamectl set-hostname \"${OSI_HOSTNAME}\""
}

setup_machine_id_target() {
  log "Generating machine-id"
  run_in_target "systemd-machine-id-setup --commit"
}

setup_user_target() {
  log "Creating user ${OSI_USER_NAME}"
  local groups=("wheel" "input" "realtime" "video" "sys" "cups" "lp" "libvirt" "kvm" "scanner")
  local groups_csv=$(IFS=,; echo "${groups[*]}")
  run_in_target "homectl create \"${OSI_USER_NAME}\" --password=\"${OSI_USER_PASSWORD}\" --shell=\"/bin/bash\" --storage=directory --member-of=\"${groups_csv}\""
}

set_root_password() {
  log "Setting root password"
  echo "root:${OSI_USER_PASSWORD}" | sudo chpasswd -R "$TARGET"
}

enable_systemd_homed_target() {
  run_in_target "systemctl enable systemd-homed.service"
}

setup_services_target() {
  log "Enabling essential services"
  local services="sshd NetworkManager systemd-timesyncd ufw plymouth"
  [[ "${OSI_DESKTOP}" == "gnome" ]] && services+=" gdm"
  for service in $services; do
    run_in_target "systemctl enable ${service}"
  done
}

configure_ssh_target() {
  log "Configuring SSH port ${OSI_SSH_PORT}"
  run_in_target "sed -i 's/^#Port 22/Port ${OSI_SSH_PORT}/' /etc/ssh/sshd_config"
}

setup_autologin_target() {
  [[ "${OSI_USER_AUTOLOGIN}" -eq 1 ]] && run_in_target "homectl update \"${OSI_USER_NAME}\" --auto-login"
}

install_software_target() {
  [[ -n "${OSI_ADDITIONAL_SOFTWARE}" ]] && run_in_target "pacman -Sy --noconfirm ${OSI_ADDITIONAL_SOFTWARE} shim-signed sbsigntools efitools ufw"
}

setup_firewall_target() {
  run_in_target "ufw allow ${OSI_SSH_PORT}"
  run_in_target "ufw enable"
}

setup_plymouth_target() {
  run_in_target "plymouth-set-default-theme -R bgrt-shani"
}

generate_mok_keys_target() {
  run_in_target "mkdir -p /usr/share/secureboot/keys"
  run_in_target '[[ ! -f /usr/share/secureboot/keys/MOK.key ]] && \
    openssl req -newkey rsa:4096 -nodes -keyout /usr/share/secureboot/keys/MOK.key -new -x509 -sha256 -days 3650 -out /usr/share/secureboot/keys/MOK.crt -subj "/CN=Shani OS Secure Boot Key/" && \
    openssl x509 -in /usr/share/secureboot/keys/MOK.crt -outform DER -out /usr/share/secureboot/keys/MOK.der && \
    chmod 0600 /usr/share/secureboot/keys/MOK.key'
}

sign_efi_binary() {
  local binary="$1"
  run_in_target "sbsign --key /usr/share/secureboot/keys/MOK.key --cert /usr/share/secureboot/keys/MOK.crt --output $binary $binary"
  run_in_target "sbverify --cert /usr/share/secureboot/keys/MOK.crt $binary"
}

install_secureboot_components_target() {
  run_in_target "cp /usr/share/shim-signed/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI"
  run_in_target "cp /usr/share/shim-signed/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi"
  run_in_target "cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi"
  sign_efi_binary "/boot/efi/EFI/BOOT/grubx64.efi"
}

enroll_mok_key_target() {
  run_in_target "echo -e \"${OSI_USER_PASSWORD}\n${OSI_USER_PASSWORD}\" | mokutil --import /usr/share/secureboot/keys/MOK.der"
}

bypass_mok_prompt_target() {
  log "Attempting to bypass MOK prompt"
  run_in_target "mkdir -p /sys/firmware/efi/efivars" || die "Failed to create efivars directory"
  run_in_target "mount --bind /sys/firmware/efi/efivars /sys/firmware/efi/efivars" || die "efivars bind mount failed"
  run_in_target 'bash -c "
    if [[ -f /usr/share/secureboot/keys/MOK.der ]]; then
      efivar -n MOKList -w -d /usr/share/secureboot/keys/MOK.der  || true;
    fi
  "'
  run_in_target "mokutil --disable-validation" || die "Disabling Secure Boot validation failed"
  run_in_target "umount /sys/firmware/efi/efivars"
}

create_dracut_config_target() {
  run_in_target 'cat > /etc/dracut.conf.d/90-shani.conf <<EOF
compress="zstd"
add_drivers+=" i915 amdgpu radeon nvidia nvidia_modeset nvidia_uvm nvidia_drm "
add_dracutmodules+=" btrfs crypt plymouth resume systemd "
omit_dracutmodules+=" brltty "
early_microcode=yes
use_fstab=yes
hostonly=yes
hostonly_cmdline=no
uefi=yes
uefi_secureboot_cert="/usr/share/secureboot/keys/MOK.crt"
uefi_secureboot_key="/usr/share/secureboot/keys/MOK.key"
uefi_splash_image="/usr/share/systemd/bootctl/splash-arch.bmp"
uefi_stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
EOF'
}

get_kernel_version() {
  run_in_target "ls -1 /usr/lib/modules | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1"
}

generate_uki_entry() {
  local slot="$1"
  local cmdline="quiet splash rootflags=subvol=deployment/system/${slot}"
  
  if run_in_target "[ -e /dev/mapper/${ROOTLABEL} ]"; then
    local luks_uuid=$(run_in_target "blkid -s UUID -o value /dev/mapper/${ROOTLABEL}")
    cmdline+=" rd.luks.uuid=${luks_uuid} rd.luks.options=${luks_uuid}=tpm2-device=auto"
  fi
  
  if run_in_target "[ -f /deployment/data/swap/swapfile ]"; then
    local root_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}")
    local swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r /deployment/data/swap/swapfile | awk '{print \$NF}'")
    cmdline+=" resume=UUID=${root_uuid} resume_offset=${swap_offset}"
  fi

  local cmdfile="$([[ $slot == $(run_in_target "cat /deployment/current-slot") ]] && echo $CMDLINE_FILE_CURRENT || echo $CMDLINE_FILE_CANDIDATE)"
  run_in_target "echo '${cmdline}' | tee ${cmdfile} >/dev/null"
  
  local kernel_version=$(get_kernel_version)
  local uki_path="/boot/${OS_NAME}-${slot}.efi"
  run_in_target "dracut --force --uefi --kver ${kernel_version} --cmdline \"${cmdline}\" ${uki_path}"
  sign_efi_binary "${uki_path}"
  
  run_in_target "cat > ${UKI_BOOT_ENTRY}/shanios-${slot}.conf <<EOF
title   shanios-${slot} (${BASE_VERSION})
efi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi
options \$kernel_cmdline
EOF"
}

main() {
  mount_target
  mount_overlay
  
  setup_locale_target
  setup_timezone_target
  setup_hostname_target
  setup_machine_id_target
  setup_user_target
  set_root_password
  enable_systemd_homed_target
  setup_services_target
  configure_ssh_target
  setup_autologin_target
  install_software_target
  setup_firewall_target
  setup_plymouth_target
  
  generate_mok_keys_target
  install_secureboot_components_target
  enroll_mok_key_target
  create_dracut_config_target
  
  local current_slot=$(run_in_target "cat /deployment/current-slot")
  local candidate_slot=$([[ $current_slot == "blue" ]] && echo "green" || echo "blue")
  
  generate_uki_entry "$current_slot"
  generate_uki_entry "$candidate_slot"
  
  run_in_target "echo '${BASE_VERSION}' > /etc/shani-version"
  log "Configuration completed successfully!"
}

main
