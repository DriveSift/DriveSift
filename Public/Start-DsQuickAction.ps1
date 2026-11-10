function Get-DsQuickActionCatalog {
    <#
    .SYNOPSIS
        快捷操作白名单：允许用户一键启动的系统工具与设置页。
    .DESCRIPTION
        白名单之外的操作一律拒绝。所有启动都是可见窗口，不做静默执行；
        RequiresAdmin 为 true 的操作会触发 UAC 提权（用户看到 UAC 对话框并自行决定）。
        ms-settings: 前缀的项打开 Windows 设置页。
    #>
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{ Id = 'cleanmgr';         Label = '磁盘清理';       Detail = 'Windows 自带清理工具，可清临时文件与更新缓存'; FilePath = 'cleanmgr.exe';           Arguments = '';                                        RequiresAdmin = $false; Category = '磁盘' }
        [pscustomobject]@{ Id = 'storagesense';     Label = '存储感知';       Detail = '按计划自动清理临时文件与回收站';               FilePath = 'ms-settings:storagesense';     Arguments = '';                                        RequiresAdmin = $false; Category = '磁盘' }
        [pscustomobject]@{ Id = 'storage';          Label = '存储设置';       Detail = '查看各应用与文件的空间占用';                   FilePath = 'ms-settings:storages';         Arguments = '';                                        RequiresAdmin = $false; Category = '磁盘' }
        [pscustomobject]@{ Id = 'appwiz';           Label = '程序和功能';     Detail = '卸载不用的程序';                               FilePath = 'appwiz.cpl';               Arguments = '';                                        RequiresAdmin = $false; Category = '磁盘' }
        [pscustomobject]@{ Id = 'startupapps';      Label = '启动应用';       Detail = '管理开机自启动程序';                           FilePath = 'ms-settings:startupapps';      Arguments = '';                                        RequiresAdmin = $false; Category = '性能' }
        [pscustomobject]@{ Id = 'backgroundapps';   Label = '后台应用';       Detail = '限制应用后台运行';                             FilePath = 'ms-settings:backgroundappsettings'; Arguments = '';                          RequiresAdmin = $false; Category = '性能' }
        [pscustomobject]@{ Id = 'taskmgr';          Label = '任务管理器';     Detail = '查看进程占用，结束卡顿程序';                   FilePath = 'taskmgr.exe';              Arguments = '';                                        RequiresAdmin = $false; Category = '性能' }
        [pscustomobject]@{ Id = 'powercfg';         Label = '电源选项';       Detail = '切换电源计划';                                 FilePath = 'powercfg.cpl';             Arguments = '';                                        RequiresAdmin = $false; Category = '性能' }
        [pscustomobject]@{ Id = 'msinfo32';         Label = '系统信息';       Detail = '硬件与软件摘要';                               FilePath = 'msinfo32.exe';             Arguments = '';                                        RequiresAdmin = $false; Category = '诊断' }
        [pscustomobject]@{ Id = 'eventvwr';         Label = '事件查看器';     Detail = '查看系统错误日志';                             FilePath = 'eventvwr.msc';             Arguments = '';                                        RequiresAdmin = $false; Category = '诊断' }
        [pscustomobject]@{ Id = 'devmgmt';          Label = '设备管理器';     Detail = '检查驱动状态';                                 FilePath = 'devmgmt.msc';              Arguments = '';                                        RequiresAdmin = $false; Category = '诊断' }
        [pscustomobject]@{ Id = 'services';         Label = '服务';           Detail = '管理系统服务';                                 FilePath = 'services.msc';             Arguments = '';                                        RequiresAdmin = $false; Category = '诊断' }
        [pscustomobject]@{ Id = 'flushdns';         Label = '刷新 DNS 缓存';  Detail = 'ipconfig /flushdns（网络排障常用）';           FilePath = 'cmd.exe';                  Arguments = '/c ipconfig /flushdns';                       RequiresAdmin = $false; Category = '网络' }
        [pscustomobject]@{ Id = 'sfc';              Label = '系统文件检查';   Detail = 'sfc /scannow，校验并修复系统文件（需管理员）'; FilePath = 'cmd.exe';                  Arguments = '/c sfc /scannow';                             RequiresAdmin = $true;  Category = '修复' }
        [pscustomobject]@{ Id = 'dism-cleanup';     Label = 'DISM 组件清理';  Detail = '清理 WinSxS 组件存储，耗时较长（需管理员）';   FilePath = 'cmd.exe';                  Arguments = '/c dism /Online /Cleanup-Image /StartComponentCleanup'; RequiresAdmin = $true; Category = '修复' }
        [pscustomobject]@{ Id = 'windowsupdate';    Label = 'Windows 更新';   Detail = '检查并安装系统更新';                           FilePath = 'ms-settings:windowsupdate';    Arguments = '';                                        RequiresAdmin = $false; Category = '系统' }
    )
}

function Start-DsQuickAction {
    <#
    .SYNOPSIS
        启动白名单内的快捷操作。
    .DESCRIPTION
        只允许启动 Get-DsQuickActionCatalog 中登记的操作，未知 Id 直接拒绝。
        需要管理员的操作通过 UAC 提权；所有窗口可见，不做静默执行。
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$Action
    )

    $item = @(Get-DsQuickActionCatalog | Where-Object { $_.Id -eq $Action }) | Select-Object -First 1
    if (-not $item) {
        throw "未知快捷操作: $Action（白名单之外的操作一律拒绝）"
    }

    if (-not $PSCmdlet.ShouldProcess($item.Label, '启动系统工具')) {
        return
    }

    try {
        if ($item.FilePath -like 'ms-settings:*') {
            Start-Process -FilePath $item.FilePath
        }
        elseif ($item.RequiresAdmin) {
            Start-Process -FilePath $item.FilePath -ArgumentList $item.Arguments -Verb 'RunAs'
        }
        else {
            Start-Process -FilePath $item.FilePath -ArgumentList $item.Arguments
        }
        [pscustomobject]@{
            Action        = $item.Id
            Label         = $item.Label
            Launched      = $true
            RequiresAdmin = [bool]$item.RequiresAdmin
            Error         = ''
        }
    }
    catch {
        # UAC 被拒绝时也会走到这里，如实报告即可
        [pscustomobject]@{
            Action        = $item.Id
            Label         = $item.Label
            Launched      = $false
            RequiresAdmin = [bool]$item.RequiresAdmin
            Error         = $_.Exception.Message
        }
    }
}
