# 项目索引与工具链索引：把"这个目录是谁的"变成可计算的关系。

function Get-DsSubDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [int]$MaxDepth = 4
    )

    # 跳过产物与依赖目录，否则一次索引会把整个 node_modules 走一遍
    $skipNames = @(
        'node_modules', '.git', '.svn', '.hg', 'dist', 'build', 'out', 'target',
        'vendor', '.venv', 'venv', '__pycache__', '.next', '.nuxt', '.gradle',
        'obj', 'coverage', '.cache', '.turbo', '.idea', '.vs'
    )

    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, 0))

    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $dir = [string]$entry[0]
        $depth = [int]$entry[1]
        [void]$list.Add($dir)

        if ($depth -ge $MaxDepth) { continue }

        try {
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $name = (Split-Path -Leaf $child).ToLowerInvariant()
                    if ($skipNames -contains $name) { continue }
                    $attr = [System.IO.File]::GetAttributes($child)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push(@($child, $depth + 1))
                }
                catch { }
            }
        }
        catch { }
    }

    return $list
}

function Get-DsProjectIndex {
    [CmdletBinding()]
    param(
        [string[]]$Root,
        [int]$MaxDepth = 4,
        [switch]$IncludeGitStatus
    )

    $markers = @(
        @{ Name = 'package.json';      Kind = 'node' },
        @{ Name = 'pyproject.toml';    Kind = 'python' },
        @{ Name = 'requirements.txt';  Kind = 'python' },
        @{ Name = 'Cargo.toml';        Kind = 'rust' },
        @{ Name = 'go.mod';            Kind = 'go' },
        @{ Name = 'pubspec.yaml';      Kind = 'flutter' },
        @{ Name = 'pom.xml';           Kind = 'java' },
        @{ Name = 'build.gradle';      Kind = 'java' },
        @{ Name = 'build.gradle.kts';  Kind = 'java' },
        @{ Name = 'global.json';       Kind = 'dotnet' },
        @{ Name = '*.sln';             Kind = 'dotnet' }
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    $projects = New-Object System.Collections.ArrayList

    foreach ($rootPath in $Root) {
        if (-not (Test-Path -LiteralPath $rootPath)) { continue }

        foreach ($dir in (Get-DsSubDirectory -Root ([string]$rootPath) -MaxDepth $MaxDepth)) {
            $full = [string]$dir
            $kinds = @()
            $found = @()

            foreach ($marker in $markers) {
                $candidate = Join-Path $full $marker.Name
                if (Test-Path -Path $candidate) {
                    $kinds += $marker.Kind
                    $found += $marker.Name
                }
            }

            if ($kinds.Count -eq 0) { continue }

            $refs = [ordered]@{}
            $nvmrc = Join-Path $full '.nvmrc'
            if (Test-Path -LiteralPath $nvmrc) {
                $refs.Node = (Get-Content -LiteralPath $nvmrc -Raw -ErrorAction SilentlyContinue).Trim()
            }
            $nodeVersion = Join-Path $full '.node-version'
            if (Test-Path -LiteralPath $nodeVersion) {
                $refs.Node = (Get-Content -LiteralPath $nodeVersion -Raw -ErrorAction SilentlyContinue).Trim()
            }
            $pyvenv = Join-Path $full 'pyvenv.cfg'
            if (Test-Path -LiteralPath $pyvenv) {
                $homeLine = Get-Content -LiteralPath $pyvenv -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^\s*home\s*=' } |
                    Select-Object -First 1
                if ($homeLine) {
                    $refs.Python = ($homeLine -split '=', 2)[1].Trim()
                }
            }
            foreach ($rustFile in @('rust-toolchain', 'rust-toolchain.toml')) {
                $candidate = Join-Path $full $rustFile
                if (Test-Path -LiteralPath $candidate) {
                    $refs.Rust = (Get-Content -LiteralPath $candidate -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match 'channel' -or $_ -match '^[0-9]' } |
                        Select-Object -First 1)
                }
            }
            $globalJson = Join-Path $full 'global.json'
            if (Test-Path -LiteralPath $globalJson) {
                try {
                    $parsed = Get-Content -LiteralPath $globalJson -Raw | ConvertFrom-Json
                    if ($parsed.sdk) { $refs.DotNet = [string]$parsed.sdk.version }
                }
                catch { }
            }

            $lastWrite = $null
            try { $lastWrite = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc } catch { }

            $dirty = $null
            if ($IncludeGitStatus -and $git) {
                try {
                    $status = & $git.Source -C $full status --porcelain --untracked-files=no 2>$null
                    if ($status) { $dirty = $true } else { $dirty = $false }
                }
                catch { }
            }

            [void]$projects.Add([pscustomobject]@{
                Path       = $full
                Name       = (Split-Path -Leaf $full)
                Kind       = (($kinds | Sort-Object -Unique) -join ', ')
                Markers    = $found
                RuntimeRefs = [pscustomobject]$refs
                LastWriteUtc = $lastWrite
                Dirty      = $dirty
            })
        }
    }

    return $projects
}

function Get-DsToolchainIndex {
    [CmdletBinding()]
    param([object[]]$Projects)

    $list = New-Object System.Collections.ArrayList
    $projects = @($Projects)

    # Rust：每个 toolchain 目录就是一个候选；default / 被项目引用 = 仍在用
    $rustRoot = Join-Path $env:USERPROFILE '.rustup\toolchains'
    if (Test-Path -LiteralPath $rustRoot) {
        $defaultName = $null
        # 先读 settings.toml（最可靠），再从 rustup 输出兜底（不同版本的标记文案不同）
        $settingsPath = Join-Path $env:USERPROFILE '.rustup\settings.toml'
        if (Test-Path -LiteralPath $settingsPath) {
            $defaultLine = Get-Content -LiteralPath $settingsPath -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*default_toolchain\s*=' } |
                Select-Object -First 1
            if ($defaultLine) {
                $defaultName = (($defaultLine -split '=', 2)[1]).Trim().Trim('"')
            }
        }

        if (-not $defaultName) {
            $rustup = Get-Command rustup -ErrorAction SilentlyContinue
            if ($rustup) {
                try {
                    $lines = & $rustup.Source toolchain list 2>$null
                    foreach ($line in $lines) {
                        if ($line -match '\(\s*[^)]*default') { $defaultName = ($line -replace '\s*\(.*$', '').Trim() }
                    }
                }
                catch { }
            }
        }

        # 无法确认默认工具链时，保守地把全部工具链视为"在用"，避免误删活动环境
        $defaultUnknown = (-not $defaultName)

        foreach ($dir in (Get-ChildItem -LiteralPath $rustRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $refs = @($projects | Where-Object {
                $_.RuntimeRefs -and $_.RuntimeRefs.PSObject.Properties.Name -contains 'Rust' -and
                $_.RuntimeRefs.Rust -and ($dir.Name -like ($_.RuntimeRefs.Rust + '*'))
            } | ForEach-Object { $_.Name })

            [void]$list.Add([pscustomobject]@{
                Kind         = 'rust'
                Name         = $dir.Name
                Version      = ($dir.Name -split '-', 2)[0]
                Path         = $dir.FullName
                IsDefault    = ($defaultUnknown -or ($defaultName -and $dir.Name -eq $defaultName))
                DefaultUncertain = $defaultUnknown
                ReferencedBy = $refs
                SizeMB       = $null
            })
        }
    }

    # Python：解释器安装目录；被 venv 的 pyvenv.cfg 指向、或在 PATH 首位 = 仍在用
    $pyRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    $pathPython = $null
    $where = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($where) {
        try { $pathPython = (& $where.Source python 2>$null | Select-Object -First 1) } catch { }
    }

    if (Test-Path -LiteralPath $pyRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $pyRoot -Directory -Filter 'Python*' -Force -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $dir.FullName 'python.exe'
            $isDefault = $false
            if ($pathPython -and $pathPython.ToLowerInvariant() -eq $exe.ToLowerInvariant()) { $isDefault = $true }

            $refs = @($projects | Where-Object {
                $_.RuntimeRefs -and $_.RuntimeRefs.PSObject.Properties.Name -contains 'Python' -and
                $_.RuntimeRefs.Python -and $_.RuntimeRefs.Python.ToLowerInvariant() -like ($dir.FullName.ToLowerInvariant() + '*')
            } | ForEach-Object { $_.Name })

            [void]$list.Add([pscustomobject]@{
                Kind         = 'python'
                Name         = $dir.Name
                Version      = ($dir.Name -replace '^Python', '')
                Path         = $dir.FullName
                IsDefault    = $isDefault
                ReferencedBy = $refs
                SizeMB       = $null
            })
        }
    }

    # Node：只记录当前 PATH 上的版本；nvm/fnm 多版本目录在存在时一并列出
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $version = $null
        try { $version = (& $node.Source -v 2>$null) } catch { }
        $nodeDir = Split-Path -Parent $node.Source
        $refs = @($projects | Where-Object {
            $_.RuntimeRefs -and $_.RuntimeRefs.PSObject.Properties.Name -contains 'Node' -and $_.RuntimeRefs.Node
        } | ForEach-Object { $_.Name })

        [void]$list.Add([pscustomobject]@{
            Kind         = 'node'
            Name         = "node $version"
            Version      = $version
            Path         = $nodeDir
            IsDefault    = $true
            ReferencedBy = $refs
            SizeMB       = $null
        })
    }

    foreach ($nvmDir in @((Join-Path $env:APPDATA 'nvm'), (Join-Path $env:LOCALAPPDATA 'fnm_multishells')) ) {
        if (-not (Test-Path -LiteralPath $nvmDir)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $nvmDir -Directory -Force -ErrorAction SilentlyContinue)) {
            [void]$list.Add([pscustomobject]@{
                Kind         = 'node'
                Name         = $dir.Name
                Version      = $dir.Name
                Path         = $dir.FullName
                IsDefault    = $false
                ReferencedBy = @()
                SizeMB       = $null
            })
        }
    }

    return $list
}

function Test-DsToolchainReference {
    [CmdletBinding()]
    param(
        [string]$Path,
        [object[]]$Toolchains
    )

    $referenced = $false
    $by = New-Object System.Collections.ArrayList

    if (-not $Toolchains) {
        return [pscustomobject]@{ Referenced = $false; By = @() }
    }

    $normalized = $Path.TrimEnd('\').ToLowerInvariant()

    foreach ($tc in $Toolchains) {
        if (-not $tc.Path) { continue }
        $tcPath = $tc.Path.TrimEnd('\').ToLowerInvariant()
        if (-not ($normalized -eq $tcPath -or $normalized -like ($tcPath + '\*'))) { continue }

        if ($tc.IsDefault) {
            if ($tc.PSObject.Properties.Name -contains 'DefaultUncertain' -and $tc.DefaultUncertain) {
                [void]$by.Add('默认工具链未知')
            }
            else {
                [void]$by.Add('当前默认')
            }
            $referenced = $true
        }
        foreach ($project in @($tc.ReferencedBy)) {
            if ($project) {
                [void]$by.Add("项目 $project")
                $referenced = $true
            }
        }
        break
    }

    [pscustomobject]@{
        Referenced = $referenced
        By         = @($by | Sort-Object -Unique)
    }
}
