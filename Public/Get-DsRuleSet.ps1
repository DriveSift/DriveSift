function Get-DsRuleSet {
    <#
    .SYNOPSIS
        读取并校验清理规则集。
    .DESCRIPTION
        规则是纯数据（rules/rules.json），不含可执行代码，便于开源协作与审计。
        tier: P0 禁删 / P1 需确认 / P2 可处理；unit: path 整个目录，child 逐个子项。
    #>
    [CmdletBinding()]
    param(
        [string]$Path = $script:RulesPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "规则文件不存在: $Path"
    }

    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $data.rules) {
        throw "规则文件格式不正确，缺少 rules 数组: $Path"
    }
    if ($data.version -and $data.version -ne 2) {
        Write-Warning "规则版本 $($data.version) 未经本模块验证，行为可能不一致。"
    }

    $knownCategories = @('docs', 'photos', 'media', 'source', 'archive', 'data', 'secrets',
        'web', 'text', 'package', 'crash', 'model')

    foreach ($rule in $data.rules) {
        $unit = 'path'
        if ($rule.PSObject.Properties.Name -contains 'unit' -and $rule.unit) {
            $unit = [string]$rule.unit
        }

        $aggregate = $false
        if ($rule.PSObject.Properties.Name -contains 'aggregate' -and $rule.aggregate) {
            $aggregate = [bool]$rule.aggregate
        }

        $allowContent = @()
        if ($rule.PSObject.Properties.Name -contains 'allowContent') {
            foreach ($category in @($rule.allowContent)) {
                if ($knownCategories -contains [string]$category) { $allowContent += [string]$category }
                else { Write-Warning "规则 $($rule.id) 的 allowContent 含未知类别: $category（已忽略）" }
            }
        }

        [pscustomobject]@{
            Id           = [string]$rule.id
            Name         = [string]$rule.name
            Category     = [string]$rule.category
            Owner        = [string]$rule.owner
            Tier         = [string]$rule.tier
            Unit         = $unit
            Aggregate    = $aggregate
            Paths        = @($rule.paths)
            Guards       = @($rule.guards)
            AllowContent = $allowContent
            Rebuild      = [string]$rule.rebuild
            Notes        = [string]$rule.notes
        }
    }
}
