. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $script:App 'config.json'))) { Write-Host 'USB backup is not installed for this account.'; exit }
Write-Host ('Backup location: ' + (Join-Path $script:App 'Backups'))
Get-Content -LiteralPath (Join-Path $script:App 'installation.json') -Raw | Write-Host
$status = Join-Path $script:App 'supervisor-status.json'
if (Test-Path -LiteralPath $status) {
    $s = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    $age = ([DateTime]::UtcNow - [DateTime]::Parse($s.UpdatedUtc).ToUniversalTime()).TotalSeconds
    if ($age -gt 120) { Write-Warning 'Supervisor heartbeat is stale. Check activity logs or sign out/in.' }
    $s | Format-List | Out-Host
} else { Write-Warning 'No supervisor heartbeat yet.' }
if (Test-Path -LiteralPath (Join-Path $script:App 'stop')) { Write-Warning 'Backup is stopped/disabled.' }
Get-ChildItem -LiteralPath (Join-Path $script:App 'Runtime') -Filter '*.status.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | Write-Host }
Write-Host 'Volume reports show the LAST completed scan; connected drives may still be copying. Check timestamps.'
Write-Host ('Recent logs (full logs are in ' + $script:App + '):')
Get-ChildItem -LiteralPath $script:App -Filter 'activity-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 4 | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 8 | Write-Host }
