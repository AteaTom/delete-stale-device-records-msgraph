#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }
    function global:Remove-MgDeviceManagementManagedDevice { param([string]$ManagedDeviceId) }
    function global:Get-MgContext { }
    function global:Invoke-MgGraphRequest { param([string]$Method, [string]$Uri, [string]$OutputType, [switch]$SkipHttpErrorCheck) }

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
        Set-Content -LiteralPath $script:csvPath -Value @('SerialNumber', '  5CD3271HSD  ', '', '5cd3271hsd', '5CD8245V12')
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
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Entra objects to remove:       1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Ambiguous serial numbers:      1' }
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Serial numbers not found:      1' }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Total DELETE operations:       3'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Serials with DELETE targets:   1'
        }
    }

    It 'counts validated Entra-only matches as destructive targets' {
        $record = [PSCustomObject]@{
            NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'
            AutopilotIdentityId = $null; IntuneManagedDeviceId = $null; EntraObjectId = 'entra1'
        }
        Mock Write-Host -ModuleName StaleDeviceCleanup { }
        Show-ScrappedDeviceSummary -ScrappedDeviceRecords @($record) -OutputPath $TestDrive `
            -TenantId tenant1 -Mode Interactive -Simulation $true
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Serials with DELETE targets:   1'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Entra objects to remove:       1'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq 'Mode: Interactive; WhatIf: True'
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
