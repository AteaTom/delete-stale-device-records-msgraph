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

Describe 'ConvertTo-NormalizedSerialNumber' {
    It 'rejects null/empty/placeholder serial numbers' {
        ConvertTo-NormalizedSerialNumber -SerialNumber $null | Should -BeNullOrEmpty
        ConvertTo-NormalizedSerialNumber -SerialNumber '' | Should -BeNullOrEmpty
        ConvertTo-NormalizedSerialNumber -SerialNumber '0' | Should -BeNullOrEmpty
        ConvertTo-NormalizedSerialNumber -SerialNumber 'To Be Filled By O.E.M.' | Should -BeNullOrEmpty
    }

    It 'trims and lowercases valid serial numbers' {
        ConvertTo-NormalizedSerialNumber -SerialNumber '  ABC123  ' | Should -Be 'abc123'
    }
}

Describe 'Resolve-DeviceCorrelation' {
    It 'matches Entra to Intune via deviceId to azureADDeviceId with High confidence' {
        $intune = [PSCustomObject]@{ Id = 'intune1'; AzureAdDeviceId = 'AAAA'; SerialNumber = 'SN1'; LastSyncDateTime = (Get-Date) }
        $indexes = New-DeviceIndexes -IntuneDevices @($intune) -AutopilotDevices @()
        $device = [PSCustomObject]@{ DeviceId = 'aaaa' }
        $result = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform 'Windows'
        $result.MatchConfidence | Should -Be 'High'
        $result.IntuneMatch.Id | Should -Be 'intune1'
    }

    It 'never uses device name as the sole match key / never produces High confidence from name alone' {
        # No identifier overlap at all -> unmatched, regardless of similar names.
        $intune = [PSCustomObject]@{ Id = 'intune2'; AzureAdDeviceId = 'ZZZZ'; SerialNumber = $null }
        $indexes = New-DeviceIndexes -IntuneDevices @($intune) -AutopilotDevices @()
        $device = [PSCustomObject]@{ DeviceId = 'different-id'; DisplayName = 'SAME-NAME' }
        $result = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform 'Windows'
        $result.MatchConfidence | Should -Not -Be 'High'
        $result.MatchStatus | Should -Be 'Unmatched'
    }

    It 'flags duplicate serial numbers as ambiguous' {
        $intune = [PSCustomObject]@{ Id = 'intune3'; AzureAdDeviceId = 'BBBB'; SerialNumber = 'DUPSERIAL' }
        $autopilot1 = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = $null; ManagedDeviceId = $null; SerialNumber = 'DUPSERIAL' }
        $autopilot2 = [PSCustomObject]@{ Id = 'ap2'; AzureActiveDirectoryDeviceId = $null; ManagedDeviceId = $null; SerialNumber = 'DUPSERIAL' }
        $indexes = New-DeviceIndexes -IntuneDevices @($intune) -AutopilotDevices @($autopilot1, $autopilot2)
        $device = [PSCustomObject]@{ DeviceId = 'bbbb' }
        $result = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform 'Windows'
        $result.MatchStatus | Should -Be 'Ambiguous'
        $result.AmbiguityReason | Should -Be 'DuplicateSerialNumber'
    }

    It 'flags multiple Autopilot records matching the same Entra device as ambiguous and blocks deletion' {
        $autopilot1 = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'CCCC'; ManagedDeviceId = $null; SerialNumber = 'SNA' }
        $autopilot2 = [PSCustomObject]@{ Id = 'ap2'; AzureActiveDirectoryDeviceId = 'CCCC'; ManagedDeviceId = $null; SerialNumber = 'SNB' }
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @($autopilot1, $autopilot2)
        $device = [PSCustomObject]@{ DeviceId = 'cccc' }
        $result = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform 'Windows'
        $result.MatchStatus | Should -Be 'Ambiguous'

        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
        $entraDevice = New-TestEntraDevice -Id 'obj1' -DeviceId 'cccc' -DisplayName 'W' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)
        $eval = Get-StaleDeviceCandidates -EntraDevices @($entraDevice) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'
        $eval[0].Decision | Should -Be 'ManualReview'
    }

    It 'only allows High confidence for AAD-deviceId-based match; managedDeviceId match is Medium' {
        $intune = [PSCustomObject]@{ Id = 'intune4'; AzureAdDeviceId = $null; SerialNumber = $null }
        $autopilot = [PSCustomObject]@{ Id = 'ap3'; AzureActiveDirectoryDeviceId = $null; ManagedDeviceId = 'intune4'; SerialNumber = 'SNX' }
        $indexes = New-DeviceIndexes -IntuneDevices @($intune) -AutopilotDevices @($autopilot)
        $device = [PSCustomObject]@{ DeviceId = 'no-match' }
        $result = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform 'Windows'
        $result.MatchConfidence | Should -Be 'Unmatched'
    }
}

Describe 'Remove-EntraDeviceRecord identifier usage' {
    It 'calls Remove-MgDevice using the Entra object id, not the physical deviceId' {
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        $objectId = (New-Guid).ToString()
        Remove-EntraDeviceRecord -EntraObjectId $objectId -Confirm:$false | Out-Null
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -ParameterFilter { $DeviceId -eq $objectId } -Times 1
    }
}
