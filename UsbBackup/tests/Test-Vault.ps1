$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot -Parent
$errors = @()
Get-ChildItem -LiteralPath $kit -Filter '*.ps1' | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    $errors += $parseErrors
}
if ($errors.Count) { $errors | Format-List | Out-Host; throw 'PowerShell parser errors' }
Add-Type -Path (Join-Path $kit 'VaultCrypto.cs')
$testRoot = Join-Path $PSScriptRoot ('run-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$rsa = [Security.Cryptography.RSACng]::new(3072)
$public = [UsbVault.Crypto]::PublicKey($rsa.ToXmlString($false))
$passes = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passes++; Write-Host ('PASS ' + $Message) }
function Reject([scriptblock]$Action, [string]$Message) { $rejected = $false; try { & $Action | Out-Null } catch { $rejected=$true }; Assert $rejected $Message }
try {
    $source = Join-Path $testRoot 'source.bin'
    $backup = Join-Path $testRoot 'sample.uvf'
    foreach ($length in @(0,1,15,16,17,1048577,8388608)) {
        $data = [byte[]]::new($length)
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($data); $rng.Dispose()
        [IO.File]::WriteAllBytes($source, $data)
        $out = Join-Path $testRoot ('size-' + $length + '.uvf')
        $hash = [UsbVault.Crypto]::EncryptFile($source, $out, ('nested\caf' + [char]0xE9 + '-file.bin'), 'test-volume', $public, 0, $null)
        Assert ($hash -ceq [UsbVault.Crypto]::HashFile($source, $null)) ('source hash ' + $length)
        $recovered = [UsbVault.Crypto]::RestoreFile($out, (Join-Path $testRoot ('restore-' + $length)), $rsa)
        Assert ((Get-FileHash -LiteralPath $source).Hash -ceq (Get-FileHash -LiteralPath $recovered).Hash) ('round trip ' + $length)
        Assert ((Get-Item -LiteralPath $source).LastWriteTimeUtc -eq (Get-Item -LiteralPath $recovered).LastWriteTimeUtc) ('timestamp ' + $length)
        if ($length -eq 17) { [IO.File]::Copy($out,$backup) }
    }
    $bytes = [IO.File]::ReadAllBytes($backup)
    foreach ($offset in @(0,9,20,410,440,($bytes.Length-1))) {
        $changed = $bytes.Clone(); $changed[$offset] = $changed[$offset] -bxor 1
        $damaged = Join-Path $testRoot ('tamper-' + $offset + '.uvf'); [IO.File]::WriteAllBytes($damaged,$changed)
        $dest = Join-Path $testRoot ('reject-' + $offset)
        Reject { [UsbVault.Crypto]::RestoreFile($damaged,$dest,$rsa) } ('tamper rejected at byte ' + $offset)
        Assert (-not (Test-Path -LiteralPath $dest)) 'no plaintext before authentication'
    }
    foreach ($length in @(0,8,12,100,($bytes.Length-1))) {
        $cut = [byte[]]::new($length); [Array]::Copy($bytes,$cut,$length)
        $path = Join-Path $testRoot ('truncated-' + $length + '.uvf'); [IO.File]::WriteAllBytes($path,$cut)
        Reject { [UsbVault.Crypto]::RestoreFile($path,(Join-Path $testRoot 'truncated-output'),$rsa) } ('truncation rejected ' + $length)
    }
    Reject { [UsbVault.Crypto]::RestoreFile($backup,(Join-Path $testRoot 'public-only'),$public) } 'public key cannot decrypt'
    $wrong = [Security.Cryptography.RSACng]::new(3072)
    try { Reject { [UsbVault.Crypto]::RestoreFile($backup,(Join-Path $testRoot 'wrong-key'),$wrong) } 'wrong private key cannot decrypt' } finally { $wrong.Dispose() }
    Reject { [UsbVault.Crypto]::PublicKey($rsa.ToXmlString($true)) } 'private XML rejected in deployment'
    foreach ($relative in @('..\escape','C:\escape','a:stream','a\..\escape','a/escape','CON.txt','a\LPT1.txt','trailing.','space ','a\\b')) {
        Reject { [UsbVault.Crypto]::CheckRelative($relative) } ('unsafe path rejected: ' + $relative)
    }
    $noSpace = Join-Path $testRoot 'no-space.uvf'
    Reject { [UsbVault.Crypto]::EncryptFile($source,$noSpace,'file','vol',$public,[long]::MaxValue-10000000,$null) } 'free-space reserve enforced'
    Assert (-not (Test-Path -LiteralPath $noSpace)) 'failed encryption leaves no committed backup'
    $locked = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Reject { [UsbVault.Crypto]::EncryptFile($source,(Join-Path $testRoot 'locked.uvf'),'file','vol',$public,0,$null) } 'locked file rejected for retry' } finally { $locked.Dispose() }
    $dest = Join-Path $testRoot 'versions'
    $first = [UsbVault.Crypto]::RestoreFile($backup,$dest,$rsa)
    $second = [UsbVault.Crypto]::RestoreFile($backup,$dest,$rsa)
    Assert ($first -cne $second -and (Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $second)) 'restore preserves existing versions'
    Assert (@(Get-ChildItem -LiteralPath $testRoot -Recurse -Filter '*.partial').Count -eq 0) 'no partial files after handled failures'
    Write-Host ("ALL {0} CHECKS PASSED. Windows PowerShell {1}; .NET {2}" -f $passes,$PSVersionTable.PSVersion,[Environment]::Version)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'last-result.txt'), ("{0:o}: {1} checks passed; PowerShell {2}; .NET {3}" -f [DateTime]::UtcNow,$passes,$PSVersionTable.PSVersion,[Environment]::Version))
} finally {
    $public.Dispose(); $rsa.Dispose()
    # The randomized test folder is resolved and constrained before recursive cleanup.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\run-'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
