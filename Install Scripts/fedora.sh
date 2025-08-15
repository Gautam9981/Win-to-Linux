#!/bin/bash
set -e

# --- Pre-Check ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# --- Disk Selection ---
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL
read -p "Enter target disk (e.g., /dev/sda): " disk

# --- Optional: Wipe Disk ---
read -p "Wipe the disk? This will destroy all data on $disk (y/N): " wipe_disk
if [[ "$wipe_disk" =~ ^[Yy]$ ]]; then
    wipefs -a $disk
    sgdisk --zap-all $disk
fi

# --- Partitioning Instructions ---
cat <<'EOF'

--- Manual Partitioning Instructions ---

If you prefer to manually partition your drive instead of wiping and auto-partitioning with this script, please use a live environment (e.g., Void Linux ISO):

1. Boot into the live environment.
2. Update xbps by doing sudo xbps-install -S xbps and sudo xbps-install -Syu
3. Then get cgdisk by installing gptfdisk (sudo xbps-install -S gptfdisk)
4. Use cgdisk to partition the disk

Note: Void Linux does not include a GUI by default. You can install a desktop environment later using `xbps-install`.
---
EOF

# --- Partition Mounting ---
read -p "Enter root partition (e.g., /dev/sda2): " root_part
read -p "Enter boot partition (or leave blank if none): " boot_part
read -p "Enter EFI partition (or leave blank if none): " efi_part

# --- Optional LUKS encryption ---
read -p "Do you want to encrypt root partition with LUKS? (y/N): " encrypt_choice
if [[ "$encrypt_choice" =~ ^[Yy]$ ]]; then
    read -s -p "Enter LUKS passphrase: " luks_pass
    echo
    cryptsetup luksFormat "$root_part" <<<"$luks_pass"
    cryptsetup open "$root_part" cryptroot <<<"$luks_pass"
    root_dev="/dev/mapper/cryptroot"
else
    root_dev="$root_part"
fi

# --- Format Partitions ---
mkfs.ext4 "$root_dev"
mount "$root_dev" /mnt

if [[ -n "$boot_part" ]]; then
    mkfs.ext4 "$boot_part"
    mkdir -p /mnt/boot
    mount "$boot_part" /mnt/boot
fi

if [[ -n "$efi_part" ]]; then
    mkfs.fat -F32 "$efi_part"
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi
fi

# --- Base System Installation ---
xbps-install -Sy -R https://alpha.de.repo.voidlinux.org/current -r /mnt base-system grub cryptsetup

# --- Generate fstab manually (Void doesn't have genfstab) ---
mkdir -p /mnt/etc
cat <<FSTAB_EOF > /mnt/etc/fstab
$(blkid -o export "$root_dev" | awk -F= '/UUID/ {print "UUID="$2" / ext4 defaults 0 1"}')
FSTAB_EOF

[[ -n "$boot_part" ]] && echo "$(blkid -o export "$boot_part" | awk -F= '/UUID/ {print "UUID="$2" /boot ext4 defaults 0 2"}')" >> /mnt/etc/fstab
[[ -n "$efi_part" ]] && echo "$(blkid -o export "$efi_part" | awk -F= '/UUID/ {print "UUID="$2" /boot/efi vfat defaults 0 2"}')" >> /mnt/etc/fstab

# --- Chroot Configuration ---
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

chroot /mnt /bin/bash <<'CHROOT_EOF'
# --- Hostname ---
read -p "Enter desired hostname for your system: " hostname
echo "$hostname" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS_EOF

# --- Root Password ---
echo "Set root password:"
passwd

# --- LUKS initramfs ---
if [ -e /dev/mapper/cryptroot ]; then
    dracut -f
fi

# --- GRUB Installation ---
if [ -d /sys/firmware/efi ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=VoidLinux
else
    read -p "Enter the disk for GRUB installation (e.g., /dev/sda): " grub_disk
    grub-install --target=i386-pc "$grub_disk"
fi

# --- GRUB config for LUKS ---
if [ -e /dev/mapper/cryptroot ]; then
    root_uuid=$(blkid -s UUID -o value /dev/sda2)
    sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$root_uuid:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_EOF

# --- Finish ---
umount -R /mnt
echo "Installation complete! Reboot into your new Void Linux system."
