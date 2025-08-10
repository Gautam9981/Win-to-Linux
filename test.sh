#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run this script AS ROOT (sudo ./migrate.sh)
#
# It downloads the specified distro ISO, prepares a target partition,
# extracts the live filesystem, and installs GRUB bootloader.
#
# Supported distros: fedora, ubuntu, mint, arch, void
#
# Example usage:
#   sudo ./migrate.sh --from fedora --to arch --partition /dev/sda3
#
# Parameters:
#   --from       Source distro (for info only, script always installs target)
#   --to         Target distro (fedora, ubuntu, mint, arch, void)
#   --partition  Target partition device (e.g. /dev/sda3)
#   --download-dir Directory to store downloaded ISOs (default: /root/Downloads)
#
##############################

# Check for root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Check required commands
check_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found."
        if [[ -n "$pkg" ]]; then
            echo "Please install package: $pkg"
        fi
        exit 1
    fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: Neither curl nor wget found. Please install one of them."
    exit 1
fi
check_command rsync "rsync"
check_command unsquashfs "squashfs-tools"
check_command grub-install "grub2"    # package names may vary
check_command grub-mkconfig "grub2"
check_command mount "mount"
check_command umount "umount"

# Default download directory
DOWNLOAD_DIR="/root/Downloads"

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) SOURCE_DISTRO="${2,,}"; shift 2 ;;
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --partition) TARGET_PARTITION="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [[ -z "${TARGET_DISTRO:-}" ]] || [[ -z "${TARGET_PARTITION:-}" ]]; then
    echo "ERROR: --to and --partition parameters are required."
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR"

# ISO URLs by distro - latest stable versions (2025-08-10)
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

echo "Downloading $TARGET_DISTRO ISO from $ISO_URL ..."
if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "$ISO_FILE" "$ISO_URL" || { echo "Failed to download ISO."; exit 1; }
else
    wget -q --show-progress -O "$ISO_FILE" "$ISO_URL" || { echo "Failed to download ISO."; exit 1; }
fi
echo "Download completed: $ISO_FILE"

# Mount ISO to a temporary mount point
ISO_MOUNT="/mnt/iso_mount"
mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_FILE" "$ISO_MOUNT"

# Prepare target partition
echo "Unmounting $TARGET_PARTITION if mounted..."
umount "$TARGET_PARTITION" 2>/dev/null || true

echo "Formatting $TARGET_PARTITION as ext4..."
mkfs.ext4 -F "$TARGET_PARTITION"

echo "Mounting $TARGET_PARTITION to /mnt/target..."
mount "$TARGET_PARTITION" /mnt/target

# Extract filesystem from ISO to target partition
echo "Extracting live filesystem for $TARGET_DISTRO..."

case "$TARGET_DISTRO" in
    fedora)
        # Fedora livesystem squashfs usually in LiveOS/squashfs.img
        FEDORA_SQUASH="$ISO_MOUNT/LiveOS/squashfs.img"
        if [[ ! -f "$FEDORA_SQUASH" ]]; then
            echo "Fedora squashfs not found at expected location."
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$FEDORA_SQUASH"
        ;;
    ubuntu|mint)
        # Ubuntu & Mint use casper/filesystem.squashfs
        UBUNTU_SQUASH="$ISO_MOUNT/casper/filesystem.squashfs"
        if [[ ! -f "$UBUNTU_SQUASH" ]]; then
            echo "Ubuntu/Mint squashfs not found at expected location."
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$UBUNTU_SQUASH"
        ;;
    arch)
        # Arch ISO is a live system, just copy contents
        rsync -aHAX --exclude=/arch/boot/x86_64/airootfs.sfs "$ISO_MOUNT/" /mnt/target/
        # Extract arch root filesystem
        AROOTFS="$ISO_MOUNT/arch/boot/x86_64/airootfs.sfs"
        if [[ -f "$AROOTFS" ]]; then
            unsquashfs -f -d /mnt/target "$AROOTFS"
        else
            echo "Arch root filesystem not found, copying entire ISO contents instead."
        fi
        ;;
    void)
        # Void Linux ISO is usually a live rootfs squashfs at root/livefs.squashfs or root/livefs.squashfs
        VOID_SQUASH="$ISO_MOUNT/livefs.squashfs"
        if [[ ! -f "$VOID_SQUASH" ]]; then
            echo "Void Linux squashfs not found at expected location."
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$VOID_SQUASH"
        ;;
    *)
        echo "Extraction for $TARGET_DISTRO is not implemented."
        exit 1
        ;;
esac

echo "Filesystem extracted."

# Mount necessary pseudo filesystems for chroot
for fs in proc sys dev; do
    mount --bind /$fs /mnt/target/$fs
done

# Install GRUB bootloader on the disk containing the target partition
DISK=$(lsblk -no pkname "$TARGET_PARTITION")
if [[ -z "$DISK" ]]; then
    echo "Cannot determine disk for partition $TARGET_PARTITION"
    exit 1
fi
DISK="/dev/$DISK"

echo "Installing GRUB on $DISK..."
chroot /mnt/target grub-install "$DISK"

echo "Generating GRUB config..."
chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg

# Cleanup mounts
for fs in proc sys dev; do
    umount /mnt/target/$fs
done
umount /mnt/target
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT"

echo "Migration complete! Reboot and select your new $TARGET_DISTRO system."

exit 0
