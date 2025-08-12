#!/bin/bash
set -e

echo "== Fedora Full Disk Wipe + Install =="

# --- Prompt inputs ---
read -p "Enter target disk to wipe and install on (e.g. /dev/sda): " disk

if [ ! -b "$disk" ]; then
  echo "ERROR: Disk $disk not found!"
  exit 1
fi

echo "IMPORTANT: This will ERASE ALL DATA on $disk."
read -p "Type YES to confirm disk wipe and continue: " confirm
if [[ "$confirm" != "YES" ]]; then
  echo "Aborted by user."
  exit 1
fi

echo "Enter firmware type (UEFI or LegacyBIOS):"
read -p "(UEFI/LegacyBIOS): " fw_type
fw_type=$(echo "$fw_type" | tr '[:upper:]' '[:lower:]')

if [[ "$fw_type" != "uefi" && "$fw_type" != "legacybios" ]]; then
  echo "Invalid firmware type. Please enter UEFI or LegacyBIOS."
  exit 1
fi

echo "Choose Desktop Environment:"
echo "1) GNOME (default)"
echo "2) KDE Plasma"
echo "3) Cinnamon"
read -p "Enter choice (1-3): " de_choice

case $de_choice in
  2) de_group="@kde-desktop";;
  3) de_group="@cinnamon-desktop";;
  *) de_group="@gnome-desktop";;
esac

# --- Wipe disk ---
echo "Wiping partition table on $disk..."
sgdisk --zap-all $disk
wipefs -a $disk
dd if=/dev/zero of=$disk bs=1M count=10 conv=fdatasync

# --- Partition sizes in MiB ---
efi_size=512      # EFI partition size (if UEFI)
swap_size=4096    # Swap size 4GiB
root_size=0       # Will use remaining disk space

# --- Create partitions ---
if [ "$fw_type" == "uefi" ]; then
  echo "Creating GPT partition table and partitions for UEFI boot..."
  parted --script $disk mklabel gpt
  parted --script $disk mkpart ESP fat32 1MiB ${efi_size}MiB
  parted --script $disk set 1 boot on
  parted --script $disk mkpart primary ext4 ${efi_size}MiB $((efi_size + swap_size))MiB
  parted --script $disk mkpart primary linux-swap $((efi_size + swap_size))MiB 100%

  efi_part="${disk}1"
  root_part="${disk}2"
  swap_part="${disk}3"

elif [ "$fw_type" == "legacybios" ]; then
  echo "Creating MBR partition table and partitions for Legacy BIOS boot..."
  parted --script $disk mklabel msdos
  parted --script $disk mkpart primary ext4 1MiB $((swap_size))MiB
  parted --script $disk set 1 boot on
  parted --script $disk mkpart primary linux-swap $((swap_size))MiB 100%

  root_part="${disk}1"
  swap_part="${disk}2"
fi

echo "Formatting partitions..."
if [ "$fw_type" == "uefi" ]; then
  mkfs.fat -F32 $efi_part
fi
mkfs.ext4 $root_part
mkswap $swap_part
swapon $swap_part

echo "Mounting partitions..."
mount $root_part /mnt
if [ "$fw_type" == "uefi" ]; then
  mkdir -p /mnt/boot/efi
  mount $efi_part /mnt/boot/efi
fi

# --- Install Fedora minimal + Desktop Environment ---
echo "Installing Fedora minimal system with $de_group..."
dnf install --installroot=/mnt --releasever=42 --setopt=install_weak_deps=False -y @core $de_group || {
  echo "ERROR: Package installation failed. Check your network connection and repos."
  exit 1
}

# --- Generate fstab ---
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab || {
  echo "ERROR: fstab generation failed."
  exit 1
}

# --- Prepare chroot environment ---
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# --- Create user and lock root ---
read -p "Enter username for the new user: " newuser
while true; do
  read -s -p "Enter password for $newuser: " userpass
  echo
  read -s -p "Confirm password for $newuser: " userpass2
  echo
  [ "$userpass" = "$userpass2" ] && break
  echo "Passwords do not match, please try again."
done

echo "Creating user $newuser with sudo privileges..."
chroot /mnt /usr/sbin/useradd -m -G wheel -s /bin/bash "$newuser"
echo "$newuser:$userpass" | chroot /mnt /usr/sbin/chpasswd

echo "Enabling sudo for wheel group..."
chroot /mnt /usr/bin/sed -i '/^# %wheel ALL=(ALL) ALL/s/^# //' /mnt/etc/sudoers || true

echo "Set root password (will be locked afterward):"
chroot /mnt /usr/bin/passwd root

echo "Locking root account for security..."
chroot /mnt /usr/sbin/usermod -L root
chroot /mnt /usr/bin/passwd -l root

# --- Cleanup ---
umount /mnt/dev
umount /mnt/proc
umount /mnt/sys

echo "Installation complete. You can now reboot and log in as $newuser."
