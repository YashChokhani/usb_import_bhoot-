<#
    watcher.ps1 - scoped USB autorun watcher (per-user, no admin).

    Installed to %LOCALAPPDATA%\UsbAutorun\ by RUN_ME.bat. It is kept alive by
    two per-user mechanisms (neither needs admin, both run only while this
    account is logged in):
      * a Startup-folder entry  -> starts it immediately at logon
      * a Scheduled Task (every few minutes) -> restarts it if it is ever
        killed or crashes, and re-arms it after a reboot+logon
    A named mutex makes those redundant launches safe: only one watcher ever
    runs at a time.

    It polls for REMOVABLE drives that carry BOTH the matching, per-drive marker
    '.usb_autorun_v2_id' AND a \RunScripts\ folder, and runs those scripts (in
    filename order) once per insertion. Every other USB drive is ignored.

    No elevation. Touches no registry and no machine-wide AutoRun setting.
    Fully removable via UNINSTALL.bat. Activity is logged to the stick
    (\autorun-logs\) and to %LOCALAPPDATA%\UsbAutorun\watcher.log.

    Scripts receive two environment variables:
      USB_AUTORUN_ROOT    the drive (e.g. "E:")
      USB_AUTORUN_OUTPUT  a per-run output/log folder on the drive

    -Once  do a single scan pass and exit (used for testing; skips the mutex).
#>
param(
    [switch]$Once,
    [int]$PollSeconds = 2
)

$ErrorActionPreference = 'SilentlyContinue'
$MarkerName = '.usb_autorun_v2_id'
$AllowedExt = @('.ps1', '.bat', '.cmd')

$appDir  = Join-Path $env:LOCALAPPDATA 'UsbAutorun'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$tokenFile = Join-Path $appDir 'drive-token.txt'
if (-not (Test-Path -LiteralPath $tokenFile)) { exit 2 }
$ExpectedToken = ([IO.File]::ReadAllText($tokenFile)).Trim()
if ([string]::IsNullOrWhiteSpace($ExpectedToken)) { exit 2 }
$pidFile = Join-Path $appDir 'watcher.pid'
$logFile = Join-Path $appDir 'watcher.log'

function Write-Log { param([string]$m) ("{0}  {1}" -f (Get-Date -Format 's'), $m) | Add-Content -Path $logFile }

# --- single-instance via a named mutex (race-free across concurrent launchers) ---
$mutex = $null
if (-not $Once) {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\UsbAutorunWatcher', [ref]$createdNew)
    if (-not $createdNew) { exit 0 }          # another watcher already owns it
    "$PID" | Set-Content -Path $pidFile        # recorded for UNINSTALL.bat
    Write-Log "watcher started pid=$PID"
}

function Get-RemovableDrives {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue
}

function Invoke-DriveScripts {
    param($drive)
    $rootLetter = $drive.DeviceID            # e.g. "E:"
    $root       = $rootLetter + '\'
    $scriptsDir = Join-Path $root 'RunScripts'
    if (-not (Test-Path -LiteralPath $scriptsDir)) { return }

    $stamp  = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $outDir = Join-Path $root ('autorun-logs\' + $env:COMPUTERNAME + '\' + $stamp)
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Write-Log "insertion $rootLetter -> running scripts, logs in $outDir"

    $files = Get-ChildItem -LiteralPath $scriptsDir -File |
             Where-Object { $AllowedExt -contains $_.Extension.ToLower() } |
             Sort-Object Name

    $env:USB_AUTORUN_ROOT   = $rootLetter
    $env:USB_AUTORUN_OUTPUT = $outDir

    $ran = 0
    Push-Location $scriptsDir
    try {
        foreach ($f in $files) {
            $log = Join-Path $outDir ($f.Name + '.log')
            Write-Log "run $($f.Name)"
            try {
                switch ($f.Extension.ToLower()) {
                    '.ps1'  { & powershell -NoProfile -ExecutionPolicy Bypass -File $f.FullName *>&1 | Tee-Object -FilePath $log | Out-Null }
                    default { & cmd.exe /c $f.FullName *>&1 | Tee-Object -FilePath $log | Out-Null }
                }
                ("exit_code={0}" -f $LASTEXITCODE) | Add-Content -Path $log
            } catch {
                ("ERROR: {0}" -f $_.Exception.Message) | Add-Content -Path $log
                Write-Log "error in $($f.Name): $($_.Exception.Message)"
            }
            $ran++
        }
    } finally { Pop-Location }
    ("ran {0} script(s) at {1} on {2}" -f $ran, $stamp, $env:COMPUTERNAME) | Add-Content -Path (Join-Path $outDir 'summary.log')
    Write-Log "done $rootLetter ($ran script(s))"
}

# --- main poll loop (hardened: a transient error never ends the loop) --------
$present = @{}   # DeviceID -> VolumeSerialNumber currently mounted & handled
do {
    try {
        $drives = @(Get-RemovableDrives)
        foreach ($d in $drives) {
            $marker = Join-Path ($d.DeviceID + '\') $MarkerName
            if ((Test-Path -LiteralPath $marker) -and (([IO.File]::ReadAllText($marker)).Trim() -ceq $ExpectedToken)) {
                if ($present[$d.DeviceID] -ne $d.VolumeSerialNumber) {   # newly inserted
                    $present[$d.DeviceID] = $d.VolumeSerialNumber
                    Invoke-DriveScripts $d
                }
            }
        }
        # forget drives that are gone so a re-insert re-triggers
        foreach ($k in @($present.Keys)) {
            if (-not ($drives | Where-Object { $_.DeviceID -eq $k })) { $present.Remove($k) }
        }
    } catch {
        Write-Log "loop error: $($_.Exception.Message)"
    }
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
} while ($true)
