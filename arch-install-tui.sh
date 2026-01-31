#!/bin/bash
set -uo pipefail

# Dialog configuration
pacman -Sq --needed --noconfirm dialog

DIALOG_OK=0
DIALOG_CANCEL=1
DIALOG_ESC=255
HEIGHT=20
WIDTH=70

# Configuration variables
declare -g disk=""
declare -g use_swap="no"
declare -g mem_gib=0
declare -g part1=""
declare -g part2=""
declare -g part3=""
declare -g btrfs_part=""
declare -g user_locale=""
declare -g full_locale=""
declare -g timezone=""
declare -g hostname=""
declare -g username=""
declare -g root_pass=""
declare -g user_pass=""
declare -g install_desktop="no"
declare -g install_gpu="no"
declare -g system_type=""
declare -g extra_packages=""
declare -g REFLECTOR_PID=""
declare -g REFLECTOR_STATUS=0

# Dialog helper functions
dialog_msgbox() {
    dialog --title "$1" --msgbox "$2" $HEIGHT $WIDTH
}

dialog_yesno() {
    dialog --title "$1" --yesno "$2" $HEIGHT $WIDTH
}

dialog_infobox() {
    dialog --title "$1" --infobox "$2" 10 $WIDTH
    sleep 2
}

# Execute command and show output in dialog
exec_with_progress() {
    local title="$1"
    local message="$2"
    shift 2
    local cmd="$@"
    
    local tmpfile=$(mktemp)
    
    (
        eval "$cmd" > "$tmpfile" 2>&1
        echo $? > "${tmpfile}.exit"
    ) &
    
    local pid=$!
    
    # Show spinning progress
    while kill -0 $pid 2>/dev/null; do
        dialog --title "$title" --infobox "$message\n\nPlease wait..." 10 $WIDTH
        sleep 1
    done
    
    wait $pid
    local exit_code=$(cat "${tmpfile}.exit" 2>/dev/null || echo 1)
    
    if [ $exit_code -eq 0 ]; then
        dialog_infobox "$title" "✓ $message - Complete"
    else
        local output=$(cat "$tmpfile")
        dialog --title "$title - Error" --msgbox "Operation failed:\n\n$output" $HEIGHT $WIDTH
    fi
    
    rm -f "$tmpfile" "${tmpfile}.exit"
    return $exit_code
}


# CONFIGURATION PHASE - Collect all settings upfront
config_choose_disk() {
    local disk_list=""
    local line_num=1
    
    # Build disk list for dialog menu
    while IFS= read -r line; do
        local disk_name=$(echo "$line" | awk '{print $1}')
        local disk_size=$(echo "$line" | awk '{print $2}')
        local disk_model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
        disk_list+="$line_num \"$disk_name - $disk_size - $disk_model\" "
        ((line_num++))
    done < <(lsblk -dpno NAME,SIZE,MODEL | sed '/^$/d')
    
    while true; do
        local selection
        selection=$(eval dialog --title \"Disk Selection\" \
            --menu \"!!!  WARNING: Selected disk will be COMPLETELY WIPED!\\n\\nChoose installation disk:\" \
            $HEIGHT $WIDTH 10 $disk_list \
            2>&1 >/dev/tty)
        
        local ret=$?
        if [ $ret -ne $DIALOG_OK ]; then
            return 1
        fi
        
        disk=$(lsblk -dpno NAME | sed -n "${selection}p")
        
        if [ -n "$disk" ]; then
            if dialog_yesno "Confirm Disk Selection" \
                "Selected disk: $disk\n\n!!!  ALL DATA WILL BE DESTROYED!\n\nContinue with this disk?"; then
                return 0
            fi
        else
            dialog_msgbox "Error" "Invalid disk selection. Please try again."
        fi
    done
}

config_set_swap() {
    if dialog_yesno "Swap Configuration" "Do you want to enable a swap partition?"; then
        use_swap="yes"
        
        while true; do
            mem_gib=$(dialog --title "Swap Size" \
                --inputbox "Enter swap size in GB (whole numbers):" \
                $HEIGHT $WIDTH "" 2>&1 >/dev/tty)
            
            if [ $? -ne $DIALOG_OK ]; then
                use_swap="no"
                return 0
            fi
            
            if [[ "$mem_gib" =~ ^[0-9]+$ ]] && [ "$mem_gib" -gt 0 ]; then
                return 0
            else
                dialog_msgbox "Invalid Input" "Please enter a positive whole number."
            fi
        done
    else
        use_swap="no"
    fi
}

config_locale_tz_hostname() {
    # Locale selection
    while true; do
        user_locale=$(dialog --title "Locale Configuration" \
            --inputbox "Enter locale (e.g., en_US, de_DE, fr_FR):" \
            $HEIGHT $WIDTH "en_US" 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        if [[ "$user_locale" =~ ^[a-zA-Z]{2}_[a-zA-Z]{2}$ ]]; then
            full_locale="${user_locale}.UTF-8"
            if grep -qxF "$full_locale UTF-8" /usr/share/i18n/SUPPORTED; then
                break
            else
                dialog_msgbox "Error" "Locale '$user_locale' is not supported."
            fi
        else
            dialog_msgbox "Error" "Invalid format. Use format like: en_US"
        fi
    done
    
    # Timezone selection
    while true; do
        timezone=$(dialog --title "Timezone Configuration" \
            --inputbox "Enter timezone (e.g., America/New_York, Europe/London):" \
            $HEIGHT $WIDTH "America/New_York" 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
            break
        else
            dialog_msgbox "Error" "Invalid timezone: $timezone"
        fi
    done

    # Hostname
    while true; do
        hostname=$(dialog --title "Hostname Configuration" \
            --inputbox "Enter a machine hostname (e.g., archlinux):" \
            $HEIGHT $WIDTH "archlinux" 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        if [ -n "$hostname" ]; then
            break
        else
            dialog_msgbox "Error" "Username cannot be empty."
        fi
    done
}

config_users() {
    # Root password
    while true; do
        root_pass=$(dialog --title "Root Password" \
            --insecure --passwordbox "Enter root password:" \
            $HEIGHT $WIDTH 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        local root_pass_confirm
        root_pass_confirm=$(dialog --title "Root Password" \
            --insecure --passwordbox "Confirm root password:" \
            $HEIGHT $WIDTH 2>&1 >/dev/tty)
        
        if [ "$root_pass" = "$root_pass_confirm" ]; then
            break
        else
            dialog_msgbox "Error" "Passwords do not match. Please try again."
        fi
    done
    
    # Username
    while true; do
        username=$(dialog --title "User Account" \
            --inputbox "Enter username for new user:" \
            $HEIGHT $WIDTH "" 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        if [ -n "$username" ]; then
            break
        else
            dialog_msgbox "Error" "Username cannot be empty."
        fi
    done
    
    # User password
    while true; do
        user_pass=$(dialog --title "User Password" \
            --insecure --passwordbox "Password for '$username':" \
            $HEIGHT $WIDTH 2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            return 1
        fi
        
        local user_pass_confirm
        user_pass_confirm=$(dialog --title "User Password" \
            --insecure --passwordbox "Confirm password:" \
            $HEIGHT $WIDTH 2>&1 >/dev/tty)
        
        if [ "$user_pass" = "$user_pass_confirm" ]; then
            return 0
        else
            dialog_msgbox "Error" "Passwords do not match. Please try again."
        fi
    done
}

config_packages() {
    local microcode_pkg=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}' | \
        sed -e 's/^GenuineIntel$/intel-ucode/' -e 's/^AuthenticAMD$/amd-ucode/')
    
    if [[ -z "$microcode_pkg" ]]; then
        microcode_pkg="intel-ucode amd-ucode"
    fi
    
    local base_pkgs="base base-devel linux linux-firmware sof-firmware limine sudo nano git networkmanager btrfs-progs reflector zram-generator $microcode_pkg"
    
    local pkg_display=$(echo "$base_pkgs" | sed 's/ /\n/g' | pr -t -3)
    
    extra_packages=$(dialog --title "Package Selection" \
        --inputbox "Base packages:\n\n$pkg_display\n\nAdd packages (space-separated) or remove with '!package':" \
        25 $WIDTH "" 2>&1 >/dev/tty)
    
    if [ $? -ne $DIALOG_OK ]; then
        extra_packages=""
    fi
}

config_desktop() {
    if dialog_yesno "Desktop Environment" "Install KDE Plasma desktop environment?\n\nThis includes: plasma-meta, sddm, dolphin, konsole, firefox"; then
        install_desktop="yes"
    else
        install_desktop="no"
    fi
}

config_gpu() {
    if dialog_yesno "GPU Drivers" "Install GPU drivers?\n\nDrivers will be auto-detected based on your hardware."; then
        install_gpu="yes"
        
        # Ask for system type
        system_type=$(dialog --title "System Type" \
            --menu "Select your system type:" \
            $HEIGHT $WIDTH 2 \
            1 "Desktop" \
            2 "Laptop" \
            2>&1 >/dev/tty)
        
        if [ $? -ne $DIALOG_OK ]; then
            install_gpu="no"
            return 0
        fi
        
        if [[ "$system_type" -eq 1 ]]; then
            system_type="Desktop"
        else
            system_type="Laptop"
        fi
    else
        install_gpu="no"
    fi
}

show_summary() {
    local swap_info="Disabled"
    if [ "$use_swap" = "yes" ]; then
        swap_info="Enabled (${mem_gib} GiB)"
    fi
    
    local desktop_info="No"
    if [ "$install_desktop" = "yes" ]; then
        desktop_info="Yes (KDE Plasma)"
    fi
    
    local gpu_info="No"
    if [ "$install_gpu" = "yes" ]; then
        gpu_info="Yes ($system_type)"
    fi
    
    local extra_info="None"
    if [ -n "$extra_packages" ]; then
        extra_info="$extra_packages"
    fi
    
    local summary="INSTALLATION CONFIGURATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DISK & PARTITIONS:
  Target Disk: $disk
  Swap: $swap_info

SYSTEM CONFIGURATION:
  Locale: $full_locale
  Timezone: $timezone
  Hostname: $hostname

USER ACCOUNTS:
  Root: Password set
  User: $username (Password set)

SOFTWARE:
  Desktop Environment: $desktop_info
  GPU Drivers: $gpu_info
  Extra Packages: $extra_info

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

!!!  WARNING: This will DESTROY all data on $disk!
"
    
    dialog --title "Configuration Summary" \
        --yes-label "Begin Installation" \
        --no-label "Modify Settings" \
        --yesno "$summary" 30 $WIDTH
}


# EXECUTION PHASE - Apply configuration to disk
cleanup_disk() {
    dialog_infobox "Cleaning Up" "Unmounting /mnt/arch and disabling swap..."
    
    if mountpoint -q /mnt/arch 2>/dev/null; then
        umount -R /mnt/arch 2>/dev/null || true
        sleep 1
    fi
    
    for part in $(lsblk -lnpo NAME "$disk" 2>/dev/null); do
        if [[ "$part" == "$disk" ]]; then continue; fi
        if lsblk -no MOUNTPOINT "$part" 2>/dev/null | grep -q '\[SWAP\]'; then
            swapoff "$part" 2>/dev/null || true
        fi
    done
}

check_nvme_4kn() {
    if [[ "$disk" != /dev/nvme*n* ]]; then
        return 0
    fi
    
    if ! dialog_yesno "NVMe 4Kn Format" \
        "This disk is an NVMe drive.\n\nDo you want to check for 4Kn formatting support?\n\nNote: This is optional and only needed for advanced users."; then
        return 0
    fi
    
    dialog_infobox "Checking NVMe" "Querying NVMe namespace formats..."
    
    local ns_info=$(nvme id-ns -H "$disk" 2>/dev/null) || {
        dialog_msgbox "NVMe Check" "Failed to query NVMe info. Continuing without 4Kn format."
        return 0
    }
    
    local current_lbaf=$(echo "$ns_info" | awk '/in use/ {print $NF}')
    local lba1_line=$(echo "$ns_info" | grep "LBA Format  1" || true)
    
    [[ -z "$lba1_line" ]] && {
        dialog_msgbox "NVMe Format" "LBA Format 1 not supported. Skipping 4Kn format."
        return 0
    }
    
    local data_size=$(echo "$lba1_line" | sed -n 's/.*Data Size: *\([0-9]\+\) bytes.*/\1/p')
    
    [[ "$data_size" != "4096" ]] && {
        dialog_msgbox "NVMe Format" "4Kn format not available. Skipping."
        return 0
    }
    
    [[ "$current_lbaf" == "1" ]] && {
        dialog_msgbox "NVMe Format" "NVMe already using 4Kn format."
        return 0
    }
    
    if dialog_yesno "Format to 4Kn" \
        "!!!  WARNING: Formatting to 4Kn will ERASE ALL DATA!\n\nNVMe supports 4096-byte logical blocks.\n\nProceed with format?"; then
        exec_with_progress "NVMe Format" "Formatting NVMe to 4Kn" \
            "nvme format --lbaf=1 '$disk' && blockdev --rereadpt '$disk' && partprobe '$disk'"
        dialog_msgbox "Format Complete" "NVMe formatted to 4Kn successfully."
    fi
}

partition_disk() {
    exec_with_progress "Partitioning" "Wiping partition table" \
        "sgdisk --zap-all '$disk' && wipefs -a '$disk'"
    
    exec_with_progress "Partitioning" "Creating EFI partition (4GB)" \
        "sgdisk -n 1:0:4G -I -t1:EF00 '$disk'"
    part1="${disk}1"
    
    if [[ "$use_swap" == "yes" ]]; then
        exec_with_progress "Partitioning" "Creating swap partition (${mem_gib}GB)" \
            "sgdisk -n 2:0:+${mem_gib}G -I -t2:8200 '$disk'"
        part2="${disk}2"
        
        exec_with_progress "Partitioning" "Creating root partition (remaining space)" \
            "sgdisk -n 3:0:0 -I -t3:8300 '$disk'"
        part3="${disk}3"
        btrfs_part="$part3"
    else
        exec_with_progress "Partitioning" "Creating root partition (remaining space)" \
            "sgdisk -n 2:0:0 -I -t2:8300 '$disk'"
        part2="${disk}2"
        btrfs_part="$part2"
    fi
    
    exec_with_progress "Partitioning" "Updating partition table" \
        "partprobe '$disk' && sleep 1"
    
    dialog_msgbox "Partitioning Complete" "Disk partitioning finished successfully."
}

format_partitions() {
    exec_with_progress "Formatting" "Formatting EFI partition" \
        "mkfs.fat -F 32 -n EFI '$part1'"
    
    if [[ "$use_swap" == "yes" ]]; then
        exec_with_progress "Formatting" "Formatting and enabling swap" \
            "mkswap -L SWAP '$part2' && swapon '$part2'"
    fi
    
    exec_with_progress "Formatting" "Formatting Btrfs root partition" \
        "mkfs.btrfs -f -L ARCH -n 32k '$btrfs_part'"
    
    dialog_msgbox "Formatting Complete" "All partitions formatted successfully."
}

create_subvolumes() {
    local base_opts="noatime,compress=zstd:3,discard=async,ssd,space_cache=v2"
    
    dialog_infobox "Btrfs Setup" "Creating Btrfs subvolumes..."
    
    mkdir -p /mnt/arch
    mount -o "${base_opts},subvolid=5" "$btrfs_part" /mnt/arch
    
    btrfs subvolume create "/mnt/arch/@"
    btrfs subvolume create "/mnt/arch/@home"
    btrfs subvolume create "/mnt/arch/@cache"
    btrfs subvolume create "/mnt/arch/@tmp"
    btrfs subvolume create "/mnt/arch/@log"
    btrfs subvolume create "/mnt/arch/@snapshots"
    
    umount -R /mnt/arch
    sleep 1
    
    dialog_infobox "Btrfs Setup" "Mounting Btrfs subvolumes..."
    
    # Mount @ to /mnt/arch
    mount -o "${base_opts},subvol=@" "$btrfs_part" /mnt/arch
    
    # Create and mount other subvolumes
    mkdir -p /mnt/arch/home
    mount -o "${base_opts},subvol=@home" "$btrfs_part" /mnt/arch/home
    
    mkdir -p /mnt/arch/var/cache/pacman/pkg
    mount -o "${base_opts},subvol=@cache" "$btrfs_part" /mnt/arch/var/cache/pacman/pkg
    
    mkdir -p /mnt/arch/var/tmp
    mount -o "${base_opts},subvol=@tmp" "$btrfs_part" /mnt/arch/var/tmp
    
    mkdir -p /mnt/arch/var/log
    mount -o "${base_opts},subvol=@log" "$btrfs_part" /mnt/arch/var/log
    
    mkdir -p /mnt/arch/.snapshots
    mount -o "${base_opts},subvol=@snapshots" "$btrfs_part" /mnt/arch/.snapshots
    
    dialog_infobox "Btrfs Setup" "Mounting EFI partition..."
    mkdir -p /mnt/arch/boot
    mount "$part1" /mnt/arch/boot
    
    dialog_msgbox "Btrfs Setup Complete" "Subvolumes created and mounted successfully."
}

install_packages() {
    local microcode_pkg=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}' | \
        sed -e 's/^GenuineIntel$/intel-ucode/' -e 's/^AuthenticAMD$/amd-ucode/')
    
    if [[ -z "$microcode_pkg" ]]; then
        microcode_pkg="intel-ucode amd-ucode"
    fi
    
    local base_pkgs="base base-devel linux linux-firmware sof-firmware limine sudo nano git networkmanager btrfs-progs reflector zram-generator $microcode_pkg"
    
    # Process extra packages
    if [[ -n "${extra_packages// }" ]]; then
        local removals=()
        local additions=()
        for token in $extra_packages; do
            if [[ "$token" == !* ]]; then
                removals+=("${token#!}")
            else
                additions+=("$token")
            fi
        done
        
        if [[ ${#removals[@]} -gt 0 ]]; then
            local filtered=()
            for pkg in $base_pkgs; do
                local skip=false
                for rm in "${removals[@]}"; do
                    if [[ "$pkg" == "$rm" ]]; then
                        skip=true
                        break
                    fi
                done
                $skip || filtered+=("$pkg")
            done
            base_pkgs="${filtered[*]}"
        fi
        
        if [[ ${#additions[@]} -gt 0 ]]; then
            base_pkgs="$base_pkgs ${additions[*]}"
        fi
    fi
    
    dialog_infobox "Preparing" "Waiting for mirror list update..."
    wait $REFLECTOR_PID 2>/dev/null || true
    REFLECTOR_STATUS=$?
    
    # Create a temporary file for pacstrap output
    local tmpfile=$(mktemp)
    
    dialog --title "Installing Packages" \
        --msgbox "Installing base system packages.\n\nThis will take several minutes.\nPress OK to begin..." \
        $HEIGHT $WIDTH
    
    # Run pacstrap with output to dialog
    (
        pacstrap -K /mnt/arch $base_pkgs 2>&1 | tee "$tmpfile"
        echo ${PIPESTATUS[0]} > "${tmpfile}.exit"
    ) | dialog --title "Installing Packages" \
        --programbox "Installing: $base_pkgs" 30 $WIDTH
    
    local exit_code=$(cat "${tmpfile}.exit" 2>/dev/null || echo 1)
    
    if [ $exit_code -eq 0 ]; then
        dialog_msgbox "Installation Complete" "Base packages installed successfully."
    else
        dialog --title "Installation Error" \
            --msgbox "Package installation failed. Check the output for errors." \
            $HEIGHT $WIDTH
        rm -f "$tmpfile" "${tmpfile}.exit"
        return 1
    fi
    
    if [[ $REFLECTOR_STATUS -ne 0 ]]; then
        cp --dereference /etc/pacman.d/mirrorlist /mnt/arch/etc/pacman.d/mirrorlist 2>/dev/null || true
    fi
    
    rm -f "$tmpfile" "${tmpfile}.exit"
}

configure_system() {
    dialog_infobox "Configuring" "Generating fstab..."
    genfstab -L /mnt/arch > /mnt/arch/etc/fstab
    
    dialog_infobox "Configuring" "Setting locale..."
    if grep -q "^#\s*${full_locale} UTF-8" /mnt/arch/etc/locale.gen; then
        sed -i "s|^#\s*\(${full_locale} UTF-8.*\)|\1|" /mnt/arch/etc/locale.gen
    elif ! grep -q "^${full_locale} UTF-8" /mnt/arch/etc/locale.gen; then
        echo "${full_locale} UTF-8" >> /mnt/arch/etc/locale.gen
    fi
    
    arch-chroot /mnt/arch locale-gen > /dev/null 2>&1
    echo "LANG=${full_locale}" > /mnt/arch/etc/locale.conf
    echo "KEYMAP=us" > /mnt/arch/etc/vconsole.conf
    echo "${hostname}" > /mnt/arch/etc/hostname
    
    dialog_infobox "Configuring" "Setting timezone..."
    arch-chroot /mnt/arch ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    arch-chroot /mnt/arch hwclock --systohc
    
    dialog_infobox "Configuring" "Setting up users..."
    echo "root:$root_pass" | arch-chroot /mnt/arch chpasswd
    arch-chroot /mnt/arch useradd -m -G wheel -s /bin/bash "$username"
    echo "$username:$user_pass" | arch-chroot /mnt/arch chpasswd
    
    dialog_infobox "Configuring" "Enabling sudo for wheel group..."
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/arch/etc/sudoers
    
    dialog_msgbox "System Configuration" "Base system configured successfully."
}

install_desktop_environment() {
    if [ "$install_desktop" != "yes" ]; then
        return 0
    fi
    
    dialog_infobox "Installing Desktop" "Enabling multilib repository..."
    sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/ { s/^[[:space:]]*#//; n; s/^[[:space:]]*#// }' /mnt/arch/etc/pacman.conf
    
    dialog_infobox "Installing Desktop" "Updating package database..."
    arch-chroot /mnt/arch pacman -Syuq --noconfirm > /dev/null 2>&1
    
    local tmpfile=$(mktemp)
    
    dialog --title "Installing Desktop Environment" \
        --msgbox "Installing KDE Plasma desktop.\n\nThis will take several minutes.\nPress OK to begin..." \
        $HEIGHT $WIDTH
    
    (
        arch-chroot /mnt/arch pacman -Sq --needed --noconfirm plasma-meta sddm dolphin konsole firefox 2>&1 | tee "$tmpfile"
        echo ${PIPESTATUS[0]} > "${tmpfile}.exit"
    ) | dialog --title "Installing KDE Plasma" \
        --programbox "Installing desktop environment..." 30 $WIDTH
    
    local exit_code=$(cat "${tmpfile}.exit" 2>/dev/null || echo 1)
    rm -f "$tmpfile" "${tmpfile}.exit"
    
    if [ $exit_code -eq 0 ]; then
        arch-chroot /mnt/arch systemctl enable sddm.service
        dialog_msgbox "Desktop Installed" "KDE Plasma installed successfully."
    else
        dialog_msgbox "Desktop Installation" "Desktop installation encountered errors."
    fi
}

install_gpu_drivers() {
    if [ "$install_gpu" != "yes" ]; then
        return 0
    fi
    
    dialog_infobox "GPU Detection" "Detecting graphics hardware..."
    
    local gpu_list=$(lspci -d ::03xx | grep -i "VGA\|3D")
    
    local has_amd=$(echo "$gpu_list" | grep -qi "AMD"; echo $?)
    local has_nvidia=$(echo "$gpu_list" | grep -qi "NVIDIA"; echo $?)
    local has_intel=$(echo "$gpu_list" | grep -qi "Intel"; echo $?)
    
    if [[ $has_amd -ne 0 && $has_nvidia -ne 0 && $has_intel -ne 0 ]]; then
        dialog_msgbox "GPU Detection" "No supported GPU found. Skipping driver installation."
        return 0
    fi
    
    local gpu_info=""
    [[ $has_amd -eq 0 ]] && gpu_info+="• AMD GPU detected\n"
    [[ $has_nvidia -eq 0 ]] && gpu_info+="• NVIDIA GPU detected\n"
    [[ $has_intel -eq 0 ]] && gpu_info+="• Intel GPU detected\n"
    
    dialog_msgbox "GPU Detection" "Detected graphics:\n\n$gpu_info\nInstalling appropriate drivers..."
    
    local amd_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader"
    local nvidia_pkgs="nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils nvidia-prime"
    local intel_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader"
    
    local tmpfile=$(mktemp)
    
    (
        if [[ "$system_type" == "Desktop" ]]; then
            [[ $has_amd -eq 0 ]] && arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $amd_pkgs
            [[ $has_nvidia -eq 0 ]] && arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $nvidia_pkgs
            [[ $has_intel -eq 0 ]] && arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $intel_pkgs
        else
            if [[ $has_intel -eq 0 && $has_nvidia -eq 0 ]]; then
                arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $intel_pkgs $nvidia_pkgs
            elif [[ $has_amd -eq 0 && $has_nvidia -eq 0 ]]; then
                arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $amd_pkgs $nvidia_pkgs
            elif [[ $has_intel -eq 0 ]]; then
                arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $intel_pkgs
            elif [[ $has_amd -eq 0 ]]; then
                arch-chroot /mnt/arch pacman -Sq --needed --noconfirm $amd_pkgs
            fi
        fi
        echo $? > "${tmpfile}.exit"
    ) 2>&1 | dialog --title "Installing GPU Drivers" \
        --programbox "Installing graphics drivers..." 30 $WIDTH
    
    local exit_code=$(cat "${tmpfile}.exit" 2>/dev/null || echo 0)
    rm -f "$tmpfile" "${tmpfile}.exit"
    
    dialog_msgbox "GPU Drivers" "GPU driver installation complete."
}

install_bootloader() {
    dialog_infobox "Bootloader" "Installing Limine bootloader..."
    
    arch-chroot /mnt/arch mkdir -p /boot/EFI/BOOT
    arch-chroot /mnt/arch pacman -Sq --needed --noconfirm limine > /dev/null 2>&1
    arch-chroot /mnt/arch cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
    
    cat > /mnt/arch/boot/limine.conf << 'EOF'
timeout: 5
default_entry: 1

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/initramfs-linux.img
    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw
EOF
    
    dialog_infobox "Bootloader" "Configuring ZRAM..."
    cat > /mnt/arch/etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = min(ram)
compression-algorithm = zstd
EOF
    
    if grep -q "SWAP" /mnt/arch/etc/fstab; then
        arch-chroot /mnt/arch swapon -a 2>/dev/null || true
    fi
    
    dialog_infobox "Bootloader" "Enabling system services..."
    arch-chroot /mnt/arch systemctl enable fstrim.timer NetworkManager.service reflector.service
    
    local tmpfile=$(mktemp)
    
    (
        arch-chroot /mnt/arch mkinitcpio -P 2>&1 | tee "$tmpfile"
        echo ${PIPESTATUS[0]} > "${tmpfile}.exit"
    ) | dialog --title "Building Initramfs" \
        --programbox "Rebuilding initramfs..." 30 $WIDTH
    
    rm -f "$tmpfile" "${tmpfile}.exit"
    
    dialog_infobox "Bootloader" "Adding EFI boot entry..."
    efibootmgr --create --disk "$disk" --part 1 --label "Arch Linux Limine Bootloader" \
        --loader '\EFI\BOOT\BOOTX64.EFI' --unicode > /dev/null 2>&1
    
    dialog_msgbox "Bootloader Complete" "Limine bootloader installed and configured."
}


# MAIN INSTALLATION FLOW


run_configuration_wizard() {
    while true; do
        # Collect all configuration
        config_choose_disk || return 1
        config_set_swap || return 1
        config_locale_tz_hostname || return 1
        config_users || return 1
        config_packages || return 1
        config_desktop || return 1
        config_gpu || return 1
        
        # Show summary and confirm
        if show_summary; then
            return 0
        fi
        # If user chose "Modify Settings", loop back
    done
}

run_installation() {
    # Start reflector in background
    dialog_infobox "Preparing" "Updating mirror list in background..."
    reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist > /dev/null 2>&1 &
    REFLECTOR_PID=$!
    
    cleanup_disk
    check_nvme_4kn
    partition_disk
    format_partitions
    create_subvolumes
    install_packages || return 1
    configure_system
    install_desktop_environment
    install_gpu_drivers
    install_bootloader
    
    dialog_msgbox "Installation Complete!" \
        "Arch Linux has been successfully installed!\n\nThe system is ready to boot."
    
    if dialog_yesno "Reboot System" "Installation complete!\n\nReboot now?"; then
        clear
        umount -R /mnt/arch 2>/dev/null || true
        sleep 2
        reboot
    else
        dialog_msgbox "Installation Complete" \
            "System mounted at /mnt/arch\n\nYou can manually reboot when ready."
    fi
}

main() {
    # Check for root
    if [[ $EUID -ne 0 ]]; then
        dialog_msgbox "Permission Error" "This script must be run as root."
        exit 1
    fi
    
    # Check for dialog command
    if ! command -v dialog &> /dev/null; then
        echo "Installing dialog utility..."
        pacman -Sy --noconfirm dialog
    fi
    
    # Welcome screen
    if ! dialog_yesno "Arch Linux TUI Installer" \
        "Welcome to the Arch Linux TUI Installer!\n\n!!!  WARNING !!!\n\nThis installer will:\n• DESTROY ALL DATA on the selected disk\n• Partition and format the disk\n• Install Arch Linux with Btrfs\n• Configure bootloader and system\n\nYou will configure all settings upfront,\nthen review before installation begins.\n\nMake sure you have backups!\n\nProceed with installation?"; then
        clear
        echo "Installation aborted by user."
        exit 0
    fi
    
    # Run configuration wizard
    if ! run_configuration_wizard; then
        clear
        echo "Installation cancelled."
        exit 0
    fi
    
    # Run installation
    run_installation
    
    clear
}

main "$@"
