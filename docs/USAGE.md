# DriveSift 使用手册

English version: [USAGE.en.md](USAGE.en.md)

本手册面向日常使用者，覆盖图形界面与命令行两种方式的完整操作流程。
概念与安全设计请先阅读仓库根目录的 [README](../README.md)。

## 目录

1. [系统要求](#系统要求)
2. [获取与启动](#获取与启动)
3. [图形界面操作流程](#图形界面操作流程)
4. [隔离区管理](#隔离区管理)
5. [定时自动清理](#定时自动清理)
6. [命令行手册](#命令行手册)
7. [自定义规则](#自定义规则)
8. [数据写在哪里](#数据写在哪里)
9. [常见问题](#常见问题)
10. [故障排查](#故障排查)

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11（Windows Server 未测试，理论可用） |
| PowerShell | 5.1（系统自带，无需安装任何模块或 NuGet 包） |
| .NET | .NET Framework 4.x（系统自带） |
| 磁盘 | 隔离区建议放在与待清理文件相同的盘上 |
| 权限 | 普通用户即可；读取部分系统目录时缺权限的条目会被跳过 |

## 获取与启动

```powershell
git clone https://atomgit.com/DriveSift/DriveSift.git DriveSift
```

**启动图形界面（推荐）**：双击仓库根目录的 `Start-Gui.cmd`。
也可以在 PowerShell 中运行：

```powershell
.\DriveSift\ui\DriveSift.Gui.ps1
```

> 注意：`DriveSift.psd1` 是模块清单（数据文件），双击它不会启动软件；
> 双击 `.ps1` / `.psd1` 默认只会用编辑器打开文件内容，这是 Windows 的正常行为。

**启动命令行**：在 PowerShell 中导入模块：

```powershell
Import-Module D:\path\to\DriveSift\DriveSift.psd1
```

想让它随会话自动加载，把仓库的**父目录**加入 `$env:PSModulePath`，
或把仓库放到 `Documents\WindowsPowerShell\Modules\` 下。

## 图形界面操作流程

### 1. 选择扫描范围并开始

- 软件启动后**不会自动扫描**。顶部「扫描范围」框显示当前范围，点击它或旁边的
  「选择路径」按钮会弹出文件夹选择窗口；从未选择过时默认为 `C:\`。
- 选好后点击顶部的「开始扫描」才开始审计。扫描在后台线程运行，逐条规则推进进度条，
  界面不会假死；期间可以切换标签页查看。
- 上一次的扫描结果缓存在本地，重新打开软件时直接显示，等你手动重新扫描。

### 2. 审核候选（清理页）

- 顶部 KPI 显示系统盘剩余空间、P2 / P1 待处理量与重复文件可释放量。
- 「全部 / P2 / P1 / P0」按钮按风险级别筛选候选表：
  - **P2**：纯缓存、日志、可重建内容，可放心隔离；
  - **P1**：需要逐条确认（应用本体、含个人内容的目录、旧版本运行时等）；
  - **P0**：永不处理，仅展示供核对。
- 点击任意一行，右侧详情展示：真实占用、归属判断（属于哪个项目 / 工具链）、
  级别理由、**内容抽查结果**（例如"缓存目录中发现 3 个文档类文件，已降级 P1"）与备注。
- 搜索框支持按名称实时过滤。

### 3. 隔离选中

- 在候选表中用 Ctrl / Shift 多选（`Ctrl+A` 全选当前显示行），
  「隔离选中（N）」按钮实时显示选中数并统计大小。
- 点击后弹出确认对话框：明确列出**不会删除任何文件**、保留期天数与还原方式。
- 隔离是**同盘改名**，瞬间完成；跨盘会提前警告（跨盘是复制，速度取决于数据量）。
- P0 候选永远不会被移走；P1 在 GUI 中会再次向你确认。

### 4. 查看与还原（隔离区页）

- 列表逐条显示：条目名、级别、大小、移入时间、**剩余保留天数**、原路径。
- 选中一条或多条（同样支持 `Ctrl+A`），点击「还原选中（N）」即可**原位还原**：
  文件回到原来的路径，清单同步回写，操作写入审计日志。
- 原路径已被占用的条目会跳过而不是覆盖。

## 隔离区管理

### 手动永久删除

- 选中条目后点击「永久删除选中（N）」，需要**两次确认**：
  第一次确认范围，第二次展示完整路径清单。
- 删除前自动校验：`EntryId` 防篡改（清单被手改过的条目会拒绝删除）与
  尺寸漂移（超过 10% 视为被改动过而跳过）。
- 被占用的文件删除失败时会保留在隔离区，便于稍后重试。
- **永久删除不可逆**，请逐条核对清单。

### 清理已到期

- 「清理已到期」按钮一次性列出所有超过保留期的条目（含完整路径清单），
  单次确认后批量永久删除。
- 到期条目不会自动消失——除非你注册了下面的定时任务。

### 打开目录

- 「打开目录」按钮直接在资源管理器中打开隔离区，可手动检查文件。
- 直接在资源管理器里删除隔离区内的文件是**允许的**，但请先在软件里刷新列表；
  手动删除不会留下审计痕迹，也不建议这样做。

## 定时自动清理

默认**关闭**。在隔离区页勾选「自动清理到期条目」，或用命令行注册：

```powershell
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -DailyAt 04:15
```

- 注册的是 Windows 任务计划程序里的任务（任务名前缀 `DriveSift`），
  每天 04:15 只清理**已到期**的条目，保留期内的一律不动。
- 查看状态：`Get-DsAutoPurgeStatus`；注销：`Register-DsAutoPurge -Unregister`。
- 已有同名任务时不会重复注册；界面勾选框与任务状态保持同步。

## 命令行手册

全部命令支持 `-WhatIf` / `-Confirm`（PowerShell 通用参数）。只读命令：
`Invoke-DsAudit`、`Get-DsInventory`、`Get-DsOwnership`、`Get-DsCandidate`、
`Find-DsDuplicate`、`Get-DsQuarantine`、`Get-DsRuleSet`、`Get-DsSystemHealth`、
`Get-DsOptimizationSuggestion`、`Get-DsQuickActionCatalog`、`Get-DsAutoPurgeStatus`。

### 审计与清点

```powershell
# 一键完整审计（只读）：归属 + 清点 + 候选 + 重复 + 体检 + 建议 + HTML 报告
Invoke-DsAudit -ProjectRoot D:\XM -DuplicatePath D:\XM -OutFile .\report.html -Open

# 分步
$own = Get-DsOwnership -ProjectRoot D:\XM        # 项目索引与运行时索引
Get-DsInventory -Path "$env:LOCALAPPDATA\npm-cache"   # 单目录真实占用
Find-DsDuplicate -Path D:\XM -MinSize 10MB            # 内容哈希找重复
```

### 候选与级别

```powershell
Get-DsCandidate -Ownership $own -Tier P2     # 只要 P2
Get-DsCandidate -Ownership $own              # 全部级别（P0 仅展示）
Get-DsCandidate -Ownership $own -Tier P1 -IncludePending   # 放行 P1
```

- 输出字段：`Tier`、`Reasons`（规则理由）、`ContentHits` / `ContentHitKinds`
  （内容抽查命中数与类别）、`Rebuild`（官方重建命令）等。
- P2 候选若内容抽查命中可疑类别（文档、密钥等）会**自动降级为 P1**。

### 隔离 / 还原 / 永久删除

```powershell
# 隔离（只移动不删除；P1 需 -IncludePending；有确认提示）
Get-DsCandidate -Ownership $own -Tier P2 |
    Move-DsToQuarantine -QuarantineRoot D:\_quarantine -RetentionDays 7

# 列出条目与到期状态
Get-DsQuarantine -QuarantineRoot D:\_quarantine

# 还原：按 EntryId 或全部
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -All

# 永久删除：到期批量 / 手动按条目（两次 -Confirm）
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -Expired
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>
```

### 体检 / 建议 / 快捷操作

```powershell
$h = Get-DsSystemHealth -QuarantineRoot D:\_quarantine   # 磁盘/SSD/内存/启动项/电源计划
Get-DsOptimizationSuggestion -Health $h
Get-DsQuickActionCatalog                                  # 16 项白名单
Start-DsQuickAction -Action cleanmgr                      # 只能启动白名单内的系统工具
```

## 自定义规则

规则在 `rules/rules.json`，纯 JSON、无代码。常用字段：

| 字段 | 说明 |
|---|---|
| `paths` | 支持环境变量（`%LOCALAPPDATA%` 等）与通配符 |
| `unit` | `path` 整目录评估；`child` 逐个子项评估（如每套 Rust 工具链） |
| `tier` | `P0` / `P1` / `P2`，P0 永不处理 |
| `guards` | `unreferenced`：仍被项目 / 默认运行时引用则降 P1；`manual`：强制 P1 |
| `allowContent` | 内容抽查白名单：该目录预期出现的内容类别，白名单内不降级 |
| `rebuild` | 官方重建命令，写入报告与详情 |

修改后执行 `Get-DsRuleSet` 确认加载无误。未知守卫不会静默放过——会把候选降为 P1 并写明原因。

## 数据写在哪里

| 位置 | 内容 | 删除影响 |
|---|---|---|
| 你指定的隔离区目录 | 被隔离的文件 + `manifest.jsonl` + `audit.jsonl` | 删除即放弃还原能力 |
| `%LOCALAPPDATA%\DriveSift\` | 上次审计缓存、窗口配置、HTML 报告 | 仅丢缓存与报告，无用户数据 |

## 常见问题

**Q：隔离和直接删除有什么区别？**
隔离是同盘改名移动，文件数据未动，保留期内随时原位还原；删除不可逆。DriveSift 的原则是先隔离、核对后再永久删除。

**Q：为什么"缓存"目录被标成了 P1？**
内容抽查在该目录发现了文档、图片、源码、密钥等白名单之外的类别——很可能混入了个人文件，自动降级保护。可用规则的 `allowContent` 声明预期类别。

**Q：还原时提示被占用？**
原路径已被同名文件 / 正在运行的程序占用。条目会留在隔离区，关闭占用程序后重试。

**Q：跨盘隔离很慢？**
跨盘移动是复制。建议把隔离区放在与待清理文件相同的盘上（GUI 默认选系统盘之外剩余空间最大的盘，同盘操作是秒级改名）。

**Q：到期条目会自己消失吗？**
不会。到期只是"允许永久删除"，需要你手动清理或注册定时任务。

**Q：删除隔离区里的 manifest.jsonl 会怎样？**
清单丢失后软件无法还原这些条目（防篡改校验也会失败）。请勿手改或删除隔离区内的清单与审计文件。

**Q：误还原 / 误删除了怎么办？**
还原是复制回原位，不影响隔离区副本外的数据；永久删除不可逆。重要数据请依赖系统备份或快照兜底——本工具不替代备份。

## 故障排查

| 现象 | 处理 |
|---|---|
| 双击 Start-Gui.cmd 一闪而过 | 在 PowerShell 里直接运行 `.\ui\DriveSift.Gui.ps1` 看报错；常见是执行策略，用 `-ExecutionPolicy Bypass` |
| 提示"无法加载模块" | 确认路径正确、目录未被杀软隔离；运行 `Get-Item .\DriveSift.psd1` 检查文件完整 |
| 扫描很慢 | 大目录（十万级文件）首轮扫描需要时间，进度条按规则推进；之后有缓存。用 GUI 的缓存显示上次结果 |
| 部分系统目录大小为空 | 普通权限读不到，条目被跳过；需要的话以管理员运行 |
| GUI 白屏 / 崩溃 | 运行 `.\ui\DriveSift.Gui.ps1 -ValidateOnly` 做无界面自检，把输出带到 Issue |
| 定时任务没生效 | `Get-DsAutoPurgeStatus` 看注册状态；任务计划程序里搜 `DriveSift` 确认上次运行结果 |

更多问题请到仓库 Issue 区反馈，附上 `-ValidateOnly` 输出与 PowerShell 版本（`$PSVersionTable.PSVersion`）。


