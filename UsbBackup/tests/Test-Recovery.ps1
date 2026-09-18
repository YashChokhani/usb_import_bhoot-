$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $kit 'VaultCrypto.cs')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('UsbVaultRecoveryTest-' + [Guid]::NewGuid().ToString('N'))
$public = [UsbVault.Crypto]::PublicKey([IO.File]::ReadAllText((Join-Path $kit 'public-key.xml')))
try {
    $inputDir = Join-Path $testRoot 'input'; $outputDir = Join-Path $testRoot 'output'
    [IO.Directory]::CreateDirectory($inputDir) | Out-Null
    $source = Join-Path $testRoot 'original.txt'
    [IO.File]::WriteAllText($source,'Recovery smoke test: known test data only.')
    $null = [UsbVault.Crypto]::EncryptFile($source,(Join-Path $inputDir 'test.uvf'),'original.txt','recovery-smoke-test',$public,0,$null)
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $env:LOCALAPPDATA 'UsbVaultRecovery\Restore.ps1') -InputFolder $inputDir -OutputFolder $outputDir
    if ($LASTEXITCODE -ne 0) { throw 'Installed recovery tool failed.' }
    $restored = @(Get-ChildItem -LiteralPath $outputDir -Recurse -File)
    if ($restored.Count -ne 1 -or (Get-FileHash -LiteralPath $restored[0].FullName).Hash -cne (Get-FileHash -LiteralPath $source).Hash) { throw 'Recovered bytes did not match.' }
    Write-Host 'PASS: USB public key -> encrypted object -> installed recovery tool -> identical bytes.'
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'recovery-result.txt'),("{0:o}: deployed public key and installed recovery tool passed exact-byte round trip" -f [DateTime]::UtcNow))
} finally {
    $public.Dispose()
    $resolved=[IO.Path]::GetFullPath($testRoot); $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\UsbVaultRecoveryTest-'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
