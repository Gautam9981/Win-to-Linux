# unified.ps1
# Ubuntu / Fedora / Mint / Void / Arch / Debian Trixie Prep Script for Grub2Win
# Run as Administrator

# === Prompt firmware type ===
Write-Host "Firmware type detection is disabled."
Write-Host "This script supports UEFI only."
$firmwareType = "UEFI"

# === Menu Selection ===
Write-Host 'Select Distro:'
Write-Host '1) Ubuntu 24.04.3 LTS'
Write-Host '2) Fedora KDE 42-1.1'
Write-Host '3) Linux Mint 22.1 Cinnamon'
Write-Host '4) Void Linux (x86_64 glibc Base)'
Write-Host '5) Arch Linux'
Write-Host '6) Debian 13.0 Trixie GNOME Live'
$distroChoice = Read-Host 'Enter number'

switch ($distroChoice) {
    "1" {
        $distro = "ubuntu"
        $isoUrls = @(
            "https://mirror.math.princeton.edu/pub/ubuntu-iso/noble/ubuntu-24.04.3-desktop-amd64.iso",
            "https://mirrors.kernel.org/ubuntu-releases/24.04.3/ubuntu-24.04.3-desktop-amd64.iso"
        )
    }
    "2" {
        $distro = "fedora"
        $isoUrls = @(
            "https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso",
            "https://mirrors.kernel.org/fedora/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
        )
    }
    "3" {
        $distro = "mint"
        $isoUrls = @(
            "https://mirrors.ocf.berkeley.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso",
            "https://mirrors.kernel.org/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
        )
    }
    "4" {
        $distro = "void"
        $isoUrls = @(
            "https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso",
            "https://mirrors.servercentral.com/voidlinux/live/current/void-live-x86_64-20250202-base.iso"
        )
    }
    "5" {
        $distro = "arch"
        $isoUrls = @(
            "https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso",
            "https://mirror.archlinux32.org/iso/latest/archlinux-x86_64.iso"
        )
    }
    "6" {
        $distro = "debian"
        $isoUrls = @(
            "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.0.0-amd64-gnome.iso",
            "https://mirrors.kernel.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.0.0-amd64-gnome.iso"
        )
    }
    default { Write-Error "Invalid selection."; exit 1 }
}

# Uppercase label
$labelUpper = $distro.ToUpper()
$downloadsFolder = Join-Path $env:USERPROFILE "Downloads"
$isoPath = Join-Path $downloadsFolder "$distro.iso"

# === Download Function ===
function Download-ISO {
    param([string[]]$urls, [string]$outputPath)
    foreach ($url in $urls) {
        Write-Host "Attempting download from $url ..."
        try {
            & curl.exe -L --progress-bar -o $outputPath $url
            if (Test-Path $outputPath) {
                $size = (Get-Item $outputPath).Length
                if ($size -gt 1GB) {
                    Write-Host "Download successful from $url"
                    return $true
                }
            }
        } catch {
            Write-Warning "Failed to download from $url"
        }
    }
    return $false
}

# === Download ISO if missing ===
if (-not (Test-Path $isoPath)) {
    if (-not (Download-ISO -urls $isoUrls -outputPath $isoPath)) {
        Write-Error "All download attempts failed."
        exit 1
    }
} else {
    Write-Host "ISO already exists at $isoPath"
}

# === Partition Sizing ===
$isoSizeBytes = (Get-Item $isoPath).Length
$isoSizeGB = [math]::Ceiling($isoSizeBytes / 1GB)
$isoPartitionSizeGB = $isoSizeGB + 1
Write-Host "Partition size: $isoPartitionSizeGB GB"

$linuxSpaceGB = 0
$totalShrinkGB = $linuxSpaceGB + $isoPartitionSizeGB
$partitionSizeMB = $isoPartitionSizeGB * 1024

# === Get system disk ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
$volume = Get-Volume -DriveLetter 'C'

$totalShrinkBytes = $totalShrinkGB * 1GB
if ($volume.SizeRemaining -lt $totalShrinkBytes) {
    Write-Error "Not enough free space."
    exit 1
}

$supportedSize = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPartition.PartitionNumber
if ($supportedSize.SizeMax -lt $totalShrinkBytes) {
    Write-Error "Shrink size exceeds limit."
    exit 1
}

# === Shrink C: ===
Resize-Partition -DriveLetter 'C' -Size ($volume.Size - $totalShrinkBytes)
Write-Host "C: shrunk by $totalShrinkGB GB"

# === Create & Format Partition ===
$part = New-Partition -DiskNumber $disk.Number -Size ($partitionSizeMB * 1MB) -AssignDriveLetter
$fileSystemType = if ($isoPartitionSizeGB -le 32) { "FAT32" } else { "NTFS" }
Format-Volume -Partition $part -FileSystem $fileSystemType -NewFileSystemLabel $labelUpper -Confirm:$false

$newDriveLetter = ($part | Get-Volume).DriveLetter
$newDrive = "${newDriveLetter}:"

# === Mount & Copy ISO ===
$diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
Start-Sleep -Seconds 3
$isoDriveLetter = ($diskImage | Get-Volume).DriveLetter + ":"
Copy-Item -Path "$isoDriveLetter\*" -Destination $newDrive -Recurse -Force
Dismount-DiskImage -ImagePath $isoPath

# === Root Partition for UEFI ===
$rootPartition = "(hd0,gpt$($part.PartitionNumber))"
$isoFileName = Split-Path $isoPath -Leaf

# === GRUB2WIN Configs ===
switch ($distro) {
    "ubuntu" {
        $grubCode = @"
set root=$rootPartition
linux /casper/vmlinuz boot=casper noprompt quiet splash ---
initrd /casper/initrd
boot
"@
    }
    "fedora" {
        $grubCode = @"
set root=$rootPartition
linux /boot/x86_64/loader/linux root=live:CDLABEL=FEDORA quiet rhgb rd.live.image
initrd /boot/x86_64/loader/initrd
boot
"@
    }
    "mint" {
        $grubCode = @"
set root=$rootPartition
linux /casper/vmlinuz boot=casper quiet splash ---
initrd /casper/initrd.lz
boot
"@
    }
    "void" {
        $grubCode = @"
set root=$rootPartition
linux /boot/vmlinuz root=live:LABEL=VOID initrd=initrd.img
initrd /boot/initrd
boot
"@
    }
    "arch" {
        $grubCode = @"
set root=$rootPartition
linux /arch/boot/x86_64/vmlinuz-linux archisobasedir=arch archisolabel=ARCH
initrd /arch/boot/x86_64/initramfs-linux.img
boot
"@
    }
    "debian" {
        $grubCode = @"
set root=$rootPartition
linux /live/vmlinuz boot=live quiet splash
initrd /live/initrd.img
boot
"@
        $manualDebianCode = @"
# Manual Fallback - Debian 13.0 Trixie GNOME Live
set root=$rootPartition
linux /live/vmlinuz boot=live quiet splash
initrd /live/initrd.img
boot
"@
    }
}

# === Output Config ===
Write-Host "Copy this GRUB2WIN menu entry:"
Write-Host "-----------------------------------"
Write-Host $grubCode
Write-Host "-----------------------------------"
Write-Host "Boot label: $labelUpper"
Write-Host "ISO File: $isoFileName"
Write-Host "Partition: $rootPartition"

if ($distro -eq "debian") {
    Write-Host ""
    Write-Host "Manual Debian Live GRUB2Win config (fallback):"
    Write-Host "-----------------------------------"
    Write-Host $manualDebianCode
    Write-Host "-----------------------------------"
}
