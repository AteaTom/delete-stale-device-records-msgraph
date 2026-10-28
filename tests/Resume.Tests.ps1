#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgContext { throw 'Unmocked tenant access is prohibited.' }
    function global:Get-MgRequestContext { throw 'Unmocked tenant access is prohibited.' }
    function global:Set-MgRequestContext { param([int]$MaxRetry) throw 'Unmocked tenant access is prohibited.' }
    function global:Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType, [string]$OutputType, [switch]$SkipHttpErrorCheck)
        throw 'Unmocked tenant access is prohibited.'
    }
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:entry = Join-Path $PSScriptRoot '..\src\Invoke-StaleDeviceCleanup.ps1'
}

Describe 'Journal-based Entra resumption' {
    BeforeEach {
        $script:sourcePath = Join-Path $TestDrive 'original'
        New-Item $script:sourcePath -ItemType Directory -Force | Out-Null
        $script:row = [PSCustomObject]@{
            RunId = 'original'; InputSerialNumber = 'SERIAL1'; NormalizedSerialNumber = 'serial1'
            MatchStatus = 'Matched'; AmbiguityReason = ''
            EntraObjectId = 'entra1'; EntraDeviceId = 'device1'; EntraDeviceName = 'OLD'
            IntuneManagedDeviceId = 'intune1'; IntuneDeviceName = 'OLD'
            AutopilotIdentityId = 'ap1'; AutopilotEnrollmentState = 'enrolled'
            IntuneRemovalStatus = 'Removed'; AutopilotRemovalStatus = 'OutcomeUnknown'
            EntraRemovalStatus = 'BlockedDependency'; ErrorMessage = ''
        }
        $script:plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId original -Workflow Scrapped -Records @($script:row)
        $script:plan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $script:sourcePath 'DeletionPlan.json')
        $script:journal = [PSCustomObject]@{
            RunId = 'original'; TenantId = 'tenant1'; PlanHash = $script:plan.Hash; Event = 'Final'
            Results = @(
                foreach ($operation in $script:plan.Operations) {
                    [PSCustomObject]@{
                        Id = $operation.Id; Resource = $operation.Resource; ObjectId = $operation.ObjectId
                        Status = $(switch ($operation.Resource) { Intune { 'Removed' }; Autopilot { 'OutcomeUnknown' }; Entra { 'BlockedDependency' } })
                        HttpStatus = $(switch ($operation.Resource) { Intune { 204 }; Autopilot { 200 }; Entra { 0 } })
                        Attempts = $(if ($operation.Resource -eq 'Entra') { 0 } else { 1 })
                        VerificationStatus = 'NotRequested'; ErrorMessage = ''
                    }
                }
            )
        }
        $script:journal | ConvertTo-Json -Depth 20 -Compress | Set-Content (Join-Path $script:sourcePath 'DeletionJournal.jsonl')
        Export-ReportCsv -InputObject @($script:row) -Path (Join-Path $script:sourcePath 'ScrappedDeviceResults.csv')
        $script:source = Read-DeviceCleanupResumeSource -Path $script:sourcePath
        $script:device = New-TestEntraDevice -Id entra1 -DeviceId device1 -DisplayName CURRENT
        $script:resolve = @{
            Source = $script:source; EntraDevices = @($script:device)
            IntuneDevices = @(); AutopilotDevices = @(); RunId = 'new'
            LogPath = (Join-Path $TestDrive 'resume.log')
        }
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{
                TenantId = 'tenant1'; AuthType = 'Delegated'; Environment = 'Global'
                Scopes = @('Device.Read.All', 'Directory.AccessAsUser.All',
                    'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All')
            }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        }
    }

    It 'creates a fresh Entra-only plan after exact-ID absence without replaying DELETE' {
        $records = @(Resolve-DeviceCleanupResumeRecords @script:resolve)
        $records.Count | Should -Be 1
        $records[0].MatchStatus | Should -Be Matched
        $records[0].EntraObjectId | Should -Be entra1
        $records[0].SourcePlanHash | Should -BeExactly $script:plan.Hash
        $fresh = New-DeviceDeletionPlan -TenantId tenant1 -RunId new -Workflow Scrapped -Records $records
        $fresh.Hash | Should -Not -Be $script:plan.Hash
        $fresh.Operations.Count | Should -Be 1
        $fresh.Operations[0].Resource | Should -Be Entra
        $fresh.Operations[0].Dependencies.Count | Should -Be 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq '/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/ap1'
        }
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }

    It 'blocks a <Readback> Autopilot response' -ForEach @(
        @{ Readback = 'Visible'; Status = [System.Net.HttpStatusCode]::OK },
        @{ Readback = 'Forbidden'; Status = [System.Net.HttpStatusCode]::Forbidden }
    ) {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [System.Net.Http.HttpResponseMessage]::new($Status)
        }
        $records = @(Resolve-DeviceCleanupResumeRecords @script:resolve)
        $records[0].MatchStatus | Should -Be Excluded
        $records[0].AmbiguityReason | Should -Be AutopilotAbsenceNotVerified
        (New-DeviceDeletionPlan -TenantId tenant1 -RunId new -Workflow Scrapped -Records $records).Operations.Count | Should -Be 0
    }

    It 'fails closed for current <Boundary>' -ForEach @(
        @{ Boundary = 'ProtectedObject' }, @{ Boundary = 'ProtectedSerial' }, @{ Boundary = 'ProtectedName' },
        @{ Boundary = 'Synced' }, @{ Boundary = 'Server' }, @{ Boundary = 'UnknownPlatform' },
        @{ Boundary = 'ChangedDeviceId' }, @{ Boundary = 'DuplicateDeviceId' },
        @{ Boundary = 'NewIntuneReference' }, @{ Boundary = 'NewAutopilotSerial' }, @{ Boundary = 'NewIntuneSerial' }
    ) {
        switch ($Boundary) {
            ProtectedObject { $script:resolve.ProtectedEntraObjectIds = @('ENTRA1') }
            ProtectedSerial { $script:resolve.ProtectedSerialNumbers = @('serial1') }
            ProtectedName { $script:resolve.ProtectedNamePatterns = @('CUR*') }
            Synced { $script:device.OnPremisesSyncEnabled = $true }
            Server { $script:device.OperatingSystem = 'Windows Server' }
            UnknownPlatform { $script:device.OperatingSystem = '' }
            ChangedDeviceId { $script:device.DeviceId = 'changed' }
            DuplicateDeviceId { $script:resolve.EntraDevices += New-TestEntraDevice -Id duplicate -DeviceId device1 }
            NewIntuneReference {
                $script:resolve.IntuneDevices = @([PSCustomObject]@{ Id = 'new'; AzureAdDeviceId = 'device1'; SerialNumber = 'different' })
            }
            NewAutopilotSerial {
                $script:resolve.AutopilotDevices = @([PSCustomObject]@{ Id = 'new'; AzureActiveDirectoryDeviceId = ''; ManagedDeviceId = ''; SerialNumber = 'SERIAL1' })
            }
            NewIntuneSerial {
                $script:resolve.IntuneDevices = @([PSCustomObject]@{ Id = 'new'; AzureAdDeviceId = ''; SerialNumber = 'SERIAL1' })
            }
        }
        $records = @(Resolve-DeviceCleanupResumeRecords @script:resolve)
        $records[0].MatchStatus | Should -Be Excluded
        $records[0].EntraObjectId | Should -BeNullOrEmpty
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'does not resume a failed Intune prerequisite or previously removed Entra object' {
        $script:source.Results['intune-intune1'].Status = 'RemovalFailed'
        (Resolve-DeviceCleanupResumeRecords @script:resolve).AmbiguityReason | Should -Be IntunePrerequisiteUnresolved
        $script:source.Results['entra-entra1'].Status = 'Removed'
        @(Resolve-DeviceCleanupResumeRecords @script:resolve).Count | Should -Be 0
    }

    It 'never resumes an already attempted or uncertain Entra DELETE' {
        $script:source.Results['entra-entra1'].Attempts = 1
        @(Resolve-DeviceCleanupResumeRecords @script:resolve).Count | Should -Be 0
        $script:source.Results['entra-entra1'].Status = 'OutcomeUnknown'
        @(Resolve-DeviceCleanupResumeRecords @script:resolve).Count | Should -Be 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'preserves timestamp precision in old source hashes and creates a fresh plan' {
        $script:plan.CreatedUtc = '2000-01-01T00:00:00.1234000Z'
        $script:plan.Hash = & (Get-Module StaleDeviceCleanup) { param($plan) Get-DeviceDeletionPlanHash -Plan $plan } $script:plan
        $script:journal.PlanHash = $script:plan.Hash
        $script:plan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $script:sourcePath 'DeletionPlan.json')
        $script:journal | ConvertTo-Json -Depth 20 -Compress | Set-Content (Join-Path $script:sourcePath 'DeletionJournal.jsonl')
        $script:resolve.Source = Read-DeviceCleanupResumeSource -Path $script:sourcePath
        $records = @(Resolve-DeviceCleanupResumeRecords @script:resolve)
        $fresh = New-DeviceDeletionPlan -TenantId tenant1 -RunId new -Workflow Scrapped -Records $records
        ([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($fresh.CreatedUtc)).TotalMinutes | Should -BeLessThan 1
        $records[0].MatchStatus | Should -Be Matched
    }

    It 'preserves an existing source output directory when timestamps collide' {
        Mock Get-Date -ModuleName StaleDeviceCleanup { [datetime]'2026-01-01T12:00:00Z' }
        $base = Join-Path $TestDrive 'collision'
        $first = Initialize-ProjectExecution -OutputPath $base
        Set-Content $first.LogPath 'original evidence'
        $second = Initialize-ProjectExecution -OutputPath $base
        $second.OutputPath | Should -Not -Be $first.OutputPath
        Get-Content $first.LogPath | Should -BeExactly 'original evidence'
    }

    It 'reports an absent Entra object without adding a DELETE target' {
        $script:resolve.EntraDevices = @()
        (Resolve-DeviceCleanupResumeRecords @script:resolve).MatchStatus | Should -Be NotFound
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'rejects a mismatched tenant before read-back' {
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ TenantId = 'different'; AuthType = 'Delegated'; Environment = 'Global' }
        }
        { Resolve-DeviceCleanupResumeRecords @script:resolve } | Should -Throw '*tenant*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'rejects <Artifact> source inconsistency' -ForEach @(
        @{ Artifact = 'Plan' }, @{ Artifact = 'JournalTenant' }, @{ Artifact = 'JournalHash' },
        @{ Artifact = 'IncompleteJournal' }, @{ Artifact = 'DuplicateResult' }, @{ Artifact = 'ReportTargets' },
        @{ Artifact = 'MissingResult' }, @{ Artifact = 'ResultTarget' }
    ) {
        switch ($Artifact) {
            Plan {
                $script:plan.Operations[0].ObjectId = 'changed'
                $script:plan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $script:sourcePath 'DeletionPlan.json')
            }
            JournalTenant { $script:journal.TenantId = 'wrong' }
            JournalHash { $script:journal.PlanHash = 'wrong' }
            IncompleteJournal { $script:journal.Event = 'Submitting' }
            DuplicateResult { $script:journal.Results += $script:journal.Results[0] }
            MissingResult { $script:journal.Results = @($script:journal.Results | Select-Object -Skip 1) }
            ResultTarget { $script:journal.Results[0].ObjectId = 'wrong' }
            ReportTargets {
                $script:row.EntraObjectId = 'unapproved'
                Export-ReportCsv -InputObject @($script:row) -Path (Join-Path $script:sourcePath 'ScrappedDeviceResults.csv')
            }
        }
        $script:journal | ConvertTo-Json -Depth 20 -Compress | Set-Content (Join-Path $script:sourcePath 'DeletionJournal.jsonl')
        { Read-DeviceCleanupResumeSource -Path $script:sourcePath } | Should -Throw '*Resume blocked*'
    }

    Context 'Latest journal discovery' {
        BeforeEach {
            $script:latestRoot = Join-Path $TestDrive 'latest'
            New-Item $script:latestRoot -ItemType Directory -Force | Out-Null
            $script:older = Join-Path $script:latestRoot 'z-older'
            $script:newer = Join-Path $script:latestRoot 'a-newer'
            $script:saveFixture = {
                param([string]$Path)
                $script:plan.Hash = & (Get-Module StaleDeviceCleanup) { param($plan) Get-DeviceDeletionPlanHash -Plan $plan } $script:plan
                $script:journal.PlanHash = $script:plan.Hash
                $script:journal.TenantId = $script:plan.TenantId
                New-Item $Path -ItemType Directory -Force | Out-Null
                $script:plan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Path 'DeletionPlan.json')
                $script:journal | ConvertTo-Json -Depth 20 -Compress | Set-Content (Join-Path $Path 'DeletionJournal.jsonl')
                Export-ReportCsv -InputObject @($script:row) -Path (Join-Path $Path 'ScrappedDeviceResults.csv')
            }
            $script:plan.CreatedUtc = [datetime]::UtcNow.AddDays(-2).ToString('o')
            & $script:saveFixture $script:older
            $script:plan.CreatedUtc = [datetime]::UtcNow.AddDays(-1).ToString('o')
            & $script:saveFixture $script:newer
            $script:latestParameters = @{ Path = $script:latestRoot; LogPath = (Join-Path $TestDrive 'latest.log') }
        }

        It 'selects by approved creation time rather than folder name or modification time' {
            (Get-Item $script:older).LastWriteTimeUtc = [datetime]::UtcNow
            $selected = Get-LatestDeviceCleanupResumeSource @script:latestParameters
            $selected.Path | Should -Be $script:newer
            Get-Content $script:latestParameters.LogPath -Raw | Should -Match 'Event=ResumeSourceSelected'
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        }

        It 'skips <Unavailable> sources and selects the older valid journal' -ForEach @(
            @{ Unavailable = 'MissingJournal' }, @{ Unavailable = 'Incomplete' },
            @{ Unavailable = 'Corrupt' }, @{ Unavailable = 'Completed' },
            @{ Unavailable = 'Attempted' }, @{ Unavailable = 'EntraOnly' },
            @{ Unavailable = 'Future' }
        ) {
            switch ($Unavailable) {
                MissingJournal { Remove-Item -LiteralPath (Join-Path $script:newer 'DeletionJournal.jsonl') }
                Incomplete { $script:journal.Event = 'Submitting'; & $script:saveFixture $script:newer }
                Corrupt { Set-Content (Join-Path $script:newer 'DeletionPlan.json') '{bad json' }
                Completed { ($script:journal.Results | Where-Object Resource -eq Entra).Status = 'Removed'; & $script:saveFixture $script:newer }
                Attempted { ($script:journal.Results | Where-Object Resource -eq Entra).Attempts = 1; & $script:saveFixture $script:newer }
                EntraOnly {
                    $script:row.AutopilotIdentityId = ''
                    $script:row.IntuneManagedDeviceId = ''
                    $script:plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId original -Workflow Scrapped -Records @($script:row)
                    $script:journal.Results = @($script:journal.Results | Where-Object Resource -eq Entra)
                    & $script:saveFixture $script:newer
                }
                Future { $script:plan.CreatedUtc = [datetime]::UtcNow.AddDays(1).ToString('o'); & $script:saveFixture $script:newer }
            }
            (Get-LatestDeviceCleanupResumeSource @script:latestParameters).Path | Should -Be $script:older
            if ($Unavailable -in 'Incomplete', 'Corrupt', 'Future') {
                Get-Content $script:latestParameters.LogPath -Raw | Should -Match 'Event=ResumeSourceSkipped'
            }
        }

        It 'requires explicit tenant selection when eligible journals span tenants' {
            $script:plan.TenantId = 'tenant2'
            & $script:saveFixture $script:newer
            { Get-LatestDeviceCleanupResumeSource @script:latestParameters } | Should -Throw '*multiple tenants*'
            (Get-LatestDeviceCleanupResumeSource @script:latestParameters -TenantId tenant1).Path | Should -Be $script:older
            (Get-LatestDeviceCleanupResumeSource @script:latestParameters -TenantId tenant2).Path | Should -Be $script:newer
        }

        It 'rejects an ambiguous latest timestamp' {
            & $script:saveFixture $script:older
            { Get-LatestDeviceCleanupResumeSource @script:latestParameters } | Should -Throw '*timestamp is ambiguous*'
        }

        It 'fails explicitly when no matching source exists' {
            { Get-LatestDeviceCleanupResumeSource @script:latestParameters -TenantId missing } | Should -Throw '*no valid scrapped journal*'
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        }
    }

    Context 'Entrypoint safety and reporting' {
        BeforeEach {
            Mock Test-Prerequisites { $true }
            Mock Connect-DeviceCleanupGraph {
                [PSCustomObject]@{ TenantId = 'tenant1'; AuthType = 'Delegated' }
            }
            Mock Get-EntraDeviceRecords {
                , @([PSCustomObject]@{
                    Id = 'entra1'; DeviceId = 'device1'; DisplayName = 'CURRENT'
                    OperatingSystem = 'Windows'; OnPremisesSyncEnabled = $false
                })
            }
            Mock Get-IntuneManagedDeviceRecords { , @() }
            Mock Get-WindowsAutopilotRecords { , @() }
            Mock Get-MgRequestContext -ModuleName StaleDeviceCleanup { [PSCustomObject]@{ MaxRetry = 3 } }
            Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup { }
            Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'POST' } {
                $requests = @((ConvertFrom-Json $Body).requests)
                @($requests | Where-Object { $_.url -notlike '/devices/*' }).Count | Should -Be 0
                [PSCustomObject]@{ responses = @($requests | ForEach-Object { [PSCustomObject]@{ id = $_.id; status = 204 } }) }
            }
            $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        }

        It 'requires new approval for <ModeCase>' -ForEach @(
            @{ ModeCase = 'Audit' }, @{ ModeCase = 'Unconfirmed' }, @{ ModeCase = 'Cancelled' },
            @{ ModeCase = 'WhatIf' }, @{ ModeCase = 'Confirmed' }
        ) {
            $parameters = @{ ResumeFromRunPath = $script:sourcePath; OutputPath = $script:output }
            switch ($ModeCase) {
                Unconfirmed { $parameters.Mode = 'Automatic' }
                Cancelled { $parameters.Mode = 'Interactive'; Mock Read-Host -ModuleName StaleDeviceCleanup { '' } }
                WhatIf { $parameters.Mode = 'Automatic'; $parameters.ConfirmDeletion = $true; $parameters.WhatIf = $true }
                Confirmed { $parameters.Mode = 'Interactive'; Mock Read-Host -ModuleName StaleDeviceCleanup { 'DELETE' } }
            }
            & $script:entry @parameters
            $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
            $fresh = Get-Content (Join-Path $run.FullName 'DeletionPlan.json') -Raw | ConvertFrom-Json
            $fresh.Operations.Count | Should -Be 1
            $fresh.Operations[0].Resource | Should -Be Entra
            $expected = if ($ModeCase -eq 'Confirmed') { 1 } else { 0 }
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times $expected -Exactly -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Connect-DeviceCleanupGraph -Times 1 -ParameterFilter {
                $TenantId -eq 'tenant1' -and $Scopes -notcontains 'DeviceManagementManagedDevices.ReadWrite.All' -and
                $Scopes -notcontains 'DeviceManagementServiceConfig.ReadWrite.All'
            }
            $report = @(Import-Csv (Join-Path $run.FullName 'ScrappedDeviceResults.csv'))
            $report[0].SourceRunId | Should -Be original
            $report[0].SourceAutopilotIdentityIds | Should -Be ap1
            (Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json).SourceRunId | Should -Be original
            Get-Content (Join-Path $run.FullName 'ExecutionLog.txt') -Raw | Should -Match 'ResumeAutopilotVerification.*Outcome=VerifiedAbsent'
            if ($ModeCase -eq 'Confirmed') { $report[0].EntraRemovalStatus | Should -Be Removed }
            if ($ModeCase -eq 'WhatIf') { $report[0].EntraRemovalStatus | Should -Be WhatIf }
        }

        It 'blocks <Failure> without destructive requests' -ForEach @(
            @{ Failure = 'InvalidSource' }, @{ Failure = 'TenantMismatch' }, @{ Failure = 'DiscoveryFailure' }
        ) {
            $parameters = @{
                ResumeFromRunPath = $script:sourcePath; OutputPath = $script:output
                Mode = 'Automatic'; ConfirmDeletion = $true
            }
            switch ($Failure) {
                InvalidSource { Set-Content (Join-Path $script:sourcePath 'DeletionJournal.jsonl') '{}' }
                TenantMismatch { $parameters.TenantId = 'different' }
                DiscoveryFailure { Mock Get-IntuneManagedDeviceRecords { throw 'Offline discovery failure' } }
            }
            & $script:entry @parameters
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
            if ($Failure -ne 'DiscoveryFailure') { Should -Invoke Connect-DeviceCleanupGraph -Times 0 }
            $run = Get-ChildItem $script:output -Directory | Select-Object -First 1
            $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
            $summary.ExitCode | Should -BeGreaterThan 0
            $summary.TotalRunErrors | Should -Be 1
        }

        It 'automatically locates the source but still enforces <LatestMode> approval' -ForEach @(
            @{ LatestMode = 'Audit' }, @{ LatestMode = 'Unconfirmed' },
            @{ LatestMode = 'WhatIf' }, @{ LatestMode = 'Confirmed' }
        ) {
            New-Item $script:output -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $script:sourcePath -Destination (Join-Path $script:output 'prior') -Recurse
            $parameters = @{ ResumeLatest = $true; OutputPath = $script:output }
            switch ($LatestMode) {
                Unconfirmed { $parameters.Mode = 'Automatic' }
                WhatIf { $parameters.Mode = 'Automatic'; $parameters.ConfirmDeletion = $true; $parameters.WhatIf = $true }
                Confirmed { $parameters.Mode = 'Interactive'; Mock Read-Host -ModuleName StaleDeviceCleanup { 'DELETE' } }
            }
            & $script:entry @parameters
            $expected = if ($LatestMode -eq 'Confirmed') { 1 } else { 0 }
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times $expected -Exactly -ParameterFilter { $Method -eq 'POST' }
            $run = Get-ChildItem $script:output -Directory | Where-Object Name -ne 'prior'
            $summary = Get-Content (Join-Path $run.FullName 'RunSummary.json') -Raw | ConvertFrom-Json
            $summary.SourceRunId | Should -Be original
            Get-Content (Join-Path $run.FullName 'ExecutionLog.txt') -Raw | Should -Match 'Event=ResumeSourceSelected'
        }

        It 'does not connect to Graph when latest discovery finds no source' {
            & $script:entry -ResumeLatest -OutputPath $script:output -Mode Automatic -ConfirmDeletion
            Should -Invoke Connect-DeviceCleanupGraph -Times 0
            Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        }
    }
}
