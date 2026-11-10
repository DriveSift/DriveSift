# 内容相关性检查：在规则"说"这个目录是缓存之前，先看里面"实际"装了什么。
# 只按扩展名分类，不读文件内容——快、无副作用，且足以拦截"目录里混着个人文件"这类误判。
#
# 分类设计：
#   默认可疑（suspicious）：docs / photos / media / source / archive / data / keys
#   中性（neutral）：web / text / package / crash / model / other
# 规则可以用 allowContent 白名单把某些类别声明为"本规则下正常"
# （例如 npm 缓存里出现 .tgz 与 .js 是应当的，浏览器缓存里出现图片也是应当的）。
# 只要抽样中出现未白名单的可疑文件，候选就从 P2 降为 P1，并给出示例路径。

$script:DsContentMap = @{
    # 文档：个人文档，出现在缓存里几乎总是误判信号
    docs = @('.doc', '.docx', '.docm', '.dotx', '.xls', '.xlsx', '.xlsm', '.xltm', '.ppt', '.pptx', '.pptm',
        '.odt', '.ods', '.odp', '.pdf', '.rtf', '.pages', '.numbers', '.key')
    photos = @('.jpg', '.jpeg', '.jpe', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif',
        '.raw', '.cr2', '.cr3', '.nef', '.arw', '.dng', '.psd', '.ai', '.sketch', '.fig', '.xcf')
    media = @('.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.oga', '.opus', '.wma',
        '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.flv', '.webm', '.mpg', '.mpeg')
    source = @('.cs', '.py', '.pyi', '.js', '.jsx', '.ts', '.tsx', '.vue', '.svelte', '.mjs',
        '.rs', '.go', '.java', '.kt', '.kts', '.swift', '.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx',
        '.m', '.mm', '.sh', '.bash', '.ps1', '.psm1', '.psd1', '.ps1xml', '.rb', '.php', '.lua', '.pl',
        '.sql', '.asm', '.f', '.f90', '.tex')
    # 压缩包 / 磁盘镜像：内容不可知，一律按可疑处理（规则可白名单，如 npm 缓存的 .tgz）
    archive = @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst', '.iso', '.cab',
        '.jar', '.war', '.ear', '.nupkg', '.whl', '.crate', '.klib', '.vhd', '.vhdx', '.img')
    data = @('.db', '.sqlite', '.sqlite3', '.mdb', '.accdb', '.vscdb', '.sdf', '.frd')
    secrets = @('.p12', '.pfx', '.pem', '.key', '.keystore', '.jks', '.p7b')
    # —— 以下为中性类别 ——
    web = @('.html', '.htm', '.css', '.json', '.xml', '.svg', '.mjs', '.woff', '.woff2', '.ttf', '.otf',
        '.eot', '.ico', '.map', '.webmanifest', '.plist', '.yaml', '.yml', '.ini', '.toml', '.cfg', '.conf')
    text = @('.txt', '.log', '.md', '.csv', '.tsv', '.err', '.out')
    package = @('.dll', '.exe', '.sys', '.msi', '.msp', '.bin', '.dat', '.pyc', '.rlib', '.pdb', '.lib',
        '.obj', '.o', '.a', '.so', '.dylib', '.vsix', '.appx', '.msix', '.pak', '.so', '.kext', '.appbundle')
    crash = @('.dmp', '.mdmp', '.minidump', '.crash')
    model = @('.safetensors', '.gguf', '.onnx', '.tflite', '.engine', '.h5', '.hdf5', '.pth', '.pt',
        '.ckpt', '.pb', '.tfevents', '.arrow')
}

$script:DsContentNames = @{
    docs = '文档'; photos = '图片'; media = '音视频'; source = '源码'; archive = '压缩包'
    data = '数据库'; secrets = '密钥'; web = '网页资源'; text = '文本'; package = '程序/二进制'
    crash = '崩溃转储'; model = '模型权重'; other = '其他'
}

# 默认视为"混入即可疑"的类别（其余类别是缓存的正常成分）
$script:DsSuspiciousCategories = @('docs', 'photos', 'media', 'source', 'archive', 'data', 'secrets')

# 扩展名 → 类别 的倒排表，避免每次分类都扫整张映射
$script:DsExtensionCategory = @{}
foreach ($category in $script:DsContentMap.Keys) {
    foreach ($ext in $script:DsContentMap[$category]) {
        # 后写入的类别让位给先定义的：docs/photos 等可疑类别优先声明，避免 .key 之类的重叠被中性类别吃掉
        if (-not $script:DsExtensionCategory.ContainsKey($ext)) {
            $script:DsExtensionCategory[$ext] = $category
        }
    }
}

function Get-DsExtensionCategory {
    [CmdletBinding()]
    param([string]$Extension)

    if (-not $Extension) { return 'other' }
    $ext = $Extension.ToLowerInvariant()
    if ($ext -notmatch '^\.[a-z0-9]{1,8}$') {
        # 无扩展名或过长（内容寻址文件名）一律按其他处理
        if ($ext.Length -lt 2) { return 'other' }
        $ext = [System.IO.Path]::GetExtension($Extension).ToLowerInvariant()
        if (-not $ext) { return 'other' }
    }
    if ($script:DsExtensionCategory.ContainsKey($ext)) { return $script:DsExtensionCategory[$ext] }
    return 'other'
}

function Get-DsContentProfile {
    <#
    .SYNOPSIS
        对候选路径做内容抽样画像，找出与"纯缓存"假设不符的文件。
    .DESCRIPTION
        最多扫描 SampleLimit 个文件（按枚举顺序，截断会如实标注），只读扩展名不读内容。
        返回可疑文件计数、类别构成与示例路径；规则允许通过的类别经 -Allow 传入。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$Allow = @(),
        [int]$SampleLimit = 5000
    )

    $result = [pscustomobject]@{
        Path              = $Path
        CheckedFiles      = 0
        Truncated         = $false
        CategoryCounts    = [ordered]@{}
        SuspiciousCount   = 0
        SuspiciousKinds   = ''
        SuspiciousSamples = @()
        TopCategories     = ''
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $records = @(Invoke-DsWalk -Path $Path)
    if ($records.Count -gt $SampleLimit) {
        $records = @($records | Select-Object -First $SampleLimit)
        $result.Truncated = $true
    }
    $result.CheckedFiles = $records.Count

    $counts = @{}
    $samples = @{}
    foreach ($r in $records) {
        $category = Get-DsExtensionCategory -Extension ([System.IO.Path]::GetExtension($r.Path))
        if (-not $counts.ContainsKey($category)) { $counts[$category] = 0 }
        $counts[$category]++

        if ($script:DsSuspiciousCategories -contains $category -and $Allow -notcontains $category) {
            if (-not $samples.ContainsKey($category)) { $samples[$category] = New-Object System.Collections.ArrayList }
            if ($samples[$category].Count -lt 5) { [void]$samples[$category].Add($r.Path) }
            $result.SuspiciousCount++
        }
    }

    foreach ($category in $counts.Keys) {
        $result.CategoryCounts[$category] = $counts[$category]
    }

    if ($result.SuspiciousCount -gt 0) {
        $kinds = @()
        $allSamples = New-Object System.Collections.ArrayList
        # 按数量降序列出可疑类别，示例路径随之展示
        foreach ($category in ($samples.Keys | Sort-Object { -($counts[$category]) })) {
            $kinds += ('{0}×{1}' -f $script:DsContentNames[$category], $counts[$category])
            foreach ($sample in $samples[$category]) {
                if ($allSamples.Count -lt 5) { [void]$allSamples.Add("$sample  （$($script:DsContentNames[$category])）") }
            }
        }
        $result.SuspiciousKinds = $kinds -join '、'
        $result.SuspiciousSamples = @($allSamples)
    }

    $top = $counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3
    $result.TopCategories = @($top | ForEach-Object {
        ('{0}×{1}' -f $script:DsContentNames[$_.Key], $_.Value)
    }) -join '、'

    $result
}
