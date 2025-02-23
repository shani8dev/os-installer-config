#!/bin/bash
# configure.sh – Post-installation configuration for Shani OS.
# Improved version with enhanced error handling, explicit if/else logic, and added logging.

set -Eeuo pipefail
IFS=$'\n\t'

# Global flag to prevent double cleanup execution.
CLEANED_UP=0

# Optional: Enable debug mode by uncommenting the following line.
# [ "${DEBUG:-0}" -eq 1 ] && set -x

########################################
# Helper Functions
########################################

# ensure_dir: Create a directory if it doesn't exist.
ensure_dir() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        log_info "Creating directory: $dir_path"
        sudo mkdir -p "$dir_path" || die "Failed to create directory: $dir_path"
    else
        log_info "Directory already exists: $dir_path"
    fi
}

# Logging functions.
log_info() { echo "[CONFIG][INFO] $*"; }
log_error() { echo "[CONFIG][ERROR] $*"; }
die() { log_error "$*"; exit 1; }

########################################
# Cleanup and Trap Handlers
########################################

# cleanup: Unmount target and its bind mounts.
cleanup() {
    if [[ $CLEANED_UP -eq 1 ]]; then
        return
    fi
    CLEANED_UP=1
    if mountpoint -q "$TARGET"; then
        log_info "Unmounting target and its bind mounts..."
        for fs in run dev sys proc; do
            if mountpoint -q "$TARGET/$fs"; then
                sudo umount -R "$TARGET/$fs" || log_error "Failed to unmount $TARGET/$fs"
            fi
        done
        sudo umount -R "$TARGET" || log_error "Failed to unmount $TARGET"
    fi
}

# Trap ERR: Log error details, cleanup, and exit.
trap 'cleanup; log_error "[CONFIG][ERROR] Error at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR
# Trap EXIT: Always run cleanup.
trap cleanup EXIT

########################################
# Global Configuration Variables
########################################

OS_NAME="shanios"
OSIDIR="/etc/os-installer"
ROOTLABEL="shani_root"
BOOTLABEL="shani_boot"

# Kernel command-line file paths (inside the target system)
CMDLINE_FILE_CURRENT="/etc/kernel/install_cmdline_current"
CMDLINE_FILE_CANDIDATE="/etc/kernel/install_cmdline_candidate"
UKI_BOOT_ENTRY="/boot/efi/loader/entries"

# Deployment subvolume paths (must match install.sh)
DEPLOYMENT_SUBVOL="/deployment"           # Top-level Btrfs subvolume
SYSTEM_SUBVOL="${DEPLOYMENT_SUBVOL}/system" # Active system (blue/green) subvolumes
DATA_SUBVOL="${DEPLOYMENT_SUBVOL}/data"     # Persistent data subvolume

# Active slot marker file (written during install)
CURRENT_SLOT_FILE="${DEPLOYMENT_SUBVOL}/current-slot"

# Mount point for chrooting into the installed system
TARGET="/mnt"

########################################
# Prerequisite and Environment Checks
########################################

check_prerequisites() {
    local cmds=("arch-chroot" "dracut" "sbsign" "sbverify" "openssl" "blkid" "localectl" "hostnamectl" "mokutil" "mount" "umount" "mkdir")
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            die "Required command '$cmd' not found. Please install it."
        fi
    done
    # All prerequisites met:
    log_info "All prerequisites are installed."
}
check_prerequisites

check_env() {
    local missing_vars=()
    local required_vars=(OSI_LOCALE OSI_KEYBOARD_LAYOUT OSI_DEVICE_PATH OSI_DEVICE_IS_PARTITION OSI_DEVICE_EFI_PARTITION OSI_USE_ENCRYPTION OSI_USER_NAME OSI_USER_AUTOLOGIN OSI_USER_PASSWORD OSI_FORMATS OSI_TIMEZONE)
    for var in "${required_vars[@]}"; do
        [ -z "${!var:-}" ] && missing_vars+=("$var")
    done
    if [[ "${OSI_USE_ENCRYPTION:-0}" -eq 1 && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
        missing_vars+=("OSI_ENCRYPTION_PIN")
    fi
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    else
        log_info "All required environment variables are set."
    fi
}
check_env

########################################
# Main Functional Blocks
########################################

# get_active_slot: Mount the Btrfs top-level subvolume (subvolid=5) to read the active slot marker.
get_active_slot() {
    local temp_mount="/mnt_top"
    ensure_dir "$temp_mount"
    sudo mount -o subvolid=5 "/dev/disk/by-label/${ROOTLABEL}" "$temp_mount" || die "Failed to mount Btrfs top-level"
    if [[ ! -f "$temp_mount${CURRENT_SLOT_FILE}" ]]; then
        sudo umount "$temp_mount"
        die "Active slot marker not found at ${CURRENT_SLOT_FILE}"
    fi
    local active_slot
    active_slot=$(cat "$temp_mount${CURRENT_SLOT_FILE}")
    sudo umount "$temp_mount"
    echo "$active_slot"
}

# mount_target: Mount the active system subvolume and bind essential filesystems.
mount_target() {
    local active_slot
    active_slot=$(get_active_slot)
    log_info "Mounting active system slot '${active_slot}' from ${SYSTEM_SUBVOL}/${active_slot} to ${TARGET}"
    ensure_dir "$TARGET"
    sudo mount -o "subvol=${SYSTEM_SUBVOL}/${active_slot}" "/dev/disk/by-label/${ROOTLABEL}" "$TARGET" \
        || die "Failed to mount active system"
    for fs in proc sys dev run; do
        sudo mount --rbind "/$fs" "$TARGET/$fs" || die "Failed to bind mount /$fs"
    done
    sudo mount --mkdir "/dev/disk/by-label/${BOOTLABEL}" "$TARGET/boot/efi" || die "EFI mount failed"
}

# mount_data_subvolume: Mount the persistent data subvolume.
mount_data_subvolume() {
    log_info "Mounting data subvolume at ${TARGET}${DATA_SUBVOL}"
    ensure_dir "$TARGET${DATA_SUBVOL}"
    sudo mount -o "subvol=${DATA_SUBVOL}" "/dev/disk/by-label/${ROOTLABEL}" "$TARGET${DATA_SUBVOL}" \
        || die "Failed to mount data subvolume"
}

# run_in_target: Execute a command inside the chroot environment.
run_in_target() {
    local cmd="$1"
    sudo chroot "$TARGET" /bin/bash -e -c "$cmd"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        die "Command failed in chroot: $cmd"
    fi
}

# setup_locale_target: Configure system locale inside chroot.
setup_locale_target() {
    log_info "Setting locale to ${OSI_LOCALE}"
    run_in_target "echo \"LANG=${OSI_LOCALE}\" | tee /etc/locale.conf > /dev/null"
    run_in_target "localectl set-locale LANG='${OSI_LOCALE}'"
    if [[ -n "${OSI_FORMATS}" ]]; then
        run_in_target "localectl set-locale '${OSI_FORMATS}'"
    fi
}

# setup_keyboard_target: Configure keyboard layout inside chroot.
setup_keyboard_target() {
    log_info "Configuring keyboard layout: ${OSI_KEYBOARD_LAYOUT}"
    run_in_target "echo \"KEYMAP=${OSI_KEYBOARD_LAYOUT}\" | tee /etc/vconsole.conf > /dev/null"
    run_in_target "localectl set-keymap '${OSI_KEYBOARD_LAYOUT}'"
    run_in_target "localectl set-x11-keymap '${OSI_KEYBOARD_LAYOUT}'"
}

# setup_timezone_target: Configure system timezone inside chroot.
setup_timezone_target() {
    log_info "Setting timezone to ${OSI_TIMEZONE}"
    run_in_target "test -f /usr/share/zoneinfo/${OSI_TIMEZONE}" || die "Invalid timezone: ${OSI_TIMEZONE}"
    run_in_target "ln -sf /usr/share/zoneinfo/${OSI_TIMEZONE} /etc/localtime"
    run_in_target "echo '${OSI_TIMEZONE}' | tee /etc/timezone > /dev/null"
    run_in_target "timedatectl set-timezone '${OSI_TIMEZONE}'"
}


# setup_hostname_target: Set the system hostname inside chroot.
setup_hostname_target() {
    log_info "Setting hostname to ${OS_NAME}"
    run_in_target "echo \"${OS_NAME}\" | tee /etc/hostname > /dev/null"
    run_in_target "hostnamectl set-hostname '${OS_NAME}'"
}

# setup_machine_id_target: Generate a new machine-id inside chroot.
setup_machine_id_target() {
    log_info "Generating new machine-id"
    run_in_target "systemd-machine-id-setup --commit"
}

# setup_user_target: Create the primary user inside chroot.
setup_user_target() {
    log_info "Creating primary user: ${OSI_USER_NAME}"
    local groups=("wheel" "input" "realtime" "video" "sys" "cups" "lp" "libvirt" "kvm" "scanner")
    log_info "Using useradd to create user"
    run_in_target "useradd -m -s /bin/bash -G '$(IFS=,; echo \"${groups[*]}\")' '${OSI_USER_NAME}'" \
        || die "User creation failed"
    if [[ -n "${OSI_USER_PASSWORD}" ]]; then
        printf "%s:%s" "$OSI_USER_NAME" "$OSI_USER_PASSWORD" | run_in_target "chpasswd" \
            || die "Failed to set user password"
    fi
}

# setup_autologin_target: Configure autologin based on available display managers.
setup_autologin_target() {
    if [[ "${OSI_USER_AUTOLOGIN}" -eq 1 ]]; then
        if run_in_target "command -v gdm >/dev/null 2>&1"; then
            log_info "GDM detected in chroot. Configuring GDM autologin."
            run_in_target "mkdir -p /etc/gdm"
            run_in_target "printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' \"${OSI_USER_NAME}\" > /etc/gdm/custom.conf"
        else
            log_info "GDM not detected in chroot. Configuring systemd getty autologin for tty1."
            run_in_target "mkdir -p /etc/systemd/system/getty@tty1.service.d"
            run_in_target "printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin %s --noclear %%I \$TERM\n' \"${OSI_USER_NAME}\" > /etc/systemd/system/getty@tty1.service.d/autologin.conf"
        fi
    else
        log_info "Autologin not enabled."
    fi
}

# set_root_password: Set root password or lock the root account.
set_root_password() {
    if [[ -n "${OSI_USER_PASSWORD}" ]]; then
        log_info "Setting root password"
        printf "root:%s" "$OSI_USER_PASSWORD" | run_in_target "chpasswd"
    else
        log_info "Locking root account"
        run_in_target "passwd --lock root"
    fi
}

# setup_firewall_target: Enable the UFW firewall inside chroot.
setup_firewall_target() {
    run_in_target "ufw enable"
}

# generate_mok_keys_target: Generate and convert Secure Boot MOK keys if not present.
generate_mok_keys_target() {
    run_in_target "mkdir -p /usr/share/secureboot/keys"
    if ! run_in_target "[ -f /usr/share/secureboot/keys/MOK.key ] && [ -f /usr/share/secureboot/keys/MOK.crt ] && [ -f /usr/share/secureboot/keys/MOK.der ]"; then
        run_in_target "openssl req -newkey rsa:4096 -nodes -keyout /usr/share/secureboot/keys/MOK.key -new -x509 -sha256 -days 3650 -out /usr/share/secureboot/keys/MOK.crt -subj '/CN=Shani OS Secure Boot Key/'" \
            || die "Failed to generate MOK keys"
        run_in_target "openssl x509 -in /usr/share/secureboot/keys/MOK.crt -outform DER -out /usr/share/secureboot/keys/MOK.der" \
            || die "Failed to convert MOK cert"
        run_in_target "chmod 0600 /usr/share/secureboot/keys/MOK.key"
    else
        log_info "MOK keys already exist."
    fi
}

# sign_efi_binary: Sign and verify an EFI binary.
sign_efi_binary() {
    local binary="$1"
    run_in_target "sbsign --key /usr/share/secureboot/keys/MOK.key --cert /usr/share/secureboot/keys/MOK.crt --output \"$binary\" \"$binary\"" \
        || die "Failed to sign $binary"
    run_in_target "sbverify --cert /usr/share/secureboot/keys/MOK.crt \"$binary\"" \
        || die "Failed to verify $binary"
}

# install_secureboot_components_target: Install and sign Secure Boot components.
install_secureboot_components_target() {
    run_in_target "mkdir -p /boot/efi/EFI/BOOT"
    run_in_target "cp /usr/share/shim-signed/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI"
    run_in_target "cp /usr/share/shim-signed/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi"
    run_in_target "cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi"
    sign_efi_binary "/boot/efi/EFI/BOOT/grubx64.efi"
}

# create_dracut_config_target: Create dracut configuration for Shani OS.
create_dracut_config_target() {
    run_in_target "mkdir -p /etc/dracut.conf.d"
    run_in_target "cat > /etc/dracut.conf.d/90-shani.conf <<'EOF'
compress=\"zstd\"
add_drivers+=\" i915 amdgpu radeon nvidia nvidia_modeset nvidia_uvm nvidia_drm \"
add_dracutmodules+=\" btrfs crypt plymouth resume systemd \"
omit_dracutmodules+=\" brltty \"
early_microcode=yes
use_fstab=yes
hostonly=yes
hostonly_cmdline=no
uefi=yes
uefi_secureboot_cert=\"/usr/share/secureboot/keys/MOK.crt\"
uefi_secureboot_key=\"/usr/share/secureboot/keys/MOK.key\"
uefi_splash_image=\"/usr/share/systemd/bootctl/splash-arch.bmp\"
uefi_stub=\"/usr/lib/systemd/boot/efi/linuxx64.efi.stub\"
EOF"
}

# get_kernel_version: Determine the kernel version inside chroot.
get_kernel_version() {
    local kernel_version
    kernel_version=$(run_in_target "ls -1 /usr/lib/modules | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1")
    if [[ -z "$kernel_version" ]]; then
        die "No kernel version found"
    else
        echo "$kernel_version"
    fi
}

# generate_uki_entry: Generate a UEFI kernel image (UKI) entry for the given slot.
generate_uki_entry() {
    local slot="$1"
    log_info "Generating UKI entry for slot: $slot"
    
    local cmdline_args=(
        "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
        "quiet"
        "splash"
        "loglevel=3"
        "systemd.show_status=auto"
        "rd.udev.log_level=3"
        "rootflags=subvol=${SYSTEM_SUBVOL}/${slot}"
    )
    
    if run_in_target "[ -e /dev/mapper/${ROOTLABEL} ]"; then
        local luks_uuid
        luks_uuid=$(run_in_target "blkid -s UUID -o value /dev/mapper/${ROOTLABEL}")
        cmdline_args+=( "rd.luks.uuid=${luks_uuid}" "rd.luks.options=${luks_uuid}=tpm2-device=auto" )
    fi
    
    if run_in_target "[ -f ${DATA_SUBVOL}/swap/swapfile ]"; then
        local root_uuid swap_offset
        root_uuid=$(run_in_target "blkid -s UUID -o value /dev/disk/by-label/${ROOTLABEL}")
        swap_offset=$(run_in_target "btrfs inspect-internal map-swapfile -r ${DATA_SUBVOL}/swap/swapfile | awk '{print \$NF}'")
        cmdline_args+=( "resume=UUID=${root_uuid}" "resume_offset=${swap_offset}" )
    fi
    
    local cmdline
    cmdline=$(IFS=' '; echo "${cmdline_args[*]}")
    
    local current_slot_file
    if [[ "$slot" == "$(get_active_slot)" ]]; then
        current_slot_file="$CMDLINE_FILE_CURRENT"
    else
        current_slot_file="$CMDLINE_FILE_CANDIDATE"
    fi
    echo "$cmdline" | sudo tee "$TARGET/$current_slot_file" > /dev/null
    
    local kernel_version
    kernel_version=$(get_kernel_version)
    local uki_dir="/boot/efi/EFI/${OS_NAME}"
    local uki_path="${uki_dir}/${OS_NAME}-${slot}.efi"
    run_in_target "mkdir -p '${uki_dir}'"
    run_in_target "dracut --force --uefi --kver '${kernel_version}' --cmdline '${cmdline}' '${uki_path}'"
    sign_efi_binary "$uki_path"
    run_in_target "mkdir -p '${UKI_BOOT_ENTRY}'"
    run_in_target "printf 'title   ${OS_NAME}-${slot}\nefi     /EFI/${OS_NAME}/${OS_NAME}-${slot}.efi\n' > '${UKI_BOOT_ENTRY}/${OS_NAME}-${slot}.conf'"
}

# setup_plymouth_target: Set the default Plymouth theme.
setup_plymouth_target() {
    run_in_target "plymouth-set-default-theme bgrt-shani"
}

# enroll_mok_key_target: Enroll the MOK key (if OSI_USER_PASSWORD is set).
enroll_mok_key_target() {
    if [[ -z "${OSI_USER_PASSWORD:-}" ]]; then
        log_info "Skipping MOK key enrollment because OSI_USER_PASSWORD is not set."
        return
    else
        printf "%s\n%s" "$OSI_USER_PASSWORD" "$OSI_USER_PASSWORD" | \
            run_in_target "mokutil --import /usr/share/secureboot/keys/MOK.der" \
            || die "Failed to enroll MOK key"
    fi
}

########################################
# Main Execution Flow
########################################

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
    setup_firewall_target
    generate_mok_keys_target
    install_secureboot_components_target
    create_dracut_config_target

    local current_slot candidate_slot
    current_slot=$(get_active_slot)
    # Expect only "blue" or "green"; otherwise, error out.
    if [[ "$current_slot" == "blue" ]]; then
        candidate_slot="green"
    elif [[ "$current_slot" == "green" ]]; then
        candidate_slot="blue"
    else
        die "Unexpected active slot value: $current_slot"
    fi

    generate_uki_entry "$current_slot"
    generate_uki_entry "$candidate_slot"
    setup_plymouth_target
    enroll_mok_key_target
    log_info "Configuration completed successfully!"
}

main

