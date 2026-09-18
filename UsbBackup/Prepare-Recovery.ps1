. (Join-Path $PSScriptRoot 'Common.ps1')
$publicPath = Join-Path $PSScriptRoot 'public-key.xml'
$existing = if (Test-Path -LiteralPath $publicPath) { [IO.File]::ReadAllText($publicPath) } else { $null }
# A deployment kit already bound to another key must never be silently re-keyed.
if ($existing -and -not [Security.Cryptography.CngKey]::Exists([UsbVault.Crypto]::KeyName, [Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider)) {
    throw 'This kit already has a recovery public key. Run recovery preparation on the original PC/account.'
}
$xml = [UsbVault.Crypto]::PrepareKey()
if ($existing -and $existing -cne $xml) { throw 'Public key differs from the recovery key on this PC. Nothing was overwritten.' }
$rsa = [UsbVault.Crypto]::OpenPrivateKey()
try {
    $exportBlocked = $false
    try { $null = $rsa.ExportParameters($true) } catch { $exportBlocked = $true }
    if (-not $exportBlocked) { throw 'Private-key export was unexpectedly permitted.' }
    $test = [Text.Encoding]::UTF8.GetBytes('UsbVault recovery key self-test')
    $clear = $rsa.Decrypt($rsa.Encrypt($test, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256), [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    if ([Convert]::ToBase64String($clear) -cne [Convert]::ToBase64String($test)) { throw 'Recovery key self-test failed.' }
} finally { $rsa.Dispose() }
[IO.File]::WriteAllText($publicPath, $xml, [Text.UTF8Encoding]::new($false))
$homeDir = Join-Path $env:LOCALAPPDATA 'UsbVaultRecovery'
Protect-Folder $homeDir
foreach ($name in @('Common.ps1','VaultCrypto.cs','Restore.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $homeDir -Force }
Save-Json (Join-Path $homeDir 'recovery-info.json') @{
    Computer = $env:COMPUTERNAME; AccountSid = $script:Sid; KeyName = [UsbVault.Crypto]::KeyName
    PublicKeySha256 = [UsbVault.Crypto]::Hash($xml); CreatedOrVerifiedUtc = [DateTime]::UtcNow.ToString('o')
}
Write-Host 'Recovery key ready: non-exportable RSA-3072 in this account\PC Windows CNG key store.'
Write-Host ('Public-key fingerprint: ' + [UsbVault.Crypto]::Hash($xml))
Write-Host ('Recovery tools: ' + $homeDir)
Write-Host 'Only public-key.xml is on the USB. No farm watcher was installed here.'
