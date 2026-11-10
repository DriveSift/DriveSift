function Restore-DsQuarantine {
    <#
    .SYNOPSIS
        查看或还原隔离区里的内容。
    .DESCRIPTION
        读取 manifest.jsonl，把条目移回原始路径。原路径已存在时跳过，不覆盖。
        还原成功后条目从 manifest 中移除，并写入 audit.jsonl 留痕。
        与永久删除同样受防篡改校验保护：StoredPath 必须位于隔离根目录之下。
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$QuarantineRoot,
        [string]$EntryId,
        [string]$Id,
        [string]$Batch,
        [switch]$List,
        [switch]$All
    )

    $entries = @(Read-DsManifest -QuarantineRoot $QuarantineRoot)
    if ($entries.Count -eq 0) {
        throw "隔离区为空或找不到 manifest: $QuarantineRoot"
    }

    if ($EntryId) { $entries = @($entries | Where-Object { [string]$_.EntryId -eq $EntryId -or [string]$_.Id -eq $EntryId }) }
    if ($Id) { $entries = @($entries | Where-Object { [string]$_.Id -eq $Id }) }
    if ($Batch) { $entries = @($entries | Where-Object { [string]$_.Batch -eq $Batch }) }

    if ($List -or (-not $All -and -not $EntryId -and -not $Id -and -not $Batch)) {
        return $entries | ForEach-Object {
            [pscustomobject]@{
                Batch         = [string]$_.Batch
                EntryId       = if ($_.PSObject.Properties.Name -contains 'EntryId') { [string]$_.EntryId } else { '' }
                Id            = [string]$_.Id
                Name          = [string]$_.Name
                Tier          = [string]$_.Tier
                SizeMB        = $_.SizeMB
                MovedAt       = if ($_.PSObject.Properties.Name -contains 'MovedAt') { [string]$_.MovedAt } else { '' }
                OriginalPath  = [string]$_.OriginalPath
                StoredPath    = [string]$_.StoredPath
                Exists        = (Test-Path -LiteralPath $_.StoredPath)
            }
        }
    }

    if ($entries.Count -eq 0) {
        Write-Warning '没有匹配要还原的条目。'
        return
    }

    $restoredKeys = New-Object System.Collections.ArrayList
    $allEntries = @(Read-DsManifest -QuarantineRoot $QuarantineRoot)

    foreach ($entry in $entries) {
        $entryId = ''
        if ($entry.PSObject.Properties.Name -contains 'EntryId') { $entryId = [string]$entry.EntryId }

        if (-not (Test-DsUnderPath -Path $entry.StoredPath -Root $QuarantineRoot)) {
            Write-Warning "条目 StoredPath 不在隔离区内，拒绝还原（可能被人改动过 manifest）: $($entry.StoredPath)"
            continue
        }
        if (-not (Test-Path -LiteralPath $entry.StoredPath)) {
            Write-Warning "隔离文件不在了，跳过: $($entry.StoredPath)"
            continue
        }
        if (Test-Path -LiteralPath $entry.OriginalPath) {
            Write-Warning "原路径已存在，跳过（不覆盖）: $($entry.OriginalPath)"
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($entry.OriginalPath, '从隔离区还原')) { continue }

        try {
            $parent = Split-Path -Parent $entry.OriginalPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $entry.StoredPath -Destination $entry.OriginalPath -Force -ErrorAction Stop

            # 还原后校验：原路径必须就位，否则把文件移回去
            if (-not (Test-Path -LiteralPath $entry.OriginalPath)) {
                Write-Warning "还原后校验失败，把条目移回隔离区: $($entry.OriginalPath)"
                Move-Item -LiteralPath $entry.StoredPath -Destination (Join-Path (Split-Path -Parent $entry.StoredPath) (Split-Path -Leaf $entry.OriginalPath)) -Force -ErrorAction Stop
                [pscustomobject]@{ Action = 'Failed'; Name = $entry.Name; OriginalPath = $entry.OriginalPath; SizeMB = $entry.SizeMB }
                continue
            }

            $key = if ($entryId) { $entryId } else { ([string]$entry.Batch + '|' + [string]$entry.OriginalPath) }
            [void]$restoredKeys.Add($key)
            Add-DsAuditLog -QuarantineRoot $QuarantineRoot -Event @{
                Action = 'restored'; EntryId = $entryId; Name = $entry.Name
                OriginalPath = $entry.OriginalPath
            }
            [pscustomobject]@{
                Action       = 'Restored'
                Name         = [string]$entry.Name
                OriginalPath = [string]$entry.OriginalPath
                SizeMB       = $entry.SizeMB
            }
        }
        catch {
            Write-Warning "还原失败: $($entry.OriginalPath) | $($_.Exception.Message)"
        }
    }

    if ($restoredKeys.Count -gt 0) {
        $remaining = @($allEntries | Where-Object {
            $id = [string]$_.EntryId
            if ($id) {
                -not ($restoredKeys -contains $id)
            }
            else {
                -not ($restoredKeys -contains ([string]$_.Batch + '|' + [string]$_.OriginalPath))
            }
        })
        if ($remaining.Count -ne $allEntries.Count) {
            Write-DsManifest -QuarantineRoot $QuarantineRoot -Entries $remaining
        }
    }
}
