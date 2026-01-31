#!/bin/bash
set -euo pipefail

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

info()    { echo; echo -e "${GREEN}[INFO] $*${RESET}"; }
warn()    { echo; echo -e "${YELLOW}[WARN] $*${RESET}"; }
error()   { echo; echo -e "${RED}[ERROR] $*${RESET}"; }
success() { echo; echo -e "${GREEN}[ OK ] $*${RESET}"; }
section() { echo; echo -e "${CYAN}==> ${BLUE}$*${RESET}"; }
prompt()  { echo; echo -en "${BLUE}[INPUT] $*${RESET}"; }

choose_disk() {
    while true; do
        section "Available disks:"
        echo
        lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1 | sed '/^$/d'

        prompt "Enter the line number of the disk to use (will be wiped): "
        read -r line

        if ! [[ "$line" =~ ^[0-9]+$ ]]; then
            error "Input must be a number."
            continue
        fi

        disk=$(lsblk -dpno NAME | sed -n "${line}p")
        if [[ -n "$disk" ]]; then
            info "Selected disk: $disk"
            break
        else
            error "Invalid selection. Choose a valid line number."
        fi
    done
}

cleanup_disk() {
    section "Unmounting /mnt/arch before proceeding..."
    if mountpoint -q /mnt/arch; then
        warn "/mnt/arch is currently mounted, unmounting..."
        umount -R /mnt/arch || true
        sleep 2
    else
        info "/mnt/arch is not mounted."
    fi

    section "Checking for swap partitions on $disk..."
    for part in $(lsblk -lnpo NAME "$disk"); do
        if [[ "$part" == "$disk" ]]; then continue; fi

        if lsblk -no MOUNTPOINT "$part" | grep -q '\[SWAP\]'; then
            warn "$part is a swap partition, turning off swap..."
            swapoff "$part" || true
        fi
    done
}

set_swap() {
    prompt "Enable swap? (y/N): "
    read -r use_swap_raw

    if [[ "${use_swap_raw,,}" == "y" ]]; then
        use_swap="yes"
        while true; do
            prompt "Enter swap size in GiB (whole number): "
            read -r mem_gib
            if [[ "$mem_gib" =~ ^[0-9]+$ ]] && [ "$mem_gib" -gt 0 ]; then
                break
            else
                error "Enter a positive whole number..."
            fi
        done
        info "Swap will be ${mem_gib} GiB..."
    else
        use_swap="no"
        warn "Swap will NOT be enabled..."
    fi
}

nvme_4kn_interactive() {
    local target_disk="$1"  # Receive disk as argument
    [[ -z "$target_disk" ]] && { error "No disk provided to NVMe interactive shell."; return 1; }

    section "Launching interactive side shell for NVMe 4Kn formatting..."
    warn "You can inspect the NVMe disk and cancel formatting safely."

    # Spawn a Bash subprocess with the function and disk pre-defined
    bash --rcfile <(echo "PS1='[NVMe 4Kn] \$ '"; declare -f nvme_4kn_prompt) -i -c "disk='$target_disk'; nvme_4kn_prompt"

    info "Exited side shell. Continuing installer..."
}

nvme_4kn_prompt() {
    section "Checking NVMe namespace LBA formats on $disk..."

    ns_info=$(nvme id-ns -H "$disk" 2>/dev/null) || {
        warn "Failed to query NVMe namespace info."
        return 0
    }

    current_lbaf=$(echo "$ns_info" | awk '/in use/ {print $NF}')
    lba1_line=$(echo "$ns_info" | grep "LBA Format  1" || true)

    [[ -n "$lba1_line" ]] || { info "LBA Format 1 not supported."; return 0; }

    info "$lba1_line"
    data_size=$(echo "$lba1_line" | sed -n 's/.*Data Size: *\([0-9]\+\) bytes.*/\1/p')

    [[ "$data_size" == "4096" ]] || { info "LBA Format 1 is ${data_size} bytes; skipping."; return 0; }

    [[ "$current_lbaf" == "1" ]] && { success "NVMe already 4Kn."; return 0; }

    info "NVMe supports 4Kn (4096-byte logical blocks)."
    warn "Formatting WILL ERASE ALL DATA on $disk."

    prompt "Format NVMe namespace to 4Kn now? (y/N): "
    read -r confirm
    [[ "${confirm,,}" != "y" ]] && { info "User canceled 4Kn format."; return 0; }

    section "Formatting NVMe namespace to 4Kn..."
    nvme format --lbaf=1 "$disk"

    blockdev --rereadpt "$disk" 2>/dev/null || true
    partprobe "$disk" 2>/dev/null || true

    success "NVMe namespace formatted to 4Kn."
    info "Returning to installer..."
}

partition_disk() {
    section "Wiping partition table and signatures on $disk..."
    sgdisk --zap-all "$disk" || true
    wipefs -a "$disk" || true

    section "Creating partitions with sgdisk..."
    sgdisk -n 1:0:4G -I -t1:EF00 "$disk"
    part1="${disk}1"

    if [[ "$use_swap" == "yes" ]]; then
        sgdisk -n 2:0:"+${mem_gib}G" -I -t2:8200 "$disk"
        part2="${disk}2"

        sgdisk -n 3:0:0 -I -t3:8300 "$disk"
        part3="${disk}3"
        btrfs_part="$part3"
    else
        sgdisk -n 2:0:0 -I -t2:8300 "$disk"
        part2="${disk}2"
        btrfs_part="$part2"
    fi

    partprobe "$disk" || true
    sleep 1
}

format_partitions() {
    section "Formatting EFI partition..."
    mkfs.fat -F 32 -n EFI "$part1"

    if [[ "$use_swap" == "yes" ]]; then
        section "Formatting swap partition..."
        mkswap -L SWAP "$part2"
        swapon "$part2"
    fi

    section "Formatting btrfs partition..."
    mkfs.btrfs -f -L ARCH -n 32k "$btrfs_part"
}

subvolumes() {
    declare -A subvol_mounts=(
        ["@"]="."
        ["@home"]="home"
        ["@cache"]="var/cache/pacman/pkg"
        ["@tmp"]="var/tmp"
        ["@log"]="var/log"
        ["@snapshots"]=".snapshots"
    )

    base_opts="noatime,compress=zstd:3,discard=async,ssd,space_cache=v2"

    section "Creating btrfs subvolumes..."
    mkdir -p /mnt/arch
    mount -o "${base_opts},subvolid=5" "$btrfs_part" /mnt/arch

    for subvol in @ @home @cache @tmp @log @snapshots; do
        btrfs subvolume create "/mnt/arch/$subvol"
    done

    umount -R /mnt/arch
    sleep 2

    section "Mounting btrfs subvolumes..."
    for subvol in @ @home @cache @tmp @log @snapshots; do
        target="/mnt/arch/${subvol_mounts[$subvol]}"
        [[ "$target" != "/mnt/arch/." ]] && mkdir -p "$target"
        mount -o "${base_opts},subvol=${subvol}" "$btrfs_part" "$target"
    done

    section "Mounting EFI partition..."
    mkdir -p /mnt/arch/boot
    mount "$part1" /mnt/arch/boot
}

run_pacstrap() {
    microcode_pkg=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}' | \
        sed -e 's/^GenuineIntel$/intel-ucode/' -e 's/^AuthenticAMD$/amd-ucode/')

    if [[ -z "$microcode_pkg" ]]; then
        warn "Unknown CPU vendor, installing both intel-ucode and amd-ucode..."
        microcode_pkg="intel-ucode amd-ucode"
    fi

    base_pkgs="base base-devel linux linux-firmware sof-firmware limine sudo nano git networkmanager btrfs-progs reflector zram-generator $microcode_pkg"

    section "Base packages to be installed:"
    info "$(echo "$base_pkgs" | sed 's/ \+/ | /g')"
    info "Add packages by name, or remove a base package by prefixing it with '!'."
    prompt "Enter package names or press [ENTER] to skip: "
    read -r extra_pkgs

    if [[ -n "${extra_pkgs// }" ]]; then
        removals=()
        additions=()
        for token in $extra_pkgs; do
            if [[ "$token" == !* ]]; then
                removals+=("${token#!}")
            else
                additions+=("$token")
            fi
        done

        if [[ ${#removals[@]} -gt 0 ]]; then
            filtered=()
            for pkg in $base_pkgs; do
                skip=false
                for rm in "${removals[@]}"; do
                    if [[ "$pkg" == "$rm" ]]; then
                        skip=true
                        break
                    fi
                done
                $skip || filtered+=("$pkg")
            done
            base_pkgs="${filtered[*]}"
            warn "Removed from base: ${removals[*]}"
        fi

        if [[ ${#additions[@]} -gt 0 ]]; then
            base_pkgs="$base_pkgs ${additions[*]}"
            info "Added extra: ${additions[*]}"
        fi
    fi

    info "Waiting for reflector to finish, please wait..."
    wait $REFLECTOR_PID
    REFLECTOR_STATUS=$?

    if [[ $REFLECTOR_STATUS -ne 0 ]]; then
        error "Reflector failed with exit code $REFLECTOR_STATUS"
    else
        success "Reflector finished successfully. Proceeding with pacstrap..."
    fi
    
    section "Installing packages: $base_pkgs"
    pacstrap -K /mnt/arch $base_pkgs

    success "Packages installed..."

    if [[ $REFLECTOR_STATUS -ne 0 ]]; then
        cp --dereference /etc/pacman.d/mirrorlist /mnt/arch/etc/pacman.d/mirrorlist
    fi
}

configure_locale_timezone() {
    while true; do
        prompt "Enter locale (e.g., en_US): "
        read -r user_locale

        if [[ "$user_locale" =~ ^[a-zA-Z]{2}_[a-zA-Z]{2}$ ]]; then
            full_locale="${user_locale}.UTF-8"
            if grep -qxF "$full_locale UTF-8" /usr/share/i18n/SUPPORTED; then
                info "Selected locale: $full_locale"
                break
            else
                error "Locale not supported..."
            fi
        else
            error "Invalid format. Example: en_US"
        fi
    done

    if grep -q "^#\s*${full_locale} UTF-8" /etc/locale.gen; then
        sed -i "s|^#\s*\(${full_locale} UTF-8.*\)|\1|" /etc/locale.gen
        info "Enabled $full_locale in /etc/locale.gen"
    elif ! grep -q "^${full_locale} UTF-8" /etc/locale.gen; then
        echo "${full_locale} UTF-8" >> /etc/locale.gen
        info "Added $full_locale to /etc/locale.gen"
    fi

    locale-gen
    info "Locale generated..."

    echo "LANG=${full_locale}" > /etc/locale.conf
    info "Locale set: $full_locale"

    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname

    while true; do
        prompt "Enter timezone (e.g., America/New_York): "
        read -r timezone
        if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
            ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
            hwclock --systohc
            info "Timezone set to $timezone"
            break
        else
            error "Invalid timezone..."
        fi
    done
}

user_setup() {
    while true; do
        prompt "Enter new root password: "
        read -rs root_pass

        prompt "Confirm root password: "
        read -rs root_pass_confirm


        if [ "$root_pass" = "$root_pass_confirm" ]; then
            echo "root:$root_pass" | chpasswd
            success "Root password set..."
            break
        else
            error "Passwords do not match..."
        fi
    done

    prompt "Enter username for new user: "
    read -r username

    while true; do
        prompt "Password for '$username': "
        read -rs user_pass

        prompt "Confirm password: "
        read -rs user_pass_confirm

        if [ "$user_pass" = "$user_pass_confirm" ]; then
            useradd -m -G wheel -s /bin/bash "$username"
            echo "$username:$user_pass" | chpasswd
            success "User '$username' created..."
            break
        else
            error "Passwords do not match..."
        fi
    done
}

install_gpu_drivers() {
    while true; do
        section "Desktop or Laptop?"
        echo "  1) Desktop"
        echo "  2) Laptop"

        prompt "Enter 1 or 2: "
        read -r gpu_line

        if ! [[ "$gpu_line" =~ ^[0-9]+$ ]]; then
            error "Input must be a number..."
            continue
        fi

        if [[ "$gpu_line" -eq 1 ]]; then
            system_type="Desktop"
            info "Desktop selected..."
            break
        elif [[ "$gpu_line" -eq 2 ]]; then
            system_type="Laptop"
            info "Laptop selected...."
            break
        fi

        error "Invalid selection..."
    done

    section "Detecting GPUs..."
    gpu_list=$(lspci -d ::03xx | grep -i "VGA\|3D")
    echo "$gpu_list"

    has_amd=$(echo "$gpu_list" | grep -qi "AMD"; echo $?)
    has_nvidia=$(echo "$gpu_list" | grep -qi "NVIDIA"; echo $?)
    has_intel=$(echo "$gpu_list" | grep -qi "Intel"; echo $?)

    if [[ $has_amd -ne 0 && $has_nvidia -ne 0 && $has_intel -ne 0 ]]; then
        warn "No supported GPU found. Skipping..."
        return 0
    fi

    info "Detected GPU:"
    [[ $has_amd -eq 0 ]] && info "  AMD GPU"
    [[ $has_nvidia -eq 0 ]] && info "  NVIDIA GPU"
    [[ $has_intel -eq 0 ]] && info "  Intel GPU"

    section "Installing GPU drivers..."
    amd_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader"
    nvidia_pkgs="nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils nvidia-prime"
    intel_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader"

    if [[ "$system_type" == "Desktop" ]]; then
        [[ $has_amd -eq 0 ]] && pacman -Sq --needed --noconfirm $amd_pkgs
        [[ $has_nvidia -eq 0 ]] && pacman -Sq --needed --noconfirm $nvidia_pkgs
        [[ $has_intel -eq 0 ]] && pacman -Sq --needed --noconfirm $intel_pkgs
    else
        if [[ $has_intel -eq 0 && $has_nvidia -eq 0 ]]; then
            info "Intel + NVIDIA hybrid detected."
            pacman -Sq --needed --noconfirm $intel_pkgs $nvidia_pkgs
        elif [[ $has_amd -eq 0 && $has_nvidia -eq 0 ]]; then
            info "AMD + NVIDIA hybrid detected."
            pacman -Sq --needed --noconfirm $amd_pkgs $nvidia_pkgs
        elif [[ $has_intel -eq 0 ]]; then
            info "Intel-only laptop."
            pacman -Sq --needed --noconfirm $intel_pkgs
        elif [[ $has_amd -eq 0 ]]; then
            info "AMD-only laptop."
            pacman -Sq --needed --noconfirm $amd_pkgs
        fi
    fi

    success "GPU driver installation complete..."
}

chroot_setup() {
    GREEN="\033[1;32m"
    YELLOW="\033[1;33m"
    RED="\033[1;31m"
    BLUE="\033[1;34m"
    CYAN="\033[1;36m"
    RESET="\033[0m"

    info()    { echo; echo -e "${GREEN}[INFO] $*${RESET}"; }
    warn()    { echo; echo -e "${YELLOW}[WARN] $*${RESET}"; }
    error()   { echo; echo -e "${RED}[ERROR] $*${RESET}"; }
    success() { echo; echo -e "${GREEN}[ OK ] $*${RESET}"; }
    section() { echo; echo -e "${CYAN}==> ${BLUE}$*${RESET}"; }
    prompt()  { echo; echo -en "${BLUE}[INPUT] $*${RESET}"; }

    section "Enabling multilib repository..."
    sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/ { s/^[[:space:]]*#//; n; s/^[[:space:]]*#// }' /etc/pacman.conf

    section "Syncing repositories and updating package database..."
    pacman -Syuq --noconfirm

    prompt "Install KDE Plasma desktop? (y/N): "
    read -r install_desktop_pkgs
    if [[ "${install_desktop_pkgs,,}" == "y" ]]; then
        pacman -Sq --needed --noconfirm plasma-meta sddm dolphin konsole firefox
        systemctl enable sddm.service
    fi

    prompt "Install GPU drivers? (y/N): "
    read -r install_gpu_driver_pkgs
    [[ "${install_gpu_driver_pkgs,,}" == "y" ]] && install_gpu_drivers

    configure_locale_timezone
    user_setup

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    systemctl enable fstrim.timer NetworkManager.service reflector.service

    mkdir -p /boot/EFI/BOOT

    pacman -Sq --needed --noconfirm limine
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    echo "timeout: 5" > /boot/limine.conf
    echo "default_entry: 1" >> /boot/limine.conf
    echo "" >> /boot/limine.conf
    echo "/Arch Linux" >> /boot/limine.conf
    echo "    protocol: linux" >> /boot/limine.conf
    echo "    kernel_path: boot():/vmlinuz-linux" >> /boot/limine.conf
    echo "    module_path: boot():/initramfs-linux.img" >> /boot/limine.conf
    echo "    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw" >> /boot/limine.conf

    if grep -q "SWAP" /etc/fstab; then
        swapon -a
    fi

    echo "[zram0]" >> /etc/systemd/zram-generator.conf
    echo "zram-size = min(ram)" >> /etc/systemd/zram-generator.conf
    echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

    success "Post-chroot configuration complete, rebuilding initramfs..."
    mkinitcpio -P
}

finalize_install() {
    section "Generating fstab..."
    genfstab -L /mnt/arch > /mnt/arch/etc/fstab

    section "Copying script into new system..."
    mkdir -p /mnt/root
    cp -- "$0" /mnt/arch/root/arch-install.sh
    chmod +x /mnt/arch/root/arch-install.sh

    prompt "Skip chroot? (y/N): "
    read -r skip_chroot
    if [[ "${skip_chroot,,}" == "y" ]]; then
        warn "Chroot skipped. System mounted at /mnt..."
        exit 0
    fi

    arch-chroot /mnt/arch /bin/bash -c \
        "$(declare -f chroot_setup configure_locale_timezone user_setup install_gpu_drivers); chroot_setup"

    section "Adding EFI boot entry..."
    efibootmgr --create --disk "$disk" --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode

    prompt "Reboot now? (y/N): "
    read -r reboot_answer
    if [[ "${reboot_answer,,}" == "y" ]]; then
        umount -R /mnt
        sleep 2
        reboot
    fi
}

main() {
    [[ $EUID -eq 0 ]] || { error "Must be run as root."; exit 1; }
    
    clear
    warn "WARNING: This WILL DESTROY ALL DATA on the selected disk."
    prompt "Proceed? (y/N): "
    read -r answer
    [[ "${answer,,}" == "y" ]] || { warn "Aborted."; exit 1; }

    reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist > /dev/null 2>&1 &
    REFLECTOR_PID=$!

    choose_disk
    cleanup_disk
    set_swap
    if [[ "$disk" == /dev/nvme*n* ]]; then
        nvme_4kn_interactive "$disk"
    fi
    partition_disk
    format_partitions
    subvolumes
    run_pacstrap
    finalize_install
}

main "$@"
