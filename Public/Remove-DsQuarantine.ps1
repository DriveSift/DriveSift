function Remove-DsQuarantine {
    <#
    .SYNOPSIS
        永久删除隔离区里的条目。
    .DESCRIPTION
        模块中唯一的破坏性命令，执行链路逐层设防：
        1. 防篡改：只删除 manifest 中登记、且 StoredPath 位于隔离根目录之下的条目；
        2. 漂移检测：条目当前大小与记录值偏差超过 10%（隔离期间内容被改动）时默认跳过，
           需 -IncludeChanged 才允许删除；
        3. 选择范围受限：-All 对未到期条目必须再给 -IncludeActive；-Expired / -Auto 只触及已到期条目；
        4. 确认机制：交互调用走 ShouldProcess（High）；-Auto 供定时任务使用，仅清理到期条目；
        5. 留痕与可重试：每次删除写入 audit.jsonl；删除失败（文件被占用）的条目保留在 manifest 中。
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$QuarantineRoot,
        [string[]]$EntryId,
        [string]$Batch,
        [switch]$Expired,
        [switch]$All,
        [switch]$IncludeActive,
        [switch]$IncludeChanged,
        [switch]$Auto,
        [ValidateRange(1, 365)]
        [int]$DefaultRetentionDays = 7
    )

    if ($Auto -and ($EntryId -or $Batch -or $All -or $Expired)) {
        throw '-Auto 只按到期时间清理，不能与其他选择参数组合。'
    }
    if (-not ($EntryId -or $Batch -or $Expired -or $All -or $Auto)) {
        throw '请指定 -EntryId、-Batch、-Expired、-All 之一，或 -Auto（定时任务专用）。'
    }

    $entries = @(Read-DsManifest -QuarantineRoot $QuarantineRoot)
    if ($entries.Count -eq 0) {
        Write-Warning '隔离区为空（manifest 不存在或没有条目）。'
        return
    }

    $now = Get-Date
    $selected = New-Object System.Collections.ArrayList
    $reasonOf = @{}

    foreach ($e in $entries) {
        $inScope = $false
        $why = ''

        if ($EntryId) {
            $ids = @($EntryId)
            if ($ids -contains [string]$e.EntryId) { $inScope = $true; $why = 'manual' }
            elseif ($ids -contains [string]$e.Id) { $inScope = $true; $why = 'manual' }
        }
        elseif ($Batch) {
            if ([string]$e.Batch -eq $Batch) { $inScope = $true; $why = 'manual' }
        }
        else {
            $expiry = Get-DsEntryExpiry -Entry $e -Now $now -DefaultRetentionDays $DefaultRetentionDays
            if ($Auto -or $Expired) {
                if ($expiry.Expired) { $inScope = $true; $why = if ($Auto) { 'auto' } else { 'expired' } }
            }
            elseif ($All) {
                if ($expiry.Expired) { $inScope = $true; $why = 'expired' }
                elseif ($IncludeActive) { $inScope = $true; $why = 'manual' }
            }
        }

        if ($inScope) {
            $reasonOf[[string]$e.EntryId] = $why
            [void]$selected.Add($e)
        }
    }

    if ($selected.Count -eq 0) {
        Write-Warning '没有条目满足删除条件。-Expired/-Auto 只清理已到期条目；未到期条目需 -All + -IncludeActive。'
        return
    }

    $purgedIds = New-Object System.Collections.ArrayList
    $manifestPath = Get-DsManifestPath -QuarantineRoot $QuarantineRoot

    foreach ($e in $selected) {
        $entryId = [string]$e.EntryId
        $stored = [string]$e.StoredPath
        $why = $reasonOf[$entryId]

        # 防线 1：防篡改——manifest 被改写指向隔离区之外时，直接拒绝
        if (-not (Test-DsUnderPath -Path $stored -Root $QuarantineRoot)) {
            Write-Warning "条目 StoredPath 不在隔离区内，拒绝删除（可能被人改动过 manifest）: $stored"
            [pscustomobject]@{ Action = 'Skipped'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = '防篡改拦截：路径不在隔离区内' }
            continue
        }

        if (-not (Test-Path -LiteralPath $stored)) {
            # 数据已经不在了：清掉清单条目即可，留痕
            $purgeKey = if ($entryId) { $entryId } else { ([string]$e.Batch + '|' + [string]$e.OriginalPath) }
            [void]$purgedIds.Add($purgeKey)
            Add-DsAuditLog -QuarantineRoot $QuarantineRoot -Event @{
                Action = 'purged'; EntryId = $entryId; Name = $e.Name
                StoredPath = $stored; SizeBytes = $e.SizeBytes; Reason = $why; Note = '存储路径已不存在，仅清理清单'
            }
            [pscustomobject]@{ Action = 'Purged'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = '存储路径已不存在，仅清理清单' }
            continue
        }

        # 防线 2：漂移检测——隔离期间内容被改动时不删
        $changed = $false
        $recordedBytes = $null
        if ($e.PSObject.Properties.Name -contains 'SizeBytes' -and $null -ne $e.SizeBytes) {
            $recordedBytes = [long]$e.SizeBytes
        }
        if ($null -ne $recordedBytes -and $recordedBytes -gt 0) {
            $currentBytes = Get-DsStoredSizeBytes -Path $stored
            if ($null -ne $currentBytes) {
                $drift = [math]::Abs([double]($currentBytes - $recordedBytes)) / [double]$recordedBytes
                if ($drift -gt 0.10) { $changed = $true }
            }
        }
        if ($changed -and -not $IncludeChanged) {
            Write-Warning "条目内容在隔离期间发生变化（尺寸偏差 >10%），默认跳过: $($e.Name)"
            [pscustomobject]@{ Action = 'Skipped'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = '内容漂移，需 -IncludeChanged' }
            continue
        }

        # 防线 3：确认
        if (-not $PSCmdlet.ShouldProcess($stored, '永久删除隔离条目（不可恢复）')) { continue }

        try {
            Remove-Item -LiteralPath $stored -Recurse -Force -ErrorAction Stop

            # 删除后校验：必须真正消失；被占用时保留条目供重试
            if (Test-Path -LiteralPath $stored) {
                [pscustomobject]@{ Action = 'Failed'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = '删除后路径仍存在（可能被占用）' }
                continue
            }

            $purgeKey = if ($entryId) { $entryId } else { ([string]$e.Batch + '|' + [string]$e.OriginalPath) }
            [void]$purgedIds.Add($purgeKey)
            Add-DsAuditLog -QuarantineRoot $QuarantineRoot -Event @{
                Action = 'purged'; EntryId = $entryId; Name = $e.Name
                StoredPath = $stored; SizeBytes = $recordedBytes; Reason = $why; Changed = $changed
            }
            [pscustomobject]@{ Action = 'Purged'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = '' }
        }
        catch {
            Write-Warning "永久删除失败（可能正被占用）: $stored | $($_.Exception.Message)"
            [pscustomobject]@{ Action = 'Failed'; EntryId = $entryId; Name = $e.Name; StoredPath = $stored; SizeMB = $e.SizeMB; Reason = $_.Exception.Message }
        }
    }

    # 全部处理完再原子化重写 manifest；中途出错时清单保持原样
    if ($purgedIds.Count -gt 0) {
        $remaining = @($entries | Where-Object {
            $id = [string]$_.EntryId
            if ($id) {
                -not ($purgedIds -contains $id)
            }
            else {
                # 旧版无 EntryId 的条目按 批次+原路径 匹配
                -not ($purgedIds -contains ([string]$_.Batch + '|' + [string]$_.OriginalPath))
            }
        })
        if ($remaining.Count -ne $entries.Count) {
            Write-DsManifest -QuarantineRoot $QuarantineRoot -Entries $remaining
        }
    }
}
