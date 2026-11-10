function Get-DsOptimizationSuggestion {
    <#
    .SYNOPSIS
        根据体检数据生成电脑优化建议。
    .DESCRIPTION
        每条建议 = 诊断（基于实测指标）+ 指引（白名单内的快捷操作）。
        本命令只读，不执行任何系统修改；用户点击快捷操作后启动的是
        Windows 自带工具或设置页，具体动作仍由用户在系统界面里确认。
        建议的 ActionId 形如 cleanmgr / storagesense（系统工具），
        或 tab:cleanup / tab:quarantine（切换到本工具的对应标签页）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Health,
        [object[]]$Candidate = @(),
        [string]$QuarantineRoot
    )

    $suggestions = New-Object System.Collections.ArrayList
    $severityRank = @{ high = 0; warn = 1; info = 2 }

    function Add-Suggestion {
        param([string]$Id, [string]$Severity, [string]$Title, [string]$Detail, [string]$ActionId, [double]$ImpactMB = 0)
        [void]$suggestions.Add([pscustomobject]@{
            Id       = $Id
            Severity = $Severity
            Title    = $Title
            Detail   = $Detail
            ActionId = $ActionId
            ImpactMB = $ImpactMB
        })
    }

    # 1) 系统盘剩余空间
    $sysDrives = @($Health.Drives | Where-Object { $_.IsSystem })
    foreach ($d in $sysDrives) {
        if ($d.FreePercent -lt 5) {
            Add-Suggestion 'disk-critical-system' 'high' `
                ('系统盘即将写满（剩余 {0:N1}%，约 {1:N0} GB）' -f $d.FreePercent, $d.FreeGB) `
                '系统盘低于 5% 会影响 Windows 更新、虚拟内存与程序写入。建议优先清理隔离区到期条目与 P2 缓存，再用磁盘清理处理系统临时文件。' `
                'tab:cleanup' $d.FreeGB * 1024
        }
        elseif ($d.FreePercent -lt 10) {
            Add-Suggestion 'disk-low-system' 'warn' `
                ('系统盘空间偏紧（剩余 {0:N1}%，约 {1:N0} GB）' -f $d.FreePercent, $d.FreeGB) `
                '建议清理缓存与临时文件，保持系统盘剩余空间在 10% 以上。' `
                'cleanmgr' $d.FreeGB * 1024
        }
    }

    # 2) 非系统盘空间告警
    foreach ($d in @($Health.Drives | Where-Object { -not $_.IsSystem })) {
        if ($d.FreePercent -lt 5) {
            Add-Suggestion ('disk-critical-{0}' -f $d.Letter.TrimEnd(':')) 'warn' `
                ('{0} 盘即将写满（剩余 {1:N1}%）' -f $d.Letter.TrimEnd(':'), $d.FreePercent) `
                '该盘空间不足可能导致存储到该盘的程序异常。建议先移走或隔离大文件。' `
                'storage'
        }
    }

    # 3) 可安全隔离的缓存
    $p2 = @($Candidate | Where-Object { $_.Tier -eq 'P2' })
    $p2Sum = ($p2 | Measure-Object -Property SizeMB -Sum).Sum
    if ($p2.Count -gt 0 -and $p2Sum -ge 100) {
        Add-Suggestion 'p2-cache-available' 'info' `
            ('发现 {0} 项可安全隔离的缓存，约 {1:N0} MB' -f $p2.Count, $p2Sum) `
            '这些目录按规则判定为纯缓存/日志，隔离前会做内容抽查；移入隔离区后 7 天内可随时原位还原。' `
            'tab:cleanup' ([double]$p2Sum)
    }

    # 4) 隔离区到期条目
    if ($Health.Quarantine -and $Health.Quarantine.ExpiredCount -gt 0) {
        Add-Suggestion 'quarantine-expired' 'warn' `
            ('隔离区有 {0} 项已超过保留期（共 {1:N0} MB）' -f $Health.Quarantine.ExpiredCount, $Health.Quarantine.TotalMB) `
            '这些条目已度过 7 天保留期且未被还原，继续占用空间。可在隔离区标签页逐条核对后永久删除。' `
            'tab:quarantine' ([double]$Health.Quarantine.TotalMB)
    }

    # 5) 启动项
    $startupCount = @($Health.StartupItems).Count
    if ($startupCount -gt 15) {
        Add-Suggestion 'startup-heavy' 'info' `
            "开机自启动项较多（$startupCount 个）" `
            '过多的启动项会拖慢开机速度并常驻内存。建议只保留必要项，其余在启动应用设置里禁用。' `
            'startupapps'
    }

    # 6) 内存
    if ($Health.MemoryTotalMB -and $Health.MemoryTotalMB -lt 8192) {
        Add-Suggestion 'memory-small' 'info' `
            ('物理内存 {0:N0} GB，多开大型应用时容易吃紧' -f ($Health.MemoryTotalMB / 1024)) `
            '建议减少常驻后台程序；若经常爆内存，可考虑增加页面文件或升级内存。' `
            'taskmgr'
    }
    if ($Health.TopMemoryProcesses -and $Health.TopMemoryProcesses.Count -gt 0 -and $Health.MemoryTotalMB) {
        $top = $Health.TopMemoryProcesses[0]
        $ratio = [double]$top.MemoryMB / [double]$Health.MemoryTotalMB
        if ($ratio -gt 0.25) {
            Add-Suggestion 'process-heavy' 'info' `
                ('进程 {0} 占用 {1:N0} MB（约 {2:N0}% 内存）' -f $top.Name, $top.MemoryMB, ($ratio * 100)) `
                '单个进程占内存超过四分之一，若不符合预期可在任务管理器中查看其行为。' `
                'taskmgr' ([double]$top.MemoryMB)
        }
    }

    # 7) 长时间未重启
    if ($Health.UptimeHours -and $Health.UptimeHours -gt 168) {
        Add-Suggestion 'uptime-long' 'info' `
            ('系统已连续运行 {0:N0} 天' -f ($Health.UptimeHours / 24)) `
            '长时间不重启可能累积内存碎片与未生效的系统更新。建议选个空闲时间重启一次。' `
            $null
    }

    # 8) 存储介质
    $ssdDisks = @($Health.Disks | Where-Object { $_.IsSsd -eq $true })
    $hddDisks = @($Health.Disks | Where-Object { $_.IsSsd -eq $false })
    if ($ssdDisks.Count -gt 0) {
        Add-Suggestion 'ssd-storagesense' 'info' '检测到 SSD，建议开启存储感知' `
            '存储感知会按计划自动清理临时文件与回收站，SSD 无需担心碎片问题。' `
            'storagesense'
    }
    elseif ($hddDisks.Count -gt 0) {
        Add-Suggestion 'hdd-keep-clean' 'info' '机械硬盘：保持定期清理' `
            '机械硬盘对碎片敏感，删除大文件后建议定期用磁盘清理；不要对正在运行的盘做深度整理。' `
            'cleanmgr'
    }

    # 9) 电源计划
    if ($Health.PowerPlan -and ($Health.PowerPlan -match '节能|Power Saver')) {
        Add-Suggestion 'powersaver-active' 'info' '当前为节能电源计划' `
            '节能计划会限制 CPU 频率，编译与大型应用会变慢。对性能有要求时可切换到平衡或高性能。' `
            'powercfg'
    }

    # 10) 系统文件深度清理指引（常驻）
    Add-Suggestion 'system-files-hint' 'info' 'WinSxS 与更新缓存交给系统工具' `
        '系统组件清理（DISM）与 Windows 更新缓存不在本工具范围内——本工具不碰系统组件。请在磁盘清理里勾选"Windows 更新清理"，或用管理员终端运行 DISM。' `
        'cleanmgr'

    @($suggestions | Sort-Object {
            if ($severityRank.ContainsKey($_.Severity)) { $severityRank[$_.Severity] } else { 9 }
        })
}
