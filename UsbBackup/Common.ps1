$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if (-not ('UsbVault.Crypto' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'VaultCrypto.cs')
}
$script:App = Join-Path $env:LOCALAPPDATA 'UsbVault'
$script:Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:TaskName = 'UsbVault-' + $script:Sid
$script:PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Save-Json($Path, $Value) {
    $temp = $Path + '.new'
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}
function Protect-Folder([string]$Path) {
    [UsbVault.Crypto]::EnsureSafeDirectory($Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in @($script:Sid, 'S-1-5-18', 'S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($id), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Set-Acl's provider can include the audit section when an existing protected
    # DACL is reapplied, triggering SeSecurityPrivilege on a non-elevated account.
    # Persist only the access changes tracked by this fresh DirectorySecurity.
    [IO.Directory]::SetAccessControl($Path, $acl)
}
function Write-Log([string]$Message) {
    try {
        $log = Join-Path $script:App ('activity-' + $PID + '.log')
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log -Destination ($log + '.old') -Force
        }
        Add-Content -LiteralPath $log -Value ((Get-Date -Format o) + ' ' + $Message)
    } catch { }
}
function Get-ErrorCode($Exception) {
    while ($Exception.InnerException) { $Exception = $Exception.InnerException }
    if ($Exception.Message -eq 'Insufficient free space; backup postponed.') { return 'LOW_DISK_SPACE' }
    return ($Exception.GetType().Name + ' HRESULT=' + $Exception.HResult)
}
function Start-VaultProcess([string]$Arguments) {
    Start-Process -FilePath $script:PowerShell -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass ' + $Arguments) -WindowStyle Hidden -PassThru
}
