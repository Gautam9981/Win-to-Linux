 #!/bin/bash
set -e

echo "== Fedora Installation Process =="

cat <<'EOF'

--- Manual Partitioning Instructions ---

If you prefer to manually partition your drive instead of wiping and auto-partitioning with this script, please use the Fedora Live environment’s GUI tool:

1. Boot into the Fedora Live environment (e.g., Fedora KDE or GNOME Spin).
2. Launch **GParted** from the applications menu.
3. Identify your target disk carefully.
4. Using GParted:
   - Create a new partition table (GPT for UEFI or MSDOS for Legacy BIOS).
   - Create the following partitions:
     * EFI System Partition (FAT32, 512 MiB) — required only for UEFI systems.
     * Root partition (ext4) — your main system partition.
     * Swap partition (linux-swap), optional.
   - To use encryption:
     * Set up LUKS encryption manually via the terminal or use another tool, as GParted itself does not directly create LUKS containers.
     * Alternatively, create partitions here and encrypt them afterward in the terminal using `cryptsetup`.
5. Apply all changes and close GParted.

Once done, return to this script and enter the paths to these partitions when prompted.

---

EOF


# Prompt for disk
read -p "Enter target disk to install on (e.g. /dev/sda): " disk
if [ ! -b "$disk" ]; then
  echo "ERROR: Disk $disk not found!"
  exit 1
fi

# Wipe and auto partition?
read -p "Do you want to wipe and auto-partition the disk? (yes/no): " wipe_answer
wipe_answer=$(echo "$wipe_answer" | tr '[:upper:]' '[:lower:]')

# Firmware type (UEFI or LegacyBIOS)
read -p "Enter firmware type (UEFI or LegacyBIOS): " fw_type
fw_type=$(echo "$fw_type" | tr '[:upper:]' '[:lower:]')
if [[ "$fw_type" != "uefi" && "$fw_type" != "legacybios" ]]; then
  echo "Invalid firmware type. Please enter UEFI or LegacyBIOS."
  exit 1
fi

# Desktop Environment selection
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

# Encryption questions
read -p "Do you want encrypted root? (yes/no): " root_enc
root_enc=$(echo "$root_enc" | tr '[:upper:]' '[:lower:]')

read -p "Do you want encrypted swap? (yes/no): " swap_enc
swap_enc=$(echo "$swap_enc" | tr '[:upper:]' '[:lower:]')

if [[ "$wipe_answer" == "yes" ]]; then
  echo "WARNING: This will ERASE ALL DATA on $disk."
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
  dd if=/dev/zero of="$disk" bs=1M count=10 conv=fdatasync status=progress

  sector_size=$(cat /sys/block/$(basename $disk)/queue/hw_sector_size)
  total_sectors=$(blockdev --getsz "$disk")

  efi_size_mib=512
  boot_size_mib=512
  efi_size_sectors=$(( (efi_size_mib * 1024 * 1024) / sector_size ))
  boot_size_sectors=$(( (boot_size_mib * 1024 * 1024) / sector_size ))
  swap_size_sectors=$(( (swap_size_mib * 1024 * 1024) / sector_size ))

  start=2048

  if [ "$fw_type" == "uefi" ]; then
    efi_start=$start
    efi_end=$((efi_start + efi_size_sectors - 1))

    boot_start=$((efi_end + 1))
    boot_end=$((boot_start + boot_size_sectors - 1))

    root_start=$((boot_end + 1))
  else
    boot_start=$start
    boot_end=$((boot_start + boot_size_sectors - 1))

    root_start=$((boot_end + 1))
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

  echo "Creating partition table and partitions..."
  if [ "$fw_type" == "uefi" ]; then
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 "${efi_start}s" "${efi_end}s"
    parted --script "$disk" set 1 boot on

    parted --script "$disk" mkpart primary ext4 "${boot_start}s" "${boot_end}s"

    parted --script "$disk" mkpart primary  ext4 "${root_start}s" "${root_end}s"

    if [ "$swap_size_mib" -gt 0 ]; then
      parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "${swap_end}s"
    fi

    efi_part="${disk}p1"
    boot_part="${disk}p2"
    root_raw_part="${disk}p3"
    if [ "$swap_size_mib" -gt 0 ]; then
      swap_raw_part="${disk}p4"
    else
      swap_raw_part=""
    fi
  else
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary ext4 "${boot_start}s" "${boot_end}s"
    parted --script "$disk" set 1 boot on

    parted --script "$disk" mkpart primary ext4 "${root_start}s" "${root_end}s"

    if [ "$swap_size_mib" -gt 0 ]; then
      parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "${swap_end}s"
    fi

    boot_part="${disk}p1"
    root_raw_part="${disk}p2"
    if [ "$swap_size_mib" -gt 0 ]; then
      swap_raw_part="${disk}p3"
    else
      swap_raw_part=""
    fi
  fi

  echo "Formatting partitions..."
  if [ "$fw_type" == "uefi" ]; then
    mkfs.fat -F32 "$efi_part"
  fi

  mkfs.ext4 "$boot_part"

  if [[ "$root_enc" == "yes" ]]; then
    echo "Setting up LUKS encryption for root partition $root_raw_part..."
    cryptsetup luksFormat "$root_raw_part"
    cryptsetup luksOpen "$root_raw_part" cryptroot
    root_part="/dev/mapper/cryptroot"
    mkfs.ext4 "$root_part"
  else
    root_part="$root_raw_part"
    mkfs.ext4 "$root_part"
  fi

  if [ "$swap_size_mib" -gt 0 ]; then
    if [[ "$swap_enc" == "yes" ]]; then
      echo "Setting up LUKS encryption for swap partition $swap_raw_part..."
      cryptsetup luksFormat "$swap_raw_part"
      cryptsetup luksOpen "$swap_raw_part" cryptswap
      swap_part="/dev/mapper/cryptswap"
      mkswap "$swap_part"
      swapon "$swap_part"
    else
      swap_part="$swap_raw_part"
      mkswap "$swap_part"
      swapon "$swap_part"
    fi
  else
    swap_part=""
  fi

  echo "Mounting partitions..."
  mount "$root_part" /mnt
  mkdir -p /mnt/boot
  mount "$boot_part" /mnt/boot
  if [ "$fw_type" == "uefi" ]; then
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi
  fi

else
  echo "Manual partitioning selected."
  echo "Note: For easier partitioning, you can use the GUI tool 'GParted' in a live environment."

  if [ "$fw_type" == "uefi" ]; then
    read -p "Enter EFI system partition (e.g. /dev/sda1): " efi_part
  else
    efi_part=""
  fi

  read -p "Enter unencrypted /boot partition (e.g. /dev/sda2): " boot_part

  read -p "Is your root partition encrypted? (yes/no): " root_enc
  root_enc=$(echo "$root_enc" | tr '[:upper:]' '[:lower:]')

  if [[ "$root_enc" == "yes" ]]; then
    read -p "Enter raw encrypted root partition (e.g. /dev/sda3): " root_raw_part
    echo "Opening encrypted root partition $root_raw_part..."
    cryptsetup luksOpen "$root_raw_part" cryptroot
    root_part="/dev/mapper/cryptroot"
  else
    read -p "Enter root partition (e.g. /dev/sda3): " root_part
  fi

  read -p "Is your swap partition encrypted? (yes/no): " swap_enc
  swap_enc=$(echo "$swap_enc" | tr '[:upper:]' '[:lower:]')

  if [[ "$swap_enc" == "yes" ]]; then
    read -p "Enter raw encrypted swap partition (e.g. /dev/sda4): " swap_raw_part
    echo "Opening encrypted swap partition $swap_raw_part..."
    cryptsetup luksOpen "$swap_raw_part" cryptswap
    swap_part="/dev/mapper/cryptswap"
    mkswap "$swap_part"
    swapon "$swap_part"
  else
    read -p "Enter swap partition (e.g. /dev/sda4) or leave blank for none: " swap_part
    if [ -n "$swap_part" ]; then
      mkswap "$swap_part"
      swapon "$swap_part"
    fi
  fi

  # Validate partitions
  for part in $efi_part $boot_part $root_part $swap_part; do
    if [ -n "$part" ] && [ ! -b "$part" ]; then
      echo "ERROR: Partition $part not found!"
      exit 1
    fi
  done

  read -p "Do you want to format the /boot partition $boot_part? (yes/no): " fmt_boot
  fmt_boot=$(echo "$fmt_boot" | tr '[:upper:]' '[:lower:]')
  if [[ "$fmt_boot" == "yes" ]]; then
    mkfs.ext4 "$boot_part"
  fi

  if [ "$fw_type" == "uefi" ] && [ -n "$efi_part" ]; then
    read -p "Do you want to format the EFI partition $efi_part? (yes/no): " fmt_efi
    fmt_efi=$(echo "$fmt_efi" | tr '[:upper:]' '[:lower:]')
    if [[ "$fmt_efi" == "yes" ]]; then
      mkfs.fat -F32 "$efi_part"
    fi
  fi

  read -p "Do you want to format the root partition $root_part? (yes/no): " fmt_root
  fmt_root=$(echo "$fmt_root" | tr '[:upper:]' '[:lower:]')
  if [[ "$fmt_root" == "yes" ]]; then
    mkfs.ext4 "$root_part"
  fi

  echo "Mounting partitions..."
  mount "$root_part" /mnt
  mkdir -p /mnt/boot
  mount "$boot_part" /mnt/boot
  if [ "$fw_type" == "uefi" ] && [ -n "$efi_part" ]; then
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi
  fi
fi

# Creat and mount special filesystems for chroot
for fs in sys dev proc run; do
  mkdir -p /mnt/$fs
  mount --bind /$fs /mnt/$fs
done

echo "Installing Fedora minimal system with $de_group..."
dnf install --installroot=/mnt --releasever=42 --setopt=install_weak_deps=False --use-host-config -y @core $de_group grub2-efi-x64 grub2-efi-modules shim efibootmgr

echo "Installing bootloader..."
if [ "$fw_type" == "uefi" ]; then
  chroot /mnt grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora --recheck
  chroot /mnt grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
else
  chroot /mnt grub2-install --target=i386-pc "$disk"
  chroot /mnt grub2-mkconfig -o /boot/grub2/grub.cfg
fi

echo "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab || { echo "ERROR: fstab generation failed."; exit 1; }

# Add crypttab if encrypted root or swap
if [[ "$root_enc" == "yes" ]] || [[ "$swap_enc" == "yes" ]]; then
  echo "Creating /etc/crypttab..."
  {
    [[ "$root_enc" == "yes" ]] && echo "cryptroot UUID=$(blkid -s UUID -o value $root_raw_part) none luks"
    [[ "$swap_enc" == "yes" ]] && echo "cryptswap UUID=$(blkid -s UUID -o value $swap_raw_part) none luks"
  } > /mnt/etc/crypttab
fi

# TODO: Add user creation, passwords, network config as needed here

# Optional: Close luks mappings opened during install (if any)
if [[ "$root_enc" == "yes" ]]; then
  cryptsetup luksClose cryptroot || true
fi
if [[ "$swap_enc" == "yes" ]]; then
  cryptsetup luksClose cryptswap || true
fi

echo "Installation complete! Please reboot."
