# A.L.I.A.S. — Arch Linux Installation Automation Script

This repository contains an automated Arch Linux installation script designed to simplify and streamline the installation process while retaining full transparency and user control. The script prepares the disk, configures the filesystem using Btrfs subvolumes, installs the base system, configures the environment inside the new installation, and optionally installs GPU drivers and KDE Plasma.

The installation remains interactive, prompting the user for necessary decisions such as disk selection, swap configuration, locale, timezone, and user credentials.

<img width="911" height="558" alt="image" src="https://github.com/user-attachments/assets/f39b043f-a7b8-4c88-bd08-4621fb15fe6b" />

<img width="911" height="558" alt="image" src="https://github.com/user-attachments/assets/920ef794-0a82-42b8-80f8-6ad23b0655c3" />

<img width="911" height="558" alt="TUI" src="https://github.com/user-attachments/assets/58bb1167-8602-426d-9f32-f562fadd37be" />

---

## Features

### Disk and Filesystem

* Interactive disk selector.
* Automatic disk cleanup if selected disk already has partitions.
* GPT partitioning with `sgdisk`.
  * EFI system partition (4 GB, FAT32)
  * Optional swap partition (user-defined size)
  * Btrfs root partition
* Btrfs formatting and subvolume setup:

  * `@` (root)
  * `@home`
  * `@cache`
  * `@tmp`
  * `@log`
  * `@snapshots`

### System Installation

* Automatic CPU microcode detection (Intel/AMD).
* Installs Arch base system with key packages:
  * base, base-devel, linux, linux-firmware, sof-firmware, sudo, git, nano, networkmanager, btrfs-progs, reflector, zram-generator, limine
* Allows optional installation of used defined additional packages.
* Locale and timezone configuration.
* Root password creation and user account setup with wheel group.
* Enables system services:

  * NetworkManager
  * Reflector
  * TRIM Support
  * Zram compressed page block device.

### Bootloader

* Installs the Limine bootloader.
* Generates bootloader configuration `/boot/limine.conf`.
* Automatic EFI boot entry using `efibootmgr`.

### GPU Driver Installation (Optional)

Auto-detects the system's GPU and installs appropriate driver for:

* Intel
* AMD
* NVIDIA

Supports:

* Desktop systems
* Laptops with hybrid graphics (Intel + NVIDIA, AMD + NVIDIA)

### Optional KDE Plasma Installation

* kde plasma, plasma-login-manager, dolphin, konsole, and firefox

---

## Requirements

To use this script, you must:

* Boot into the Arch Linux live ISO.
* Be running in UEFI mode.
* Have an active internet connection.
* Run the script as root.

---

## Usage

### 1. Download the script

```
curl -L -o alias.sh \
https://github.com/MowMdown/arch-install-script/releases/download/v2/arch-install-script.sh
```

### 2. Make the script executable

```sh
chmod +x alias.sh
```

### 3. Run the script

```sh
./ais.sh
```

You must run it as root. The script will stop if not executed with root privileges.

---

## Partition Layout Overview

| Partition              | Size         | Type                 | Description                |
| ---------------------- | ------------ | -------------------- | -------------------------- |
| /dev/sdX1              | 4 GB         | EFI System Partition | Bootloader                 |
| /dev/sdX2              | User-defined | Swap (optional)      | Swap partition             |
| /dev/sdX3 or /dev/sdX2 | Remainder    | Btrfs                | Root filesystem            |

---

## Btrfs Subvolumes

| Subvolume  | Mount point           |
| ---------- | --------------------- |
| @          | /                     |
| @home      | /home                 |
| @cache     | /var/cache/pacman/pkg |
| @tmp       | /var/tmp              |
| @log       | /var/log              |
| @snapshots | /.snapshots           |

---

## What the Script Configures Inside the Chroot

* Enables multilib repository.
* Syncronizes package database.
* Configure system locale and keyboard layout.
* Sets the hostname.
* Configures timezone and syncs hardware clock.
* Set root password and create user account.
* Configures sudo access for the wheel group.
* Optionally installs:
  * GPU drivers
  * KDE Plasma
* Installs and configures Limine bootloader.
* Enables essential services such as NetworkManager and fstrim.

---

## What Happens After Installation

When installation completes:

* A fully bootable Arch Linux system is written to the target disk.
* The EFI bootloader entry is created automatically.

---

## Notes

* This script is intended for users who prefer a guided installation while still maintaining full insight into what their system is doing.
* Swap partition is optional. If disabled, no swap partition is created.
* On laptop systems with hybrid GPUs, NVIDIA PRIME support is automatically configured for laptops with Nvidia GPUs.
