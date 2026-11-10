function Get-DsInventory {
    <#
    .SYNOPSIS
        清点指定路径的真实占用，按目录汇总。
    .DESCRIPTION
        默认按"磁盘实际占用"统计（压缩/稀疏文件按真实大小，小文件按簇对齐），
        这比逻辑长度更接近"删掉能释放多少"。不给 -Path 时使用规则集里的全部路径。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$Path,
        [switch]$Fast,
        [int]$MaxDepth = -1,
        [switch]$IncludeFiles
    )

    if (-not $Path -or $Path.Count -eq 0) {
        $Path = @(
            Get-DsRuleSet |
                ForEach-Object { $_.Paths } |
                ForEach-Object { Resolve-DsRulePath -Pattern $_ } |
                Select-Object -Unique
        )
    }

    foreach ($item in $Path) {
        $resolved = Expand-DsPath -Pattern $item
        if (-not (Test-Path -LiteralPath $resolved)) {
            Write-Verbose "跳过不存在的路径: $resolved"
            continue
        }

        $summary = Get-DsPathSummary -Path $resolved -ExactAllocation:(-not $Fast) -MaxDepth $MaxDepth

        $topFolders = @()
        if ($summary.FileCount -gt 0) {
            $prefixLength = $resolved.TrimEnd('\').Length
            $groups = $summary.Records |
                ForEach-Object {
                    $relative = $_.Path.Substring($prefixLength).TrimStart('\')
                    $segment = ($relative -split '\\')[0]
                    [pscustomobject]@{ Name = $segment; Bytes = $_.Allocated }
                } |
                Group-Object -Property Name

            $topFolders = @(
                $groups |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name        = $_.Name
                            AllocatedMB = [math]::Round((($_.Group | Measure-Object -Property Bytes -Sum).Sum) / 1MB, 1)
                        }
                    } |
                    Sort-Object -Property AllocatedMB -Descending |
                    Select-Object -First 5
            )
        }

        $result = [pscustomobject]@{
            Path           = $summary.Path
            FileCount      = $summary.FileCount
            LengthMB       = $summary.LengthMB
            AllocatedMB    = $summary.AllocatedMB
            LastWriteUtc   = $summary.LastWriteUtc
            OldestWriteUtc = $summary.OldestWriteUtc
            TopFolders     = $topFolders
        }

        if ($IncludeFiles) {
            $result | Add-Member -NotePropertyName Files -NotePropertyValue $summary.Records
        }

        $result
    }
}
