# UEFI.ps1
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
$isoPartitionSizeGB = $isoSizeGB + 1  # 1 GB buffer

Write-Host ""
$linuxSpaceGB = Read-Host "Enter extra space (GB) to leave unallocated for Linux installation (0 for none)"
if (-not ($linuxSpaceGB -as [int])) {
    Write-Error "Invalid number."; exit 1
}
if ([int]$linuxSpaceGB -lt 0) {
    Write-Error "Linux space cannot be negative."; exit 1
}

# Bytes (Int64/UInt64 safe)
$isoPartitionSizeMB = [int64]$isoPartitionSizeGB * 1024
$isoPartitionBytes  = [int64]$isoPartitionSizeMB * 1MB
$totalShrinkGB      = [int64]$linuxSpaceGB + [int64]$isoPartitionSizeGB
$totalShrinkBytes   = [int64]$totalShrinkGB * 1GB

Write-Host "Partition for ISO: $isoPartitionSizeGB GB"
Write-Host "Extra unallocated for Linux: $linuxSpaceGB GB"
Write-Host "Total requested shrink from C: $totalShrinkGB GB"

# === Get system disk/vol ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $disk) { Write-Error "Could not determine system disk."; exit 1 }

$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "Could not locate C: partition."; exit 1 }

$volume = Get-Volume -DriveLetter 'C'
if (-not $volume) { Write-Error "Could not get C: volume information."; exit 1 }

# === Query max shrinkable size and clamp ===
$supportedSize = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPartition.PartitionNumber
$maxShrinkBytes = [int64]$supportedSize.SizeMax

if ($maxShrinkBytes -le 0) {
    Write-Error "Windows reports no shrinkable space on C:. Free up space (disable hibernation, pagefile, system restore) and try again."
    exit 1
}

# Clamp to max shrinkable
if ($totalShrinkBytes -gt $maxShrinkBytes) {
    Write-Warning "Requested shrink exceeds maximum allowed. Clamping to max shrinkable size."
    $totalShrinkBytes = $maxShrinkBytes
    $totalShrinkGB = [math]::Round($totalShrinkBytes / 1GB, 2)
}

# Must at least fit the ISO partition
if ($totalShrinkBytes -lt $isoPartitionBytes) {
    $maxGB = [math]::Round($maxShrinkBytes / 1GB, 2)
    $isoGB = [math]::Round($isoPartitionBytes / 1GB, 2)
    Write-Error "Insufficient shrinkable space. Max shrinkable: ${maxGB} GB, but ISO partition needs ${isoGB} GB. Reduce extra Linux space or free up disk space and retry."
    exit 1
}

# Also verify current free space on C: is enough for the shrink operation
if ([int64]$volume.SizeRemaining -lt $totalShrinkBytes) {
    $needGB = [math]::Round($totalShrinkBytes / 1GB, 2)
    $haveGB = [math]::Round($volume.SizeRemaining / 1GB, 2)
    Write-Error "Not enough free space on C: to perform shrink. Need ${needGB} GB free, have ${haveGB} GB."
    exit 1
}

# === Shrink C: ===
try {
    $newSize = [uint64]($volume.Size - $totalShrinkBytes)
    Resize-Partition -DriveLetter 'C' -Size $newSize -ErrorAction Stop
    Write-Host "C: shrunk by $totalShrinkGB GB"
}
catch {
    Write-Error "Resize-Partition failed: $($_.Exception.Message)"
    exit 1
}

# === Create & Format ISO Partition ===
try {
    $part = New-Partition -DiskNumber $disk.Number -Size ([uint64]$isoPartitionBytes) -AssignDriveLetter -ErrorAction Stop
} catch {
    Write-Error "New-Partition failed (no usable unallocated extent or alignment issue): $($_.Exception.Message)"
    exit 1
}

$fileSystemType = if ($isoPartitionSizeGB -le 32) { "FAT32" } else { "NTFS" }
try {
    Format-Volume -Partition $part -FileSystem $fileSystemType -NewFileSystemLabel $labelUpper -Confirm:$false -ErrorAction Stop
} catch {
    Write-Error "Format-Volume failed: $($_.Exception.Message)"
    exit 1
}

$newDriveLetter = ($part | Get-Volume).DriveLetter
$newDrive = "${newDriveLetter}:"

# === Mount & Copy ISO ===
try {
    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 3
    $isoVol = ($diskImage | Get-Volume | Select-Object -First 1)
    if (-not $isoVol) { throw "Mounted ISO volume not found." }
    $isoDriveLetter = $isoVol.DriveLetter + ":"
    Copy-Item -Path "$isoDriveLetter\*" -Destination $newDrive -Recurse -Force -ErrorAction Stop
} catch {
    Write-Error "ISO copy failed: $($_.Exception.Message)"
    try { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue } catch {}
    exit 1
}
# Always try to dismount
try { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue } catch {}

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
