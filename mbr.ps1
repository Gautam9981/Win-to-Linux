# legacy-mbr.ps1
# Live Linux ISO Prep for Grub2Win - Legacy BIOS / MBR Disks
# Run as Administrator

Write-Host "=== Legacy BIOS / MBR Linux ISO Prep Script ===" -ForegroundColor Cyan

# Check partition style
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if ($disk.PartitionStyle -ne "MBR") {
    Write-Error "This script only works on MBR disks (Legacy BIOS). Aborting."
    exit 1
}

# Menu selection
Write-Host "Select Distro:"
Write-Host "1) Ubuntu 24.04.3 LTS"
Write-Host "2) Fedora KDE 42-1.1"
Write-Host "3) Linux Mint 22.1 Cinnamon"
Write-Host "4) Void Linux (x86_64 glibc Base)"
Write-Host "5) Arch Linux"
$distroChoice = Read-Host "Enter number"

switch ($distroChoice) {
    "1" { 
        $distro = "ubuntu"
        $isoUrl = "https://mirrors.kernel.org/ubuntu-releases/24.04.3/ubuntu-24.04.3-desktop-amd64.iso"
    }
    "2" { 
        $distro = "fedora"
        $isoUrl = "https://mirrors.kernel.org/fedora/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
    }
    "3" { 
        $distro = "mint"
        $isoUrl = "https://mirrors.kernel.org/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
    }
    "4" { 
        $distro = "void"
        $isoUrl = "https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso"
    }
    "5" { 
        $distro = "arch"
        $isoUrl = "https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
    }
    default { Write-Error "Invalid selection"; exit 1 }
}

# Download ISO
$downloadsFolder = Join-Path $env:USERPROFILE "Downloads"
$isoPath = Join-Path $downloadsFolder "$distro.iso"
if (-not (Test-Path $isoPath)) {
    Write-Host "Downloading ISO..."
    & curl.exe -L --progress-bar -o $isoPath $isoUrl
}

# Calculate size (+1 GB)
$isoSizeBytes = (Get-Item $isoPath).Length
$isoSizeGB = [math]::Ceiling($isoSizeBytes / 1GB) + 1

# Ask shrink amount
$linuxSpaceGB = [int](Read-Host "Enter GB to shrink C: for Linux (0 for none)")
$totalShrinkGB = $isoSizeGB + $linuxSpaceGB
$totalShrinkBytes = $totalShrinkGB * 1GB

# Get C: partition
$cPart = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
$volume = Get-Volume -DriveLetter 'C'
$supportedSize = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPart.PartitionNumber
if ($supportedSize.SizeMax -lt $totalShrinkBytes) {
    Write-Error "Not enough shrink space"
    exit 1
}

# Shrink C:
Resize-Partition -DriveLetter 'C' -Size ($volume.Size - $totalShrinkBytes)
Write-Host "C: shrunk successfully"

# Create FAT32 partition
$part = New-Partition -DiskNumber $disk.Number -Size ($isoSizeGB * 1GB) -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $distro.ToUpper() -Confirm:$false
$newDrive = ($part | Get-Volume).DriveLetter + ":"

# Mount ISO
$diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
$isoDrive = ($diskImage | Get-Volume).DriveLetter + ":"

# Copy files
Copy-Item "$isoDrive\*" -Destination $newDrive -Recurse -Force
Dismount-DiskImage -ImagePath $isoPath

# Get partition number for GRUB
$rootPartition = "(hd0,msdos$($part.PartitionNumber))"

# Distro boot params
switch ($distro) {
    "ubuntu" { $bootCmd = "linux /casper/vmlinuz boot=casper quiet splash ---`ninitrd /casper/initrd" }
    "mint"   { $bootCmd = "linux /casper/vmlinuz boot=casper quiet splash ---`ninitrd /casper/initrd" }
    "fedora" { $bootCmd = "linux /isolinux/vmlinuz root=live:CDLABEL=$($distro.ToUpper()) quiet rd.live.image`ninitrd /isolinux/initrd.img" }
    "void"   { $bootCmd = "linux /boot/vmlinuz root=live:$($distro.ToUpper()) initrd=initrd.img`ninitrd /boot/initrd.img" }
    "arch"   { $bootCmd = "linux /arch/boot/x86_64/vmlinuz archisobasedir=arch archisolabel=$($distro.ToUpper())`ninitrd /arch/boot/x86_64/initrd" }
}

# Output GRUB entry
Write-Host "`n=== GRUB2Win Entry ==="
Write-Host "set root=$rootPartition"
Write-Host $bootCmd
Write-Host "boot"