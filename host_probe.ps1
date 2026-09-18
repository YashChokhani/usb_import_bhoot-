<#
    host_probe.ps1 - Portable USB System Profiler (probe)

    Profiles the current Windows host and emits a JSON document matching the
    agreed schema. Read-only on the host EXCEPT one consented write/delete
    permission test inside -SourceDir.

    Windows PowerShell 5.1 compatible (the version that always ships with
    Windows 11); also runs under PowerShell 7+.

    PARAMETERS
      -SourceDir  Folder to profile as the "source" (read speed, size, and the
                  consented read/write/delete permission test). Defaults to the
                  root of the drive this script lives on.
      -OutDir     Folder to write host_<COMPUTERNAME>_<mac>.json into. If given,
                  the JSON is written there (and also echoed to stdout). If
                  omitted, JSON goes to stdout only.
      -PiHost     Optional host/IP to ping for the network.pi_reachable check.

    EXIT CODES
      0  success (JSON written / emitted)
      2  -OutDir was given but is not writable (e.g. write-protected stick)
      3  unexpected fatal error
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutDir,
    [string]$PiHost,
    [switch]$Quiet   # suppress the JSON echo on stdout (launcher use); file is still written
)

$ErrorActionPreference = 'Stop'

# ---- small helpers ---------------------------------------------------------

# Run a scriptblock; return its value, or $null if it throws. Keeps a single
# unreadable field from aborting the whole probe (PRD: mark fields it couldn't
# read rather than failing).
function Try-Get {
    param([scriptblock]$Block)
    try { & $Block } catch { $null }
}

function Get-DefaultSourceDir {
    # Root of the drive this script is on, e.g. "E:\".
    $root = Split-Path -Qualifier $PSCommandPath
    if ($root) { return ($root + '\') }
    return (Get-Location).Path
}

if (-not $SourceDir) { $SourceDir = Get-DefaultSourceDir }

# ---------------------------------------------------------------------------
# Build the profile. Wrapped so any fatal surprise still exits with a code the
# launcher can report instead of hanging.
# ---------------------------------------------------------------------------
try {

    # ---- identity / OS ----
    $hostname = $env:COMPUTERNAME
    # InvariantCulture so the ':' separators are always ':' (some locales
    # substitute '.' for the time separator, which would malform the schema).
    $nowUtc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

    $os = Try-Get { Get-CimInstance -ClassName Win32_OperatingSystem }
    $cs = Try-Get { Get-CimInstance -ClassName Win32_ComputerSystem }

    $distro = if ($os) { $os.Caption.Trim() } else { $null }
    $kernel = if ($os) { $os.Version } else { $null }
    $arch   = $env:PROCESSOR_ARCHITECTURE

    $uptimeSeconds = $null
    if ($os -and $os.LastBootUpTime) {
        $uptimeSeconds = [int64]((Get-Date) - $os.LastBootUpTime).TotalSeconds
    }

    # ---- CPU ----
    $cpuInfo = Try-Get { Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 }
    $cpuModel = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { $null }
    # Logical processors across all sockets (matches "cores":32 on an i9-13900KF).
    $cpuCores = $null
    if ($cs -and $cs.NumberOfLogicalProcessors) {
        $cpuCores = [int]$cs.NumberOfLogicalProcessors
    } elseif ($cpuInfo) {
        $cpuCores = [int]$cpuInfo.NumberOfLogicalProcessors
    }

    # Instruction-set support. Available cleanly only via System.Runtime.Intrinsics
    # (PowerShell 7 / .NET Core). On Windows PowerShell 5.1 that type is absent,
    # so we report null rather than guessing.
    $hwAes    = Try-Get { [System.Runtime.Intrinsics.X86.Aes]::IsSupported }
    $hwCrc32c = Try-Get { [System.Runtime.Intrinsics.X86.Sse42]::IsSupported }

    # ---- memory ----
    $totalKb = $null
    $availKb = $null
    if ($os) {
        $totalKb = [int64]$os.TotalVisibleMemorySize   # already in KB
        $availKb = [int64]$os.FreePhysicalMemory        # already in KB
    }

    # ---- source dir: existence, readability, size, file count ----
    $srcExists   = Test-Path -LiteralPath $SourceDir
    $srcReadable = $false
    $srcBytes    = $null
    $srcFiles    = $null

    if ($srcExists) {
        # Readable = we can enumerate its top level.
        $srcReadable = [bool](Try-Get { Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction Stop | Out-Null; $true })

        # Recursive size + count with a time budget, robust to access-denied
        # subdirectories (manual BFS so one locked folder can't abort the walk).
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $budgetMs = 10000
        $bytes = [int64]0
        $count = [int64]0
        $queue = New-Object System.Collections.Generic.Queue[string]
        $queue.Enqueue((Convert-Path -LiteralPath $SourceDir))
        while ($queue.Count -gt 0 -and $sw.ElapsedMilliseconds -lt $budgetMs) {
            $dir = $queue.Dequeue()
            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                    try { $bytes += (New-Object System.IO.FileInfo $f).Length; $count++ } catch {}
                    if ($sw.ElapsedMilliseconds -ge $budgetMs) { break }
                }
                foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                    $queue.Enqueue($d)
                }
            } catch {}  # unreadable directory: skip it
        }
        $sw.Stop()
        $srcBytes = $bytes
        $srcFiles = $count
    }

    # ---- disk that holds the source + read-speed probe ----
    $mount = Try-Get { (Split-Path -Qualifier (Convert-Path -LiteralPath $SourceDir)) + '\' }
    $fsTotal = $null
    $fsFree  = $null
    if ($mount) {
        $driveLetter = $mount.TrimEnd('\',':')
        $ld = Try-Get { Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetter`:'" }
        if ($ld) {
            $fsTotal = [int64]$ld.Size
            $fsFree  = [int64]$ld.FreeSpace
        }
    }

    # Read-speed: read up to 64 MB (or 3s) from source files, measure MB/s.
    $readSpeed = $null
    if ($srcExists -and $srcReadable) {
        $readSpeed = Try-Get {
            $capBytes = 64MB
            $budget   = 3000
            $buf      = New-Object byte[] (1MB)
            $read     = [int64]0
            $sw2      = [System.Diagnostics.Stopwatch]::StartNew()
            $enum     = [System.IO.Directory]::EnumerateFiles((Convert-Path -LiteralPath $SourceDir), '*', [System.IO.SearchOption]::AllDirectories)
            foreach ($file in $enum) {
                if ($read -ge $capBytes -or $sw2.ElapsedMilliseconds -ge $budget) { break }
                try {
                    $fs = [System.IO.File]::OpenRead($file)
                    try {
                        while ($true) {
                            if ($read -ge $capBytes -or $sw2.ElapsedMilliseconds -ge $budget) { break }
                            $n = $fs.Read($buf, 0, $buf.Length)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                    } finally { $fs.Dispose() }
                } catch {}
            }
            $sw2.Stop()
            if ($read -gt 0 -and $sw2.Elapsed.TotalSeconds -gt 0) {
                $mbps = ($read / 1MB) / $sw2.Elapsed.TotalSeconds
                ('{0:N1} MB/s' -f $mbps)
            } else { $null }
        }
    }

    # ---- network: primary (default-route) adapter ----
    $netIf     = $null
    $localIp   = $null
    $mtu       = $null
    $linkMbps  = $null
    $mac       = $null

    $route = Try-Get {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, ifMetric | Select-Object -First 1
    }
    if ($route) {
        $ifIndex = $route.ifIndex
        $adapter = Try-Get { Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction Stop }
        if ($adapter) {
            $netIf = $adapter.Name
            $mac   = $adapter.MacAddress
            $linkMbps = Try-Get {
                if ($adapter.LinkSpeed) {
                    $parts = $adapter.LinkSpeed -split '\s+'
                    $val = [double]$parts[0]
                    switch -Regex ($parts[1]) {
                        'Gbps' { [int]($val * 1000); break }
                        'Mbps' { [int]$val; break }
                        'Kbps' { [int]($val / 1000); break }
                        default { [int]($val / 1e6) }
                    }
                }
            }
        }
        $ipObj = Try-Get {
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        }
        if ($ipObj) { $localIp = "$($ipObj.IPAddress)/$($ipObj.PrefixLength)" }
        $mtu = Try-Get {
            (Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop).NlMtu
        }
    }

    # Fallback for hosts without the NetTCPIP cmdlets.
    if (-not $mac) {
        $nic = Try-Get {
            Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' |
                Select-Object -First 1
        }
        if ($nic) {
            $mac = $nic.MACAddress
            if (-not $localIp -and $nic.IPAddress) {
                $localIp = ($nic.IPAddress | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
            }
        }
    }

    # pi_reachable / pi_ping_ms - only meaningful when a target is supplied.
    $piReachable = $false
    $piPingMs    = $null
    if ($PiHost) {
        $ping = Try-Get { Test-Connection -ComputerName $PiHost -Count 1 -ErrorAction Stop }
        if ($ping) {
            $piReachable = $true
            $piPingMs = Try-Get { [int]$ping.ResponseTime }
        }
    }

    # ---- privileges + consented write/delete test on the source ----
    $wid   = Try-Get { [Security.Principal.WindowsIdentity]::GetCurrent() }
    $userName = if ($wid) { $wid.Name } else { "$env:USERDOMAIN\$env:USERNAME" }
    $isRoot = $false
    if ($wid) {
        $prin = New-Object Security.Principal.WindowsPrincipal($wid)
        $isRoot = $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    $canRead   = $srcReadable
    $canWrite  = $false
    $canDelete = $false
    if ($srcExists) {
        $probeFile = Join-Path $SourceDir (".host_probe_perm_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        try {
            [System.IO.File]::WriteAllText($probeFile, 'perm-test')
            $canWrite = $true
            try {
                Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
                $canDelete = $true
            } catch {
                # Written but couldn't delete: best-effort cleanup, leave canDelete false.
                Try-Get { [System.IO.File]::Delete($probeFile) } | Out-Null
            }
        } catch {
            $canWrite = $false
        }
    }

    # ---- tools on PATH ----
    function Test-Tool { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

    # ---- assemble (field order matches the agreed schema exactly) ----
    $result = [ordered]@{
        hostname       = $hostname
        probed_at_utc  = $nowUtc
        os             = 'Windows'
        distro         = $distro
        kernel         = $kernel
        arch           = $arch
        uptime_seconds = $uptimeSeconds
        cpu = [ordered]@{
            model      = $cpuModel
            cores      = $cpuCores
            hw_aes     = $hwAes
            hw_crc32c  = $hwCrc32c
        }
        memory = [ordered]@{
            total_kb     = $totalKb
            available_kb = $availKb
        }
        source = [ordered]@{
            path       = (Try-Get { Convert-Path -LiteralPath $SourceDir })
            exists     = [bool]$srcExists
            readable   = [bool]$srcReadable
            total_bytes= $srcBytes
            file_count = $srcFiles
        }
        disk = [ordered]@{
            mount          = $mount
            fs_total_bytes = $fsTotal
            fs_free_bytes  = $fsFree
            read_speed     = $readSpeed
        }
        network = [ordered]@{
            interface     = $netIf
            local_ip      = $localIp
            mtu           = $mtu
            link_mbps     = $linkMbps
            pi_reachable  = $piReachable
            pi_ping_ms    = $piPingMs
            udp_wmem_max  = $null   # Linux sysctl; not applicable on Windows
            udp_rmem_max  = $null   # Linux sysctl; not applicable on Windows
        }
        privileges = [ordered]@{
            user            = $userName
            is_root         = $isRoot
            can_read_source = [bool]$canRead
            can_write_source= [bool]$canWrite
            can_delete_source=[bool]$canDelete
        }
        tools = [ordered]@{
            zstd      = (Test-Tool 'zstd')
            sha256sum = (Test-Tool 'sha256sum')
            ss        = (Test-Tool 'ss')   # Linux; false on Windows
            ip        = (Test-Tool 'ip')   # Linux; false on Windows
        }
    }

    # If source path failed to normalize, fall back to the raw argument.
    if (-not $result.source.path) { $result.source.path = $SourceDir }

    $json = $result | ConvertTo-Json -Depth 6

    # ---- output ----
    if ($OutDir) {
        if (-not (Test-Path -LiteralPath $OutDir)) {
            try { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
            catch {
                # Write straight to stderr (not Write-Error, which would throw
                # under 'Stop' and be reclassified by the outer catch as exit 3).
                [Console]::Error.WriteLine("OutDir '$OutDir' does not exist and cannot be created (write-protected media?): $($_.Exception.Message)")
                exit 2
            }
        }

        # Disambiguate identically-named (imaged) machines by MAC, so re-running
        # one PC overwrites only its own file while two PCs sharing a COMPUTERNAME
        # get distinct files. Fall back to a timestamp if no MAC is available.
        $macTag = $null
        if ($mac) { $macTag = ($mac -replace '[^0-9A-Fa-f]', '').ToLower() }
        if (-not $macTag) { $macTag = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') }

        $safeHost = ($hostname -replace '[^0-9A-Za-z_-]', '_')
        $fileName = "host_${safeHost}_${macTag}.json"
        $outPath  = Join-Path $OutDir $fileName

        try {
            # UTF-8 without BOM, matching the sample launcher output style.
            [System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            [Console]::Error.WriteLine("Could not write '$outPath' (write-protected media?): $($_.Exception.Message)")
            exit 2
        }

        # Echo to stdout too (unless -Quiet), plus a machine-parseable marker
        # the launcher reads on its own line.
        if (-not $Quiet) { $json }
        Write-Output "PROBE_WROTE=$fileName"
    } else {
        $json
    }

    exit 0
}
catch {
    Write-Error "Probe failed: $($_.Exception.Message)"
    exit 3
}
