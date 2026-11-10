function Invoke-DsAudit {
    <#
    .SYNOPSIS
        一条命令跑完整条审计链路：归属 → 清点 → 候选 → 重复 → 报告。
    .DESCRIPTION
        只读。不会移动或删除任何文件，产出是一份可归档的 HTML 报告。
    .EXAMPLE
        Invoke-DsAudit -ProjectRoot C:\Projects -DuplicatePath C:\Projects -OutFile .\report.html -Open
    #>
    [CmdletBinding()]
    param(
        [string[]]$ProjectRoot = @(),
        [string[]]$DuplicatePath = @(),
        [long]$MinSize = 1MB,
        [string]$OutFile = (Join-Path (Get-Location) 'DriveSift-report.html'),
        [switch]$IncludeGitStatus,
        [switch]$Fast,
        [switch]$Open
    )

    Write-Progress -Activity 'DriveSift 审计' -Status '建立归属索引' -PercentComplete 5
    $ownership = Get-DsOwnership -ProjectRoot $ProjectRoot -IncludeGitStatus:$IncludeGitStatus

    Write-Progress -Activity 'DriveSift 审计' -Status '生成清理候选' -PercentComplete 65
    $candidates = @(Get-DsCandidate -Ownership $ownership -Fast:$Fast)

    $duplicates = @()
    if ($DuplicatePath -and $DuplicatePath.Count -gt 0) {
        Write-Progress -Activity 'DriveSift 审计' -Status '查找重复文件' -PercentComplete 80
        $duplicates = @(Find-DsDuplicate -Path $DuplicatePath -MinSize $MinSize -Ownership $ownership -Fast:$Fast)
    }

    Write-Progress -Activity 'DriveSift 审计' -Status '生成报告' -PercentComplete 95
    $report = New-DsReport -Candidate $candidates -Duplicate $duplicates -Ownership $ownership -OutFile $OutFile -Open:$Open

    Write-Progress -Activity 'DriveSift 审计' -Completed

    [pscustomobject]@{
        Report      = $report.Path
        Candidates  = $candidates
        Duplicates  = $duplicates
        Ownership   = $ownership
    }
}
