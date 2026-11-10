# 隔离区基础设施：manifest 读写、审计日志、防篡改校验、尺寸漂移检测。
# 原则：manifest 是"隔离区里有什么"的唯一事实来源；audit.jsonl 是只增不删的操作留痕。

function Get-DsManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QuarantineRoot)
    Join-Path $QuarantineRoot 'manifest.jsonl'
}

function Read-DsManifest {
    <#
    .SYNOPSIS
        读取 manifest.jsonl，返回条目数组。损坏的行跳过而不是中断。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QuarantineRoot)

    $manifestPath = Get-DsManifestPath -QuarantineRoot $QuarantineRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @() }

    $entries = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { [void]$entries.Add(($line | ConvertFrom-Json)) }
        catch { Write-Warning "manifest 存在无法解析的行，已跳过: $($line.Substring(0, [math]::Min(80, $line.Length)))" }
    }
    return @($entries)
}

function Write-DsManifest {
    <#
    .SYNOPSIS
        原子化重写 manifest：先写临时文件再替换，避免写一半损坏清单。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [object[]]$Entries
    )

    $manifestPath = Get-DsManifestPath -QuarantineRoot $QuarantineRoot
    $dir = Split-Path -Parent $manifestPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = @($Entries | ForEach-Object { ($_ | ConvertTo-Json -Compress) })
    $tmp = "$manifestPath.tmp"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($tmp, $lines, $utf8Bom)
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

function Add-DsAuditLog {
    <#
    .SYNOPSIS
        向 audit.jsonl 追加一条操作记录（quarantined / restored / purged）。
        审计失败不阻断主操作，但会给出警告。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [hashtable]$Event
    )

    try {
        $logPath = Join-Path $QuarantineRoot 'audit.jsonl'
        $record = [ordered]@{ Time = (Get-Date).ToString('s') }
        foreach ($key in $Event.Keys) { $record[[string]$key] = $Event[[string]$key] }
        Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    }
    catch {
        Write-Warning "审计日志写入失败: $($_.Exception.Message)"
    }
}

# 防篡改：只有隔离根目录之下的路径才允许参与删除/还原操作。
# 即使 manifest 被人手工改成指向别处，执行层也会拒绝。
function Test-DsUnderPath {
    [CmdletBinding()]
    param([string]$Path, [string]$Root)

    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.TrimEnd('\').ToLowerInvariant()
    $r = $Root.TrimEnd('\').ToLowerInvariant()
    return ($p -eq $r -or $p.StartsWith($r + [string]'\'))
}

# 计算隔离区内条目的当前实际大小（逻辑长度），用于删除前的尺寸漂移检测。
# 用快速遍历（不算精确磁盘占用），大目录也能保持秒级。
function Get-DsStoredSizeBytes {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $records = @(Invoke-DsWalk -Path $Path)
    $total = [long]0
    foreach ($r in $records) { $total += [long]$r.Length }
    return $total
}

# 计算条目到期信息：剩余天数与是否已到期。
function Get-DsEntryExpiry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [datetime]$Now = (Get-Date),
        [int]$DefaultRetentionDays = 7
    )

    $purgeAfter = $null
    if ($Entry.PSObject.Properties.Name -contains 'PurgeAfter' -and $Entry.PurgeAfter) {
        try { $purgeAfter = [datetime]$Entry.PurgeAfter } catch { $purgeAfter = $null }
    }
    if ($null -eq $purgeAfter -and $Entry.PSObject.Properties.Name -contains 'MovedAt' -and $Entry.MovedAt) {
        try { $purgeAfter = ([datetime]$Entry.MovedAt).AddDays($DefaultRetentionDays) } catch { $purgeAfter = $null }
    }
    if ($null -eq $purgeAfter) {
        # 旧版 manifest 没有时间戳：保守处理，视为未到期，只能手动选择删除
        return [pscustomobject]@{ PurgeAfter = $null; DaysLeft = $null; Expired = $false; Unknown = $true }
    }

    $daysLeft = [math]::Ceiling(($purgeAfter - $Now).TotalDays)
    [pscustomobject]@{ PurgeAfter = $purgeAfter; DaysLeft = $daysLeft; Expired = ($Now -ge $purgeAfter); Unknown = $false }
}
