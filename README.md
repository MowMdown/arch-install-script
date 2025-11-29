# Arch Linux Automated Installation Script

This repository contains an automated Arch Linux installation script designed to simplify and streamline the installation process while retaining full transparency and user control. The script prepares the disk, configures the filesystem using Btrfs subvolumes, installs the base system, configures the environment inside the new installation, and optionally installs GPU drivers and KDE Plasma.

The installation remains interactive, prompting the user for necessary decisions such as disk selection, swap configuration, locale, timezone, and user credentials.

---

## Features

### Disk and Filesystem

* Interactive disk selector.
* Automatic disk cleanup if selected disk already has partitions.
* GPT partitioning with `sgdisk`.
* Partitions as follows:

  * EFI system partition (2 GiB, FAT32)
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

  * base, base-devel, linux, linux-firmware
  * sof-firmware, sudo, git, nano, networkmanager
  * btrfs-progs, reflector, zram-generator, limine
* Optional installation of user-provided extra packages.
* Locale and timezone configuration.
* Root password creation and user account setup with wheel group.
* Enables system services:

  * NetworkManager
  * reflector
  * fstrim.timer
  * zram-generator

### Bootloader

* Installs the Limine bootloader.
* Generates `/boot/limine.conf`.
* Creates EFI entry using `efibootmgr`.

### GPU Driver Installation (Optional)

Auto-detects the system's GPU and installs appropriate driver for:

* Intel
* AMD
* NVIDIA

Supports:

* Desktop systems
* Laptops with hybrid graphics (Intel + NVIDIA, AMD + NVIDIA)

### Optional KDE Plasma Installation

* kde plasma, sddm, dolphin, konsole, and firefox

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

Place the script in your Arch ISO environment.

### 2. Make the script executable

```sh
chmod +x arch-install.sh
```

### 3. Run the script

```sh
./arch-install.sh
```

You must run it as root. The script will stop if not executed with root privileges.

---

## Partition Layout Overview

The script creates the following partitions:

| Partition              | Size         | Type                 | Description                |
| ---------------------- | ------------ | -------------------- | -------------------------- |
| /dev/sdX1              | 2 GiB        | EFI System Partition | Contains Limine bootloader |
| /dev/sdX2              | User-defined | Swap (optional)      | Swap partition             |
| /dev/sdX3 or /dev/sdX2 | Remainder    | Btrfs                | Main filesystem            |

---

## Btrfs Subvolumes

The script creates and mounts the following subvolumes:

| Subvolume  | Mount point           |
| ---------- | --------------------- |
| @          | /                     |
| @home      | /home                 |
| @cache     | /var/cache/pacman/pkg |
| @tmp       | /var/tmp              |
| @log       | /var/log              |
| @snapshots | /.snapshots           |

All subvolumes are mounted with:

---

## What the Script Configures Inside the Chroot

* Enables multilib repository.
* Updates all packages.
* Sets system locale and keyboard layout.
* Sets the hostname.
* Configures timezone and hardware clock.
* Creates root and user accounts.
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
