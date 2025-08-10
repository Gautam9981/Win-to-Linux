#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run as root (sudo ./migrate.sh)
# Supports fedora, ubuntu, mint, arch, void
##############################

# Check for root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Check commands
check_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found."
        [[ -n "$pkg" ]] && echo "Please install package: $pkg"
        exit 1
    fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: Neither curl nor wget found. Please install one of them."
    exit 1
fi

check_command rsync "rsync"
check_command unsquashfs "squashfs-tools"
check_command grub-install "grub2"
check_command grub-mkconfig "grub2"
check_command mount "mount"
check_command umount "umount"

# Defaults
DOWNLOAD_DIR="/root/Downloads"

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) SOURCE_DISTRO="${2,,}"; shift 2 ;;
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --partition) TARGET_PARTITION="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [[ -z "${TARGET_DISTRO:-}" || -z "${TARGET_PARTITION:-}" ]]; then
    echo "ERROR: --to and --partition parameters are required."
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR"

declare -A ISO_URLS=(
    [fedora]="https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
    [ubuntu]="https://mirror.math.princeton.edu/pub/ubuntu-iso/releases/24.04.3/release/ubuntu-24.04.3-desktop-amd64.iso"
    [mint]="https://mirror.math.princeton.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
    [arch]="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
    [void]="https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso"
)

if [[ -z "${ISO_URLS[$TARGET_DISTRO]:-}" ]]; then
    echo "ERROR: Unsupported target distro '$TARGET_DISTRO'. Supported: fedora, ubuntu, mint, arch, void."
    exit 1
fi

ISO_URL="${ISO_URLS[$TARGET_DISTRO]}"
ISO_FILE="$DOWNLOAD_DIR/$(basename "$ISO_URL")"

# Download ISO if missing
if [[ -f "$ISO_FILE" ]]; then
    echo "ISO already exists at $ISO_FILE. Skipping download."
else
    echo "Downloading $TARGET_DISTRO ISO from $ISO_URL ..."
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --progress-bar -o "$ISO_FILE" "$ISO_URL" || { echo "Failed to download ISO."; exit 1; }
    else
        wget -q --show-progress -O "$ISO_FILE" "$ISO_URL" || { echo "Failed to download ISO."; exit 1; }
    fi
    echo "Download completed: $ISO_FILE"
fi

# Mount ISO
ISO_MOUNT="/mnt/iso_mount"
if mountpoint -q "$ISO_MOUNT"; then
    echo "Unmounting previous ISO mount at $ISO_MOUNT..."
    umount "$ISO_MOUNT"
fi
mkdir -p "$ISO_MOUNT"
echo "Mounting ISO to $ISO_MOUNT..."
mount -o loop "$ISO_FILE" "$ISO_MOUNT"
echo "ISO mounted."

# Prepare target partition
echo "Unmounting $TARGET_PARTITION if mounted..."
umount "$TARGET_PARTITION" 2>/dev/null || true

echo "Formatting $TARGET_PARTITION as ext4..."
mkfs.ext4 -F "$TARGET_PARTITION"

echo "Mounting $TARGET_PARTITION to /mnt/target..."
mkdir -p /mnt/target
mount "$TARGET_PARTITION" /mnt/target
echo "Partition mounted."

# Function to detect squashfs image path based on distro
detect_squashfs() {
    local base="$1"
    declare -a candidates=()
    case "$TARGET_DISTRO" in
        fedora)
            candidates=("$base/LiveOS/squashfs.img" "$base/LiveOS/rootfs.img")
            ;;
        ubuntu|mint)
            candidates=("$base/casper/filesystem.squashfs" "$base/casper/filesystem.img")
            ;;
        arch)
            candidates=("$base/arch/boot/x86_64/airootfs.sfs")
            ;;
        void)
            candidates=("$base/LiveOS/squashfs.img" "$base/livefs.squashfs" "$base/squashfs.img")
            ;;
        *)
            echo "ERROR: Unsupported distro for squashfs detection."
            exit 1
            ;;
    esac

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Extract filesystem
echo "Extracting live filesystem for $TARGET_DISTRO..."

SQUASH=$(detect_squashfs "$ISO_MOUNT")
if [[ -z "$SQUASH" ]]; then
    echo "ERROR: Could not find squashfs image for $TARGET_DISTRO in $ISO_MOUNT."
    exit 1
fi

echo "Using squashfs image at: $SQUASH"
echo "Extracting $SQUASH..."
unsquashfs -f -d /mnt/target "$SQUASH"

DISK=$(lsblk -no pkname "$TARGET_PARTITION")
if [[ -z "$DISK" ]]; then
    echo "ERROR: Cannot determine disk for partition $TARGET_PARTITION"
    exit 1
fi
DISK="/dev/$DISK"

# Decide if we chroot or not
if [[ "$TARGET_DISTRO" == "ubuntu" || "$TARGET_DISTRO" == "mint" || "$TARGET_DISTRO" == "fedora" ]]; then
    echo "Mounting pseudo filesystems for chroot..."
    for fs in proc sys dev; do
        mount --bind /$fs /mnt/target/$fs
    done

    echo "Installing GRUB inside chroot on $DISK..."
    chroot /mnt/target grub-install "$DISK"

    echo "Generating GRUB config inside chroot..."
    chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg

    echo "Cleaning up mounts..."
    for fs in proc sys dev; do
        umount /mnt/target/$fs
    done

else
    # For arch and void, install grub from host environment and skip chroot
    echo "Installing GRUB from host environment onto $DISK..."
    grub-install --boot-directory=/mnt/target/boot "$DISK"

    echo ""
    echo "IMPORTANT:"
    echo "For $TARGET_DISTRO, you should boot into your new system after reboot"
    echo "and run the following command to generate the GRUB configuration:"
    echo "    sudo grub-mkconfig -o /boot/grub/grub.cfg"
    echo ""
fi

# Cleanup
umount /mnt/target
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT"

echo "Migration complete! Reboot and select your new $TARGET_DISTRO system."

exit 0
