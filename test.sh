#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run as root:
#   sudo ./migrate.sh --to <distro> --disk <disk> [--partitions <partitions>] [--erase whole|partitions] [--download-dir <dir>] [--root-partition <dev>] [--efi-partition <dev>]
#
# Supported distros: fedora, ubuntu, mint, arch, void
##############################

# Ensure running as root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Parse CLI args
TARGET_DISTRO=""
TARGET_DISK=""
DOWNLOAD_DIR="/root/Downloads"
ERASE_MODE="whole"
PARTITIONS_TO_ERASE=""
ROOT_PARTITION=""
EFI_PARTITION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --disk) TARGET_DISK="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        --erase) ERASE_MODE="${2,,}"; shift 2 ;;
        --partitions) PARTITIONS_TO_ERASE="$2"; shift 2 ;;
        --root-partition) ROOT_PARTITION="$2"; shift 2 ;;
        --efi-partition) EFI_PARTITION="$2"; shift 2 ;;
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

if [[ "$ERASE_MODE" == "partitions" && -z "$PARTITIONS_TO_ERASE" ]]; then
    echo "ERROR: --partitions is required when --erase is set to 'partitions'."
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

# Function to install dependencies based on the distro
install_deps() {
    echo "Detecting package manager and installing dependencies..."

    if command -v apt-get >/dev/null 2>&1; then
        echo "Using apt-get (Debian/Ubuntu/Mint)"
        apt-get update

        BASE_PKGS=(
            curl rsync squashfs-tools parted dosfstools e2fsprogs tar
        )
        GRUB_PKGS=(grub-common grub-pc)
        if [[ "$FIRMWARE" == "uefi" ]]; then
            GRUB_PKGS+=(grub-efi-amd64 shim-signed)
        fi

        apt-get install -y "${BASE_PKGS[@]}" "${GRUB_PKGS[@]}" || {
            echo "ERROR: Failed to install dependencies with apt-get"
            exit 1
        }

    elif command -v dnf >/dev/null 2>&1; then
        echo "Using dnf (Fedora)"
        BASE_PKGS=(
            curl rsync squashfs-tools parted dosfstools e2fsprogs tar
            grub2 efibootmgr shim
        )
        dnf install -y "${BASE_PKGS[@]}" || {
            echo "ERROR: Failed to install dependencies with dnf"
            exit 1
        }

    elif command -v pacman >/dev/null 2>&1; then
        echo "Using pacman (Arch)"
        BASE_PKGS=(
            curl rsync squashfs-tools parted dosfstools e2fsprogs tar
            grub efibootmgr
        )
        pacman -Sy --noconfirm "${BASE_PKGS[@]}" || {
            echo "ERROR: Failed to install dependencies with pacman"
            exit 1
        }

    elif command -v xbps-install >/dev/null 2>&1; then
        echo "Using xbps-install (Void Linux)"
        BASE_PKGS=(
            curl rsync squashfs-tools parted dosfstools e2fsprogs tar
            grub efibootmgr
        )
        xbps-install -Sy "${BASE_PKGS[@]}" || {
            echo "ERROR: Failed to install dependencies with xbps-install"
            exit 1
        }

    else
        echo "ERROR: No supported package manager found to install dependencies."
        echo "Please install required packages manually."
        exit 1
    fi
}

install_deps

# Check for grub-install or grub2-install command
if command -v grub-install >/dev/null 2>&1; then
    GRUB_INSTALL_CMD="grub-install"
elif command -v grub2-install >/dev/null 2>&1; then
    GRUB_INSTALL_CMD="grub2-install"
else
    echo "ERROR: Required command 'grub-install' or 'grub2-install' not found."
    exit 1
fi

# Check for grub-mkconfig or grub2-mkconfig command
if command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG_CMD="grub-mkconfig"
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG_CMD="grub2-mkconfig"
else
    echo "ERROR: Required command 'grub-mkconfig' or 'grub2-mkconfig' not found."
    exit 1
fi

# Validate necessary tools
for cmd in curl rsync unsquashfs grub-mkconfig mount umount parted mkfs.vfat mkfs.ext4 tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found."
        exit 1
    fi
done

mkdir -p "$DOWNLOAD_DIR"

declare -A ISO_URLS=(
    [fedora]="https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
    [ubuntu]="https://mirror.math.princeton.edu/pub/ubuntu-iso/releases/24.04.3/release/ubuntu-24.04.3-desktop-amd64.iso"
    [mint]="https://mirror.math.princeton.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
    [arch]="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-bootstrap-x86_64.tar.gz"
    [void]="https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.tar.xz"
)

if [[ -z "${ISO_URLS[$TARGET_DISTRO]:-}" ]]; then
    echo "ERROR: Unsupported target distro '$TARGET_DISTRO'."
    exit 1
fi

ISO_URL="${ISO_URLS[$TARGET_DISTRO]}"
ISO_FILE="$DOWNLOAD_DIR/$(basename "$ISO_URL")"

if [[ ! -f "$ISO_FILE" ]]; then
    echo "Downloading $TARGET_DISTRO ISO/tarball..."
    curl -L --fail --progress-bar -o "$ISO_FILE" "$ISO_URL" || exit 1
fi

# Partitioning
if [[ "$ERASE_MODE" == "whole" ]]; then
    echo "WARNING: This will ERASE ALL DATA on disk $TARGET_DISK!"
    read -rp "Type YES to continue: " confirm
    [[ "$confirm" != "YES" ]] && echo "Aborted." && exit 1

    if [[ "$FIRMWARE" == "uefi" ]]; then
        parted -s "$TARGET_DISK" mklabel gpt
        parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 boot on
        parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 100%
        EFI_PARTITION="${TARGET_DISK}p1"
        ROOT_PARTITION="${TARGET_DISK}p2"
    else
        parted -s "$TARGET_DISK" mklabel msdos
        parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
        ROOT_PARTITION="${TARGET_DISK}1"
    fi
elif [[ "$ERASE_MODE" == "partitions" ]]; then
    echo "WARNING: This will ERASE data on: $PARTITIONS_TO_ERASE"
    read -rp "Type YES to continue: " confirm
    [[ "$confirm" != "YES" ]] && echo "Aborted." && exit 1

    IFS=',' read -ra PART_ARR <<< "$PARTITIONS_TO_ERASE"
    for p in "${PART_ARR[@]}"; do
        dd if=/dev/zero of="$p" bs=1M count=10 status=progress || true
    done

    if [[ -z "$ROOT_PARTITION" ]]; then
        echo "ERROR: --root-partition is required with --erase partitions"
        exit 1
    fi

    if [[ "$FIRMWARE" == "uefi" && -z "$EFI_PARTITION" ]]; then
        echo "ERROR: --efi-partition is required in UEFI mode"
        exit 1
    fi
else
    echo "ERROR: Invalid --erase mode"
    exit 1
fi

# Format partitions
echo "Formatting partitions..."
[[ "$FIRMWARE" == "uefi" ]] && mkfs.vfat -F32 -n EFI "$EFI_PARTITION"
mkfs.ext4 -F -L ROOT "$ROOT_PARTITION"

# Mount
echo "Mounting partitions..."
mkdir -p /mnt/target
mount "$ROOT_PARTITION" /mnt/target
[[ "$FIRMWARE" == "uefi" ]] && mkdir -p /mnt/target/boot/efi && mount "$EFI_PARTITION" /mnt/target/boot/efi

# Extract filesystem
echo "Extracting filesystem..."
ISO_MOUNT="/mnt/iso_mount"
mkdir -p "$ISO_MOUNT"
case "$TARGET_DISTRO" in
    fedora)
        mount -o loop "$ISO_FILE" "$ISO_MOUNT"
        unsquashfs -f -d /mnt/target "$ISO_MOUNT/LiveOS/squashfs.img"
        ;;
    ubuntu|mint)
        mount -o loop "$ISO_FILE" "$ISO_MOUNT"
        unsquashfs -f -d /mnt/target "$ISO_MOUNT/casper/filesystem.squashfs"
        ;;
    arch)
        tar -xpf "$ISO_FILE" -C /mnt/target --strip-components=1
        ;;
    void)
        tar -xpf "$ISO_FILE" -C /mnt/target --strip-components=1
        ;;
    *)
        echo "ERROR: Unsupported distro."
        exit 1
        ;;
esac
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT"

# Prep for chroot
for fs in proc sys dev run; do
    mount --bind /$fs /mnt/target/$fs
done
cp /etc/resolv.conf /mnt/target/etc/resolv.conf

# Install GRUB in chroot
echo "Installing GRUB..."
chroot /mnt/target /bin/bash -c "
set -e

# Detect GRUB commands
if command -v grub-install >/dev/null 2>&1; then
    GRUB_INSTALL_CMD=grub-install
elif command -v grub2-install >/dev/null 2>&1; then
    GRUB_INSTALL_CMD=grub2-install
else
    echo 'ERROR: grub-install or grub2-install not found.'
    exit 1
fi

if command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG_CMD=grub-mkconfig
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG_CMD=grub2-mkconfig
else
    echo 'ERROR: grub-mkconfig or grub2-mkconfig not found.'
    exit 1
fi

# Install required packages
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y grub-common grub-pc grub-efi-amd64 shim-signed || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y grub2 shim efibootmgr || true
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm grub efibootmgr || true
elif command -v xbps-install >/dev/null 2>&1; then
    xbps-install -Sy grub efibootmgr || true
fi

# Install GRUB
if [ -d /sys/firmware/efi ]; then
    \$GRUB_INSTALL_CMD --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy || echo 'WARNING: EFI grub install failed.'
else
    \$GRUB_INSTALL_CMD --boot-directory=/boot \"$TARGET_DISK\" || echo 'WARNING: BIOS grub install failed.'
fi

\$GRUB_MKCONFIG_CMD -o /boot/grub/grub.cfg || echo 'WARNING: grub config generation failed.'
"

# Cleanup
for fs in run dev sys proc; do
    umount /mnt/target/$fs || true
done
[[ "$FIRMWARE" == "uefi" ]] && umount /mnt/target/boot/efi || true
umount /mnt/target || true

echo "Migration complete! Reboot into $TARGET_DISTRO."
exit 0
