#!/usr/bin/env bash
# arch-install-automated.sh
# Usage: run as root inside an Arch install/live environment.
set -euo pipefail

# ---------- helper functions ----------

confirm() {
  # Usage: confirm "message"
  local msg="$1"
  echo ""
  echo ">>> $msg"
  echo "Type YES to proceed, anything else to abort:"
  read -r answer
  if [[ "$answer" != "YES" ]]; then
    echo "Aborted by user."
    exit 1
  fi
}

choose_disk() {
  echo "Available disks:"
  # Show only whole-disk devices (no partitions) and their sizes & model where available using lsblk
  lsblk -dpno NAME,SIZE,MODEL | nl -w2 -s'. ' -v1
  echo ""
  echo "Enter the line number of the disk to use (will be wiped):"
  read -r line
  disk=$(lsblk -dpno NAME | sed -n "${line}p")
  if [[ -z "$disk" ]]; then
    echo "Invalid selection."
    exit 1
  fi
  echo "Selected disk: $disk"
}

post_chroot_setup() {

    # --- Interactive Locale and Timezone Setting ---
    read -p "Enter desired locale (e.g., en_US.UTF-8): " locale_gen
    read -p "Enter desired timezone (e.g., Europe/London or America/New_York): " timezone_loc
    echo "$locale_gen UTF-8" > /etc/locale.gen
    locale-gen
    # Extract language part (e.g., en_US) for LANG
    lang_var=$(echo "$locale_gen" | cut -d'.' -f1)
    echo "LANG=$lang_var.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    echo "archlinux" > /etc/hostname
    ln -sf /usr/share/zoneinfo/"$timezone_loc" /etc/localtime
    hwclock --systohc

   # --- Set root password interactively ---
    while true; do
        read -s -p "Enter new root password: " root_pass
        echo ""
        read -s -p "Confirm root password: " root_pass_confirm
        echo ""
        if [ "$root_pass" = "$root_pass_confirm" ]; then
            echo "root:$root_pass" | chpasswd
            echo "Root password set successfully."
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done

    # --- Create a standard user interactively ---
    read -p "Enter username for new user: " username
    
    while true; do
        read -s -p "Enter password for user '$username': " user_pass
        echo ""
        read -s -p "Confirm password for user '$username': " user_pass_confirm
        echo ""
        if [ "$user_pass" = "$user_pass_confirm" ]; then
            useradd -m -G wheel -s /bin/bash "$username"
            echo "$username:$user_pass" | chpasswd
            echo "User '$username' created successfully."
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
    
    # Enable sudo for wheel group
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    
    # Update packages
    pacman -Syu
    
    # Enable basic services
    systemctl enable fstrim.timer
    systemctl enable NetworkManager.service
    systemctl enable reflector.service

    # Install bootloader and add bootloader entry
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

    # Enable swap if present
    if grep -q "SWAP" /etc/fstab; then
        swapon -a
    fi
    
    # Enable ZRAM
    echo "[zram0]" >> /etc/systemd/zram-generator.conf
    echo "zram-size = min(ram)" >> /etc/systemd/zram-generator.conf
    echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

    echo ""
    echo "Post-chroot configuration complete!"
    sleep 5
}

# ---------- start ----------

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

echo "=== Arch automated partitioner + btrfs subvolume creator ==="
echo "WARNING: This script WILL DESTROY data on the selected disk."

# select disk
choose_disk

# Get current RAM in MiB for swap suggestion
# We'll use /proc/meminfo
mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
mem_mib=$(( (mem_kb + 1023) / 1024 ))
echo "Detected system RAM: ${mem_mib} MiB"

echo ""
echo "Do you want to enable a swap partition equal to RAM (${mem_mib} MiB)? (y/N)"
read -r use_swap_raw
use_swap="no"
if [[ "$use_swap_raw" =~ ^[Yy] ]]; then
  use_swap="yes"
fi

echo ""
echo "Any extra packages to install with pacstrap? (space-separated, or leave empty):"
read -r extra_packages

echo ""
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
parted -s "$disk" mklabel gpt

# Detect disk size in MiB
disk_mib=$(parted -sm "$disk" unit MiB print | awk -F: '/^/ {print $2}' | head -n1)

# Determine EFI size in MiB
if (( disk_mib < 65536 )); then        # < 64 GiB
  efi_mib=512
elif (( disk_mib < 262144 )); then     # < 256 GiB
  efi_mib=1024
else
  efi_mib=2048
fi

# Determine swap size (nearest GiB)
swap_gib=$(( (mem_mib + 1023) / 1024 ))   # ceil to GiB
swap_mib=$(( swap_gib * 1024 ))

efi_end_mib=$((1 + efi_mib))
next_start_mib=$efi_end_mib

# Create EFI
parted -s "$disk" mkpart primary fat32 1MiB "${efi_end_mib}MiB"
parted -s "$disk" set 1 boot on
part1="${disk}1"

if [[ "$use_swap" == "yes" ]]; then
  swap_end_mib=$((next_start_mib + swap_mib))
  parted -s "$disk" mkpart primary linux-swap "${next_start_mib}MiB" "${swap_end_mib}MiB"
  part2="${disk}2"

  parted -s "$disk" mkpart primary btrfs "${swap_end_mib}MiB" 100%
  part3="${disk}3"
else
  parted -s "$disk" mkpart primary btrfs "${next_start_mib}MiB" 100%
  part2="${disk}2"
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
umount -R /mnt

echo "Remounting Btrfs partition to /mnt before directory creation..."
mount -o compress=zstd,noatime,subvol=@ "$btrfs_part" /mnt

echo "Creating required mount directories..."
mkdir -p /mnt/{home,var/cache/pacman/pkg,var/tmp,var/log,.snapshots}

echo "Mounting subvolumes with options..."
mount -o compress=zstd,noatime,subvol=@home "$btrfs_part" /mnt/home
mount -o compress=zstd,noatime,subvol=@cache "$btrfs_part" /mnt/var/cache/pacman/pkg
mount -o compress=zstd,noatime,subvol=@tmp "$btrfs_part" /mnt/var/tmp
mount -o compress=zstd,noatime,subvol=@log "$btrfs_part" /mnt/var/log
mount -o compress=zstd,noatime,subvol=@snapshots "$btrfs_part" /mnt/.snapshots

echo "Verifying subvolume mounts..."

# Mount EFI
echo "Mounting EFI partition ($part1) to /mnt/boot ..."
mount --mkdir "$part1" /mnt/boot

# Install base system (pacstrap) with requested packages
confirm "Proceed to pacstrap base system to /mnt? (This will download & install packages)"
# --- Microcode Detection ---
cpu_vendor=$(lscpu | awk '/Vendor ID/ {print $3}')
microcode_pkg=""
if [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
  microcode_pkg="amd-ucode"
  echo "Detected AMD CPU, including amd-ucode."
elif [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  microcode_pkg="intel-ucode"
  echo "Detected Intel CPU, including intel-ucode."
else
  echo "Could not detect CPU vendor, including both amd-ucode and intel-ucode for safety."
  microcode_pkg="amd-ucode intel-ucode"
fi
# Default packages: base base-devel linux linux-firmware sof-firmware amd-ucode intel-ucode limine sudo nano git networkmanager btrfs-progs reflector zram-generator
base_pkgs="base base-devel linux linux-firmware sof-firmware $microcode_pkg limine sudo nano git networkmanager btrfs-progs reflector zram-generator"
if [[ -n "${extra_packages// }" ]]; then
  echo "Including extra packages: $extra_packages"
  base_pkgs="$base_pkgs $extra_packages"
fi
echo "Running pacstrap -K /mnt $base_pkgs ..."
pacstrap -K /mnt $base_pkgs

# Generate fstab using labels (-L). Ensure file is created/overwritten (not appended repeatedly)
echo "Generating /mnt/etc/fstab with genfstab -L ..."
genfstab -L /mnt > /mnt/etc/fstab

echo ""
echo "pacstrap and fstab generation complete."

# Provide the user the chance to chroot now
echo ""
echo "Everything required for entering the new system is ready."
echo "We will now copy this script into the new system at /root/arch-install-automated.sh for later reference."
mkdir -p /mnt/root
cp -- "$0" /mnt/root/arch-install-automated.sh
chmod +x /mnt/root/arch-install-automated.sh

echo ""
echo "Final step: arch-chroot into /mnt to finish configuration."
echo "Type YES to proceed into chroot; anything else will exit leaving system mounted."
read -r final_go
if [[ "$final_go" == "YES" ]]; then
  echo "Executing post-chroot configuration automatically..."
  arch-chroot /mnt /bin/bash -c "$(declare -f post_chroot_setup); post_chroot_setup"
  # Add bootloader entry
  echo ""
  echo "Adding EFI Bootloader Entry"
  efibootmgr \
  --create \
  --disk "$disk" \
  --part 1 \
  --label "Arch Linux Limine Bootloader" \
  --loader '\EFI\BOOT\BOOTX64.EFI' \
  --unicode
  echo "EFI boot entry created successfully."
  echo ""
  confirm "Would you like to reboot the system now?"
  echo "Unmounting disk to prepare for reboot"
  umount -R /mnt
  echo "Please reboot your system"
  confirm reboot
else
  echo "Exiting. System is mounted under /mnt; remember to chroot later with: arch-chroot /mnt"
  exit 0
fi
