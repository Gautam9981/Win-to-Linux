#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run as root (sudo ./migrate.sh --to <distro> --disk <disk> [--download-dir <dir>])
# Supported distros: fedora, ubuntu, mint, arch, void
##############################

# Ensure running as root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Parse CLI args early for TARGET_DISTRO, needed in install_deps
TARGET_DISTRO=""
TARGET_DISK=""
DOWNLOAD_DIR="/root/Downloads"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --disk) TARGET_DISK="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_DISTRO" || -z "$TARGET_DISK" ]]; then
    echo "ERROR: --to and --disk parameters are required."
    exit 1
fi

if [[ ! -b "$TARGET_DISK" ]]; then
    echo "ERROR: Specified disk '$TARGET_DISK' is not a block device."
    exit 1
fi

# Detect firmware (UEFI vs BIOS) early for dependency decisions
detect_firmware() {
    if [ -d /sys/firmware/efi ]; then
        echo "uefi"
    else
        echo "bios"
    fi
}
FIRMWARE=$(detect_firmware)
echo "Detected firmware: $FIRMWARE"

# Install dependencies based on available package manager and detected firmware
install_deps() {
    echo "Detecting package manager..."

    if command -v apt-get >/dev/null 2>&1; then
        echo "Using apt-get"
        apt-get update

        # Install common dependencies
        apt-get install -y curl rsync squashfs-tools parted dosfstools e2fsprogs || {
            echo "ERROR: Failed installing basic dependencies."
            exit 1
        }

        # Special handling for grub on Ubuntu/Mint due to grub-efi-amd64 issues
        if [[ "$TARGET_DISTRO" == "ubuntu" || "$TARGET_DISTRO" == "mint" ]]; then
            echo "Installing grub EFI/BIOS packages for $TARGET_DISTRO"

            if [[ "$FIRMWARE" == "uefi" ]]; then
                # Install necessary EFI packages
                apt-get install -y shim-signed grub-efi-amd64-signed grub-efi-amd64 || true

                # Try fixing broken dependencies
                apt-get install -f -y || true

                # Retry grub packages install to fix potential dependency issues
                if ! apt-get install -y grub-efi-amd64; then
                    echo "WARNING: grub-efi-amd64 installation failed. You may need to install it manually."
                fi
            else
                if ! apt-get install -y grub-pc; then
                    echo "WARNING: grub-pc installation failed. You may need to install it manually."
                fi
            fi
        else
            # For other distros, install a broad grub package list if apt-get available
            apt-get install -y grub2 grub-common grub-pc grub-efi grub2-common || true
        fi

    elif command -v dnf >/dev/null 2>&1; then
        echo "Using dnf"
        dnf install -y curl rsync squashfs-tools grub2 parted dosfstools e2fsprogs || {
            echo "ERROR: Failed installing dependencies via dnf."
            exit 1
        }

    elif command -v pacman >/dev/null 2>&1; then
        echo "Using pacman"
        pacman -Sy --noconfirm curl rsync squashfs-tools grub parted dosfstools e2fsprogs || {
            echo "ERROR: Failed installing dependencies via pacman."
            exit 1
        }

    elif command -v xbps-install >/dev/null 2>&1; then
        echo "Using xbps-install"
        xbps-install -Sy curl rsync squashfs-tools grub parted dosfstools e2fsprogs || {
            echo "ERROR: Failed installing dependencies via xbps-install."
            exit 1
        }
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

# Partitioning

echo "WARNING: This will ERASE ALL DATA on disk $TARGET_DISK!"
read -rp "Type YES to continue partitioning $TARGET_DISK: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted by user."
    exit 1
fi

echo "Creating new partition table on $TARGET_DISK..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    parted -s "$TARGET_DISK" mklabel gpt
else
    parted -s "$TARGET_DISK" mklabel msdos
fi

if [[ "$FIRMWARE" == "uefi" ]]; then
    echo "Creating EFI System Partition and Linux root partition on $TARGET_DISK..."
    parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 boot on
    parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 100%
    EFI_PARTITION="${TARGET_DISK}p1"
    ROOT_PARTITION="${TARGET_DISK}p2"
else
    echo "Creating single Linux root partition on $TARGET_DISK..."
    parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
    ROOT_PARTITION="${TARGET_DISK}1"
fi

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
    if ! chroot /mnt/target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy; then
        echo "WARNING: grub-install failed. You may need to fix the EFI bootloader manually."
    fi

    echo "Generating GRUB config..."
    chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg

    # Unmount pseudo filesystems
    for fs in proc sys dev; do
        umount /mnt/target/$fs
    done
else
    echo "Installing GRUB BIOS..."
    if ! grub-install --boot-directory=/mnt/target/boot "$TARGET_DISK"; then
        echo "WARNING: grub-install failed. You may need to fix the BIOS bootloader manually."
    fi

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
