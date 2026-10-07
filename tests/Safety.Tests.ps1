#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Connect-MgGraph { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) }
    function global:Get-MgContext { }
    function global:Update-MgDevice { param([string]$DeviceId, [hashtable]$BodyParameter) }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }
    function global:Get-MgRequestContext { }
    function global:Set-MgRequestContext {
        [CmdletBinding(SupportsShouldProcess)]param([int]$MaxRetry)
        $PSCmdlet.ShouldProcess('Mock request context', 'Set retry limit') | Out-Null
    }
    function global:Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType, [string]$OutputType)
    }

    $modulePath = Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1'
    Import-Module $modulePath -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:scriptPath = Join-Path $PSScriptRoot '..\src\Invoke-StaleDeviceCleanup.ps1'
}

Describe 'Parameter validation' {
    It 'rejects DaysInactive below 180' {
        { & $script:scriptPath -DaysInactive 179 -Mode Audit -WhatIf } | Should -Throw
    }

    It 'defaults Mode to Audit' {
        $command = Get-Command $script:scriptPath
        $command.Parameters['Mode'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }) | Out-Null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $modeParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
        $default = $modeParam.DefaultValue.Extent.Text
        $default | Should -Be "'Audit'"
    }

    It 'reloads an older module when scrapped-device parameters are missing' {
        $scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw

        $scriptContent | Should -Match "requiredModuleVersion = \[version\]'1\.2\.0'"
        $scriptContent | Should -Match 'loadedModule\.Version -eq \$requiredModuleVersion'
        $scriptContent | Should -Match "Get-Command -Name 'New-RunSummary'.*ErrorAction SilentlyContinue"
        $scriptContent | Should -Match "newRunSummaryCommand\.Parameters\.ContainsKey\('AllowOnPremisesSyncedDeletion'\)"
        $scriptContent | Should -Match "Get-ScrappedDeviceSerialNumbers'.*ErrorAction SilentlyContinue"
        $scriptContent | Should -Match "getScrappedSerialsCommand\.Parameters\.ContainsKey\('Statistics'\)"
        $scriptContent | Should -Match "showScrappedSummaryCommand\.Parameters\.ContainsKey\('CsvDuplicateCount'\)"
        $scriptContent | Should -Match "Get-Command -Name 'Submit-WindowsAutopilotIdentityRemoval'.*ErrorAction SilentlyContinue"
        $scriptContent | Should -Match "Get-Command -Name 'Invoke-ScrappedDeviceBatchRemoval'.*ErrorAction SilentlyContinue"
        $scriptContent | Should -Match "Get-Command -Name 'Invoke-DeviceDeletionPlan'.*ErrorAction SilentlyContinue"
    }
}

Describe 'Request-DeletionConfirmation' {
    It 'defaults to cancellation on empty input' {
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { '' }
        Request-DeletionConfirmation | Should -Be $false
    }

    It 'cancels on ambiguous affirmative responses (Y, YES, J)' {
        foreach ($response in @('Y', 'YES', 'J', 'yes')) {
            Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { $response }.GetNewClosure()
            Request-DeletionConfirmation | Should -Be $false
        }
    }

    It 'permits deletion only on the exact phrase DELETE' {
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { 'DELETE' }
        Request-DeletionConfirmation | Should -Be $true
    }

    It 'is case-sensitive: "delete" (lowercase) does not confirm' {
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { 'delete' }
        Request-DeletionConfirmation | Should -Be $false
    }
}

Describe 'ShouldProcess / WhatIf enforcement on destructive functions' {
    It 'Remove-WindowsAutopilotRecord does not call the Graph cmdlet under -WhatIf' {
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }
        Remove-WindowsAutopilotRecord -WindowsAutopilotDeviceIdentityId 'id1' -WhatIf | Out-Null
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'Remove-EntraDeviceRecord does not call the Graph cmdlet under -WhatIf' {
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Remove-EntraDeviceRecord -EntraObjectId 'obj1' -WhatIf | Out-Null
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'Remove-EntraDeviceRecord does not call the Graph cmdlet when -Confirm:$false is combined with -WhatIf' {
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Remove-EntraDeviceRecord -EntraObjectId 'obj2' -WhatIf -Confirm:$false | Out-Null
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }
}

Describe 'Invoke-GraphWithRetry' {
    It 'retries on a transient (429) failure and eventually succeeds' {
        $script:callCount = 0
        $block = {
            $script:callCount++
            if ($script:callCount -lt 2) { throw [System.Exception]::new('429 Too Many Requests') }
            return 'ok'
        }
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        $result = Invoke-GraphWithRetry -ScriptBlock $block -OperationName 'Test' -MaxRetries 3 -InitialDelaySeconds 1
        $result | Should -Be 'ok'
        $script:callCount | Should -Be 2
    }

    It 'does not retry a permanent (non-transient) failure' {
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        $block = { throw [System.Exception]::new('403 Forbidden') }
        { Invoke-GraphWithRetry -ScriptBlock $block -OperationName 'Test' -MaxRetries 3 -InitialDelaySeconds 1 } | Should -Throw
    }

    It 'gives up after MaxRetries transient failures' {
        Mock -CommandName Start-Sleep -ModuleName StaleDeviceCleanup -MockWith { }
        $block = { throw [System.Exception]::new('503 Service Unavailable') }
        { Invoke-GraphWithRetry -ScriptBlock $block -OperationName 'Test' -MaxRetries 2 -InitialDelaySeconds 1 } | Should -Throw
    }

    It 'includes Graph ErrorDetails in the logged failure message' {
        $testLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "graph-error-$(New-Guid).log"
        $block = {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Bad Request'),
                'BadRequest',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )
            $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"InvalidRequest","message":"Serial list is invalid."}}')
            Write-Error -ErrorRecord $errorRecord -ErrorAction Stop
        }

        { Invoke-GraphWithRetry -ScriptBlock $block -OperationName 'Test details' -LogPath $testLogPath } | Should -Throw

        (Get-Content -LiteralPath $testLogPath -Raw) | Should -Match 'InvalidRequest.*Serial list is invalid'
        Remove-Item -LiteralPath $testLogPath -Force -ErrorAction SilentlyContinue
    }
}

Describe 'End-to-end mode behavior (fully mocked Graph)' {
    BeforeAll {
        Mock -CommandName Connect-MgGraph -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{ TenantId = 'tenant1'; AuthType = 'Delegated'; Scopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All', 'Directory.AccessAsUser.All', 'DeviceManagementServiceConfig.ReadWrite.All') }
        }
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)))
        }
        Mock -CommandName Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { @() }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { @() }
        Mock -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }
    }

    BeforeEach {
        $script:runOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "sdc-e2e-$(New-Guid)"
        Mock Get-MgRequestContext -ModuleName StaleDeviceCleanup { [PSCustomObject]@{ MaxRetry = 3 } }
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup { }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; status = 204 }
            }) }
        }
    }

    AfterEach {
        Remove-Item -Path $script:runOutputPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Audit mode never calls a destructive Graph operation' {
        & $script:scriptPath -Mode Audit -DaysInactive 180 -OutputPath $script:runOutputPath
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'wires batch transport without using individual DELETE cmdlets' {
        & $script:scriptPath -Mode Automatic -ConfirmDeletion -DeletionTransport JsonBatch -OutputPath $script:runOutputPath
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem $script:runOutputPath -Directory | Select-Object -First 1
        (Import-Csv (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv'))[0].EntraRemovalStatus | Should -Be 'Removed'
        Test-Path (Join-Path $runFolder.FullName 'DeletionPlan.json') | Should -BeTrue
        Test-Path (Join-Path $runFolder.FullName 'DeletionJournal.jsonl') | Should -BeTrue
    }

    It 'performs no batch deletion for <Scenario>' -TestCases @(
        @{ Scenario = 'Audit' }, @{ Scenario = 'Unconfirmed' }, @{ Scenario = 'WhatIf' }, @{ Scenario = 'Cancelled' }
    ) {
        param($Scenario)
        $parameters = @{ DeletionTransport = 'JsonBatch'; OutputPath = $script:runOutputPath }
        switch ($Scenario) {
            Audit { $parameters.Mode = 'Audit' }
            Unconfirmed { $parameters.Mode = 'Automatic' }
            WhatIf { $parameters.Mode = 'Automatic'; $parameters.ConfirmDeletion = $true; $parameters.WhatIf = $true }
            Cancelled {
                $parameters.Mode = 'Interactive'
                Mock Read-Host -ModuleName StaleDeviceCleanup { '' }
            }
        }
        & $script:scriptPath @parameters
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem $script:runOutputPath -Directory | Select-Object -First 1
        Test-Path (Join-Path $runFolder.FullName 'DeletionPlan.json') | Should -BeTrue
    }

    It 'persists uncertain batch outcomes and non-success summary on lost response' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup { throw 'Lost batch response' }
        & $script:scriptPath -Mode Automatic -ConfirmDeletion -DeletionTransport JsonBatch -OutputPath $script:runOutputPath
        $runFolder = Get-ChildItem $script:runOutputPath -Directory | Select-Object -First 1
        (Import-Csv (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv'))[0].EntraRemovalStatus | Should -Be 'OutcomeUnknown'
        (Get-Content (Join-Path $runFolder.FullName 'RunSummary.json') -Raw | ConvertFrom-Json).ExitCode | Should -Not -Be 0
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'Automatic mode without -ConfirmDeletion never calls a destructive Graph operation' {
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'passes stale workflow context before interactive confirmation' {
        Mock Show-CleanupSummary -ModuleName StaleDeviceCleanup { }
        Mock Read-Host -ModuleName StaleDeviceCleanup {
            Should -Invoke Show-CleanupSummary -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
                $TenantId -eq 'tenant1' -and $Mode -eq 'Interactive' -and
                -not $Simulation -and $DeletionTransport -eq 'JsonBatch'
            }
            ''
        }
        & $script:scriptPath -Mode Interactive -DeletionTransport JsonBatch -OutputPath $script:runOutputPath
        Should -Invoke Read-Host -ModuleName StaleDeviceCleanup -Times 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'Automatic mode removes a stale Entra device directly' {
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1
    }

    It 'protects an Autopilot-backed stale Entra device from both deletions' {
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'protects a disabled Autopilot-backed Entra device regardless of legacy retention data' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        $result[0].ReasonCode | Should -Be 'AutopilotProtected'
        $result[0].EntraRemovalStatus | Should -Be 'NotAttempted'
    }

    It 'does not simulate permanent Entra removal under WhatIf while Autopilot is still present' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion -WhatIf

        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        $result[0].ReasonCode | Should -Be 'AutopilotProtected'
        $result[0].EntraRemovalStatus | Should -Be 'NotAttempted'
    }

    It 'removes an eligible disabled Entra device when a later discovery finds no Autopilot record' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { @() }
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $DeviceId -eq 'obj1' }
    }

    It 'never attempts stale-device Autopilot removal even when its DELETE would fail' {
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            throw [System.Exception]::new('Service rejected deletion.')
        }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        $result[0].ReasonCode | Should -Be 'AutopilotProtected'
        $result[0].EntraRemovalStatus | Should -Be 'NotAttempted'
    }

    It 'Interactive mode cancels safely on empty confirmation input' {
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { '' }
        & $script:scriptPath -Mode Interactive -DaysInactive 180 -OutputPath $script:runOutputPath
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'reports are written before any confirmation prompt in Interactive mode' {
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { '' }
        & $script:scriptPath -Mode Interactive -DaysInactive 180 -OutputPath $script:runOutputPath
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        Test-Path (Join-Path $runFolder.FullName 'DeletionCandidates.csv') | Should -Be $true
    }

    It 'does not persist newly tracked disabled devices when Interactive mode is cancelled' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        $statePath = Join-Path $script:runOutputPath 'DeviceLifecycleState.json'
        '{}' | Set-Content -LiteralPath $statePath
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith { '' }
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'DISABLED-01' -AccountEnabled $false))
        }

        & $script:scriptPath -Mode Interactive -DaysInactive 180 -OutputPath $script:runOutputPath

        (Get-Content -LiteralPath $statePath -Raw).Trim() | Should -Be '{}'
    }

    It 'executes scrapped-only cleanup with <Transport> after accepted Autopilot deletion' -TestCases @(
        @{ Transport = 'Individual' }, @{ Transport = 'JsonBatch' }
    ) {
        param($Transport)
        $scrappedPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-branch-$(New-Guid).csv"
        Set-Content -LiteralPath $scrappedPath -Value @('SerialNumber', '5CD3271HSD')
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        }

        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{
                TenantId = 'tenant1'
                AuthType = 'Delegated'
                Scopes = @(
                    'Device.Read.All',
                    'DeviceManagementManagedDevices.Read.All',
                    'DeviceManagementServiceConfig.Read.All',
                    'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.ReadWrite.All',
                    'DeviceManagementServiceConfig.ReadWrite.All'
                )
            }
        }
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300)))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = 'intune1'; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' })
        }
        Mock -CommandName Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'intune1'; AzureAdDeviceId = 'dev1'; SerialNumber = '5CD3271HSD'; DeviceName = 'STALE-WIN01'; OperatingSystem = 'Windows' })
        }
        Mock -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { }

        & $script:scriptPath -Mode Automatic -ScrappedDevices -OutputPath $script:runOutputPath -ConfirmDeletion `
            -ScrappedDeviceCsvPath $scrappedPath -DeletionTransport $Transport

        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        if ($Transport -eq 'Individual') {
            Assert-MockCalled Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1
            Assert-MockCalled Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
            Assert-MockCalled Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $WindowsAutopilotDeviceIdentityId -eq 'ap1' }
            Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter { $Method -eq 'GET' }
        } else {
            Assert-MockCalled Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
            Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' }
            Assert-MockCalled Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter { $Method -eq 'GET' }
            Assert-MockCalled Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 0
            Assert-MockCalled Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        }
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $executionLog = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'ExecutionLog.txt') -Raw
        $executionLog | Should -Match 'Scrapped device removals completed: Autopilot accepted=1, already absent=0, failed=0; Intune removed=1, already absent=0, failed=0; Entra removed=1, already absent=0, failed=0, blocked by Autopilot=0\.'
        $runSummary = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $runSummary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 1
        $runSummary.TotalScrappedIntuneDevicesRemoved | Should -Be 1
        $runSummary.TotalScrappedEntraDevicesRemoved | Should -Be 1
        $runSummary.TotalScrappedComplete | Should -Be 1
        $runSummary.PSObject.Properties.Name | Should -Not -Contain 'DaysInactiveThreshold'
        $runSummary.PSObject.Properties.Name | Should -Not -Contain 'CutoffDateUtc'
        $runSummary.TotalErrors | Should -Be 0

        Remove-Item -Path $scrappedPath -Force -ErrorAction SilentlyContinue
    }

    It 'continues after an individual removal failure and exits with code 6' {
        $scrappedPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-partial-$(New-Guid).csv"
        Set-Content -LiteralPath $scrappedPath -Value @('SerialNumber', 'SERIAL-FAIL', 'SERIAL-SUCCEED')

        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{
                TenantId = 'tenant1'
                AuthType = 'Delegated'
                Scopes = @(
                    'Device.Read.All',
                    'DeviceManagementManagedDevices.Read.All',
                    'DeviceManagementServiceConfig.Read.All',
                    'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.ReadWrite.All',
                    'DeviceManagementServiceConfig.ReadWrite.All'
                )
            }
        }
        Mock -CommandName Get-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            @(
                [PSCustomObject]@{ Id = 'intune-fail'; AzureAdDeviceId = $null; SerialNumber = 'SERIAL-FAIL'; DeviceName = 'SCRAPPED-FAIL'; OperatingSystem = 'Windows' },
                [PSCustomObject]@{ Id = 'intune-succeed'; AzureAdDeviceId = $null; SerialNumber = 'SERIAL-SUCCEED'; DeviceName = 'SCRAPPED-SUCCEED'; OperatingSystem = 'Windows' }
            )
        }
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith {
            if ($ManagedDeviceId -eq 'intune-fail') { throw [System.Exception]::new('403 Forbidden') }
        }

        & $script:scriptPath -Mode Automatic -ScrappedDevices -OutputPath $script:runOutputPath `
            -ConfirmDeletion -ScrappedDeviceCsvPath $scrappedPath

        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 2
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $results = @(Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'ScrappedDeviceResults.csv'))
        ($results | Where-Object InputSerialNumber -eq 'SERIAL-FAIL').IntuneRemovalStatus | Should -Be 'RemovalFailed'
        ($results | Where-Object InputSerialNumber -eq 'SERIAL-SUCCEED').IntuneRemovalStatus | Should -Be 'Removed'
        $runSummary = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $runSummary.ExitCode | Should -Be 6
        $runSummary.TotalScrappedIntuneDevicesFailed | Should -Be 1
        $runSummary.TotalScrappedIntuneDevicesRemoved | Should -Be 1

        Remove-Item -Path $scrappedPath -Force -ErrorAction SilentlyContinue
    }

    It 'shows the scrapped-device summary before interactive deletion confirmation' {
        $scrappedPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-summary-$(New-Guid).csv"
        Set-Content -LiteralPath $scrappedPath -Value @('SerialNumber', '5CD3271HSD', '5cd3271hsd')
        $global:scrappedSummaryShown = $false

        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{
                TenantId = 'tenant1'
                AuthType = 'Delegated'
                Scopes = @(
                    'Device.Read.All',
                    'DeviceManagementManagedDevices.Read.All',
                    'DeviceManagementServiceConfig.Read.All',
                    'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.ReadWrite.All',
                    'DeviceManagementServiceConfig.ReadWrite.All'
                )
            }
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' })
        }
        $global:scrappedSummaryLines = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedSummaryLines.Add([string]$Object)
            if ($Object -eq 'Scrapped-device cleanup summary') { $global:scrappedSummaryShown = $true }
        }
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedSummaryShown | Should -BeTrue
            $global:scrappedSummaryLines | Should -Contain 'Workflow: Explicit scrapped hardware deregistration; tenant: tenant1'
            $global:scrappedSummaryLines | Should -Contain 'Mode: Interactive; WhatIf: False; transport: Individual'
            return ''
        }

        & $script:scriptPath -Mode Interactive -ScrappedDevices -OutputPath $script:runOutputPath -ScrappedDeviceCsvPath $scrappedPath

        Assert-MockCalled -CommandName Read-Host -ModuleName StaleDeviceCleanup -Times 1
        $global:scrappedSummaryLines | Should -Contain '  Duplicate CSV rows ignored:    1'
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Sort-Object Name -Descending | Select-Object -First 1
        $runSummary = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $runSummary.ExitCode | Should -Be 5

        Remove-Variable -Name scrappedSummaryShown -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name scrappedSummaryLines -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Path $scrappedPath -Force -ErrorAction SilentlyContinue
    }
}
