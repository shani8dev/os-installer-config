#!/usr/bin/env bash

set -o pipefail
set -e  # Exit immediately if a command exits with a non-zero status.

# Constants
readonly WORKDIR='/mnt/deployment/shared/roota'  # Update as needed
readonly OSIDIR='/etc/os-installer'
readonly USER_SHELL="/bin/bash"  # Change to desired shell if needed
readonly USER_GROUPS=("wheel" "input" "realtime" "lp" "video" "sys" "cups" "libvirt" "kvm")
readonly ROOTLABEL='shani_root'
readonly BOOTLABEL='shani_boot'
readonly SWAPLABEL='shani_swap'

# Function to quit and notify user of an error
quit_on_err() {
    local message="$1"
    [[ -n $message ]] && printf "Error: %s\n" "$message"
    sleep 2
    exit 1
}

# Function to check if the user is in sudo group
check_sudo() {
    if ! groups | grep -qE '^(wheel|sudo)'; then
        quit_on_err 'The current user is not a member of either the sudo or wheel group. This OS-installer configuration requires sudo permissions.'
    fi
}

# Function to check required environment variables
check_env_vars() {
    local required_vars=(
        "OSI_LOCALE"
        "OSI_DEVICE_PATH"
        "OSI_DEVICE_IS_PARTITION"
        "OSI_DEVICE_EFI_PARTITION"
        "OSI_USE_ENCRYPTION"
        "OSI_ENCRYPTION_PIN"
        "OSI_USER_NAME"
        "OSI_USER_AUTOLOGIN"
        "OSI_USER_PASSWORD"
        "OSI_FORMATS"
        "OSI_TIMEZONE"
        "OSI_ADDITIONAL_SOFTWARE"
        "OSI_ADDITIONAL_FEATURES"
        "OSI_DESKTOP"
    )

    for var in "${required_vars[@]}"; do
        [[ -z ${!var+x} ]] && quit_on_err "$var is not set"
    done
}

# Function to copy overlay to new root
copy_overlay() {
    sudo cp -rv "$OSIDIR/overlay/"* "$WORKDIR/" || quit_on_err 'Failed to copy overlay files'
}

# Function to enable systemd-homed
enable_systemd_homed() {
    echo "Enabling systemd-homed service"
    sudo arch-chroot "$WORKDIR" systemctl enable systemd-homed.service || quit_on_err 'Failed to enable systemd-homed'
    sudo arch-chroot "$WORKDIR" systemctl start systemd-homed.service || quit_on_err 'Failed to start systemd-homed'
}

# Function to set up locale
setup_locale() {
    echo "Generating locale: $OSI_LOCALE"
    echo "$OSI_LOCALE UTF-8" | sudo tee -a "$WORKDIR/etc/locale.gen" > /dev/null
    sudo arch-chroot "$WORKDIR" locale-gen || quit_on_err 'Failed to generate locale'

    if [[ -n $OSI_FORMATS ]]; then
        echo "Setting locale formats: $OSI_FORMATS"
        sudo arch-chroot "$WORKDIR" localectl set-locale "$OSI_FORMATS" || quit_on_err 'Failed to set locale formats'
    fi
}

# Function to set timezone using systemd
setup_timezone() {
    echo "Setting timezone to: $OSI_TIMEZONE"
    sudo arch-chroot "$WORKDIR" timedatectl set-timezone "$OSI_TIMEZONE" || quit_on_err 'Failed to set timezone'
}

# Function to create user with systemd-homed
setup_user() {
    echo "Creating user: $OSI_USER_NAME"

    # Create the user with homectl
    sudo arch-chroot "$WORKDIR" homectl create "$OSI_USER_NAME" --password="$OSI_USER_PASSWORD" --shell="$USER_SHELL" || quit_on_err 'Failed to create user with systemd-homed'

    # Add user to groups
    for group in "${USER_GROUPS[@]}"; do
        if ! sudo arch-chroot "$WORKDIR" groups "$OSI_USER_NAME" | grep -q "$group"; then
            sudo arch-chroot "$WORKDIR" homectl add-group "$OSI_USER_NAME" "$group" || quit_on_err "Failed to add user to group: $group"
        fi
    done
}

# Function to set up hostname
setup_hostname() {
    echo "Setting hostname to: $OSI_HOSTNAME"
    sudo arch-chroot "$WORKDIR" hostnamectl set-hostname "$OSI_HOSTNAME" || quit_on_err 'Failed to set hostname'
}

# Function to set up machine ID
setup_machine_id() {
    echo "Generating machine ID"
    sudo arch-chroot "$WORKDIR" systemd-machine-id-setup || quit_on_err 'Failed to set machine ID'
}

# Function to enable and start essential services
setup_services() {
    local services=("sshd" "NetworkManager" "systemd-timesyncd")  # List of services to enable

    for service in "${services[@]}"; do
        echo "Enabling and starting service: $service"
        sudo arch-chroot "$WORKDIR" systemctl enable "$service" || quit_on_err "Failed to enable $service"
        sudo arch-chroot "$WORKDIR" systemctl start "$service" || quit_on_err "Failed to start $service"
    done
}

# Function to configure SSH
configure_ssh() {
    echo "Configuring SSH on port: $OSI_SSH_PORT"
    sudo arch-chroot "$WORKDIR" sed -i "s/#Port 22/Port $OSI_SSH_PORT/" /etc/ssh/sshd_config || quit_on_err 'Failed to set SSH port'
    sudo arch-chroot "$WORKDIR" systemctl restart sshd || quit_on_err 'Failed to restart SSH service'
}

# Function to set up auto-login using homectl
setup_autologin() {
    if [[ $OSI_USER_AUTOLOGIN -eq 1 ]]; then
        echo "Setting up auto-login for user: $OSI_USER_NAME"

        # Enable auto-login for the user using homectl
        sudo arch-chroot "$WORKDIR" homectl set "$OSI_USER_NAME" --autologin || quit_on_err 'Failed to enable auto-login for user with homectl'

        echo "Auto-login setup complete. Please run 'systemctl daemon-reload' and reboot to apply changes."
    else
        echo "Auto-login is not enabled for user: $OSI_USER_NAME"
    fi
}


# Function to install additional software
install_software() {
    if [[ -n $OSI_ADDITIONAL_SOFTWARE ]]; then
        echo "Installing additional software: $OSI_ADDITIONAL_SOFTWARE"
        sudo arch-chroot "$WORKDIR" pacman -Sy --noconfirm $OSI_ADDITIONAL_SOFTWARE || quit_on_err 'Failed to install additional software'
    else
        echo "No additional software specified for installation."
    fi
}

# Function to configure the firewall
setup_firewall() {
    echo "Setting up firewall..."
    sudo arch-chroot "$WORKDIR" pacman -Sy --noconfirm ufw || quit_on_err 'Failed to install UFW'
    sudo arch-chroot "$WORKDIR" ufw allow "$OSI_SSH_PORT" || quit_on_err 'Failed to allow SSH port in firewall'
    sudo arch-chroot "$WORKDIR" ufw enable || quit_on_err 'Failed to enable firewall'
}

# Function to set Plymouth theme
setup_plymouth() {
    echo "Setting Plymouth theme to: bgrt-shani"
    sudo arch-chroot "$WORKDIR" plymouth-set-default-theme -R bgrt-shani || quit_on_err 'Failed to set Plymouth theme'
}

# Function to enable GDM for GNOME desktop
enable_gdm() {
    if [[ $OSI_DESKTOP == "gnome" ]]; then
        echo "Enabling GDM for GNOME desktop..."
        sudo arch-chroot "$WORKDIR" systemctl enable gdm.service || quit_on_err 'Failed to enable GDM'
    fi
}

# Function to create Dracut configuration file
create_dracut_config() {
    local mok_key="/path/to/your/mok.key"       # Path to your MOK and Secure Boot key (same for both)
    local mok_cert="/path/to/your/mok.crt"     # Path to your MOK and Secure Boot certificate (same for both)
    local splash_image="/usr/share/systemd/bootctl/splash-arch.bmp" # Path to splash image
    local uefi_stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"   # Path to UEFI stub

    echo "Creating Dracut configuration at /etc/dracut.conf.d/shani.conf"

    # Validate existence of required files
    if [[ ! -f "$mok_key" ]]; then
        echo "Warning: Secure boot key not found: $mok_key" >&2
        return 1  # Exit if the key is not found
    fi
    if [[ ! -f "$mok_cert" ]]; then
        echo "Warning: Secure boot certificate not found: $mok_cert" >&2
        return 1  # Exit if the certificate is not found
    fi
    if [[ ! -f "$splash_image" ]]; then
        echo "Warning: UEFI splash image not found: $splash_image" >&2
        return 1  # Exit if the splash image is not found
    fi

    # Create the Dracut configuration file within chroot
    if sudo arch-chroot "$WORKDIR" test -f /etc/dracut.conf.d/shani.conf; then
        echo "Warning: Dracut configuration file already exists." >&2
    else
        sudo arch-chroot "$WORKDIR" bash -c "cat <<'EOF' > /etc/dracut.conf.d/shani.conf
compress=\"zstd\"
add_drivers+=\"i915 amdgpu xe radeon nouveau\"
add_dracutmodules+=\"btrfs lvm mdraid crypt network plymouth uefi resume\"
omit_dracutmodules+=\"brltty\"
early_microcode=yes
use_fstab=yes
hostonly=yes
hostonly_cmdline=no
uefi=yes
uefi_secureboot_cert=\"$mok_cert\"
uefi_secureboot_key=\"$mok_key\"
uefi_splash_image=\"$splash_image\"
uefi_stub=\"$uefi_stub\"
resume='\"$( [[ \"\$OSI_USE_ENCRYPTION\" -eq 1 ]] && echo \"/dev/mapper/\$SWAPLABEL\" || echo \"/swapfile\")\"'
EOF" || echo 'Failed to create Dracut configuration file' >&2
    fi
}


# Function to get the UUID of the root filesystem and check for encryption
get_uuid_and_encryption() {
    local source_device
    source_device="$(sudo arch-chroot "$WORKDIR" df --output=source / | tail -n1)"
    
    # Get UUID and check if it's LUKS encrypted
    local blkid_info
    blkid_info=$(sudo arch-chroot "$WORKDIR" blkid "$source_device")
    
    # Extract UUID
    local uuid
    uuid=$(echo "$blkid_info" | awk -F'UUID=' '{ print $2 }' | awk '{ print $1 }' | tr -d '"')

    # Check for LUKS encryption
    if echo "$blkid_info" | grep -q 'luks'; then
        echo "$uuid" "luks"
    else
        echo "$uuid" "plain"
    fi
}

# Function to generate the kernel command line configuration
generate_cmdline() {
    local root_name="$1"
    local subvol="$2"  # Add subvolume parameter
    local uuid_and_encryption
    uuid_and_encryption=$(get_uuid_and_encryption)
    local uuid
    uuid=$(echo "$uuid_and_encryption" | awk '{ print $1 }')
    local encryption_type
    encryption_type=$(echo "$uuid_and_encryption" | awk '{ print $2 }')

    # Start the command line with common options
    local cmdline="quiet splash root=UUID=${uuid} rootflags=subvol=${subvol}"

    # Add LUKS options if encryption is detected
    if [[ "$encryption_type" == "luks" ]]; then
        local luks_uuid
        luks_uuid=$(sudo arch-chroot "$WORKDIR" blkid | grep "$uuid" | awk -F'/dev/mapper/' '{ print $2 }' | awk '{ print $1 }' | tr -d '"')
        cmdline+=" rd.luks.uuid=${luks_uuid} rd.luks.options=${luks_uuid}=tpm2-device=auto"
    fi

    # Output to the configuration file inside chroot
    echo "kernel_cmdline=\"${cmdline}\"" | sudo tee "$WORKDIR/etc/dracut.conf.d/dracut-cmdline-${root_name}.conf" > /dev/null

    echo "Generated command line configuration for ${root_name}."
}

# Function to generate UEFI images
generate_uefi_image() {
    local root_name="$1"
    local subvol="$2"  # Add subvolume parameter
    local image_name="shanios-${root_name,,}.efi"  # Set image name directly
    local cmdline

    # Retrieve the command line from the configuration file
    cmdline=$(sudo arch-chroot "$WORKDIR" bash -c "source /etc/dracut.conf.d/dracut-cmdline-${root_name}.conf && echo \$kernel_cmdline")

    echo ":: Building unified kernel image for ${root_name}..."
    
    # Create the UEFI image with the desired name
    if ! sudo arch-chroot "$WORKDIR" dracut -q -f --uefi --cmdline "${cmdline}" --name "${image_name}"; then
        echo "Error: Failed to build unified kernel image for ${root_name}." >&2
        return 1
    fi

    echo "Generated UEFI image: ${image_name}."
}


remove_uefi_images() {
    local efi_path
    local images=("shanios-roota.efi" "shanios-rootb.efi")

    efi_path="$(sudo arch-chroot "$WORKDIR" bootctl -p)"
    echo ":: Removing UEFI images..."

    for image in "${images[@]}"; do
        if sudo arch-chroot "$WORKDIR" [[ -e "${efi}/EFI/Linux/${image}" ]]; then
            sudo arch-chroot "$WORKDIR" rm -f "${efi}/EFI/Linux/${image}"
            echo "Removed: ${image}"
        else
            echo "Image not found: ${image}"
        fi
    done
}

# Function to create initramfs with dracut inside arch-chroot
create_initramfs() {
    echo "Creating initramfs images using dracut..."
    generate_uefi_image "roota" "deployment/shared/roota"
    generate_uefi_image "rootb" "deployment/shared/rootb"
}

# Function to install systemd-boot bootloader
install_bootloader() {
    local mok_key="/etc/ssl/private/mok.key"       # Path to your MOK and Secure Boot key
    local mok_cert="/etc/ssl/certs/mok.crt"       # Path to your MOK and Secure Boot certificate
    local mok_cer="/etc/ssl/certs/mok.cer"        # Path to your MOK certificate file

    echo "Installing systemd-boot bootloader..."

    # Execute all commands inside the arch-chroot environment
    sudo arch-chroot "$WORKDIR" bash -c "
        set -e  # Exit on error

        # Define paths
        mok_key=\"$mok_key\"
        mok_cert=\"$mok_cert\"
        mok_cer=\"$mok_cer\"

        # Create bootloader directory and configuration file
        mkdir -p /boot/loader
        cat <<'EOF' > /boot/loader/loader.conf
default shanios-roota.efi
timeout 5
console-mode max
EOF

        # Install bootloader using bootctl
        bootctl install || { echo 'Failed to install systemd-boot'; exit 1; }

        # Get the EFI system partition directory
        efi_path=\$(bootctl -p)
        BOOT_LOADER_EFI=\"\${efi_path}/EFI/systemd/systemd-bootx64.efi\"
        SHIM_TARGET_EFI=\"\${efi_path}/EFI/BOOT/grubx64.efi\" 

        # Check if the bootloader and shim are identical
        if diff -q \"\$BOOT_LOADER_EFI\" \"\$SHIM_TARGET_EFI\"; then
            echo 'info: no changes, nothing to do'
            exit 0
        fi

        # Copy the bootloader as the EFI shim target
        cp \"\$BOOT_LOADER_EFI\" \"\$SHIM_TARGET_EFI\" && echo 'info: bootloader installed as EFI shim target'

        # Copy shim and MOK certificate
        echo 'Copying shim and certificate...'
        if [[ ! -f /usr/share/shim-signed/shimx64.efi || ! -f /usr/share/shim-signed/mmx64.efi ]]; then
            echo 'Shim files not found' && exit 1
        fi

        cp -t \"\$efi_path\" /usr/share/shim-signed/{shim,mm}x64.efi || { echo 'Failed to copy shim and mm files'; exit 1; }
        cp \"\$mok_cer\" \"\$efi_path\" || { echo 'Failed to copy MOK certificate'; exit 1; }
        
        # Sign the grub EFI file if it exists
        if [[ -f \"\${efi_path}/EFI/BOOT/grubx64.efi\" ]]; then
            sbsign --key \"\$mok_key\" --cert \"\$mok_cert\" --output \"\${efi_path}/EFI/BOOT/grubx64.efi\" \"\${efi_path}/EFI/BOOT/grubx64.efi\" || { echo 'Failed to sign grubx64.efi'; exit 1; }
        else
            echo 'grubx64.efi not found for signing' && exit 1
        fi

        # Define the EFI binaries to sign
        efi_binaries=(\"EFI/Linux/shanios-roota.efi\" \"EFI/Linux/shanios-rootb.efi\")  # Adjusted path

        # Sign each EFI binary
        for efi_binary in \"\${efi_binaries[@]}\"; do
            echo \"Signing \$efi_binary...\"
            sbsign --key \"\$mok_key\" --cert \"\$mok_cert\" --output \"\$efi_path/\$efi_binary\" \"\$efi_path/\$efi_binary\" || { echo \"Failed to sign \$efi_binary\"; exit 1; }
        done
    "
}



# Function to create boot entries for both subvolumes within arch-chroot
create_boot_entries() {
    for root in "a" "b"; do
        sudo arch-chroot "$WORKDIR" bash -c "cat <<EOF > /boot/loader/entries/shani-${root}.conf
title Shani OS - deployment (Root ${root^^})
linux /boot/vmlinuz-linux
initrd /boot/amd-ucode.img
initrd /boot/intel-ucode.img
initrd /boot/initramfs-linux.img
options \$( [[ \"\$OSI_USE_ENCRYPTION\" -eq 1 ]] && \
    echo \"rd.auto=0 rd.luks.name=\$ROOTLABEL=\$ROOTLABEL root=/dev/mapper/\$ROOTLABEL rw rootflags=subvol=/deployment/shared/root${root}\" || \
    echo \"root=/dev/disk/by-label/\$ROOTLABEL ro rootflags=subvol=/deployment/shared/root${root}\")
EOF"
    done
}

# Function to set up /etc/fstab in the chroot environment
setup_fstab() {
    echo "Setting up /etc/fstab in chroot..."
    
    # Use arch-chroot to execute commands within the chroot environment
    sudo arch-chroot "$WORKDIR" /bin/bash <<EOF
cat <<EOL > /etc/fstab
LABEL=$ROOTLABEL                /home         btrfs   defaults,noatime,compress=zstd,subvol=deployment/shared/home  0 0
LABEL=$ROOTLABEL                /roota        btrfs   defaults,noatime,compress=zstd,subvol=deployment/shared/roota  0 0
LABEL=$ROOTLABEL                /rootb        btrfs   defaults,noatime,compress=zstd,subvol=deployment/shared/rootb  0 0
LABEL=$ROOTLABEL                /var/lib/flatpak btrfs   defaults,noatime,compress=zstd,subvol=deployment/shared/flatpak  0 0
# Overlay Filesystem
overlay                         /etc          overlay  lowerdir=/mnt/deployment/shared/etc-writable,upperdir=/deployment/overlay/upper,workdir=/deployment/overlay/work  0 0
# EFI Boot Partition
LABEL=$BOOTLABEL                /boot         vfat    defaults,noatime                                 0 0
# Temporary filesystems
tmpfs                           /var/tmp      tmpfs   defaults,noatime                                 0 0
tmpfs                           /var/log      tmpfs   defaults,noatime                                 0 0
tmpfs                           /run          tmpfs   defaults,noatime                                 0 0
# Btrfs swapfile
/swapfile                      swap          swap    defaults                                         0 0
EOL
EOF

    # Check if the command was successful
    [[ $? -ne 0 ]] && quit_on_err 'Failed to set up /etc/fstab in chroot.'
}


# Main execution flow
check_sudo
check_env_vars
copy_overlay
sudo arch-chroot "$WORKDIR" dconf update || quit_on_err 'Failed to update dconf'
# Function calls in sequence
enable_systemd_homed
setup_locale
setup_timezone
setup_user
setup_hostname
setup_machine_id
setup_services
configure_ssh
setup_autologin 
install_software
setup_firewall
setup_plymouth
enable_gdm
create_dracut_config
create_initramfs  # Create the initramfs images
install_bootloader  # Call the bootloader installation function
setup_fstab  # Setup fstab for mounting

echo "Configuration completed successfully!"

