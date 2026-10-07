#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Connect-MgGraph { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) throw 'Unmocked authentication is prohibited in offline tests.' }
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) throw 'Unmocked discovery is prohibited in offline tests.' }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) throw 'Unmocked discovery is prohibited in offline tests.' }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All) throw 'Unmocked discovery is prohibited in offline tests.' }
    function global:Get-MgContext { }
    function global:Get-MgRequestContext { }
    function global:Set-MgRequestContext { param([int]$MaxRetry) }
    function global:Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType, [string]$OutputType, [switch]$SkipHttpErrorCheck)
    }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementManagedDevice { param([string]$ManagedDeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:entry = Join-Path $PSScriptRoot '..\src\Invoke-StaleDeviceCleanup.ps1'
    function New-ScrappedIntuneFixture {
        param([string]$Id = 'intune1', [string]$DeviceId = 'device1', [string]$Serial = 'SERIAL1', [string]$OS = 'Windows')
        [PSCustomObject]@{ Id = $Id; AzureAdDeviceId = $DeviceId; SerialNumber = $Serial; OperatingSystem = $OS; DeviceName = 'Information-only' }
    }
    function New-ScrappedAutopilotFixture {
        param([string]$Id = 'ap1', [string]$DeviceId = 'device1', [string]$ManagedId = 'intune1', [string]$Serial = 'SERIAL1')
        [PSCustomObject]@{
            Id = $Id; AzureActiveDirectoryDeviceId = $DeviceId; ManagedDeviceId = $ManagedId
            SerialNumber = $Serial; EnrollmentState = 'enrolled'
        }
    }
}

Describe 'Scrapped parameter and CSV contracts' {
    It 'separates the parameter sets at binding time' {
        $sets = (Get-Command $script:entry).ParameterSets
        ($sets | Where-Object Name -eq 'Scrapped').Parameters.Name | Should -Not -Contain 'DaysInactive'
        ($sets | Where-Object Name -eq 'Inactivity').Parameters.Name | Should -Contain 'DaysInactive'
        ($sets | Where-Object Name -eq 'Inactivity').Parameters.Name | Should -Not -Contain 'ScrappedDevices'
        ($sets | Where-Object Name -eq 'Scrapped').Parameters.Where({ $_.Name -eq 'ScrappedDevices' }).IsMandatory | Should -BeTrue
    }

    It 'rejects explicit inactivity parameters with scrapped workflow: <Days>' -ForEach @(
        @{ Days = 179 }, @{ Days = 180 }, @{ Days = 1800 }
    ) {
        { & $script:entry -ScrappedDevices -DaysInactive $Days -WhatIf } | Should -Throw
    }

    It 'rejects a path without explicit new destructive-workflow intent' {
        { & $script:entry -ScrappedDeviceCsvPath 'unused.csv' -DaysInactive 180 } | Should -Throw
    }

    It 'requires a serial column for strict CSV input: <Content>' -ForEach @(
        @{ Content = 'SERIAL1' }, @{ Content = 'DeviceName' }, @{ Content = 'SerialNumber,SerialNumber' }
    ) {
        $path = Join-Path $TestDrive 'bad.csv'
        Set-Content $path $Content
        { Get-ScrappedDeviceSerialNumbers -Path $path } | Should -Throw '*SerialNumber*'
    }

    It 'rejects malformed rows: <Row>' -ForEach @(
        @{ Row = '"unterminated' }, @{ Row = 'one,two' }
    ) {
        $path = Join-Path $TestDrive 'malformed.csv'
        Set-Content $path @('SerialNumber', $Row)
        { Get-ScrappedDeviceSerialNumbers -Path $path } | Should -Throw
    }

    It 'parses quoted fields and ignores empty serials while counting duplicate inputs' {
        $path = Join-Path $TestDrive 'serials.csv'
        Set-Content $path @('Notes,SerialNumber', '"a,b"," SERIAL1 "', 'blank,', 'same,serial1', 'next,SERIAL2')
        $statistics = $null
        $serials = Get-ScrappedDeviceSerialNumbers -Path $path -Statistics ([ref]$statistics)
        $serials | Should -Be @('SERIAL1', 'SERIAL2')
        $statistics.DuplicateRowCount | Should -Be 1
    }

    It 'accepts headerless input only with the explicit legacy-format option' {
        $path = Join-Path $TestDrive 'legacy.csv'
        Set-Content $path @(' SERIAL1 ', '', 'serial1')
        { Get-ScrappedDeviceSerialNumbers -Path $path } | Should -Throw
        Get-ScrappedDeviceSerialNumbers -Path $path -AllowLegacyFormat | Should -Be @('SERIAL1')
    }
}

Describe 'Scrapped stable-identifier correlation boundaries' {
    BeforeEach {
        $script:entra = New-TestEntraDevice -Id 'entra1' -DeviceId 'device1' -DisplayName 'Not-a-serial'
        $script:resolve = @{
            SerialNumbers = @('SERIAL1'); RunId = 'r1'; EntraDevices = @($script:entra)
            IntuneDevices = @(New-ScrappedIntuneFixture); AutopilotDevices = @(New-ScrappedAutopilotFixture)
        }
    }

    It 'handles all corroborated Intune and Autopilot objects once in the plan' {
        $script:resolve.IntuneDevices += New-ScrappedIntuneFixture -Id intune2
        $script:resolve.AutopilotDevices += New-ScrappedAutopilotFixture -Id ap2 -ManagedId intune2
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object MatchStatus -ne 'Matched').Count | Should -Be 0
        $plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId r1 -Workflow Scrapped -Records $records
        @($plan.Operations | Where-Object Resource -eq 'Intune').Count | Should -Be 2
        @($plan.Operations | Where-Object Resource -eq 'Autopilot').Count | Should -Be 2
        @($plan.Operations | Where-Object Resource -eq 'Entra').Count | Should -Be 1
        ($plan.Operations | Where-Object Resource -eq 'Entra').Dependencies.Count | Should -Be 4
        ($records | Where-Object EntraObjectId).EntraDeviceName | Should -Be 'Not-a-serial'
        ($records | Where-Object EntraObjectId).EntraDeviceId | Should -Be 'device1'
        ($records | Where-Object EntraObjectId).CorrelationMethod | Should -Be 'StableDeviceIdReference'
    }

    It 'handles all corroborated Intune records even without Autopilot' {
        $script:resolve.IntuneDevices += New-ScrappedIntuneFixture -Id intune2
        $script:resolve.AutopilotDevices = @()
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object MatchStatus -eq 'Matched').Count | Should -Be 2
        ($records.IntuneManagedDeviceId | Sort-Object -Unique) | Should -Be @('intune1', 'intune2')
    }

    It 'fails closed on serial-only collisions without corroborating IDs' {
        $script:resolve.IntuneDevices = @((New-ScrappedIntuneFixture -DeviceId ''), (New-ScrappedIntuneFixture -Id intune2 -DeviceId ''))
        $script:resolve.AutopilotDevices = @()
        (Resolve-ScrappedDeviceRecords @script:resolve)[0].MatchStatus | Should -Be 'Ambiguous'
    }

    It 'does not bypass a differently-serialized related <Service> record' -ForEach @(
        @{ Service = 'Intune' }, @{ Service = 'Autopilot' }
    ) {
        if ($Service -eq 'Autopilot') { $script:resolve.AutopilotDevices += New-ScrappedAutopilotFixture -Id ap2 -Serial DIFFERENT }
        else { $script:resolve.IntuneDevices += New-ScrappedIntuneFixture -Id intune2 -Serial DIFFERENT }
        (Resolve-ScrappedDeviceRecords @script:resolve)[0].AmbiguityReason | Should -Be 'ConflictingIdentifiers'
    }

    It 'protects synchronized Entra objects unless explicitly overridden' {
        $script:entra.OnPremisesSyncEnabled = $true
        (Resolve-ScrappedDeviceRecords @script:resolve)[0].AmbiguityReason | Should -Be 'OnPremisesSyncProtected'
        $records = Resolve-ScrappedDeviceRecords @script:resolve -AllowOnPremisesSyncedDeletion
        @($records | Where-Object EntraObjectId).Count | Should -Be 1
        @($records | Where-Object MatchStatus -ne 'Matched').Count | Should -Be 0
    }

    It 'does not correlate an Entra object by its display name alone' {
        $script:entra.DeviceId = 'different'
        $script:entra.DisplayName = 'SERIAL1'
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object EntraObjectId).Count | Should -Be 0
        @($records | Where-Object IntuneManagedDeviceId).Count | Should -Be 1
    }

    It 'ignores inactivity but never ignores protected hardware' {
        $script:entra.ApproximateLastSignInDateTime = [datetime]::UtcNow
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object MatchStatus -eq 'Matched').Count | Should -BeGreaterThan 0
        (Resolve-ScrappedDeviceRecords @script:resolve -ProtectedSerialNumbers SERIAL1)[0].MatchStatus | Should -Be 'Excluded'
    }

    It 'never attempts Autopilot correlation for <Platform> hardware' -ForEach @(
        @{ Platform = 'iOS' }, @{ Platform = 'Android' }
    ) {
        $script:entra.OperatingSystem = $Platform
        $script:resolve.IntuneDevices = @(New-ScrappedIntuneFixture -OS $Platform)
        $script:resolve.AutopilotDevices = @()
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object AutopilotIdentityId).Count | Should -Be 0
        @($records | Where-Object MatchStatus -ne 'Matched').Count | Should -Be 0
    }

    It 'does not trust a zero Entra device reference as a stable identifier' {
        $zero = '00000000-0000-0000-0000-000000000000'
        $script:entra.DeviceId = $zero
        $script:resolve.IntuneDevices = @(New-ScrappedIntuneFixture -DeviceId $zero)
        $script:resolve.AutopilotDevices = @()
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        @($records | Where-Object EntraObjectId).Count | Should -Be 0
        @($records | Where-Object IntuneManagedDeviceId).Count | Should -Be 1
    }

    It 'supports an Autopilot managed-device link without an Entra reference' {
        $script:resolve.AutopilotDevices = @(New-ScrappedAutopilotFixture -DeviceId '')
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        ($records | Where-Object EntraObjectId).EntraObjectId | Should -Be 'entra1'
    }

    It 'rejects conflicting supported platforms without Autopilot' {
        $script:resolve.AutopilotDevices = @()
        $script:resolve.IntuneDevices = @(New-ScrappedIntuneFixture -OS Android)
        $records = Resolve-ScrappedDeviceRecords @script:resolve
        $records[0].MatchStatus | Should -Be 'Excluded'
        $records[0].AmbiguityReason | Should -Be 'ConflictingPlatform'
        (New-DeviceDeletionPlan -TenantId tenant1 -RunId r1 -Workflow Scrapped -Records $records).Operations.Count | Should -Be 0
    }
}

Describe 'Scrapped script outcomes with entirely offline Graph mocks' {
    BeforeEach {
        $script:csv = Join-Path $TestDrive 'scrapped.csv'
        Set-Content $script:csv @('SerialNumber', 'SERIAL1')
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:invoke = @{ ScrappedDevices = $true; ScrappedDeviceCsvPath = $script:csv; OutputPath = $script:output }
        Mock Test-Prerequisites -ModuleName StaleDeviceCleanup { }
        Mock Connect-MgGraph -ModuleName StaleDeviceCleanup { }
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{
                TenantId = 'tenant1'; AuthType = 'Delegated'; Environment = 'Global'
                Scopes = @('Device.Read.All', 'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All',
                    'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
            }
        }
        Mock Get-MgDevice -ModuleName StaleDeviceCleanup {
            @((New-TestEntraDevice -Id entra1 -DeviceId device1 -DisplayName 'Not-a-serial' -ApproximateLastSignInDateTime ([datetime]::UtcNow)))
        }
        Mock Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup { @(New-ScrappedIntuneFixture) }
        Mock Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup { @(New-ScrappedAutopilotFixture) }
        Mock Get-StaleDeviceCandidates -ModuleName StaleDeviceCleanup { throw 'Inactivity evaluation must not be reached' }
        Mock Get-EffectiveLastActivity -ModuleName StaleDeviceCleanup { throw 'Activity must not be evaluated' }
        Mock Remove-MgDevice -ModuleName StaleDeviceCleanup { }
        Mock Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup { }
        Mock Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup { }
        Mock Get-MgRequestContext -ModuleName StaleDeviceCleanup { [PSCustomObject]@{ MaxRetry = 3 } }
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup { }
        Mock Start-Sleep -ModuleName StaleDeviceCleanup { }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object { [PSCustomObject]@{ id = $_.id; status = 204 } }) }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        }
    }

    It 'performs no destructive work in <Scenario> with <Transport>' -ForEach @(
        @{ Scenario = 'Audit'; Transport = 'Individual' }, @{ Scenario = 'WhatIf'; Transport = 'Individual' },
        @{ Scenario = 'Audit'; Transport = 'JsonBatch' }, @{ Scenario = 'WhatIf'; Transport = 'JsonBatch' },
        @{ Scenario = 'Unconfirmed'; Transport = 'Individual' }, @{ Scenario = 'Unconfirmed'; Transport = 'JsonBatch' },
        @{ Scenario = 'Cancelled'; Transport = 'Individual' }, @{ Scenario = 'Cancelled'; Transport = 'JsonBatch' }
    ) {
        $script:invoke.DeletionTransport = $Transport
        switch ($Scenario) {
            WhatIf { $script:invoke.Mode = 'Automatic'; $script:invoke.ConfirmDeletion = $true; $script:invoke.WhatIf = $true }
            Unconfirmed { $script:invoke.Mode = 'Automatic' }
            Cancelled { $script:invoke.Mode = 'Interactive'; Mock Read-Host -ModuleName StaleDeviceCleanup { '' } }
        }
        & $script:entry @script:invoke
        Should -Invoke Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Get-StaleDeviceCandidates -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Get-EffectiveLastActivity -ModuleName StaleDeviceCleanup -Times 0
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.PSObject.Properties.Name | Should -Not -Contain 'DaysInactiveThreshold'
        $summary.PSObject.Properties.Name | Should -Not -Contain 'CutoffDateUtc'
        if ($Scenario -eq 'WhatIf') { $summary.TotalScrappedSimulated | Should -Be 1 }
    }

    It 'blocks Entra and reports partial success when Autopilot <Readback> with <Transport>' -ForEach @(
        @{ Readback = 'OK'; Transport = 'Individual' }, @{ Readback = 'Forbidden'; Transport = 'Individual' },
        @{ Readback = 'OK'; Transport = 'JsonBatch' }, @{ Readback = 'Forbidden'; Transport = 'JsonBatch' }
    ) {
        $script:invoke.DeletionTransport = $Transport
        $responseMock = if ($Readback -eq 'OK') {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK) }
        } else {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden) }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } -MockWith $responseMock
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        Should -Invoke Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter { $Method -eq 'POST' -and $Body -match '/devices/' }
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $rows = Import-Csv (Join-Path $run.FullName 'ScrappedDeviceResults.csv')
        ($rows | Where-Object EntraObjectId).EntraRemovalStatus | Should -Be 'BlockedDependency'
        $rows.CleanupOutcome | Sort-Object -Unique | Should -Be @('Partial')
        $verification = if ($Readback -eq 'OK') { 'VerificationPending' } else { 'OutcomeUnknown' }
        ($rows | Where-Object AutopilotIdentityId | Select-Object -First 1).AutopilotVerificationStatus | Should -Be $verification
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.ExitCode | Should -Be 6
        $summary.TotalScrappedComplete | Should -Be 0
        $summary.TotalScrappedEntraDevicesBlockedByAutopilot | Should -Be 1
    }

    It 'reports empty input as scrapped without inactivity metadata' {
        Set-Content $script:csv 'SerialNumber'
        & $script:entry @script:invoke
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.ScrappedWorkflow | Should -BeTrue
        $summary.TotalScrappedSerials | Should -Be 0
        $summary.PSObject.Properties.Name | Should -Not -Contain 'DaysInactiveThreshold'
    }

    It 'fails closed and preserves individual service lookup states when <Service> retrieval fails' -ForEach @(
        @{ Service = 'Entra'; Command = 'Get-MgDevice'; Entra = 'FailedLookup'; Intune = 'NotAttempted'; Autopilot = 'NotAttempted' },
        @{ Service = 'Intune'; Command = 'Get-MgDeviceManagementManagedDevice'; Entra = 'LookupSucceededCorrelationBlocked'; Intune = 'FailedLookup'; Autopilot = 'NotAttempted' },
        @{ Service = 'Autopilot'; Command = 'Get-MgDeviceManagementWindowsAutopilotDeviceIdentity'; Entra = 'LookupSucceededCorrelationBlocked'; Intune = 'LookupSucceededCorrelationBlocked'; Autopilot = 'FailedLookup' }
    ) {
        Mock $Command -ModuleName StaleDeviceCleanup { throw 'Lookup denied' }
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        Should -Invoke Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $rows = Import-Csv (Join-Path $run.FullName 'ScrappedDeviceResults.csv')
        $rows.MatchStatus | Should -Be 'LookupFailed'
        $rows.EntraLookupStatus | Should -Be $Entra
        $rows.IntuneLookupStatus | Should -Be $Intune
        $rows.AutopilotLookupStatus | Should -Be $Autopilot
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.ExitCode | Should -Be 4
        $summary.DiscoveryComplete | Should -BeFalse
    }

    It 'distinguishes Entra absence from a newly deleted object' {
        Mock Remove-MgDevice -ModuleName StaleDeviceCleanup { throw 'Request_ResourceNotFound' }
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalScrappedEntraDevicesRemoved | Should -Be 0
        $summary.TotalScrappedEntraDevicesAlreadyRemoved | Should -Be 1
        $summary.TotalScrappedComplete | Should -Be 1
    }

    It 'handles all corroborated targets once with <Transport>' -ForEach @(
        @{ Transport = 'Individual' }, @{ Transport = 'JsonBatch' }
    ) {
        Mock Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup {
            @((New-ScrappedIntuneFixture), (New-ScrappedIntuneFixture -Id intune2))
        }
        Mock Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup {
            @((New-ScrappedAutopilotFixture), (New-ScrappedAutopilotFixture -Id ap2 -ManagedId intune2))
        }
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion -DeletionTransport $Transport
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 2 -Exactly -ParameterFilter { $Method -eq 'GET' }
        if ($Transport -eq 'Individual') {
            Should -Invoke Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 2 -Exactly
            Should -Invoke Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 2 -Exactly
            Should -Invoke Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -Exactly
        } else {
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalScrappedIntuneDevicesRemoved | Should -Be 2
        $summary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 2
        $summary.TotalScrappedEntraDevicesRemoved | Should -Be 1
        $summary.TotalScrappedComplete | Should -Be 1
    }

    It 'continues an unrelated serial after Entra deletion failure with <Transport>' -ForEach @(
        @{ Transport = 'Individual' }, @{ Transport = 'JsonBatch' }
    ) {
        Set-Content $script:csv @('SerialNumber', 'SERIAL1', 'SERIAL2')
        Mock Get-MgDevice -ModuleName StaleDeviceCleanup {
            @((New-TestEntraDevice -Id entra1 -DeviceId device1), (New-TestEntraDevice -Id entra2 -DeviceId device2))
        }
        Mock Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup {
            @((New-ScrappedIntuneFixture), (New-ScrappedIntuneFixture -Id intune2 -DeviceId device2 -Serial SERIAL2))
        }
        Mock Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup {
            @((New-ScrappedAutopilotFixture), (New-ScrappedAutopilotFixture -Id ap2 -DeviceId device2 -ManagedId intune2 -Serial SERIAL2))
        }
        Mock Remove-MgDevice -ModuleName StaleDeviceCleanup { if ($DeviceId -eq 'entra1') { throw 'Denied Entra deletion' } }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'POST' } {
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; status = $(if ($_.id -eq 'entra-entra1') { 400 } else { 204 }) }
            }) }
        }
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion -DeletionTransport $Transport
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $rows = Import-Csv (Join-Path $run.FullName 'ScrappedDeviceResults.csv')
        ($rows | Where-Object EntraObjectId -eq 'entra1').EntraRemovalStatus | Should -Be 'RemovalFailed'
        ($rows | Where-Object EntraObjectId -eq 'entra2').EntraRemovalStatus | Should -Be 'Removed'
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalScrappedComplete | Should -Be 1
        $summary.TotalScrappedPartial | Should -Be 1
        $summary.ExitCode | Should -Be 6
    }

    It 'requests only read scopes in scrapped Audit' {
        & $script:entry @script:invoke
        Should -Invoke Connect-MgGraph -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Scopes.Count -eq 3 -and $Scopes -contains 'Device.Read.All' -and
                $Scopes -notcontains 'Directory.AccessAsUser.All' -and
                $Scopes -notcontains 'DeviceManagementServiceConfig.ReadWrite.All'
        }
    }

    It 'retains Individual verification columns when the first serial is unmatched' {
        Set-Content $script:csv @('SerialNumber', 'UNKNOWN', 'SERIAL1')
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $rows = Import-Csv (Join-Path $run.FullName 'ScrappedDeviceResults.csv')
        ($rows | Where-Object InputSerialNumber -eq UNKNOWN).AutopilotVerificationStatus | Should -Be 'NotRequested'
        ($rows | Where-Object AutopilotIdentityId | Select-Object -First 1).AutopilotVerificationStatus | Should -Be 'VerifiedAbsent'
    }

    It 'does not report Complete when optional <Service> verification is <Readback>' -ForEach @(
        @{ Service = 'Intune'; Readback = 'OK'; Outcome = 'Pending' },
        @{ Service = 'Intune'; Readback = 'Forbidden'; Outcome = 'Partial' },
        @{ Service = 'Entra'; Readback = 'OK'; Outcome = 'Pending' },
        @{ Service = 'Entra'; Readback = 'Forbidden'; Outcome = 'Partial' }
    ) {
        $filter = if ($Service -eq 'Intune') { { $Method -eq 'GET' -and $Uri -like '*/managedDevices/*' } }
        else { { $Method -eq 'GET' -and $Uri -like '*/devices/*' } }
        $responseMock = if ($Readback -eq 'OK') {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK) }
        } else {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden) }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter $filter -MockWith $responseMock
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion -DeletionTransport JsonBatch -VerifyDeletion
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalScrappedComplete | Should -Be 0
        $summary.("TotalScrapped$Outcome") | Should -Be 1 -Because (Get-Content (Join-Path $run.FullName 'ScrappedDeviceResults.csv') -Raw)
        $summary.ExitCode | Should -Be 6
    }

    It 'requires verified absence for already-removed Autopilot-only hardware with <Readback>' -ForEach @(
        @{ Readback = 'OK'; Outcome = 'Pending' },
        @{ Readback = 'Forbidden'; Outcome = 'Blocked' }
    ) {
        Mock Get-MgDevice -ModuleName StaleDeviceCleanup { @() }
        Mock Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup { @() }
        Mock Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup { throw 'ZtdDeviceAlreadyDeleted' }
        $responseMock = if ($Readback -eq 'OK') {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK) }
        } else {
            { [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden) }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } -MockWith $responseMock
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalScrappedComplete | Should -Be 0
        $summary.("TotalScrapped$Outcome") | Should -Be 1 -Because (Get-Content (Join-Path $run.FullName 'ScrappedDeviceResults.csv') -Raw)
        $summary.ExitCode | Should -Be 6
    }

    It 'blocks all deletion without Entra write scope for expanded scrapped cleanup' {
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{
                TenantId = 'tenant1'; AuthType = 'Delegated'
                Scopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All',
                    'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
            }
        }
        & $script:entry @script:invoke -Mode Automatic -ConfirmDeletion
        Should -Invoke Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
        (Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json).ExitCode | Should -Be 4
    }
}
