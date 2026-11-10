function Get-DsAutoPurgeStatus {
    <#
    .SYNOPSIS
        查看"自动清理到期条目"定时任务的注册状态（只读）。
    #>
    [CmdletBinding()]
    param()

    $taskName = 'DriveSift AutoPurge'
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ TaskName = $taskName; Registered = $false; State = 'not-registered' }
    }

    $state = [string]$task.State
    $dailyAt = $null
    if ($task.Triggers -and $task.Triggers.Count -gt 0 -and $task.Triggers[0].StartBoundary) {
        try {
            $dailyAt = ([datetime]$task.Triggers[0].StartBoundary).ToString('HH:mm')
        }
        catch { }
    }
    [pscustomobject]@{ TaskName = $taskName; Registered = $true; State = $state; DailyAt = $dailyAt; Description = [string]$task.Description }
}

function Register-DsAutoPurge {
    <#
    .SYNOPSIS
        注册或注销"自动清理隔离区到期条目"的每日定时任务。
    .DESCRIPTION
        默认关闭。注册后每天在指定时间运行 Remove-DsQuarantine -Expired -Auto：
        只删除已过保留期（默认 7 天）的条目，删除前同样经过防篡改与尺寸漂移检测，
        并写入 audit.jsonl 留痕。未注册时，隔离区条目会一直保留到用户手动处理。
        任务以当前用户身份运行，不需要管理员。
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$QuarantineRoot,
        [ValidateRange(1, 365)]
        [int]$RetentionDays = 7,
        [ValidatePattern('^\d{2}:\d{2}$')]
        [string]$DailyAt = '03:30',
        [switch]$Unregister
    )

    $taskName = 'DriveSift AutoPurge'

    if ($Unregister) {
        $status = Get-DsAutoPurgeStatus
        if (-not $status.Registered) {
            Write-Warning "定时任务不存在，无需注销: $taskName"
            return [pscustomobject]@{ TaskName = $taskName; Registered = $false; State = 'not-registered' }
        }
        if ($PSCmdlet.ShouldProcess($taskName, '注销定时任务')) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
            [pscustomobject]@{ TaskName = $taskName; Registered = $false; State = 'unregistered' }
        }
        return
    }

    $status = Get-DsAutoPurgeStatus
    if ($status.Registered) {
        Write-Warning "定时任务已存在（每日 $($status.DailyAt)），如需重建请先 -Unregister: $taskName"
        return [pscustomobject]@{ TaskName = $taskName; Registered = $true; State = 'already-registered' }
    }

    if ($QuarantineRoot -like "*'*" -or $script:ModuleRoot -like "*'*") {
        throw '隔离区路径或模块路径含单引号，无法安全构造任务命令。'
    }

    if (-not $PSCmdlet.ShouldProcess($taskName, "注册每日 $DailyAt 的自动清理任务（保留期 $RetentionDays 天）")) {
        return
    }

    $modulePath = Join-Path $script:ModuleRoot 'DriveSift.psd1'
    $command = "Import-Module -Name '$modulePath' -Force; Remove-DsQuarantine -QuarantineRoot '$QuarantineRoot' -RetentionDays $RetentionDays -Expired -Auto"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $command + '"'
    )
    $hour = [int]($DailyAt -split ':')[0]
    $minute = [int]($DailyAt -split ':')[1]
    $at = [datetime]::new(2000, 1, 1, $hour, $minute, 0)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description "DriveSift：每日自动永久删除隔离区中超过 $RetentionDays 天保留期的条目（$QuarantineRoot）" | Out-Null

    [pscustomobject]@{
        TaskName       = $taskName
        Registered     = $true
        State          = 'registered'
        DailyAt        = $DailyAt
        RetentionDays  = $RetentionDays
        QuarantineRoot = $QuarantineRoot
    }
}
