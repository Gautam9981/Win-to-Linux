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
     - EFI System Partition (FAT32, 512 MiB): mkpart primary fat32 2048s 1050623s
       set 1 boot on
     - Root (ext4, rest of disk minus swap): mkpart primary ext4 1050624s <root_end>
     - Swap (linux-swap, optional): mkpart primary linux-swap <swap_start> -1s
   For Legacy BIOS/MBR:
     - Root (ext4, rest of disk minus swap): mkpart primary ext4 2048s <root_end>
       set 1 boot on
     - Swap (linux-swap, optional): mkpart primary linux-swap <swap_start> -1s
6. Exit parted: quit
7. Format partitions:
   - EFI (UEFI only): sudo mkfs.fat -F32 /dev/sdX1
   - Root: sudo mkfs.ext4 /dev/sdX2 (or /dev/sdX1 for Legacy BIOS)
   - Swap (if any): sudo mkswap /dev/sdX3 (or /dev/sdX2 for Legacy BIOS) && sudo swapon /dev/sdX3 (or /dev/sdX2)
8. Mount partitions before installation:
   sudo mount /dev/sdX2 /mnt (or /dev/sdX1 for Legacy BIOS)
   sudo mkdir -p /mnt/boot/efi
   sudo mount /dev/sdX1 /mnt/boot/efi  # UEFI only

Proceed with the installation script after this setup.

---

EOF

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

  read -p "Enter desired swap size in MiB (0 for no swap): " swap_size_mib
  if ! [[ "$swap_size_mib" =~ ^[0-9]+$ ]]; then
    echo "Invalid swap size entered."
    exit 1
  fi

  echo "Wiping partition table on $disk..."
  wipefs -a "$disk"
  dd if=/dev/zero of="$disk" bs=1M count=10 conv=fdatasync

  # Gather sector info
  sector_size=$(cat /sys/block/$(basename $disk)/queue/hw_sector_size)
  total_sectors=$(blockdev --getsz "$disk")

  echo "Disk sector size: $sector_size bytes"
  echo "Disk total sectors: $total_sectors"

  efi_size_mib=512
  efi_size_sectors=$(( (efi_size_mib * 1024 * 1024) / sector_size ))
  swap_size_sectors=$(( (swap_size_mib * 1024 * 1024) / sector_size ))

  # Start sectors
  # 2048 is a common first partition start (1MiB aligned)
  efi_start=2048

  if [ "$fw_type" == "uefi" ]; then
    efi_end=$((efi_start + efi_size_sectors - 1))
    root_start=$((efi_end + 1))
  else
    # Legacy BIOS - no EFI partition
    root_start=2048
  fi

  if [ "$swap_size_mib" -gt 0 ]; then
    root_end=$((total_sectors - swap_size_sectors - 1))
    swap_start=$((root_end + 1))
    swap_end=$((total_sectors - 1))
  else
    root_end=$((total_sectors - 1))
    swap_start=0
    swap_end=0
  fi

  if [ "$fw_type" == "uefi" ]; then
    echo "Creating GPT partition table and partitions for UEFI boot..."
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 "${efi_start}s" "${efi_end}s"
    parted --script "$disk" set 1 boot on
    parted --script "$disk" mkpart primary ext4 "${root_start}s" "${root_end}s"
    if [ "$swap_size_mib" -gt 0 ]; then
      parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "-1s"
    fi

    efi_part="${disk}p1"
    root_part="${disk}p2"
    if [ "$swap_size_mib" -gt 0 ]; then
      swap_part="${disk}p3"
    else
      swap_part=""
    fi

  else
    echo "Creating MBR partition table and partitions for Legacy BIOS boot..."
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary ext4 "${root_start}s" "${root_end}s"
    parted --script "$disk" set 1 boot on
    if [ "$swap_size_mib" -gt 0 ]; then
      parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "${swap_end}s"
    fi

    root_part="${disk}p1"
    if [ "$swap_size_mib" -gt 0 ]; then
      swap_part="${disk}p2"
    else
      swap_part=""
    fi
  fi

  echo "Formatting partitions..."
  if [ "$fw_type" == "uefi" ]; then
    mkfs.fat -F32 "$efi_part"
  fi
  mkfs.ext4 "$root_part"

  if [ -n "$swap_part" ]; then
    mkswap "$swap_part"
    swapon "$swap_part"
  fi

  echo "Mounting partitions..."
  mount "$root_part" /mnt
  if [ "$fw_type" == "uefi" ]; then
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi
  fi

else
  echo "You chose NOT to wipe or auto-partition. Please specify your existing partitions."

  if [ "$fw_type" == "uefi" ]; then
    read -p "Enter EFI system partition (e.g. /dev/sda1): " efi_part
  else
    efi_part=""
  fi

  read -p "Enter root partition (e.g. /dev/sda2): " root_part
  read -p "Enter swap partition (e.g. /dev/sda3) or leave blank if none: " swap_part

  # Validate partitions exist
  for part in $efi_part $root_part $swap_part; do
    if [ -n "$part" ] && [ ! -b "$part" ]; then
      echo "ERROR: Partition $part not found!"
      exit 1
    fi
  done

  read -p "Do you want to format the root partition $root_part? (yes/no): " fmt_root
  fmt_root=$(echo "$fmt_root" | tr '[:upper:]' '[:lower:]')
  if [[ "$fmt_root" == "yes" ]]; then
    mkfs.ext4 "$root_part"
  fi

  if [ "$fw_type" == "uefi" ] && [ -n "$efi_part" ]; then
    read -p "Do you want to format the EFI partition $efi_part? (yes/no): " fmt_efi
    fmt_efi=$(echo "$fmt_efi" | tr '[:upper:]' '[:lower:]')
    if [[ "$fmt_efi" == "yes" ]]; then
      mkfs.fat -F32 "$efi_part"
    fi
  fi

  if [ -n "$swap_part" ]; then
    mkswap "$swap_part"
    swapon "$swap_part"
  fi

  echo "Mounting root partition $root_part to /mnt..."
  mount "$root_part" /mnt
  if [ "$fw_type" == "uefi" ] && [ -n "$efi_part" ]; then
    echo "Mounting EFI partition $efi_part to /mnt/boot/efi..."
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi
  fi
fi

#Mounting special directories
echo "Mounting necessary chroot directories..."
sudo mkdir -p /mnt/sys /mnt/dev /mnt/run /mnt/proc /mnt/usr
sudo mount --bind /sys /mnt/sys
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /run /mnt/run
sudo mount --bind /usr /mnt/usr

echo "Installing Fedora minimal system with $de_group..."
dnf install --installroot=/mnt --releasever=42 --setopt=install_weak_deps=False -y @core $de_group grub2-efi shim efibootmgr || \
dnf install --installroot=/mnt --releasever=42 -y @core $de_group grub2



echo "Installing bootloader..."
if [ "$fw_type" == "uefi" ]; then
  chroot /mnt grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora --recheck
  chroot /mnt grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
else
  chroot /mnt grub2-install --target=i386-pc "$disk"
  chroot /mnt grub2-mkconfig -o /boot/grub2/grub.cfg
fi

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab || { echo "ERROR: fstab generation failed."; exit 1; }



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
umount /mnt/dev || true
umount /mnt/proc || true
umount /mnt/sys || true

echo "Installation complete. You can now reboot and log in as $newuser."
