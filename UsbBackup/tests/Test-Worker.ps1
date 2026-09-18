$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $kit 'VaultCrypto.cs')
$testRoot = Join-Path $PSScriptRoot ('worker-' + [Guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$source = Join-Path $testRoot 'source'
$env:LOCALAPPDATA = Join-Path $testRoot 'profile'
$app = Join-Path $env:LOCALAPPDATA 'UsbVault'
$rsa = [Security.Cryptography.RSACng]::new(3072)
$id = '0123456789abcdef01234567'
$scanId = 'scan-one'
$count = 0
function Assert($condition, $message) { if (-not $condition) { throw $message }; $script:count++; Write-Host ('PASS ' + $message) }
function Json($path,$value) { [IO.File]::WriteAllText($path,($value | ConvertTo-Json -Depth 5)) }
function Run-Scan {
    Json (Join-Path $app 'Runtime\job.json') @{ Root=$source; Identity='test-volume'; Id=$id; ScanId=$script:scanId }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $kit 'Worker.ps1') -JobPath (Join-Path $app 'Runtime\job.json') -Once
    if ($LASTEXITCODE -ne 0) { throw 'Worker process failed.' }
    Get-Content -LiteralPath (Join-Path $app ('Runtime\' + $id + '.status.json')) -Raw | ConvertFrom-Json
}
try {
    foreach ($p in @($source,(Join-Path $source 'nested'),$app,(Join-Path $app 'Runtime'))) { [IO.Directory]::CreateDirectory($p) | Out-Null }
    $xml = $rsa.ToXmlString($false)
    [IO.File]::WriteAllText((Join-Path $app 'public-key.xml'),$xml)
    Json (Join-Path $app 'config.json') @{ PublicKeySha256=[UsbVault.Crypto]::Hash($xml); ReserveBytes=0; ScanSeconds=0 }
    [IO.File]::WriteAllText((Join-Path $app ('Runtime\' + $id + '.pulse')),'')
    [IO.File]::WriteAllText((Join-Path $source 'one.txt'),'original')
    [IO.File]::WriteAllText((Join-Path $source 'nested\two.txt'),'second')
    [IO.File]::WriteAllBytes((Join-Path $source 'empty.bin'),[byte[]]::new(0))
    $s = Run-Scan
    Assert ($s.CopiedThisScan -eq 3 -and $s.ErrorsThisScan -eq 0) 'first scan copies every test file'
    $s = Run-Scan
    Assert ($s.UnchangedThisScan -eq 3 -and $s.CopiedThisScan -eq 0) 'repeat scan skips unchanged files'
    $script:scanId = 'scan-two'; $s = Run-Scan
    Assert ($s.UnchangedThisScan -eq 3 -and $s.CopiedThisScan -eq 0) 'reconnection verifies hashes without duplicate backups'
    $file = Join-Path $source 'one.txt'; $time = [IO.File]::GetLastWriteTimeUtc($file)
    [IO.File]::WriteAllText($file,'modified'); [IO.File]::SetLastWriteTimeUtc($file,$time)
    $script:scanId = 'scan-three'; $s = Run-Scan
    Assert ($s.CopiedThisScan -eq 1 -and $s.UnchangedThisScan -eq 2) 'same-length same-timestamp change found on reconnect'
    $objects = @(Get-ChildItem -LiteralPath (Join-Path $app ('Backups\' + $id)) -Filter '*.uvf')
    Assert ($objects.Count -eq 4) 'old version retained'
    $lockedFile = Join-Path $source 'locked.txt'; [IO.File]::WriteAllText($lockedFile,'retry me')
    $lock = [IO.File]::Open($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $s = Run-Scan; Assert ($s.ErrorsThisScan -eq 1 -and $s.State -like 'INCOMPLETE*') 'locked file is reported incomplete' } finally { $lock.Dispose() }
    $s = Run-Scan; Assert ($s.ErrorsThisScan -eq 1 -and $s.CopiedThisScan -eq 0) 'failed-file cooldown survives worker restart'
    $index = Join-Path $app ('State\' + $id + '\' + [UsbVault.Crypto]::Hash('LOCKED.TXT') + '.json')
    $state = Get-Content -LiteralPath $index -Raw | ConvertFrom-Json; $state.RetryAfterUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); Json $index $state
    $partial = Join-Path $app ('Backups\' + $id + '\interrupted.uvf.partial'); [IO.File]::WriteAllText($partial,'incomplete ciphertext')
    $s = Run-Scan; Assert ($s.ErrorsThisScan -eq 0 -and $s.CopiedThisScan -eq 1) 'failed file recovers when retry is due'
    Assert (-not (Test-Path -LiteralPath $partial)) 'interrupted partial is cleaned on restart'
    $backupDir = Join-Path $app ('Backups\' + $id)
    $recovered = Join-Path $testRoot 'recovered'
    $restored = @(Get-ChildItem -LiteralPath $backupDir -Filter '*.uvf' | ForEach-Object { [UsbVault.Crypto]::RestoreFile($_.FullName,$recovered,$rsa) })
    Assert ($restored.Count -eq 5) 'every completed worker object decrypts including older version'
    $contents = @($restored | ForEach-Object { [IO.File]::ReadAllText($_) })
    Assert ($contents -contains 'original' -and $contents -contains 'modified' -and $contents -contains 'retry me') 'original, changed, and retried contents recovered'
    Json $index @{ broken='index' }
    $s = Run-Scan
    Assert ($s.CopiedThisScan -eq 1 -and $s.ErrorsThisScan -eq 0) 'corrupted index rebuilds without deleting backups'
    Write-Host ("ALL {0} WORKER CHECKS PASSED" -f $count)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'worker-result.txt'),("{0:o}: {1} worker integration checks passed" -f [DateTime]::UtcNow,$count))
} finally {
    $rsa.Dispose(); $env:LOCALAPPDATA=$savedLocal
    $resolved=[IO.Path]::GetFullPath($testRoot); $allowed=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\worker-'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
