#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    # Stub the Microsoft Graph cmdlets so Mock can intercept them even when
    # the real Microsoft.Graph modules are not installed in the CI runner.
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

Describe 'Resolve-DevicePlatform' {
    It 'classifies Windows Server as Server (excluded)' {
        Resolve-DevicePlatform -OperatingSystem 'Windows Server 2022' | Should -Be 'Server'
    }

    It 'classifies WindowsServer (no space) as Server' {
        Resolve-DevicePlatform -OperatingSystem 'WindowsServer' | Should -Be 'Server'
    }

    It 'classifies plain Windows as Windows' {
        Resolve-DevicePlatform -OperatingSystem 'Windows' | Should -Be 'Windows'
    }

    It 'is case-insensitive' {
        Resolve-DevicePlatform -OperatingSystem 'wInDoWs' | Should -Be 'Windows'
    }

    It 'classifies iOS' {
        Resolve-DevicePlatform -OperatingSystem 'iOS' | Should -Be 'iOS'
    }

    It 'classifies Android' {
        Resolve-DevicePlatform -OperatingSystem 'Android' | Should -Be 'Android'
    }

    It 'classifies macOS as Unsupported' {
        Resolve-DevicePlatform -OperatingSystem 'macOS' | Should -Be 'Unsupported'
    }

    It 'classifies Linux as Unsupported' {
        Resolve-DevicePlatform -OperatingSystem 'Linux' | Should -Be 'Unsupported'
    }

    It 'classifies ChromeOS as Unsupported' {
        Resolve-DevicePlatform -OperatingSystem 'ChromeOS' | Should -Be 'Unsupported'
    }

    It 'classifies missing operating system as Unknown' {
        Resolve-DevicePlatform -OperatingSystem $null | Should -Be 'Unknown'
    }

    It 'classifies an unrecognized operating system as Unknown' {
        Resolve-DevicePlatform -OperatingSystem 'SomeMysteryOS' | Should -Be 'Unknown'
    }
}

Describe 'Get-StaleDeviceCandidates platform-based exclusions' {
    BeforeAll {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
    }

    It 'excludes Windows Server devices' {
        $device = New-TestEntraDevice -Id '1' -DeviceId 'd1' -DisplayName 'SRV01' -OperatingSystem 'Windows Server 2019' -ApproximateLastSignInDateTime (Get-Date).AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Excluded'
        $result[0].ReasonCode | Should -Be 'UnsupportedPlatform'
    }

    It 'routes missing operating system to manual review, never auto-delete' {
        $device = New-TestEntraDevice -Id '2' -DeviceId 'd2' -DisplayName 'UNKNOWN01' -OperatingSystem $null -ApproximateLastSignInDateTime (Get-Date).AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'ManualReview'
        $result[0].ReasonCode | Should -Be 'MissingOperatingSystem'
    }

    It 'excludes unsupported platforms (macOS)' {
        $device = New-TestEntraDevice -Id '3' -DeviceId 'd3' -DisplayName 'MAC01' -OperatingSystem 'macOS' -ApproximateLastSignInDateTime (Get-Date).AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Excluded'
        $result[0].ReasonCode | Should -Be 'UnsupportedPlatform'
    }

    It 'never performs Autopilot correlation for iOS devices' {
        $autopilot = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'd4'; ManagedDeviceId = $null; SerialNumber = 'SN1'; EnrollmentState = 'enrolled'; LastContactedDateTime = (Get-Date) }
        $idx = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @($autopilot)
        $device = New-TestEntraDevice -Id '4' -DeviceId 'd4' -DisplayName 'IPHONE01' -OperatingSystem 'iOS' -ApproximateLastSignInDateTime (Get-Date).AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $idx -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].AutopilotPresent | Should -Be $false
    }

    It 'never performs Autopilot correlation for Android devices' {
        $autopilot = [PSCustomObject]@{ Id = 'ap2'; AzureActiveDirectoryDeviceId = 'd5'; ManagedDeviceId = $null; SerialNumber = 'SN2'; EnrollmentState = 'enrolled'; LastContactedDateTime = (Get-Date) }
        $idx = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @($autopilot)
        $device = New-TestEntraDevice -Id '5' -DeviceId 'd5' -DisplayName 'ANDROID01' -OperatingSystem 'Android' -ApproximateLastSignInDateTime (Get-Date).AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $idx -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].AutopilotPresent | Should -Be $false
    }
}
