#!/bin/bash
set -e

echo "== Debian Installation Process =="

cat <<'EOF'

--- Manual Partitioning Instructions ---

If you prefer to manually partition your drive instead of wiping and auto-partitioning with this script, please use the Debian Live environment’s GUI tool:

1. Boot into the Debian Live environment (e.g., GNOME, KDE, or Cinnamon Live ISO).
2. Launch **GParted** from the applications menu.
3. Identify your target disk carefully.
4. Using GParted:
   - Create a new partition table (GPT for UEFI or MSDOS for Legacy BIOS).
   - Create the following partitions:
     * EFI System Partition (FAT32, 512 MiB) — required only for UEFI systems.
     * Root partition (ext4) — your main system partition.
     * Swap partition (linux-swap), optional.
   - To use encryption:
     * Set up LUKS encryption manually via the terminal.
     * Or create partitions now and encrypt them afterward using `cryptsetup`.
5. Apply changes and close GParted.

Once done, return to this script and enter the partition paths when prompted.

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

# Firmware type
read -p "Enter firmware type (UEFI or LegacyBIOS): " fw_type
fw_type=$(echo "$fw_type" | tr '[:upper:]' '[:lower:]')
if [[ "$fw_type" != "uefi" && "$fw_type" != "legacybios" ]]; then
  echo "Invalid firmware type."
  exit 1
fi

# Desktop selection
echo "Choose Desktop Environment:"
echo "1) GNOME (default)"
echo "2) KDE Plasma"
echo "3) Cinnamon"
read -p "Enter choice (1-3): " de_choice
case $de_choice in
  2) de_task="kde-desktop";;
  3) de_task="cinnamon-desktop";;
  *) de_task="gnome-desktop";;
esac

# Encryption
read -p "Do you want encrypted root? (yes/no): " root_enc
root_enc=$(echo "$root_enc" | tr '[:upper:]' '[:lower:]')
read -p "Do you want encrypted swap? (yes/no): " swap_enc
swap_enc=$(echo "$swap_enc" | tr '[:upper:]' '[:lower:]')

if [[ "$wipe_answer" == "yes" ]]; then
  echo "WARNING: This will ERASE ALL DATA on $disk."
  read -p "Type YES to confirm: " confirm
  [ "$confirm" != "YES" ] && { echo "Aborted."; exit 1; }

  read -p "Enter desired swap size in MiB (0 for no swap): " swap_size_mib
  [[ ! "$swap_size_mib" =~ ^[0-9]+$ ]] && { echo "Invalid swap size."; exit 1; }

  wipefs -a "$disk"
  dd if=/dev/zero of="$disk" bs=1M count=10 status=progress conv=fdatasync

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
  fi

  if [ "$fw_type" == "uefi" ]; then
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 "${efi_start}s" "${efi_end}s"
    parted --script "$disk" set 1 boot on
    parted --script "$disk" mkpart primary ext4 "${boot_start}s" "${boot_end}s"
    parted --script "$disk" mkpart primary ext4 "${root_start}s" "${root_end}s"
    [ "$swap_size_mib" -gt 0 ] && parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "${swap_end}s"
    efi_part="${disk}p1"
    boot_part="${disk}p2"
    root_raw_part="${disk}p3"
    [ "$swap_size_mib" -gt 0 ] && swap_raw_part="${disk}p4"
  else
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary ext4 "${boot_start}s" "${boot_end}s"
    parted --script "$disk" set 1 boot on
    parted --script "$disk" mkpart primary ext4 "${root_start}s" "${root_end}s"
    [ "$swap_size_mib" -gt 0 ] && parted --script "$disk" mkpart primary linux-swap "${swap_start}s" "${swap_end}s"
    boot_part="${disk}p1"
    root_raw_part="${disk}p2"
    [ "$swap_size_mib" -gt 0 ] && swap_raw_part="${disk}p3"
  fi

  [ "$fw_type" == "uefi" ] && mkfs.fat -F32 "$efi_part"
  mkfs.ext4 "$boot_part"

  if [[ "$root_enc" == "yes" ]]; then
    cryptsetup luksFormat "$root_raw_part"
    cryptsetup luksOpen "$root_raw_part" cryptroot
    root_part="/dev/mapper/cryptroot"
    mkfs.ext4 "$root_part"
  else
    root_part="$root_raw_part"
    mkfs.ext4 "$root_part"
  fi

  if [ -n "$swap_raw_part" ]; then
    if [[ "$swap_enc" == "yes" ]]; then
      cryptsetup luksFormat "$swap_raw_part"
      cryptsetup luksOpen "$swap_raw_part" cryptswap
      mkswap /dev/mapper/cryptswap
      swapon /dev/mapper/cryptswap
    else
      mkswap "$swap_raw_part"
      swapon "$swap_raw_part"
    fi
  fi

  mount "$root_part" /mnt
  mkdir -p /mnt/boot
  mount "$boot_part" /mnt/boot
  [ "$fw_type" == "uefi" ] && mkdir -p /mnt/boot/efi && mount "$efi_part" /mnt/boot/efi
else
  echo "Manual partitioning mode..."
  if [ "$fw_type" == "uefi" ]; then read -p "Enter EFI partition: " efi_part; fi
  read -p "Enter boot partition: " boot_part
  read -p "Is root encrypted? (yes/no): " root_enc
  root_enc=$(echo "$root_enc" | tr '[:upper:]' '[:lower:]')
  if [[ "$root_enc" == "yes" ]]; then
    read -p "Enter encrypted root partition: " root_raw_part
    cryptsetup luksOpen "$root_raw_part" cryptroot
    root_part="/dev/mapper/cryptroot"
  else
    read -p "Enter root partition: " root_part
  fi
  read -p "Is swap encrypted? (yes/no): " swap_enc
  swap_enc=$(echo "$swap_enc" | tr '[:upper:]' '[:lower:]')
  if [[ "$swap_enc" == "yes" ]]; then
    read -p "Enter encrypted swap partition: " swap_raw_part
    cryptsetup luksOpen "$swap_raw_part" cryptswap
    mkswap /dev/mapper/cryptswap && swapon /dev/mapper/cryptswap
  else
    read -p "Enter swap partition (blank for none): " swap_part
    [ -n "$swap_part" ] && mkswap "$swap_part" && swapon "$swap_part"
  fi
  mount "$root_part" /mnt
  mkdir -p /mnt/boot
  mount "$boot_part" /mnt/boot
  [ "$fw_type" == "uefi" ] && mkdir -p /mnt/boot/efi && mount "$efi_part" /mnt/boot/efi
fi

for fs in sys dev proc run; do
  mount --bind /$fs /mnt/$fs
done

echo "Installing base Debian system..."
debootstrap --arch amd64 stable /mnt http://deb.debian.org/debian

echo "Configuring APT sources..."
cat <<APT > /mnt/etc/apt/sources.list
deb http://deb.debian.org/debian stable main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security stable-security main contrib non-free non-free-firmware
APT

chroot /mnt apt update
chroot /mnt apt install -y task-$de_task locales sudo

echo "Installing bootloader..."
if [ "$fw_type" == "uefi" ]; then
  chroot /mnt apt install -y grub-efi-amd64 shim
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
  chroot /mnt update-grub
else
  chroot /mnt apt install -y grub-pc
  chroot /mnt grub-install --target=i386-pc "$disk"
  chroot /mnt update-grub
fi

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

if [[ "$root_enc" == "yes" ]] || [[ "$swap_enc" == "yes" ]]; then
  echo "Creating crypttab..."
  {
    [[ "$root_enc" == "yes" ]] && echo "cryptroot UUID=$(blkid -s UUID -o value $root_raw_part) none luks"
    [[ "$swap_enc" == "yes" ]] && echo "cryptswap UUID=$(blkid -s UUID -o value $swap_raw_part) none luks"
  } > /mnt/etc/crypttab
fi

echo "=== User Setup ==="
read -p "Enter username: " new_user
chroot /mnt useradd -m -G sudo "$new_user"
echo "Set password for $new_user:"
chroot /mnt passwd "$new_user"
chroot /mnt passwd -l root

echo "Installation complete! You can reboot now."
