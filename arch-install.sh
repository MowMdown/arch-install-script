#!/usr/bin/env bash
set -euo pipefail

RED="\033[0;31m"
YELLOW="\033[0;33m"
GREEN="\033[0;32m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
success() { echo -e "${GREEN}[ OK ]${RESET} $*"; }

choose_disk() {
    while true; do
        info "Available disks:"
        lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1 | sed '/^$/d'
        read -rp $'\033[0;32mEnter the line number of the disk to use (will be wiped): \033[0m' line

        if ! [[ "$line" =~ ^[0-9]+$ ]]; then
            error "Input must be a number."
            continue
        fi

        disk=$(lsblk -dpno NAME | sed -n "${line}p")
        if [[ -n "$disk" ]]; then
            success "Selected disk: $disk"
            break
        else
            warn "Invalid selection. Please choose a valid line number."
        fi
    done
}

cleanup_disk() {
    info "Unmounting /mnt before proceeding..."
    if mountpoint -q /mnt; then
        warn "/mnt is currently mounted, unmounting..."
        umount -R /mnt || true
        sleep 2
    else
        info "/mnt is not mounted, nothing to do."
    fi

    info "Checking for swap partitions on $disk..."
    for part in $(lsblk -lnpo NAME "$disk"); do
        [[ "$part" == "$disk" ]] && continue
        if lsblk -no MOUNTPOINT "$part" | grep -q '\[SWAP\]'; then
            warn "$part is a swap partition, turning off swap..."
            swapoff "$part" || true
        fi
    done
}

set_swap() {
    echo
    read -rp $'\033[0;32mDo you want to enable swap? (y/N): \033[0m' use_swap_raw

    if [[ "${use_swap_raw,,}" == "y" ]]; then
        use_swap="yes"
        while true; do
            read -rp $'\033[0;32mEnter the swap size in GiB (whole numbers only): \033[0m' mem_gib
            if [[ "$mem_gib" =~ ^[0-9]+$ ]] && [ "$mem_gib" -gt 0 ]; then
                break
            else
                error "Invalid input. Please enter a positive whole number."
            fi
        done
        success "Swap will be set to ${mem_gib} GiB."
    else
        use_swap="no"
        info "Swap will not be enabled."
    fi
}

partition_disk() {
    info "Wiping partition table and signatures on $disk..."
    sgdisk --zap-all "$disk" || true
    wipefs -a "$disk" || true

    info "Creating partitions with sgdisk..."
    sgdisk -n 1:0:2G -t1:EF00 "$disk"
    part1="${disk}1"

    if [[ "$use_swap" == "yes" ]]; then
        sgdisk -n 2:0:"+${mem_gib}G" -t2:8200 "$disk"
        part2="${disk}2"
        sgdisk -n 3:0:0 -t3:8300 "$disk"
        part3="${disk}3"
        btrfs_part="$part3"
    else
        sgdisk -n 2:0:0 -t2:8300 "$disk"
        part2="${disk}2"
        btrfs_part="$part2"
    fi

    partprobe "$disk" || true
    sleep 1
}

format_partitions() {
    info "Formatting EFI partition..."
    mkfs.fat -F32 -n EFI "$part1"

    if [[ "$use_swap" == "yes" ]]; then
        info "Creating swap..."
        mkswap -L SWAP "$part2"
        swapon "$part2"
    fi

    info "Formatting Btrfs partition..."
    mkfs.btrfs -f -L ARCH "$btrfs_part"
}

subvolumes() {
    mount -o subvolid=5 "$btrfs_part" /mnt

    for sv in @ @home @cache @tmp @log @snapshots; do
        info "Creating subvolume $sv..."
        btrfs subvolume create "/mnt/$sv"
    done

    sync
    umount -R /mnt
    sleep 2

    info "Mounting root subvolume..."
    mount -o compress=zstd,noatime,subvol=@ "$btrfs_part" /mnt

    mkdir -p /mnt/{home,var/cache/pacman/pkg,var/tmp,var/log,.snapshots}
    info "Mounting subvolumes..."
    mount -o compress=zstd,noatime,subvol=@home "$btrfs_part" /mnt/home
    mount -o compress=zstd,noatime,subvol=@cache "$btrfs_part" /mnt/var/cache/pacman/pkg
    mount -o compress=zstd,noatime,subvol=@tmp "$btrfs_part" /mnt/var/tmp
    mount -o compress=zstd,noatime,subvol=@log "$btrfs_part" /mnt/var/log
    mount -o compress=zstd,noatime,subvol=@snapshots "$btrfs_part" /mnt/.snapshots

    mkdir -p /mnt/boot
    mount "$part1" /mnt/boot
}

run_pacstrap() {
    microcode_pkg=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}' | \
        sed -e 's/^GenuineIntel$/intel-ucode/' -e 's/^AuthenticAMD$/amd-ucode/')

    [[ -z "$microcode_pkg" ]] && microcode_pkg="intel-ucode amd-ucode"

    base_pkgs="base base-devel linux linux-firmware sof-firmware limine sudo nano git networkmanager btrfs-progs reflector zram-generator $microcode_pkg"

    info "Any extra packages to install with pacstrap? (space-separated, or leave empty):"
    read -r extra_packages

    [[ -n "${extra_packages// }" ]] && base_pkgs="$base_pkgs $extra_packages"

    info "Installing packages: $base_pkgs"
    pacstrap -K /mnt $base_pkgs
    success "Package installation complete."
}

configure_locale_timezone() {
    while true; do
        read -rp $'\033[0;32mEnter your locale (e.g., en_US): \033[0m' user_locale
        if [[ "$user_locale" =~ ^[a-zA-Z]{2}_[a-zA-Z]{2}$ ]]; then
            full_locale="${user_locale}.UTF-8"
            if grep -qxF "$full_locale UTF-8" /usr/share/i18n/SUPPORTED; then
                success "Selected locale: $full_locale"
                break
            else
                warn "Locale $full_locale UTF-8 is not supported."
            fi
        else
            error "Invalid format. Example: en_US"
        fi
    done

    if grep -q "^#\s*${full_locale} UTF-8" /etc/locale.gen; then
        sed -i "s|^#\s*\(${full_locale} UTF-8.*\)|\1|" /etc/locale.gen
        info "Uncommented $full_locale in /etc/locale.gen"
    elif ! grep -q "^${full_locale} UTF-8" /etc/locale.gen; then
        echo "${full_locale} UTF-8" >> /etc/locale.gen
        info "Added $full_locale to /etc/locale.gen"
    fi

    locale-gen
    echo "LANG=${full_locale}" > /etc/locale.conf
    export LANG="$full_locale"
    info "Locale set to $full_locale"

    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname

    while true; do
        read -rp $'\033[0;32mEnter your timezone (e.g., America/New_York, Europe/London): \033[0m' timezone
        if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
            ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
            hwclock --systohc
            success "Timezone set to $timezone"
            break
        else
            error "Invalid timezone. Make sure it exists in /usr/share/zoneinfo."
        fi
    done
}

user_setup() {
    while true; do
        read -s -rp $'\033[0;32mEnter new root password: \033[0m' root_pass
        echo
        read -s -rp $'\033[0;32mConfirm root password: \033[0m' root_pass_confirm
        echo
        if [ "$root_pass" = "$root_pass_confirm" ]; then
            echo "root:$root_pass" | chpasswd
            success "Root password set successfully."
            break
        else
            error "Passwords do not match. Try again."
        fi
    done

    read -rp $'\033[0;32mEnter username for new user: \033[0m' username
    while true; do
        read -s -rp $'\033[0;32mEnter password for user '"$username"': \033[0m' user_pass
        echo
        read -s -rp $'\033[0;32mConfirm password for user '"$username"': \033[0m' user_pass_confirm
        echo
        if [ "$user_pass" = "$user_pass_confirm" ]; then
            useradd -m -G wheel -s /bin/bash "$username"
            echo "$username:$user_pass" | chpasswd
            success "User '$username' created and added to wheel group."
            break
        else
            error "Passwords do not match. Try again."
        fi
    done
}

install_gpu_drivers() {
    while true; do
        info "Is this system a:"
        echo "  1) Desktop"
        echo "  2) Laptop"
        read -rp $'\033[0;32mEnter 1 or 2: \033[0m' gpu_line

        if ! [[ "$gpu_line" =~ ^[0-9]+$ ]]; then
            error "Input must be a number."
            continue
        fi

        if [[ "$gpu_line" -eq 1 ]]; then
            system_type="Desktop"
            success "Desktop selected."
            break
        elif [[ "$gpu_line" -eq 2 ]]; then
            system_type="Laptop"
            success "Laptop selected."
            break
        else
            warn "Invalid selection. Please enter 1 or 2."
        fi
    done

    info "Detecting GPUs..."
    gpu_list=$(lspci -nnk | grep -i "VGA\|3D")
    echo "$gpu_list"
    echo

    has_amd=$(echo "$gpu_list" | grep -qi "AMD"; echo $?)
    has_nvidia=$(echo "$gpu_list" | grep -qi "NVIDIA"; echo $?)
    has_intel=$(echo "$gpu_list" | grep -qi "Intel"; echo $?)

    if [[ $has_amd -ne 0 && $has_nvidia -ne 0 && $has_intel -ne 0 ]]; then
        warn "No supported GPU detected (AMD, NVIDIA, Intel). Skipping GPU driver installation."
        return 0
    fi

    info "Detected GPUs:"
    [[ $has_amd -eq 0 ]] && echo "  - AMD GPU detected"
    [[ $has_nvidia -eq 0 ]] && echo "  - NVIDIA GPU detected"
    [[ $has_intel -eq 0 ]] && echo "  - Intel GPU detected"
    echo

    info "Installing appropriate drivers..."
    amd_pkgs="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader"
    nvidia_pkgs="nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils"
    intel_pkgs="mesa lib32-mesa vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader"

    if [[ "$system_type" == "Desktop" ]]; then
        [[ $has_amd -eq 0 ]] && pacman -S --needed $amd_pkgs
        [[ $has_nvidia -eq 0 ]] && pacman -S --needed $nvidia_pkgs
        [[ $has_intel -eq 0 ]] && pacman -S --needed $intel_pkgs
    fi

    if [[ "$system_type" == "Laptop" ]]; then
        if [[ $has_intel -eq 0 && $has_nvidia -eq 0 ]]; then
            info "Intel + NVIDIA hybrid laptop detected (Optimus)."
            pacman -S --needed $intel_pkgs $nvidia_pkgs nvidia-prime
        elif [[ $has_amd -eq 0 && $has_nvidia -eq 0 ]]; then
            info "AMD + NVIDIA hybrid laptop detected."
            pacman -S --needed $amd_pkgs $nvidia_pkgs nvidia-prime
        elif [[ $has_intel -eq 0 && $has_nvidia -ne 0 && $has_amd -ne 0 ]]; then
            info "Intel-only laptop detected."
            pacman -S --needed $intel_pkgs
        elif [[ $has_amd -eq 0 && $has_nvidia -ne 0 && $has_intel -ne 0 ]]; then
            info "AMD-only laptop detected."
            pacman -S --needed $amd_pkgs
        fi
    fi

    success "GPU driver installation complete."
}

chroot_setup() {
    sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/ { s/^[[:space:]]*#//; n; s/^[[:space:]]*#// }' /etc/pacman.conf
    pacman -Syu --noconfirm

    read -rp $'\033[0;32mInstall KDE Plasma desktop packages? (y/N) \033[0m' install_desktop_pkgs
    if [[ "${install_desktop_pkgs,,}" == "y" ]]; then
        pacman -S --noconfirm plasma-meta sddm dolphin konsole firefox
        systemctl enable sddm.service
    fi

    read -rp $'\033[0;32mDo you want to install GPU drivers? (y/N) \033[0m' install_gpu_driver_pkgs
    if [[ "${install_gpu_driver_pkgs,,}" == "y" ]]; then
        install_gpu_drivers
    else
        info "Skipping GPU driver package installation..."
    fi

    configure_locale_timezone
    user_setup

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    systemctl enable fstrim.timer NetworkManager.service reflector.service

    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    success "Post-chroot configuration complete!"
    sleep 1
}

finalize_install() {
    info "Generating /etc/fstab..."
    genfstab -L /mnt > /mnt/etc/fstab

    info "Copying script into new root..."
    mkdir -p /mnt/root
    cp -- "$0" /mnt/root/arch-install.sh
    chmod +x /mnt/root/arch-install.sh

    read -rp $'\033[0;32mSkip chroot? (y/N): \033[0m' skip_chroot
    if [[ "$skip_chroot" == "y" || "$skip_chroot" == "Y" ]]; then
        info "Exiting. System is mounted at /mnt."
        exit 0
    else
        arch-chroot /mnt /bin/bash -c "$(declare -f chroot_setup configure_locale_timezone user_setup install_gpu_drivers); chroot_setup"

        info "Adding EFI Bootloader Entry"
        efibootmgr --create --disk "$disk" --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode

        read -rp $'\033[0;32mReboot system now? (y/N): \033[0m' reboot_answer
        if [[ "${reboot_answer,,}" == "y" ]]; then
            umount -R /mnt
            sleep 2
            reboot
        fi
    fi
}

main() {
    [[ $EUID -eq 0 ]] || { error "Must be run as root."; exit 1; }
    warn "WARNING: This WILL DESTROY ALL DATA on the selected disk."
    read -rp $'\033[0;32mProceed with installation? (y/N): \033[0m' answer
    [[ "${answer,,}" == "y" ]] || { info "Aborted."; exit 1; }

    choose_disk
    cleanup_disk
    set_swap
    partition_disk
    format_partitions
    subvolumes
    run_pacstrap
    finalize_install
}

main "$@"
