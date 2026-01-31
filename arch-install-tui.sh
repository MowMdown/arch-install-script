#!/bin/bash
set -euo pipefail

pacman -Sy --noconfirm dialog

# ─── CONFIG (globals set by each step, consumed downstream) ──────────────────
disk=""
use_swap="no"
mem_gib=0
nvme_4kn_applied=false
declare -a pkg_list=()
full_locale=""
timezone=""
username=""
REFLECTOR_PID=""
REFLECTOR_STATUS=0

# ─── DIALOG HELPERS ──────────────────────────────────────────────────────────
# All dialog output goes to fd 3 so we can capture it cleanly.
# stderr is where dialog draws its UI; stdout/fd3 is where it writes results.

DIALOG_TITLE="Arch Linux Installer"
DW=70   # default dialog width
DH=20   # default dialog height

d_msg()       { dialog --title "$DIALOG_TITLE" --msgbox "$1" "${2:-12}" "${3:-$DW}"; }
d_yesno()     { dialog --title "$DIALOG_TITLE" --yesno "$1" "${2:-12}" "${3:-$DW}"; }
d_input()     { dialog --title "$DIALOG_TITLE" --inputbox "$1" "${2:-10}" "${3:-$DW}" "${4:-}" 2>&1 1>&3 3>&-; }
d_pass()      { dialog --title "$DIALOG_TITLE" --insecure --passwordbox "$1" "${2:-8}" "${3:-$DW}" 2>&1 1>&3 3>&-; }
d_menu()      { dialog --title "$DIALOG_TITLE" --menu "$1" "${2:-$DH}" "${3:-$DW}" "${4:-8}" "${@:5}" 2>&1 1>&3 3>&-; }
d_checklist() { dialog --title "$DIALOG_TITLE" --checklist "$1" "${2:-$DH}" "${3:-$DW}" "${4:-10}" "${@:5}" 2>&1 1>&3 3>&-; }
d_gauge()     { dialog --title "$DIALOG_TITLE" --gauge "$1" "${2:-6}" "${3:-$DW}" "${4:-0}"; }
d_infobox()   { dialog --title "$DIALOG_TITLE" --infobox "$1" "${2:-3}" "${3:-$DW}"; }
d_tailbox()   { dialog --title "$DIALOG_TITLE" --tailbox "$1" "${2:-$DH}" "${3:-$DW}"; }

# Error box — shows message then exits unless caller handles it
d_error()     { dialog --title "ERROR" --msgbox "$1" 8 $DW; }

# ─── STEP 1: WARNING ─────────────────────────────────────────────────────────
step_warning() {
    d_yesno \
"WARNING: DESTRUCTIVE OPERATION\n\n\
This installer will completely wipe the selected disk.\n\
All data on that device will be permanently lost.\n\
This action cannot be undone.\n\n\
Do you want to proceed?" 14 $DW

    # yesno returns 0 for Yes, 1 for No
    if [[ $? -ne 0 ]]; then
        d_msg "Aborted by user." 6
        exit 0
    fi
}

# ─── STEP 2: DISK SELECTION ──────────────────────────────────────────────────
step_choose_disk() {
    # Build the menu items from lsblk: "name" "size  model"
    local -a menu_args=()
    while IFS=$'\t' read -r name size model; do
        [[ -z "$name" ]] && continue
        menu_args+=("$name" "${size}  ${model:-unknown}")
    done < <(lsblk -dpno NAME,SIZE,MODEL | sed 's/  */\t/g')

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        d_error "No disks detected."
        exit 1
    fi

    disk=$(d_menu \
        "Select the target disk (will be wiped):" \
        16 $DW 8 \
        "${menu_args[@]}")
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }
    [[ -z "$disk" ]] && { d_error "No disk selected."; step_choose_disk; return; }

    d_msg "Selected disk:\n\n  $disk\n\nThis disk will be completely wiped." 10
}

# ─── STEP 3: SWAP ────────────────────────────────────────────────────────────
step_set_swap() {
    local choice
    choice=$(d_menu \
        "Enable a swap partition?" \
        10 $DW 2 \
        "yes" "Create a swap partition" \
        "no"  "No swap")
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

    use_swap="$choice"

    if [[ "$use_swap" == "yes" ]]; then
        _prompt_swap_size
    fi
}

_prompt_swap_size() {
    while true; do
        local input
        input=$(d_input "Enter swap size in GiB (whole number):" 8 40)
        local rc=$?

        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -gt 0 ]]; then
            mem_gib=$input
            d_infobox "Swap set to ${mem_gib} GiB." 3
            sleep 1
            return
        fi

        d_error "Invalid input. Enter a positive whole number."
    done
}

# ─── STEP 4: NVME 4Kn (only if NVMe disk) ───────────────────────────────────
step_nvme_4kn() {
    [[ "$disk" != /dev/nvme* ]] && return

    d_infobox "Querying NVMe namespace info..." 3
    sleep 1

    local ns_info
    ns_info=$(nvme id-ns -H "$disk" 2>/dev/null) || {
        d_msg "Could not query NVMe namespace.\nSkipping 4Kn check." 8
        return
    }

    local current_lbaf lba1_line data_size
    current_lbaf=$(echo "$ns_info" | awk '/in use/ {print $NF}')
    lba1_line=$(echo "$ns_info" | grep "LBA Format  1" || true)

    if [[ -z "$lba1_line" ]]; then
        d_msg "LBA Format 1 not supported on this drive.\nSkipping 4Kn." 8
        return
    fi

    data_size=$(echo "$lba1_line" | sed -n 's/.*Data Size: *\([0-9]\+\) bytes.*/\1/p')

    if [[ "$data_size" != "4096" ]]; then
        d_msg "LBA Format 1 is ${data_size} bytes (not 4096).\nSkipping 4Kn." 8
        return
    fi

    if [[ "$current_lbaf" == "1" ]]; then
        d_msg "NVMe is already formatted to 4Kn." 6
        nvme_4kn_applied=true
        return
    fi

    # Offer the format
    d_yesno \
"NVMe 4Kn Support Detected\n\n\
Your drive supports 4096-byte logical blocks (4Kn).\n\
This can improve performance but WILL ERASE ALL DATA\n\
on $disk.\n\n\
Format to 4Kn now?" 14 $DW

    if [[ $? -eq 0 ]]; then
        d_infobox "Formatting NVMe namespace to 4Kn..." 3
        nvme format --lbaf=1 "$disk"
        blockdev --rereadpt "$disk" 2>/dev/null || true
        partprobe "$disk" 2>/dev/null || true
        nvme_4kn_applied=true
        d_msg "NVMe namespace formatted to 4Kn." 6
    else
        d_msg "4Kn format skipped." 6
    fi
}

# ─── STEP 5: PACKAGES ────────────────────────────────────────────────────────
step_packages() {
    local -a base=(
        "base"              "on"
        "base-devel"        "on"
        "linux"             "on"
        "linux-firmware"    "on"
        "sof-firmware"      "on"
        "limine"            "on"
        "sudo"              "on"
        "nano"              "on"
        "git"               "on"
        "networkmanager"    "on"
        "btrfs-progs"       "on"
        "reflector"         "on"
        "zram-generator"    "on"
    )

    # Detect microcode
    local vendor
    vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    case "$vendor" in
        GenuineIntel) base+=("intel-ucode" "on")  ;;
        AuthenticAMD) base+=("amd-ucode"  "on")  ;;
        *)            base+=("intel-ucode" "on" "amd-ucode" "on") ;;
    esac

    local selected
    selected=$(dialog --title "$DIALOG_TITLE" \
        --checklist "Base packages (toggle with space):" \
        22 $DW 16 \
        "${base[@]}" \
        2>&1 1>&3 3>&-)
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

    # Parse the quoted output into the array
    pkg_list=($selected)  # word-split on spaces; dialog quotes items

    # Offer to add extra packages
    _prompt_extra_packages

    d_msg "Packages selected:\n\n$(printf '  %s\n' "${pkg_list[@]}")" 20 50
}

_prompt_extra_packages() {
    while true; do
        local extra
        extra=$(d_input \
            "Add extra packages (space-separated).\n\
Leave blank to finish." \
            8 $DW)
        local rc=$?

        [[ $rc -ne 0 ]] && return  # Cancel = done adding
        [[ -z "$extra" ]] && return # Empty = done adding

        # Append each token
        for pkg in $extra; do
            pkg_list+=("$pkg")
        done

        d_infobox "Added: $extra" 3
        sleep 1
    done
}

# ─── STEP 6: LOCALE & TIMEZONE ───────────────────────────────────────────────
step_locale_timezone() {
    _prompt_locale
    _prompt_timezone
}

_prompt_locale() {
    # Build menu from /usr/share/i18n/SUPPORTED (filter to common .UTF-8 ones)
    local -a items=()
    while read -r loc _; do
        [[ "$loc" == *.UTF-8 ]] || continue
        items+=("$loc" " ")
    done < /usr/share/i18n/SUPPORTED

    if [[ ${#items[@]} -eq 0 ]]; then
        # Fallback: manual input
        _prompt_locale_manual
        return
    fi

    full_locale=$(d_menu \
        "Select locale:" \
        22 $DW 12 \
        "${items[@]}")
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }
    [[ -z "$full_locale" ]] && { d_error "No locale selected."; _prompt_locale; }
}

_prompt_locale_manual() {
    while true; do
        local input
        input=$(d_input "Enter locale (e.g. en_US.UTF-8):" 8 40)
        local rc=$?

        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        if grep -qxF "$input UTF-8" /usr/share/i18n/SUPPORTED; then
            full_locale="$input"
            return
        fi
        d_error "Locale '$input' not supported. Try again."
    done
}

_prompt_timezone() {
    # Build menu from zoneinfo
    local -a items=()
    while IFS= read -r tz; do
        items+=("$tz" " ")
    done < <(find /usr/share/zoneinfo -type f | sed 's|/usr/share/zoneinfo/||' | grep -E '^[A-Z]' | sort)

    timezone=$(d_menu \
        "Select timezone:" \
        22 $DW 12 \
        "${items[@]}")
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }
    [[ -z "$timezone" ]] && { d_error "No timezone selected."; _prompt_timezone; }
}

# ─── STEP 7: USERS ───────────────────────────────────────────────────────────
step_users() {
    _prompt_root_password
    _prompt_new_user
}

_prompt_root_password() {
    while true; do
        local pass1 pass2
        pass1=$(d_pass "Enter root password:" 8 40)
        local rc=$?
        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        pass2=$(d_pass "Confirm root password:" 8 40)
        rc=$?
        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        if [[ "$pass1" == "$pass2" ]]; then
            # Store for chroot; not echoed anywhere
            ROOT_PASS="$pass1"
            d_infobox "Root password set." 3
            sleep 1
            return
        fi
        d_error "Passwords do not match. Try again."
    done
}

_prompt_new_user() {
    # Username
    while true; do
        username=$(d_input "Enter new username:" 8 40)
        local rc=$?
        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            break
        fi
        d_error "Invalid username.\nMust start with a-z or _, lowercase only."
    done

    # User password
    while true; do
        local pass1 pass2
        pass1=$(d_pass "Password for '$username':" 8 40)
        local rc=$?
        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        pass2=$(d_pass "Confirm password for '$username':" 8 40)
        rc=$?
        [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

        if [[ "$pass1" == "$pass2" ]]; then
            USER_PASS="$pass1"
            d_infobox "User '$username' configured." 3
            sleep 1
            return
        fi
        d_error "Passwords do not match. Try again."
    done
}

# ─── STEP 8: DESKTOP ─────────────────────────────────────────────────────────
step_desktop() {
    local choice
    choice=$(d_menu \
        "Install a desktop environment?" \
        12 $DW 4 \
        "kde"  "KDE Plasma (plasma-meta, sddm, dolphin, konsole, firefox)" \
        "none" "No desktop environment")
    local rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }
    DESKTOP_CHOICE="$choice"
}

# ─── STEP 9: GPU DRIVERS ─────────────────────────────────────────────────────
step_gpu() {
    # System type
    local sys_type
    sys_type=$(d_menu \
        "Is this system a desktop or laptop?" \
        10 $DW 2 \
        "Desktop" "Discrete GPU(s) only" \
        "Laptop"  "May have integrated + discrete (hybrid)")
    local rc=$?
    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }
    SYSTEM_TYPE="$sys_type"

    # Detect GPUs
    local gpu_list
    gpu_list=$(lspci -d ::03xx 2>/dev/null | grep -i "VGA\|3D" || true)

    if [[ -z "$gpu_list" ]]; then
        d_msg "No supported GPUs detected.\nSkipping driver installation." 8
        GPU_PKGS=""
        return
    fi

    # Build checklist from detected GPUs
    local -a check_args=()
    local has_amd=false has_nvidia=false has_intel=false

    if echo "$gpu_list" | grep -qi "AMD";    then has_amd=true;    check_args+=("AMD"    "AMD Radeon (mesa, vulkan-radeon)"                  "off"); fi
    if echo "$gpu_list" | grep -qi "NVIDIA"; then has_nvidia=true; check_args+=("NVIDIA" "NVIDIA (nvidia-open, nvidia-utils, nvidia-prime)" "off"); fi
    if echo "$gpu_list" | grep -qi "Intel";  then has_intel=true;  check_args+=("Intel"  "Intel (mesa, vulkan-intel)"                       "off"); fi

    d_infobox "Detected GPUs:\n$gpu_list" 6
    sleep 1

    local selected
    selected=$(dialog --title "$DIALOG_TITLE" \
        --checklist "Select GPU drivers to install:" \
        14 $DW 6 \
        "${check_args[@]}" \
        2>&1 1>&3 3>&-)
    rc=$?

    [[ $rc -ne 0 ]] && { d_msg "Aborted."; exit 0; }

    # Build package string from selection
    GPU_PKGS=""
    local amd_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader"
    local nvidia_pkgs="nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils nvidia-prime"
    local intel_pkgs="mesa lib32-mesa vulkan-mesa-layers lib32-vulkan-mesa-layers vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader"

    [[ "$selected" == *AMD*    ]] && GPU_PKGS+="$amd_pkgs "
    [[ "$selected" == *NVIDIA* ]] && GPU_PKGS+="$nvidia_pkgs "
    [[ "$selected" == *Intel*  ]] && GPU_PKGS+="$intel_pkgs "
}

# ─── STEP 10: REVIEW ─────────────────────────────────────────────────────────
step_review() {
    local swap_str="Disabled"
    [[ "$use_swap" == "yes" ]] && swap_str="${mem_gib} GiB"

    local nvme_str="N/A"
    [[ "$disk" == /dev/nvme* ]] && { $nvme_4kn_applied && nvme_str="Applied" || nvme_str="Skipped"; }

    local desktop_str="None"
    [[ "${DESKTOP_CHOICE:-}" == "kde" ]] && desktop_str="KDE Plasma"

    local gpu_str="None"
    [[ -n "${GPU_PKGS:-}" ]] && gpu_str="$(echo $GPU_PKGS | tr ' ' '\n' | sort -u | tr '\n' ' ')"

    d_yesno \
"Review Configuration\n\
─────────────────────────────────\n\
Disk:         $disk\n\
Swap:         $swap_str\n\
NVMe 4Kn:     $nvme_str\n\
Locale:       $full_locale\n\
Timezone:     $timezone\n\
Root user:    (password set)\n\
User:         $username\n\
Desktop:      $desktop_str\n\
GPU drivers:  $gpu_str\n\
Packages:     ${#pkg_list[@]} selected\n\
─────────────────────────────────\n\n\
Proceed with installation?" 22 $DW

    if [[ $? -ne 0 ]]; then
        d_msg "Installation cancelled." 6
        exit 0
    fi
}

# ─── STEP 11: INSTALL ────────────────────────────────────────────────────────
step_install() {
    # We run the install phases sequentially and pipe progress to a gauge.
    # Each phase echoes its percentage when done.

    local tmplog
    tmplog=$(mktemp)

    (
        local pct=0
        _phase() { echo "$1"; pct=$2; echo $pct; }

        # Determine partition separator for NVMe
        local sep=""
        [[ "$disk" == /dev/nvme* ]] && sep="p"

        # ── Wipe ──
        _phase "Wiping partition table..." 2
        sgdisk --zap-all "$disk" >> "$tmplog" 2>&1
        wipefs -a "$disk" >> "$tmplog" 2>&1

        # ── Partition ──
        _phase "Creating partitions..." 8
        sgdisk -n 1:0:4G -I -t1:EF00 "$disk" >> "$tmplog" 2>&1
        local part1="${disk}${sep}1"
        local btrfs_part

        if [[ "$use_swap" == "yes" ]]; then
            sgdisk -n 2:0:"+${mem_gib}G" -I -t2:8200 "$disk" >> "$tmplog" 2>&1
            sgdisk -n 3:0:0 -I -t3:8300 "$disk" >> "$tmplog" 2>&1
            local part2="${disk}${sep}2"
            btrfs_part="${disk}${sep}3"
        else
            sgdisk -n 2:0:0 -I -t2:8300 "$disk" >> "$tmplog" 2>&1
            btrfs_part="${disk}${sep}2"
        fi
        partprobe "$disk" 2>/dev/null || true
        sleep 1

        # ── Format ──
        _phase "Formatting partitions..." 16
        mkfs.fat -F 32 -n EFI "$part1" >> "$tmplog" 2>&1
        if [[ "$use_swap" == "yes" ]]; then
            mkswap -L SWAP "${disk}${sep}2" >> "$tmplog" 2>&1
            swapon "${disk}${sep}2" >> "$tmplog" 2>&1
        fi
        mkfs.btrfs -f -L ARCH -n 32k "$btrfs_part" >> "$tmplog" 2>&1

        # ── Subvolumes ──
        _phase "Creating btrfs subvolumes..." 24
        local base_opts="noatime,compress=zstd:3,discard=async,ssd,space_cache=v2"
        mount -o subvolid=5 "$btrfs_part" /mnt
        for subv in @ @home @cache @tmp @log @snapshots; do
            btrfs subvolume create "/mnt/$subv" >> "$tmplog" 2>&1
        done
        umount -R /mnt
        sleep 1

        # ── Mount ──
        _phase "Mounting subvolumes..." 32
        declare -A subvol_mounts=(["@"]="." ["@home"]="home" ["@cache"]="var/cache/pacman/pkg" \
            ["@tmp"]="var/tmp" ["@log"]="var/log" ["@snapshots"]=".snapshots")

        for subvol in @ @home @cache @tmp @log @snapshots; do
            local target="/mnt/${subvol_mounts[$subvol]}"
            [[ "$target" != "/mnt/." ]] && mkdir -p "$target"
            mount -o "${base_opts},subvol=${subvol}" "$btrfs_part" "$target"
        done
        mkdir -p /mnt/boot
        mount "$part1" /mnt/boot

        # ── Pacstrap ──
        _phase "Installing base packages (this may take a while)..." 40
        pacstrap -K /mnt ${pkg_list[*]} >> "$tmplog" 2>&1
        _phase "Pacstrap complete." 60

        # ── Fstab ──
        _phase "Generating fstab..." 62
        genfstab -L /mnt > /mnt/etc/fstab

        # ── Chroot setup ──
        _phase "Entering chroot..." 64

        # Write a chroot script that runs inside the new system
        cat > /mnt/root/_chroot_setup.sh <<CHROOT_EOF
#!/bin/bash
set -euo pipefail

# ── Multilib ──
sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/ { s/^[[:space:]]*#//; n; s/^[[:space:]]*#// }' /etc/pacman.conf
pacman -Syuq --noconfirm

# ── Locale ──
locale_line="${full_locale} UTF-8"
if grep -q "^#\s*\${locale_line}" /etc/locale.gen; then
    sed -i "s|^#\s*\(\${locale_line}.*\)|\1|" /etc/locale.gen
elif ! grep -q "^\${locale_line}" /etc/locale.gen; then
    echo "\${locale_line}" >> /etc/locale.gen
fi
locale-gen
echo "LANG=${full_locale}" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "archlinux" > /etc/hostname
ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
hwclock --systohc

# ── Users ──
echo "root:${ROOT_PASS}" | chpasswd
useradd -m -G wheel -s /bin/bash "${username}"
echo "${username}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── Services ──
systemctl enable fstrim.timer NetworkManager.service reflector.service

# ── Desktop ──
CHROOT_EOF

        if [[ "${DESKTOP_CHOICE:-}" == "kde" ]]; then
            cat >> /mnt/root/_chroot_setup.sh <<'CHROOT_EOF'
pacman -Sq --needed --noconfirm plasma-meta sddm dolphin konsole firefox
systemctl enable sddm.service
CHROOT_EOF
        fi

        # ── GPU drivers inside chroot ──
        if [[ -n "${GPU_PKGS:-}" ]]; then
            echo "pacman -Sq --needed --noconfirm ${GPU_PKGS}" >> /mnt/root/_chroot_setup.sh
        fi

        # ── Bootloader ──
        cat >> /mnt/root/_chroot_setup.sh <<'CHROOT_EOF'
# ── Limine ──
mkdir -p /boot/EFI/BOOT
pacman -Sq --needed --noconfirm limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

cat > /boot/limine.conf <<LIMINE
timeout: 5
default_entry: 1

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/initramfs-linux.img
    cmdline: root=LABEL=ARCH rootflags=subvol=@ rw
LIMINE

# ── Zram ──
cat >> /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram)
compression-algorithm = zstd
ZRAM

# ── Initramfs ──
mkinitcpio -P
CHROOT_EOF

        chmod +x /mnt/root/_chroot_setup.sh
        _phase "Running chroot configuration..." 68
        arch-chroot /mnt /bin/bash /root/_chroot_setup.sh >> "$tmplog" 2>&1
        _phase "Chroot complete." 88

        # ── EFI boot entry ──
        _phase "Adding EFI boot entry..." 92
        efibootmgr --create --disk "$disk" --part 1 \
            --label "Arch Linux Limine Bootloader" \
            --loader '\EFI\BOOT\BOOTX64.EFI' --unicode >> "$tmplog" 2>&1

        # ── Cleanup ──
        _phase "Cleaning up..." 96
        rm -f /mnt/root/_chroot_setup.sh

        _phase "Installation complete." 100

    ) | dialog --title "$DIALOG_TITLE" --gauge "Installing..." 8 $DW 0

    # Check if chroot script actually ran cleanly
    if [[ -s "$tmplog" ]]; then
        # Offer to show log on error (non-zero exit would have been caught by set -e inside subshell)
        d_yesno "Installation finished.\n\nShow installation log?" 10 $DW
        if [[ $? -eq 0 ]]; then
            dialog --title "Installation Log" --textbox "$tmplog" 22 $DW
        fi
    fi

    rm -f "$tmplog"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: Must be run as root."; exit 1; }

    # Kick off reflector in the background immediately
    reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist > /dev/null 2>&1 &
    REFLECTOR_PID=$!

    # Run each step; open fd 3 globally for dialog input capture
    exec 3>&1

    step_warning
    step_choose_disk
    step_set_swap
    step_nvme_4kn
    step_packages

    # Wait for reflector before we need mirrors (pacstrap)
    d_infobox "Waiting for mirror list to update..." 3
    wait $REFLECTOR_PID && REFLECTOR_STATUS=0 || REFLECTOR_STATUS=$?
    if [[ $REFLECTOR_STATUS -ne 0 ]]; then
        d_msg "Mirror update failed. Continuing with existing mirrorlist." 8
    fi

    step_locale_timezone
    step_users
    step_desktop
    step_gpu
    step_review
    step_install

    exec 3>&-

    # Post-install reboot prompt
    d_yesno "Installation complete!\n\nReboot now?" 8 $DW
    if [[ $? -eq 0 ]]; then
        umount -R /mnt 2>/dev/null || true
        sleep 1
        reboot
    else
        d_msg "System is mounted at /mnt.\nYou can inspect or chroot manually." 8
    fi
}

main "$@"
