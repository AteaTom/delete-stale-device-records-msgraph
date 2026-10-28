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

Describe 'Test-DeviceProtection' {
    It 'protects a device whose Entra object id is in the protected list' {
        $device = [PSCustomObject]@{ Id = 'obj-1'; DeviceId = 'dev-1'; DisplayName = 'ANY' }
        $result = Test-DeviceProtection -Device $device -ProtectedEntraObjectIds @('obj-1')
        $result.IsProtected | Should -Be $true
    }

    It 'protects a device whose serial number is in the protected list (normalized)' {
        $device = [PSCustomObject]@{ Id = 'obj-2'; DeviceId = 'dev-2'; DisplayName = 'ANY2' }
        $result = Test-DeviceProtection -Device $device -IntuneSerialNumber '  Serial123  ' -ProtectedSerialNumbers @('serial123')
        $result.IsProtected | Should -Be $true
    }

    It 'protects a device whose name matches a protected wildcard pattern' {
        $device = [PSCustomObject]@{ Id = 'obj-3'; DeviceId = 'dev-3'; DisplayName = 'BREAKGLASS-ADMIN01' }
        $result = Test-DeviceProtection -Device $device -ProtectedNamePatterns @('BREAKGLASS-*')
        $result.IsProtected | Should -Be $true
    }

    It 'does not protect an unrelated device' {
        $device = [PSCustomObject]@{ Id = 'obj-4'; DeviceId = 'dev-4'; DisplayName = 'NORMAL-DEVICE' }
        $result = Test-DeviceProtection -Device $device -ProtectedNamePatterns @('BREAKGLASS-*') -ProtectedEntraObjectIds @('obj-1')
        $result.IsProtected | Should -Be $false
    }

    It 'protects a device whose name matches a wildcard pattern loaded from the ProtectedDeviceIdFile DeviceName column' {
        $device = [PSCustomObject]@{ Id = 'obj-5'; DeviceId = 'dev-5'; DisplayName = 'PAW-CEO-LAPTOP' }
        $result = Test-DeviceProtection -Device $device -ProtectedDeviceNames @('PAW*')
        $result.IsProtected | Should -Be $true
    }

    It 'reuses indexed case-insensitive ID, serial, literal-name, and wildcard lookups' {
        $index = InModuleScope StaleDeviceCleanup {
            New-DeviceProtectionIndex -ProtectedEntraObjectIds @('OBJECT-1') `
                -ProtectedEntraDeviceIds @('DEVICE-1') -ProtectedSerialNumbers @(' Serial123 ') `
                -ProtectedDeviceNames @('Literal-device', 'CSV-*') -ProtectedNamePatterns @('Explicit-*')
        }

        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = 'object-1'; DeviceId = $null; DisplayName = $null }) -ProtectionIndex $index).IsProtected | Should -BeTrue
        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = $null; DeviceId = 'device-1'; DisplayName = $null }) -ProtectionIndex $index).IsProtected | Should -BeTrue
        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = $null; DeviceId = $null; DisplayName = 'LITERAL-DEVICE' }) -ProtectionIndex $index).Reason |
            Should -Be 'Device name matches the protected device list.'
        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = $null; DeviceId = $null; DisplayName = 'CSV-DEVICE' }) -ProtectionIndex $index).IsProtected | Should -BeTrue
        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = $null; DeviceId = $null; DisplayName = 'Explicit-Device' }) -ProtectionIndex $index).IsProtected | Should -BeTrue
        (Test-DeviceProtection -Device ([PSCustomObject]@{ Id = 'other'; DeviceId = $null; DisplayName = $null }) -IntuneSerialNumber 'serial123' -ProtectionIndex $index).IsProtected |
            Should -BeTrue
    }
}

Describe 'Get-StaleDeviceCandidates protection integration' {
    BeforeAll {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
    }

    It 'excludes a device present in the protected device id list' {
        $device = New-TestEntraDevice -Id 'p1' -DeviceId 'dp1' -DisplayName 'W' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1' -ProtectedEntraObjectIds @('p1')
        $result[0].Decision | Should -Be 'Excluded'
        $result[0].ReasonCode | Should -Be 'ProtectedDevice'
    }

    It 'excludes on-premises synchronized devices by default' {
        $device = New-TestEntraDevice -Id 'p2' -DeviceId 'dp2' -DisplayName 'W' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300) -OnPremisesSyncEnabled $true
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $result[0].Decision | Should -Be 'Excluded'
        $result[0].ReasonCode | Should -Be 'OnPremisesSyncProtected'
    }

    It 'allows on-premises synchronized device deletion only when the override switch is set' {
        $device = New-TestEntraDevice -Id 'p3' -DeviceId 'dp3' -DisplayName 'W' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300) -OnPremisesSyncEnabled $true
        $result = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1' -AllowOnPremisesSyncedDeletion
        $result[0].Decision | Should -Be 'Candidate'
        $result[0].ReasonCode | Should -Be 'Stale'
        $result[0].EntraAction | Should -Be 'Remove'
    }

    It 'removes stale disabled devices directly' {
        $device = New-TestEntraDevice -Id 'p4' -DeviceId 'dp4' -DisplayName 'W' -AccountEnabled $false -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)
        $default = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $default[0].Decision | Should -Be 'Candidate'
        $default[0].ReasonCode | Should -Be 'Stale'
        $default[0].EntraAction | Should -Be 'Remove'
    }
}
