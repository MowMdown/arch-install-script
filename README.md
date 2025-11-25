# Arch Linux Automated Installer Script

**Filename:** `arch-install.sh`  
**Environment:** Must be run as `root` inside an Arch Linux live environment.

---

## Overview

This script automates the installation of Arch Linux on a target disk. It handles disk partitioning, formatting, Btrfs subvolume creation, base system installation, and post-install configuration, including user creation, locale, services, and bootloader setup.

** WARNING:** This script will **wipe the selected disk completely**. Use with caution.

---

## Features

1. **Interactive Disk Selection**
   - Lists all available disks with sizes and models.
   - Prompts for user confirmation before wiping and partitioning.

2. **Partitioning**
   - Creates a GPT partition table.
   - Default partitions:
     - 2 GiB EFI system partition (`EFI`)
     - Optional swap partition equal to system RAM
     - Remaining space as Btrfs root (`ARCH`)
   - Uses `parted` for precise MiB alignment.

3. **Btrfs Setup**
   - Formats the root partition as Btrfs.
   - Creates standard subvolumes:
     - `@` (root)
     - `@home`, `@cache`, `@tmp`, `@log`, `@snapshots`
   - Mounts subvolumes with `compress=zstd,noatime` options.
   - Mounts EFI partition at `/mnt/boot`.

4. **System Installation**
   - Installs base packages using `pacstrap`:
     - `base`, `base-devel`, `linux`, `linux-firmware`, `sof-firmware`, CPU microcode packages, `limine`, `sudo`, `nano`, `git`, `networkmanager`, `btrfs-progs`, `reflector`, `zram-generator`
   - Allows optional extra packages.
   - Generates `/etc/fstab` using partition labels.

5. **Post-Chroot Configuration**
   - Locale and keyboard setup (`en_US.UTF-8`, US keymap).
   - Hostname setup (`archlinux` by default).
   - Timezone and hardware clock configuration.
   - Interactive root password setup.
   - Interactive creation of a user with password.
   - Enables sudo for the `wheel` group.
   - Enables essential services:
     - `NetworkManager`, `fstrim.timer`, `reflector.service`
   - Sets up Limine bootloader with basic configuration.
   - Configures swap if present and enables ZRAM for improved memory performance.

6. **Bootloader Setup**
   - Copies Limine EFI binary to `/boot/EFI/BOOT/BOOTX64.EFI`.
   - Adds an EFI boot entry using `efibootmgr`.

---

## Usage

1. Boot into an Arch Linux live environment.
2. Download or copy the script to the live environment.
3. Run: `chmod +x ./arch-install.sh`

4. Follow interactive prompts for:
   - Disk selection
   - Swap usage (y/N)
   - Extra packages (optional packages)
   - Root and user passwords
   - Final confirmation to chroot and configure the system

5. After post-chroot setup, optionally reboot into the newly installed system.

---

## Requirements

- Arch Linux live environment
- Internet connection

---

## Notes

- Script assumes `/mnt` as the temporary mount point for installation.
- Uses Btrfs subvolume structure suitable for snapshotting and system rollback.
- Enables basic services for a functional system after installation.
- Compatible with both Intel and AMD systems with microcode packages installed automatically.

---

## Disclaimer

This script is provided **as-is**. It will destroy all data on the target disk. Make sure to back up any important data before proceeding. Use at your own risk.

