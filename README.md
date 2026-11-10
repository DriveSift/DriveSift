# DriveSift

Windows 磁盘审计工具：**先证明归属，再决定删除**。

它不是又一个"一键清理"。它回答四个问题：这个目录是什么、里面实际装了什么、它属于哪个项目或工具链、删掉之后怎么回来。所有操作默认只读；真要清理时，它把文件**移进隔离区**（7 天保留期，期内随时原位还原），**从不一次性永久删除**——永久删除只在保留期结束后放行，且随时可以手动执行、每一步都留痕。

```
C: 已用 116 GB / 剩余 48 GB
├─ npm-cache            3.5 GB   P2  纯缓存，npm 自动重建
├─ .rustup/toolchains   5.2 GB   P2  4 套工具链，其中 3 套无引用
├─ Doubao               6.5 GB   P1  应用本体，需确认旧版本
└─ Trae/workspaceStorage   ?     P1  含会话历史，删除不可恢复
```

## 它做什么 / 不做什么

| 做 | 不做 |
|---|---|
| 按磁盘实际占用统计（含压缩、稀疏、簇对齐） | 不一次性永久删除任何文件 |
| 内容相关性抽样检查："缓存"里混入个人文件自动降级 P1 | 不猜"最近没用就可以删" |
| 建立"目录 → 项目 / 工具链"归属关系 | 不修改 ACL、不接管所有权 |
| 按内容哈希找完全重复的文件，识别硬链接 | 不处理系统组件（交给 DISM / 磁盘清理） |
| 按规则给出 P0 / P1 / P2 风险级别和理由 | 不联网、不上传任何数据 |
| 移入隔离区（同盘改名，瞬间完成）+ 7 天保留 + 还原 / 到期删除 | |
| 系统体检、优化建议、启动系统自带工具 | |
| 可选定时任务自动清理到期项（默认关闭，手动注册） | |

## 安装

无需安装依赖，PowerShell 5.1 即可。

```powershell
# 主仓库（AtomGit）
git clone https://atomgit.com/DriveSift/DriveSift.git DriveSift
# 镜像（GitHub）
git clone https://github.com/DriveSift/DriveSift.git DriveSift

Import-Module .\DriveSift\DriveSift.psd1
```

English documentation: [README.en.md](README.en.md) · [User Guide 用户手册](docs/USAGE.md) ([EN](docs/USAGE.en.md)) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

想让它随会话自动加载，把仓库路径加进 `$env:PSModulePath`。

## 快速开始

```powershell
# 只读审计：归属 + 清点 + 候选（含内容检查）+ 重复 + 报告
Invoke-DsAudit -ProjectRoot C:\Projects -DuplicatePath C:\Projects -OutFile .\report.html -Open

# 分步执行
$own = Get-DsOwnership -ProjectRoot C:\Projects
Get-DsInventory -Path "$env:LOCALAPPDATA\npm-cache"
Get-DsCandidate -Ownership $own -Tier P2    # 混入个人文件的候选会自动降为 P1 并给出内容理由
Find-DsDuplicate -Path C:\Projects -MinSize 10MB

# 清理：先隔离（同盘改名，瞬间完成，默认 7 天保留期）
Get-DsCandidate -Ownership $own -Tier P2 |
    Move-DsToQuarantine -QuarantineRoot D:\_quarantine -RetentionDays 7

# 保留期内核对：列出条目与剩余天数，还原
Get-DsQuarantine -QuarantineRoot D:\_quarantine
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -All

# 到期后（或随时手动）：永久删除（校验尺寸漂移，留审计痕迹）
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -Expired
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>

# 电脑优化：体检 → 建议 → 快捷操作（只启动 Windows 自带工具）
$h = Get-DsSystemHealth -QuarantineRoot D:\_quarantine
Get-DsOptimizationSuggestion -Health $h -Candidate (Get-DsCandidate -Tier P2)
Start-DsQuickAction -Action cleanmgr        # 白名单清单见 Get-DsQuickActionCatalog

# 可选：每天 04:15 自动清理到期项（默认关闭，需手动注册）
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -DailyAt 04:15
Get-DsAutoPurgeStatus
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -Unregister
```

## 图形界面

不想记命令就双击 `Start-Gui.cmd`，或者：

```powershell
.\DriveSift\ui\DriveSift.Gui.ps1 -ProjectRoot C:\Projects
```

> 注意：`DriveSift.psd1` 是模块清单（数据文件），双击它不会启动软件——
> 双击 `.psd1` / `.ps1` 在 Windows 上只会用编辑器打开文件内容。
> 图形界面的完整操作说明见[使用手册](docs/USAGE.md)。

三个标签页：

- **清理**：系统盘剩余与 P2/P1 待处理量、按风险级别筛选的候选表、每个候选的内容检查理由；「隔离选中」带确认对话框。
- **优化建议**：基于体检实测指标给出磁盘 / 启动项 / 内存 / 电源计划等建议，点击建议直接启动对应的系统自带工具。
- **隔离区**：逐条列出条目、剩余天数、漂移状态；过期条目可手动永久删除，需双重确认，删除前校验 EntryId 与尺寸漂移并留审计痕迹。

- 启动后不自动扫描：扫描范围通过顶部的路径选择弹窗更换（未选择过默认 `C:\`），点击「开始扫描」才开始审计。
- 审计跑在后台线程，逐条规则推进进度，界面不会假死。
- 结果缓存到 `%LOCALAPPDATA%\DriveSift\last-audit.json`，下次打开直接显示上次结果，可手动重新扫描。
- 候选列表与隔离区列表支持 Ctrl/Shift 多选、`Ctrl+A` 全选，方便整批隔离或删除（按钮实时显示选中数）。
- 隔离区默认选系统盘之外可用空间最大的那块盘，可以在界面里看到具体路径。
- `-ValidateOnly` 只做界面自检（XAML、行模型、筛选），不弹窗也不扫描。

## 命令

| 命令 | 作用 |
|---|---|
| `Invoke-DsAudit` | 一键跑完整链路，输出 HTML 报告（只读） |
| `Get-DsInventory` | 按目录汇总真实占用、文件数、最近修改 |
| `Get-DsOwnership` | 建立项目索引与运行时索引 |
| `Get-DsCandidate` | 按规则生成候选，附带级别、理由与内容检查 |
| `Find-DsDuplicate` | 按哈希找重复文件，识别硬链接 |
| `New-DsReport` | 生成自包含 HTML 报告 |
| `Move-DsToQuarantine` | 移入隔离区，写 manifest 与到期时间，审计留痕 |
| `Get-DsQuarantine` | 列出隔离区条目与保留期状态 |
| `Restore-DsQuarantine` | 原位还原条目（到期前随时可还原） |
| `Remove-DsQuarantine` | 手动 / 到期永久删除（校验尺寸漂移） |
| `Get-DsRuleSet` | 查看当前规则集 |
| `Get-DsSystemHealth` | 体检：磁盘、SSD、内存、进程、启动项、电源计划、隔离区 |
| `Get-DsOptimizationSuggestion` | 按体检数据生成优化建议 |
| `Get-DsQuickActionCatalog` | 快捷操作清单（16 项白名单） |
| `Start-DsQuickAction` | 启动白名单内的系统自带工具 / 设置页 |
| `Get-DsAutoPurgeStatus` | 查询定时任务状态 |
| `Register-DsAutoPurge` | 注册 / 注销自动清理到期项的定时任务 |

## 安全模型

判断 → 审核 → 执行，每一步可追溯、可撤销：

**判断（清理什么）**

1. **规则分级**：P0 永不处理（系统组件、凭据、源码、桌面/文档）；P2 纯缓存 / 日志 / 旧版本运行时。
2. **内容相关性检查**：对"缓存"目录抽样文件扩展名——出现文档、图片、音视频、源码、压缩包、数据库、密钥时自动降为 P1，候选理由里写明命中的类别与示例路径。规则可用 `allowContent` 白名单豁免预期类别（如 npm 缓存里的源码与压缩包）。
3. **归属索引**：`unreferenced` 守卫检查运行时是否仍被项目引用或是默认工具链；仍被引用则降为 P1。

**审核（清理前）**

4. **级别闸门**：P0 永远拒绝；P1 需显式 `-IncludePending`；GUI 对高风险操作另加确认对话框。
5. **执行前复核**：内置保护清单不可被规则或候选对象绕过；隔离区自身不允许再被移入隔离区。

**执行（怎么清理）**

6. **只移动不删除**：同盘移动是改名（瞬间完成），跨盘会提前警告（那是复制，不是改名）；移动后校验源路径消失且目标就位，校验失败自动回滚。
7. **7 天保留期**：每条记录分配 `EntryId` 与到期时间（移入时间 + 保留天数，默认 7 天、可配 1–365 天），`manifest.jsonl` 记录原路径；期内可用 `Restore-DsQuarantine` 原位还原。
8. **永久删除只有两个入口**：手动（按 EntryId 逐条）或到期后（`-Expired` / 定时任务）；删除前再校验 EntryId 与尺寸漂移（超过 10% 视为被改动过而跳过），所有操作写入 `audit.jsonl`。

## 规则

规则是纯 JSON，存放在 `rules/rules.json`，不含可执行代码，便于审计和贡献（当前 v2，共 24 条）。

```json
{
  "id": "npm-cache",
  "name": "npm 全局缓存",
  "category": "包缓存",
  "owner": "npm",
  "tier": "P2",
  "unit": "path",
  "paths": ["%LOCALAPPDATA%\\npm-cache"],
  "guards": [],
  "allowContent": ["source", "archive"],
  "rebuild": "npm cache clean --force",
  "notes": "纯缓存，不含任何项目代码；源码与压缩包是其正常成分"
}
```

- `paths` 支持环境变量与通配符；`unit: child` 表示逐个评估子项（如每套 Rust 工具链）。
- `guards`：`unreferenced` 检查是否仍被默认运行时或项目引用；`manual` 强制降级为 P1。
- `allowContent`：该目录预期会出现的内容类别；内容抽样出现白名单之外的可疑类别时降为 P1。
- 未知守卫不会被静默放过，而是把候选降级为 P1 并写明原因。

## 已知限制

- 不扫描 `WinSxS`、系统还原、页面文件等系统占用，请用存储感知 / DISM / cleanmgr。
- atime 在 Windows 上默认关闭，所以本工具**不用"最近访问时间"**判断死活，只看修改时间、引用关系、路径归属和内容抽样。
- 内容检查只读扩展名、不读文件内容，且按抽样上限截断（截断会如实标注在候选理由里）。
- 硬链接与内容寻址存储（pnpm、Ollama、Git 对象）只能按链接数近似计算释放量，不能精确到字节。
- 跨盘隔离是复制，大目录会很慢，建议隔离区放在同一块盘。
- 中文 Windows 上的部分系统目录需要管理员权限才能完整读取，缺失项会被跳过而不是报错中断。

## 数据与隐私

- 纯本地运行：不联网、无遥测、不上传任何文件内容或系统信息。
- 所有写入只发生在你指定的隔离区路径与 `%LOCALAPPDATA%\DriveSift\`（上次审计缓存、配置、HTML 报告）；删除后者不丢失任何用户数据。
- 开发者不收集、不处理用户数据，因此本项目没有（也不需要有）隐私政策——上面的表述即数据处理说明。

## 使用警告

本工具的"永久删除"不可逆：

- 隔离区条目在保留期内可随时原位还原；到期后或手动永久删除后，无法通过本工具找回。
- 永久删除前会做防篡改与尺寸漂移检查并展示完整清单，但请仍然逐条核对；重要数据请先用系统备份或快照兜底。
- 软件按"现状"提供，不作任何担保（见 LICENSE）；使用风险自负。

## 开发

```
DriveSift/
├── DriveSift.psd1 / .psm1
├── Start-Gui.cmd    双击启动图形界面
├── Private/         原生文件访问、项目与工具链索引、内容检查、隔离区基础设施
├── Public/          对外命令
├── rules/           规则集
├── ui/              WPF 界面
└── tests/           Pester 测试
```

```powershell
# 兼容 Pester 3.4（Windows PowerShell 5.1 自带）与 Pester 5+
Invoke-Pester .\DriveSift\tests
```

## 变更日志

完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

**0.2.0**（2026-11-07）

- 新增内容相关性抽样检查：P2 候选混入可疑内容自动降为 P1；规则集升级 v2，支持 `allowContent` 白名单。
- 隔离区升级为可恢复软删除：`EntryId`、7 天保留期、移动后校验回滚、尺寸漂移检测、`audit.jsonl` 审计日志。
- 新增 `Get-DsQuarantine` / `Remove-DsQuarantine`（手动或到期永久删除），`Restore-DsQuarantine` 适配新 manifest。
- 新增系统体检 `Get-DsSystemHealth`、优化建议 `Get-DsOptimizationSuggestion` 与 16 项白名单快捷操作 `Start-DsQuickAction`。
- 新增可选定时任务 `Register-DsAutoPurge`（自动清理到期项，默认关闭）。
- GUI 重写为三个标签页：清理 / 优化建议 / 隔离区，永久删除需双重确认。
- 修复 PowerShell 5.1 下哈希表字面量以 `keys` 为键时被错误求值的解析陷阱。

## 许可

MIT（全文见 LICENSE）。项目无任何第三方依赖，全部代码自研（含原生文件访问层）。
安全漏洞报告见 SECURITY.md。
