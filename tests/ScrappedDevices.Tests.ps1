#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDeviceManagementManagedDevice { param([string]$ManagedDeviceId) }

    $modulePath = Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1'
    Import-Module $modulePath -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}
Describe 'Get-ScrappedDeviceSerialNumbers' {
    BeforeEach {
        $script:csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-$(New-Guid).csv"
    }

    AfterEach {
        Remove-Item -Path $script:csvPath -Force -ErrorAction SilentlyContinue
    }

    It 'trims whitespace, skips blank lines, and de-duplicates case-insensitively' {
        Set-Content -LiteralPath $script:csvPath -Value @('  5CD3271HSD  ', '', '5cd3271hsd', '5CD8245V12')
        $statistics = $null
        $result = Get-ScrappedDeviceSerialNumbers -Path $script:csvPath -Statistics ([ref]$statistics)
        $result | Should -Be @('5CD3271HSD', '5CD8245V12')
        $statistics.UniqueSerialCount | Should -Be 2
        $statistics.DuplicateRowCount | Should -Be 1
    }

    It 'skips an optional header row' {
        Set-Content -LiteralPath $script:csvPath -Value @('SerialNumber', '5CD3271HSD')
        $result = Get-ScrappedDeviceSerialNumbers -Path $script:csvPath
        $result | Should -Be @('5CD3271HSD')
    }

    It 'throws when the file does not exist' {
        { Get-ScrappedDeviceSerialNumbers -Path (Join-Path ([System.IO.Path]::GetTempPath()) "missing-$(New-Guid).csv") } | Should -Throw
    }
}
Describe 'Resolve-ScrappedDeviceRecords' {
    BeforeAll {
        $script:entraDevice = New-TestEntraDevice -Id 'entra1' -DeviceId 'aad-device-1' -DisplayName 'SCRAPPED-01'
        $script:intuneDevice = [PSCustomObject]@{ Id = 'intune1'; AzureAdDeviceId = 'aad-device-1'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-01'; OperatingSystem = 'Windows' }
        $script:autopilotDevice = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'aad-device-1'; ManagedDeviceId = 'intune1'; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' }
    }

    It 'matches a serial number across Autopilot, Intune, and Entra' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId 'r1'

        $result | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.MatchStatus -eq 'Matched' } | Select-Object -ExpandProperty AutopilotIdentityId | Sort-Object -Unique) | Should -Be @('ap1')
        ($result | Where-Object { $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId | Sort-Object -Unique) | Should -Be @('intune1')
        ($result | Where-Object { $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId | Sort-Object -Unique) | Should -Be @('entra1')
    }

    It 'is case-insensitive when matching the input serial number' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5cd3271hsd') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId 'r1'

        ($result | Where-Object { $_.MatchStatus -eq 'Matched' }).Count | Should -BeGreaterThan 0
    }

    It 'fails closed on duplicate Intune and Entra serial matches even with Autopilot present' {
        $entraDeviceTwo = New-TestEntraDevice -Id 'entra2' -DeviceId 'aad-device-2' -DisplayName 'SCRAPPED-02'
        $intuneDeviceTwo = [PSCustomObject]@{ Id = 'intune2'; AzureAdDeviceId = 'aad-device-2'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-02'; OperatingSystem = 'Windows' }
        $autopilotDevice = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'aad-device-1'; ManagedDeviceId = 'intune1'; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' }

        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice, $entraDeviceTwo) `
            -IntuneDevices @($script:intuneDevice, $intuneDeviceTwo) -AutopilotDevices @($autopilotDevice) -RunId 'r1'

        $result.Count | Should -Be 1
        $result[0].MatchStatus | Should -Be 'Ambiguous'
        $result[0].AutopilotIdentityId | Should -BeNullOrEmpty
        $result[0].IntuneManagedDeviceId | Should -BeNullOrEmpty
        $result[0].EntraObjectId | Should -BeNullOrEmpty
    }

    It 'flags a duplicate serial number as Ambiguous and never selects a single match when there is no Autopilot authority' {
        $duplicateIntune = [PSCustomObject]@{ Id = 'intune2'; AzureAdDeviceId = 'aad-device-2'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-02'; OperatingSystem = 'Windows' }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice, $duplicateIntune) -AutopilotDevices @() -RunId 'r1'

        $result[0].MatchStatus | Should -Be 'Ambiguous'
        $result[0].AmbiguityReason | Should -Be 'DuplicateSerialNumber'
        $result[0].IntuneManagedDeviceId | Should -BeNullOrEmpty
    }

    It 'reports NotFound for a serial number absent from every source' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('NOTHERE123') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId 'r1'

        $result[0].MatchStatus | Should -Be 'NotFound'
    }

    It 'protects explicitly scrapped serials by <Protection>' -TestCases @(
        @{ Protection = 'Serial' }, @{ Protection = 'EntraId' }, @{ Protection = 'DeviceId' }, @{ Protection = 'Name' }
    ) {
        param($Protection)
        $parameters = @{}
        switch ($Protection) {
            Serial { $parameters.ProtectedSerialNumbers = @('5CD3271HSD') }
            EntraId { $parameters.ProtectedEntraObjectIds = @('entra1') }
            DeviceId { $parameters.ProtectedEntraDeviceIds = @('aad-device-1') }
            Name { $parameters.ProtectedNamePatterns = @('SCRAPPED-*') }
        }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId r1 @parameters
        $result[0].MatchStatus | Should -Be 'Excluded'
        $result[0].AmbiguityReason | Should -Be 'ProtectedDevice'
        $result[0].IntuneManagedDeviceId | Should -BeNullOrEmpty
    }

    It 'excludes unsupported or missing scrapped platforms: <OS>' -TestCases @(
        @{ OS = 'Windows Server' }, @{ OS = 'macOS' }, @{ OS = '' }
    ) {
        param($OS)
        $intune = [PSCustomObject]@{
            Id = 'intune1'; AzureAdDeviceId = 'aad-device-1'; SerialNumber = '5CD3271HSD'
            DeviceName = 'SCRAPPED-01'; OperatingSystem = $OS
        }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($intune) -AutopilotDevices @($script:autopilotDevice) -RunId r1
        $result[0].MatchStatus | Should -Be 'Excluded'
        $result[0].AmbiguityReason | Should -Be 'UnsupportedOrMissingPlatform'
    }

    It 'protects an Autopilot-only identity using its Entra device reference' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @() `
            -IntuneDevices @() -AutopilotDevices @($script:autopilotDevice) -RunId r1 `
            -ProtectedEntraDeviceIds @('aad-device-1')
        $result[0].MatchStatus | Should -Be 'Excluded'
        $result[0].AmbiguityReason | Should -Be 'ProtectedDevice'
        $result[0].AutopilotIdentityId | Should -BeNullOrEmpty
    }

    It 'does not trust serial matches over conflicting stable identifiers' {
        $intune = [PSCustomObject]@{
            Id = 'another'; AzureAdDeviceId = 'aad-device-1'; SerialNumber = '5CD3271HSD'
            DeviceName = 'SCRAPPED-01'; OperatingSystem = 'Windows'
        }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($intune) -AutopilotDevices @($script:autopilotDevice) -RunId r1
        $result[0].AmbiguityReason | Should -Be 'ConflictingIdentifiers'
        $result[0].AutopilotIdentityId | Should -BeNullOrEmpty
    }

    It 'does not bypass an Intune prerequisite whose serial differs from its Autopilot reference' {
        $intune = [PSCustomObject]@{
            Id = 'intune1'; AzureAdDeviceId = 'aad-device-1'; SerialNumber = 'ANOTHER-SERIAL'
            DeviceName = 'SCRAPPED-01'; OperatingSystem = 'Windows'
        }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($intune) -AutopilotDevices @($script:autopilotDevice) -RunId r1
        $result[0].MatchStatus | Should -Be 'Excluded'
        $result[0].AmbiguityReason | Should -Be 'ConflictingIdentifiers'
    }
}
Describe 'Show-ScrappedDeviceSummary' {
    It 'shows unique target counts without inflating repeated correlation rows' {
        $records = @(
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = $null; EntraObjectId = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = 'intune1'; EntraObjectId = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = $null; EntraObjectId = 'entra1' },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial2'; MatchStatus = 'Ambiguous'; AutopilotIdentityId = $null; IntuneManagedDeviceId = $null; EntraObjectId = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial3'; MatchStatus = 'NotFound'; AutopilotIdentityId = $null; IntuneManagedDeviceId = $null; EntraObjectId = $null }
        )
        Mock -CommandName Write-Host -ModuleName StaleDeviceCleanup -MockWith { }

        Show-ScrappedDeviceSummary -ScrappedDeviceRecords $records -OutputPath 'C:\reports' -CsvDuplicateCount 2

        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Unique input serial numbers:   3' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Duplicate CSV rows ignored:    2' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Matched serial numbers:        1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Autopilot records:             1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Intune managed devices:        1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Entra objects for review:      1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Ambiguous serial numbers:      1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Serial numbers not found:      1' }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Total DELETE operations:       2'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Serials with DELETE targets:   1'
        }
    }

    It 'does not count Entra-only matches as destructive targets' {
        $record = [PSCustomObject]@{
            NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'
            AutopilotIdentityId = $null; IntuneManagedDeviceId = $null; EntraObjectId = 'entra1'
        }
        Mock Write-Host -ModuleName StaleDeviceCleanup { }
        Show-ScrappedDeviceSummary -ScrappedDeviceRecords @($record) -OutputPath $TestDrive `
            -TenantId tenant1 -Mode Interactive -Simulation $true -DeletionTransport JsonBatch
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Serials with DELETE targets:   0'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Entra objects for review:      1'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq 'Mode: Interactive; WhatIf: True; transport: JsonBatch'
        }
    }

    It 'supports an empty scrapped report' {
        Mock Write-Host -ModuleName StaleDeviceCleanup { }
        Show-ScrappedDeviceSummary -ScrappedDeviceRecords @() -OutputPath $TestDrive
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Total DELETE operations:       0'
        }
    }
}
Describe 'Remove-IntuneManagedDeviceRecord' {
    It 'calls Remove-MgDeviceManagementManagedDevice with the managed device id' {
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Remove-IntuneManagedDeviceRecord -ManagedDeviceId 'intune1' -Confirm:$false | Out-Null
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $ManagedDeviceId -eq 'intune1' }
    }

    It 'does not call the Graph cmdlet under -WhatIf' {
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Remove-IntuneManagedDeviceRecord -ManagedDeviceId 'intune1' -WhatIf | Out-Null
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'treats an already absent managed device as a completed removal' {
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('Request_ResourceNotFound')
        }
        $alreadyRemoved = $false
        $result = Remove-IntuneManagedDeviceRecord -ManagedDeviceId 'intune-gone' -AlreadyRemoved ([ref]$alreadyRemoved) -Confirm:$false

        $result | Should -BeTrue
        $alreadyRemoved | Should -BeTrue
    }
}

Describe 'Invoke-ScrappedDeviceRemoval' {
    BeforeAll {
        function New-TestScrappedRecord {
            param(
                [string]$MatchStatus = 'Matched',
                [string]$AutopilotIdentityId = 'ap1',
                [string]$IntuneManagedDeviceId = 'intune1',
                [string]$EntraObjectId = 'entra1',
                [string]$InputSerialNumber = '5CD3271HSD'
            )
            [PSCustomObject]@{
                RunId                    = 'r1'
                InputSerialNumber        = $InputSerialNumber
                NormalizedSerialNumber   = $InputSerialNumber.ToLowerInvariant()
                MatchStatus              = $MatchStatus
                AmbiguityReason          = $null
                AutopilotIdentityId      = $AutopilotIdentityId
                AutopilotEnrollmentState = 'enrolled'
                IntuneManagedDeviceId    = $IntuneManagedDeviceId
                IntuneDeviceName         = 'SCRAPPED-01'
                EntraObjectId            = $EntraObjectId
                EntraDeviceName          = 'SCRAPPED-01'
                AutopilotRemovalStatus   = 'NotAttempted'
                IntuneRemovalStatus      = 'NotAttempted'
                EntraRemovalStatus       = 'NotAttempted'
                ErrorMessage             = $null
            }
        }
    }

    BeforeEach {
        $script:testLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-test-$(New-Guid).log"
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
    }

    AfterEach {
        Remove-Item -Path $script:testLogPath -Force -ErrorAction SilentlyContinue
    }

    It 'submits an Autopilot identity and continues for a successful response' {
        $global:scrappedRemovalOrder = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedRemovalOrder.Add('Intune')
        }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedRemovalOrder.Add('Autopilot')
        }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false

        $record.AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $WindowsAutopilotDeviceIdentityId -eq 'ap1' }
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $global:scrappedRemovalOrder | Should -Be @('Intune', 'Autopilot')
        Remove-Variable -Name scrappedRemovalOrder -Scope Global -ErrorAction SilentlyContinue
    }

    It 'never touches Ambiguous or NotFound records' {
        $records = @((New-TestScrappedRecord -MatchStatus 'Ambiguous'), (New-TestScrappedRecord -MatchStatus 'NotFound' -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId $null))
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath -Confirm:$false

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'keeps the Intune-first removal and skips Entra when Autopilot identity removal fails' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('Service rejected deletion.')
        }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false

        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        $record.ErrorMessage | Should -Be 'Service rejected deletion.'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'records an individual Autopilot request failure and still returns reportable statuses' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('503 Service Unavailable')
        }
        $record = New-TestScrappedRecord

        { Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false } | Should -Not -Throw

        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        $record.ErrorMessage | Should -Match '503 Service Unavailable'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'isolates one failed Autopilot identity from a successful identity' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            if ($WindowsAutopilotDeviceIdentityId -eq 'ap2') { throw [System.Exception]::new('Rejected identity') }
        }
        $acceptedRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap1' -IntuneManagedDeviceId $null -EntraObjectId 'entra1' -InputSerialNumber 'SERIAL-ACCEPTED'
        $missingRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap2' -IntuneManagedDeviceId $null -EntraObjectId 'entra2' -InputSerialNumber 'SERIAL-MISSING'

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($acceptedRecord, $missingRecord) -LogPath $script:testLogPath -Confirm:$false

        $acceptedRecord.AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $acceptedRecord.EntraRemovalStatus | Should -Be 'ManualReview'
        $missingRecord.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $missingRecord.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'handles an Autopilot identity with a rejected DELETE without Entra removal' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('Rejected identity')
        }
        $record = New-TestScrappedRecord -IntuneManagedDeviceId $null

        { Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false } | Should -Not -Throw

        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'submits a shared Autopilot serial once and removes each related object once' {
        $records = @(
            (New-TestScrappedRecord -IntuneManagedDeviceId $null -EntraObjectId $null),
            (New-TestScrappedRecord -IntuneManagedDeviceId 'intune1' -EntraObjectId $null),
            (New-TestScrappedRecord -IntuneManagedDeviceId $null -EntraObjectId 'entra1')
        )

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath -Confirm:$false

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'removes each unique batch target once and copies its outcome to duplicate rows' {
        $records = @(
            (New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId 'intune1' -EntraObjectId $null),
            (New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId 'INTUNE1' -EntraObjectId $null),
            (New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId $null)
        )

        Invoke-ScrappedDeviceBatchRemoval -ScrappedDeviceRecords $records -TargetType Intune -LogPath $script:testLogPath -Confirm:$false

        $records[0].IntuneRemovalStatus | Should -Be 'Removed'
        $records[1].IntuneRemovalStatus | Should -Be 'Removed'
        $records[2].IntuneRemovalStatus | Should -Be 'NotApplicable'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1

        { Invoke-ScrappedDeviceBatchRemoval -ScrappedDeviceRecords @() -TargetType Entra -LogPath $script:testLogPath -Confirm:$false } | Should -Throw
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'retries throttled batch items and records individual exhaustion without aborting later targets' {
        $global:scrappedRetryAttempts = 0
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            if ($ManagedDeviceId -eq 'intune-throttled') {
                $global:scrappedRetryAttempts++
                if ($global:scrappedRetryAttempts -lt 3) {
                    throw [System.Exception]::new('429 Too Many Requests')
                }
            }
            if ($ManagedDeviceId -eq 'intune-exhausted') {
                throw [System.Exception]::new('503 Service Unavailable')
            }
        }
        $throttledRecord = New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId 'intune-throttled' -EntraObjectId $null
        $failedRecord = New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId 'intune-exhausted' -EntraObjectId $null -InputSerialNumber 'SERIAL-FAILED'
        $laterRecord = New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId 'intune-later' -EntraObjectId $null -InputSerialNumber 'SERIAL-LATER'

        Invoke-ScrappedDeviceBatchRemoval -ScrappedDeviceRecords @($throttledRecord, $failedRecord, $laterRecord) -TargetType Intune -LogPath $script:testLogPath -Confirm:$false

        $throttledRecord.IntuneRemovalStatus | Should -Be 'Removed'
        $failedRecord.IntuneRemovalStatus | Should -Be 'RemovalFailed'
        $failedRecord.ErrorMessage | Should -Match '503 Service Unavailable'
        $laterRecord.IntuneRemovalStatus | Should -Be 'Removed'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 9
        Remove-Variable -Name scrappedRetryAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'fails closed for a missing Autopilot result and blocks the associated Entra target' {
        Mock -CommandName Submit-WindowsAutopilotIdentityRemoval -ModuleName StaleDeviceCleanup -MockWith { @() }
        $record = New-TestScrappedRecord -IntuneManagedDeviceId $null

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false

        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        $record.ErrorMessage | Should -Match 'was not submitted'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'blocks Entra removal when any Autopilot identity for the serial fails' {
        Mock -CommandName Submit-WindowsAutopilotIdentityRemoval -ModuleName StaleDeviceCleanup -MockWith {
            @(
                [PSCustomObject]@{ IdentityId = 'ap1'; Status = 'RemovalSubmitted'; ErrorMessage = $null },
                [PSCustomObject]@{ IdentityId = 'ap2'; Status = 'RemovalFailed'; ErrorMessage = 'Identity rejected' }
            )
        }
        $firstIdentityRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap1' -IntuneManagedDeviceId $null -EntraObjectId $null
        $secondIdentityRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap2' -IntuneManagedDeviceId $null -EntraObjectId $null
        $entraRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap1' -IntuneManagedDeviceId $null -EntraObjectId 'entra1'

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($firstIdentityRecord, $secondIdentityRecord, $entraRecord) `
            -LogPath $script:testLogPath -Confirm:$false

        $firstIdentityRecord.AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $secondIdentityRecord.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $entraRecord.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'preserves already-removed Autopilot outcomes and retains the Entra object for review' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('ZtdDeviceAlreadyDeleted')
        }
        $record = New-TestScrappedRecord -IntuneManagedDeviceId $null

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath -Confirm:$false

        $record.AutopilotRemovalStatus | Should -Be 'AlreadyRemoved'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'retains every matched Entra object for manual review without deleting it' {
        $records = @(
            (New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId 'entra-one'),
            (New-TestScrappedRecord -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId 'entra-two' -InputSerialNumber 'SERIAL-TWO')
        )

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath -Confirm:$false

        @($records | Where-Object EntraRemovalStatus -ne 'ManualReview').Count | Should -Be 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'does not call any Graph cmdlet under -WhatIf' {
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -WhatIf -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'WhatIf'
        $record.IntuneRemovalStatus | Should -Be 'WhatIf'
        $record.EntraRemovalStatus | Should -Be 'ManualReview'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'blocks all related Autopilot rows when Intune removal fails' {
        Mock Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup { throw 'Denied Intune' }
        $records = @(
            (New-TestScrappedRecord),
            (New-TestScrappedRecord -IntuneManagedDeviceId $null -EntraObjectId 'entra2')
        )
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath -Confirm:$false
        @($records | Where-Object AutopilotRemovalStatus -eq 'BlockedDependency').Count | Should -Be 2
        Assert-MockCalled Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }
}
