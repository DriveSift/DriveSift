function Get-DsOwnership {
    <#
    .SYNOPSIS
        建立"目录 → 项目 / 工具链"的归属索引。
    .DESCRIPTION
        输出 Projects 与 Toolchains 两个索引。后续 Get-DsCandidate 用它们判断
        "某个缓存/某个运行时是否还有人在用"，而不是靠体积或修改时间猜。
    #>
    [CmdletBinding()]
    param(
        [string[]]$ProjectRoot = @(),
        [int]$MaxDepth = 4,
        [switch]$IncludeGitStatus
    )

    $projects = @()
    if ($ProjectRoot -and $ProjectRoot.Count -gt 0) {
        $projects = @(Get-DsProjectIndex -Root $ProjectRoot -MaxDepth $MaxDepth -IncludeGitStatus:$IncludeGitStatus)
    }

    $toolchains = @(Get-DsToolchainIndex -Projects $projects)

    [pscustomobject]@{
        GeneratedAt  = (Get-Date).ToString('s')
        ProjectRoots = $ProjectRoot
        Projects     = $projects
        Toolchains   = $toolchains
    }
}
