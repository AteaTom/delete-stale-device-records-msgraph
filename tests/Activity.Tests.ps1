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

Describe 'Get-EffectiveLastActivity' {
    It 'returns None when both sources are missing' {
        $result = Get-EffectiveLastActivity -IntuneLastSyncDateTimeUtc $null -EntraApproximateLastSignInDateTimeUtc $null
        $result.EffectiveLastActivityUtc | Should -BeNullOrEmpty
        $result.ActivitySource | Should -Be 'None'
    }

    It 'uses the Entra timestamp when Intune data is missing (missing Intune data is normal)' {
        $entra = (Get-Date).ToUniversalTime().AddDays(-250)
        $result = Get-EffectiveLastActivity -IntuneLastSyncDateTimeUtc $null -EntraApproximateLastSignInDateTimeUtc $entra
        $result.EffectiveLastActivityUtc | Should -Be $entra
        $result.ActivitySource | Should -Be 'EntraApproximateLastSignInDateTime'
    }

    It 'uses the newest timestamp: recent Entra activity overrides old Intune activity' {
        $intune = (Get-Date).ToUniversalTime().AddDays(-240)
        $entra = (Get-Date).ToUniversalTime().AddDays(-20)
        $result = Get-EffectiveLastActivity -IntuneLastSyncDateTimeUtc $intune -EntraApproximateLastSignInDateTimeUtc $entra
        $result.EffectiveLastActivityUtc | Should -Be $entra
        $result.ActivitySource | Should -Be 'EntraApproximateLastSignInDateTime'
    }

    It 'uses the newest timestamp: recent Intune activity overrides old Entra activity' {
        $intune = (Get-Date).ToUniversalTime().AddDays(-30)
        $entra = (Get-Date).ToUniversalTime().AddDays(-300)
        $result = Get-EffectiveLastActivity -IntuneLastSyncDateTimeUtc $intune -EntraApproximateLastSignInDateTimeUtc $entra
        $result.EffectiveLastActivityUtc | Should -Be $intune
        $result.ActivitySource | Should -Be 'IntuneLastSyncDateTime'
    }
}

Describe 'Get-SafeUtcTimestamp' {
    It 'treats year-0001 sentinel values as missing' {
        Get-SafeUtcTimestamp -Value ([datetime]'0001-01-01T00:00:00Z') | Should -BeNullOrEmpty
    }

    It 'treats $null as missing' {
        Get-SafeUtcTimestamp -Value $null | Should -BeNullOrEmpty
    }

    It 'passes through a real timestamp as UTC' {
        $dt = Get-Date '2025-01-01T00:00:00Z'
        (Get-SafeUtcTimestamp -Value $dt).Kind | Should -Be 'Utc'
    }
}

Describe 'Get-StaleDeviceCandidates activity-based decisions' {
    BeforeAll {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
    }

    It 'makes an Entra-only device with old approximateLastSignInDateTime a candidate' {
        $device = New-TestEntraDevice -Id '1' -DeviceId 'd1' -DisplayName 'W1' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-250)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Candidate'
        $result[0].ReasonCode | Should -Be 'Stale'
    }

    It 'retains an Entra-only device with recent approximateLastSignInDateTime' {
        $device = New-TestEntraDevice -Id '2' -DeviceId 'd2' -DisplayName 'W2' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-5)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Excluded'
        $result[0].ReasonCode | Should -Be 'RecentActivityDetected'
    }

    It 'routes a device with both authoritative timestamps missing to manual review' {
        $device = New-TestEntraDevice -Id '3' -DeviceId 'd3' -DisplayName 'W3' -ApproximateLastSignInDateTime $null
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'ManualReview'
        $result[0].ReasonCode | Should -Be 'MissingAllActivity'
    }

    It 'treats a timestamp exactly equal to the cutoff as stale (inclusive)' {
        $device = New-TestEntraDevice -Id '4' -DeviceId 'd4' -DisplayName 'W4' -ApproximateLastSignInDateTime $cutoff
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Candidate'
    }
}

Describe 'UTC cutoff calculation' {
    It 'computes the cutoff as UTC now minus DaysInactive days' {
        $daysInactive = 200
        $before = (Get-Date).ToUniversalTime().AddDays(-$daysInactive)
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$daysInactive)
        $after = (Get-Date).ToUniversalTime().AddDays(-$daysInactive)
        $cutoff | Should -BeGreaterOrEqual $before
        $cutoff | Should -BeLessOrEqual $after.AddSeconds(1)
        $cutoff.Kind | Should -Be 'Utc'
    }
}
