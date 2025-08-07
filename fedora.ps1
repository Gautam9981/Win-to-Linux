# Fedora Prep Script: Shrinks C: by user-specified amount, creates FAT32 partition for ISO contents, outputs Grub2Win config
# Run as Administrator

# === CONFIG ===
$volumeLabel = "VENTOY"
$isoPartitionSizeGB = 5

# Prompt user for Linux space to shrink
$linuxSpaceGB = Read-Host "Enter how many GB to shrink C: for Linux space (e.g., 150)"
if (-not ($linuxSpaceGB -as [int])) {
    Write-Error "Invalid input. Please enter a number."
    exit 1
}
$linuxSpaceGB = [int]$linuxSpaceGB
$totalShrinkGB = $linuxSpaceGB + $isoPartitionSizeGB
$fat32PartitionSizeMB = $isoPartitionSizeGB * 1024

# === Shrink C: Drive ===
Write-Host "Shrinking C: by $totalShrinkGB GB..."
$cPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
if (-not $cPartition) { Write-Error "C: drive not found."; exit 1 }
$volume = Get-Volume -DriveLetter 'C'
$maxSize = (Get-PartitionSupportedSize -DriveLetter 'C').SizeMax
$newSize = $maxSize - ($totalShrinkGB * 1GB)
if ($volume.SizeRemaining -lt ($totalShrinkGB * 1GB)) { Write-Error "Not enough free space."; exit 1 }
Resize-Partition -DriveLetter 'C' -Size $newSize -ErrorAction Stop
Write-Host "C: shrunk successfully."

# === Wait for Unallocated Space ===
$disk = Get-Disk | Where-Object { $_.IsSystem -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $disk) { Write-Error "System disk not found."; exit 1 }
Write-Host "Waiting for unallocated space..."
$maxRetries = 10; $count = 0; $ready = $false
while ($count -lt $maxRetries) {
    Start-Sleep -Seconds 3
    try {
        $sup = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $cPartition.PartitionNumber
        $freeSpace = $sup.SizeMax - $newSize
        if ($freeSpace -ge ($isoPartitionSizeGB * 1GB)) { $ready = $true; break }
    } catch {}
    $count++
}
if (-not $ready) { Write-Error "Timeout waiting for unallocated space."; exit 1 }
Write-Host "Unallocated space ready."

# === Create FAT32 Partition ===
Write-Host "Creating FAT32 partition..."
$part = New-Partition -DiskNumber $disk.Number -Size ($fat32PartitionSizeMB * 1MB) -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $volumeLabel -Confirm:$false
$newDrive = ($part | Get-Volume).DriveLetter + ":"

# === Final Instructions ===
$instructions = @"
==============================================
Manual Steps: Copy Fedora ISO Files + Setup Grub2Win
==============================================
Part 1: Getting Grub2Win
1. Download the files for Grub2Win: https://sourceforge.net/projects/grub2win/files/latest/download
2. Extract the files
3. Run the installer

Part 2:
1. Manually extract or mount your Fedora ISO.

2. Copy **all contents** of the ISO (not the ISO file itself) to the new FAT32 partition:
   -> Target drive: $newDrive

3. Open Grub2Win:
   - Go to "Manage Boot Menu"
   - Click "Add A New Entry"
   - Type: **Custom Code**
   - Paste the following code:

     set root='(hd0,gpt4)'
     linux /boot/x86_64/loader/linux root=live:LABEL=VENTOY rd.live.image quiet
     initrd /boot/x86_64/loader/initrd.img

   (Change hd0,gpt4 if needed — adjust to match the actual partition)

4. Save and reboot.
   - From Grub2Win boot menu, select your custom Fedora entry.

Done!
"@
Write-Host "`n$instructions"
