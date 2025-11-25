#!/usr/bin/env bash
# arch-install-automated.sh
# Usage: run as root inside an Arch install/live environment.
set -euo pipefail

# ---------- helper functions ----------

confirm() {
  # Usage: confirm "message"
  local msg="$1"
  echo
  echo ">>> $msg"
  echo "Type YES to proceed, anything else to abort:"
  read -r answer
  if [[ "$answer" != "YES" || "$answer" != "Yes" || "$answer" != "yes" || "$answer" != "Y" || "$answer" != "y" ]]; then
    echo "Aborted by user."
    exit 1
  fi
}

choose_disk() {
  echo "Available disks:"
  # Show only whole-disk devices (no partitions) and their sizes & model where available
  # using lsblk
  lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1
  echo
  echo "Enter the line number of the disk to use (will be wiped):"
  read -r line
  disk=$(lsblk -dpno NAME | sed -n "${line}p")
  if [[ -z "$disk" ]]; then
    echo "Invalid selection."
    exit 1
  fi
  echo "Selected disk: $disk"
}

bytes_to_mib() {
  # converts bytes to MiB rounded up
  awk "BEGIN{printf \"%d\", ($1/1024/1024)+0.5}"
}

post_chroot_setup() {
    echo "=== Starting post-chroot configuration ==="

    # Set Defaults
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname
    ln -sf /usr/share/zoneinfo/America/New-York /etc/localtime
    hwclock --systohc

    # Set root password
    echo "root:changeme" | chpasswd
    echo "Root password set to 'changeme'. Please change after first login."

    # Create a standard user
    username="archuser"
    useradd -m -G wheel -s /bin/bash "$username"
    echo "${username}:changeme" | chpasswd
    echo "User '$username' created. Please change password after first login."

    # Enable sudo for wheel group
    pacman -S --noconfirm sudo
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

    # Enable basic services
    pacman -S --noconfirm networkmanager
    systemctl enable NetworkManager
    systemctl enable fstrim.timer

    # Configure bootloader (Limine, EFI assumed)
    pacman -S --noconfirm limine
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    echo "timeout: 5" > /boot/limine.conf
    echo "default_entry: 1" >> /boot/limine.conf
    echo "" >> /boot/limine.conf
    echo "/Arch Linux" >> /boot/limine.conf
    echo "    protocol: Linux" >> /boot/limine.conf
    echo "    kernel_path: boot():/vmlinuz-linux" >> /boot/limine.conf
    echo "    module_path: boot():/initramfs-linux.img" >> /boot/limine.conf
    echo "    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw" >> /boot/limine.conf

    echo "Created /boot/limine.conf"

    # Add bootloader entry
    echo
    echo "Adding EFI Bootloader Entry"
    efibootmgr \
    --create \
    --disk "$disk" \
    --part 1 \
    --label "Arch Linux Limine Bootloader" \
    --loader '\EFI\BOOT\BOOTX64.EFI' \
    --Unicode
    echo "EFI boot entry created successfully."


    # Enable swap if present
    if grep -q "SWAP" /etc/fstab; then
        swapon -a
    fi

    echo
    echo "Post-chroot configuration complete!"
}

# ---------- start ----------

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

echo "=== Arch automated partitioner + btrfs subvolume creator ==="
echo "WARNING: This script WILL DESTROY data on the selected disk."
confirm "I understand this will destroy the selected disk and want to continue"

# select disk
choose_disk

# final confirmation with the exact disk path
confirm "FINAL CHECK: I confirm I want to wipe and partition the disk: ${disk}"

# Get current RAM in MiB for swap suggestion
# We'll use /proc/meminfo
mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
mem_mib=$(( (mem_kb + 1023) / 1024 ))
echo "Detected system RAM: ${mem_mib} MiB"

echo
echo "Do you want to enable a swap partition equal to RAM (${mem_mib} MiB)? (y/N)"
read -r use_swap_raw
use_swap="no"
if [[ "$use_swap_raw" =~ ^[Yy] ]]; then
  use_swap="yes"
fi

echo
echo "Any extra packages to install with pacstrap? (space-separated, or leave empty):"
read -r extra_packages

echo
echo "We will create these partitions on ${disk}:"
echo "  1) 2 GiB EFI FAT32 labeled 'EFI'"
if [[ "$use_swap" == "yes" ]]; then
  echo "  2) swap of ${mem_mib} MiB labeled 'SWAP'"
  echo "  3) remaining space as btrfs labeled 'ARCH'"
else
  echo "  2) remaining space as btrfs labeled 'ARCH'"
fi
confirm "Proceed with partitioning ${disk} as described?"

# Unmount any mounted partitions from this disk to avoid conflicts
echo "Unmounting any mounted partitions on $disk ..."
mapfile -t mounted_parts < <(lsblk -lnpo NAME,MOUNTPOINT "$disk" | awk '$2!="" {print $1}')
if [[ ${#mounted_parts[@]} -gt 0 ]]; then
  for p in "${mounted_parts[@]}"; do
    echo "  umount $p || true"
    umount "$p" || true
  done
fi

# Wipe partition table and existing signatures
echo "Wiping partition table and signatures on $disk ..."
sgdisk --zap-all "$disk" || true
wipefs -a "$disk" || true

# Build parted commands
echo "Creating partitions..."
# We'll use parted for precise MiB-level sizes
# partition 1: 1MiB start to 2048MiB (2GiB)
# partition 2: if swap -> 2048MiB to 2048MiB + mem_mib MiB
# final btrfs partition -> rest of disk
parted -s "$disk" mklabel gpt

# Using 1MiB alignment
parted -s "$disk" mkpart primary fat32 1MiB 2048MiB
parted -s "$disk" set 1 boot on
part1="${disk}1"

if [[ "$use_swap" == "yes" ]]; then
  swap_end_mib=$((2048 + mem_mib))
  parted -s "$disk" mkpart primary linux-swap 2048MiB "${swap_end_mib}MiB"
  part2="${disk}2"
  parted -s "$disk" mkpart primary btrfs "${swap_end_mib}MiB" 100%
  part3="${disk}3"
else
  parted -s "$disk" mkpart primary btrfs 2048MiB 100%
  part2="${disk}2"  # this will be the btrfs partition
fi

# Wait for kernel to refresh partition table
echo "Informing kernel of partition table changes..."
partprobe "$disk" || true
sleep 1

# Format partitions
echo "Formatting EFI partition ($part1) as FAT32 and labeling 'EFI'..."
mkfs.fat -F32 -n EFI "$part1"

if [[ "$use_swap" == "yes" ]]; then
  echo "Creating swap on $part2 with label 'SWAP'..."
  mkswap -L SWAP "$part2"
  # enable swap now? We won't enable it permanently yet; user can decide.
  echo "Enabling swap ($part2) temporarily..."
  swapon "$part2"
  btrfs_part="$part3"
else
  btrfs_part="$part2"
fi

echo "Formatting btrfs partition ($btrfs_part) and labeling 'ARCH'..."
mkfs.btrfs -f -L ARCH "$btrfs_part"

# Mount btrfs to /mnt for subvolume creation
echo "Mounting ${btrfs_part} to /mnt with subvolid=5 to create subvolumes..."
mount -o subvolid=5 "$btrfs_part" /mnt

# Create Btrfs subvolumes commonly used for snapshot setups
echo "Creating Btrfs subvolumes: @, @home, @var, @srv, @tmp, @snapshots ..."
for sv in @ @home @cache @tmp @log @snapshots; do
  echo "  creating subvol $sv"
  btrfs subvolume create "/mnt/$sv"
done

# Sync and unmount
sync
umount /mnt

# Mount btrfs to /mnt for subvolume creation
echo "Mounting ${btrfs_part} to /mnt with subvolid=5 to create subvolumes..."
mount -o subvolid=5 "$btrfs_part" /mnt

echo "Creating subvolumes..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@snapshots

sync
umount /mnt

echo "Remounting Btrfs partition to /mnt before directory creation..."
mount "$btrfs_part" /mnt

echo "Creating required mount directories..."
mkdir -p /mnt
mkdir -p /mnt/home
mkdir -p /mnt/var/cache/pacman/pkg
mkdir -p /mnt/var/tmp
mkdir -p /mnt/var/log
mkdir -p /mnt/.snapshots

echo "Mounting subvolumes with options..."
mount -o compress=zstd,noatime,subvol=@ "$btrfs_part" /mnt
mount -o compress=zstd,noatime,subvol=@home "$btrfs_part" /mnt/home
mount -o compress=zstd,noatime,subvol=@cache "$btrfs_part" /mnt/var/cache/pacman/pkg
mount -o compress=zstd,noatime,subvol=@tmp "$btrfs_part" /mnt/var/tmp
mount -o compress=zstd,noatime,subvol=@log "$btrfs_part" /mnt/var/log
mount -o compress=zstd,noatime,subvol=@snapshots "$btrfs_part" /mnt/.snapshots

echo "Verifying subvolume mounts..."

declare -A subvol_checks=(
  ["/mnt"]="@"
  ["/mnt/home"]="@home"
  ["/mnt/var/cache/pacman/pkg"]="@cache"
  ["/mnt/var/tmp"]="@tmp"
  ["/mnt/var/log"]="@log"
  ["/mnt/.snapshots"]="@snapshots"
)

mount_errors=0

for path in "${!subvol_checks[@]}"; do
  sv="${subvol_checks[$path]}"

  if ! findmnt -rn -S "$btrfs_part" -T "$path" | grep -q "subvol=$sv"; then
    echo "[FAIL] $path (expected subvol=$sv)"
    mount_errors=$((mount_errors+1))
  else
    echo "[OK]   $path mounted correctly (subvol=$sv)"
  fi
done

if [[ $mount_errors -gt 0 ]]; then
  echo
  echo "ERROR: One or more subvolumes failed to mount correctly."
  echo "Aborting to prevent corrupted install."
  exit 1
fi

echo
echo "All subvolumes successfully mounted and verified."

# Mount EFI
echo "Mounting EFI partition ($part1) to /mnt/boot ..."
mkdir -p /mnt/boot
mount "$part1" /mnt/boot

echo "Now we'll run pacstrap to install base system to /mnt."
confirm "Proceed to pacstrap base system to /mnt? (This will download & install packages)"

# Install base system (pacstrap) with requested packages
# Default packages: base base-devel linux linux-firmware sof-firmware amd-ucode intel-ucode limine sudo nano git networkmanager efibootmgr btrfs-progs
base_pkgs="base base-devel linux linux-firmware sof-firmware amd-ucode intel-ucode limine sudo nano git networkmanager efibootmgr btrfs-progs"
if [[ -n "${extra_packages// }" ]]; then
  echo "Including extra packages: $extra_packages"
  base_pkgs="$base_pkgs $extra_packages"
fi

echo "Running pacstrap -K /mnt $base_pkgs ..."
pacstrap -K /mnt $base_pkgs

# Generate fstab using labels (-L). Ensure file is created/overwritten (not appended repeatedly)
echo "Generating /mnt/etc/fstab with genfstab -L ..."
genfstab -L /mnt > /mnt/etc/fstab

echo
echo "pacstrap and fstab generation complete."

# Provide the user the chance to chroot now
echo
echo "Everything required for entering the new system is ready."
echo "We will now copy this script into the new system at /root/arch-install-automated.sh for later reference."
mkdir -p /mnt/root
cp -- "$0" /mnt/root/arch-install-automated.sh
chmod +x /mnt/root/arch-install-automated.sh

echo
echo "Final step: arch-chroot into /mnt to finish configuration."
echo "Type YES to proceed into chroot; anything else will exit leaving system mounted."
read -r final_go
if [[ "$final_go" == "YES" ]]; then
  echo "Executing post-chroot configuration automatically..."
  arch-chroot /mnt /bin/bash -c "$(declare -f post_chroot_setup); post_chroot_setup"
else
  echo "Exiting. System is mounted under /mnt; remember to chroot later with: arch-chroot /mnt"
  exit 0
fi
