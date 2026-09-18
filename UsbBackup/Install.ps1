. (Join-Path $PSScriptRoot 'Common.ps1')
if ($env:USB_AUTORUN_ROOT -or $env:USB_AUTORUN_OUTPUT) { throw 'Automatic deployment is disabled. Launch INSTALL_USB_BACKUP.cmd yourself.' }
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or $env:SESSIONNAME -like 'RDP*') { throw 'Use an interactive local console session to install.' }
$publicPath = Join-Path $PSScriptRoot 'public-key.xml'
if (-not (Test-Path -LiteralPath $publicPath)) { throw 'Prepare the recovery key on the recovery PC first.' }
$xml = [IO.File]::ReadAllText($publicPath)
$rsa = [UsbVault.Crypto]::PublicKey($xml); $rsa.Dispose()
$localDisk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:App))
if ($localDisk.DriveType -ne [IO.DriveType]::Fixed -or $localDisk.DriveFormat -ne 'NTFS') { throw 'Installation requires a local NTFS user profile for protected backup storage.' }
Write-Host ''
Write-Host 'USB BACKUP - install for this Windows account only'
Write-Host ('Computer: ' + $env:COMPUTERNAME + '   User: ' + $env:USERNAME)
Write-Host ('Backups: ' + (Join-Path $script:App 'Backups'))
Write-Host ('Recovery public-key SHA256: ' + [UsbVault.Crypto]::Hash($xml))
Write-Host 'This watches readable USB volumes while you are signed in. Files are encrypted locally.'
Write-Host 'It starts at sign-in; a background supervisor restarts failed backup workers.'
Write-Host 'To authorize installation, type this computer name and press Enter.'
$answer = Read-Host $env:COMPUTERNAME
if ($answer -cne $env:COMPUTERNAME) { throw 'Computer name did not match. Installation cancelled.' }
Protect-Folder $script:App
$configPath = Join-Path $script:App 'config.json'
if (Test-Path -LiteralPath $configPath) {
    $old = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($old.PublicKeySha256 -cne [UsbVault.Crypto]::Hash($xml)) { throw 'Installed public key differs. Refusing to change recovery keys.' }
}
# Stop through a sentinel, not an untrusted PID file. Do not replace live scripts.
$stop = Join-Path $script:App 'stop'
[IO.File]::WriteAllText($stop, 'install')
Start-Sleep -Seconds 6
$mutex = [Threading.Mutex]::new($false, ('Local\UsbVault-Supervisor-' + $script:Sid))
$owns = $false
try {
    try { $owns = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $owns = $true }
    if (-not $owns) { throw 'Existing supervisor did not stop. Sign out/in and retry installation.' }
    foreach ($name in @('Common.ps1','VaultCrypto.cs','Supervisor.ps1','Worker.ps1','public-key.xml','Status.ps1','Uninstall.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $script:App -Force
    }
    foreach ($name in @('Backups','State','Runtime')) { Protect-Folder (Join-Path $script:App $name) }
    Save-Json $configPath @{
        Version = 1; Computer = $env:COMPUTERNAME; AccountSid = $script:Sid
        PublicKeySha256 = [UsbVault.Crypto]::Hash($xml); ReserveBytes = 2GB; ScanSeconds = 60
        InstalledUtc = [DateTime]::UtcNow.ToString('o'); Consent = 'Interactive computer-name confirmation'
    }
    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startup 'UsbVault.lnk'))
    $shortcut.TargetPath = $script:PowerShell
    $shortcut.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $script:App 'Supervisor.ps1') + '"'
    $shortcut.WindowStyle = 7; $shortcut.Description = 'USB encrypted backup for this account'; $shortcut.Save()
    $keepAlive = $false
    try {
        $service = New-Object -ComObject Schedule.Service; $service.Connect()
        $task = $service.NewTask(0); $task.RegistrationInfo.Description = 'UsbVault per-user crash recovery (interactive logon only)'
        $task.Principal.UserId = $script:Sid; $task.Principal.LogonType = 3; $task.Principal.RunLevel = 0
        $task.Settings.ExecutionTimeLimit = 'PT0S'; $task.Settings.MultipleInstances = 2
        $task.Settings.DisallowStartIfOnBatteries = $false; $task.Settings.StopIfGoingOnBatteries = $false
        $task.Settings.StartWhenAvailable = $true
        $trigger = $task.Triggers.Create(1); $trigger.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss'); $trigger.Repetition.Interval = 'PT3M'
        $action = $task.Actions.Create(0); $action.Path = $script:PowerShell; $action.Arguments = $shortcut.Arguments
        $null = $service.GetFolder('\').RegisterTaskDefinition($script:TaskName, $task, 6, $script:Sid, $null, 3)
        $keepAlive = $true
    } catch { Write-Warning 'Windows policy denied the optional keep-alive task. Startup and worker crash recovery still work; a killed supervisor restarts at next sign-in.' }
    Save-Json (Join-Path $script:App 'installation.json') @{ KeepAliveTask = $keepAlive; TaskName = $script:TaskName }
    Remove-Item -LiteralPath $stop -Force
} finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
$process = Start-VaultProcess ('-File "' + (Join-Path $script:App 'Supervisor.ps1') + '"')
Start-Sleep -Seconds 3
if ($process.HasExited) { throw 'Supervisor exited immediately. Run USB_BACKUP_STATUS.cmd and inspect activity logs.' }
Write-Host 'Installed and started. Use USB_BACKUP_STATUS.cmd to check progress and errors.'
