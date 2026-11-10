function Get-DsCandidate {
    <#
    .SYNOPSIS
        按规则集生成清理候选，并给出风险级别与理由。
    .DESCRIPTION
        每个候选都必须带着"归属 + 重建方式 + 风险级别 + 理由"四件套输出。
        P2 可以直接进隔离区；P1 需要 -IncludePending；P0 永远不会被执行。
        unit=child 但不需要逐项判断的规则（如临时目录）会聚合成一个候选，避免报告里出现几百行。
    #>
    [CmdletBinding()]
    param(
        [string]$RuleSetPath = $script:RulesPath,
        [ValidateSet('P0', 'P1', 'P2')]
        [string[]]$Tier = @('P1', 'P2'),
        [object]$Ownership,
        [switch]$Fast,
        [switch]$IncludeMissing,
        [string[]]$Id
    )

    $rules = @(Get-DsRuleSet -Path $RuleSetPath)
    if ($Id) { $rules = @($rules | Where-Object { $_.Id -in $Id }) }

    foreach ($rule in $rules) {
        $targets = New-Object System.Collections.ArrayList

        foreach ($pattern in $rule.Paths) {
            foreach ($resolved in @(Resolve-DsRulePath -Pattern $pattern)) {
                if ($rule.Unit -eq 'child') {
                    $children = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue)
                    foreach ($child in $children) { [void]$targets.Add($child.FullName) }
                }
                else {
                    [void]$targets.Add($resolved)
                }
            }
        }

        if ($targets.Count -eq 0) { continue }

        # 默认每个目标路径单独成候选；规则声明 aggregate 时聚合成一个（如临时目录、缩略图）
        $perItem = -not $rule.Aggregate
        $units = @()
        if ($perItem) {
            $units = @($targets | ForEach-Object { , @($_) })
        }
        else {
            $units = @(, @($targets))
        }

        foreach ($unit in $units) {
            $paths = @($unit)
            $existing = @($paths | Where-Object { Test-Path -LiteralPath $_ })
            if ($existing.Count -eq 0 -and -not $IncludeMissing) { continue }

            $fileCount = 0
            $sizeMB = 0
            $sizeBytes = [long]0
            $lengthMB = 0
            $newest = $null

            foreach ($path in $existing) {
                $summary = Get-DsPathSummary -Path $path -ExactAllocation:(-not $Fast)
                $fileCount += $summary.FileCount
                $sizeMB += $summary.AllocatedMB
                $sizeBytes += [long]$summary.AllocatedBytes
                $lengthMB += $summary.LengthMB
                if ($summary.LastWriteUtc -and (-not $newest -or $summary.LastWriteUtc -gt $newest)) {
                    $newest = $summary.LastWriteUtc
                }
            }

            $finalTier = $rule.Tier
            $reasons = @()
            $primary = if ($existing.Count -gt 0) { $existing[0] } else { $paths[0] }
            $state = if ($existing.Count -gt 0) { 'Exists' } else { 'Missing' }

            if ($existing.Count -gt 0 -and $fileCount -eq 0) {
                # 能枚举 = 空目录，没有清理价值；无法枚举 = 可能藏着大量数据，必须保留并标注
                $readable = $true
                foreach ($path in $existing) {
                    try {
                        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                            [void][System.IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator().MoveNext()
                        }
                    }
                    catch { $readable = $false; break }
                }

                if ($readable) { continue }
                $state = 'Unreadable'
                $reasons += '无法读取（可能需要管理员权限）'
            }

            if (Test-DsProtectedPath -Path $primary) {
                $finalTier = 'P0'
                $reasons += '命中受保护路径'
            }

            $reference = [pscustomobject]@{ Referenced = $false; By = @() }
            foreach ($guard in $rule.Guards) {
                switch ($guard) {
                    'unreferenced' {
                        if ($Ownership) {
                            $reference = Test-DsToolchainReference -Path $primary -Toolchains $Ownership.Toolchains
                            if ($reference.Referenced) {
                                if ($finalTier -ne 'P0') { $finalTier = 'P1' }
                                $reasons += "仍被引用: $($reference.By -join ', ')"
                            }
                        }
                        else {
                            if ($finalTier -ne 'P0') { $finalTier = 'P1' }
                            $reasons += '未提供归属索引，无法确认是否被引用'
                        }
                    }
                    'manual' {
                        if ($finalTier -ne 'P0') { $finalTier = 'P1' }
                        $reasons += '规则要求人工确认'
                    }
                    default {
                        if ($finalTier -ne 'P0') { $finalTier = 'P1' }
                        $reasons += "未知守卫: $guard"
                    }
                }
            }

            # 内容相关性检查：规则说"这是缓存"，先看里面实际装了什么。
            # 出现未白名单的个人文件（文档/图片/音视频/源码/压缩包/数据库/密钥）时降级并要求人工确认。
            $content = [pscustomobject]@{
                CheckedFiles      = 0
                Truncated         = $false
                SuspiciousCount   = 0
                SuspiciousKinds   = ''
                SuspiciousSamples = @()
                TopCategories     = ''
            }
            if ($existing.Count -gt 0 -and $fileCount -gt 0) {
                $allow = @()
                if ($rule.PSObject.Properties.Name -contains 'AllowContent') { $allow = @($rule.AllowContent) }
                $content = Get-DsContentProfile -Path $primary -Allow $allow

                if ($content.SuspiciousCount -gt 0) {
                    if ($finalTier -ne 'P0') { $finalTier = 'P1' }
                    $scope = if ($content.Truncated) { '抽样 {0} 个文件（目录较大，已截断）' -f $content.CheckedFiles }
                    else { '抽样 {0} 个文件' -f $content.CheckedFiles }
                    $reasons += ('内容检查：{0}，发现 {1} 个疑似个人文件（{2}），已要求人工确认' -f `
                        $scope, $content.SuspiciousCount, $content.SuspiciousKinds)
                }
            }

            $owner = $rule.Owner
            if ($Ownership -and $existing.Count -eq 1) {
                $project = Get-DsProjectRootForPath -Path $primary -Projects $Ownership.Projects
                if ($project) { $owner = "project:$($project.Name)" }
            }

            if ($reasons.Count -eq 0) {
                if (-not $perItem) {
                    $reasons += "聚合 $($paths.Count) 个子项"
                }
                else {
                    $reasons += '无附加守卫命中'
                }
            }

            $candidateId = if (-not $perItem) { $rule.Id } else { "$($rule.Id):$primary" }

            $candidate = [pscustomobject]@{
                Id                = $candidateId
                RuleId            = $rule.Id
                Name              = $rule.Name
                Category          = $rule.Category
                Owner             = $owner
                Tier              = $finalTier
                RequestedTier     = $rule.Tier
                State             = $state
                Paths             = $paths
                FileCount         = $fileCount
                SizeBytes         = $sizeBytes
                SizeMB            = [math]::Round($sizeMB, 1)
                LengthMB          = [math]::Round($lengthMB, 1)
                LastWriteUtc      = $newest
                Rebuild           = $rule.Rebuild
                Notes             = $rule.Notes
                Referenced        = $reference.Referenced
                ReferencedBy      = $reference.By
                Reasons           = $reasons
                Protected         = ($finalTier -eq 'P0')
                ContentChecked    = $content.CheckedFiles
                ContentTruncated  = $content.Truncated
                ContentHits       = $content.SuspiciousCount
                ContentHitKinds   = $content.SuspiciousKinds
                ContentHitSamples = @($content.SuspiciousSamples)
                ContentTop        = $content.TopCategories
            }

            if ($Tier -contains $finalTier) { $candidate }
        }
    }
}
