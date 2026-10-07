#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Administrator protection report routing' {
    BeforeAll {
        $cutoff = [datetime]::UtcNow.AddDays(-180)
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @(
            [PSCustomObject]@{ Id = 'ap-both'; AzureActiveDirectoryDeviceId = 'dev-both'; ManagedDeviceId = $null; SerialNumber = 'serial-both'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null }
            [PSCustomObject]@{ Id = 'ap-explicit'; AzureActiveDirectoryDeviceId = 'dev-explicit'; ManagedDeviceId = $null; SerialNumber = 'serial-explicit'; EnrollmentState = 'enrolled'; LastContactedDateTime = $null }
        )
        $devices = @(
            New-TestEntraDevice -Id 'sync' -DeviceId 'dev-sync' -OnPremisesSyncEnabled $true -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-300))
            New-TestEntraDevice -Id 'both' -DeviceId 'dev-both' -OnPremisesSyncEnabled $true -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-300))
            New-TestEntraDevice -Id 'explicit' -DeviceId 'dev-explicit' -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-300))
            New-TestEntraDevice -Id 'recent' -DeviceId 'dev-recent' -OnPremisesSyncEnabled $true -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-1))
            New-TestEntraDevice -Id 'missing' -DeviceId 'dev-missing' -OnPremisesSyncEnabled $true
            New-TestEntraDevice -Id 'candidate' -DeviceId 'dev-candidate' -ApproximateLastSignInDateTime ([datetime]::UtcNow.AddDays(-300))
        )
    }

    It 'partitions exclusions by existing primary reason without changing eligibility or overlapping rows' {
        $evaluated = Get-StaleDeviceCandidates -EntraDevices $devices -Indexes $indexes -CutoffDateUtc $cutoff `
            -RunId report-run -ProtectedEntraObjectIds explicit
        $before = $evaluated | ConvertTo-Json -Depth 5
        $planBefore = New-DeviceDeletionPlan -TenantId synthetic-tenant -RunId report-run -Workflow Stale -Records $evaluated
        Export-CleanupReports -AllEvaluatedDevices $evaluated -OutputPath $TestDrive
        Export-CleanupReports -AllEvaluatedDevices $evaluated -OutputPath $TestDrive
        $ad = @(Import-Csv (Join-Path $TestDrive 'ADSyncedDevices.csv'))
        $ap = @(Import-Csv (Join-Path $TestDrive 'AutopilotProtectedDevices.csv'))
        $other = @(Import-Csv (Join-Path $TestDrive 'ExcludedDevices.csv'))
        $ad.Count | Should -Be 1
        $ad[0].EntraObjectId | Should -Be 'sync'
        $ad[0].SourceADDeletionSafety | Should -Be 'NotAssessed'
        $ap.Count | Should -Be 1
        $ap[0].EntraObjectId | Should -Be 'both'
        $ap[0].OnPremisesSyncEnabled | Should -Be 'True'
        $ap[0].AutopilotIdentityId | Should -Be 'ap-both'
        $other.Count | Should -Be 2
        $other.EntraObjectId | Should -Contain explicit
        $other.EntraObjectId | Should -Contain recent
        @(Import-Csv (Join-Path $TestDrive 'UnknownDevices.csv')).EntraObjectId | Should -Contain missing
        (Get-Content (Join-Path $TestDrive 'ADSyncedDevices.csv') -Raw) |
            Should -BeExactly (Get-Content (Join-Path $TestDrive 'OnPremisesSyncedReview.csv') -Raw)
        ($evaluated | ConvertTo-Json -Depth 5) | Should -BeExactly $before
        $planAfter = New-DeviceDeletionPlan -TenantId synthetic-tenant -RunId report-run -Workflow Stale -Records $evaluated
        ($planAfter.Operations | ConvertTo-Json -Depth 5) | Should -BeExactly ($planBefore.Operations | ConvertTo-Json -Depth 5)
        $planAfter.Operations.ObjectId | Should -Be candidate
        $summary = New-RunSummary -RunId report-run -Mode Audit -StartTimeUtc $cutoff -CutoffDateUtc $cutoff `
            -DaysInactive 180 -AllEvaluatedDevices $evaluated
        $summary.TotalExcluded | Should -Be ($ad.Count + $ap.Count + $other.Count)
        $summary.TotalADSyncedDevices | Should -Be $ad.Count
        $summary.TotalAutopilotProtectedDevices | Should -Be $ap.Count
        $summary.TotalOtherExcludedDevices | Should -Be $other.Count
        $summary.ExclusionsByReason.ProtectedDevice | Should -Be 1
        $summary.ManualReviewByReason.MissingAllActivity | Should -Be 1
    }

    It 'writes stable protection headers even when empty' {
        Export-CleanupReports -AllEvaluatedDevices @() -OutputPath $TestDrive
        foreach ($file in 'ADSyncedDevices.csv', 'AutopilotProtectedDevices.csv') {
            @(Get-Content (Join-Path $TestDrive $file)).Count | Should -Be 1
            (Get-Content (Join-Path $TestDrive $file)) | Should -Match 'RunId.*EvaluationTimestampUtc'
            @(Import-Csv (Join-Path $TestDrive $file)).Count | Should -Be 0
        }
    }

    It 'does not report AD-sync protection when the explicit override permits deletion' {
        $evaluated = Get-StaleDeviceCandidates -EntraDevices $devices -Indexes $indexes -CutoffDateUtc $cutoff `
            -RunId override-run -AllowOnPremisesSyncedDeletion
        Export-CleanupReports -AllEvaluatedDevices $evaluated -OutputPath $TestDrive
        @(Import-Csv (Join-Path $TestDrive 'ADSyncedDevices.csv')).Count | Should -Be 0
        ($evaluated | Where-Object EntraObjectId -eq sync).Decision | Should -Be Candidate
        ($evaluated | Where-Object EntraObjectId -eq both).ReasonCode | Should -Be AutopilotProtected
    }

    It 'retains excluded rows without reason evidence under terminating error preferences' {
        $ErrorActionPreference = 'Stop'
        $records = @(
            foreach ($id in 'missing', 'null', 'empty') {
                $record = [PSCustomObject]@{
                    EntraObjectId = $id; Decision = 'Excluded'; MatchStatus = 'Unmatched'
                    EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'
                    ErrorMessage = $null
                }
                if ($id -ne 'missing') {
                    $record | Add-Member -NotePropertyName ReasonCode -NotePropertyValue $(if ($id -eq 'null') { $null } else { '' })
                }
                $record
            }
        )
        $before = $records | ConvertTo-Json
        Export-CleanupReports -AllEvaluatedDevices $records -OutputPath $TestDrive
        $other = @(Import-Csv (Join-Path $TestDrive 'ExcludedDevices.csv'))
        $other.Count | Should -Be 3
        foreach ($id in 'missing', 'null', 'empty') { $other.EntraObjectId | Should -Contain $id }
        foreach ($file in 'ADSyncedDevices.csv', 'AutopilotProtectedDevices.csv', 'DeletionCandidates.csv') {
            @(Import-Csv (Join-Path $TestDrive $file)).Count | Should -Be 0
        }
        ($records | ConvertTo-Json) | Should -BeExactly $before
    }

    It 'reconciles missing exclusion and review reasons without claiming protection or deletion' {
        $ErrorActionPreference = 'Stop'
        $records = @(
            foreach ($decision in 'Excluded', 'ManualReview') {
                foreach ($kind in 'missing', 'null', 'empty') {
                    $record = [PSCustomObject]@{
                        Decision = $decision; EntraRemovalStatus = 'NotAttempted'
                        AutopilotRemovalStatus = 'NotAttempted'; ErrorMessage = $null
                    }
                    if ($kind -ne 'missing') {
                        $record | Add-Member -NotePropertyName ReasonCode -NotePropertyValue $(if ($kind -eq 'null') { $null } else { '' })
                    }
                    $record
                }
            }
        )
        $before = $records | ConvertTo-Json
        $summary = New-RunSummary -RunId missing-reasons -Mode Audit -StartTimeUtc $cutoff `
            -CutoffDateUtc $cutoff -DaysInactive 180 -AllEvaluatedDevices $records
        $summary.TotalEvaluated | Should -Be 6
        $summary.TotalExcluded | Should -Be 3
        $summary.TotalManualReview | Should -Be 3
        $summary.TotalOtherExcludedDevices | Should -Be 3
        $summary.TotalADSyncedDevices | Should -Be 0
        $summary.TotalAutopilotProtectedDevices | Should -Be 0
        $summary.ExclusionsByReason.MissingReasonCode | Should -Be 3
        $summary.ManualReviewByReason.MissingReasonCode | Should -Be 3
        $summary.TotalCandidates | Should -Be 0
        $summary.TotalEntraDevicesToRemove | Should -Be 0
        $summary.TotalEntraDevicesRemoved | Should -Be 0
        ($records | ConvertTo-Json) | Should -BeExactly $before
    }
}

Describe 'Action results and reconciled completion summaries' {
    BeforeEach {
        $records = @(
            foreach ($i in 1..10) {
                [PSCustomObject]@{ Decision = 'Candidate'; EntraAction = 'Remove'; AutopilotPresent = $false;
                    EntraObjectId = "obj$i"; DeviceName = "SYNTHETIC-$i"; ReasonCode = 'Stale'; ErrorMessage = $null;
                    EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted' }
            }
        )
        $plan = New-DeviceDeletionPlan -TenantId synthetic-tenant -RunId synthetic-run -Workflow Stale -Records $records
        $statuses = @('Removed', 'AlreadyAbsent', 'RemovalFailed', 'OutcomeUnknown', 'BlockedDependency',
            'WhatIf', 'Declined', 'NotAttempted', 'RemovalSubmitted', 'AlreadyRemoved')
        $results = @(
            for ($i = 0; $i -lt $plan.Operations.Count; $i++) {
                [PSCustomObject]@{ Id = $plan.Operations[$i].Id; Status = $statuses[$i];
                    Attempts = $(if ($i -lt 4) { 2 } else { 0 }); HttpStatus = $(if ($i -eq 2) { 403 } else { 0 });
                    VerificationStatus = $(if ($i -eq 0) { 'VerificationPending' } else { 'NotRequested' });
                    ErrorMessage = $(if ($i -eq 2) { 'Permission denied' } else { '' }) }
            }
        )
    }

    It 'counts every final status once, separates retries, and keeps failed and unknown operations visible' {
        $actions = @(Get-CleanupActionRecords -Plan $plan -Results $results -Records @($records + $records))
        $actions.Count | Should -Be 10
        $summary = New-RunSummary -RunId synthetic-run -Mode Automatic -StartTimeUtc ([datetime]::UtcNow) `
            -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -DaysInactive 180 -AllEvaluatedDevices $records `
            -ActionRecords $actions -ExitCode 6
        $summary.TotalPlannedActions | Should -Be 10
        $summary.TotalAttemptedActions | Should -Be 4
        $summary.TotalRetryAttempts | Should -Be 4
        foreach ($status in $statuses) { $summary.ActionOutcomes[$status] | Should -Be 1 }
        ($summary.ActionOutcomes.Values | Measure-Object -Sum).Sum | Should -Be $actions.Count
        $summary.ActionsByResource.Entra.Attempted | Should -Be 4
        $summary.TotalVerificationPending | Should -Be 1
        $logPath = Join-Path $TestDrive 'ExecutionLog.txt'
        Complete-ProjectExecution -RunSummary $summary -OutputPath $TestDrive -LogPath $logPath -ActionRecords $actions
        $log = Get-Content $logPath -Raw
        $log | Should -Match 'RemovalFailed=1; OutcomeUnknown=1; BlockedDependency=1'
        $log | Should -Match 'Planned=10 Attempted=4 RetryAttempts=4'
        $csv = @(Import-Csv (Join-Path $TestDrive 'ActionResults.csv'))
        $csv.Count | Should -Be 10
        ($csv | Where-Object Outcome -eq RemovalFailed).ErrorMessage | Should -Be 'Permission denied'
        ($csv | Where-Object Outcome -eq RemovalFailed).HttpStatus | Should -Be 403
        @($csv | Where-Object Outcome -eq OutcomeUnknown).Count | Should -Be 1
        $json = Get-Content (Join-Path $TestDrive 'RunSummary.json') -Raw | ConvertFrom-Json
        $json.ActionOutcomes.RemovalFailed | Should -Be 1
    }

    It 'represents an unexecuted plan without claiming attempts or successful deletion' {
        $actions = @(Get-CleanupActionRecords -Plan $plan -Records $records)
        @($actions | Where-Object Outcome -eq NotAttempted).Count | Should -Be 10
        @($actions | Where-Object Attempts -gt 0).Count | Should -Be 0
        @(Get-CleanupActionRecords -Plan $null).Count | Should -Be 0
    }

    It 'keeps run-level discovery errors visible even without evaluated device rows' {
        $summary = New-RunSummary -RunId failed-run -Mode Audit -StartTimeUtc ([datetime]::UtcNow) `
            -CutoffDateUtc ([datetime]::UtcNow.AddDays(-180)) -DaysInactive 180 -AllEvaluatedDevices @() `
            -DiscoveryComplete $false -RunErrorCount 1 -ExitCode 4
        Complete-ProjectExecution -RunSummary $summary -OutputPath $TestDrive -LogPath (Join-Path $TestDrive 'failed.txt')
        $summary.TotalEvaluated | Should -Be 0
        $summary.TotalErrors | Should -Be 0
        $summary.TotalRunErrors | Should -Be 1
        $summary.TotalAttemptedActions | Should -Be 0
        (Get-Content (Join-Path $TestDrive 'failed.txt') -Raw) | Should -Match 'DiscoveryComplete=False ExitCode=4'
        (Get-Content (Join-Path $TestDrive 'failed.txt') -Raw) | Should -Match 'RunErrors=1'
        (Get-Content (Join-Path $TestDrive 'ActionResults.csv') -TotalCount 1) | Should -Match 'RunId.*Outcome.*Attempts'
    }

    It 'keeps scrapped action counts separate from expanded rows and primary exclusion reasons' {
        $rows = @(
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; IntuneManagedDeviceId = 'intune1';
                AutopilotIdentityId = 'ap1'; EntraObjectId = 'obj1'; IntuneDeviceName = 'SYNTHETIC' }
        )
        $scrappedPlan = New-DeviceDeletionPlan -TenantId synthetic-tenant -RunId synthetic-run -Workflow Scrapped -Records @($rows + $rows)
        $actions = @(Get-CleanupActionRecords -Plan $scrappedPlan -Records @($rows + $rows))
        $actions.Count | Should -Be 3
        @($actions | Where-Object Resource -eq Autopilot).Count | Should -Be 1
        $actions.ReasonCode | Select-Object -Unique | Should -Be ExplicitScrappedCleanup
    }
}

Describe 'Normal and diagnostic log streams' {
    It 'appends normal messages, excludes diagnostic detail, escapes lines, and redacts secret fields' {
        $path = Join-Path $TestDrive 'streams.txt'
        Write-CleanupLog -Message 'first' -Level INFO -LogPath $path
        Write-CleanupLog -Message 'verbose detail' -Level VERBOSE -LogPath $path -Verbose 4>&1 | Out-Null
        Write-CleanupLog -Message 'debug detail' -Level DEBUG -LogPath $path -Debug 5>&1 | Out-Null
        Write-CleanupLog -Message "Failure`nsecond line access_token=synthetic-secret" -Level ERROR -LogPath $path -WarningVariable warnings
        @(Get-Content $path).Count | Should -Be 2
        $text = Get-Content $path -Raw
        $text | Should -Not -Match 'verbose detail|debug detail|synthetic-secret'
        $text | Should -Match '\[ERROR\].*Failure\\nsecond line'
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Not -Match synthetic-secret
    }

    It 'surfaces file write errors instead of hiding them' {
        Write-CleanupLog -Message 'important failure' -Level ERROR -LogPath (Join-Path $TestDrive 'missing\log.txt') -WarningVariable warnings
        $warnings.Count | Should -Be 2
        $warnings[0].Message | Should -Match 'Failed to write to log file'
        $warnings[1].Message | Should -Be 'important failure'
    }

    It 'redacts complete quoted values and omits unrelated Graph response properties' {
        $path = Join-Path $TestDrive 'redacted.txt'
        Write-CleanupLog -Message 'password="synthetic multi word value" client_secret=''synthetic second value''' `
            -Level WARNING -LogPath $path -WarningVariable warnings
        (Get-Content $path -Raw) | Should -Not -Match 'synthetic|multi word|second value'
        $warnings[0].Message | Should -Not -Match synthetic
        InModuleScope StaleDeviceCleanup {
            $body = @{ error = @{ code = 'Denied'; message = 'Permission denied'; innerError = @{ diagnostic = 'synthetic-private-detail' } };
                unnecessaryPersonalData = 'synthetic-user' }
            $text = Get-GraphResponseErrorText -Body $body
            $text | Should -BeExactly 'Denied: Permission denied'
            $text | Should -Not -Match 'synthetic'
        }
    }

    It 'redacts complete credential values containing escaped quotes' {
        InModuleScope StaleDeviceCleanup {
            $jsonMessage = '{"client_secret":"synthetic\"private-tail","code":"Denied"}'
            $text = ConvertTo-CleanupLogText -Text $jsonMessage
            $text | Should -Not -Match 'synthetic|private-tail'
            $text | Should -Match 'Denied'
            $text = ConvertTo-CleanupLogText -Text "password='synthetic''private-tail' code=Denied"
            $text | Should -Not -Match 'synthetic|private-tail'
            $text | Should -Match 'Denied'
        }
    }
}
