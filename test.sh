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

# Detect firmware (UEFI vs BIOS)
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

        apt-get install -y curl rsync squashfs-tools parted dosfstools e2fsprogs || {
            echo "ERROR: Failed installing basic dependencies."
            exit 1
        }

        if [[ "$TARGET_DISTRO" == "ubuntu" || "$TARGET_DISTRO" == "mint" ]]; then
            if [[ "$FIRMWARE" == "uefi" ]]; then
                apt-get install -y shim-signed grub-efi-amd64-signed grub-efi-amd64 || true
                apt-get install -f -y || true
                if ! apt-get install -y grub-efi-amd64; then
                    echo "WARNING: grub-efi-amd64 installation failed."
                fi
            else
                if ! apt-get install -y grub-pc; then
                    echo "WARNING: grub-pc installation failed."
                fi
            fi
        else
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

# Check required commands after install
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found after installation."
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

# Prompt user: erase whole disk or use partitions
echo
echo "Disk preparation options:"
echo "1) Erase whole disk '$TARGET_DISK' and create partitions"
echo "2) Use existing partitions on '$TARGET_DISK'"
read -rp "Select option [1 or 2]: " disk_option

EFI_PARTITION=""
ROOT_PARTITION=""

if [[ "$disk_option" == "1" ]]; then
    echo "WARNING: This will ERASE ALL DATA on disk $TARGET_DISK!"
    read -rp "Type YES to confirm erasing $TARGET_DISK: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted by user."
        exit 1
    fi

    echo "Creating new partition table on $TARGET_DISK..."
    if [[ "$FIRMWARE" == "uefi" ]]; then
        parted -s "$TARGET_DISK" mklabel gpt
        echo "Creating EFI System Partition and Linux root partition on $TARGET_DISK..."
        parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 boot on
        parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 100%
    else
        parted -s "$TARGET_DISK" mklabel msdos
        echo "Creating single Linux root partition on $TARGET_DISK..."
        parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
    fi

    # Determine partition names (handle /dev/sdX vs /dev/nvmeXn1 style)
    if [[ "$TARGET_DISK" =~ nvme ]]; then
        if [[ "$FIRMWARE" == "uefi" ]]; then
            EFI_PARTITION="${TARGET_DISK}p1"
            ROOT_PARTITION="${TARGET_DISK}p2"
        else
            ROOT_PARTITION="${TARGET_DISK}p1"
        fi
    else
        if [[ "$FIRMWARE" == "uefi" ]]; then
            EFI_PARTITION="${TARGET_DISK}1"
            ROOT_PARTITION="${TARGET_DISK}2"
        else
            ROOT_PARTITION="${TARGET_DISK}1"
        fi
    fi

elif [[ "$disk_option" == "2" ]]; then
    echo "Using existing partitions."

    if [[ "$FIRMWARE" == "uefi" ]]; then
        read -rp "Enter EFI partition device (e.g. /dev/sda1): " EFI_PARTITION
        if [[ ! -b "$EFI_PARTITION" ]]; then
            echo "ERROR: EFI partition device '$EFI_PARTITION' is not valid."
            exit 1
        fi
    fi

    read -rp "Enter root partition device (e.g. /dev/sda2): " ROOT_PARTITION
    if [[ ! -b "$ROOT_PARTITION" ]]; then
        echo "ERROR: Root partition device '$ROOT_PARTITION' is not valid."
        exit 1
    fi
else
    echo "Invalid selection."
    exit 1
fi

echo "Formatting partitions..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    mkfs.vfat -F32 -n EFI "$EFI_PARTITION"
fi
mkfs.ext4 -F -L ROOT "$ROOT_PARTITION"

# Mount target partition(s)
echo "Mounting target partition(s)..."
mkdir -p /mnt/target

mount "$ROOT_PARTITION" /mnt/target

if [[ "$FIRMWARE" == "uefi" ]]; then
    mkdir -p /mnt/target/boot/efi
    mount "$EFI_PARTITION" /mnt/target/boot/efi
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
        echo "Copying Arch Linux files except rootfs is usually not squashfs but livefs..."
        # Arch ISO uses a compressed root filesystem, extract from rootfs.img
        SQUASH="$ISO_MOUNT/arch/x86_64/airootfs.sfs"
        if [[ ! -f "$SQUASH" ]]; then
            SQUASH="$ISO_MOUNT/arch/airootfs.sfs"
        fi
        ;;
    void)
        # Void ISO often has base rootfs tarball instead of squashfs
        echo "Downloading minimal Void rootfs tarball instead of squashfs..."
        VOID_ROOTFS_URL="https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.tar.xz"
        ROOTFS_TARBALL="$DOWNLOAD_DIR/void-rootfs.tar.xz"
        if [[ ! -f "$ROOTFS_TARBALL" ]]; then
            curl -L --fail --progress-bar -o "$ROOTFS_TARBALL" "$VOID_ROOTFS_URL"
        fi
        ;;
    *)
        echo "Unsupported distro $TARGET_DISTRO for filesystem extraction."
        exit 1
        ;;
esac

if [[ "$TARGET_DISTRO" == "void" ]]; then
    echo "Extracting Void rootfs tarball..."
    tar -xJf "$ROOTFS_TARBALL" -C /mnt/target
else
    echo "Extracting squashfs from $SQUASH ..."
    unsquashfs -f -d /mnt/target "$SQUASH"
fi

# Mount necessary pseudo filesystems for chroot grub install
mount --bind /dev /mnt/target/dev
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys

echo "Installing grub bootloader..."

# grub-install inside chroot with correct target
if [[ "$FIRMWARE" == "uefi" ]]; then
    mount --bind /sys/firmware/efi/efivars /mnt/target/sys/firmware/efi/efivars || true
    chroot /mnt/target /bin/bash -c "
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy || true
        grub-mkconfig -o /boot/grub/grub.cfg || true
    "
else
    chroot /mnt/target /bin/bash -c "
        grub-install --target=i386-pc --recheck $TARGET_DISK || true
        grub-mkconfig -o /boot/grub/grub.cfg || true
    "
fi

# Cleanup mounts
umount /mnt/target/dev
umount /mnt/target/proc
umount /mnt/target/sys

if [[ "$FIRMWARE" == "uefi" ]]; then
    umount /mnt/target/boot/efi
fi
umount /mnt/target
umount "$ISO_MOUNT"

echo "Migration to $TARGET_DISTRO complete. You can reboot now."
