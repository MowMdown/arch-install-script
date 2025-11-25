#!/usr/bin/env bash
# arch-install.sh
# Usage: run as root inside an Arch install/live environment.
set -euo pipefail

# ---------- Helper Functions ----------

confirm() {
    local msg="$1"
    echo -e "\n>>> $msg"
    echo "Type YES to proceed, anything else to abort:"
    read -r answer
    [[ "$answer" != "YES" ]] && { echo "Aborted by user."; exit 1; }
}

choose_disk() {
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1
    echo -e "\nEnter the line number of the disk to use (will be wiped):"
    read -r line
    disk=$(lsblk -dpno NAME | sed -n "${line}p")
    [[ -z "$disk" ]] && { echo "Invalid selection."; exit 1; }
    echo "Selected disk: $disk"
}

get_ram_mib() {
    awk '/MemTotal:/ {print int(($2 + 1023)/1024)}' /proc/meminfo
}

wipe_and_partition_disk() {
    local disk="$1"
    local use_swap="$2"
    local mem_mib="$3"

    # Unmount and wipe
    mapfile -t mounted < <(lsblk -lnpo NAME,MOUNTPOINT "$disk" | awk '$2!="" {print $1}')
    for p in "${mounted[@]}"; do umount "$p" || true; done
    sgdisk --zap-all "$disk" || true
    wipefs -a "$disk" || true
    parted -s "$disk" mklabel gpt

    # EFI size logic
    local disk_mib efi_mib
    disk_mib=$(parted -sm "$disk" unit MiB print | awk -F: '/^/ {print $2}' | head -n1)
    efi_mib=$(( disk_mib < 65536 ? 512 : disk_mib < 262144 ? 1024 : 2048 ))
    local efi_end=$((efi_mib + 1))
    local next_start=$efi_end

    # Create partitions
    parted -s "$disk" mkpart primary fat32 1MiB "${efi_end}MiB"
    parted -s "$disk" set 1 boot on
    part1="${disk}1"

    if [[ "$use_swap" == "yes" ]]; then
        swap_gib=$(( (mem_mib + 1023)/1024 ))
        swap_mib=$(( swap_gib * 1024 ))
        swap_end=$((next_start + swap_mib))
        parted -s "$disk" mkpart primary linux-swap "${next_start}MiB" "${swap_end}MiB"
        part2="${disk}2"
        parted -s "$disk" mkpart primary btrfs "${swap_end}MiB" 100%
        part3="${disk}3"
        btrfs_part="$part3"
    else
        parted -s "$disk" mkpart primary btrfs "${next_start}MiB" 100%
        part2="${disk}2"
        btrfs_part="$part2"
    fi

    partprobe "$disk" || true
    sleep 1

    # Format
    mkfs.fat -F32 -n EFI "$part1"
    [[ "$use_swap" == "yes" ]] && { mkswap -L SWAP "$part2"; swapon "$part2"; }
    mkfs.btrfs -f -L ARCH "$btrfs_part"

    echo "$part1" "$btrfs_part"
}

create_btrfs_subvolumes() {
    local btrfs_part="$1"
    mount -o subvolid=5 "$btrfs_part" /mnt
    for sv in @ @home @cache @tmp @log @snapshots; do btrfs subvolume create "/mnt/$sv"; done
    sync; umount -R /mnt

    mount -o compress=zstd,noatime,subvol=@ "$btrfs_part" /mnt
    mkdir -p /mnt/{home,var/cache/pacman/pkg,var/tmp,var/log,.snapshots}

    declare -A subvolumes=( ["home"]="@home" ["var/cache/pacman/pkg"]="@cache" ["var/tmp"]="@tmp" ["var/log"]="@log" [".snapshots"]="@snapshots" )
    for dir in "${!subvolumes[@]}"; do
        mount -o compress=zstd,noatime,subvol=${subvolumes[$dir]} "$btrfs_part" "/mnt/$dir"
    done
}

mount_efi() { mount --mkdir "$1" /mnt/boot; }

install_base_system() {
    local extra_packages="$1"
    confirm "Proceed to pacstrap base system to /mnt?"
    local cpu_vendor microcode_pkg
    cpu_vendor=$(lscpu | awk '/Vendor ID/ {print $3}')
    microcode_pkg=$([[ "$cpu_vendor" == "AuthenticAMD" ]] && echo "amd-ucode" || [[ "$cpu_vendor" == "GenuineIntel" ]] && echo "intel-ucode" || echo "amd-ucode intel-ucode")
    base_pkgs="base base-devel linux linux-firmware sof-firmware $microcode_pkg limine sudo nano git networkmanager btrfs-progs reflector zram-generator"
    [[ -n "${extra_packages// }" ]] && base_pkgs="$base_pkgs $extra_packages"
    pacstrap -K /mnt $base_pkgs
    genfstab -L /mnt > /mnt/etc/fstab
}

post_chroot_setup() {
    read -p "Enter locale (e.g., en_US.UTF-8): " locale_gen
    read -p "Enter timezone (e.g., Europe/London): " timezone_loc
    echo "$locale_gen UTF-8" > /etc/locale.gen; locale-gen
    echo "LANG=${locale_gen%%.*}.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname
    ln -sf /usr/share/zoneinfo/"$timezone_loc" /etc/localtime; hwclock --systohc

    # Root password
    while true; do
        read -s -p "Root password: " root_pass; echo
        read -s -p "Confirm: " root_pass_confirm; echo
        [[ "$root_pass" == "$root_pass_confirm" ]] && break
        echo "Passwords do not match."
    done
    echo "root:$root_pass" | chpasswd

    # Standard user
    read -p "Username for new user: " username
    while true; do
        read -s -p "Password for $username: " user_pass; echo
        read -s -p "Confirm: " user_pass_confirm; echo
        [[ "$user_pass" == "$user_pass_confirm" ]] && break
        echo "Passwords do not match."
    done
    useradd -m -G wheel "$username"
    echo "$username:$user_pass" | chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    pacman -Syu
    systemctl enable fstrim.timer NetworkManager.service reflector.service

    # Limine config using echo (original method)
    echo "timeout: 5" > /boot/limine.conf
    echo "default_entry: 1" >> /boot/limine.conf
    echo "" >> /boot/limine.conf
    echo "/Arch Linux" >> /boot/limine.conf
    echo "    protocol: linux" >> /boot/limine.conf
    echo "    kernel_path: boot():/vmlinuz-linux" >> /boot/limine.conf
    echo "    module_path: boot():/initramfs-linux.img" >> /boot/limine.conf
    echo "    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw" >> /boot/limine.conf

    [[ $(grep -c "SWAP" /etc/fstab) -gt 0 ]] && swapon -a

    echo "[zram0]" >> /etc/systemd/zram-generator.conf
    echo "zram-size = min(ram)" >> /etc/systemd/zram-generator.conf
    echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf
}

# ---------- Main Flow ----------

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }
echo "=== Arch automated installer with Btrfs subvolumes ==="
echo "WARNING: This script WILL DESTROY data on the selected disk."

choose_disk
mem_mib=$(get_ram_mib)
echo "Detected system RAM: ${mem_mib} MiB"

# Interactive swap decision
echo ""
echo "Do you want to enable a swap partition equal to RAM (${mem_mib} MiB)? (y/N)"
read -r use_swap_raw
use_swap="no"
[[ "$use_swap_raw" =~ ^[Yy] ]] && use_swap="yes"

read -rp "Extra packages for pacstrap (space-separated)? " extra_packages

confirm "Proceed with disk partitioning?"
parts=($(wipe_and_partition_disk "$disk" "$use_swap" "$mem_mib"))
part1="${parts[0]}"; btrfs_part="${parts[1]}"

create_btrfs_subvolumes "$btrfs_part"
mount_efi "$part1"
install_base_system "$extra_packages"

mkdir -p /mnt/root
cp -- "$0" /mnt/root/arch-install-automated.sh
chmod +x /mnt/root/arch-install-automated.sh

read -rp "Type YES to enter chroot and finish configuration: " final_go
if [[ "$final_go" == "YES" ]]; then
    arch-chroot /mnt /bin/bash -c "$(declare -f post_chroot_setup); post_chroot_setup"
    efibootmgr --create --disk "$disk" --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\BOOT\BOOTX64.EFI' --unicode
    confirm "Reboot now?"
    umount -R /mnt
    echo "Reboot your system."
else
    echo "System mounted under /mnt; remember to chroot later."
fi

