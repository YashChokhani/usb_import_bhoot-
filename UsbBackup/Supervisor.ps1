. (Join-Path $PSScriptRoot 'Common.ps1')
$stop = Join-Path $script:App 'stop'
if (Test-Path -LiteralPath $stop) { exit }
$config = Get-Content -LiteralPath (Join-Path $script:App 'config.json') -Raw | ConvertFrom-Json
if ($config.AccountSid -cne $script:Sid -or $config.Computer -cne $env:COMPUTERNAME) { throw 'Installation does not belong to this account and PC.' }
$mutex = [Threading.Mutex]::new($false, ('Local\UsbVault-Supervisor-' + $script:Sid))
$owns = $false
$jobs = @{}
$wmiWarned = $false
function Get-UsbVolumes {
    $found = @{}
    # DriveInfo remains usable when WMI/CIM is denied to a standard account.
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -eq [IO.DriveType]::Removable -and $drive.IsReady) {
                $found[$drive.Name] = @{ Root = $drive.Name; Identity = $drive.Name + '|' + $drive.VolumeLabel + '|' + $drive.TotalSize }
            }
        } catch { Write-Log 'A removable volume is not ready; will retry.' }
    }
    try {
        # Also detect USB enclosures/sticks that report themselves as fixed disks.
        $disks = @(Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 10 -ErrorAction Stop | Where-Object { $_.InterfaceType -eq 'USB' -or $_.PNPDeviceID -like 'USBSTOR*' })
        foreach ($disk in $disks) {
            foreach ($partition in @(Get-CimAssociatedInstance -InputObject $disk -Association Win32_DiskDriveToDiskPartition -OperationTimeoutSec 10 -ErrorAction Stop)) {
                foreach ($logical in @(Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -OperationTimeoutSec 10 -ErrorAction Stop)) {
                    $root = $logical.DeviceID + '\'
                    if ([IO.DriveInfo]::new($root).IsReady) { $found[$root] = @{ Root = $root; Identity = [string]$disk.PNPDeviceID + '|' + [string]$logical.VolumeSerialNumber } }
                }
            }
        }
        # Improve identity for conventional removable media (drive letters can change).
        foreach ($logical in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -OperationTimeoutSec 10 -ErrorAction Stop)) {
            $root = $logical.DeviceID + '\'
            if ($found.ContainsKey($root) -and $found[$root].Identity.StartsWith($root + '|')) {
                $found[$root].Identity = 'Removable|' + [string]$logical.VolumeSerialNumber + '|' + [string]$logical.Size
            }
        }
    } catch {
        if (-not $script:wmiWarned) { Write-Log 'CIM unavailable: watching removable volumes only; USB disks reported as fixed cannot be detected.'; $script:wmiWarned = $true }
    }
    foreach ($value in $found.Values) {
        # Never back up the OS/profile disk or the installer stick carrying this kit.
        if ($value.Root -ieq [IO.Path]::GetPathRoot($script:App) -or $value.Root -ieq ($env:SystemDrive + '\')) { continue }
        if (Test-Path -LiteralPath (Join-Path $value.Root '.usbvault-ignore')) { continue }
        $value
    }
}
try {
    try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
    if (-not $owns) { exit }
    Write-Log 'Supervisor started.'
    while (-not (Test-Path -LiteralPath $stop)) {
        try {
            $volumes = @(Get-UsbVolumes)
            foreach ($root in @($jobs.Keys)) {
                $job = $jobs[$root]
                $stillThere = @($volumes | Where-Object { $_.Root -eq $root -and $_.Identity -eq $job.Identity }).Count -gt 0
                $heartbeat = Join-Path $script:App ('Runtime\' + $job.Id + '.pulse')
                $stalled = (Test-Path -LiteralPath $heartbeat) -and (([DateTime]::UtcNow - (Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc).TotalMinutes -gt 5)
                if (-not $stillThere -or $stalled -or $job.Process.HasExited) {
                    if (-not $job.Process.HasExited) { $job.Process.Kill(); $null = $job.Process.WaitForExit(3000) }
                    if ($stalled) { Write-Log ('Worker stalled; retrying after cooldown: ' + $job.Id) }
                    $job.Process.Dispose(); $jobs.Remove($root)
                }
            }
            foreach ($volume in $volumes) {
                if ($jobs.ContainsKey($volume.Root)) { continue }
                $id = [UsbVault.Crypto]::Hash($volume.Identity).Substring(0,24)
                # Worker gets a local job file, never a command or script from the USB.
                $jobPath = Join-Path $script:App ('Runtime\' + $id + '.json')
                Save-Json $jobPath @{ Root = $volume.Root; Identity = $volume.Identity; Id = $id; ScanId = [Guid]::NewGuid().ToString('N') }
                [IO.File]::WriteAllText((Join-Path $script:App ('Runtime\' + $id + '.pulse')), '')
                $p = Start-VaultProcess ('-File "' + (Join-Path $script:App 'Worker.ps1') + '" -JobPath "' + $jobPath + '"')
                $jobs[$volume.Root] = @{ Identity = $volume.Identity; Id = $id; Process = $p }
                Write-Log ('Backup worker started for volume ' + $id)
            }
            Save-Json (Join-Path $script:App 'supervisor-status.json') @{
                UpdatedUtc = [DateTime]::UtcNow.ToString('o'); ProcessId = $PID; ActiveVolumes = $jobs.Count; CimFallback = $script:wmiWarned
            }
        } catch { Write-Log ('Supervisor retry after error: ' + $_.Exception.GetType().Name) }
        Start-Sleep -Seconds 5
    }
} finally {
    foreach ($job in $jobs.Values) { try { if (-not $job.Process.HasExited) { $job.Process.Kill() }; $job.Process.Dispose() } catch { } }
    if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
