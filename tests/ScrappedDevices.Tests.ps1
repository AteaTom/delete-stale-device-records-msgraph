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
        $result = Get-ScrappedDeviceSerialNumbers -Path $script:csvPath
        $result | Should -Be @('5CD3271HSD', '5CD8245V12')
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

        $result[0].MatchStatus | Should -Be 'Matched'
        $result[0].AutopilotIdentityId | Should -Be 'ap1'
        $result[0].IntuneManagedDeviceId | Should -Be 'intune1'
        $result[0].EntraObjectId | Should -Be 'entra1'
    }

    It 'is case-insensitive when matching the input serial number' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5cd3271hsd') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId 'r1'

        $result[0].MatchStatus | Should -Be 'Matched'
    }

    It 'flags a duplicate serial number as Ambiguous and never selects a single match' {
        $duplicateAutopilot = [PSCustomObject]@{ Id = 'ap2'; AzureActiveDirectoryDeviceId = 'aad-device-2'; ManagedDeviceId = $null; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' }
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('5CD3271HSD') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice, $duplicateAutopilot) -RunId 'r1'

        $result[0].MatchStatus | Should -Be 'Ambiguous'
        $result[0].AmbiguityReason | Should -Be 'DuplicateSerialNumber'
        $result[0].AutopilotIdentityId | Should -BeNullOrEmpty
    }

    It 'reports NotFound for a serial number absent from every source' {
        $result = Resolve-ScrappedDeviceRecords -SerialNumbers @('NOTHERE123') -EntraDevices @($script:entraDevice) `
            -IntuneDevices @($script:intuneDevice) -AutopilotDevices @($script:autopilotDevice) -RunId 'r1'

        $result[0].MatchStatus | Should -Be 'NotFound'
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
                [string]$EntraObjectId = 'entra1'
            )
            [PSCustomObject]@{
                RunId                    = 'r1'
                InputSerialNumber        = '5CD3271HSD'
                NormalizedSerialNumber   = '5cd3271hsd'
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
    }

    AfterEach {
        Remove-Item -Path $script:testLogPath -Force -ErrorAction SilentlyContinue
    }

    It 'removes Autopilot, Intune, and Entra records once the re-issued delete confirms removal' {
        $script:autopilotCallCount = 0
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            $script:autopilotCallCount++
            if ($script:autopilotCallCount -eq 1) { return }
            throw [System.Exception]::new('ZtdDeviceAlreadyDeleted: already been deleted')
        }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'AlreadyRemoved'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'Removed'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 2
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1
    }

    It 'never touches Ambiguous or NotFound records' {
        $records = @((New-TestScrappedRecord -MatchStatus 'Ambiguous'), (New-TestScrappedRecord -MatchStatus 'NotFound' -AutopilotIdentityId $null -IntuneManagedDeviceId $null -EntraObjectId $null))
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $records -LogPath $script:testLogPath

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'treats a ZtdDeviceAlreadyDeleted response as confirmed removal and continues' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { throw [System.Exception]::new('ZtdDeviceAlreadyDeleted: already been deleted') }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'AlreadyRemoved'
        $record.IntuneRemovalStatus | Should -Be 'Removed'
        $record.EntraRemovalStatus | Should -Be 'Removed'
    }

    It 'skips Intune and Entra removal when Autopilot removal cannot be confirmed' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { throw [System.Exception]::new('ZtdDeviceDeletionInProgess: currently in progress') }
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -AutopilotDeletionRetryAttempts 1 -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'RemovalUnconfirmed'
        $record.IntuneRemovalStatus | Should -Be 'SkippedAutopilotNotRemoved'
        $record.EntraRemovalStatus | Should -Be 'SkippedAutopilotNotRemoved'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'does not call any Graph cmdlet under -WhatIf' {
        $record = New-TestScrappedRecord
        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords @($record) -WhatIf -LogPath $script:testLogPath

        $record.AutopilotRemovalStatus | Should -Be 'WhatIf'
        $record.IntuneRemovalStatus | Should -Be 'WhatIf'
        $record.EntraRemovalStatus | Should -Be 'WhatIf'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }
}
