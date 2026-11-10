$script:ModuleRoot = $PSScriptRoot
$script:RulesPath  = Join-Path $script:ModuleRoot 'rules\rules.json'

foreach ($folder in @('Private', 'Public')) {
    $dir = Join-Path $script:ModuleRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File |
        Sort-Object Name |
        ForEach-Object { . $_.FullName }
}

Export-ModuleMember -Function @(
    'Invoke-DsAudit',
    'Get-DsInventory',
    'Get-DsOwnership',
    'Find-DsDuplicate',
    'Get-DsCandidate',
    'Get-DsRuleSet',
    'New-DsReport',
    'Move-DsToQuarantine',
    'Restore-DsQuarantine',
    'Get-DsQuarantine',
    'Remove-DsQuarantine',
    'Get-DsSystemHealth',
    'Get-DsOptimizationSuggestion',
    'Get-DsQuickActionCatalog',
    'Start-DsQuickAction',
    'Get-DsAutoPurgeStatus',
    'Register-DsAutoPurge'
)
