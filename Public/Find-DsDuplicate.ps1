function Find-DsDuplicate {
    <#
    .SYNOPSIS
        按内容哈希找出完全重复的文件，并识别硬链接共享。
    .DESCRIPTION
        先按大小分桶，只对同尺寸的文件计算 SHA256，避免全盘哈希。
        LinkCount 大于 1 的副本被删除时不会释放空间，这部分不计入 ReclaimableMB。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Path,
        [long]$MinSize = 1MB,
        [int]$MaxDepth = -1,
        [switch]$Fast,
        [object]$Ownership,
        [switch]$IgnoreHardlinks
    )

    $records = New-Object System.Collections.ArrayList
    foreach ($root in $Path) {
        $walked = @(Invoke-DsWalk -Path $root -MaxDepth $MaxDepth -ExactAllocation:(-not $Fast))
        foreach ($r in $walked) {
            if ($r.Length -ge $MinSize -and -not $r.IsReparse) {
                [void]$records.Add($r)
            }
        }
    }

    if ($records.Count -eq 0) { return }

    $bySize = @{}
    foreach ($r in $records) {
        $key = [string]$r.Length
        if (-not $bySize.ContainsKey($key)) { $bySize[$key] = New-Object System.Collections.ArrayList }
        [void]$bySize[$key].Add($r)
    }

    $sizeGroups = @($bySize.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
    if ($sizeGroups.Count -eq 0) { return }

    $groupIndex = 0
    $total = $sizeGroups.Count

    foreach ($entry in $sizeGroups) {
        $groupIndex++
        Write-Progress -Activity '计算重复文件' -Status "$groupIndex / $total 组" -PercentComplete ([int](100 * $groupIndex / $total))

        $byHash = @{}
        foreach ($r in $entry.Value) {
            $hash = Get-DsFileHash -Path $r.Path
            if (-not $hash) { continue }
            if (-not $byHash.ContainsKey($hash)) { $byHash[$hash] = New-Object System.Collections.ArrayList }
            [void]$byHash[$hash].Add($r)
        }

        foreach ($hashEntry in $byHash.GetEnumerator()) {
            if ($hashEntry.Value.Count -lt 2) { continue }

            $files = @()
            $owners = @()
            $reclaimable = [long]0
            $first = $true

            foreach ($r in $hashEntry.Value) {
                $linkCount = 1
                if (-not $IgnoreHardlinks) {
                    try { $linkCount = [DriveSift.Native]::LinkCount($r.Path) } catch { $linkCount = 1 }
                }

                $freed = [long]0
                if (-not $first -and $linkCount -le 1) { $freed = [long]$r.Allocated }

                $owner = $null
                if ($Ownership) {
                    $project = Get-DsProjectRootForPath -Path $r.Path -Projects $Ownership.Projects
                    if ($project) { $owner = $project.Name }
                }
                if ($owner) { $owners += $owner }

                $files += [pscustomobject]@{
                    Path           = $r.Path
                    LinkCount      = $linkCount
                    Owner          = $owner
                    ReclaimableMB  = [math]::Round($freed / 1MB, 1)
                }

                $reclaimable += $freed
                $first = $false
            }

            [pscustomobject]@{
                Hash           = $hashEntry.Key
                SizeBytes      = [long]$entry.Key
                SizeMB         = [math]::Round([long]$entry.Key / 1MB, 1)
                FileCount      = $files.Count
                ReclaimableMB  = [math]::Round($reclaimable / 1MB, 1)
                Owners         = @($owners | Sort-Object -Unique)
                Files          = $files
            }
        }
    }

    Write-Progress -Activity '计算重复文件' -Completed
}
