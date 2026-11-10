function Get-DsSystemHealth {
    <#
    .SYNOPSIS
        采集本机主要健康指标（全程只读，不做任何修改）。
    .DESCRIPTION
        为优化建议与界面概览提供数据：各盘剩余空间、内存、CPU、SSD 检测、
        电源计划、启动项、运行时长、内存占用前五的进程、隔离区统计。
        每一段独立容错：单项采集失败只影响对应字段（为 null），不中断整体。
    #>
    [CmdletBinding()]
    param(
        [string]$QuarantineRoot,
        [ValidateRange(1, 365)]
        [int]$DefaultRetentionDays = 7
    )

    $result = [ordered]@{
        GeneratedAt  = (Get-Date).ToString('s')
        ComputerName = $env:COMPUTERNAME
    }

    # 操作系统、内存、运行时长
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $result['Os'] = [string]$os.Caption
        $result['MemoryTotalMB'] = [math]::Round([double]$os.TotalVisibleMemorySize / 1KB, 0)
        $result['MemoryFreeMB'] = [math]::Round([double]$os.FreePhysicalMemory / 1KB, 0)
        if ($os.LastBootUpTime) {
            try { $result['UptimeHours'] = [math]::Round(((Get-Date) - [datetime]$os.LastBootUpTime).TotalHours, 1) }
            catch { }
        }
    }
    catch { }

    # CPU
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1)
        if ($cpu.Count -gt 0) {
            $result['CpuName'] = [string]$cpu[0].Name
            $result['CpuLoad'] = [int]$cpu[0].LoadPercentage
        }
    }
    catch { }

    # 逻辑盘
    $drives = @()
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $total = [long]$d.Size
        if ($total -gt 0) {
            $drives += [pscustomobject]@{
                Letter        = [string]$d.DeviceID
                TotalGB       = [math]::Round([double]$total / 1GB, 1)
                FreeGB        = [math]::Round([double][long]$d.FreeSpace / 1GB, 1)
                FreePercent   = [math]::Round([double][long]$d.FreeSpace / [double]$total * 100, 1)
                IsSystem      = ([string]$d.DeviceID -eq $env:SystemDrive)
            }
        }
    }
    $result['Drives'] = $drives

    # 物理盘与 SSD 检测（Win10+ 用 Storage 命名空间，失败时退回 Win32_DiskDrive，介质类型置空）
    # PS 5.1 下 MediaType 可能是枚举整数（0 未指定 / 1 HDD / 2 SSD / 3 SCM / 4 未知），两种形态都兼容。
    $disks = @()
    try {
        $phys = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction Stop)
        foreach ($p in $phys) {
            $media = [string]$p.MediaType
            $isSsd = $null
            if ($media -eq 'SSD' -or $media -eq '2') { $isSsd = $true }
            elseif ($media -eq 'HDD' -or $media -eq '1') { $isSsd = $false }
            $disks += [pscustomobject]@{
                Name   = if ($p.FriendlyName) { [string]$p.FriendlyName } else { ('Disk ' + $p.DeviceNumber) }
                SizeGB = [math]::Round([double][long]$p.Size / 1GB, 0)
                IsSsd  = $isSsd
            }
        }
    }
    catch { }
    if ($disks.Count -eq 0) {
        foreach ($p in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
            $disks += [pscustomobject]@{
                Name   = [string]$p.Model
                SizeGB = [math]::Round([double][long]$p.Size / 1GB, 0)
                IsSsd  = $null
            }
        }
    }
    $result['Disks'] = $disks

    # 当前电源计划：多路探测（原生 API → powercfg CLI），名称解析（WMI → CLI → 内置 GUID 表）。
    # 精简虚拟机可能全部失败，此时留空而不是报错。
    $activeGuid = $null
    try {
        if (-not ('DriveSift.Power' -as [type])) {
            Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DriveSift
{
    public static class Power
    {
        [DllImport("powrprof.dll", SetLastError = true)]
        private static extern int GetActivePowerScheme(ref Guid activePolicy);

        public static string GetActiveScheme()
        {
            Guid g = Guid.Empty;
            int hr = GetActivePowerScheme(ref g);
            return hr == 0 ? g.ToString().ToUpperInvariant() : null;
        }
    }
}
'@
        }
        $activeGuid = [DriveSift.Power]::GetActiveScheme()
    }
    catch { $activeGuid = $null }

    if (-not $activeGuid) {
        try {
            $line = & powercfg.exe /activescheme 2>$null | Select-Object -First 1
            if ($line -and ([string]$line -match '\{([0-9a-fA-F-]+)\}')) { $activeGuid = $Matches[1].ToUpperInvariant() }
        }
        catch { }
    }

    if ($activeGuid) {
        $planName = $null
        try {
            foreach ($p in @(Get-CimInstance Win32_PowerPlan -ErrorAction Stop)) {
                if ([string]$p.InstanceName -eq $activeGuid) { $planName = [string]$p.ElementName; break }
            }
        }
        catch { }
        if (-not $planName) {
            foreach ($line in @(& powercfg.exe /list 2>$null)) {
                $text = [string]$line
                if ($text -match [regex]::Escape($activeGuid)) {
                    # 行形如 "电源方案 GUID: {xxx} (平衡) *"，名称在最后一对括号内
                    if ($text -match '\(([^()]+)\)\s*\*?\s*$') { $planName = $Matches[1] }
                    break
                }
            }
        }
        if (-not $planName) {
            $builtin = @{
                '381B4222-BBB9-4E4A-B618-0C293D9BCA9B' = '节能'
                '381B4222-6693-43EE-A700-DD605D2D2A1B' = '平衡'
                '8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C' = '高性能'
                'E9A42B02-D5DF-448D-AA00-03F14749EB61' = 'Windows 7'
            }
            if ($builtin.ContainsKey($activeGuid)) { $planName = $builtin[$activeGuid] }
            else { $planName = '自定义计划' }
        }
        $result['PowerPlan'] = $planName
        $result['PowerPlanGuid'] = $activeGuid
    }

    # 启动项：注册表 Run 键 + 开始菜单启动文件夹
    $startup = New-Object System.Collections.ArrayList
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($hive in $runKeys) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        $props = Get-ItemProperty -LiteralPath $hive -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($name in @($props.PSObject.Properties.Name)) {
            if ($name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'DisplayName')) { continue }
            [void]$startup.Add([pscustomobject]@{
                Name    = [string]$name
                Command = [string]$props.$name
                Source  = $hive
            })
        }
    }
    $startupFolders = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    )
    foreach ($folder in $startupFolders) {
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            [void]$startup.Add([pscustomobject]@{
                Name    = [string]$item.Name
                Command = [string]$item.FullName
                Source  = 'StartupFolder'
            })
        }
    }
    $result['StartupItems'] = @($startup)

    # 内存占用前五的进程
    try {
        $top = @(Get-Process -ErrorAction SilentlyContinue |
            Sort-Object WorkingSet64 -Descending |
            Select-Object -First 5 |
            ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; MemoryMB = [math]::Round([double]$_.WorkingSet64 / 1MB, 0) }
            })
        $result['TopMemoryProcesses'] = $top
    }
    catch { }

    # 隔离区统计（可选）
    $quarantine = $null
    if ($QuarantineRoot -and (Test-Path -LiteralPath $QuarantineRoot)) {
        try {
            $entries = @(Get-DsQuarantine -QuarantineRoot $QuarantineRoot -DefaultRetentionDays $DefaultRetentionDays)
            $sizeMB = ($entries | Measure-Object -Property SizeMB -Sum).Sum
            $quarantine = [pscustomobject]@{
                EntryCount   = $entries.Count
                TotalMB      = [math]::Round([double]$sizeMB, 1)
                ExpiredCount = @($entries | Where-Object { $_.Expired }).Count
            }
        }
        catch { }
    }
    $result['Quarantine'] = $quarantine

    [pscustomobject]$result
}
