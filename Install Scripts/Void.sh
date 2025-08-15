#!/bin/bash
# Void Linux Safe Installer + Optional Encrypted Root + NVIDIA + Sound + Desktop (runit)
# Run from Void live ISO
set -euo pipefail

echo "=== Void Linux Installer ==="

# ===== USER INPUT =====
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -rp "Enter timezone (e.g., UTC or Europe/London): " TIMEZONE
read -rp "Enter locale (default: en_US.UTF-8): " LOCALE
LOCALE=${LOCALE:-en_US.UTF-8}
read -rp "Enter keyboard layout (default: us): " KEYMAP
KEYMAP=${KEYMAP:-us}

echo "Choose desktop environment:"
echo "1) XFCE"
echo "2) KDE Plasma"
echo "3) GNOME"
echo "4) LXQt"
echo "5) None (headless)"
read -rp "Enter choice [1-5]: " DE_CHOICE

case "$DE_CHOICE" in
    1) DESKTOP_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
    2) DESKTOP_PKGS="plasma kde-applications sddm" ;;
    3) DESKTOP_PKGS="gnome gdm" ;;
    4) DESKTOP_PKGS="lxqt sddm" ;;
    5) DESKTOP_PKGS="" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

# ===== DISK SETUP =====
lsblk
echo "You can manually specify partitions. Example:"
echo "  Root: /dev/sda2"
echo "  Home: /dev/sda3 (optional)"
echo "  Swap: /dev/sda1 (optional)"
read -rp "Enter root partition: " ROOT_PART
read -rp "Enter home partition (optional): " HOME_PART
read -rp "Enter swap partition (optional): " SWAP_PART
read -rp "Is the root partition encrypted? (y/n): " ENC_ROOT

if [[ "$ENC_ROOT" == "y" ]]; then
    read -s -rp "Enter LUKS passphrase: " LUKS_PASS
    echo
    cryptsetup luksFormat "$ROOT_PART"
    cryptsetup open "$ROOT_PART" cryptroot --key-file <(echo "$LUKS_PASS")
    ROOT_MAPPED="/dev/mapper/cryptroot"
else
    ROOT_MAPPED="$ROOT_PART"
fi

# ===== FILESYSTEMS =====
mkfs.ext4 "$ROOT_MAPPED"
mount "$ROOT_MAPPED" /mnt

if [[ -n "$HOME_PART" ]]; then
    mkfs.ext4 "$HOME_PART"
    mkdir -p /mnt/home
    mount "$HOME_PART" /mnt/home
fi

if [[ -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
fi

# Optional EFI partition setup
read -rp "Do you have an EFI partition to mount? (y/n): " EFI_CHOICE
if [[ "$EFI_CHOICE" == "y" ]]; then
    read -rp "Enter EFI partition (e.g., /dev/sda1): " EFI_PART
    mkdir -p /mnt/boot/efi
    mkfs.vfat -F32 "$EFI_PART"
    mount "$EFI_PART" /mnt/boot/efi
fi

# ===== UPDATE XBPS =====
xbps-install -S xbps
xbps-install -Syyu

# ===== BASE SYSTEM INSTALL =====
xbps-install -Sy -R https://alpha.de.repo.voidlinux.org/current -r /mnt \
    base-system linux linux-firmware kernel-headers sudo grub-x86_64-efi efibootmgr \
    nano git cryptsetup lvm2

# ===== CHROOT CONFIGURATION =====
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

chroot /mnt /bin/bash -c "
set -euo pipefail

# Hostname, locale, keyboard
echo '$HOSTNAME' > /etc/hostname
echo 'LANG=$LOCALE' > /etc/locale.conf
echo 'KEYMAP=$KEYMAP' > /etc/vconsole.conf
xbps-install -Sy glibc-locales
echo '$LOCALE UTF-8' >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# Timezone
ln -sf '/usr/share/zoneinfo/$TIMEZONE' /etc/localtime

# NVIDIA drivers
xbps-install -Sy void-repo-nonfree
xbps-install -Sy nvidia nvidia-dkms nvidia-libs nvidia-utils

# Sound (PipeWire + runit)
xbps-install -Sy alsa-utils alsa-plugins pipewire pipewire-alsa pipewire-pulse wireplumber
ln -s /etc/sv/pipewire /var/service/
ln -s /etc/sv/wireplumber /var/service/

# Desktop environment
if [[ -n '$DESKTOP_PKGS' ]]; then
    xbps-install -Sy $DESKTOP_PKGS
    case '$DE_CHOICE' in
        1) ln -s /etc/sv/lightdm /var/service/ ;;
        2) ln -s /etc/sv/sddm /var/service/ ;;
        3) ln -s /etc/sv/gdm /var/service/ ;;
        4) ln -s /etc/sv/sddm /var/service/ ;;
    esac
fi

# Users and sudo
echo 'Set root password:'
passwd
useradd -m -G wheel,audio,video '$USERNAME'
echo 'Set password for $USERNAME:'
passwd '$USERNAME'
xbps-install -Sy sudo
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/10-wheel

# Initramfs
xbps-reconfigure -fa

# GRUB
if [[ -n '$EFI_PART' ]]; then
    UUID=\$(blkid -s UUID -o value '$ROOT_PART')
    echo 'GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"' >> /etc/default/grub
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id='Void'
    grub-mkconfig -o /boot/grub/grub.cfg
fi
"

echo "Installation complete! You can now reboot."
