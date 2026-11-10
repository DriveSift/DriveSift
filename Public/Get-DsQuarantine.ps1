function Get-DsQuarantine {
    <#
    .SYNOPSIS
        列出隔离区里的条目及其到期状态（只读）。
    .DESCRIPTION
        读取 manifest.jsonl，为每个条目计算剩余保留天数与是否已到期。
        旧版 manifest（无时间戳）的条目按"未到期、需手动选择"处理，不会自动清理。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$QuarantineRoot,
        [ValidateRange(1, 365)]
        [int]$DefaultRetentionDays = 7,
        [switch]$ExpiredOnly
    )

    $entries = @(Read-DsManifest -QuarantineRoot $QuarantineRoot)
    $now = Get-Date

    foreach ($e in $entries) {
        $expiry = Get-DsEntryExpiry -Entry $e -Now $now -DefaultRetentionDays $DefaultRetentionDays
        if ($ExpiredOnly -and -not $expiry.Expired) { continue }

        $sizeMB = $null
        if ($e.PSObject.Properties.Name -contains 'SizeMB' -and $null -ne $e.SizeMB) { $sizeMB = [double]$e.SizeMB }
        elseif ($e.PSObject.Properties.Name -contains 'SizeBytes') { $sizeMB = [math]::Round([double][long]$e.SizeBytes / 1MB, 1) }

        $entryId = ''
        if ($e.PSObject.Properties.Name -contains 'EntryId') { $entryId = [string]$e.EntryId }

        [pscustomobject]@{
            Batch         = [string]$e.Batch
            EntryId       = $entryId
            Id            = [string]$e.Id
            Name          = [string]$e.Name
            Tier          = [string]$e.Tier
            OriginalPath  = [string]$e.OriginalPath
            StoredPath    = [string]$e.StoredPath
            SizeMB        = $sizeMB
            SizeBytes     = if ($e.PSObject.Properties.Name -contains 'SizeBytes') { [long]$e.SizeBytes } else { $null }
            MovedAt       = if ($e.PSObject.Properties.Name -contains 'MovedAt') { [string]$e.MovedAt } else { '' }
            PurgeAfter    = $expiry.PurgeAfter
            DaysLeft      = $expiry.DaysLeft
            Expired       = $expiry.Expired
            ExpiryUnknown = $expiry.Unknown
            StoredExists  = (Test-Path -LiteralPath $e.StoredPath)
            ContentHits   = if ($e.PSObject.Properties.Name -contains 'ContentHits') { [int]$e.ContentHits } else { 0 }
            Rebuild       = [string]$e.Rebuild
        }
    }
}
