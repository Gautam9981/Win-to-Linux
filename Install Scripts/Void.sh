#!/bin/bash
# Void Linux Encrypted Root + NVIDIA + Sound + Desktop (runit) Installer
# Run from Void live ISO

set -euo pipefail

echo "=== Void Linux Encrypted Installer ==="

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
read -rp "Select target disk (e.g., /dev/sda or /dev/nvme0n1): " DISK

echo "All data on $DISK will be lost! Type 'YES' to confirm:"
read -r CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborting."; exit 1; }

# Wipe and partition
wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI "$DISK"
sgdisk -n2:0:0 -t2:8300 -c2:cryptroot "$DISK"

# ===== LUKS ENCRYPTION =====
echo "Enter LUKS password:"
cryptsetup luksFormat "${DISK}p2"
cryptsetup open "${DISK}p2" cryptroot

# ===== FILESYSTEMS =====
mkfs.vfat -F32 "${DISK}p1"
mkfs.ext4 /dev/mapper/cryptroot

# ===== MOUNT =====
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}p1" /mnt/boot/efi

# ===== BASE INSTALL =====
XBPS_ARCH=x86_64 XBPS_TARGETDIR=/mnt xbps-install -Sy base-system linux kernel-headers cryptsetup lvm2 grub-x86_64-efi efibootmgr nano

# ===== CHROOT PHASE =====
cat << EOF | chroot /mnt /bin/bash
set -euo pipefail

# ===== XBPS UPDATE =====
xbps-install -S xbps
xbps-install -Syyu

# ===== HOSTNAME & LOCALE =====
echo "$HOSTNAME" > /etc/hostname
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
xbps-install -Sy glibc-locales
echo "$LOCALE UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# ===== TIMEZONE =====
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# ===== NVIDIA DRIVERS =====
xbps-install -Sy void-repo-nonfree
xbps-install -Sy nvidia nvidia-dkms nvidia-libs nvidia-utils

# ===== SOUND (PipeWire + runit) =====
xbps-install -Sy alsa-utils alsa-plugins pipewire pipewire-alsa pipewire-pulse wireplumber
ln -s /etc/sv/pipewire /var/service/
ln -s /etc/sv/wireplumber /var/service/

# ===== DESKTOP ENVIRONMENT =====
if [ -n "$DESKTOP_PKGS" ]; then
    xbps-install -Sy $DESKTOP_PKGS
    case "$DE_CHOICE" in
        1) ln -s /etc/sv/lightdm /var/service/ ;;
        2) ln -s /etc/sv/sddm /var/service/ ;;
        3) ln -s /etc/sv/gdm /var/service/ ;;
        4) ln -s /etc/sv/sddm /var/service/ ;;
    esac
fi

# ===== USERS =====
echo "Set root password:"
passwd
useradd -m -G wheel,audio,video "$USERNAME"
echo "Set password for $USERNAME:"
passwd "$USERNAME"

# ===== SUDO =====
xbps-install -Sy sudo
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/10-wheel

# ===== INITRAMFS =====
xbps-reconfigure -fa

# ===== GRUB CONFIG =====
UUID=\$(blkid -s UUID -o value ${DISK}p2)
echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"
grub-mkconfig -o /boot/grub/grub.cfg

EOF

echo "Installation complete. You can now reboot."
