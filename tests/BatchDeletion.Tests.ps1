#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgContext { }
    function global:Get-MgRequestContext { }
    function global:Set-MgRequestContext {
        [CmdletBinding(SupportsShouldProcess)]param([int]$MaxRetry)
        $PSCmdlet.ShouldProcess('Mock request context', 'Set retry limit') | Out-Null
    }
    function global:Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, [object]$Body, [string]$ContentType, [string]$OutputType, [switch]$SkipHttpErrorCheck)
    }
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    function New-BatchTestRecords {
        param([int]$Count = 1)
        return , @(for ($i = 0; $i -lt $Count; $i++) {
            [PSCustomObject]@{
                Decision = 'Candidate'; EntraAction = 'Remove'; AutopilotPresent = $false
                EntraObjectId = "obj$i"; EntraRemovalStatus = 'NotAttempted'; ErrorMessage = $null
            }
        })
    }
    function New-ScrappedBatchRecord {
        param([string]$Serial = 'SERIAL1', [string]$IntuneId = 'intune1', [string]$AutopilotId = 'ap1')
        [PSCustomObject]@{
            MatchStatus = 'Matched'; NormalizedSerialNumber = $Serial; IntuneManagedDeviceId = $IntuneId
            AutopilotIdentityId = $AutopilotId; EntraObjectId = 'entra1'
            IntuneRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'
            EntraRemovalStatus = 'NotAttempted'; ErrorMessage = $null
        }
    }
}

Describe 'Guarded JSON batch deletion' {
    BeforeEach {
        $script:journalPath = Join-Path $TestDrive "$([guid]::NewGuid()).jsonl"
        $script:logPath = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        $script:plan = New-DeviceDeletionPlan -TenantId 'tenant1' -RunId 'run1' -Workflow Stale -Records (New-BatchTestRecords)
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{
                TenantId = 'tenant1'; AuthType = 'Delegated'; Environment = 'Global'
                Scopes = @('Directory.AccessAsUser.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
            }
        }
        Mock Get-MgRequestContext -ModuleName StaleDeviceCleanup { [PSCustomObject]@{ MaxRetry = 3 } }
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup { }
        Mock Start-Sleep -ModuleName StaleDeviceCleanup { }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            $requests = @((ConvertFrom-Json $Body).requests)
            [PSCustomObject]@{
                responses = @($requests | Sort-Object id -Descending | ForEach-Object {
                    [PSCustomObject]@{ id = $_.id; status = 204 }
                })
            }
        }
        $script:invoke = @{
            Plan = $script:plan; ApprovalHash = $script:plan.Hash; Mode = 'Automatic'; ConfirmDeletion = $true
            JournalPath = $script:journalPath; LogPath = $script:logPath; Confirm = $false
        }
    }

    It 'never submits destructive requests in Audit' {
        $script:invoke.Mode = 'Audit'
        (Invoke-DeviceDeletionPlan @script:invoke).Status | Should -Be 'NotAttempted'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'sanitizes verification errors before persisting them in journal and device reports' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            throw 'Read-back failed: client_secret="synthetic-private-value"'
        }
        $results = @(Invoke-DeviceDeletionPlan @script:invoke -VerifyDeletion)
        $results[0].Status | Should -Be Removed
        $results[0].VerificationStatus | Should -Be OutcomeUnknown
        $results[0].ErrorMessage | Should -Match 'Read-back failed'
        $results[0].ErrorMessage | Should -Not -Match 'synthetic-private-value'
        (Get-Content $script:journalPath -Raw) | Should -Not -Match 'synthetic-private-value'
        $records = New-BatchTestRecords
        Set-DeviceDeletionResults -Workflow Stale -Records $records -Results $results
        Export-ReportCsv -InputObject $records -Path (Join-Path $TestDrive 'ErrorDevices.csv')
        (Get-Content (Join-Path $TestDrive 'ErrorDevices.csv') -Raw) | Should -Not -Match 'synthetic-private-value'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' }
    }

    It 'never submits without explicit confirmation' {
        $script:invoke.ConfirmDeletion = $false
        Invoke-DeviceDeletionPlan @script:invoke | Out-Null
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'simulates the same operations under WhatIf without SDK calls' {
        (Invoke-DeviceDeletionPlan @script:invoke -WhatIf).Status | Should -Be 'WhatIf'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
        Should -Invoke Set-MgRequestContext -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'enforces the 20-request limit for <Count> targets' -TestCases @(
        @{ Count = 0; Expected = 0 }, @{ Count = 1; Expected = 1 }, @{ Count = 20; Expected = 1 },
        @{ Count = 21; Expected = 2 }, @{ Count = 41; Expected = 3 }
    ) {
        param($Count, $Expected)
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count $Count)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        $results.Count | Should -Be $Count
        @($results | Where-Object Status -ne 'Removed').Count | Should -Be 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times $Expected -Exactly
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter {
            @((ConvertFrom-Json $Body).requests).Count -gt 20 -or @((ConvertFrom-Json $Body).requests).Count -eq 0
        }
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter {
            $Uri -cne '/v1.0/$batch'
        }
    }

    It 'rejects a batch size outside the Graph contract' {
        { Invoke-DeviceDeletionPlan @script:invoke -BatchSize 21 } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'rejects post-approval target mutation' {
        $script:plan.Operations[0].ObjectId = 'different'
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*hash*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'rejects wrong approval hash' {
        $script:invoke.ApprovalHash = 'wrong'
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*hash*'
    }

    It 'rejects expired plans' {
        & (Get-Module StaleDeviceCleanup) {
            param($Plan)
            $Plan.CreatedUtc = [datetime]::UtcNow.AddHours(-1).ToString('o')
            $Plan.Hash = Get-DeviceDeletionPlanHash -Plan $Plan
        } $script:plan
        $script:invoke.ApprovalHash = $script:plan.Hash
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*expired*'
    }

    It 'rejects route injection before creating a plan' {
        $records = New-BatchTestRecords
        $records[0].EntraObjectId = 'obj1?$filter=anything'
        { New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records $records } | Should -Throw '*Invalid*'
    }

    It 'deduplicates immutable object IDs and fans the result out' {
        $records = (New-BatchTestRecords) + (New-BatchTestRecords)
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records $records
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        $results.Count | Should -Be 1
        Set-DeviceDeletionResults -Workflow Stale -Records $records -Results $results
        @($records | Where-Object EntraRemovalStatus -eq 'Removed').Count | Should -Be 2
    }

    It 'does not plan excluded, manual-review or Autopilot-backed stale records' {
        $records = New-BatchTestRecords -Count 3
        $records[0].Decision = 'Excluded'
        $records[1].Decision = 'ManualReview'
        $records[2].AutopilotPresent = $true
        (New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records $records).Operations.Count | Should -Be 0
    }

    It 'preserves verification columns when the first CSV row has no batch result for <Workflow>' -TestCases @(
        @{ Workflow = 'Stale'; Resource = 'Entra' }, @{ Workflow = 'Scrapped'; Resource = 'Intune' },
        @{ Workflow = 'Scrapped'; Resource = 'Autopilot' }
    ) {
        param($Workflow, $Resource)
        $records = if ($Workflow -eq 'Stale') {
            New-BatchTestRecords -Count 2
        } else {
            @((New-ScrappedBatchRecord -Serial SERIAL0 -IntuneId intune0 -AutopilotId ap0), (New-ScrappedBatchRecord))
        }
        $records[0].EntraObjectId = 'excluded'
        $operationId = switch ($Resource) {
            Entra { 'entra-obj1' }
            Intune { 'intune-intune1' }
            Autopilot { 'autopilot-ap1' }
        }
        $result = [PSCustomObject]@{
            Id = $operationId; Status = 'Removed'; VerificationStatus = 'VerifiedAbsent'; ErrorMessage = ''
        }
        Set-DeviceDeletionResults -Workflow $Workflow -Records $records -Results @($result)
        $path = Join-Path $TestDrive 'verification.csv'
        Export-ReportCsv -InputObject $records -Path $path
        $exported = @(Import-Csv $path)
        $exported[0].("${Resource}VerificationStatus") | Should -Be 'NotRequested'
        $exported[1].("${Resource}VerificationStatus") | Should -Be 'VerifiedAbsent'
    }

    It 'blocks mismatched tenant, app-only authentication, missing permission or non-public cloud: <Failure>' -TestCases @(
        @{ Failure = 'Tenant' }, @{ Failure = 'Auth' }, @{ Failure = 'Scope' }, @{ Failure = 'Cloud' }
    ) {
        param($Failure)
        $context = [PSCustomObject]@{ TenantId = 'tenant1'; AuthType = 'Delegated'; Environment = 'Global'; Scopes = @('Directory.AccessAsUser.All') }
        switch ($Failure) {
            Tenant { $context.TenantId = 'wrong' }
            Auth { $context.AuthType = 'AppOnly' }
            Scope { $context.Scopes = @('Device.ReadWrite.All') }
            Cloud { $context.Environment = 'USGov' }
        }
        Mock Get-MgContext -ModuleName StaleDeviceCleanup { $context }.GetNewClosure()
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'checks the tenant again before a later envelope' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count 21)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        $counter = [PSCustomObject]@{ Count = 0 }
        Mock Get-MgContext -ModuleName StaleDeviceCleanup {
            $counter.Count++
            [PSCustomObject]@{
                TenantId = $(if ($counter.Count -eq 1) { 'tenant1' } else { 'wrong' })
                AuthType = 'Delegated'; Scopes = @('Directory.AccessAsUser.All')
            }
        }.GetNewClosure()
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'records 404 as already absent only for Entra' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{
                id = 'entra-obj0'; status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound' } }
            }) }
        }
        $result = Invoke-DeviceDeletionPlan @script:invoke
        $result.Status | Should -Be 'AlreadyAbsent'
        $result.ErrorMessage | Should -BeNullOrEmpty
    }

    It 'preserves successful results but stops on a 403 in outer HTTP success' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count 2)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @(
                [PSCustomObject]@{ id = 'entra-obj1'; status = 403; body = @{ error = @{ code = 'Denied' } } },
                [PSCustomObject]@{ id = 'entra-obj0'; status = 204 }
            ) }
        }
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*authorization*'
        $last = Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json
        ($last.Results | Where-Object Id -eq 'entra-obj0').Status | Should -Be 'Removed'
        ($last.Results | Where-Object Id -eq 'entra-obj1').Status | Should -Be 'RemovalFailed'
    }

    It 'treats <Shape> as unknown rather than success' -TestCases @(
        @{ Shape = 'Missing' }, @{ Shape = 'Duplicate' }, @{ Shape = 'Unexpected' }, @{ Shape = 'Malformed' },
        @{ Shape = 'WrongSuccess' }, @{ Shape = 'ContradictoryBody' }
    ) {
        param($Shape)
        $entry = [PSCustomObject]@{ id = 'entra-obj0'; status = 204 }
        $response = switch ($Shape) {
            Missing { [PSCustomObject]@{ responses = @() } }
            Duplicate { [PSCustomObject]@{ responses = @($entry, $entry) } }
            Unexpected { [PSCustomObject]@{ responses = @($entry, [PSCustomObject]@{ id = 'unknown'; status = 204 }) } }
            Malformed { [PSCustomObject]@{ unrelated = 'value' } }
            WrongSuccess { [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 200 }) } }
            ContradictoryBody { [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 204; body = @{ error = 'bad' } }) } }
        }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup { $response }.GetNewClosure()
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*integrity*'
        (Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json).Results[0].Status | Should -Be 'OutcomeUnknown'
    }

    It 'retries only a throttled operation and honors its Retry-After' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count 2)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            $requests = @((ConvertFrom-Json $Body).requests)
            if ($requests.Count -eq 2) {
                [PSCustomObject]@{ responses = @(
                    [PSCustomObject]@{ id = 'entra-obj0'; status = 204 },
                    [PSCustomObject]@{ id = 'entra-obj1'; status = 429; headers = @{ 'Retry-After' = '7' } }
                ) }
            } else {
                [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj1'; status = 204 }) }
            }
        }
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        ($results | Where-Object Id -eq 'entra-obj0').Attempts | Should -Be 1
        ($results | Where-Object Id -eq 'entra-obj1').Attempts | Should -Be 2
        Should -Invoke Start-Sleep -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Seconds -ge 7 }
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            @((ConvertFrom-Json $Body).requests).Count -eq 1
        }
    }

    It 'exhausts finite retries for HTTP <Code>' -TestCases @(@{ Code = 429 }, @{ Code = 503 }, @{ Code = 504 }) {
        param($Code)
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = $Code }) }
        }.GetNewClosure()
        (Invoke-DeviceDeletionPlan @script:invoke -MaxAttempts 2).Status | Should -Be 'RemovalFailed'
        $log = Get-Content $script:logPath -Raw
        $log | Should -Match 'Event=BatchRetry.*Targets=1'
        ([regex]::Matches($log, 'Event=ActionAttention')).Count | Should -Be 1
        $log | Should -Match 'Outcome=RemovalFailed.*Attempts=2'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 2 -Exactly
    }

    It 'parses case-insensitive HTTP-date Retry-After headers' {
        $date = [datetimeoffset]::UtcNow.AddSeconds(15).ToString('r')
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{
                id = 'entra-obj0'; status = 429; headers = [PSCustomObject]@{ 'retry-after' = $date }
            }) }
        }.GetNewClosure()
        (Invoke-DeviceDeletionPlan @script:invoke -MaxAttempts 2).Status | Should -Be 'RemovalFailed'
        Should -Invoke Start-Sleep -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $Seconds -gt 5 }
    }

    It 'halts before Graph when durable intent cannot be created' {
        $script:invoke.JournalPath = Join-Path $TestDrive 'nonexistent\journal.jsonl'
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'does not sleep beyond the elapsed retry budget' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 429; headers = @{ 'Retry-After' = '1000' } }) }
        }
        (Invoke-DeviceDeletionPlan @script:invoke -RetryBudgetSeconds 1).Status | Should -Be 'RemovalFailed'
        Should -Invoke Start-Sleep -ModuleName StaleDeviceCleanup -Times 0
    }

    It 'does not resubmit when backoff returns after the retry deadline' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 429 }) }
        }
        Mock Start-Sleep -ModuleName StaleDeviceCleanup {
            [System.Threading.Thread]::Sleep(3100)
        }
        (Invoke-DeviceDeletionPlan @script:invoke -RetryBudgetSeconds 3).Status | Should -Be 'RemovalFailed'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'does not retry a permanent subrequest error' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 400 }) }
        }
        $result = Invoke-DeviceDeletionPlan @script:invoke
        $result.Status | Should -Be 'RemovalFailed'
        $result.ErrorMessage | Should -Match '400'
        $log = Get-Content $script:logPath -Raw
        $log | Should -Match 'Event=ActionAttention.*ObjectId=obj0.*Outcome=RemovalFailed.*HTTP=400'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'never replays an envelope when its response is lost and restores SDK retry settings' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup { throw 'Timeout' }
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*Reconcile*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
        Should -Invoke Set-MgRequestContext -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $MaxRetry -eq 0 }
        Should -Invoke Set-MgRequestContext -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter { $MaxRetry -eq 3 }
        $last = Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json
        $last.Results[0].Status | Should -Be 'OutcomeUnknown'
        $last.Results[0].ErrorMessage | Should -Match 'Timeout'
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*journal already exists*'
    }

    It 'surfaces the underlying envelope error while preserving earlier successful chunks' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count 41)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        $state = [PSCustomObject]@{ Calls = 0 }
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            param($Body)
            $state.Calls++
            if ($state.Calls -eq 2) { throw 'Invalid URI: The format of the URI could not be determined.' }
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; status = 204 }
            }) }
        }.GetNewClosure()
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*Invalid URI*Reconcile*'
        $final = Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json
        @($final.Results | Where-Object Status -eq Removed).Count | Should -Be 20
        @($final.Results | Where-Object Status -eq OutcomeUnknown).Count | Should -Be 20
        @($final.Results | Where-Object Status -eq NotAttempted).Count | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 2 -Exactly
    }

    It 'preserves received outcomes and stops when SDK retry restoration fails' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Stale -Records (New-BatchTestRecords -Count 21)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup -ParameterFilter { $MaxRetry -eq 3 } {
            throw 'Cannot restore retry settings'
        }
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*retry restoration failed*journaled*'
        $final = Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json
        @($final.Results | Where-Object Status -eq Removed).Count | Should -Be 20
        @($final.Results | Where-Object Status -eq NotAttempted).Count | Should -Be 1
        @($final.Results | Where-Object Status -eq OutcomeUnknown).Count | Should -Be 0
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'preserves the request error when SDK retry restoration also fails' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup { throw 'Request timed out' }
        Mock Set-MgRequestContext -ModuleName StaleDeviceCleanup -ParameterFilter { $MaxRetry -eq 3 } {
            throw 'Cannot restore retry settings'
        }
        { Invoke-DeviceDeletionPlan @script:invoke } | Should -Throw '*Request timed out*restoration also failed*'
        $final = Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json
        $final.Results[0].Status | Should -Be 'OutcomeUnknown'
        $final.Results[0].ErrorMessage | Should -Match 'Request timed out.*Cannot restore retry settings'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'writes intent before making the destructive call' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            (Get-Content $script:journalPath -Tail 1 | ConvertFrom-Json).Event | Should -Be 'Submitting'
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'entra-obj0'; status = 204 }) }
        }
        Invoke-DeviceDeletionPlan @script:invoke | Out-Null
    }

    It 'blocks Autopilot and Entra after a failed Intune prerequisite' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Scrapped -Records @(New-ScrappedBatchRecord)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        @($script:invoke.Plan.Operations | Where-Object Resource -eq 'Entra').Count | Should -Be 1
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'intune-intune1'; status = 400 }) }
        }
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        ($results | Where-Object Resource -eq 'Autopilot').Status | Should -Be 'BlockedDependency'
        ($results | Where-Object Resource -eq 'Entra').Status | Should -Be 'BlockedDependency'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly
    }

    It 'executes all three phases after accepted Autopilot deletion without read-back' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Scrapped -Records @(New-ScrappedBatchRecord)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        ($results | Where-Object Resource -eq 'Intune').Status | Should -Be 'Removed'
        ($results | Where-Object Resource -eq 'Autopilot').Status | Should -Be 'RemovalSubmitted'
        ($results | Where-Object Resource -eq 'Entra').Status | Should -Be 'Removed'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter { $Method -eq 'GET' }
        $script:invoke.JournalPath = Join-Path $TestDrive 'simulation.jsonl'
        @(Invoke-DeviceDeletionPlan @script:invoke -WhatIf | Where-Object Status -eq 'WhatIf').Count | Should -Be 3
    }

    It 'does not let optional Autopilot read-back block Entra deletion' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Scrapped -Records @(New-ScrappedBatchRecord)
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
        }

        $results = @(Invoke-DeviceDeletionPlan @script:invoke -VerifyDeletion)

        ($results | Where-Object Resource -eq 'Autopilot').Status | Should -Be 'RemovalSubmitted'
        ($results | Where-Object Resource -eq 'Autopilot').VerificationStatus | Should -Be 'OutcomeUnknown'
        ($results | Where-Object Resource -eq 'Entra').Status | Should -Be 'Removed'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -Exactly -ParameterFilter { $Method -eq 'GET' }
    }

    It 'isolates a failed Intune prerequisite from an unrelated successful device' {
        $records = @(
            (New-ScrappedBatchRecord),
            (New-ScrappedBatchRecord -Serial 'SERIAL2' -IntuneId 'intune2' -AutopilotId 'ap2')
        )
        $records[1].EntraObjectId = 'entra2'
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Scrapped -Records $records
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @((ConvertFrom-Json $Body).requests | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; status = $(if ($_.id -eq 'intune-intune1') { 400 } else { 204 }) }
            }) }
        }
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        ($results | Where-Object Id -eq 'autopilot-ap1').Status | Should -Be 'BlockedDependency'
        ($results | Where-Object Id -eq 'autopilot-ap2').Status | Should -Be 'RemovalSubmitted'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter {
            $Body -match 'autopilot-ap1'
        }
    }

    It 'does not treat an Autopilot 404 as accepted deletion' {
        $script:invoke.Plan = New-DeviceDeletionPlan -TenantId tenant1 -RunId run1 -Workflow Scrapped `
            -Records @(New-ScrappedBatchRecord -IntuneId '')
        $script:invoke.ApprovalHash = $script:invoke.Plan.Hash
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup {
            [PSCustomObject]@{ responses = @([PSCustomObject]@{ id = 'autopilot-ap1'; status = 404 }) }
        }
        $results = @(Invoke-DeviceDeletionPlan @script:invoke)
        ($results | Where-Object Resource -eq 'Autopilot').Status | Should -Be 'RemovalFailed'
        ($results | Where-Object Resource -eq 'Entra').Status | Should -Be 'BlockedDependency'
    }

    It 'only verifies observed absence on an authoritative read-back 404' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        }
        $result = Invoke-DeviceDeletionPlan @script:invoke -VerifyDeletion
        $result.Status | Should -Be 'Removed'
        $result.VerificationStatus | Should -Be 'VerifiedAbsent'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -ceq '/v1.0/devices/obj0'
        }
    }

    It 'does not convert denied read-back into absence' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
        }
        $result = Invoke-DeviceDeletionPlan @script:invoke -VerifyDeletion
        $result.VerificationStatus | Should -Be 'OutcomeUnknown'
        $result.ErrorMessage | Should -Match '403'
    }

    It 'bounds verification polling when the object remains visible' {
        Mock Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -ParameterFilter { $Method -eq 'GET' } {
            [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
        }
        (Invoke-DeviceDeletionPlan @script:invoke -VerifyDeletion).VerificationStatus | Should -Be 'VerificationPending'
        Should -Invoke Invoke-MgGraphRequest -ModuleName StaleDeviceCleanup -Times 3 -Exactly -ParameterFilter { $Method -eq 'GET' }
    }
}
