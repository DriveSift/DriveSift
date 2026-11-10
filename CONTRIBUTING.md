# Contributing to DriveSift | 参与贡献

Thanks for your interest in contributing! This document covers the ground
rules. 中文说明见下半部分。

## Ground rules (English)

### 1. Safety first — this tool deletes files

Every change that touches the deletion path must preserve these invariants:

- **P0 is never moved.** No rule, flag, or candidate shape may bypass the
  built-in protected-path list.
- **Nothing is permanently deleted without passing through the quarantine.**
  Every purge must verify `EntryId` and size drift first.
- **Every state-changing action is audit-logged** (`audit.jsonl`).
- Gate behavior must stay: P0 rejected, P1 requires explicit
  `-IncludePending`, P2 allowed.

If a change weakens any of these, it will be rejected — no matter how
convenient it is.

### 2. Technical constraints

- Target is **Windows PowerShell 5.1** with **no third-party dependencies**
  (no NuGet, no bundled binaries). .NET Framework 4.x APIs only.
- Source files must be **UTF-8 with BOM** — PS 5.1 reads BOM-less files as
  ANSI and non-ASCII strings break.
- Known PS 5.1 pitfalls to avoid: a hashtable literal keyed `keys` is parsed
  as the `.Keys` property (use `secrets`); the `-replace` replacement
  operand does not treat backslashes as escapes; `Join-String` does not
  exist; `$var:` inside strings is parsed as a drive-qualified name (use
  `${var}`).
- Rules (`rules/rules.json`) are pure data — never add executable logic.

### 3. Tests

The suite runs on both Pester 3.4 (bundled with PS 5.1) and Pester 5+:

```powershell
Invoke-Pester .\tests
```

- Do not use top-level `BeforeAll`, `-Show`, `BeIn`, `BeContainedBy`, or
  `BeGreater` (see existing tests for compatible helpers such as
  `Assert-Contained`).
- New commands need new tests; changes to the quarantine lifecycle need
  both a happy path and a tamper/drift test.
- The GUI has a headless self-check: `.\ui\DriveSift.Gui.ps1 -ValidateOnly`.

### 4. Pull requests

1. Fork, create a feature branch.
2. Keep commits focused; write messages that explain *why*.
3. Run the full Pester suite and `-ValidateOnly` before submitting.
4. Describe the risk surface of your change in the PR description —
   especially anything touching the deletion path.
5. Docs: user-facing behavior changes need matching updates in
   `README.md` / `README.en.md` and `docs/USAGE.md` / `docs/USAGE.en.md`,
   plus a `CHANGELOG.md` entry under `Unreleased` (bilingual).

### 5. Reporting bugs / security issues

- Security vulnerabilities: follow [SECURITY.md](SECURITY.md) — private
  disclosure, never a public issue.
- Regular bugs: open an issue with PowerShell version, exact repro steps,
  and `-ValidateOnly` output where relevant.

---

## 参与指南（中文）

### 1. 安全优先——这个工具会删除文件

任何涉及删除路径的改动必须保持以下不变量：

- **P0 永远不被移动**：任何规则、参数、候选形态都不能绕过内置保护路径清单。
- **任何文件不经隔离区不得永久删除**：所有清理动作先校验 `EntryId` 与尺寸漂移。
- **所有状态变更操作写入审计日志**（`audit.jsonl`）。
- 闸门语义不变：P0 拒绝；P1 需显式 `-IncludePending`；P2 直接允许。

削弱以上任何一条的改动会被拒绝，与它带来多少便利无关。

### 2. 技术约束

- 目标环境是 **Windows PowerShell 5.1**，**零第三方依赖**（不引 NuGet、不打包二进制），只用 .NET Framework 4.x API。
- 源文件必须保存为 **UTF-8 with BOM**——PS 5.1 会把无 BOM 文件按 ANSI 解析，中文字符串会损坏。
- 已知 PS 5.1 陷阱：哈希表字面量以 `keys` 为键会被解析为 `.Keys` 属性（改用 `secrets`）；`-replace` 的替换串不把反斜杠当转义；`Join-String` 不存在；字符串里的 `$var:` 会被当成驱动器限定名（用 `${var}`）。
- 规则文件（`rules/rules.json`）是纯数据，不允许加入可执行逻辑。

### 3. 测试

测试套件同时兼容 Pester 3.4（PS 5.1 自带）与 Pester 5+：

```powershell
Invoke-Pester .\tests
```

- 不要用顶层 `BeforeAll`、`-Show`、`BeIn`、`BeContainedBy`、`BeGreater`
  （兼容写法参考现有测试里的 `Assert-Contained` 等助手）。
- 新命令配新测试；隔离区生命周期的改动需要正常路径与篡改 / 漂移两类测试。
- GUI 提供无界面自检：`.\ui\DriveSift.Gui.ps1 -ValidateOnly`。

### 4. 提交 PR

1. Fork 后建特性分支，保持提交聚焦，提交信息说清“为什么”。
2. 提交前跑全量 Pester 与 `-ValidateOnly`。
3. PR 描述里说明改动的风险面，尤其涉及删除路径时。
4. 行为变化需同步更新 `README.md` / `README.en.md`、
   `docs/USAGE.md` / `docs/USAGE.en.md`，并在 `CHANGELOG.md` 的
   `Unreleased` 下加双语条目。

### 5. 反馈问题

- 安全漏洞走 [SECURITY.md](SECURITY.md) 的私密渠道，不要开公开 Issue。
- 普通问题开 Issue，附 PowerShell 版本、复现步骤与相关 `-ValidateOnly` 输出。
