#!/bin/bash
set -euo pipefail

# Check root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo)."
    exit 1
fi

# Check commands function
check_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found."
        [[ -n "$pkg" ]] && echo "Please install package: $pkg"
        exit 1
    fi
}

for cmd in curl rsync unsquashfs grub-install grub-mkconfig mount umount parted mkfs.vfat mkfs.ext4; do
    check_command "$cmd" ""
done

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET_DISTRO="${2,,}"; shift 2 ;;
        --disk) TARGET_DISK="$2"; shift 2 ;;   # Use disk, not partition, for partitioning
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) echo "Unknown param $1"; exit 1 ;;
    esac
done

if [[ -z "${TARGET_DISTRO:-}" || -z "${TARGET_DISK:-}" ]]; then
    echo "ERROR: --to and --disk parameters are required."
    exit 1
fi

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/root/Downloads}"
mkdir -p "$DOWNLOAD_DIR"

declare -A ISO_URLS=(
    [fedora]="https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
    [ubuntu]="https://mirror.math.princeton.edu/pub/ubuntu-iso/releases/24.04.3/release/ubuntu-24.04.3-desktop-amd64.iso"
    [mint]="https://mirror.math.princeton.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
    [arch]="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
    [void]="https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso"
)

if [[ -z "${ISO_URLS[$TARGET_DISTRO]:-}" ]]; then
    echo "ERROR: Unsupported distro $TARGET_DISTRO."
    exit 1
fi

ISO_URL="${ISO_URLS[$TARGET_DISTRO]}"
ISO_FILE="$DOWNLOAD_DIR/$(basename "$ISO_URL")"

# Download ISO if needed
if [[ ! -f "$ISO_FILE" ]]; then
    echo "Downloading $TARGET_DISTRO ISO..."
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --progress-bar -o "$ISO_FILE" "$ISO_URL"
    else
        wget -q --show-progress -O "$ISO_FILE" "$ISO_URL"
    fi
fi

# Detect firmware mode
if [[ -d /sys/firmware/efi ]]; then
    firmware="uefi"
else
    firmware="bios"
fi
echo "Firmware detected: $firmware"

# Partitioning target disk
echo "Partitioning $TARGET_DISK for $firmware boot..."

# Unmount all partitions on the disk
for part in $(lsblk -ln -o NAME "$TARGET_DISK" | tail -n +2); do
    umount "/dev/$part" 2>/dev/null || true
done

if [[ "$firmware" == "uefi" ]]; then
    parted "$TARGET_DISK" --script mklabel gpt
    parted "$TARGET_DISK" --script mkpart ESP fat32 1MiB 513MiB
    parted "$TARGET_DISK" --script set 1 boot on
    parted "$TARGET_DISK" --script set 1 esp on
    parted "$TARGET_DISK" --script mkpart primary ext4 513MiB 100%
else
    parted "$TARGET_DISK" --script mklabel msdos
    parted "$TARGET_DISK" --script mkpart primary ext4 1MiB 100%
    parted "$TARGET_DISK" --script set 1 boot on
fi

sleep 2  # wait for kernel to refresh partition table

if [[ "$firmware" == "uefi" ]]; then
    ESP_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
else
    ROOT_PART="${TARGET_DISK}1"
fi

# Format partitions
if [[ "$firmware" == "uefi" ]]; then
    mkfs.vfat -F32 "$ESP_PART"
fi
mkfs.ext4 -F "$ROOT_PART"

# Mount partitions
mountpoint -q /mnt/target && umount /mnt/target
mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target

if [[ "$firmware" == "uefi" ]]; then
    mkdir -p /mnt/target/boot/efi
    mount "$ESP_PART" /mnt/target/boot/efi
fi

# Mount ISO
ISO_MOUNT="/mnt/iso_mount"
mountpoint -q "$ISO_MOUNT" && umount "$ISO_MOUNT"
mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_FILE" "$ISO_MOUNT"

# Extract squashfs per distro (reuse your logic here)
case "$TARGET_DISTRO" in
    fedora)
        SQUASH="$ISO_MOUNT/LiveOS/squashfs.img"
        ;;
    ubuntu|mint)
        SQUASH="$ISO_MOUNT/casper/filesystem.squashfs"
        ;;
    arch)
        rsync -aHAX --exclude=/arch/boot/x86_64/airootfs.sfs "$ISO_MOUNT/" /mnt/target/
        SQUASH="$ISO_MOUNT/arch/boot/x86_64/airootfs.sfs"
        ;;
    void)
        SQUASH="$ISO_MOUNT/livefs.squashfs"
        ;;
    *)
        echo "Unsupported distro."
        exit 1
        ;;
esac

if [[ -f "$SQUASH" ]]; then
    echo "Extracting squashfs..."
    unsquashfs -f -d /mnt/target "$SQUASH"
else
    echo "ERROR: Squashfs not found at $SQUASH"
    exit 1
fi

# Mount pseudo filesystems for chroot if supported
if [[ "$TARGET_DISTRO" == "fedora" || "$TARGET_DISTRO" == "ubuntu" || "$TARGET_DISTRO" == "mint" ]]; then
    for fs in proc sys dev; do
        mount --bind /$fs /mnt/target/$fs
    done
    chroot /mnt/target grub-install
    chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg
    for fs in proc sys dev; do
        umount /mnt/target/$fs
    done
else
    # Non-chroot grub install
    if [[ "$firmware" == "uefi" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/mnt/target/boot/efi --bootloader-id=GRUB --removable --boot-directory=/mnt/target/boot
    else
        grub-install --target=i386-pc --boot-directory=/mnt/target/boot "$TARGET_DISK"
    fi
    echo "IMPORTANT: After boot, run grub-mkconfig in new system."
fi

# Cleanup
umount /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT"

echo "Migration complete! Reboot and select your new $TARGET_DISTRO system."

exit 0
