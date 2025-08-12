#!/bin/bash
set -e

echo "== Fedora Manual Installer Prep + Install =="

# --- Prompt inputs ---
read -p "Enter target disk (e.g. /dev/sda): " disk
read -p "Enter partition to shrink (e.g. /dev/sda3): " shrink_part
read -p "Enter space to shrink in GiB (e.g. 20): " shrink_gib

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

# --- Check disk and partition ---
if [ ! -b "$disk" ]; then
  echo "ERROR: Disk $disk not found!"
  exit 1
fi

if [ ! -b "$shrink_part" ]; then
  echo "ERROR: Partition $shrink_part not found!"
  exit 1
fi

# --- Detect partition style ---
part_style=$(parted $disk print | grep 'Partition Table' | awk '{print $3}')
echo "Detected partition style: $part_style"

echo "IMPORTANT: THIS SCRIPT DOES NOT SHRINK FILESYSTEMS AUTOMATICALLY."
echo "You must shrink the filesystem on $shrink_part before continuing."
echo "For example, use 'resize2fs' for ext4, or KDE Partition Manager / gparted live environment."
read -p "Have you safely shrunk your filesystem on $shrink_part? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Please shrink the filesystem first. Aborting."
  exit 1
fi

# --- Calculate sizes in MiB ---
shrink_mib=$((shrink_gib * 1024))

# --- Find free space start ---
free_start=$(parted $disk unit MiB print free | grep "Free Space" | head -1 | awk '{print $2}' | sed 's/MiB//')
if [ -z "$free_start" ]; then
  echo "ERROR: Could not find free space on $disk. Make sure you have shrunk a partition and there is free space."
  exit 1
fi
echo "Free space starts at ${free_start}MiB"

if [ "$part_style" == "gpt" ]; then
  efi_size=500
  swap_size=4096
  root_size=$((shrink_mib - efi_size - swap_size))

  echo "Creating EFI (500 MiB), root, and swap partitions..."

  parted --script $disk mkpart primary fat32 ${free_start}MiB $((free_start + efi_size))MiB
  efi_part="${disk}$(parted $disk print | grep -E '^ [0-9]+' | tail -3 | head -1 | awk '{print $1}')"
  parted --script $disk set $efi_part boot on

  parted --script $disk mkpart primary ext4 $((free_start + efi_size))MiB $((free_start + efi_size + root_size))MiB
  root_part="${disk}$(parted $disk print | grep -E '^ [0-9]+' | tail -2 | head -1 | awk '{print $1}')"

  parted --script $disk mkpart primary linux-swap $((free_start + efi_size + root_size))MiB $((free_start + efi_size + root_size + swap_size))MiB
  swap_part="${disk}$(parted $disk print | grep -E '^ [0-9]+' | tail -1 | awk '{print $1}')"

  echo "Formatting partitions..."
  mkfs.fat -F32 $efi_part
  mkfs.ext4 $root_part
  mkswap $swap_part
  swapon $swap_part

  echo "Mounting root at /mnt and EFI at /mnt/boot/efi"
  mount $root_part /mnt
  mkdir -p /mnt/boot/efi
  mount $efi_part /mnt/boot/efi

elif [ "$part_style" == "msdos" ]; then
  swap_size=4096
  root_size=$((shrink_mib - swap_size))

  echo "MBR detected. Creating root and swap partitions (no EFI)."

  parted --script $disk mkpart primary ext4 ${free_start}MiB $((free_start + root_size))MiB
  root_part="${disk}$(parted $disk print | grep -E '^ [0-9]+' | tail -2 | head -1 | awk '{print $1}')"

  parted --script $disk mkpart primary linux-swap $((free_start + root_size))MiB $((free_start + root_size + swap_size))MiB
  swap_part="${disk}$(parted $disk print | grep -E '^ [0-9]+' | tail -1 | awk '{print $1}')"

  echo "Formatting partitions..."
  mkfs.ext4 $root_part
  mkswap $swap_part
  swapon $swap_part

  echo "Mounting root at /mnt"
  mount $root_part /mnt

else
  echo "Unsupported partition table type: $part_style"
  exit 1
fi

# --- Install Fedora minimal + Desktop Environment ---
echo "Installing Fedora minimal system with $de_group..."
dnf install --installroot=/mnt --releasever=42 --setopt=install_weak_deps=False -y @core $de_group || {
  echo "ERROR: Package installation failed. Check your network connection and package repos."
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
