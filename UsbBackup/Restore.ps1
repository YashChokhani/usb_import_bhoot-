param([string]$InputFolder, [string]$OutputFolder)
. (Join-Path $PSScriptRoot 'Common.ps1')
$rsa = [UsbVault.Crypto]::OpenPrivateKey()
try {
    if (-not $InputFolder) { $InputFolder = Read-Host 'Folder containing copied encrypted backups (.uvf files)' }
    if (-not $OutputFolder) { $OutputFolder = Read-Host 'New, empty local folder for recovered files' }
    $inputRoot = [IO.Path]::GetFullPath($InputFolder)
    $outputRoot = [IO.Path]::GetFullPath($OutputFolder)
    foreach ($path in @($inputRoot, $outputRoot)) {
        $disk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path))
        if ($disk.DriveType -ne [IO.DriveType]::Fixed) { throw 'Copy backups onto this PC first; input and output must be on local fixed disks.' }
    }
    if (-not [IO.Directory]::Exists($inputRoot)) { throw 'Input folder does not exist.' }
    if ($outputRoot.StartsWith($inputRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $outputRoot -ieq $inputRoot) { throw 'Recovery output must be outside the backup input folder.' }
    if (Test-Path -LiteralPath $outputRoot) {
        if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -gt 0) { throw 'Use an empty output folder.' }
    }
    Protect-Folder $outputRoot
    $ok = 0; $failed = 0
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($inputRoot)
    while ($stack.Count -gt 0) {
        $dir = [IO.DirectoryInfo]::new($stack.Pop())
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points in the backup input are not supported.' }
        foreach ($entry in $dir.EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points in the backup input are not supported.' }
            if ($entry -is [IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
            if ($entry.Extension -ine '.uvf') { continue }
            try { $target = [UsbVault.Crypto]::RestoreFile($entry.FullName, $outputRoot, $rsa); $ok++; Write-Host ('Recovered: ' + $target) }
            catch { $failed++; Write-Warning ($entry.Name + ': ' + $_.Exception.Message) }
        }
    }
    Write-Host ("Recovered {0} file versions; failed {1}. Existing versions were preserved." -f $ok,$failed)
    if ($failed -gt 0 -or $ok -eq 0) { exit 1 }
} finally { $rsa.Dispose() }
