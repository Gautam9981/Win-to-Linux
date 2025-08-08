# Ubuntu / Fedora Prep Script for Grub2Win
# Run as Administrator

# === Select Distro ===
$distro = Read-Host "Enter distro (ubuntu or fedora)"
$distro = $distro.ToLower()

switch ($distro) {
    "ubuntu" { 
        $isoPartitionSizeGB = 7
        $fileSystemType = "FAT32"
    }
    "fedora" { 
        $isoPartitionSizeGB = 4
        $fileSystemType = "FAT32"
    }
    default { 
        Write-Error "Invalid distro. Use 'ubuntu' or 'fedora'."
        exit 1 
    }
}

# Prompt for Linux space to shrink
$linuxSpaceGB = Read-Host "Enter how many GB to shrink C: for Linux space (e.g., 150)"
if (-not ($linuxSpaceGB -as [int])) {
    Write-Error "Invalid input. Please enter a number."
    exit 1
}
$linuxSpaceGB = [int]$linuxSpaceGB
$totalShrinkGB = $linuxSpaceGB + $isoPartitionSizeGB
$partitionSizeMB = $isoPartitionSizeGB * 1024

# Prompt for ISO path
$isoPath = Read-Host "Enter full path to the $distro ISO"
if (-not (Test-Path $isoPath)) { 
    Write-Error "ISO file not found."
    exit 1 
}

# === Mount ISO ===
try {
    Write-Host "Mounting ISO..."
    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 2
    $isoVolume = ($diskImage | Get-Volume)
    $isoLabel = $isoVolume.FileSystemLabel
    $isoDriveLetter = $isoVolume.DriveLetter + ":"
    Write-Host "ISO mounted as drive $isoDriveLetter with label $isoLabel"
} catch {
    Write-Error "Could not mount ISO."
    exit 1
}

# === Shrink C: Drive ===
Write-Host "Shrinking C: by $totalShrinkGB GB..."
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "C: drive not found."; exit 1 }
$volume = Get-Volume -DriveLetter 'C'
$maxSize = (Get-PartitionSupportedSize -DriveLetter 'C').SizeMax
$newSize = $maxSize - ($totalShrinkGB * 1GB)
if ($volume.SizeRemaining -lt ($totalShrinkGB * 1GB)) { 
    Write-Error "Not enough free space."
    exit 1 
}
Resize-Partition -DriveLetter 'C' -Size $newSize -ErrorAction Stop
Write-Host "C: shrunk successfully."

# === Create ISO Partition ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
Write-Host "Creating $fileSystemType partition..."
$part = New-Partition -DiskNumber $disk.Number -Size ($partitionSizeMB * 1MB) -AssignDriveLetter
Format-Volume -Partition $part -FileSystem $fileSystemType -NewFileSystemLabel $isoLabel -Confirm:$false
$newDrive = ($part | Get-Volume).DriveLetter + ":"

# === Copy ISO contents ===
Write-Host "Copying ISO contents to $newDrive..."
Copy-Item -Path "$isoDriveLetter\*" -Destination $newDrive -Recurse -Force

# === Unmount ISO ===
Write-Host "Unmounting ISO..."
Dismount-DiskImage -ImagePath $isoPath

# === Grub2Win Code Output ===
if ($distro -eq "fedora") {
    $grubCode = @"
set root='(hd0,gpt4)'   # adjust to match FAT32 partition
linux /boot/x86_64/loader/linux root=live:CDLABEL=FEDORA rd.live.dir=/LiveOS rd.live.image nomodeset
initrd /boot/x86_64/loader/initrd.img
boot
"@
} elseif ($distro -eq "ubuntu") {
    $grubCode = @"
set root='(hd0,gpt4)'   # adjust to match FAT32 partition
linux /casper/vmlinuz boot=casper live-media-path=/casper noprompt quiet splash ---
initrd /casper/initrd
boot
"@
}

Write-Host "`n=============================================="
Write-Host "Grub2Win Custom Code for $distro"
Write-Host "=============================================="
Write-Host $grubCode
Write-Host "=============================================="
Write-Host "1. Open Grub2Win → Manage Boot Menu → Add New Entry → Custom Code"
Write-Host "2. Paste above code, adjust (hd0,gptX) if needed."
Write-Host "3. Save & reboot."
