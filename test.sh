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

# Validate necessary tools in live environment
REQUIRED_CMDS=(curl rsync unsquashfs mount umount parted mkfs.vfat mkfs.ext4 tar)
GRUB_INSTALL_CMDS=(grub-install grub2-install)
GRUB_MKCONFIG_CMDS=(grub-mkconfig grub2-mkconfig)

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found in live environment."
        exit 1
    fi
done

# Check grub-install or grub2-install in live environment
GRUB_INSTALL_CMD=""
for cmd in "${GRUB_INSTALL_CMDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        GRUB_INSTALL_CMD="$cmd"
        break
    fi
done
if [[ -z "$GRUB_INSTALL_CMD" ]]; then
    echo "ERROR: Required command 'grub-install' or 'grub2-install' not found in live environment."
    exit 1
fi

# Check grub-mkconfig or grub2-mkconfig in live environment
GRUB_MKCONFIG_CMD=""
for cmd in "${GRUB_MKCONFIG_CMDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="$cmd"
        break
    fi
done
if [[ -z "$GRUB_MKCONFIG_CMD" ]]; then
    echo "ERROR: Required command 'grub-mkconfig' or 'grub2-mkconfig' not found in live environment."
    exit 1
fi

# Install dependencies in live environment
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
            grub2 grub2-tools efibootmgr shim
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

download_files() {
    mkdir -p "$DOWNLOAD_DIR"

    case "$TARGET_DISTRO" in
        fedora)
            # Fedora 42 KDE Live ISO
            ISO_NAME="Fedora-KDE-Live-42-1.8-x86_64.iso"
            URL="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Spins/x86_64/iso/$ISO_NAME"
            ;;

        ubuntu)
            # Ubuntu 24.04.3 LTS Desktop ISO
            ISO_NAME="ubuntu-24.04.3-desktop-amd64.iso"
            URL="http://releases.ubuntu.com/24.04/$ISO_NAME"
            ;;

        mint)
            # Mint 22.1 Cinnamon ISO
            ISO_NAME="linuxmint-22.1-cinnamon-64bit.iso"
            URL="https://mirrors.edge.kernel.org/linuxmint/stable/22.1/$ISO_NAME"
            ;;

        arch)
            # Arch latest rootfs tarball (official Arch rootfs)
            ROOTFS_NAME="archlinux-bootstrap-x86_64.tar.gz"
            URL="https://mirror.rackspace.com/archlinux/iso/latest/$ROOTFS_NAME"
            ;;

        void)
            # Void latest rootfs tarball
            # For Void, it's good to check latest URL, here fixed date for example
            URL="https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-20250202.tar.xz""
            ;;
        *)
            echo "ERROR: Unsupported distro for downloading."
            exit 1
            ;;
    esac

    if [[ "$TARGET_DISTRO" == "arch" || "$TARGET_DISTRO" == "void" ]]; then
        DOWNLOAD_PATH="$DOWNLOAD_DIR/$ROOTFS_NAME"
    else
        DOWNLOAD_PATH="$DOWNLOAD_DIR/$ISO_NAME"
    fi

    if [[ -f "$DOWNLOAD_PATH" ]]; then
        echo "$DOWNLOAD_PATH already exists, skipping download."
    else
        echo "Downloading $URL to $DOWNLOAD_PATH..."
        curl -L --fail -o "$DOWNLOAD_PATH" "$URL" || {
            echo "ERROR: Download failed for $URL"
            exit 1
        }
    fi
}

download_files

prepare_filesystem() {
    echo "Preparing target root filesystem..."
    mkdir -p /mnt/target

    case "$TARGET_DISTRO" in
        ubuntu|mint|fedora)
            echo "Mounting ISO for $TARGET_DISTRO..."
            if [[ "$TARGET_DISTRO" == "fedora" ]]; then
                ISO_PATH="$DOWNLOAD_DIR/Fedora-KDE-Live-42-1.8-x86_64.iso"
            elif [[ "$TARGET_DISTRO" == "ubuntu" ]]; then
                ISO_PATH="$DOWNLOAD_DIR/ubuntu-24.04.3-desktop-amd64.iso"
            else
                ISO_PATH="$DOWNLOAD_DIR/linuxmint-22.1-cinnamon-64bit.iso"
            fi

            MNT_ISO="/mnt/iso"
            mkdir -p "$MNT_ISO"
            mount -o loop "$ISO_PATH" "$MNT_ISO"

            echo "Extracting ISO squashfs contents..."
            # Try common squashfs locations
            if ! unsquashfs -f -d /mnt/target "$MNT_ISO"/casper/*.squashfs 2>/dev/null; then
                if ! unsquashfs -f -d /mnt/target "$MNT_ISO"/LiveOS/*.squashfs 2>/dev/null; then

                    echo "ERROR: Failed to extract ISO squashfs for $TARGET_DISTRO"
                    umount "$MNT_ISO"
                    exit 1
                fi
            fi

            umount "$MNT_ISO"
            ;;

        arch)
            echo "Extracting Arch rootfs tarball..."
            ROOTFS_PATH="$DOWNLOAD_DIR/archlinux-bootstrap-x86_64.tar.gz"
            tar -xpf "$ROOTFS_PATH" -C /mnt/target || {
                echo "ERROR: Failed to extract Arch rootfs"
                exit 1
            }
            ;;

        void)
            echo "Extracting Void rootfs tarball..."
            ROOTFS_PATH="$DOWNLOAD_DIR/void-x86_64-musl-ROOTFS-20230820.tar.xz"
            tar -xpf "$ROOTFS_PATH" -C /mnt/target || {
                echo "ERROR: Failed to extract Void rootfs"
                exit 1
            }
            ;;

        *)
            echo "ERROR: Unsupported distro for filesystem preparation."
            exit 1
            ;;
    esac
}

prepare_filesystem

prepare_chroot() {
    echo "Preparing chroot environment for GRUB installation..."

    for dir in dev proc sys run boot/efi; do
        mkdir -p "/mnt/target/$dir"
    done

    mount --bind /dev /mnt/target/dev
    mount --bind /proc /mnt/target/proc
    mount --bind /sys /mnt/target/sys
    mount --bind /run /mnt/target/run

    if [[ "$FIRMWARE" == "uefi" ]]; then
        mount --bind /boot/efi /mnt/target/boot/efi
    fi
}

install_grub_in_chroot() {
    prepare_chroot

    echo "Installing GRUB inside chroot for $TARGET_DISTRO..."

    if [[ "$FIRMWARE" == "uefi" ]]; then
        GRUB_INSTALL_CMD_ARGS="$GRUB_INSTALL_CMD --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --no-floppy"
    else
        GRUB_INSTALL_CMD_ARGS="$GRUB_INSTALL_CMD --boot-directory=/boot $TARGET_DISK"
    fi

    GRUB_MKCONFIG_CMD_ARGS="$GRUB_MKCONFIG_CMD -o /boot/grub/grub.cfg"

    case "$TARGET_DISTRO" in
        void)
            CHROOT_CMDS=$(cat <<EOF
set -e
xbps-install -S xbps
xbps-install -Syyu
xbps-install -y grub efibootmgr
$GRUB_INSTALL_CMD_ARGS
$GRUB_MKCONFIG_CMD_ARGS
EOF
)
            ;;

        ubuntu|mint)
            CHROOT_CMDS=$(cat <<EOF
set -e
apt-get update
apt-get install -y grub-common grub-pc
$GRUB_INSTALL_CMD_ARGS
$GRUB_MKCONFIG_CMD_ARGS
EOF
)
            ;;

        fedora)
            CHROOT_CMDS=$(cat <<EOF
set -e
dnf install -y grub2 grub2-tools efibootmgr shim
$GRUB_INSTALL_CMD_ARGS
$GRUB_MKCONFIG_CMD_ARGS
EOF
)
            ;;

        arch)
            CHROOT_CMDS=$(cat <<EOF
set -e
pacman -Sy --noconfirm grub efibootmgr
$GRUB_INSTALL_CMD_ARGS
$GRUB_MKCONFIG_CMD_ARGS
EOF
)
            ;;

        *)
            echo "ERROR: Unsupported distro for GRUB installation."
            exit 1
            ;;
    esac

    chroot /mnt/target /bin/bash -c "$CHROOT_CMDS"

    echo "Cleaning up mounts..."
    umount /mnt/target/dev || true
    umount /mnt/target/proc || true
    umount /mnt/target/sys || true
    umount /mnt/target/run || true
    if [[ "$FIRMWARE" == "uefi" ]]; then
        umount /mnt/target/boot/efi || true
    fi
}

install_grub_in_chroot

echo "Unmounting target root filesystem..."
umount /mnt/target || true

echo "Migration complete! You can now reboot into your new system."
exit 0
