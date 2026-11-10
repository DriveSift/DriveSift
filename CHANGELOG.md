# Changelog

本项目的所有显著变更都会记录在本文件。
格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循语义化版本（SemVer）。

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
SemVer.

## [Unreleased]

### Changed 变更

- GUI 不再启动即自动扫描：扫描范围改为路径选择弹窗（未选择过默认 `C:\`），由「开始扫描」手动触发。/ GUI no longer auto-scans on launch: the scope is picked via a folder dialog (default `C:\`), triggered manually by "Start Scan".
- 候选列表与隔离区列表支持 `Ctrl+A` 全选；隔离区按钮实时显示选中数。/ `Ctrl+A` select-all in candidate and quarantine tables; quarantine buttons show live selection counts.
- 文档补齐：新增中英双语使用手册（docs/）、CHANGELOG、CONTRIBUTING、SECURITY。/ Docs: bilingual user guide (docs/), changelog, contributing guide, security policy.

### Fixed 修复

- 修复路径选择弹窗报错：PS 5.1 的 `FolderBrowserDialog` 没有 `UseDescriptionForTitle` 属性，赋值即抛异常。/ Fixed the folder-picker crash: `FolderBrowserDialog` on PS 5.1 has no `UseDescriptionForTitle` property.

## [0.2.0] - 2026-11-07

### Added 新增

- 内容相关性抽样检查：P2 候选混入可疑内容（文档、图片、音视频、源码、压缩包、数据库、密钥）自动降为 P1；规则集升级 v2，新增 `allowContent` 白名单字段。/ Content relevance spot-check: P2 candidates containing suspicious categories are auto-downgraded to P1; rules v2 with `allowContent` whitelist.
- 可恢复软删除隔离区：`EntryId`（SHA256）、7 天保留期（1–365 可配）、移动后校验失败自动回滚、永久删除前防篡改与尺寸漂移检测、独立 `audit.jsonl` 审计日志。/ Restorable soft-delete quarantine: EntryId, configurable retention, move verification with rollback, tamper & drift checks before purge, dedicated audit log.
- 新命令 `Get-DsQuarantine` / `Remove-DsQuarantine` / `Restore-DsQuarantine`。/ New commands for listing, purging and restoring quarantine entries.
- 系统体检 `Get-DsSystemHealth`（磁盘、SSD、内存、进程、启动项、电源计划）、优化建议 `Get-DsOptimizationSuggestion`、16 项白名单快捷操作 `Start-DsQuickAction` / `Get-DsQuickActionCatalog`。/ System health, optimization suggestions, and a 16-item whitelist of quick actions launching built-in Windows tools.
- 可选定时自动清理 `Register-DsAutoPurge` / `Get-DsAutoPurgeStatus`（默认关闭）。/ Optional scheduled auto-purge (off by default).
- GUI 重写为三标签页：清理 / 优化建议 / 隔离区；永久删除双重确认；`-ValidateOnly` 无界面自检。/ GUI rewritten with three tabs; double confirmation for permanent delete; headless `-ValidateOnly` self-check.

### Fixed 修复

- 修复 PowerShell 5.1 下哈希表字面量以 `keys` 为键被解析为属性访问导致映射塌缩的问题（改用 `secrets`）。/ Fixed a PS 5.1 parsing trap where a hashtable literal keyed `keys` was evaluated as the `.Keys` property (renamed to `secrets`).

## [0.1.0] - 2026-11-07

### Added 新增

- 首个版本：Windows 磁盘审计模块（PowerShell 5.1，无第三方依赖）。/ Initial release: Windows disk audit module on PowerShell 5.1, zero third-party dependencies.
- 真实占用清点（压缩 / 稀疏 / 簇对齐感知的 C# 原生访问层）、项目与工具链归属索引、P0/P1/P2 规则分级、内容哈希查重（识别硬链接）、自包含 HTML 报告、基础 WPF 界面。/ Real-usage inventory via a native C# layer, ownership index, P0/P1/P2 rule tiers, content-hash duplicate detection with hardlink awareness, self-contained HTML report, basic WPF UI.

[Unreleased]: https://atomgit.com/DriveSift/DriveSift/compare/v0.2.0...HEAD
[0.2.0]: https://atomgit.com/DriveSift/DriveSift/compare/v0.1.0...v0.2.0
[0.1.0]: https://atomgit.com/DriveSift/DriveSift/releases/tag/v0.1.0
