<#
DriveSift 测试套件。
兼容 Pester 3.4（PowerShell 5.1）与 Pester 5+：
- 不使用顶层 BeforeAll（Pester 3.4 不支持）
- 否定断言用 "Should Not Be"（两代都支持）
- 不使用 -Show 等 Pester 5 专有参数
#>

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePath = Join-Path $script:ProjectRoot 'DriveSift.psd1'
$script:RulesFile = Join-Path $script:ProjectRoot 'rules\rules.json'

Import-Module -Name $script:ModulePath -Force

# 私有函数用于单元测试：按文件名顺序 dot-source。
# 00-Native.ps1 的 Add-Type 带类型守卫，与已加载的模块共存不会冲突。
Get-ChildItem -Path (Join-Path $script:ProjectRoot 'Private') -Filter '*.ps1' -File |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

# 本次运行的独立临时根目录
$script:TestRoot = Join-Path $env:TEMP ("ds-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

function Remove-DsTestRoot {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Pester 3.4 没有 BeIn/BeContainedBy 操作符：自写成员断言（失败时抛异常，3.4 与 5+ 都兼容）
function Assert-Contained {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        $Item,
        [Parameter(Mandatory)]
        $In
    )
    if (@($In) -contains $Item) { return }
    throw "断言失败：'$Item' 不在集合中 [$( @($In) -join ', ' )]"
}

# ---------- 模块与规则集 ----------
Describe '模块与规则集' {
    It '模块导出全部 17 个公共命令' {
        $cmds = @(Get-Command -Module DriveSift -CommandType Function)
        $cmds.Count | Should Be 17
        'Get-DsQuarantine' | Assert-Contained -In @($cmds.Name)
        'Remove-DsQuarantine' | Assert-Contained -In @($cmds.Name)
        'Get-DsSystemHealth' | Assert-Contained -In @($cmds.Name)
        'Get-DsOptimizationSuggestion' | Assert-Contained -In @($cmds.Name)
        'Register-DsAutoPurge' | Assert-Contained -In @($cmds.Name)
    }

    It '规则集版本为 2，共 24 条规则' {
        $raw = Get-Content -LiteralPath $script:RulesFile -Raw | ConvertFrom-Json
        $raw.version | Should Be 2
        $rules = @(Get-DsRuleSet)
        $rules.Count | Should Be 24
    }

    It '每条规则都有 id/name/tier/paths，tier 合法' {
        $rules = @(Get-DsRuleSet)
        foreach ($rule in $rules) {
            $rule.Id | Should Not BeNullOrEmpty
            $rule.Name | Should Not BeNullOrEmpty
            $rule.Tier | Assert-Contained -In @('P0', 'P1', 'P2')
            @($rule.Paths).Count | Should BeGreaterThan 0
        }
    }

    It 'allowContent 只包含已知类别' {
        $known = @('docs', 'photos', 'media', 'source', 'archive', 'data', 'secrets',
            'web', 'text', 'package', 'crash', 'model')
        foreach ($rule in @(Get-DsRuleSet)) {
            foreach ($category in @($rule.AllowContent)) {
                $category | Assert-Contained -In $known
            }
        }
    }

    It '规则文件不存在时抛异常' {
        { Get-DsRuleSet -Path (Join-Path $script:TestRoot 'no-such-rules.json') } | Should Throw
    }
}

# ---------- 内容分类与抽样画像 ----------
Describe '内容分类与抽样画像' {
    BeforeAll {
        $script:ContentRoot = Join-Path $script:TestRoot 'content'
        New-Item -ItemType Directory -Path (Join-Path $script:ContentRoot 'mixed') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:ContentRoot 'clean') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:ContentRoot 'allowed') -Force | Out-Null

        # mixed：缓存 + 个人文件混装
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'mixed\a.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'mixed\b.log') -Value 'log'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'mixed\memo.docx') -Value 'doc'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'mixed\photo.jpg') -Value 'img'

        # clean：纯缓存
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'clean\a.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'clean\b.log') -Value 'log'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'clean\c.txt') -Value 'txt'

        # allowed：源码 + 压缩包（npm 缓存的正常成分）
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'allowed\app.js') -Value 'console.log(1)'
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'allowed\lib.tgz') -Value 'tar'
    }

    It '扩展名分类：docs/photos/media/package/other' {
        (Get-DsExtensionCategory -Extension '.pdf') | Should Be 'docs'
        (Get-DsExtensionCategory -Extension '.DOCX') | Should Be 'docs'
        (Get-DsExtensionCategory -Extension '.png') | Should Be 'photos'
        (Get-DsExtensionCategory -Extension '.mp4') | Should Be 'media'
        (Get-DsExtensionCategory -Extension '.exe') | Should Be 'package'
        (Get-DsExtensionCategory -Extension '.dmp') | Should Be 'crash'
        (Get-DsExtensionCategory -Extension '.key') | Should Be 'secrets'
        (Get-DsExtensionCategory -Extension '.xyzzy12345678') | Should Be 'other'
        (Get-DsExtensionCategory -Extension '') | Should Be 'other'
    }

    It '混入个人文件的目录被识别为可疑' {
        $p = Get-DsContentProfile -Path (Join-Path $script:ContentRoot 'mixed')
        $p.SuspiciousCount | Should Be 2
        $p.SuspiciousKinds -like '*文档*' | Should Be $true
        $p.SuspiciousKinds -like '*图片*' | Should Be $true
        @($p.SuspiciousSamples).Count | Should Be 2
        $p.TopCategories -like '*网页资源*' | Should Be $true
    }

    It '纯缓存目录无可疑文件' {
        $p = Get-DsContentProfile -Path (Join-Path $script:ContentRoot 'clean')
        $p.SuspiciousCount | Should Be 0
        $p.SuspiciousKinds | Should Be ''
        $p.CheckedFiles | Should Be 3
        $p.Truncated | Should Be $false
    }

    It 'allowContent 白名单豁免相应类别' {
        $p = Get-DsContentProfile -Path (Join-Path $script:ContentRoot 'allowed') -Allow @('source', 'archive')
        $p.SuspiciousCount | Should Be 0
        # 不带白名单时，这两类都算可疑
        $p2 = Get-DsContentProfile -Path (Join-Path $script:ContentRoot 'allowed')
        $p2.SuspiciousCount | Should Be 2
    }

    It '超出抽样上限时标注截断' {
        $p = Get-DsContentProfile -Path (Join-Path $script:ContentRoot 'clean') -SampleLimit 2
        $p.Truncated | Should Be $true
        $p.CheckedFiles | Should Be 2
    }

    It '不存在的目录返回空画像' {
        $p = Get-DsContentProfile -Path (Join-Path $script:TestRoot 'does-not-exist')
        $p.CheckedFiles | Should Be 0
        $p.SuspiciousCount | Should Be 0
    }
}

# ---------- 候选生成与降级 ----------
Describe '候选生成与降级' {
    BeforeAll {
        $script:FixRoot = Join-Path $script:TestRoot 'fixtures'
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-clean') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-dirty') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-allow') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-manual') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-ref') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'cache-empty') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'multi\sub-a') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FixRoot 'multi\sub-b') -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-clean\a.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-clean\b.log') -Value 'log'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-dirty\a.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-dirty\memo.docx') -Value 'doc'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-allow\app.js') -Value 'console.log(1)'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-allow\lib.tgz') -Value 'tar'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-manual\a.log') -Value 'log'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'cache-ref\a.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'multi\sub-a\1.bin') -Value 'a'
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'multi\sub-b\2.bin') -Value 'b'

        $r = $script:FixRoot
        $json = @'
{
  "version": 2,
  "rules": [
    { "id": "t-clean", "name": "纯缓存", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-clean"], "guards": [], "rebuild": "重建", "notes": "" },
    { "id": "t-dirty", "name": "脏缓存", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-dirty"], "guards": [], "rebuild": "重建", "notes": "" },
    { "id": "t-allow", "name": "白名单缓存", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-allow"], "guards": [], "allowContent": ["source", "archive"], "rebuild": "重建", "notes": "" },
    { "id": "t-manual", "name": "人工确认", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-manual"], "guards": ["manual"], "rebuild": "重建", "notes": "" },
    { "id": "t-ref", "name": "引用守卫", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-ref"], "guards": ["unreferenced"], "rebuild": "重建", "notes": "" },
    { "id": "t-child", "name": "子项聚合", "category": "测试", "owner": "test", "tier": "P2", "unit": "child", "aggregate": true, "paths": ["__ROOT__\\multi"], "guards": [], "rebuild": "重建", "notes": "" },
    { "id": "t-empty", "name": "空目录", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\cache-empty"], "guards": [], "rebuild": "重建", "notes": "" },
    { "id": "t-missing", "name": "缺失路径", "category": "测试", "owner": "test", "tier": "P2", "unit": "path", "paths": ["__ROOT__\\no-such-dir"], "guards": [], "rebuild": "重建", "notes": "" }
  ]
}
'@
        $script:SyntheticRules = Join-Path $script:TestRoot 'synthetic-rules.json'
        # 路径里的反斜杠必须转义，否则不是合法 JSON（.NET 替换串不转义反斜杠，替换值写两个）
        Set-Content -LiteralPath $script:SyntheticRules -Value ($json -replace '__ROOT__', ($r -replace '\\', '\\')) -Encoding UTF8
    }

    It '纯缓存 P2 保持 P2，无内容命中' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-clean') | Select-Object -First 1
        $c | Should Not BeNullOrEmpty
        $c.Tier | Should Be 'P2'
        $c.ContentHits | Should Be 0
        $c.ContentChecked | Should Be 2
    }

    It '混入文档的 P2 目录被降为 P1 并给出内容理由' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-dirty') | Select-Object -First 1
        $c.Tier | Should Be 'P1'
        $c.RequestedTier | Should Be 'P2'
        $c.ContentHits | Should Be 1
        $c.Reasons -match '内容检查' | Should Be $true
    }

    It 'allowContent 白名单抑制降级' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-allow') | Select-Object -First 1
        $c.Tier | Should Be 'P2'
        $c.ContentHits | Should Be 0
        $c.ContentChecked | Should Be 2
    }

    It 'manual 守卫强制 P1' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-manual') | Select-Object -First 1
        $c.Tier | Should Be 'P1'
        $c.Reasons -match '人工确认' | Should Be $true
    }

    It 'unreferenced 守卫在无归属索引时降为 P1' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-ref') | Select-Object -First 1
        $c.Tier | Should Be 'P1'
        $c.Reasons -match '归属索引' | Should Be $true
    }

    It 'aggregate 规则把子项聚合成单个候选' {
        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-child')
        $c.Count | Should Be 1
        @($c[0].Paths).Count | Should Be 2
    }

    It '空目录与缺失路径不产生候选' {
        @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-empty').Count | Should Be 0
        @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-missing').Count | Should Be 0
    }

    It '候选携带归属项目（归属索引接入）' {
        Set-Content -LiteralPath (Join-Path $script:FixRoot 'package.json') -Value '{"name":"ds-test-proj"}'
        $ownership = Get-DsOwnership -ProjectRoot @($script:FixRoot)
        @($ownership.Projects).Count | Should BeGreaterThan 0

        $c = @(Get-DsCandidate -RuleSetPath $script:SyntheticRules -Id 't-clean' -Ownership $ownership) | Select-Object -First 1
        $c.Owner -like 'project:*' | Should Be $true

        Remove-Item -LiteralPath (Join-Path $script:FixRoot 'package.json') -Force
    }
}

# ---------- 隔离区生命周期 ----------
function New-DsTestCandidate {
    param(
        [string]$Name,
        [string[]]$Paths,
        [string]$Tier = 'P2',
        [long]$SizeBytes = 1024
    )
    [pscustomobject]@{
        Id = $Name; RuleId = 't'; Name = $Name; Tier = $Tier
        Paths = @($Paths); FileCount = 1
        SizeMB = [math]::Round($SizeBytes / 1MB, 3)
        SizeBytes = $SizeBytes
        Rebuild = 'n/a'; ContentHits = 0; ContentHitKinds = ''
    }
}

# 每个用例一套独立隔离区 + 源目录（64KB 载荷，便于尺寸漂移检测）
function New-DsQFixture {
    param([string]$Name)
    $root = Join-Path $script:TestRoot "q-$Name"
    $src = Join-Path $root "src\$Name"
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    $payload = New-Object byte[] 65536
    [System.IO.File]::WriteAllBytes((Join-Path $src 'payload.bin'), $payload)
    $cand = New-DsTestCandidate -Name $Name -Paths @($src) -SizeBytes 65536
    @{ Root = (Join-Path $root 'quarantine'); Candidate = $cand; Source = $src }
}

function Read-DsAuditActions {
    param([string]$QuarantineRoot)
    $log = Join-Path $QuarantineRoot 'audit.jsonl'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { ($_ | ConvertFrom-Json).Action })
}

Describe '隔离区生命周期' {
    It '移入隔离区：文件就位、manifest 字段完整、审计留痕' {
        $fx = New-DsQFixture 'move'
        $r = @(Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -RetentionDays 7 -Confirm:$false)
        $r.Count | Should Be 1
        $r[0].Action | Should Be 'Quarantined'
        (Test-Path -LiteralPath $fx.Source) | Should Be $false
        (Test-Path -LiteralPath $r[0].StoredPath) | Should Be $true

        $entry = @(Read-DsManifest -QuarantineRoot $fx.Root)[0]
        $entry.EntryId | Should Not BeNullOrEmpty
        $entry.RetentionDays | Should Be 7
        $entry.SizeBytes | Should Be 65536
        $entry.OriginalPath | Should Be $fx.Source
        $purgeAfter = [datetime]$entry.PurgeAfter
        $movedAt = [datetime]$entry.MovedAt
        ($purgeAfter - $movedAt).Days | Should Be 7

        $actions = Read-DsAuditActions $fx.Root
        'quarantined' | Assert-Contained -In @($actions)
    }

    It 'Get-DsQuarantine 返回保留期状态' {
        $fx = New-DsQFixture 'list'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -RetentionDays 7 -Confirm:$false
        $list = @(Get-DsQuarantine -QuarantineRoot $fx.Root)
        $list.Count | Should Be 1
        $list[0].DaysLeft | Should Be 7
        $list[0].Expired | Should Be $false
        $list[0].StoredExists | Should Be $true
        $list[0].Name | Should Be 'list'
    }

    It '还原：原位恢复、manifest 清空、审计留痕' {
        $fx = New-DsQFixture 'restore'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $r = @(Restore-DsQuarantine -QuarantineRoot $fx.Root -All -Confirm:$false)
        $r[0].Action | Should Be 'Restored'
        (Test-Path -LiteralPath $fx.Source) | Should Be $true
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 0
        'restored' | Assert-Contained -In @(Read-DsAuditActions $fx.Root)
    }

    It '篡改 manifest 的 StoredPath 会被防篡改拦截' {
        $fx = New-DsQFixture 'tamper'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $entry = @(Read-DsManifest -QuarantineRoot $fx.Root)[0]
        # 指向隔离区之外的路径，必须被拦截
        $evil = Join-Path $script:TestRoot 'tamper-outside'
        $entry.StoredPath = $evil
        Write-DsManifest -QuarantineRoot $fx.Root -Entries @($entry)

        $r = @(Remove-DsQuarantine -QuarantineRoot $fx.Root -EntryId $entry.EntryId -Confirm:$false)
        $r[0].Action | Should Be 'Skipped'
        $r[0].Reason -match '防篡改' | Should Be $true
        (Test-Path -LiteralPath $evil) | Should Be $false
    }

    It '隔离期间内容尺寸漂移会被跳过' {
        $fx = New-DsQFixture 'drift'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $entry = @(Read-DsManifest -QuarantineRoot $fx.Root)[0]
        # 追加 100KB，超过 10% 漂移阈值（StoredPath 是被移走的目录本身）
        $extra = New-Object byte[] 102400
        $fs = [System.IO.File]::Open((Join-Path $entry.StoredPath 'payload.bin'), [System.IO.FileMode]::Append)
        $fs.Write($extra, 0, $extra.Length)
        $fs.Dispose()

        $r = @(Remove-DsQuarantine -QuarantineRoot $fx.Root -EntryId $entry.EntryId -Confirm:$false)
        $r[0].Action | Should Be 'Skipped'
        $r[0].Reason -match '漂移' | Should Be $true
    }

    It '手动永久删除：文件移除、manifest 更新、审计留痕' {
        $fx = New-DsQFixture 'purge'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $entry = @(Read-DsManifest -QuarantineRoot $fx.Root)[0]
        $stored = $entry.StoredPath

        $r = @(Remove-DsQuarantine -QuarantineRoot $fx.Root -EntryId $entry.EntryId -Confirm:$false)
        $r[0].Action | Should Be 'Purged'
        (Test-Path -LiteralPath $stored) | Should Be $false
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 0
        'purged' | Assert-Contained -In @(Read-DsAuditActions $fx.Root)
    }

    It '到期清理：只删到期条目，未到期保留' {
        $fx = New-DsQFixture 'expiry'
        # 第二个源目录必须位于隔离区根之外，否则会被“已在隔离区”拦截
        $base = Split-Path -Parent $fx.Root
        $src2 = Join-Path $base 'src-second'
        New-Item -ItemType Directory -Path $src2 -Force | Out-Null
        $payload = New-Object byte[] 65536
        [System.IO.File]::WriteAllBytes((Join-Path $src2 'payload.bin'), $payload)
        $cand2 = New-DsTestCandidate -Name 'second' -Paths @($src2) -SizeBytes 65536
        $null = Move-DsToQuarantine -Candidate @($fx.Candidate, $cand2) -QuarantineRoot $fx.Root -RetentionDays 7 -Confirm:$false
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 2

        # 把其中一条改成已到期
        $entries = @(Read-DsManifest -QuarantineRoot $fx.Root)
        $target = $entries | Where-Object { $_.Id -eq 'expiry' }
        $target.PurgeAfter = (Get-Date).AddDays(-1).ToString('s')
        Write-DsManifest -QuarantineRoot $fx.Root -Entries $entries

        $list = @(Get-DsQuarantine -QuarantineRoot $fx.Root)
        @($list | Where-Object { $_.Expired }).Count | Should Be 1

        $r = @(Remove-DsQuarantine -QuarantineRoot $fx.Root -Expired -Confirm:$false)
        @($r | Where-Object { $_.Action -eq 'Purged' }).Count | Should Be 1
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 1
    }

    It '无到期条目时 -Expired 不删除任何内容' {
        $fx = New-DsQFixture 'noexpiry'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $r = @(Remove-DsQuarantine -QuarantineRoot $fx.Root -Expired -Confirm:$false)
        $r.Count | Should Be 0
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 1
    }

    It 'manifest 损坏行被跳过，正常条目仍可读' {
        $fx = New-DsQFixture 'corrupt'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        Add-Content -LiteralPath (Join-Path $fx.Root 'manifest.jsonl') -Value 'not-json{{{garbage' -Encoding UTF8
        $list = @(Get-DsQuarantine -QuarantineRoot $fx.Root)
        $list.Count | Should Be 1
    }

    It 'P0 永远拒绝，P1 需要 -IncludePending' {
        $fx = New-DsQFixture 'tiers'
        $p0 = New-DsTestCandidate -Name 'p0-item' -Paths @($fx.Source) -Tier 'P0'
        $null = Move-DsToQuarantine -Candidate $p0 -QuarantineRoot $fx.Root -Confirm:$false
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 0
        (Test-Path -LiteralPath $fx.Source) | Should Be $true

        $p1 = New-DsTestCandidate -Name 'p1-item' -Paths @($fx.Source) -Tier 'P1'
        $null = Move-DsToQuarantine -Candidate $p1 -QuarantineRoot $fx.Root -Confirm:$false
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 0
        (Test-Path -LiteralPath $fx.Source) | Should Be $true

        $null = Move-DsToQuarantine -Candidate $p1 -QuarantineRoot $fx.Root -IncludePending -Confirm:$false
        @(Read-DsManifest -QuarantineRoot $fx.Root).Count | Should Be 1
        (Test-Path -LiteralPath $fx.Source) | Should Be $false
    }

    It 'Get-DsEntryExpiry 对无时间戳的旧条目保守处理' {
        $legacy = [pscustomobject]@{ Batch = 'b'; OriginalPath = 'x'; StoredPath = 'y' }
        $e = Get-DsEntryExpiry -Entry $legacy -DefaultRetentionDays 7
        $e.Unknown | Should Be $true
        $e.Expired | Should Be $false
    }

    It '受保护路径拒绝移入隔离区' {
        $protected = Join-Path $env:USERPROFILE 'Documents'
        $result = @(Test-DsProtectedPath -Path $protected)
        $result | Should Be $true
        (Test-DsProtectedPath -Path $env:TEMP) | Should Be $false
    }
}

# ---------- 系统体检 ----------
Describe '系统体检' {
    It '采集磁盘、内存与进程指标（只读）' {
        $h = Get-DsSystemHealth
        @($h.Drives).Count | Should BeGreaterThan 0
        $h.MemoryTotalMB | Should BeGreaterThan 0
        @($h.TopMemoryProcesses).Count | Should BeGreaterThan 0
        $h.Os | Should Not BeNullOrEmpty
    }

    It '每个磁盘都带完整字段，且恰好一个系统盘' {
        $h = Get-DsSystemHealth
        foreach ($d in $h.Drives) {
            $d.Letter | Should Not BeNullOrEmpty
            $d.TotalGB | Should BeGreaterThan 0
            $d.FreePercent | Should Not BeNullOrEmpty
        }
        @($h.Drives | Where-Object { $_.IsSystem }).Count | Should Be 1
    }

    It '隔离区统计：空隔离区为 0 条' {
        $fx = New-DsQFixture 'health-q'
        $null = Move-DsToQuarantine -Candidate $fx.Candidate -QuarantineRoot $fx.Root -Confirm:$false
        $h = Get-DsSystemHealth -QuarantineRoot $fx.Root
        $h.Quarantine.EntryCount | Should Be 1
        $h.Quarantine.ExpiredCount | Should Be 0
    }
}

# ---------- 优化建议 ----------
Describe '优化建议' {
    BeforeAll {
        $script:FakeHealth = [pscustomobject]@{
            Drives             = @([pscustomobject]@{ Letter = 'C:'; TotalGB = 500; FreeGB = 12; FreePercent = 2.4; IsSystem = $true })
            Disks              = @([pscustomobject]@{ Name = 'TestSSD'; SizeGB = 500; IsSsd = $true })
            MemoryTotalMB      = 8000
            MemoryFreeMB       = 1500
            StartupItems       = @(1..20 | ForEach-Object { [pscustomobject]@{ Name = "s$_"; Command = 'c'; Source = 'r' } })
            TopMemoryProcesses = @([pscustomobject]@{ Name = 'bigapp'; MemoryMB = 4000 })
            UptimeHours        = 200
            PowerPlan          = '节能'
            Os                 = 'Test'
            Quarantine         = [pscustomobject]@{ EntryCount = 2; TotalMB = 300; ExpiredCount = 1 }
        }
        $script:FakeCands = @(
            [pscustomobject]@{ Tier = 'P2'; SizeMB = 1500.0 },
            [pscustomobject]@{ Tier = 'P2'; SizeMB = 900.0 },
            [pscustomobject]@{ Tier = 'P1'; SizeMB = 500.0 }
        )
    }

    It '低磁盘 + 多项指标异常时给出多条建议，紧急项排最前' {
        $s = @(Get-DsOptimizationSuggestion -Health $script:FakeHealth -Candidate $script:FakeCands)
        $s.Count | Should BeGreaterThan 5
        $s[0].Id | Should Be 'disk-critical-system'
        $s[0].Severity | Should Be 'high'
        $s[0].ActionId | Should Be 'tab:cleanup'
    }

    It '覆盖各诊断维度' {
        $s = @(Get-DsOptimizationSuggestion -Health $script:FakeHealth -Candidate $script:FakeCands)
        $ids = @($s | ForEach-Object { $_.Id })
        'p2-cache-available' | Assert-Contained -In $ids
        'startup-heavy' | Assert-Contained -In $ids
        'process-heavy' | Assert-Contained -In $ids
        'memory-small' | Assert-Contained -In $ids
        'ssd-storagesense' | Assert-Contained -In $ids
        'powersaver-active' | Assert-Contained -In $ids
        'quarantine-expired' | Assert-Contained -In $ids
        'system-files-hint' | Assert-Contained -In $ids
    }

    It '磁盘充足且无异常时不出现紧急空间建议' {
        $calm = [pscustomobject]@{
            Drives             = @([pscustomobject]@{ Letter = 'C:'; TotalGB = 500; FreeGB = 200; FreePercent = 40; IsSystem = $true })
            Disks              = @([pscustomobject]@{ Name = 'TestSSD'; SizeGB = 500; IsSsd = $true })
            MemoryTotalMB      = 32768
            MemoryFreeMB       = 20000
            StartupItems       = @([pscustomobject]@{ Name = 'a'; Command = 'c'; Source = 'r' })
            TopMemoryProcesses = @([pscustomobject]@{ Name = 'small'; MemoryMB = 100 })
            UptimeHours        = 5
            PowerPlan          = '平衡'
            Os                 = 'Test'
            Quarantine         = $null
        }
        $s = @(Get-DsOptimizationSuggestion -Health $calm -Candidate @([pscustomobject]@{ Tier = 'P2'; SizeMB = 10.0 }))
        @($s | Where-Object { $_.Severity -eq 'high' }).Count | Should Be 0
        @($s | Where-Object { $_.Severity -eq 'warn' }).Count | Should Be 0
    }

    It '快捷操作白名单完整、无重复 id' {
        $cat = @(Get-DsQuickActionCatalog)
        $cat.Count | Should Be 16
        @($cat | ForEach-Object { $_.Id } | Sort-Object -Unique).Count | Should Be 16
    }

    It '快捷操作只允许系统工具与设置页' {
        foreach ($item in @(Get-DsQuickActionCatalog)) {
            $ok = ($item.FilePath -match '^(cleanmgr\.exe|taskmgr\.exe|msinfo32\.exe|powercfg\.cpl|appwiz\.cpl|ms-settings:.*|eventvwr\.msc|devmgmt\.msc|services\.msc|cmd\.exe)$')
            $ok | Should Be $true
        }
    }

    It '未知快捷操作被拒绝' {
        { Start-DsQuickAction -Action 'rmrf' -Confirm:$false } | Should Throw
    }

    It '白名单操作支持 -WhatIf（不真正启动，不抛异常）' {
        Start-DsQuickAction -Action 'taskmgr' -WhatIf *> $null
    }
}

# ---------- 定时任务 ----------
Describe '自动清理定时任务' {
    BeforeAll {
        # 清理可能残留的旧任务
        $s = Get-DsAutoPurgeStatus
        if ($s.Registered) {
            $null = Register-DsAutoPurge -QuarantineRoot $env:TEMP -Unregister -Confirm:$false
        }
    }

    It '默认未注册' {
        (Get-DsAutoPurgeStatus).Registered | Should Be $false
    }

    It '注册 → 查询 → 防重复 → 注销' {
        $q = Join-Path $script:TestRoot 'autopurge-q'
        $r = Register-DsAutoPurge -QuarantineRoot $q -RetentionDays 7 -DailyAt '04:15' -Confirm:$false
        $r.Registered | Should Be $true
        $r.DailyAt | Should Be '04:15'

        $s = Get-DsAutoPurgeStatus
        $s.Registered | Should Be $true
        $s.DailyAt | Should Be '04:15'

        $r2 = Register-DsAutoPurge -QuarantineRoot $q -Confirm:$false
        $r2.State | Should Be 'already-registered'

        $r3 = Register-DsAutoPurge -QuarantineRoot $q -Unregister -Confirm:$false
        $r3.Registered | Should Be $false
        (Get-DsAutoPurgeStatus).Registered | Should Be $false
    }
}

# ---------- 回归：既有核心命令 ----------
Describe '回归：库存 / 重复 / 报告 / 归属' {
    It 'Get-DsInventory 清点目录真实占用' {
        $dir = Join-Path $script:TestRoot 'inv'
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
        $bytes = New-Object byte[] 1048576
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'sub\a.bin'), $bytes)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'b.bin'), $bytes)

        $inv = @(Get-DsInventory -Path $dir)
        $inv.Count | Should Be 1
        $inv[0].FileCount | Should Be 2
        $inv[0].LengthMB | Should Be 2
        $inv[0].TopFolders.Count | Should BeGreaterThan 0
    }

    It 'Find-DsDuplicate 识别重复并计算可回收量' {
        $dir = Join-Path $script:TestRoot 'dup'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $bytes = New-Object byte[] 1048576
        for ($i = 0; $i -lt 100; $i++) { $bytes[$i] = [byte]$i }
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'x1.bin'), $bytes)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'x2.bin'), $bytes)
        $other = New-Object byte[] 1048576
        $other[0] = 255
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'y1.bin'), $other)

        $dups = @(Find-DsDuplicate -Path $dir -MinSize 1MB)
        $dups.Count | Should Be 1
        $dups[0].FileCount | Should Be 2
        $dups[0].ReclaimableMB | Should BeGreaterThan 0
    }

    It 'Get-DsOwnership 建立项目索引' {
        $proj = Join-Path $script:TestRoot 'proj'
        New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj 'package.json') -Value '{"name":"ds-proj"}'

        $ownership = Get-DsOwnership -ProjectRoot @($proj)
        @($ownership.Projects).Count | Should BeGreaterThan 0
        $ownNames = @($ownership.PSObject.Properties.Name)
        foreach ($n in @('Projects', 'Toolchains', 'GeneratedAt', 'ProjectRoots')) {
            $n | Assert-Contained -In $ownNames
        }
    }

    It 'New-DsReport 生成 HTML 报告' {
        $out = Join-Path $script:TestRoot 'report.html'
        $cand = New-DsTestCandidate -Name 'report-item' -Paths @($script:TestRoot)
        $null = New-DsReport -Candidate @($cand) -Duplicate @() -OutFile $out
        (Test-Path -LiteralPath $out) | Should Be $true
        $html = Get-Content -LiteralPath $out -Raw
        $html -match '<html' | Should Be $true
        $html -match 'report-item' | Should Be $true
    }

    # 最后一个 Describe 收尾时清理全部测试临时文件
    # （顶层 AfterAll 不被 Pester 3.4 支持，故放在这里）
    AfterAll {
        Remove-DsTestRoot
    }
}
