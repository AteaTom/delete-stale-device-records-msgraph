#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Connect-MgGraph { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) throw 'Unmocked authentication prohibited.' }
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) throw 'Unmocked discovery prohibited.' }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) throw 'Unmocked discovery prohibited.' }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All) throw 'Unmocked discovery prohibited.' }
    function global:Get-MgContext { throw 'Unmocked context prohibited.' }
    function global:Get-MgRequestContext { }
    function global:Set-MgRequestContext { param([int]$MaxRetry) }
    function global:Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType, [string]$OutputType, [switch]$SkipHttpErrorCheck)
        throw 'Unmocked Graph request prohibited.'
    }
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:entry = Join-Path $PSScriptRoot '..\src\Invoke-StaleDeviceCleanup.ps1'
}

Describe 'Two independent invocations with persistent evidence' {
    BeforeEach {
        $global:TwoRunTestState = @{ Round = 1; Sync = $null; StillRegistered = $false }
        $script:retainedPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:twoRunOutput = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:twoRunCsv = Join-Path $TestDrive 'two-run.csv'
        Set-Content $script:twoRunCsv @('SerialNumber', 'SERIAL1')
        Mock Test-Prerequisites -ModuleName StaleDeviceCleanup { }
        Mock Connect-MgGraph -ModuleName StaleDeviceCleanup { }
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{
                TenantId = 'two-run-tenant'; AuthType = 'Delegated'; Environment = 'Global'
                Scopes = @('Device.Read.All', 'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All',
                    'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
            }
        }
        Mock Get-MgDevice -ModuleName StaleDeviceCleanup {
            @(New-TestEntraDevice -Id entra1 -DeviceId device1 -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-400)))
        }
        Mock Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup {
            if ($global:TwoRunTestState.Round -eq 1) {
                @([PSCustomObject]@{
                    Id = 'intune1'; AzureAdDeviceId = 'device1'; SerialNumber = 'SERIAL1'
                    LastSyncDateTime = $global:TwoRunTestState.Sync; OperatingSystem = 'Windows'; DeviceName = 'SYNTHETIC'
                })
            } else { @() }
        }
        Mock Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup {
            if ($global:TwoRunTestState.Round -eq 1 -or $global:TwoRunTestState.StillRegistered) {
                @([PSCustomObject]@{
                    Id = 'ap1'; AzureActiveDirectoryDeviceId = 'device1'; ManagedDeviceId = 'intune1'
                    SerialNumber = 'SERIAL1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null
                })
            } else { @() }
        }
        Mock Get-MgRequestContext -ModuleName StaleDeviceCleanup { [PSCustomObject]@{ MaxRetry = 3 } }
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup { }
        Mock Start-Sleep -ModuleName StaleDeviceCleanup { throw 'No completion polling is permitted.' }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            if ($global:TwoRunTestState.Round -eq 1) { $Body | Should -Not -Match '/devices/' }
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; status = 204 }
            }) }
        }
    }

    It 'uses the inactivity threshold after deregistration for <Case>' -ForEach @(
        @{ Case = 'recent retained Intune activity'; Age = 10; StillRegistered = $false; Expected = 'RecentActivityDetected'; DeleteCount = 0 },
        @{ Case = 'old retained Intune activity'; Age = 300; StillRegistered = $false; Expected = 'Stale'; DeleteCount = 1 },
        @{ Case = 'missing Intune activity'; Age = 0; StillRegistered = $false; Expected = 'UnresolvedSafetyEvidence'; DeleteCount = 0 },
        @{ Case = 'still-pending Autopilot'; Age = 300; StillRegistered = $true; Expected = 'AutopilotProtected'; DeleteCount = 0 }
    ) {
        $global:TwoRunTestState.Sync = if ($Age) { [datetime]::UtcNow.AddDays(-$Age) } else { $null }
        $global:TwoRunTestState.StillRegistered = $StillRegistered
        & $script:entry -ScrappedDevices -ScrappedDeviceCsvPath $script:twoRunCsv `
            -Mode Automatic -ConfirmDeletion -EvidencePath $script:retainedPath -OutputPath $script:twoRunOutput
        $first = Get-ChildItem $script:twoRunOutput -Directory | Select-Object -First 1
        $firstSummary = Get-Content (Join-Path $first.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $firstSummary.TotalScrappedEntraToRemove | Should -Be 0
        $firstSummary.TotalScrappedEntraDevicesRemoved | Should -Be 0
        $firstSummary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 1
        $firstSummary.ExitCode | Should -Be 0

        $global:TwoRunTestState.Round = 2
        & $script:entry -DaysInactive 180 -Mode Automatic -ConfirmDeletion `
            -EvidencePath $script:retainedPath -OutputPath $script:twoRunOutput
        $second = Get-ChildItem $script:twoRunOutput -Directory | Where-Object FullName -ne $first.FullName | Select-Object -First 1
        $rows = @(Import-Csv (Join-Path $second.FullName 'AllEvaluatedDevices.csv'))
        $rows.Count | Should -Be 1
        $rows[0].ReasonCode | Should -Be $Expected
        $summary = Get-Content (Join-Path $second.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $summary.TotalEntraDevicesRemoved | Should -Be $DeleteCount
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times $DeleteCount -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Body -match '/devices/entra1'
        }
        Should -Invoke Start-Sleep -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'blocks all tenant writes when safety evidence cannot be saved' {
        Mock Update-DeviceCleanupEvidence { throw [System.IO.IOException]::new('Synthetic save failure') }
        $global:TwoRunTestState.Sync = [datetime]::UtcNow.AddDays(-300)
        & $script:entry -ScrappedDevices -ScrappedDeviceCsvPath $script:twoRunCsv `
            -Mode Automatic -ConfirmDeletion -EvidencePath $script:retainedPath -OutputPath $script:twoRunOutput
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        $run = Get-ChildItem $script:twoRunOutput -Directory | Select-Object -First 1
        (Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json).ExitCode | Should -Be 3
    }

    It 'blocks all tenant writes when initialized safety evidence is corrupt' {
        $saved = Open-DeviceCleanupEvidence -Path $script:retainedPath -TenantId two-run-tenant
        try {
            Update-DeviceCleanupEvidence -Evidence $saved -EntraDevices @() -Indexes (New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @())
            Set-Content -LiteralPath $saved.Path -Value '{malformed'
        } finally { $saved.Lock.Dispose() }
        $global:TwoRunTestState.Sync = [datetime]::UtcNow.AddDays(-300)
        $global:TwoRunTestState.StillRegistered = $false
        & $script:entry -ScrappedDevices -ScrappedDeviceCsvPath $script:twoRunCsv `
            -Mode Automatic -ConfirmDeletion -EvidencePath $script:retainedPath -OutputPath $script:twoRunOutput
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        $run = Get-ChildItem $script:twoRunOutput -Directory | Select-Object -First 1
        (Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json).ExitCode | Should -Be 3
    }

    AfterAll { Remove-Variable -Name TwoRunTestState -Scope Global -ErrorAction SilentlyContinue }
}
