# unified.ps1
# Ubuntu / Fedora / Mint / Void / Arch Prep Script for Grub2Win
# Run as Administrator

# === Menu Selection ===
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

# === Dynamically set ISO partition size from file size + margin ===
$isoSizeBytes = (Get-Item $isoPath).Length
$isoSizeGB = [math]::Ceiling($isoSizeBytes / 1GB)
$isoPartitionSizeGB = $isoSizeGB + 1   # +1 GB margin for safety
Write-Host "Calculated ISO partition size: $isoPartitionSizeGB GB"

# Prompt for Linux space to shrink (can be 0)
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

# === Shrink C: Drive by totalShrinkGB (Linux + ISO) ===
Write-Host "Shrinking C: by $totalShrinkGB GB..."
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "C: drive not found."; exit 1 }

$volume = Get-Volume -DriveLetter 'C'
$totalShrinkBytes = $totalShrinkGB * 1GB

if ($volume.SizeRemaining -lt $totalShrinkBytes) {
    Write-Error "Not enough free space on C: to shrink by $totalShrinkGB GB."
    exit 1
}

try {
    Resize-Partition -DriveLetter 'C' -Size ($volume.Size - $totalShrinkBytes) -ErrorAction Stop
    Write-Host "C: shrunk successfully."
} catch {
    Write-Error "Failed to shrink C: drive. $_"
    exit 1
}

# === Check free unallocated space for ISO partition creation ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
$supportedSize = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPartition.PartitionNumber

if ($supportedSize.SizeMax -lt $totalShrinkGB * 1GB) {
    Write-Error "You can only shrink C: by up to $([math]::Round($supportedSize.SizeMax / 1GB)) GB, which is less than the required $totalShrinkGB GB."
    exit 1
}

Resize-Partition -DriveLetter 'C' -Size ($volume.Size - $totalShrinkGB * 1GB)


# === Create ISO Partition with uppercase label ===
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

# === Auto-detect kernel/initrd ===
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

# === Grub2Win Code Output ===
switch ($distro) {
    "ubuntu" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /$kernelName boot=casper noprompt quiet splash ---
initrd /$initrdName
boot
"@
    }
    "fedora" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /boot/x86_64/loader/linux root=live:CDLABEL=FEDORA rd.live.dir=/LiveOS rd.live.image nomodeset
initrd /boot/x86_64/loader/initrd
boot
"@
    }
    "mint" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /$kernelName boot=casper quiet splash ---
initrd /$initrdName
boot
"@
    }
    "void" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /$kernelName root=live:CDLABEL=$labelUpper img_dev=/dev/disk/by-label/$labelUpper img_loop=/$isoFileName
initrd /$initrdName
boot
"@
    }
    "arch" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /arch/boot/x86_64/vmlinuz-linux archisobasedir=arch archisolabel=$labelUpper
initrd /arch/boot/x86_64/initramfs-linux.img
boot
"@
    }
}

Write-Host "`n=============================================="
Write-Host "Grub2Win Custom Code for $distro ($labelUpper)"
Write-Host "=============================================="
Write-Host $grubCode
Write-Host "=============================================="
Write-Host "1. Open Grub2Win → Manage Boot Menu → Add New Entry → Custom Code"
Write-Host "2. Paste above code, adjust (hd0,gptX) if needed."
Write-Host "3. Save & reboot."

