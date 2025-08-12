#!/bin/bash
set -e

echo "== Fedora Full Disk Wipe + Install =="

cat <<'EOF'

--- Manual Partitioning Instructions ---

If you prefer to manually partition your drive instead of wiping and auto-partitioning with this script, follow these steps carefully:

1. Boot Fedora Live environment (e.g., Fedora KDE Spin).
2. Open a terminal and identify your disk with: lsblk
3. Start parted on your disk (replace /dev/sdX accordingly):
   sudo parted /dev/sdX
4. Create a partition table:
   - For UEFI systems (GPT): mklabel gpt
   - For Legacy BIOS (MBR): mklabel msdos
5. Create partitions:
   For UEFI/GPT:
     - EFI System Partition (FAT32, 512 MiB): mkpart primary fat32 1MiB 513MiB
       set 1 boot on
     - Root (ext4, 20GiB+): mkpart primary ext4 513MiB 20GiB
     - Swap (linux-swap, 4GiB): mkpart primary linux-swap 20GiB 24GiB
   For Legacy BIOS/MBR:
     - Root (ext4, 20GiB+): mkpart primary ext4 1MiB 20GiB
       set 1 boot on
     - Swap (linux-swap, 4GiB): mkpart primary linux-swap 20GiB 24GiB
6. Exit parted: quit
7. Format partitions:
   - EFI (UEFI only): sudo mkfs.fat -F32 /dev/sdX1
   - Root: sudo mkfs.ext4 /dev/sdX2
   - Swap: sudo mkswap /dev/sdX3 && sudo swapon /dev/sdX3
8. Mount partitions before installation:
   sudo mount /dev/sdX2 /mnt
   sudo mkdir -p /mnt/boot/efi
   sudo mount /dev/sdX1 /mnt/boot/efi  # UEFI only

Proceed with the installation script after this setup.

---

EOF

# --- Prompt inputs ---
read -p "Enter target disk to install on (e.g. /dev/sda): " disk

if [ ! -b "$disk" ]; then
  echo "ERROR: Disk $disk not found!"
  exit 1
fi

read -p "Do you want to wipe and auto-partition the disk? (yes/no): " wipe_answer
wipe_answer=$(echo "$wipe_answer" | tr '[:upper:]' '[:lower:]')

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

if [[ "$wipe_answer" == "yes" ]]; then
  echo "IMPORTANT: This will ERASE ALL DATA on $disk."
  read -p "Type YES to confirm disk wipe and continue: " confirm
  if [[ "$confirm" != "YES" ]]; then
    echo "Aborted by user."
    exit 1
  fi

  # --- Wipe disk ---
  echo "Wiping partition table on $disk..."
  wipefs -a $disk
  dd if=/dev/zero of=$disk bs=1M count=10 conv=fdatasync

  # --- Partition sizes in MiB ---
  efi_size=512      # EFI partition size (if UEFI)
  swap_size=4096    # Swap size 4GiB

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

else
  echo "You chose to NOT wipe or auto-partition. Please specify your existing partitions."

  # Collect partitions depending on firmware
  if [ "$fw_type" == "uefi" ]; then
    read -p "Enter EFI system partition (e.g. /dev/sda1): " efi_part
  fi

  read -p "Enter root partition (e.g. /dev/sda2): " root_part
  read -p "Enter swap partition (e.g. /dev/sda3): " swap_part

  # Validate partitions exist
  for part in $efi_part $root_part $swap_part; do
    if [ -n "$part" ] && [ ! -b "$part" ]; then
      echo "ERROR: Partition $part not found!"
      exit 1
    fi
  done

  # Ask if user wants to format root and EFI partitions
  read -p "Do you want to format the root partition $root_part? (yes/no): " fmt_root
  fmt_root=$(echo "$fmt_root" | tr '[:upper:]' '[:lower:]')
  if [[ "$fmt_root" == "yes" ]]; then
    mkfs.ext4 $root_part
  fi

  if [ "$fw_type" == "uefi" ]; then
    read -p "Do you want to format the EFI partition $efi_part? (yes/no): " fmt_efi
    fmt_efi=$(echo "$fmt_efi" | tr '[:upper:]' '[:lower:]')
    if [[ "$fmt_efi" == "yes" ]]; then
      mkfs.fat -F32 $efi_part
    fi
  fi

  # Enable swap
  mkswap $swap_part
  swapon $swap_part

  echo "Mounting root partition $root_part to /mnt..."
  mount $root_part /mnt

  if [ "$fw_type" == "uefi" ]; then
    echo "Mounting EFI partition $efi_part to /mnt/boot/efi..."
    mkdir -p /mnt/boot/efi
    mount $efi_part /mnt/boot/efi
  fi
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
