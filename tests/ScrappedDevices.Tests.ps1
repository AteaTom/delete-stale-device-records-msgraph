#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDeviceManagementManagedDevice { param([string]$ManagedDeviceId) }
    function global:Invoke-MgGraphRequest { param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType) }

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
        $script:intuneDevice = [PSCustomObject]@{ Id = 'intune1'; AzureAdDeviceId = 'aad-device-1'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-01' }
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

    It 'returns every related Entra and Intune object for a serial that exists in Autopilot' {
        $entraDeviceTwo = New-TestEntraDevice -Id 'entra2' -DeviceId 'aad-device-2' -DisplayName 'SCRAPPED-02'
        $intuneDeviceTwo = [PSCustomObject]@{ Id = 'intune2'; AzureAdDeviceId = 'aad-device-2'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-02' }
        $autopilotDevice = [PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'aad-device-1'; ManagedDeviceId = 'intune1'; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' }

        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice, $entraDeviceTwo) `
            -IntuneDevices @($script:intuneDevice, $intuneDeviceTwo) -AutopilotDevices @($autopilotDevice) -RunId 'r1'

        $result.Count | Should -Be 5
        ($result | Where-Object { $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId | Sort-Object -Unique) | Should -Be @('ap1')
        ($result | Where-Object { $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId | Sort-Object -Unique) | Should -Be @('intune1', 'intune2')
        ($result | Where-Object { $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId | Sort-Object -Unique) | Should -Be @('entra1', 'entra2')
        ($result | Select-Object -ExpandProperty MatchStatus | Sort-Object -Unique) | Should -Be @('Matched')
    }

    It 'flags a duplicate serial number as Ambiguous and never selects a single match when there is no Autopilot authority' {
        $duplicateIntune = [PSCustomObject]@{ Id = 'intune2'; AzureAdDeviceId = 'aad-device-2'; SerialNumber = '5CD3271HSD'; DeviceName = 'SCRAPPED-02' }
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
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Entra device objects:          1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Ambiguous serial numbers:      1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Serial numbers not found:      1' }
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
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = '5CD3271HSD'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }
    }

    AfterEach {
        Remove-Item -Path $script:testLogPath -Force -ErrorAction SilentlyContinue
    }

    It 'submits Autopilot in bulk and continues for an accepted state' {
        $global:scrappedRemovalOrder = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedRemovalOrder.Add('Intune')
        }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedRemovalOrder.Add('Autopilot')
            @{ value = @([PSCustomObject]@{ serialNumber = '5CD3271HSD'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'Removed'
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $parsedBody = $Body | ConvertFrom-Json
            $Method -eq 'POST' -and $Uri -match 'windowsAutopilotDeviceIdentities/deleteDevices$' -and
                $ContentType -eq 'application/json' -and $Body -is [string] -and
                $parsedBody.serialNumbers -contains '5CD3271HSD'
        }
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1
        $global:scrappedRemovalOrder | Should -Be @('Intune', 'Autopilot')
        Remove-Variable -Name scrappedRemovalOrder -Scope Global -ErrorAction SilentlyContinue
    }

    It 'never touches Ambiguous or NotFound records' {
        $records = @((New-TestScrappedRecord -MatchStatus 'Ambiguous'), (New-TestScrappedRecord -MatchStatus 'NotFound' -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId $null))
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'keeps the Intune-first removal and skips Entra when bulk Autopilot submission fails' {
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = '5CD3271HSD'; deviceRegistrationId = 'ap1'; deletionState = 'failed'; errorMessage = 'Service rejected deletion.' }) }
        }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'SkippedAutopilotSubmissionFailed'
        $record.ErrorMessage | Should -Be 'Service rejected deletion.'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'records a whole bulk request failure and still returns reportable statuses' {
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('503 Service Unavailable')
        }
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        $record = New-TestScrappedRecord

        { Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath } | Should -Not -Throw

        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.EntraRemovalStatus | Should -Be 'SkippedAutopilotSubmissionFailed'
        $record.ErrorMessage | Should -Match '503 Service Unavailable'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'isolates a missing serial in a partial bulk response' {
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = 'SERIAL-ACCEPTED'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }
        $acceptedRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap1' -IntuneManagedDeviceId $null -EntraObjectId 'entra1' -InputSerialNumber 'SERIAL-ACCEPTED'
        $missingRecord = New-TestScrappedRecord -AutopilotIdentityId 'ap2' -IntuneManagedDeviceId $null -EntraObjectId 'entra2' -InputSerialNumber 'SERIAL-MISSING'

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($acceptedRecord, $missingRecord) -LogPath $script:testLogPath

        $acceptedRecord.AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $acceptedRecord.EntraRemovalStatus | Should -Be 'Removed'
        $missingRecord.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $missingRecord.EntraRemovalStatus | Should -Be 'SkippedAutopilotSubmissionFailed'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $DeviceId -eq 'entra1' }
    }

    It 'handles a malformed bulk response item without a serial number' {
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ deletionState = 'accepted' }) }
        }
        $record = New-TestScrappedRecord -IntuneManagedDeviceId $null

        { Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath } | Should -Not -Throw

        $record.AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $record.EntraRemovalStatus | Should -Be 'SkippedAutopilotSubmissionFailed'
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'submits a shared Autopilot serial once and removes each related object once' {
        $records = @(
            (New-TestScrappedRecord -IntuneManagedDeviceId $null -EntraObjectId $null),
            (New-TestScrappedRecord -IntuneManagedDeviceId 'intune1' -EntraObjectId $null),
            (New-TestScrappedRecord -IntuneManagedDeviceId $null -EntraObjectId 'entra1')
        )

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath

        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1
    }

    It 'does not call any Graph cmdlet under -WhatIf' {
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -WhatIf -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'WhatIf'
        $record.IntuneRemovalStatus | Should -Be 'WhatIf'
        $record.EntraRemovalStatus | Should -Be 'WhatIf'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }
}

Describe 'Submit-WindowsAutopilotBulkRemoval chunking' {
    BeforeEach {
        $script:testLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "bulk-test-$(New-Guid).log"
    }

    AfterEach {
        Remove-Item -Path $script:testLogPath -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name autopilotBatchSizes -Scope Global -ErrorAction SilentlyContinue
    }

    It 'submits 201 unique serial numbers as sequential chunks of 100, 100, and 1' {
        $global:autopilotBatchSizes = [System.Collections.Generic.List[int]]::new()
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            $serials = @(($Body | ConvertFrom-Json).serialNumbers)
            $global:autopilotBatchSizes.Add($serials.Count)
            @{ value = @($serials | ForEach-Object { [PSCustomObject]@{ serialNumber = $_; deviceRegistrationId = "id-$_"; deletionState = 'accepted'; errorMessage = $null } }) }
        }
        $serialNumbers = @(1..201 | ForEach-Object { 'SERIAL-{0:D3}' -f $_ })

        $result = @(Submit-WindowsAutopilotBulkRemoval -SerialNumbers $serialNumbers -LogPath $script:testLogPath -Confirm:$false)

        $global:autopilotBatchSizes | Should -Be @(100, 100, 1)
        $result.Count | Should -Be 201
        @($result | Where-Object DeletionState -eq 'accepted').Count | Should -Be 201
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -ParameterFilter {
            $ContentType -eq 'application/json' -and $Body -is [string] -and
                @(($Body | ConvertFrom-Json).serialNumbers).Count -le 100
        }
    }

    It 'continues after one chunk fails and marks only that chunk as errors' {
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            $serials = @(($Body | ConvertFrom-Json).serialNumbers)
            if ($serials[0] -eq 'SERIAL-101') { throw [System.Exception]::new('400 Rejected chunk') }
            @{ value = @($serials | ForEach-Object { [PSCustomObject]@{ serialNumber = $_; deviceRegistrationId = "id-$_"; deletionState = 'accepted'; errorMessage = $null } }) }
        }
        $serialNumbers = @(1..201 | ForEach-Object { 'SERIAL-{0:D3}' -f $_ })

        $result = @(Submit-WindowsAutopilotBulkRemoval -SerialNumbers $serialNumbers -LogPath $script:testLogPath -Confirm:$false)

        $result.Count | Should -Be 201
        @($result | Where-Object DeletionState -eq 'accepted').Count | Should -Be 101
        @($result | Where-Object DeletionState -eq 'error').Count | Should -Be 100
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3
    }
}
