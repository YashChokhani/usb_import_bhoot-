param([Parameter(Mandatory=$true)][string]$JobPath, [switch]$Once)
. (Join-Path $PSScriptRoot 'Common.ps1')
$job = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json
$config = Get-Content -LiteralPath (Join-Path $script:App 'config.json') -Raw | ConvertFrom-Json
$xml = [IO.File]::ReadAllText((Join-Path $script:App 'public-key.xml'))
if ([UsbVault.Crypto]::Hash($xml) -cne $config.PublicKeySha256) { throw 'Public key fingerprint mismatch.' }
$rsa = [UsbVault.Crypto]::PublicKey($xml)
$root = [IO.Path]::GetFullPath($job.Root)
if (-not $root.EndsWith('\')) { $root += '\' }
# -Once also supports a fixture directory for tests; persistent workers require a volume root.
if ((-not $Once -and $root -cne [IO.Path]::GetPathRoot($root)) -or $script:App.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe source root.' }
if ($job.Id -notmatch '^[a-f0-9]{24}$') { throw 'Invalid volume identifier.' }
$backupDir = Join-Path $script:App ('Backups\' + $job.Id)
$stateDir = Join-Path $script:App ('State\' + $job.Id)
$heartbeat = Join-Path $script:App ('Runtime\' + $job.Id + '.pulse')
$statusPath = Join-Path $script:App ('Runtime\' + $job.Id + '.status.json')
$stop = Join-Path $script:App 'stop'
foreach ($path in @($backupDir, $stateDir)) { [UsbVault.Crypto]::EnsureSafeDirectory($path) }
$mutex = [Threading.Mutex]::new($false, ('Local\UsbVault-Volume-' + $script:Sid + '-' + $job.Id))
$owns = $false
function Pulse { [IO.File]::SetLastWriteTimeUtc($heartbeat, [DateTime]::UtcNow) }
try {
    try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
    if (-not $owns) { exit }
    # Only incomplete ciphertext in this worker's verified backup directory is removed.
    foreach ($partial in @(Get-ChildItem -LiteralPath $backupDir -Filter '*.partial' -File)) { Remove-Item -LiteralPath $partial.FullName -Force }
    while (-not (Test-Path -LiteralPath $stop) -and (Test-Path -LiteralPath $root)) {
        $copied = 0; $unchanged = 0; $errors = 0; $skipped = 0
        Save-Json $statusPath @{ Volume=$job.Id; UpdatedUtc=[DateTime]::UtcNow.ToString('o'); State='Scanning / copying'; CopiedThisScan=0; UnchangedThisScan=0; ErrorsThisScan=0; ExcludedThisScan=0 }
        $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($root)
        while ($stack.Count -gt 0 -and -not (Test-Path -LiteralPath $stop)) {
            $directory = $stack.Pop(); Pulse
            try {
                $di = [IO.DirectoryInfo]::new($directory)
                if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped++; continue }
                # Enumerate lazily so large directories do not exhaust memory.
                foreach ($entry in $di.EnumerateFileSystemInfos()) {
                    Pulse
                    if (Test-Path -LiteralPath $stop) { break }
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped++; continue }
                    if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                        if ($directory -eq $root -and $entry.Name -in @('System Volume Information','$RECYCLE.BIN')) { $skipped++; continue }
                        $stack.Push($entry.FullName); continue
                    }
                    $relative = $entry.FullName.Substring($root.Length)
                    $token = [UsbVault.Crypto]::Hash($relative.ToUpperInvariant())
                    $statePath = Join-Path $stateDir ($token + '.json')
                    try {
                        $state = $null
                        if (Test-Path -LiteralPath $statePath) {
                            try {
                                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                                foreach ($property in @('ScanId','Size','Ticks','Object','RetryAfterUtc')) {
                                    if (-not $state.PSObject.Properties[$property]) { throw 'Invalid index schema' }
                                }
                                if ($state.RetryAfterUtc) { $null = [DateTime]::Parse($state.RetryAfterUtc) }
                            } catch { $state = $null; Write-Log ('Unreadable index; recopying ' + $token) }
                        }
                        if ($state -and $state.RetryAfterUtc -and [DateTime]::Parse($state.RetryAfterUtc).ToUniversalTime() -gt [DateTime]::UtcNow) { $errors++; continue }
                        # Fast polling uses metadata. Reinsertion/restart verifies contents even if metadata was preserved.
                        if ($state -and $state.ScanId -eq $job.ScanId -and $state.Size -eq $entry.Length -and $state.Ticks -eq $entry.LastWriteTimeUtc.Ticks -and $state.Object -match '^[a-f0-9]{32}\.uvf$' -and (Test-Path -LiteralPath (Join-Path $backupDir $state.Object))) { $unchanged++; continue }
                        $previous = $state
                        $object = [Guid]::NewGuid().ToString('N') + '.uvf'
                        $length = $entry.Length; $ticks = $entry.LastWriteTimeUtc.Ticks
                        # Persist an attempted-file cooldown before I/O, so a hung device does not starve other files after restart.
                        Save-Json $statePath @{ ScanId=''; Size=$length; Ticks=$ticks; Object=''; RetryAfterUtc=[DateTime]::UtcNow.AddMinutes(10).ToString('o') }
                        if ($previous -and $previous.PSObject.Properties['Hash'] -and $previous.Hash -match '^[a-f0-9]{64}$' -and $previous.Ticks -eq $ticks -and $previous.Object -match '^[a-f0-9]{32}\.uvf$' -and (Test-Path -LiteralPath (Join-Path $backupDir $previous.Object))) {
                            $hash = [UsbVault.Crypto]::HashFile($entry.FullName, $heartbeat)
                            if ($hash -ceq $previous.Hash) {
                                Save-Json $statePath @{ ScanId=$job.ScanId; Size=$length; Ticks=$ticks; Object=$previous.Object; Hash=$hash; RetryAfterUtc=$null }
                                $unchanged++; continue
                            }
                        }
                        $hash = [UsbVault.Crypto]::EncryptFile($entry.FullName, (Join-Path $backupDir $object), $relative, $job.Identity, $rsa, [long]$config.ReserveBytes, $heartbeat)
                        Save-Json $statePath @{ ScanId=$job.ScanId; Size=$length; Ticks=$ticks; Object=$object; Hash=$hash; RetryAfterUtc=$null }
                        $copied++
                    } catch { $errors++; Write-Log ('File ' + $token + ' failed: ' + (Get-ErrorCode $_.Exception) + '; retry after cooldown. Source names are not logged.') }
                }
            } catch { $errors++; Write-Log ('Directory read failed: ' + (Get-ErrorCode $_.Exception) + '; retry next scan.') }
        }
        Save-Json $statusPath @{
            Volume=$job.Id; UpdatedUtc=[DateTime]::UtcNow.ToString('o'); CopiedThisScan=$copied; UnchangedThisScan=$unchanged
            ErrorsThisScan=$errors; ExcludedThisScan=$skipped; State=$(if($errors -gt 0){'INCOMPLETE - retry pending'}else{'Scan complete'})
        }
        Write-Log ('Scan ' + $job.Id + ': copied=' + $copied + ' unchanged=' + $unchanged + ' errors=' + $errors + ' excluded=' + $skipped)
        if ($Once) { break }
        for ($i=0; $i -lt [int]$config.ScanSeconds; $i+=5) { if (Test-Path -LiteralPath $stop) { break }; Pulse; Start-Sleep -Seconds 5 }
    }
} finally { $rsa.Dispose(); if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
