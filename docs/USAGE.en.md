# DriveSift User Guide

中文版：[USAGE.md](USAGE.md)

This guide is for day-to-day users and covers the full workflow in both the
graphical interface and the command line. For concepts and the security
design, read the root [README](../README.md) first.

## Contents

1. [System requirements](#system-requirements)
2. [Get and launch](#get-and-launch)
3. [GUI workflow](#gui-workflow)
4. [Managing the quarantine](#managing-the-quarantine)
5. [Scheduled auto-purge](#scheduled-auto-purge)
6. [Command-line reference](#command-line-reference)
7. [Custom rules](#custom-rules)
8. [Where data is written](#where-data-is-written)
9. [FAQ](#faq)
10. [Troubleshooting](#troubleshooting)

## System requirements

| Item | Requirement |
|---|---|
| OS | Windows 10 / 11 (Windows Server untested, expected to work) |
| PowerShell | 5.1 (built in — no modules or NuGet packages to install) |
| .NET | .NET Framework 4.x (built in) |
| Disk | Put the quarantine on the same disk as the files being cleaned |
| Privileges | Standard user is enough; system dirs without permission are skipped |

## Get and launch

```powershell
git clone https://atomgit.com/DriveSift/DriveSift.git DriveSift
```

**Launch the GUI (recommended)**: double-click `Start-Gui.cmd` in the repo
root, or run in PowerShell:

```powershell
.\DriveSift\ui\DriveSift.Gui.ps1
```

> Note: `DriveSift.psd1` is a module manifest (a data file). Double-clicking
> it does not launch the software — Windows just opens it with an editor.

**Command line**: import the module in PowerShell:

```powershell
Import-Module D:\path\to\DriveSift\DriveSift.psd1
```

To auto-load it every session, add the repo's **parent** directory to
`$env:PSModulePath`, or place the repo under
`Documents\WindowsPowerShell\Modules\`.

## GUI workflow

### 1. Pick a scope and scan

- The app does **not** scan on launch. The scope box at the top shows the
  current scope; clicking it (or the "Select Path" button) opens a folder
  picker. Until you have ever picked one, the default is `C:\`.
- Click "Start Scan" to begin. The audit runs on a background thread with
  per-rule progress; the UI stays responsive.
- The previous result is cached locally and shown on the next launch until
  you re-scan.

### 2. Review candidates (Cleanup tab)

- The KPI row shows free space on the system drive, pending P2 / P1 volume,
  and reclaimable duplicates.
- "All / P2 / P1 / P0" buttons filter the candidate table by risk tier:
  - **P2** — pure caches, logs, rebuildable content; safe to quarantine;
  - **P1** — needs case-by-case confirmation;
  - **P0** — never touched, shown for review only.
- Clicking a row shows details on the right: real disk usage, ownership
  (which project / toolchain it belongs to), tier reasoning, the
  **content spot-check result** (e.g. "3 document-like files found in a
  cache directory — downgraded to P1") and notes.

### 3. Quarantine selection

- Multi-select with Ctrl / Shift (`Ctrl+A` selects all visible rows);
  the "Quarantine Selected (N)" button live-updates the count and size.
- A confirmation dialog states that **nothing is deleted**, the retention
  days, and how to restore.
- Quarantine is a **same-disk rename** — instant. Cross-disk moves are
  copies and warn first.
- P0 rows are never moved; P1 rows get an extra confirmation in the GUI.

### 4. Restore (Quarantine tab)

- Each row shows the entry name, tier, size, move-in time, **days
  remaining**, and the original path.
- Select one or more rows (`Ctrl+A` works here too) and click
  "Restore Selected (N)" to restore **in place**: files return to their
  original paths, the manifest is updated, and the action is audit-logged.
- Entries whose original path is now occupied are skipped, never
  overwritten.

## Managing the quarantine

### Manual permanent delete

- Select entries and click "Permanently Delete Selected (N)" — this
  requires **two confirmations**: first the scope, then a full path list.
- Before deleting, the app verifies the `EntryId` (tamper check — entries
  whose manifest was edited by hand are refused) and the size drift
  (over 10% is treated as modified and skipped).
- Files that are locked are kept in quarantine so you can retry later.
- **Permanent deletion is irreversible.** Review the list line by line.

### Purge expired

- "Purge Expired" lists every entry past its retention (with the full
  path list), then permanently deletes them after one confirmation.
- Expired entries never disappear on their own — unless you register the
  scheduled task below.

### Open folder

- "Open Folder" shows the quarantine in File Explorer for manual review.
- Deleting files inside the quarantine via File Explorer is allowed but
  leaves no audit trail and is not recommended; refresh the list
  afterwards.

## Scheduled auto-purge

Disabled by **default**. Tick "Auto-purge expired entries" on the
Quarantine tab, or register from the CLI:

```powershell
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -DailyAt 04:15
```

- This creates a task in Windows Task Scheduler (name prefix `DriveSift`)
  that runs daily at 04:15 and purges **only expired** entries; anything
  within its retention window is untouched.
- Status: `Get-DsAutoPurgeStatus`; unregister:
  `Register-DsAutoPurge -Unregister`.
- An existing task is not re-registered; the GUI checkbox stays in sync.

## Command-line reference

All commands support the common `-WhatIf` / `-Confirm` parameters.
Read-only commands: `Invoke-DsAudit`, `Get-DsInventory`, `Get-DsOwnership`,
`Get-DsCandidate`, `Find-DsDuplicate`, `Get-DsQuarantine`, `Get-DsRuleSet`,
`Get-DsSystemHealth`, `Get-DsOptimizationSuggestion`,
`Get-DsQuickActionCatalog`, `Get-DsAutoPurgeStatus`.

### Audit and inventory

```powershell
# One-shot full audit (read-only): ownership + inventory + candidates
# + duplicates + health + suggestions + HTML report
Invoke-DsAudit -ProjectRoot D:\XM -DuplicatePath D:\XM -OutFile .\report.html -Open

# Step by step
$own = Get-DsOwnership -ProjectRoot D:\XM
Get-DsInventory -Path "$env:LOCALAPPDATA\npm-cache"
Find-DsDuplicate -Path D:\XM -MinSize 10MB
```

### Candidates and tiers

```powershell
Get-DsCandidate -Ownership $own -Tier P2     # P2 only
Get-DsCandidate -Ownership $own              # all tiers (P0 shown, never moved)
Get-DsCandidate -Ownership $own -Tier P1 -IncludePending   # opt in to P1
```

- Output fields include `Tier`, `Reasons`, `ContentHits` /
  `ContentHitKinds` (content spot-check hits), and `Rebuild` (the
  official rebuild command).
- A P2 candidate whose content spot-check finds suspicious categories
  (documents, secrets, …) is **automatically downgraded to P1**.

### Quarantine / restore / permanent delete

```powershell
# Quarantine (move only; P1 requires -IncludePending; asks for confirmation)
Get-DsCandidate -Ownership $own -Tier P2 |
    Move-DsToQuarantine -QuarantineRoot D:\_quarantine -RetentionDays 7

# List entries and expiry state
Get-DsQuarantine -QuarantineRoot D:\_quarantine

# Restore: by EntryId or everything
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -All

# Permanent delete: expired in bulk / manual per entry (double -Confirm)
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -Expired
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>
```

### Health / suggestions / quick actions

```powershell
$h = Get-DsSystemHealth -QuarantineRoot D:\_quarantine   # disk/SSD/RAM/startup/power
Get-DsOptimizationSuggestion -Health $h
Get-DsQuickActionCatalog                                  # the 16-item whitelist
Start-DsQuickAction -Action cleanmgr                      # whitelist only
```

## Custom rules

Rules live in `rules/rules.json` — plain JSON, no code. Key fields:

| Field | Meaning |
|---|---|
| `paths` | Environment variables (`%LOCALAPPDATA%`) and wildcards supported |
| `unit` | `path` evaluates the whole directory; `child` evaluates each child (e.g. each Rust toolchain) |
| `tier` | `P0` / `P1` / `P2`; P0 is never touched |
| `guards` | `unreferenced`: downgrade to P1 while still referenced; `manual`: always P1 |
| `allowContent` | Content whitelist: expected categories inside this directory |
| `rebuild` | Official rebuild command, shown in reports and details |

After editing, run `Get-DsRuleSet` to confirm it loads. Unknown guards are
never silently ignored — the candidate is downgraded to P1 with a reason.

## Where data is written

| Location | Contents | If deleted |
|---|---|---|
| Your chosen quarantine directory | quarantined files + `manifest.jsonl` + `audit.jsonl` | you lose the ability to restore |
| `%LOCALAPPDATA%\DriveSift\` | last-audit cache, window settings, HTML report | only cache and reports, no user data |

## FAQ

**Q: How is quarantining different from deleting?**
Quarantine is a same-disk rename — the data is untouched and restorable
during the retention window. Deleting is irreversible. DriveSift's rule:
quarantine first, review, then permanently delete.

**Q: Why was a "cache" directory marked P1?**
The content spot-check found documents, images, source, or secrets outside
the whitelist — personal files are probably mixed in, so it is downgraded
for safety. Declare expected categories via `allowContent`.

**Q: Restore says the path is occupied?**
Something now occupies the original path. The entry stays in quarantine;
close the occupying program and retry.

**Q: Cross-disk quarantine is slow?**
Cross-disk moves are copies. Keep the quarantine on the same disk as the
files being cleaned (same-disk moves are instant renames).

**Q: Do expired entries vanish by themselves?**
No. Expiry only means "permanent delete is now allowed" — purge manually
or register the scheduled task.

**Q: What if manifest.jsonl is deleted?**
Without the manifest the software cannot restore those entries (the
tamper check fails too). Never edit or remove the manifest or audit files.

**Q: I made a mistake restoring / deleting?**
Restore copies back and leaves the quarantine copy untouched; permanent
deletion is irreversible. Rely on system backups or snapshots — this tool
does not replace backups.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Start-Gui.cmd flashes and exits | Run `.\ui\DriveSift.Gui.ps1` from PowerShell to see the error; usually execution policy — use `-ExecutionPolicy Bypass` |
| "Cannot load module" | Check the path and that antivirus has not quarantined files; verify with `Get-Item .\DriveSift.psd1` |
| Scan is slow | First pass over huge trees takes time; progress advances per rule; later runs use the cache |
| Some system dirs show no size | Normal accounts cannot read them; entries are skipped. Run elevated if needed |
| GUI blank / crash | Run `.\ui\DriveSift.Gui.ps1 -ValidateOnly` (headless self-check) and attach the output to an issue |
| Scheduled task not running | Check `Get-DsAutoPurgeStatus`; search for `DriveSift` in Task Scheduler and look at the last run result |

For anything else, open an issue with the `-ValidateOnly` output and your
PowerShell version (`$PSVersionTable.PSVersion`).

