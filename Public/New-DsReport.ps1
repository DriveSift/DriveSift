function New-DsReport {
    <#
    .SYNOPSIS
        生成自包含的 HTML 审计报告。
    .DESCRIPTION
        报告内嵌全部数据，无外部依赖，可直接归档或分享。
        内容只陈述"这个目录是什么、属于谁、删掉怎么回来"，不给出自动执行结论。
    #>
    [CmdletBinding()]
    param(
        [object[]]$Candidate = @(),
        [object[]]$Duplicate = @(),
        [object]$Ownership,
        [string]$OutFile = (Join-Path (Get-Location) 'DriveSift-report.html'),
        [switch]$Open
    )

    $driveName = $env:SystemDrive.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue

    $usedGB = $null
    $freeGB = $null
    if ($drive) {
        $usedGB = [math]::Round($drive.Used / 1GB, 1)
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
    }

    $candidateData = @($Candidate | ForEach-Object {
        $lastWrite = ''
        if ($_.LastWriteUtc) { $lastWrite = ([datetime]$_.LastWriteUtc).ToLocalTime().ToString('yyyy-MM-dd') }
        [pscustomobject]@{
            Name      = $_.Name
            Category  = $_.Category
            Owner     = $_.Owner
            Tier      = $_.Tier
            SizeMB    = $_.SizeMB
            FileCount = $_.FileCount
            Paths     = @($_.Paths)
            Rebuild   = $_.Rebuild
            Reasons   = @($_.Reasons)
            Notes     = $_.Notes
            LastWrite = $lastWrite
        }
    })

    $duplicateData = @($Duplicate | ForEach-Object {
        [pscustomobject]@{
            Hash          = $_.Hash
            SizeMB        = $_.SizeMB
            FileCount     = $_.FileCount
            ReclaimableMB = $_.ReclaimableMB
            Owners        = @($_.Owners)
            Paths         = @($_.Files | Select-Object -First 8 | ForEach-Object { $_.Path })
            LinkCounts    = @($_.Files | Select-Object -First 8 | ForEach-Object { $_.LinkCount })
        }
    })

    $projectData = @()
    $toolchainData = @()
    if ($Ownership) {
        $projectData = @($Ownership.Projects | ForEach-Object {
            [pscustomobject]@{
                Name      = $_.Name
                Path      = $_.Path
                Kind      = $_.Kind
                LastWrite = if ($_.LastWriteUtc) { ([datetime]$_.LastWriteUtc).ToLocalTime().ToString('yyyy-MM-dd') } else { '' }
                Dirty     = $_.Dirty
            }
        })
        $toolchainData = @($Ownership.Toolchains | ForEach-Object {
            [pscustomobject]@{
                Kind         = $_.Kind
                Name         = $_.Name
                Path         = $_.Path
                IsDefault    = $_.IsDefault
                ReferencedBy = @($_.ReferencedBy)
            }
        })
    }

    $payload = [ordered]@{
        meta = [ordered]@{
            GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Machine     = $env:COMPUTERNAME
            Drive       = "$driveName`:"
            UsedGB      = $usedGB
            FreeGB      = $freeGB
        }
        candidates = $candidateData
        duplicates = $duplicateData
        projects   = $projectData
        toolchains = $toolchainData
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    $json = $json.Replace('</', '<\/')

    $template = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DriveSift 磁盘审计报告</title>
<style>
:root{
  --bg:#f5f5f7;--card:#ffffff;--text:#1d1d1f;--muted:#6e6e73;--border:#e3e3e8;
  --accent:#0a8f4d;--ok:#0a8f4d;--warn:#b26b00;--stop:#c0322a;--chip:#f0f0f3;
}
@media (prefers-color-scheme: dark){
  :root{--bg:#111113;--card:#1c1c1e;--text:#f2f2f7;--muted:#98989d;--border:#2c2c2e;
  --accent:#32f08c;--ok:#32f08c;--warn:#e0a33a;--stop:#ff6b5e;--chip:#26262a;}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
  font:400 14px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:1120px;margin:0 auto;padding:40px 24px 72px}
header{margin-bottom:32px}
h1{font-size:30px;line-height:1.2;margin:0 0 8px;font-weight:650;letter-spacing:-.02em}
.sub{color:var(--muted);margin:0 0 18px}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{background:var(--chip);color:var(--muted);border-radius:999px;padding:5px 12px;font-size:12px;
  border:1px solid var(--border)}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:28px 0 36px}
.kpi{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px}
.kpi .label{color:var(--muted);font-size:12px;margin-bottom:6px}
.kpi .value{font-size:26px;font-weight:650;font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.kpi .hint{color:var(--muted);font-size:12px;margin-top:4px}
section{margin-bottom:40px}
h2{font-size:18px;margin:0 0 14px;font-weight:600;letter-spacing:-.01em}
.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
.search{flex:1;min-width:220px;background:var(--card);border:1px solid var(--border);border-radius:9px;
  padding:8px 12px;color:var(--text);font:inherit;outline:none}
.search:focus{border-color:var(--accent)}
.filter{border:1px solid var(--border);background:var(--card);color:var(--muted);border-radius:999px;
  padding:5px 14px;font:500 12px/1.4 inherit;cursor:pointer}
.filter[aria-pressed="true"]{border-color:var(--accent);color:var(--accent)}
table{width:100%;border-collapse:separate;border-spacing:0;background:var(--card);
  border:1px solid var(--border);border-radius:14px;overflow:hidden}
th{text-align:left;font:500 12px/1.4 inherit;color:var(--muted);padding:12px 14px;border-bottom:1px solid var(--border);
  white-space:nowrap}
td{padding:12px 14px;border-bottom:1px solid var(--border);vertical-align:top}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover{background:var(--chip)}
td.num{font-variant-numeric:tabular-nums;white-space:nowrap;font-weight:600}
.path{font-family:ui-monospace,"Cascadia Mono",Consolas,monospace;font-size:12px;color:var(--muted);
  word-break:break-all}
.why{color:var(--muted);font-size:12px;margin-top:4px}
.badge{display:inline-block;border-radius:999px;padding:2px 9px;font-size:11px;font-weight:600;
  border:1px solid currentColor}
.badge.ok{color:var(--ok)}.badge.warn{color:var(--warn)}.badge.stop{color:var(--stop)}
.mono{font-family:ui-monospace,"Cascadia Mono",Consolas,monospace;font-size:12px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:18px}
.dupe{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px;margin-bottom:12px}
.dupe .head{display:flex;justify-content:space-between;gap:12px;align-items:baseline;margin-bottom:8px}
.dupe .head b{font-size:15px}
.dupe ul{margin:8px 0 0;padding-left:18px}
.dupe li{margin-bottom:4px}
.empty{color:var(--muted);padding:18px;border:1px dashed var(--border);border-radius:12px;text-align:center}
footer{color:var(--muted);font-size:12px;border-top:1px solid var(--border);padding-top:20px;line-height:1.8}
code{background:var(--chip);border-radius:6px;padding:2px 6px;font-family:ui-monospace,Consolas,monospace;font-size:12px}
@media (max-width:760px){.kpis{grid-template-columns:1fr}.grid2{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>DriveSift 磁盘审计报告</h1>
  <p class="sub">先证明归属，再决定删除。本报告不会删除任何文件。</p>
  <div class="chips" id="meta"></div>
</header>

<div class="kpis" id="kpis"></div>

<section>
  <h2>清理候选</h2>
  <div class="bar">
    <input class="search" id="search" placeholder="按名称、路径、归属过滤…">
    <button class="filter" data-tier="ALL" aria-pressed="true">全部</button>
    <button class="filter" data-tier="P2" aria-pressed="false">P2 可处理</button>
    <button class="filter" data-tier="P1" aria-pressed="false">P1 需确认</button>
  </div>
  <div id="candidateTable"></div>
</section>

<section>
  <h2>重复文件</h2>
  <div id="dupes"></div>
</section>

<section>
  <h2>归属索引</h2>
  <div class="grid2">
    <div><h2 style="font-size:14px;color:var(--muted);font-weight:500">项目</h2><div id="projects"></div></div>
    <div><h2 style="font-size:14px;color:var(--muted);font-weight:500">工具链</h2><div id="toolchains"></div></div>
  </div>
</section>

<footer>
  <div>执行方式：<code>$c = Get-DsCandidate -Tier P2</code> → <code>$c | Move-DsToQuarantine -QuarantineRoot D:\_quarantine</code></div>
  <div>回滚方式：<code>Restore-DsQuarantine -QuarantineRoot D:\_quarantine -List</code>，确认后加 <code>-All</code> 还原。</div>
  <div>隔离区只做改名，不删除内容；P0 与受保护路径永远不会被移动。</div>
</footer>
</div>

<script>
const DATA = __PAYLOAD__;
const cand = DATA.candidates || [];
const dupes = DATA.duplicates || [];
const projects = DATA.projects || [];
const toolchains = DATA.toolchains || [];
const meta = DATA.meta || {};

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtMB = mb => {
  const n = Number(mb) || 0;
  return n >= 1024 ? (n / 1024).toFixed(1) + ' GB' : Math.round(n) + ' MB';
};
const tierBadge = t => '<span class="badge ' + (t === 'P2' ? 'ok' : t === 'P1' ? 'warn' : 'stop') + '">' + esc(t) + '</span>';

document.getElementById('meta').innerHTML = [
  '生成于 ' + esc(meta.GeneratedAt),
  '主机 ' + esc(meta.Machine),
  '盘符 ' + esc(meta.Drive),
  '已用 ' + esc(meta.UsedGB) + ' GB / 剩余 ' + esc(meta.FreeGB) + ' GB'
].map(x => '<span class="chip">' + x + '</span>').join('');

const p2 = cand.filter(c => c.Tier === 'P2').reduce((s, c) => s + (Number(c.SizeMB) || 0), 0);
const p1 = cand.filter(c => c.Tier === 'P1').reduce((s, c) => s + (Number(c.SizeMB) || 0), 0);
const dr = dupes.reduce((s, d) => s + (Number(d.ReclaimableMB) || 0), 0);
document.getElementById('kpis').innerHTML = [
  ['P2 可处理', fmtMB(p2), '纯缓存、旧版本，可隔离'],
  ['P1 需确认', fmtMB(p1), '可能含会话、模型或活跃环境'],
  ['重复可回收', fmtMB(dr), dupes.length + ' 组内容完全相同的文件']
].map(k => '<div class="kpi"><div class="label">' + k[0] + '</div><div class="value">' + esc(k[1]) +
  '</div><div class="hint">' + esc(k[2]) + '</div></div>').join('');

let tierFilter = 'ALL';
let keyword = '';

function renderCandidates() {
  const rows = cand
    .filter(c => tierFilter === 'ALL' || c.Tier === tierFilter)
    .filter(c => {
      if (!keyword) return true;
      const hay = (c.Name + ' ' + c.Owner + ' ' + (c.Paths || []).join(' ') + ' ' + c.Category).toLowerCase();
      return hay.indexOf(keyword) >= 0;
    })
    .sort((a, b) => (Number(b.SizeMB) || 0) - (Number(a.SizeMB) || 0));

  if (!rows.length) {
    document.getElementById('candidateTable').innerHTML = '<div class="empty">没有匹配的候选</div>';
    return;
  }

  const body = rows.map(c => {
    const paths = (c.Paths || []).map(p => '<div class="path">' + esc(p) + '</div>').join('');
    const why = (c.Reasons || []).map(r => '<div class="why">· ' + esc(r) + '</div>').join('');
    const rebuild = c.Rebuild ? '<div class="why">重建：' + esc(c.Rebuild) + '</div>' : '';
    return '<tr>' +
      '<td><b>' + esc(c.Name) + '</b>' + why + rebuild + '</td>' +
      '<td class="path">' + esc(c.Category) + '</td>' +
      '<td class="path">' + esc(c.Owner) + '</td>' +
      '<td class="num">' + fmtMB(c.SizeMB) + '<div class="why">' + esc(c.FileCount) + ' 个文件</div></td>' +
      '<td>' + tierBadge(c.Tier) + '</td>' +
      '<td class="path">' + esc(c.LastWrite) + '</td>' +
      '<td>' + paths + '</td>' +
      '</tr>';
  }).join('');

  document.getElementById('candidateTable').innerHTML =
    '<table><thead><tr><th>名称 / 理由</th><th>类别</th><th>归属</th><th>占用</th><th>级别</th><th>最近修改</th><th>路径</th></tr></thead>' +
    '<tbody>' + body + '</tbody></table>';
}

document.querySelectorAll('.filter').forEach(btn => {
  btn.addEventListener('click', () => {
    tierFilter = btn.dataset.tier;
    document.querySelectorAll('.filter').forEach(b => b.setAttribute('aria-pressed', String(b === btn)));
    renderCandidates();
  });
});
document.getElementById('search').addEventListener('input', e => {
  keyword = e.target.value.trim().toLowerCase();
  renderCandidates();
});

if (!dupes.length) {
  document.getElementById('dupes').innerHTML = '<div class="empty">没有发现内容完全相同的文件</div>';
} else {
  document.getElementById('dupes').innerHTML = dupes.slice(0, 30).map(d => {
    const links = (d.Paths || []).map((p, i) => {
      const lc = (d.LinkCounts || [])[i] || 1;
      return '<li><span class="path">' + esc(p) + '</span>' + (lc > 1 ? ' <span class="badge warn">硬链接</span>' : '') + '</li>';
    }).join('');
    return '<div class="dupe"><div class="head"><b>' + fmtMB(d.SizeMB) + ' × ' + esc(d.FileCount) + ' 份</b>' +
      '<span>可回收 ' + fmtMB(d.ReclaimableMB) + '</span></div>' +
      '<div class="path">hash ' + esc(String(d.Hash).slice(0, 16)) + ' · 归属 ' + esc((d.Owners || []).join(', ') || '—') + '</div>' +
      '<ul>' + links + '</ul></div>';
  }).join('');
}

const smallTable = (head, rows) => {
  if (!rows.length) return '<div class="empty">无数据</div>';
  return '<table><thead><tr>' + head.map(h => '<th>' + esc(h) + '</th>').join('') + '</tr></thead><tbody>' +
    rows.map(r => '<tr>' + r.map(c => '<td>' + c + '</td>').join('') + '</tr>').join('') + '</tbody></table>';
};

document.getElementById('projects').innerHTML = smallTable(['项目', '类型', '最近修改'], projects.map(p => [
  '<b>' + esc(p.Name) + '</b><div class="path">' + esc(p.Path) + '</div>',
  esc(p.Kind),
  esc(p.LastWrite) + (p.Dirty === true ? ' <span class="badge warn">有未提交</span>' : '')
]));

document.getElementById('toolchains').innerHTML = smallTable(['运行时', '版本 / 名称', '状态'], toolchains.map(t => [
  esc(t.Kind),
  '<b>' + esc(t.Name) + '</b><div class="path">' + esc(t.Path) + '</div>',
  (t.IsDefault ? '<span class="badge ok">默认</span> ' : '') +
  ((t.ReferencedBy || []).length ? esc((t.ReferencedBy || []).join(', ')) : '<span class="badge stop">无引用</span>')
]));

renderCandidates();
</script>
</body>
</html>
'@

    $html = $template.Replace('__PAYLOAD__', $json)

    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $html, $encoding)

    $result = [pscustomobject]@{
        Path          = (Resolve-Path -LiteralPath $OutFile).Path
        CandidateCount = $candidateData.Count
        DuplicateGroups = $duplicateData.Count
        SizeKB        = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1)
    }

    if ($Open) { Start-Process -FilePath $result.Path }
    $result
}
