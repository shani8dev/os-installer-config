#!/bin/bash
# configure.sh – Post-installation configuration for Shani OS.
#
# This script performs post-install configuration on the active (immutable) root.
# It mounts the active system subvolume (blue or green) based on the marker stored at
# /deployment/current-slot (visible in the top‐level Btrfs subvolume), mounts the data subvolume,
# and proceeds with additional configuration tasks.
#
# REQUIRED ENVIRONMENT VARIABLES (in addition to those in install.sh):
#   OSI_LOCALE, OSI_DEVICE_PATH, OSI_DEVICE_IS_PARTITION, OSI_DEVICE_EFI_PARTITION,
#   OSI_USE_ENCRYPTION, OSI_ENCRYPTION_PIN, OSI_USER_NAME, OSI_USER_USERNAME,
#   OSI_USER_AUTOLOGIN, OSI_USER_PASSWORD, OSI_FORMATS, OSI_TIMEZONE, OSI_DESKTOP,
#   OSI_HOSTNAME, OSI_KEYBOARD_LAYOUT
#
# Requires root privileges.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'cleanup; echo "[CONFIG][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR
trap cleanup EXIT

### Global configuration variables
OS_NAME="shanios"
OSIDIR="/etc/os-installer"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"

# Kernel command-line file paths (inside the target system)
CMDLINE_FILE_CURRENT="/etc/kernel/install_cmdline_current"
CMDLINE_FILE_CANDIDATE="/etc/kernel/install_cmdline_candidate"
UKI_BOOT_ENTRY="/boot/efi/loader/entries"

# Define deployment and subvolume paths (must match install.sh)
DEPLOYMENT_SUBVOL="/deployment"           # As seen in the top‐level Btrfs subvolume
SYSTEM_SUBVOL="${DEPLOYMENT_SUBVOL}/system" # Active system subvolumes reside here (blue/green)
DATA_SUBVOL="${DEPLOYMENT_SUBVOL}/data"     # Persistent data subvolume

# Active slot marker file (written during install)
CURRENT_SLOT_FILE="${DEPLOYMENT_SUBVOL}/current-slot"

# Mount point for chrooting into the installed system
TARGET="/mnt"

# Cleanup: Unmount target and bind mounts on exit.
cleanup() {
    if mountpoint -q "$TARGET"; then
        echo "[CONFIG][INFO] Unmounting target and its bind mounts..."
        for fs in run dev sys proc; do
            if mountpoint -q "$TARGET/$fs"; then
                umount -R "$TARGET/$fs" || echo "[CONFIG][WARN] Failed to unmount $TARGET/$fs"
            fi
        done
        umount -R "$TARGET" || echo "[CONFIG][WARN] Failed to unmount $TARGET"
    fi
}

# Check required commands
check_prerequisites() {
    local cmds=("arch-chroot" "dracut" "sbsign" "sbverify" "openssl" "blkid" "localectl" "hostnamectl" "mokutil" "mount" "umount" "mkdir")
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "[CONFIG][ERROR] Required command '$cmd' not found. Please install it." >&2
            exit 1
        fi
    done
}
check_prerequisites

# Check for root privileges.
if [[ $EUID -ne 0 ]]; then
    echo "[CONFIG][ERROR] This script must be run as root" >&2
    exit 1
fi

# Check required environment variables.
required_vars=(OSI_LOCALE OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_DEVICE_EFI_PARTITION \
               OSI_USE_ENCRYPTION OSI_ENCRYPTION_PIN OSI_USER_NAME OSI_USER_USERNAME OSI_USER_AUTOLOGIN \
               OSI_USER_PASSWORD OSI_FORMATS OSI_TIMEZONE OSI_DESKTOP OSI_HOSTNAME OSI_KEYBOARD_LAYOUT)
for var in "${required_vars[@]}"; do
    [[ -z "${!var:-}" ]] && { echo "[CONFIG][ERROR] Environment variable $var is not set"; exit 1; }
done

# Logging functions
log_info() { echo "[CONFIG][INFO] $*"; }
die() { echo "[CONFIG][ERROR] $*" >&2; exit 1; }

# get_active_slot: Temporarily mount the Btrfs top‐level (subvolid=5) to read the slot marker.
get_active_slot() {
    local temp_mount="/mnt_top"
    mkdir -p "$temp_mount"
    mount -o subvolid=5 "/dev/disk/by-label/${ROOTLABEL}" "$temp_mount" || die "Failed to mount Btrfs top‐level"
    if [[ ! -f "$temp_mount${CURRENT_SLOT_FILE}" ]]; then
        umount "$temp_mount"
        die "Active slot marker not found at ${CURRENT_SLOT_FILE}"
    fi
    ACTIVE_SLOT=$(cat "$temp_mount${CURRENT_SLOT_FILE}")
    umount "$temp_mount"
    echo "$ACTIVE_SLOT"
}

# mount_target: Mount the active system subvolume and bind essential filesystems.
mount_target() {
    ACTIVE_SLOT=$(get_active_slot)
    log_info "Mounting active system slot '${ACTIVE_SLOT}' from ${SYSTEM_SUBVOL}/${ACTIVE_SLOT} to ${TARGET}"
    mount -o "subvol=${SYSTEM_SUBVOL}/${ACTIVE_SLOT}" "/dev/disk/by-label/${ROOTLABEL}" "$TARGET" \
      || die "Failed to mount active system"
    for fs in proc sys dev run; do
        mount --rbind "/$fs" "$TARGET/$fs" || die "Failed to bind mount /$fs"
    done
    mount --mkdir "/dev/disk/by-label/${BOOTLABEL}" "$TARGET/boot/efi" || die "EFI mount failed"
}

# mount_data_subvolume: Mount the data subvolume for persistent files.
mount_data_subvolume() {
    log_info "Mounting data subvolume at ${TARGET}${DATA_SUBVOL}"
    mkdir -p "$TARGET${DATA_SUBVOL}"  # Ensure the full mount point exists
    mount -o "subvol=${DATA_SUBVOL}" "/dev/disk/by-label/${ROOTLABEL}" "$TARGET${DATA_SUBVOL}" \
      || die "Failed to mount data subvolume"
}

# run_in_target: Execute a command inside the chroot environment.
run_in_target() {
    arch-chroot "$TARGET" /bin/bash -e -c "$1"
}

setup_locale_target() {
    log_info "Setting locale to ${OSI_LOCALE}"
    echo "LANG=${OSI_LOCALE}" > "$TARGET/etc/locale.conf"
    run_in_target "localectl set-locale LANG='${OSI_LOCALE}'"
    [[ -n "${OSI_FORMATS}" ]] && run_in_target "localectl set-locale '${OSI_FORMATS}'"
}

setup_keyboard_target() {
    log_info "Configuring keyboard layout: ${OSI_KEYBOARD_LAYOUT}"
    run_in_target "localectl set-keymap '${OSI_KEYBOARD_LAYOUT}'"
    run_in_target "localectl set-x11-keymap '${OSI_KEYBOARD_LAYOUT}'"
    echo "KEYMAP=${OSI_KEYBOARD_LAYOUT}" > "$TARGET/etc/vconsole.conf"
}

setup_timezone_target() {
    log_info "Setting timezone to ${OSI_TIMEZONE}"
    if [[ ! -f "$TARGET/usr/share/zoneinfo/${OSI_TIMEZONE}" ]]; then
        die "Invalid timezone: ${OSI_TIMEZONE}"
    fi
    ln -sf "/usr/share/zoneinfo/${OSI_TIMEZONE}" "$TARGET/etc/localtime"
    if run_in_target "command -v timedatectl &>/dev/null"; then
        run_in_target "timedatectl set-timezone '${OSI_TIMEZONE}'" || die "Failed to set timezone"
    else
        echo "${OSI_TIMEZONE}" > "$TARGET/etc/timezone"
    fi
}

setup_hostname_target() {
    log_info "Setting hostname to ${OSI_HOSTNAME}"
    echo "${OSI_HOSTNAME}" > "$TARGET/etc/hostname"
    run_in_target "hostnamectl set-hostname '${OSI_HOSTNAME}'"
}

setup_machine_id_target() {
    log_info "Generating new machine-id"
    run_in_target "systemd-machine-id-setup --commit"
}

setup_user_target() {
    log_info "Creating primary user: ${OSI_USER_USERNAME}"
    local groups=("wheel" "input" "realtime" "video" "sys" "cups" "lp" "libvirt" "kvm" "scanner")
    if run_in_target "id '${OSI_USER_USERNAME}'" &>/dev/null; then
        log_info "User ${OSI_USER_USERNAME} already exists."
    else
        if run_in_target "command -v homectl &>/dev/null"; then
            log_info "Using homectl to create user"
            run_in_target "homectl create '${OSI_USER_USERNAME}' --real-name='${OSI_USER_NAME}' \
              --shell='/bin/bash' --storage=directory --member-of='$(IFS=,; echo "${groups[*]}")'" \
              || die "Failed to create user ${OSI_USER_USERNAME}"
            [[ -n "${OSI_USER_PASSWORD}" ]] && \
              printf "%s\n%s" "$OSI_USER_PASSWORD" "$OSI_USER_PASSWORD" | run_in_target "homectl passwd '${OSI_USER_USERNAME}'" \
              || die "Failed to set password"
        else
            log_info "Using useradd to create user"
            run_in_target "useradd -m -s /bin/bash -G '$(IFS=,; echo "${groups[*]}")' '${OSI_USER_USERNAME}'" \
              || die "User creation failed"
            [[ -n "${OSI_USER_PASSWORD}" ]] && \
              printf "%s:%s" "$OSI_USER_USERNAME" "$OSI_USER_PASSWORD" | run_in_target "chpasswd" \
              || die "Failed to set user password"
        fi
    fi
}

setup_autologin_target() {
    if [[ "${OSI_USER_AUTOLOGIN}" -eq 1 ]]; then
        if run_in_target "command -v homectl &>/dev/null"; then
            run_in_target "homectl update '${OSI_USER_USERNAME}' --auto-login" || die "Autologin setup failed"
        else
            log_info "Setting up autologin via systemd"
            mkdir -p "$TARGET/etc/systemd/system/getty@tty1.service.d"
            cat > "$TARGET/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${OSI_USER_USERNAME} --noclear %I \$TERM
EOF
        fi
    fi
}

set_root_password() {
    if [[ -n "${OSI_USER_PASSWORD}" ]]; then
        log_info "Setting root password"
        printf "root:%s" "$OSI_USER_PASSWORD" | run_in_target "chpasswd"
    else
        log_info "Locking root account"
        run_in_target "passwd --lock root"
    fi
}

enable_systemd_homed_target() {
    run_in_target "systemctl enable systemd-homed.service"
}

setup_services_target() {
    log_info "Enabling essential services"
    local services="sshd NetworkManager systemd-timesyncd ufw plymouth"
    [[ "${OSI_DESKTOP}" == "gnome" ]] && services+=" gdm"
    for service in $services; do
        run_in_target "systemctl enable ${service}" || die "Failed to enable ${service}"
    done
}

setup_firewall_target() {
    run_in_target "ufw enable"
}

setup_plymouth_target() {
    run_in_target "plymouth-set-default-theme -R bgrt-shani"
}

generate_mok_keys_target() {
    run_in_target "mkdir -p /usr/share/secureboot/keys"
    if ! run_in_target "[ -f /usr/share/secureboot/keys/MOK.key ] && [ -f /usr/share/secureboot/keys/MOK.crt ] && [ -f /usr/share/secureboot/keys/MOK.der ]"; then
        run_in_target "openssl req -newkey rsa:4096 -nodes -keyout /usr/share/secureboot/keys/MOK.key \
          -new -x509 -sha256 -days 3650 -out /usr/share/secureboot/keys/MOK.crt \
          -subj '/CN=Shani OS Secure Boot Key/'" || die "Failed to generate MOK keys"
        run_in_target "openssl x509 -in /usr/share/secureboot/keys/MOK.crt -outform DER -out /usr/share/secureboot/keys/MOK.der" \
          || die "Failed to convert MOK cert"
        run_in_target "chmod 0600 /usr/share/secureboot/keys/MOK.key"
    fi
}

sign_efi_binary() {
    local binary="$1"
    run_in_target "sbsign --key /usr/share/secureboot/keys/MOK.key --cert /usr/share/secureboot/keys/MOK.crt --output \"$binary\" \"$binary\"" \
      || die "Failed to sign $binary"
    run_in_target "sbverify --cert /usr/share/secureboot/keys/MOK.crt \"$binary\"" \
      || die "Failed to verify $binary"
}

install_secureboot_components_target() {
    run_in_target "cp /usr/share/shim-signed/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI"
    run_in_target "cp /usr/share/shim-signed/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi"
    run_in_target "cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi"
    sign_efi_binary "/boot/efi/EFI/BOOT/grubx64.efi"
}

enroll_mok_key_target() {
    if [[ -z "${OSI_USER_PASSWORD:-}" ]]; then
        log_info "Skipping MOK key enrollment because OSI_USER_PASSWORD is not set."
        return
    fi
    printf "%s\n%s" "$OSI_USER_PASSWORD" "$OSI_USER_PASSWORD" | \
      run_in_target "mokutil --import /usr/share/secureboot/keys/MOK.der" \
      || die "Failed to enroll MOK key"
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
    local kernel_version
    kernel_version=$(run_in_target "ls -1 /usr/lib/modules | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1")
    [[ -z "$kernel_version" ]] && die "No kernel version found"
    echo "$kernel_version"
}

generate_uki_entry() {
    local slot="$1"
    log_info "Generating UKI entry for slot: $slot"
    
    # Build kernel command-line arguments.
    local cmdline_args=(
        "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
        "quiet"
        "splash"
        "loglevel=3"
        "systemd.show_status=auto"
        "rd.udev.log_level=3"
        "rootflags=subvol=${SYSTEM_SUBVOL}/${slot}"
    )
    
    # Append LUKS parameters if applicable.
    if run_in_target "[ -e /dev/mapper/${ROOTLABEL} ]"; then
        local luks_uuid
        luks_uuid=$(run_in_target "blkid -s UUID -o value /dev/mapper/${ROOTLABEL}")
        cmdline_args+=("rd.luks.uuid=${luks_uuid}" "rd.luks.options=${luks_uuid}=tpm2-device=auto")
    fi
    
    # Append resume parameters if a swap file exists.
    if run_in_target "[ -f ${DATA_SUBVOL}/swap/swapfile ]"; then
        local root_uuid swap_offset
        root_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}")
        swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r ${DATA_SUBVOL}/swap/swapfile | awk '{print \$NF}'")
        cmdline_args+=("resume=UUID=${root_uuid}" "resume_offset=${swap_offset}")
    fi
    
    local cmdline
    cmdline=$(IFS=' '; echo "${cmdline_args[*]}")
    
    # Write kernel command-line file.
    local current_slot_file
    if [[ "$slot" == "$(get_active_slot)" ]]; then
        current_slot_file="$CMDLINE_FILE_CURRENT"
    else
        current_slot_file="$CMDLINE_FILE_CANDIDATE"
    fi
    echo "$cmdline" > "$TARGET/$current_slot_file"
    
    # Generate the UKI image.
    local kernel_version
    kernel_version=$(get_kernel_version)
    local uki_dir="/boot/efi/EFI/${OS_NAME}"
    local uki_path="${uki_dir}/${OS_NAME}-${slot}.efi"
    run_in_target "mkdir -p '${uki_dir}'"
    run_in_target "dracut --force --uefi --kver '${kernel_version}' --cmdline '${cmdline}' '${uki_path}'"
    sign_efi_binary "$uki_path"
    run_in_target "mkdir -p '${UKI_BOOT_ENTRY}'"
    run_in_target "cat > '${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}.conf' <<EOF
title   ${OS_NAME}-${slot}
efi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi
EOF"
}

main() {
    mount_target
    mount_data_subvolume
    setup_locale_target
    setup_keyboard_target
    setup_timezone_target
    setup_hostname_target
    setup_machine_id_target
    setup_user_target
    set_root_password
    setup_autologin_target
    enable_systemd_homed_target
    setup_services_target
    setup_firewall_target
    setup_plymouth_target
    generate_mok_keys_target
    install_secureboot_components_target
    enroll_mok_key_target
    create_dracut_config_target

    local current_slot candidate_slot
    current_slot=$(get_active_slot)
    if [[ "$current_slot" == "blue" ]]; then
        candidate_slot="green"
    else
        candidate_slot="blue"
    fi

    generate_uki_entry "$current_slot"
    generate_uki_entry "$candidate_slot"

    log_info "Configuration completed successfully!"
}

main

