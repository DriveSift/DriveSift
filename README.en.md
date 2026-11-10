# DriveSift

中文文档：[README.md](README.md)

Windows disk audit tool: **prove ownership before you delete.**

This is not another "one-click cleaner." It answers four questions: what is
this directory, what does it actually contain, which project or toolchain
does it belong to, and how do I get things back afterwards. Every operation
is read-only by default; when you do want to clean, it moves files **into a
quarantine** (7-day retention, restorable in place at any time) and **never
permanently deletes in one step** — permanent deletion is only allowed after
the retention window, requires explicit confirmation, and leaves an audit
trail at every step.

```
C: 116 GB used / 48 GB free
├─ npm-cache            3.5 GB   P2  pure cache, rebuilt by npm
├─ .rustup/toolchains   5.2 GB   P2  4 toolchains, 3 unreferenced
├─ Doubao               6.5 GB   P1  app itself, confirm old versions
└─ Trae/workspaceStorage  ?      P1  contains session history, not recoverable
```

## What it does / does not do

| Does | Does not |
|---|---|
| Sizes by real disk usage (compression, sparse, cluster-aware) | Never permanently deletes in one step |
| Content relevance spot-check: personal files inside a "cache" auto-downgrade to P1 | Never guesses "old means deletable" |
| Builds a directory → project / toolchain ownership index | Never touches ACLs or takes ownership |
| Finds exact duplicates by content hash, detects hardlinks | Never handles OS components (that's DISM / Disk Cleanup) |
| Assigns P0 / P1 / P2 risk tiers with reasons | Never goes online or uploads anything |
| Quarantine (same-disk rename, instant) + 7-day retention + restore / expiry purge | |
| System health, optimization suggestions, quick launch of built-in tools | |
| Optional scheduled auto-purge of expired entries (off by default) | |

## Install

No dependencies to install; PowerShell 5.1 is enough.

```powershell
# Primary repository (AtomGit)
git clone https://atomgit.com/DriveSift/DriveSift.git DriveSift
# Mirror (GitHub)
git clone https://github.com/DriveSift/DriveSift.git DriveSift

Import-Module .\DriveSift\DriveSift.psd1
```

More: [User Guide](docs/USAGE.en.md) ([中文](docs/USAGE.md)) ·
[Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

To auto-load each session, add the repo path to `$env:PSModulePath`.

## Quick start

```powershell
# Read-only audit: ownership + inventory + candidates (with content check)
# + duplicates + report
Invoke-DsAudit -ProjectRoot C:\Projects -DuplicatePath C:\Projects -OutFile .\report.html -Open

# Step by step
$own = Get-DsOwnership -ProjectRoot C:\Projects
Get-DsInventory -Path "$env:LOCALAPPDATA\npm-cache"
Get-DsCandidate -Ownership $own -Tier P2   # candidates with personal files auto-drop to P1
Find-DsDuplicate -Path C:\Projects -MinSize 10MB

# Clean: quarantine first (same-disk rename, instant, 7-day retention)
Get-DsCandidate -Ownership $own -Tier P2 |
    Move-DsToQuarantine -QuarantineRoot D:\_quarantine -RetentionDays 7

# Review during retention: list entries and days remaining, restore
Get-DsQuarantine -QuarantineRoot D:\_quarantine
Restore-DsQuarantine -QuarantineRoot D:\_quarantine -All

# After expiry (or manually any time): permanent delete
# (verifies size drift, audit-logged)
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -Expired
Remove-DsQuarantine -QuarantineRoot D:\_quarantine -EntryId <id>

# PC optimization: health → suggestions → quick actions (built-in tools only)
$h = Get-DsSystemHealth -QuarantineRoot D:\_quarantine
Get-DsOptimizationSuggestion -Health $h -Candidate (Get-DsCandidate -Tier P2)
Start-DsQuickAction -Action cleanmgr        # whitelist: Get-DsQuickActionCatalog

# Optional: auto-purge expired entries daily at 04:15 (off by default)
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -DailyAt 04:15
Get-DsAutoPurgeStatus
Register-DsAutoPurge -QuarantineRoot D:\_quarantine -Unregister
```

## Graphical interface

Double-click `Start-Gui.cmd`, or:

```powershell
.\DriveSift\ui\DriveSift.Gui.ps1 -ProjectRoot C:\Projects
```

> Note: `DriveSift.psd1` is a module manifest (a data file) — double-clicking
> it does not launch the software; Windows just opens it with an editor.

Three tabs:

- **Cleanup**: free space and P2/P1 pending volume, a risk-tier-filtered
  candidate table, and per-candidate content-check reasoning;
  "Quarantine Selected" asks for confirmation.
- **Suggestions**: disk / startup / memory / power-plan advice based on
  measured health; clicking a suggestion launches the matching built-in
  Windows tool.
- **Quarantine**: entries with days remaining and drift status; expired
  entries can be permanently deleted manually with double confirmation,
  EntryId and size-drift verification, and an audit trail.

- No auto-scan on launch: change the scope via the folder picker at the top
  (defaults to `C:\` until you ever pick one), then click "Start Scan".
- The audit runs on a background thread with per-rule progress; the UI never
  freezes.
- Results are cached to `%LOCALAPPDATA%\DriveSift\last-audit.json` and shown
  on the next launch until you re-scan.
- Candidate and quarantine tables support Ctrl/Shift multi-select and
  `Ctrl+A` select-all; buttons show live selection counts.
- The quarantine defaults to the non-system disk with the most free space.
- `-ValidateOnly` performs a headless UI self-check (XAML, row models,
  filtering) — no windows, no scanning.

## Commands

| Command | Purpose |
|---|---|
| `Invoke-DsAudit` | One-shot full chain, emits an HTML report (read-only) |
| `Get-DsInventory` | Real per-directory usage, file counts, recent modifications |
| `Get-DsOwnership` | Builds the project and runtime ownership index |
| `Get-DsCandidate` | Rule-based candidates with tiers, reasons and content checks |
| `Find-DsDuplicate` | Content-hash duplicates with hardlink detection |
| `New-DsReport` | Self-contained HTML report |
| `Move-DsToQuarantine` | Move into quarantine with manifest, expiry and audit trail |
| `Get-DsQuarantine` | List quarantine entries and retention state |
| `Restore-DsQuarantine` | Restore in place (any time before expiry) |
| `Remove-DsQuarantine` | Manual / expired permanent delete (drift-checked) |
| `Get-DsRuleSet` | Show the current rule set |
| `Get-DsSystemHealth` | Health: disk, SSD, memory, processes, startup, power plan, quarantine |
| `Get-DsOptimizationSuggestion` | Suggestions derived from measured health |
| `Get-DsQuickActionCatalog` | Quick-action whitelist (16 items) |
| `Start-DsQuickAction` | Launch whitelisted built-in tools / settings pages |
| `Get-DsAutoPurgeStatus` | Query the scheduled task state |
| `Register-DsAutoPurge` | Register / unregister the auto-purge scheduled task |

## Security model

Judge → review → execute; every step is traceable and reversible.

**Judge (what to clean)**

1. **Rule tiers**: P0 is never touched (OS components, credentials, source
   code, Desktop / Documents); P2 is pure cache / logs / old runtimes.
2. **Content relevance check**: sampled extensions inside "cache"
   directories — documents, images, audio/video, source, archives,
   databases, or secrets downgrade the candidate to P1 with the hit
   categories and example paths in the reasons. Rules can whitelist
   expected categories via `allowContent`.
3. **Ownership index**: the `unreferenced` guard downgrades to P1 when the
   directory is still referenced by a project or is the default toolchain.

**Review (before cleaning)**

4. **Tier gates**: P0 always rejected; P1 requires explicit
   `-IncludePending`; the GUI adds confirmation dialogs for risky actions.
5. **Pre-flight re-checks**: the built-in protected list cannot be bypassed
   by rules or candidate objects; the quarantine itself can never be
   quarantined.

**Execute (how it cleans)**

6. **Move, never delete**: same-disk moves are renames (instant);
   cross-disk warns first (that is a copy). After moving, the source is
   verified gone and the target in place — verification failure rolls back.
7. **7-day retention**: each entry gets an `EntryId` and expiry (move time
   + retention days; default 7, configurable 1–365); `manifest.jsonl`
   records original paths; `Restore-DsQuarantine` restores in place.
8. **Permanent deletion has exactly two entries**: manual per `EntryId`, or
   expired (`-Expired` / scheduled task). Both verify `EntryId` and size
   drift (over 10% is treated as modified and skipped); every action is
   written to `audit.jsonl`.

## Rules

Rules are plain JSON in `rules/rules.json` — no executable code, easy to
audit and contribute (currently v2, 24 rules).

```json
{
  "id": "npm-cache",
  "name": "npm global cache",
  "category": "package cache",
  "owner": "npm",
  "tier": "P2",
  "unit": "path",
  "paths": ["%LOCALAPPDATA%\\npm-cache"],
  "guards": [],
  "allowContent": ["source", "archive"],
  "rebuild": "npm cache clean --force",
  "notes": "pure cache, no project code; source and archives are normal here"
}
```

- `paths` supports environment variables and wildcards; `unit: child`
  evaluates each child separately (e.g. each Rust toolchain).
- `guards`: `unreferenced` checks whether a project or default runtime
  still references the directory; `manual` forces P1.
- `allowContent`: content categories expected inside this directory;
  spot-check hits outside the whitelist downgrade to P1.
- Unknown guards are never silently ignored — the candidate is downgraded
  to P1 with a written reason.

## Known limitations

- Does not scan `WinSxS`, system restore, page files — use Storage Sense /
  DISM / cleanmgr.
- Windows disables atime by default, so this tool never uses "last access
  time"; it relies on modification time, references, path ownership and
  content sampling.
- The content check reads extensions only, never file contents, and is
  sample-capped (truncation is stated in the candidate reasons).
- Hardlinks and content-addressed stores (pnpm, Ollama, Git objects) can
  only be approximated by link count, not exact bytes.
- Cross-disk quarantine is a copy and can be slow — keep the quarantine on
  the same disk.
- Some system directories need elevation on Chinese-locale Windows;
  unreadable entries are skipped rather than aborting.

## Data and privacy

- Purely local: no network, no telemetry, never uploads file contents or
  system information.
- All writes go to the quarantine directory you choose and
  `%LOCALAPPDATA%\DriveSift\` (last-audit cache, settings, HTML report);
  deleting the latter loses no user data.
- The developer collects and processes no user data, so the project has no
  (and needs no) privacy policy — the statements above are the data
  handling disclosure.

## Warnings

Permanent deletion in this tool is irreversible:

- Entries can be restored in place during the retention window; after
  expiry or manual permanent deletion they are gone.
- Purges verify tamper state and size drift and show the full list, but
  still review line by line; keep system backups or snapshots as the real
  safety net.
- The software is provided "as is", without warranty of any kind (see
  LICENSE); use at your own risk.

## Development

```
DriveSift/
├── DriveSift.psd1 / .psm1
├── Start-Gui.cmd    double-click to launch the GUI
├── Private/         native file access, ownership index, content check, quarantine core
├── Public/          exported commands
├── rules/           rule set
├── ui/              WPF interface
└── tests/           Pester tests
```

```powershell
# Compatible with Pester 3.4 (bundled with PS 5.1) and Pester 5+
Invoke-Pester .\DriveSift\tests
```

## License

MIT (see LICENSE). The project has zero third-party dependencies; all code
is original (including the native file-access layer).
Security vulnerabilities: see SECURITY.md.

