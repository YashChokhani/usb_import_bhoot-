$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.ps1')
$fixture = Join-Path $env:TEMP ('UsbVaultAclTest-' + [Guid]::NewGuid().ToString('N'))
try {
    Protect-Folder $fixture
    $child = Join-Path $fixture 'Backups'
    Protect-Folder $child
    $sample = Join-Path $child 'preserved.txt'
    [IO.File]::WriteAllText($sample, 'preserve this through reinstall')
    $beforeOwner = (Get-Acl -LiteralPath $fixture).Owner
    for ($i=0; $i -lt 3; $i++) {
        Protect-Folder $fixture
        Protect-Folder $child
    }
    foreach ($path in @($fixture,$child)) {
        $acl = Get-Acl -LiteralPath $path
        if (-not $acl.AreAccessRulesProtected) { throw 'Permission inheritance was re-enabled.' }
        $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        $expected = @($script:Sid,'S-1-5-18','S-1-5-32-544')
        if ($rules.Count -ne 3) { throw 'Unexpected ACL entries.' }
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -notin $expected -or $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl') { throw 'Unexpected access granted.' }
        }
    }
    if ((Get-Acl -LiteralPath $fixture).Owner -cne $beforeOwner) { throw 'Owner changed.' }
    if ([IO.File]::ReadAllText($sample) -cne 'preserve this through reinstall') { throw 'Existing data changed.' }
    Write-Output 'PASS: repeated folder protection succeeds; owner, restricted access and existing data preserved.'
} finally {
    $full = [IO.Path]::GetFullPath($fixture)
    $prefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\UsbVaultAclTest-'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
