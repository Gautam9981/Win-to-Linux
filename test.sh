#!/bin/bash
set -euo pipefail

##############################
# Migration Script Usage:
#
# Run as root (sudo ./migrate.sh --to <distro> --disk <disk> [--partitions <partitions>] [--erase whole|partitions] [--download-dir <dir>])
# Supported distros: fedora, ubuntu, mint, arch, void
# --erase: 'whole' erases entire disk, 'partitions' erases only specified partitions
# --partitions: comma-separated list of partitions (e.g. /dev/sda1,/dev/sda2) - required if --erase partitions
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
ERASE_MODE="whole"   # default to erase entire disk
PARTITIONS_TO_ERASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --disk) TARGET_DISK="$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        --erase) ERASE_MODE="${2,,}"; shift 2 ;;
        --partitions) PARTITIONS_TO_ERASE="$2"; shift 2 ;;
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
            echo "Installing grub EFI/BIOS packages for $TARGET_DISTRO"

            if [[ "$FIRMWARE" == "uefi" ]]; then
                # Try installing grub EFI packages carefully due to known issues
                apt-get install -y shim-signed grub-efi-amd64-signed grub-efi-amd64 || true
                apt-get install -f -y || true

                if ! apt-get install -y grub-efi-amd64; then
                    echo "WARNING: grub-efi-amd64 installation failed. You may need to install it manually."
                fi
            else
                if ! apt-get install -y grub-pc; then
                    echo "WARNING: grub-pc installation failed. You may need to install it manually."
                fi
            fi
        else
            # Broad grub install for other distros using apt
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

# Verify necessary commands exist
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found even after installation."
        exit 1
    fi
}

for cmd in curl rsync unsquashfs grub-install grub-mkconfig mount umount parted mkfs.vfat mkfs.ext4 tar; do
    check_command "$cmd"
done

mkdir -p "$DOWNLOAD_DIR"

declare -A ISO_URLS=(
    [fedora]="https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
    [ubuntu]="https://mirror.math.princeton.edu/pub/ubuntu-iso/releases/24.04.3/release/ubuntu-24.04.3-desktop-amd64.iso"
    [mint]="https://mirror.math.princeton.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
    [arch]="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-bootstrap-x86_64.tar.gz"
    [void]="https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso"
)

if [[ -z "${ISO_URLS[$TARGET_DISTRO]:-}" ]]; then
    echo "ERROR: Unsupported target distro '$TARGET_DISTRO'. Supported: fedora, ubuntu, mint, arch, void."
    exit 1
fi

ISO_URL="${ISO_URLS[$TARGET_DISTRO]}"
ISO_FILE="$DOWNLOAD_DIR/$(basename "$ISO_URL")"

# Download ISO or tarball if missing
if [[ -f "$ISO_FILE" ]]; then
    echo "ISO/tarball already exists at $ISO_FILE. Skipping download."
else
    echo "Downloading $TARGET_DISTRO ISO/tarball from $ISO_URL ..."
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --progress-bar -o "$ISO_FILE" "$ISO_URL" || { echo "Failed to download $TARGET_DISTRO rootfs."; exit 1; }
    else
        wget -q --show-progress -O "$ISO_FILE" "$ISO_URL" || { echo "Failed to download $TARGET_DISTRO rootfs."; exit 1; }
    fi
    echo "Download completed: $ISO_FILE"
fi

# Partitioning and wiping
if [[ "$ERASE_MODE" == "whole" ]]; then
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

elif [[ "$ERASE_MODE" == "partitions" ]]; then
    echo "WARNING: This will ERASE data on specified partitions: $PARTITIONS_TO_ERASE"
    read -rp "Type YES to continue wiping these partitions: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted by user."
        exit 1
    fi
    IFS=',' read -ra PART_ARR <<< "$PARTITIONS_TO_ERASE"
    for p in "${PART_ARR[@]}"; do
        echo "Wiping partition $p..."
        dd if=/dev/zero of="$p" bs=1M count=10 status=progress || true
    done
    # User must ensure root partition is specified explicitly here (or script enhanced to handle)
    echo "Please set ROOT_PARTITION environment variable or modify script to specify root partition."
    echo "Exiting."
    exit 1
else
    echo "ERROR: Unknown erase mode '$ERASE_MODE'. Supported: whole, partitions."
    exit 1
fi

# Format partitions
echo "Formatting partitions..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    mkfs.vfat -F32 -n EFI "$EFI_PARTITION"
fi
mkfs.ext4 -F -L ROOT "$ROOT_PARTITION"

# Mount target root
echo "Mounting target root partition..."
mkdir -p /mnt/target
mount "$ROOT_PARTITION" /mnt/target

if [[ "$FIRMWARE" == "uefi" ]]; then
    mkdir -p /mnt/target/boot/efi
    mount "$EFI_PARTITION" /mnt/target/boot/efi
fi

# Extract filesystem
echo "Extracting filesystem for $TARGET_DISTRO..."

case "$TARGET_DISTRO" in
    fedora)
        # Fedora uses squashfs.img in LiveOS
        SQUASH="$ISO_MOUNT/LiveOS/squashfs.img"
        # Mount ISO and extract squashfs
        ISO_MOUNT="/mnt/iso_mount"
        mkdir -p "$ISO_MOUNT"
        mount -o loop "$ISO_FILE" "$ISO_MOUNT"
        if [[ ! -f "$SQUASH" ]]; then
            echo "ERROR: Fedora squashfs image not found at $SQUASH"
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$SQUASH"
        umount "$ISO_MOUNT"
        rmdir "$ISO_MOUNT"
        ;;
    ubuntu|mint)
        # Ubuntu and Mint use casper filesystem.squashfs
        ISO_MOUNT="/mnt/iso_mount"
        mkdir -p "$ISO_MOUNT"
        mount -o loop "$ISO_FILE" "$ISO_MOUNT"
        SQUASH="$ISO_MOUNT/casper/filesystem.squashfs"
        if [[ ! -f "$SQUASH" ]]; then
            echo "ERROR: $TARGET_DISTRO squashfs image not found at $SQUASH"
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$SQUASH"
        umount "$ISO_MOUNT"
        rmdir "$ISO_MOUNT"
        ;;
    arch)
        # Extract Arch bootstrap tarball directly
        echo "Extracting Arch bootstrap tarball..."
        tar -xpf "$ISO_FILE" -C /mnt/target --strip-components=1
        ;;
    void)
        # Void uses squashfs.img under LiveOS
        ISO_MOUNT="/mnt/iso_mount"
        mkdir -p "$ISO_MOUNT"
        mount -o loop "$ISO_FILE" "$ISO_MOUNT"
        SQUASH="$ISO_MOUNT/LiveOS/squashfs.img"
        if [[ ! -f "$SQUASH" ]]; then
            echo "ERROR: Void squashfs image not found at $SQUASH"
            exit 1
        fi
        unsquashfs -f -d /mnt/target "$SQUASH"
        umount "$ISO_MOUNT"
        rmdir "$ISO_MOUNT"
        ;;
    *)
        echo "ERROR: Unsupported distro extraction logic."
        exit 1
        ;;
esac

echo "Filesystem extracted."

# Setup mounts for chroot
for fs in proc sys dev run; do
    mount --bind "/$fs" "/mnt/target/$fs"
done

# Copy resolv.conf for network in chroot
cp /etc/resolv.conf /mnt/target/etc/resolv.conf

# Install grub inside chroot
echo "Installing GRUB bootloader inside chroot..."

chroot /mnt/target /bin/bash -c "
set -e
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y grub-common grub-pc grub-efi shim-signed || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y grub2 shim || true
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm grub efibootmgr || true
elif command -v xbps-install >/dev/null 2>&1; then
    xbps-install -Sy grub || true
fi

if [[ \"$FIRMWARE\" == \"uefi\" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy || {
        echo 'WARNING: grub-install failed inside chroot for EFI.'
    }
else
    grub-install --boot-directory=/boot \"$TARGET_DISK\" || {
        echo 'WARNING: grub-install failed inside chroot for BIOS.'
    }
fi

grub-mkconfig -o /boot/grub/grub.cfg || {
    echo 'WARNING: grub-mkconfig failed inside chroot.'
}
"

# Cleanup mounts
echo "Cleaning up mounts..."
for fs in run dev sys proc; do
    umount /mnt/target/$fs || true
done

if [[ "$FIRMWARE" == "uefi" ]]; then
    umount /mnt/target/boot/efi || true
fi
umount /mnt/target || true

echo "Migration complete! Reboot and select your new $TARGET_DISTRO system."

exit 0
