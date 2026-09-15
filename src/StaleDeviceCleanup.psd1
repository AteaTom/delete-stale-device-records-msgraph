@{
    RootModule        = 'StaleDeviceCleanup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a6e2f7c4-9b3d-4e2a-8f1b-6c7d8e9f0a1b'
    Author            = 'Repository owner'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) Repository owner. All rights reserved.'
    Description       = 'Discovery, correlation, and safe deletion helpers for identifying stale Microsoft Entra ID and Windows Autopilot device records.'
    PowerShellVersion = '7.0'

    RequiredModules   = @()

    FunctionsToExport = @(
        'Write-CleanupLog',
        'Test-Prerequisites',
        'Connect-DeviceCleanupGraph',
        'Test-GraphPermissions',
        'Invoke-GraphWithRetry',
        'Get-EntraDeviceRecords',
        'Get-IntuneManagedDeviceRecords',
        'Get-WindowsAutopilotRecords',
        'ConvertTo-NormalizedSerialNumber',
        'Get-SafeUtcTimestamp',
        'Resolve-DevicePlatform',
        'New-DeviceIndexes',
        'Resolve-DeviceCorrelation',
        'Get-EffectiveLastActivity',
        'Test-DeviceProtection',
        'Get-StaleDeviceCandidates',
        'Show-CleanupSummary',
        'Show-ScrappedDeviceSummary',
        'Request-DeletionConfirmation',
        'Export-ReportCsv',
        'Get-DeviceLifecycleState',
        'Save-DeviceLifecycleState',
        'Export-CleanupReports',
        'New-RunSummary',
        'Get-ScrappedDeviceSerialNumbers',
        'Resolve-ScrappedDeviceRecords',
        'Disable-EntraDeviceRecord',
        'Remove-WindowsAutopilotRecord',
        'Wait-WindowsAutopilotRemoval',
        'Remove-EntraDeviceRecord',
        'Remove-IntuneManagedDeviceRecord',
        'Invoke-ScrappedDeviceRemoval',
        'Initialize-ProjectExecution',
        'Complete-ProjectExecution'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('MicrosoftGraph', 'Intune', 'Autopilot', 'EntraID', 'DeviceManagement')
            ProjectUri = ''
        }
    }
}
