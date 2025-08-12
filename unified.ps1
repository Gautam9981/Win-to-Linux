# unified.ps1
# Ubuntu / Fedora / Mint / Void / Arch Prep Script for Grub2Win
# Run as Administrator

# === Prompt user for firmware type manually ===
Write-Host "Firmware type detection is disabled."
Write-Host "Please enter firmware type manually (UEFI or LegacyBIOS):"
while ($true) {
    $firmwareTypeInput = Read-Host "Firmware Type"
    if ($firmwareTypeInput -match "^(UEFI|LegacyBIOS)$") {
        $firmwareType = $firmwareTypeInput
        break
    } else {
        Write-Warning "Invalid input. Please enter exactly 'UEFI' or 'LegacyBIOS'."
    }
}

if ($firmwareType -notin @("UEFI", "LegacyBIOS")) {
    Write-Warning "Firmware detection uncertain. Defaulting to Legacy BIOS boot."
    $firmwareType = "LegacyBIOS"
}

# === Menu Selection ===
Write-Host 'Select Distro:'
Write-Host '1) Ubuntu 24.04.3 LTS'
Write-Host '2) Fedora KDE 42-1.1'
Write-Host '3) Linux Mint 22.1 Cinnamon'
Write-Host '4) Void Linux (x86_64 glibc Base)'
Write-Host '5) Arch Linux'
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
    default { Write-Error "Invalid selection."; exit 1 }
}

# Make uppercase label
$labelUpper = $distro.ToUpper()
$fileSystemType = "FAT32"
$downloadsFolder = Join-Path $env:USERPROFILE "Downloads"
$isoPath = Join-Path $downloadsFolder "$distro.iso"

# === Function: Download ISO ===
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
                } else {
                    Write-Warning "Downloaded file too small (<1GB), trying next mirror..."
                }
            }
        } catch {
            Write-Warning "Failed to download from $url"
        }
    }
    Write-Error "All download attempts failed."
    return $false
}

# === Download ISO if not exists ===
if (-not (Test-Path $isoPath)) {
    if (-not (Download-ISO -urls $isoUrls -outputPath $isoPath)) { exit 1 }
} else {
    Write-Host "ISO already exists at $isoPath"
}

# === Calculate ISO partition size (ISO file size + 1 GB margin) ===
$isoSizeBytes = (Get-Item $isoPath).Length
$isoSizeGB = [math]::Ceiling($isoSizeBytes / 1GB)
$isoPartitionSizeGB = $isoSizeGB + 1   # +1 GB margin for safety
Write-Host "Calculated ISO partition size: $isoPartitionSizeGB GB"

# === Prompt for Linux space to shrink (can be 0) ===
while ($true) {
    $linuxSpaceInput = Read-Host "Enter how many GB to shrink C: for Linux space (enter 0 to skip shrinking for Linux)"
    if ([int]::TryParse($linuxSpaceInput, [ref]$null) -and [int]$linuxSpaceInput -ge 0) {
        $linuxSpaceGB = [int]$linuxSpaceInput
        break
    } else {
        Write-Warning "Invalid input. Please enter a non-negative integer."
    }
}

$totalShrinkGB = $linuxSpaceGB + $isoPartitionSizeGB
$partitionSizeMB = $isoPartitionSizeGB * 1024

# === Get system disk ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $disk) {
    Write-Error "System disk not found."
    exit 1
}

# === Get C: partition and volume ===
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "C: drive partition not found."; exit 1 }
$volume = Get-Volume -DriveLetter 'C'

# Check free space on C:
$totalShrinkBytes = $totalShrinkGB * 1GB
if ($volume.SizeRemaining -lt $totalShrinkBytes) {
    Write-Error "Not enough free space on C: to shrink by $totalShrinkGB GB."
    exit 1
}

# === Check supported shrink size and resize ===
$supportedSize = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPartition.PartitionNumber
if ($supportedSize.SizeMax -lt $totalShrinkBytes) {
    Write-Error "Maximum shrink size allowed: $([math]::Round($supportedSize.SizeMax / 1GB)) GB, less than required $totalShrinkGB GB."
    exit 1
}

try {
    Resize-Partition -DriveLetter 'C' -Size ($volume.Size - $totalShrinkBytes) -ErrorAction Stop
    Write-Host "C: partition shrunk by $totalShrinkGB GB successfully."
} catch {
    Write-Error "Failed to shrink C: drive. $_"
    exit 1
}

# === Create ISO Partition ===
Write-Host "Creating $fileSystemType partition with label $labelUpper..."
$part = New-Partition -DiskNumber $disk.Number -Size ($partitionSizeMB * 1MB) -AssignDriveLetter
Format-Volume -Partition $part -FileSystem $fileSystemType -NewFileSystemLabel $labelUpper -Confirm:$false
$newDriveLetter = ($part | Get-Volume).DriveLetter
$newDrive = "${newDriveLetter}:"

# === Mount ISO ===
try {
    Write-Host "Mounting ISO..."
    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 3
    $isoVolume = ($diskImage | Get-Volume)
    $isoDriveLetter = $isoVolume.DriveLetter + ":"
    Write-Host "ISO mounted as drive $isoDriveLetter"
} catch {
    Write-Error "Could not mount ISO."
    exit 1
}

# === Copy ISO contents ===
Write-Host "Copying ISO contents to $newDrive..."
Copy-Item -Path "$isoDriveLetter\*" -Destination $newDrive -Recurse -Force

# === Unmount ISO ===
Write-Host "Unmounting ISO..."
Dismount-DiskImage -ImagePath $isoPath

# === Determine root partition for GRUB syntax based on firmware and partition style ===
$partitionStyle = $disk.PartitionStyle
Write-Host "Detected partition style: $partitionStyle"
$rootPartition = ""

if ($firmwareType -eq "UEFI" -and $partitionStyle -eq "GPT") {
    $rootPartition = "(hd0,gpt" + $part.PartitionNumber + ")"
    Write-Host "Selected boot mode: UEFI"
} elseif ($firmwareType -eq "LegacyBIOS") {
    $rootPartition = "(hd0,msdos" + $part.PartitionNumber + ")"
    Write-Host "Selected boot mode: Legacy BIOS"
} else {
    Write-Warning "Firmware and partition style combination not fully supported or uncertain. Defaulting to Legacy BIOS syntax."
    $rootPartition = "(hd0,msdos" + $part.PartitionNumber + ")"
}

# === Auto-detect kernel and initrd files on new ISO partition ===
$kernel = Get-ChildItem -Path $newDrive -Recurse -Include "vmlinuz*" -ErrorAction SilentlyContinue | Select-Object -First 1
$initrd = Get-ChildItem -Path $newDrive -Recurse -Include "initrd*" -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $kernel) { 
    $kernelName = "vmlinuz" 
} else { 
    $kernelName = $kernel.FullName.Replace("$newDrive\", "").Replace('\','/') 
}
if (-not $initrd) { 
    $initrdName = "initrd" 
} else { 
    $initrdName = $initrd.FullName.Replace("$newDrive\", "").Replace('\','/') 
}

$isoFileName = Split-Path $isoPath -Leaf

# === Generate GRUB2WIN custom boot entry code ===
switch ($distro) {
    "ubuntu" {
        $grubCode = @"
set root=$rootPartition
linux /$kernelName boot=casper noprompt quiet splash ---
initrd /$initrdName
boot
"@
    }
    "fedora" {
        $grubCode = @"
set root=$rootPartition
linux /boot/x86_64/loader/linux root=live:CDLABEL=$labelUpper quiet rhgb rd.live.image
initrd /$initrdName
boot
"@
    }
    "mint" {
        $grubCode = @"
set root=$rootPartition
linux /$kernelName boot=casper quiet splash ---
initrd /$initrdName
boot
"@
    }
    "void" {
        $grubCode = @"
set root=$rootPartition
linux /$kernelName root=live:$labelUpper initrd=initrd.img
initrd /$initrdName
boot
"@
    }
    "arch" {
        $grubCode = @"
set root=$rootPartition
linux /$kernelName archisobasedir=arch archisolabel=$labelUpper
initrd /$initrdName
boot
"@
    }
    default {
        $grubCode = ""
    }
}

# === Output GRUB2WIN entry ===
Write-Host "Copy this GRUB2WIN menu entry:"
Write-Host "-----------------------------------"
Write-Host $grubCode
Write-Host "-----------------------------------"
Write-Host "Boot label: $labelUpper"
Write-Host "ISO File: $isoFileName"
Write-Host "Partition: $rootPartition"
