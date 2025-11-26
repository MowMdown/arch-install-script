#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Functions
# ================================================================

confirm() {
    local msg="$1"
    echo
    echo ">>> $msg"
    echo "Type YES to proceed, anything else to abort:"
    read -r answer
    [[ "$answer" == "YES" ]] || { echo "Aborted."; exit 1; }
}

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

bytes_to_mib() {
    awk "BEGIN{printf \"%d\", ($1/1024/1024)+0.5}"
}

post_chroot_setup() {
    echo "=== Starting post-chroot configuration ==="

    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
    hwclock --systohc

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

    pacman -Syu
    pacman -S --noconfirm sudo
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

set_swap() {
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    mem_mib=$(( (mem_kb + 1023) / 1024 ))
    echo "Detected system RAM: ${mem_mib} MiB"

    echo
    echo "Enable swap equal to RAM (${mem_mib} MiB)? (y/N)"
    read -r use_swap_raw
    if [[ "$use_swap_raw" =~ ^[Yy] ]]; then
        use_swap="yes"
    else
        use_swap="no"
    fi
}

partition_disk() {
    echo "Wiping partition table and signatures ..."
    sgdisk --zap-all "$disk" || true
    wipefs -a "$disk" || true

    echo "Creating partitions..."
    parted -s "$disk" mklabel gpt

    parted -s "$disk" mkpart primary fat32 1MiB 2048MiB
    parted -s "$disk" set 1 boot on
    part1="${disk}1"

    if [[ "$use_swap" == "yes" ]]; then
        swap_end_mib=$((2048 + mem_mib))
        parted -s "$disk" mkpart primary linux-swap 2048MiB "${swap_end_mib}MiB"
        part2="${disk}2"
        parted -s "$disk" mkpart primary btrfs "${swap_end_mib}MiB" 100%
        part3="${disk}3"
        btrfs_part="$part3"
    else
        parted -s "$disk" mkpart primary btrfs 2048MiB 100%
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

    echo "Formatting Btrfs..."
    mkfs.btrfs -f -L ARCH "$btrfs_part"
}

create_subvolumes() {
    mount -o subvolid=5 "$btrfs_part" /mnt
    for sv in @ @home @cache @tmp @log @snapshots; do
        btrfs subvolume create "/mnt/$sv"
    done
    sync
    umount -R /mnt
}

mount_subvolumes() {
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

    echo "Any extra packages to install with pacstrap? (space-separated, or leave empty):"
    read -r extra_packages

    if [[ -n "${extra_packages// }" ]]; then
        base_pkgs="$base_pkgs $extra_packages"
    fi

    pacstrap -K /mnt $base_pkgs
    genfstab -L /mnt > /mnt/etc/fstab
}

finalize_install() {
    echo "Copying script into new system..."
    mkdir -p /mnt/root
    cp -- "$0" /mnt/root/arch-install-automated.sh
    chmod +x /mnt/root/arch-install-automated.sh

    echo
    echo "Type YES to enter chroot:"
    read -r final_go

    if [[ "$final_go" == "YES" ]]; then
        arch-chroot /mnt /bin/bash -c "$(declare -f post_chroot_setup); post_chroot_setup"

        echo
        echo "Adding EFI Bootloader Entry"
        efibootmgr \
        --create \
        --disk "$disk" \
        --part 1 \
        --label "Arch Linux Limine Bootloader" \
        --loader '\EFI\BOOT\BOOTX64.EFI' \
        --unicode

        confirm "Reboot to system now?"
        umount -R /mnt
        reboot
    else
        echo "Exiting. System is mounted at /mnt."
        exit 0
    fi
}

# ================================================================
# Main Workflow
# ================================================================

main() {
    [[ $EUID -eq 0 ]] || { echo "Must be run as root."; exit 1; }

    echo "=== Arch automated installation script ==="
    echo "WARNING: This WILL DESTROY ALL DATA on the selected disk."

    choose_disk
    set_swap

    echo
    echo "We will create the following on ${disk}:"
    echo "  1) EFI partition (2 GiB)"
    if [[ "$use_swap" == "yes" ]]; then
        echo "  2) swap (${mem_mib} MiB)"
        echo "  3) Btrfs"
    else
        echo "  2) Btrfs"
    fi

    confirm "Proceed with partitioning?"

    cleanup_disk
    partition_disk
    format_partitions
    create_subvolumes
    mount_subvolumes
    run_pacstrap
    finalize_install
}

main "$@"
