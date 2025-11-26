#!/usr/bin/env bash
set -euo pipefail

# Select disk to partition and store global $disk variable
choose_disk() {
    while true; do
        echo "Available disks:"
        lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1 | sed '/^$/d'
        echo -n "Enter the line number of the disk to use (will be wiped): "
        read -r line
        
        if ! [[ "$line" =~ ^[0-9]+$ ]]; then
            echo "Error: Input must be a number."
            continue
        fi
        disk=$(lsblk -dpno NAME | sed -n "${line}p")
        if [[ -n "$disk" ]]; then
            echo "Selected disk: $disk"
            break
        else
            echo "Invalid selection. Please choose a valid line number."
        fi
    done
}

# If disk selected is currently mounted or contains existing partitions, remove them
cleanup_disk() {
    echo "Unmounting /mnt before proceeding..."
    if mountpoint -q /mnt; then
        echo "/mnt is currently mounted, unmounting..."
        umount -R /mnt || true
        sleep 2
    else
        echo "/mnt is not mounted, nothing to do."
    fi

    echo "Checking for swap partitions on $disk..."
    for part in $(lsblk -lnpo NAME "$disk"); do
        if [[ "$part" == "$disk" ]]; then
            continue
        fi
        if lsblk -no MOUNTPOINT "$part" | grep -q '\[SWAP\]'; then
            echo "$part is a swap partition, turning off swap..."
            swapoff "$part" || true
        fi
    done
}

# Option to enable swap use
set_swap() {
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    mem_mib=$(( (mem_kb + 1023) / 1024 ))
    echo "Detected system RAM: ${mem_mib} MiB"

    echo
    echo "Enable swap equal to RAM (${mem_mib} MiB)? (y/N)"
    read -r use_swap_raw
    if [[ "${use_swap_raw,,}" == "y" ]]; then
        use_swap="yes"
    else
        use_swap="no"
    fi
}

# Partition disk with selected disk and swap options
partition_disk() {
    echo "Wiping partition table and signatures on $disk..."
    sgdisk --zap-all "$disk" || true
    wipefs -a "$disk" || true
    echo "Creating partitions with sgdisk..."
    sgdisk -n1:1MiB:2048MiB -t1:EF00 "$disk"
    part1="${disk}1"

    if [[ "$use_swap" == "yes" ]]; then
    
        swap_end_mib=$((2048 + mem_mib))
        sgdisk -n2:2048MiB:"${swap_end_mib}MiB" -t2:8200 "$disk"
        part2="${disk}2"

        sgdisk -n3:"${swap_end_mib}MiB":0 -t3:8300 "$disk"
        part3="${disk}3"
        btrfs_part="$part3"
    else
        sgdisk -n2:2048MiB:0 -t2:8300 "$disk"
        part2="${disk}2"
        btrfs_part="$part2"
    fi

    partprobe "$disk" || true
    sleep 1
}

format_partitions() {
    echo "Formatting EFI partition..."
    mkfs.fat -F32 -n EFI "$part1"

    if [[ "$use_swap" == "yes" ]]; then
        echo "Creating swap..."
        mkswap -L SWAP "$part2"
        swapon "$part2"
    fi

    echo "Formatting Btrfs partition..."
    mkfs.btrfs -f -L ARCH "$btrfs_part"
}

# Create and mount btrfs subvolumes to root btrfs partition
subvolumes() {
    mount -o subvolid=5 "$btrfs_part" /mnt
    
    for sv in @ @home @cache @tmp @log @snapshots; do
        btrfs subvolume create "/mnt/$sv"
    done
    
    sync
    umount -R /mnt
    sleep 2
    
    echo "Mounting root..."
    mount -o compress=zstd,noatime,subvol=@ "$btrfs_part" /mnt

    mkdir -p /mnt/{home,var/cache/pacman/pkg,var/tmp,var/log,.snapshots}
    echo "Mounting subvolumes..."
    mount -o compress=zstd,noatime,subvol=@home "$btrfs_part" /mnt/home
    mount -o compress=zstd,noatime,subvol=@cache "$btrfs_part" /mnt/var/cache/pacman/pkg
    mount -o compress=zstd,noatime,subvol=@tmp "$btrfs_part" /mnt/var/tmp
    mount -o compress=zstd,noatime,subvol=@log "$btrfs_part" /mnt/var/log
    mount -o compress=zstd,noatime,subvol=@snapshots "$btrfs_part" /mnt/.snapshots

    mkdir -p /mnt/boot
    mount "$part1" /mnt/boot
}

run_pacstrap() {
    base_pkgs="base base-devel linux linux-firmware sof-firmware amd-ucode intel-ucode limine sudo nano git networkmanager btrfs-progs reflector zram-generator"

    while true; do
        echo
        echo "Any extra packages to install with pacstrap? (space-separated, or press Enter to skip):"
        read -r extra_packages
        
        [[ -z "${extra_packages// }" ]] && break
        
        invalid_pkg=""

        for pkg in $extra_packages; do
            [[ -z "$pkg" ]] && continue
            if ! pacman -Si "$pkg" &>/dev/null; then
                invalid_pkg="$invalid_pkg $pkg"
            fi
        done

        if [[ -n "$invalid_pkg" ]]; then
            echo
            echo "The following packages are invalid or not found in the repositories:$invalid_pkg"
            echo "Please try again or press Enter to skip extra packages."
        else
            base_pkgs="$base_pkgs $extra_packages"
            break
        fi
    done

    echo
    echo "Installing packages: $base_pkgs"
    pacstrap -K /mnt $base_pkgs
    echo
    echo "Package installation complete..."
}

configure_locale_timezone() {
    while true; do
        read -rp "Enter your locale (e.g., en_US): " user_locale
        if [[ "$user_locale" =~ ^[a-zA-Z]{2}_[a-zA-Z]{2}$ ]]; then
            full_locale="${user_locale}.UTF-8"
            echo "Selected locale: $full_locale"
            break
        else
            echo "Invalid format. Example: en_US"
        fi
    done

    if grep -q "^#\s*${full_locale} UTF-8" /etc/locale.gen; then
        sed -i "s|^#\s*\(${full_locale} UTF-8.*\)|\1|" /etc/locale.gen
        echo "Uncommented $full_locale in /etc/locale.gen"
    else
        echo "$full_locale UTF-8" >> /etc/locale.gen
        echo "Added $full_locale to /etc/locale.gen"
    fi


    locale-gen
    echo "LANG=${full_locale}" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname

    while true; do
        read -rp "Enter your timezone (e.g., America/New_York, Europe/London): " user_timezone
        if [[ -f "/usr/share/zoneinfo/$user_timezone" ]]; then
            ln -sf "/usr/share/zoneinfo/$user_timezone" /etc/localtime
            hwclock --systohc
            echo "Timezone set to $user_timezone"
            break
        else
            echo "Invalid timezone. Make sure it exists in /usr/share/zoneinfo."
        fi
    done
    
    echo "Locale and timezone configured successfully!"
}

user_setup() {
    while true; do
        read -s -p "Enter new root password: " root_pass
        echo
        read -s -p "Confirm root password: " root_pass_confirm
        echo
        if [ "$root_pass" = "$root_pass_confirm" ]; then
            echo "root:$root_pass" | chpasswd
            echo "Root password set successfully."
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done

    read -p "Enter username for new user: " username
    while true; do
        read -s -p "Enter password for user '$username': " user_pass
        echo
        read -s -p "Confirm password for user '$username': " user_pass_confirm
        echo
        if [ "$user_pass" = "$user_pass_confirm" ]; then
            useradd -m -G wheel -s /bin/bash "$username"
            echo "$username:$user_pass" | chpasswd
            echo "User '$username' created successfully."
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
    }

chroot_setup() {
    pacman -Syu --noconfirm

    configure_locale_timezone
    user_setup    

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    systemctl enable fstrim.timer
    systemctl enable NetworkManager.service
    systemctl enable reflector.service

    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    echo "timeout: 5" > /boot/limine.conf
    echo "default_entry: 1" >> /boot/limine.conf
    echo "" >> /boot/limine.conf
    echo "/Arch Linux" >> /boot/limine.conf
    echo "    protocol: linux" >> /boot/limine.conf
    echo "    kernel_path: boot():/vmlinuz-linux" >> /boot/limine.conf
    echo "    module_path: boot():/initramfs-linux.img" >> /boot/limine.conf
    echo "    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw" >> /boot/limine.conf

    echo "Created /boot/limine.conf"

    if grep -q "SWAP" /etc/fstab; then
        swapon -a
    fi

    echo "[zram0]" >> /etc/systemd/zram-generator.conf
    echo "zram-size = min(ram)" >> /etc/systemd/zram-generator.conf
    echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

    echo
    echo "Post-chroot configuration complete!"
    sleep 1
}

finalize_install() {
    echo "Generating /etc/fstab..."
    genfstab -L /mnt > /mnt/etc/fstab
    echo "Copying script into new root..."
    mkdir -p /mnt/root
    cp -- "$0" /mnt/root/arch-install.sh
    chmod +x /mnt/root/arch-install.sh
    echo
    read -rp "Proceed to enter chroot? (N/y): " final_go

    if [[ "${final_go,,}" == "y" ]]; then
        arch-chroot /mnt /bin/bash -c "$(declare -f chroot_setup); chroot_setup"
        echo "Adding EFI Bootloader Entry"
        efibootmgr --create --disk "$disk" --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode
        echo
        read -rp "Reboot system now? (N/y): " reboot_answer
        
        if [[ "${reboot_answer,,}" == "y" ]]; then
            umount -R /mnt
            sleep 2
            reboot
        else
            echo "Exiting. System is mounted at /mnt."
            exit 0
        fi
    else
        echo "Exiting. System is mounted at /mnt."
        exit 0
    fi
}

main() {
    [[ $EUID -eq 0 ]] || { echo "Must be run as root."; exit 1; }
    echo "WARNING: This WILL DESTROY ALL DATA on the selected disk."
    echo
    read -rp "Proceed with installation? (N/y): " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 1; }

    choose_disk
    cleanup_disk
    set_swap
    partition_disk
    format_partitions
    subvolumes
    run_pacstrap
    chroot_setup
    finalize_install
}

main "$@"
