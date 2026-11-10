@{
    RootModule        = 'DriveSift.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'a3f7c4e2-9b18-4d57-8c6a-5e2f1b90d4a7'
    Author            = 'DriveSift contributors'
    CompanyName       = 'DriveSift'
    Copyright         = '(c) DriveSift contributors. MIT License.'
    Description       = 'Windows disk audit that proves ownership before deletion; quarantines instead of deleting, with 7-day retention, content relevance checks, system health suggestions and quick actions.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('disk', 'cleanup', 'windows', 'audit', 'dedupe')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/DriveSift/DriveSift'
        }
    }
}
