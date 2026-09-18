. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-Path -LiteralPath $script:App)) { Write-Host 'Not installed.'; exit }
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'UsbVault.lnk'
[IO.File]::WriteAllText((Join-Path $script:App 'stop'), 'disabled')
if (Test-Path -LiteralPath $startup) { Remove-Item -LiteralPath $startup -Force }
try {
    $service = New-Object -ComObject Schedule.Service; $service.Connect()
    $service.GetFolder('\').DeleteTask($script:TaskName, 0)
} catch { Write-Host 'Keep-alive task absent or could not be removed. The stop marker prevents future launches.' }
Start-Sleep -Seconds 7
Write-Host 'USB backup disabled for this account. Background processes stop after their current detection call.'
Write-Host ('Encrypted backups and logs are preserved in ' + $script:App)
Write-Host 'Recovery keys are unchanged. Run the installer again to re-enable.'
