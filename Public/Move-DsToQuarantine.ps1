function Move-DsToQuarantine {
    <#
    .SYNOPSIS
        把候选移入隔离区，并写入可回滚、带到期时间的 manifest。
    .DESCRIPTION
        只做移动，不做删除。同盘移动是改名（瞬间完成），跨盘会退化为复制。
        P2 直接允许；P1 需要 -IncludePending；P0 永远拒绝。
        每条记录分配 EntryId 与到期时间（移入时间 + RetentionDays 天）：
        到期前可用 Restore-DsQuarantine 随时原位还原；到期后走 Remove-DsQuarantine 永久删除。
        执行前复核保护清单，移动后校验源路径消失且目标就位，校验失败自动回滚。
        所有操作同步写入 audit.jsonl 留痕。
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [object[]]$Candidate,
        [Parameter(Mandatory)]
        [string]$QuarantineRoot,
        [ValidateRange(1, 365)]
        [int]$RetentionDays = 7,
        [switch]$IncludePending
    )

    begin {
        $items = New-Object System.Collections.ArrayList
    }

    process {
        foreach ($c in $Candidate) {
            if ($null -ne $c) { [void]$items.Add($c) }
        }
    }

    end {
        if ($items.Count -eq 0) {
            Write-Warning '没有收到任何候选。'
            return
        }

        $batch = Get-Date -Format 'yyyyMMdd-HHmmss'
        $batchRoot = Join-Path $QuarantineRoot $batch
        $quarantineVolume = Split-Path -Qualifier $QuarantineRoot

        if (-not (Test-Path -LiteralPath $QuarantineRoot)) {
            if ($PSCmdlet.ShouldProcess($QuarantineRoot, '创建隔离区根目录')) {
                New-Item -ItemType Directory -Path $QuarantineRoot -Force | Out-Null
            }
        }

        $manifest = @(Read-DsManifest -QuarantineRoot $QuarantineRoot)
        $index = 0

        foreach ($c in $items) {
            if ($c.Tier -eq 'P0' -or $c.Protected) {
                Write-Warning "拒绝移动受保护候选: $($c.Name)"
                continue
            }
            if ($c.Tier -eq 'P1' -and -not $IncludePending) {
                Write-Warning "跳过 P1 候选（需 -IncludePending）: $($c.Name)"
                continue
            }

            foreach ($path in @($c.Paths)) {
                if (-not (Test-Path -LiteralPath $path)) {
                    Write-Warning "路径已不存在，跳过: $path"
                    continue
                }

                # 执行前复核：保护清单不可被规则或候选对象绕过；隔离区自身不允许再被移入
                if (Test-DsProtectedPath -Path $path) {
                    Write-Warning "命中保护清单，拒绝移动: $path"
                    continue
                }
                if (Test-DsUnderPath -Path $path -Root $QuarantineRoot) {
                    Write-Warning "路径已在隔离区内，跳过: $path"
                    continue
                }

                $index++
                $leaf = Split-Path -Leaf $path
                $slot = Join-Path $batchRoot ('{0:D3}' -f $index)
                $destination = Join-Path $slot $leaf

                $sourceVolume = Split-Path -Qualifier $path
                if ($sourceVolume -ne $quarantineVolume) {
                    Write-Warning "跨盘移动会复制数据而不是改名，耗时且需要临时空间: $path"
                }

                if (-not $PSCmdlet.ShouldProcess($path, '移入隔离区')) { continue }

                try {
                    New-Item -ItemType Directory -Path $slot -Force | Out-Null
                    Move-Item -LiteralPath $path -Destination $destination -Force -ErrorAction Stop

                    # 移动后校验：源必须消失、目标必须就位，否则立即回滚，避免"半移动"状态
                    $sourceGone = -not (Test-Path -LiteralPath $path)
                    $destExists = Test-Path -LiteralPath $destination
                    if (-not ($sourceGone -and $destExists)) {
                        $rollbackNote = ''
                        if ($destExists) {
                            try {
                                Move-Item -LiteralPath $destination -Destination $path -Force -ErrorAction Stop
                            }
                            catch {
                                $rollbackNote = "，回滚亦失败请人工检查（$($_.Exception.Message)）"
                            }
                        }
                        Write-Warning "移动后校验失败，已回滚${rollbackNote} — $path"
                        [pscustomobject]@{
                            Action       = 'Failed'
                            Name         = $c.Name
                            Tier         = $c.Tier
                            OriginalPath = $path
                            StoredPath   = $null
                            SizeMB       = $c.SizeMB
                            Reason       = '移动后校验失败，已回滚'
                        }
                        continue
                    }

                    $sizeBytes = [long]0
                    if ($c.PSObject.Properties.Name -contains 'SizeBytes' -and $null -ne $c.SizeBytes) {
                        $sizeBytes = [long]$c.SizeBytes
                    }
                    else { $sizeBytes = [long]($c.SizeMB * 1MB) }

                    $contentHits = 0
                    $contentKinds = ''
                    if ($c.PSObject.Properties.Name -contains 'ContentHits') { $contentHits = [int]$c.ContentHits }
                    if ($c.PSObject.Properties.Name -contains 'ContentHitKinds') { $contentKinds = [string]$c.ContentHitKinds }

                    $movedAt = Get-Date
                    $record = [ordered]@{
                        Batch           = $batch
                        EntryId         = [guid]::NewGuid().ToString('N')
                        Id              = [string]$c.Id
                        RuleId          = [string]$c.RuleId
                        Name            = [string]$c.Name
                        Tier            = [string]$c.Tier
                        OriginalPath    = $path
                        StoredPath      = $destination
                        SizeBytes       = $sizeBytes
                        SizeMB          = $c.SizeMB
                        FileCount       = $c.FileCount
                        Rebuild         = [string]$c.Rebuild
                        MovedAt         = $movedAt.ToString('s')
                        PurgeAfter      = $movedAt.AddDays($RetentionDays).ToString('s')
                        RetentionDays   = $RetentionDays
                        ContentHits     = $contentHits
                        ContentHitKinds = $contentKinds
                    }

                    $manifest = @($manifest + [pscustomobject]$record)
                    Write-DsManifest -QuarantineRoot $QuarantineRoot -Entries $manifest
                    Add-DsAuditLog -QuarantineRoot $QuarantineRoot -Event @{
                        Action = 'quarantined'; EntryId = $record.EntryId; Name = $record.Name
                        OriginalPath = $path; SizeBytes = $sizeBytes
                    }

                    [pscustomobject]@{
                        Action       = 'Quarantined'
                        Name         = $c.Name
                        Tier         = $c.Tier
                        OriginalPath = $path
                        StoredPath   = $destination
                        SizeMB       = $c.SizeMB
                        Reason       = ''
                    }
                }
                catch {
                    Write-Warning "移动失败（可能正被占用）: $path | $($_.Exception.Message)"
                    [pscustomobject]@{
                        Action       = 'Failed'
                        Name         = $c.Name
                        Tier         = $c.Tier
                        OriginalPath = $path
                        StoredPath   = $null
                        SizeMB       = $c.SizeMB
                        Reason       = $_.Exception.Message
                    }
                }
            }
        }
    }
}
