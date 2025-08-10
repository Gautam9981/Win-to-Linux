#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run as root (sudo ./migrate.sh --to <distro> --partition <partition> [--download-dir <dir>])
# Supported distros: fedora, ubuntu, mint, arch, void
##############################

# Ensure running as root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Install dependencies based on available package manager
install_deps() {
    local deps=(curl rsync squashfs-tools grub2 grub-common grub-pc grub-efi grub2-common parted dosfstools e2fsprogs)

    echo "Detecting package manager..."
    if command -v apt-get >/dev/null 2>&1; then
        echo "Using apt-get"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${deps[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        echo "Using dnf"
        dnf install -y "${deps[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        echo "Using pacman"
        pacman -Sy --noconfirm "${deps[@]}"
    elif command -v xbps-install >/dev/null 2>&1; then
        echo "Using xbps-install"
        xbps-install -Sy "${deps[@]}"
    else
        echo "ERROR: No supported package manager found to install dependencies."
        echo "Please install curl, rsync, squashfs-tools, grub, parted, dosfstools, e2fsprogs manually."
        exit 1
    fi
}

install_deps

# Check that required commands exist after install
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found even after installation."
        exit 1
    fi
}

for cmd in curl rsync unsquashfs grub-install grub-mkconfig mount umount parted mkfs.vfat mkfs.ext4; do
    check_command "$cmd"
done

# Parse CLI args
TARGET_DISTRO=""
TARGET_PARTITION=""
DOWNLOAD_DIR="/root/Downloads"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --partition) TARGET_PARTITION="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_DISTRO" || -z "$TARGET_PARTITION" ]]; then
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

# Detect firmware (UEFI vs BIOS)
detect_firmware() {
    if [ -d /sys/firmware/efi ]; then
        echo "UEFI detected."
        echo "uefi"
    else
        echo "BIOS detected."
        echo "bios"
    fi
}

FIRMWARE=$(detect_firmware)

# Partitioning

echo "Preparing target partition $TARGET_PARTITION..."

if mountpoint -q "$TARGET_PARTITION"; then
    echo "Unmounting $TARGET_PARTITION..."
    umount "$TARGET_PARTITION"
fi

DISK=$(lsblk -no pkname "$TARGET_PARTITION")
if [[ -z "$DISK" ]]; then
    echo "ERROR: Cannot determine disk for partition $TARGET_PARTITION"
    exit 1
fi
DISK="/dev/$DISK"

# Wipe partition table on disk - BE CAREFUL, WARNING TO USER
echo "WARNING: This will erase all data on $DISK!"
read -rp "Type YES to continue partitioning $DISK: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted by user."
    exit 1
fi

# Create GPT or MBR based on firmware
echo "Creating new partition table on $DISK..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    parted -s "$DISK" mklabel gpt
else
    parted -s "$DISK" mklabel msdos
fi

# Partition layout:
# For UEFI:
#   1) EFI System Partition (512M, FAT32)
#   2) Linux root partition (rest)
# For BIOS:
#   1) Linux root partition (whole disk)

if [[ "$FIRMWARE" == "uefi" ]]; then
    echo "Creating EFI System Partition and Linux root partition..."
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
else
    echo "Creating single Linux root partition..."
    parted -s "$DISK" mkpart primary ext4 1MiB 100%
    ROOT_PARTITION="${DISK}1"
fi

# Format partitions
echo "Formatting partitions..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    mkfs.vfat -F32 -n EFI "$EFI_PARTITION"
fi
mkfs.ext4 -F -L ROOT "$ROOT_PARTITION"

# Mount target partition(s)
echo "Mounting target partition(s)..."
mkdir -p /mnt/target

if [[ "$FIRMWARE" == "uefi" ]]; then
    mount "$ROOT_PARTITION" /mnt/target
    mkdir -p /mnt/target/boot/efi
    mount "$EFI_PARTITION" /mnt/target/boot/efi
else
    mount "$ROOT_PARTITION" /mnt/target
fi

# Extract filesystem

echo "Extracting live filesystem for $TARGET_DISTRO..."

case "$TARGET_DISTRO" in
    fedora)
        SQUASH="$ISO_MOUNT/LiveOS/squashfs.img"
        ;;
    ubuntu|mint)
        SQUASH="$ISO_MOUNT/casper/filesystem.squashfs"
        ;;
    arch)
        # Copy everything except the compressed rootfs, then extract it separately
        rsync -aHAX --exclude=/arch/boot/x86_64/airootfs.sfs "$ISO_MOUNT/" /mnt/target/
        SQUASH="$ISO_MOUNT/arch/boot/x86_64/airootfs.sfs"
        ;;
    void)
        SQUASH="$ISO_MOUNT/livefs.squashfs"
        ;;
    *)
        echo "ERROR: Unsupported distro extraction logic."
        exit 1
        ;;
esac

if [[ -f "$SQUASH" ]]; then
    echo "Extracting squashfs $SQUASH to /mnt/target ..."
    unsquashfs -f -d /mnt/target "$SQUASH"
else
    echo "ERROR: Expected squashfs image not found at $SQUASH"
    exit 1
fi

echo "Filesystem extracted."

# Install GRUB bootloader

echo "Installing GRUB bootloader..."

if [[ "$FIRMWARE" == "uefi" ]]; then
    # Mount necessary pseudo filesystems for chroot
    for fs in proc sys dev; do
        mount --bind /$fs /mnt/target/$fs
    done

    echo "Installing GRUB EFI..."
    chroot /mnt/target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy

    echo "Generating GRUB config..."
    chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg

    # Unmount pseudo filesystems
    for fs in proc sys dev; do
        umount /mnt/target/$fs
    done
else
    echo "Installing GRUB BIOS..."
    grub-install --boot-directory=/mnt/target/boot "$DISK"

    echo ""
    echo "IMPORTANT:"
    echo "Please boot into your new system after reboot and run:"
    echo "    sudo grub-mkconfig -o /boot/grub/grub.cfg"
    echo ""
fi

# Cleanup

echo "Cleaning up mounts..."
umount /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target 2>/dev/null || true
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT" 2>/dev/null || true

echo "Migration complete! Reboot and select your new $TARGET_DISTRO system."

exit 0
