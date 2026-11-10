#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:entry = Join-Path $PSScriptRoot '..\src\Invoke-StaleDeviceCleanup.ps1'
}

Describe 'Retired resume selectors' {
    It 'rejects <Selector> before any connection or output initialization' -ForEach @(
        @{ Selector = 'ResumeLatest'; Value = $true },
        @{ Selector = 'ResumeLatest'; Value = $false },
        @{ Selector = 'ResumeFromRunPath'; Value = 'old-run' }
    ) {
        $arguments = @{ $Selector = $Value; OutputPath = (Join-Path $TestDrive 'no-output') }
        { & $script:entry @arguments } | Should -Throw '*Resume selectors are retired*'
        Test-Path $arguments.OutputPath | Should -BeFalse
    }

    It 'does not export resume deletion helpers' {
        (Get-Module StaleDeviceCleanup).ExportedFunctions.Keys | Should -Not -Contain 'Resolve-DeviceCleanupResumeRecords'
        (Get-Module StaleDeviceCleanup).ExportedFunctions.Keys | Should -Not -Contain 'Get-LatestDeviceCleanupResumeSource'
    }
}

Describe 'Durable two-run safety evidence' {
    BeforeEach {
        $script:path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:evidence = Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1
        $script:device = New-TestEntraDevice -Id object1 -DeviceId device1 -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-400))
        $script:managed = [PSCustomObject]@{
            Id = 'managed1'; AzureAdDeviceId = 'device1'; SerialNumber = 'SERIAL1'
            LastSyncDateTime = [datetime]::UtcNow.AddDays(-10)
        }
        $script:indexes = New-DeviceIndexes -IntuneDevices @($script:managed) -AutopilotDevices @()
    }
    AfterEach { $script:evidence.Lock.Dispose() }

    It 'retains a newer Intune sync after Intune disappears' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:evidence.Lock.Dispose()
        $script:evidence = Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1
        $empty = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $empty
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes $empty -RunId r2 `
            -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -HistoricalEvidence $script:evidence.Devices
        $row.ReasonCode | Should -Be RecentActivityDetected
        $row.ActivitySource | Should -Be RetainedActivityEvidence
    }

    It 'retains activity through an Autopilot managed-device link without an Intune Entra reference' {
        $script:managed.AzureAdDeviceId = ''
        $ap = [PSCustomObject]@{
            Id = 'ap1'; AzureActiveDirectoryDeviceId = 'device1'; ManagedDeviceId = 'managed1'; SerialNumber = 'SERIAL1'
        }
        $linked = New-DeviceIndexes -IntuneDevices @($script:managed) -AutopilotDevices @($ap)
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $linked
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes (New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()) `
            -RunId r2 -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -HistoricalEvidence $script:evidence.Devices
        $row.ReasonCode | Should -Be RecentActivityDetected
    }

    It 'preserves serial-based protection after both service records disappear' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes (New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()) `
            -RunId r2 -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) `
            -HistoricalEvidence $script:evidence.Devices -ProtectedSerialNumbers @('serial1')
        $row.ReasonCode | Should -Be ProtectedDevice
    }

    It 'protects a serial re-registered in Autopilot without its old Entra reference' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $ap = [PSCustomObject]@{ Id = 'new-ap'; AzureActiveDirectoryDeviceId = ''; ManagedDeviceId = ''; SerialNumber = 'serial1' }
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes (New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @($ap)) `
            -RunId r2 -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -HistoricalEvidence $script:evidence.Devices
        $row.ReasonCode | Should -Be AutopilotProtected
    }

    It 'allows genuinely old retained activity to qualify without restarting the 180-day clock' {
        $script:managed.LastSyncDateTime = [datetime]::UtcNow.AddDays(-300)
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes (New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()) `
            -RunId r2 -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -HistoricalEvidence $script:evidence.Devices
        $row.Decision | Should -Be Candidate
    }

    It 'retains missing Intune activity as unresolved rather than trusting an older sign-in' {
        $script:managed.LastSyncDateTime = $null
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $empty = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $empty
        $row = Get-StaleDeviceCandidates -EntraDevices @($script:device) -Indexes $empty `
            -RunId r2 -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -HistoricalEvidence $script:evidence.Devices
        $row.ReasonCode | Should -Be UnresolvedSafetyEvidence
    }

    It 'fails closed on a changed stable device identity' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:device.DeviceId = 'changed'
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:evidence.Devices.object1.Ambiguous | Should -BeTrue
    }

    It 'rejects concurrent access to the same tenant evidence' {
        { Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1 } | Should -Throw
    }

    It 'isolates evidence for different tenants' {
        $other = Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant2
        try {
            $other.Path | Should -Not -Be $script:evidence.Path
            $other.Devices.Count | Should -Be 0
        } finally { $other.Lock.Dispose() }
    }

    It 'rejects missing initialized evidence' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:evidence.Lock.Dispose()
        Remove-Item -LiteralPath $script:evidence.Path
        { Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1 } | Should -Throw '*evidence is missing*'
    }

    It 'rejects a malformed evidence field: <Field>' -ForEach @(
        @{ Field = 'SerialNumbers'; Invalid = 'serial1' },
        @{ Field = 'LastActivityUtc'; Invalid = 0 },
        @{ Field = 'ActivityUnknown'; Invalid = 'false' }
    ) {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:evidence.Lock.Dispose()
        $document = Get-Content -LiteralPath $script:evidence.Path -Raw | ConvertFrom-Json
        $document.Devices[0].$Field = $Invalid
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:evidence.Path
        { Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1 } | Should -Throw '*Invalid or duplicate*'
    }

    It 'rejects malformed evidence instead of resetting it' {
        Update-DeviceCleanupEvidence -Evidence $script:evidence -EntraDevices @($script:device) -Indexes $script:indexes
        $script:evidence.Lock.Dispose()
        Set-Content -LiteralPath $script:evidence.Path -Value '{bad'
        { Open-DeviceCleanupEvidence -Path $script:path -TenantId tenant1 } | Should -Throw
    }
}

Describe 'Streaming final journal reader' {
    It 'reads a legacy full final checkpoint without changing the source' {
        $path = Join-Path $TestDrive 'legacy.jsonl'
        Set-Content $path @('{"Event":"Approved"}', '{"Event":"Final","Results":[{"Status":"OutcomeUnknown"}]}')
        $before = Get-FileHash $path
        (Read-DeviceDeletionJournal $path).Results[0].Status | Should -Be OutcomeUnknown
        (Get-FileHash $path).Hash | Should -Be $before.Hash
    }

    It 'rejects <Content> instead of using an earlier checkpoint' -ForEach @(
        @{ Content = '{"Event":"Response"}' }, @{ Content = '{"Event":' },
        @{ Content = '{"SchemaVersion":99,"Event":"Final"}' }
    ) {
        $path = Join-Path $TestDrive 'invalid.jsonl'
        Set-Content $path @('{"Event":"Final"}', $Content)
        { Read-DeviceDeletionJournal $path } | Should -Throw
    }
}
