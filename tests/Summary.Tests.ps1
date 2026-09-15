#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Connect-MgGraph { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) }
    function global:Get-MgContext { }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }

    $modulePath = Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1'
    Import-Module $modulePath -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Export-CleanupReports' {
    BeforeEach {
        $script:testOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "sdc-test-$(New-Guid)"
        New-Item -Path $script:testOutputPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Path $script:testOutputPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes all required report files even when there are no candidates' {
        Export-CleanupReports -AllEvaluatedDevices @() -OutputPath $script:testOutputPath

        $expectedFiles = @(
            'AllEvaluatedDevices.csv', 'DeletionCandidates.csv', 'DeletedDevices.csv',
            'UnknownDevices.csv', 'AmbiguousMatches.csv', 'ExcludedDevices.csv', 'ErrorDevices.csv'
        )
        foreach ($file in $expectedFiles) {
            Test-Path (Join-Path $script:testOutputPath $file) | Should -Be $true
        }
    }

    It 'writes DeletionCandidates.csv containing only Candidate-decision rows' {
        $devices = @(
            [PSCustomObject]@{ RunId = 'r1'; Decision = 'Candidate'; MatchStatus = 'Unmatched'; ErrorMessage = $null; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; DeviceName = 'A' }
            [PSCustomObject]@{ RunId = 'r1'; Decision = 'Excluded'; MatchStatus = 'Unmatched'; ErrorMessage = $null; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; DeviceName = 'B' }
        )
        Export-CleanupReports -AllEvaluatedDevices $devices -OutputPath $script:testOutputPath
        $candidates = Import-Csv (Join-Path $script:testOutputPath 'DeletionCandidates.csv')
        $candidates.Count | Should -Be 1
        $candidates[0].DeviceName | Should -Be 'A'
    }
}

Describe 'New-RunSummary' {
    It 'produces the expected count fields' {
        $devices = @(
            [PSCustomObject]@{ Decision = 'Candidate'; EntraRemovalStatus = 'Removed'; AutopilotRemovalStatus = 'Removed'; ErrorMessage = $null }
            [PSCustomObject]@{ Decision = 'Excluded'; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; ErrorMessage = $null }
            [PSCustomObject]@{ Decision = 'ManualReview'; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; ErrorMessage = 'oops' }
        )
        $summary = New-RunSummary -RunId 'r1' -Mode 'Audit' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices $devices

        $summary.TotalEvaluated | Should -Be 3
        $summary.TotalCandidates | Should -Be 1
        $summary.TotalExcluded | Should -Be 1
        $summary.TotalManualReview | Should -Be 1
        $summary.TotalEntraDevicesRemoved | Should -Be 1
        $summary.TotalErrors | Should -Be 1
    }

    It 'counts an AlreadyRemoved Autopilot identity as removed' {
        $device = [PSCustomObject]@{
            Decision = 'Candidate'
            EntraRemovalStatus = 'Removed'
            AutopilotRemovalStatus = 'AlreadyRemoved'
            ErrorMessage = $null
        }
        $summary = New-RunSummary -RunId 'r2' -Mode 'Interactive' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @($device)

        $summary.TotalEntraDevicesRemoved | Should -Be 1
        $summary.TotalAutopilotRemoved | Should -Be 1
    }
}

Describe 'AllEvaluatedDevices.csv required fields' {
    It 'includes the required evaluated-device columns' {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
        $device = New-TestEntraDevice -Id '1' -DeviceId 'd1' -DisplayName 'W1' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-250)
        $eval = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'

        $requiredFields = @(
            'RunId', 'EvaluationTimestampUtc', 'DeviceName', 'Platform', 'EntraObjectId', 'EntraDeviceId',
            'IntunePresent', 'AutopilotPresent', 'EffectiveLastActivityUtc', 'ActivitySource', 'DaysInactive',
            'CutoffDateUtc', 'MatchStatus', 'MatchMethod', 'MatchConfidence', 'Decision', 'ReasonCode',
            'ReasonDescription', 'AutopilotRemovalStatus', 'EntraRemovalStatus', 'ErrorMessage'
        )
        $properties = $eval[0].PSObject.Properties.Name
        foreach ($field in $requiredFields) {
            $properties | Should -Contain $field
        }
    }
}
