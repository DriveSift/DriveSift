function Expand-DsPath {
    [CmdletBinding()]
    param([string]$Pattern)
    [Environment]::ExpandEnvironmentVariables($Pattern)
}

# 这些位置无论规则怎么写都不允许动，只交给系统自带工具处理。
function Get-DsProtectedPattern {
    @(
        '%WINDIR%\WinSxS',
        '%WINDIR%\System32',
        '%WINDIR%\SysWOW64',
        '%WINDIR%\CSC',
        '%ProgramData%\Microsoft\Crypto',
        '%USERPROFILE%\.ssh',
        '%USERPROFILE%\.gnupg',
        '%USERPROFILE%\Documents',
        '%USERPROFILE%\Desktop',
        '%USERPROFILE%\Pictures',
        '%USERPROFILE%\Videos'
    ) | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }
}

function Test-DsProtectedPath {
    [CmdletBinding()]
    param([string]$Path)

    $normalized = $Path.TrimEnd('\')
    foreach ($pattern in (Get-DsProtectedPattern)) {
        if ($normalized -eq $pattern) { return $true }
        if ($normalized -like ($pattern + '\*')) { return $true }
    }
    return $false
}

# 规则里的路径可能带通配符，也可能指向文件（例如 thumbcache_*.db）。
function Resolve-DsRulePath {
    [CmdletBinding()]
    param([string]$Pattern)

    $expanded = Expand-DsPath -Pattern $Pattern
    if ($expanded -notmatch '[*?]') {
        if (Test-Path -LiteralPath $expanded) { return @($expanded) }
        return @()
    }

    $items = @(Get-ChildItem -Path $expanded -Directory -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        $items = @(Get-ChildItem -Path $expanded -File -Force -ErrorAction SilentlyContinue)
    }
    return @($items | ForEach-Object { $_.FullName })
}

function Get-DsFileHash {
    [CmdletBinding()]
    param([string]$Path)

    $sha = $null
    $stream = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-DsPathSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$ExactAllocation,
        [int]$MaxDepth = -1
    )

    $records = @(Invoke-DsWalk -Path $Path -ExactAllocation:$ExactAllocation -MaxDepth $MaxDepth)

    $length = [long]0
    $allocated = [long]0
    $newest = [datetime]::MinValue
    $oldest = [datetime]::MaxValue

    foreach ($r in $records) {
        $length += [long]$r.Length
        $allocated += [long]$r.Allocated
        if ($r.LastWriteUtc -gt $newest) { $newest = $r.LastWriteUtc }
        if ($r.LastWriteUtc -lt $oldest) { $oldest = $r.LastWriteUtc }
    }

    if ($records.Count -eq 0) {
        $newest = $null
        $oldest = $null
    }

    [pscustomobject]@{
        Path           = $Path
        FileCount      = $records.Count
        LengthBytes    = $length
        AllocatedBytes = $allocated
        LengthMB       = [math]::Round($length / 1MB, 1)
        AllocatedMB    = [math]::Round($allocated / 1MB, 1)
        LastWriteUtc   = $newest
        OldestWriteUtc = $oldest
        Records        = $records
    }
}

# 从一个路径向上找最近的、带清单文件的项目根目录。
function Get-DsProjectRootForPath {
    [CmdletBinding()]
    param(
        [string]$Path,
        [object[]]$Projects
    )

    if (-not $Projects -or $Projects.Count -eq 0) { return $null }

    $best = $null
    $bestLength = -1
    $needle = $Path.TrimEnd('\')

    foreach ($project in $Projects) {
        $root = $project.Path.TrimEnd('\')
        if ($needle -eq $root -or $needle -like ($root + '\*')) {
            if ($root.Length -gt $bestLength) {
                $best = $project
                $bestLength = $root.Length
            }
        }
    }
    return $best
}
