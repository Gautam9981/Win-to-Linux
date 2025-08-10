# unified.ps1
# Ubuntu / Fedora / Mint Prep Script for Grub2Win
# Run as Administrator

# === Menu Selection ===
Write-Host "Select Distro:"
Write-Host "1) Ubuntu 24.04.3 LTS"
Write-Host "2) Fedora KDE 42-1.1"
Write-Host "3) Linux Mint 22.1 Cinnamon"
$distroChoice = Read-Host "Enter number"

switch ($distroChoice) {
    "1" { 
        $distro = "ubuntu"
        $isoUrls = @(
            "https://mirror.math.princeton.edu/pub/ubuntu-iso/noble/ubuntu-24.04.3-desktop-amd64.iso",
            "https://mirrors.kernel.org/ubuntu-releases/24.04.3/ubuntu-24.04.3-desktop-amd64.iso"
        )
        $isoPartitionSizeGB = 7
    }
    "2" { 
        $distro = "fedora"
        $isoUrls = @(
            "https://mirror.arizona.edu/fedora/linux/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso",
            "https://mirrors.kernel.org/fedora/releases/42/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-42-1.1.x86_64.iso"
        )
        $isoPartitionSizeGB = 4
    }
    "3" { 
        $distro = "mint"
        $isoUrls = @(
            "https://mirrors.ocf.berkeley.edu/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso",
            "https://mirrors.kernel.org/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
        )
        $isoPartitionSizeGB = 4
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

# Prompt for Linux space to shrink
$linuxSpaceGB = Read-Host "Enter how many GB to shrink C: for Linux space (e.g., 150)"
if (-not ($linuxSpaceGB -as [int])) { Write-Error "Invalid input. Please enter a number."; exit 1 }
$linuxSpaceGB = [int]$linuxSpaceGB
$totalShrinkGB = $linuxSpaceGB + $isoPartitionSizeGB
$partitionSizeMB = $isoPartitionSizeGB * 1024

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

# === Shrink C: Drive ===
Write-Host "Shrinking C: by $totalShrinkGB GB..."
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "C: drive not found."; exit 1 }
$volume = Get-Volume -DriveLetter 'C'
if ($volume.SizeRemaining -lt ($totalShrinkGB * 1GB)) { Write-Error "Not enough free space."; exit 1 }
Resize-Partition -DriveLetter 'C' -Size ($volume.Size - ($totalShrinkGB * 1GB)) -ErrorAction Stop
Write-Host "C: shrunk successfully."

# === Create ISO Partition with uppercase label ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
Write-Host "Creating $fileSystemType partition with label $labelUpper..."
$part = New-Partition -DiskNumber $disk.Number -Size ($partitionSizeMB * 1MB) -AssignDriveLetter
Format-Volume -Partition $part -FileSystem $fileSystemType -NewFileSystemLabel $labelUpper -Confirm:$false
$newDrive = ($part | Get-Volume).DriveLetter + ":"

# === Copy ISO contents ===
Write-Host "Copying ISO contents to $newDrive..."
Copy-Item -Path "$isoDriveLetter\*" -Destination $newDrive -Recurse -Force

# === Unmount ISO ===
Write-Host "Unmounting ISO..."
Dismount-DiskImage -ImagePath $isoPath

# === Auto-detect kernel/initrd ===
$kernel = Get-ChildItem -Path $newDrive -Recurse -Include "vmlinuz*" | Select-Object -First 1
$initrd = Get-ChildItem -Path $newDrive -Recurse -Include "initrd*" | Select-Object -First 1

# Clean paths to relative inside partition, using forward slashes
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

# === Grub2Win Code Output ===
switch ($distro) {
    "ubuntu" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /$kernelName boot=casper live-media-path=/casper cdrom-detect/try-usb=true iso-scan/filename=/$labelUpper noprompt quiet splash ---
initrd /$initrdName
boot
"@
    }
    "fedora" {
        $grubCode = @"
set root=(hd0,gpt4)   # adjust to match FAT32 partition
linux /boot/x86_64/loader/linux root=live:CDLABEL=$labelUpper rd.live.dir=/LiveOS rd.live.image nomodeset
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
}

Write-Host "`n=============================================="
Write-Host "Grub2Win Custom Code for $distro ($labelUpper)"
Write-Host "=============================================="
Write-Host $grubCode
Write-Host "=============================================="
Write-Host "1. Open Grub2Win → Manage Boot Menu → Add New Entry → Custom Code"
Write-Host "2. Paste above code, adjust (hd0,gptX) if needed."
Write-Host "3. Save & reboot."

