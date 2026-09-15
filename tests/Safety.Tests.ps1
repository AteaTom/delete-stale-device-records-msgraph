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
    function global:Invoke-MgGraphRequest { param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType) }

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

        $scriptContent | Should -Match "Get-ScrappedDeviceSerialNumbers'.*ErrorAction SilentlyContinue"
        $scriptContent | Should -Match "getScrappedSerialsCommand\.Parameters\.ContainsKey\('Statistics'\)"
        $scriptContent | Should -Match "showScrappedSummaryCommand\.Parameters\.ContainsKey\('CsvDuplicateCount'\)"
        $scriptContent | Should -Match "Get-Command -Name 'Submit-WindowsAutopilotBulkRemoval'.*ErrorAction SilentlyContinue"
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
    It 'Disable-EntraDeviceRecord updates accountEnabled to false' {
        Mock -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Disable-EntraDeviceRecord -EntraObjectId 'obj1' -Confirm:$false | Out-Null
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $DeviceId -eq 'obj1' -and $BodyParameter.accountEnabled -eq $false
        }
    }

    It 'Disable-EntraDeviceRecord does not call Graph under -WhatIf' {
        Mock -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Disable-EntraDeviceRecord -EntraObjectId 'obj1' -WhatIf -Confirm:$false | Out-Null
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

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
}

Describe 'End-to-end mode behavior (fully mocked Graph)' {
    BeforeAll {
        Mock -CommandName Connect-MgGraph -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{ TenantId = 'tenant1'; AuthType = 'Delegated'; Scopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All', 'Device.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All') }
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
    }

    AfterEach {
        Remove-Item -Path $script:runOutputPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Audit mode never calls a destructive Graph operation' {
        & $script:scriptPath -Mode Audit -DaysInactive 180 -OutputPath $script:runOutputPath
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'Automatic mode without -ConfirmDeletion never calls a destructive Graph operation' {
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'Automatic mode disables a stale Entra device before removal eligibility' {
        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'bulk-submits Autopilot and disables an active stale Entra device when accepted' {
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = 'STALE-SERIAL-1'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $DeviceId -eq 'obj1' }
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'defers permanent Entra removal until a later run confirms Autopilot is absent' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = 'STALE-SERIAL-1'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -DaysDisabled 30 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        $result[0].AutopilotRemovalStatus | Should -Be 'RemovalSubmitted'
        $result[0].EntraRemovalStatus | Should -Be 'PendingAutopilotRemoval'
    }

    It 'does not simulate permanent Entra removal under WhatIf while Autopilot is still present' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith { }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -DaysDisabled 30 -OutputPath $script:runOutputPath -ConfirmDeletion -WhatIf

        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        $result[0].AutopilotRemovalStatus | Should -Be 'WhatIf'
        $result[0].EntraRemovalStatus | Should -Be 'PendingAutopilotRemoval'
    }

    It 'removes an eligible disabled Entra device when a later discovery finds no Autopilot record' {
        New-Item -ItemType Directory -Path $script:runOutputPath -Force | Out-Null
        @{ obj1 = @{ DisabledSinceUtc = (Get-Date).ToUniversalTime().AddDays(-40).ToString('o') } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runOutputPath 'DeviceLifecycleState.json')
        Mock -CommandName Get-MgDevice -ModuleName StaleDeviceCleanup -MockWith {
            @((New-TestEntraDevice -Id 'obj1' -DeviceId 'dev1' -DisplayName 'STALE-WIN01' -AccountEnabled $false))
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith { @() }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith { }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -DaysDisabled 30 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $DeviceId -eq 'obj1' }
    }

    It 'blocks the Entra action when stale-device Autopilot bulk submission fails' {
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = 'STALE-SERIAL-1'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null })
        }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = 'STALE-SERIAL-1'; deviceRegistrationId = 'ap1'; deletionState = 'failed'; errorMessage = 'Service rejected deletion.' }) }
        }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion

        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $result = Import-Csv -LiteralPath (Join-Path $runFolder.FullName 'AllEvaluatedDevices.csv')
        $result[0].AutopilotRemovalStatus | Should -Be 'RemovalFailed'
        $result[0].EntraRemovalStatus | Should -Be 'SkippedAutopilotSubmissionFailed'
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

    It 'executes the scrapped-device branch and exits before running the stale lifecycle flow when the CSV path is supplied' {
        $scrappedPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-branch-$(New-Guid).csv"
        Set-Content -LiteralPath $scrappedPath -Value @('5CD3271HSD')

        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{
                TenantId = 'tenant1'
                AuthType = 'Delegated'
                Scopes = @(
                    'Device.Read.All',
                    'DeviceManagementManagedDevices.Read.All',
                    'DeviceManagementServiceConfig.Read.All',
                    'Device.ReadWrite.All',
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
            @([PSCustomObject]@{ Id = 'intune1'; AzureAdDeviceId = 'dev1'; SerialNumber = '5CD3271HSD'; DeviceName = 'STALE-WIN01' })
        }
        Mock -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -MockWith { }
        Mock -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -MockWith {
            @{ value = @([PSCustomObject]@{ serialNumber = '5CD3271HSD'; deviceRegistrationId = 'ap1'; deletionState = 'accepted'; errorMessage = $null }) }
        }

        & $script:scriptPath -Mode Automatic -DaysInactive 180 -OutputPath $script:runOutputPath -ConfirmDeletion -ScrappedDeviceCsvPath $scrappedPath

        Assert-MockCalled -CommandName Update-MgDevice -ModuleName StaleDeviceCleanup -Times 0
        Assert-MockCalled -CommandName Remove-MgDevice -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $DeviceId -eq 'obj1' }
        Assert-MockCalled -CommandName Remove-MgDeviceManagementManagedDevice -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0
        $runFolder = Get-ChildItem -Path $script:runOutputPath -Directory | Select-Object -First 1
        $executionLog = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'ExecutionLog.txt') -Raw
        $executionLog | Should -Match 'Scrapped device removals completed: Autopilot submissions accepted=1; Intune removed=1; Entra removed=1\.'
        $runSummary = Get-Content -LiteralPath (Join-Path $runFolder.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
        $runSummary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 1
        $runSummary.TotalScrappedIntuneDevicesRemoved | Should -Be 1
        $runSummary.TotalScrappedEntraDevicesRemoved | Should -Be 1
        $runSummary.TotalErrors | Should -Be 0

        Remove-Item -Path $scrappedPath -Force -ErrorAction SilentlyContinue
    }

    It 'shows the scrapped-device summary before interactive deletion confirmation' {
        $scrappedPath = Join-Path ([System.IO.Path]::GetTempPath()) "scrapped-summary-$(New-Guid).csv"
        Set-Content -LiteralPath $scrappedPath -Value @('5CD3271HSD', '5cd3271hsd')
        $global:scrappedSummaryShown = $false

        Mock -CommandName Get-MgContext -ModuleName StaleDeviceCleanup -MockWith {
            [PSCustomObject]@{
                TenantId = 'tenant1'
                AuthType = 'Delegated'
                Scopes = @(
                    'Device.Read.All',
                    'DeviceManagementManagedDevices.Read.All',
                    'DeviceManagementServiceConfig.Read.All',
                    'Device.ReadWrite.All',
                    'DeviceManagementManagedDevices.ReadWrite.All',
                    'DeviceManagementServiceConfig.ReadWrite.All'
                )
            }
        }
        Mock -CommandName Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -MockWith {
            @([PSCustomObject]@{ Id = 'ap1'; AzureActiveDirectoryDeviceId = 'dev1'; ManagedDeviceId = $null; SerialNumber = '5CD3271HSD'; EnrollmentState = 'enrolled' })
        }
        Mock -CommandName Write-Host -ModuleName StaleDeviceCleanup -ParameterFilter { $Object -eq 'Scrapped-device cleanup summary' } -MockWith {
            $global:scrappedSummaryShown = $true
        }
        Mock -CommandName Write-Host -ModuleName StaleDeviceCleanup -ParameterFilter { $Object -eq '  Duplicate CSV rows ignored:    1' } -MockWith { }
        Mock -CommandName Read-Host -ModuleName StaleDeviceCleanup -MockWith {
            $global:scrappedSummaryShown | Should -BeTrue
            return ''
        }

        & $script:scriptPath -Mode Interactive -DaysInactive 180 -OutputPath $script:runOutputPath -ScrappedDeviceCsvPath $scrappedPath

        Assert-MockCalled -CommandName Read-Host -ModuleName StaleDeviceCleanup -Times 1
        Assert-MockCalled -CommandName Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Object -eq '  Duplicate CSV rows ignored:    1' }
        Assert-MockCalled -CommandName Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -ModuleName StaleDeviceCleanup -Times 0

        Remove-Variable -Name scrappedSummaryShown -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Path $scrappedPath -Force -ErrorAction SilentlyContinue
    }
}
