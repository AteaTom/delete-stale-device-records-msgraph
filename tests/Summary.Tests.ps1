#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    function global:Get-MgDevice { param([switch]$All, [string[]]$Property) }
    function global:Get-MgDeviceManagementManagedDevice { param([switch]$All) }
    function global:Get-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([switch]$All, [string]$WindowsAutopilotDeviceIdentityId) }
    function global:Connect-MgGraph { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) }
    function global:Get-MgContext { }
    function global:Remove-MgDevice { param([string]$DeviceId) }
    function global:Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity { param([string]$WindowsAutopilotDeviceIdentityId) }

    $modulePath = Join-Path $PSScriptRoot '..\src\StaleDeviceCleanup.psd1'
    Import-Module $modulePath -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Show-CleanupSummary workflow semantics' {
    BeforeEach {
        Mock Write-Host -ModuleName StaleDeviceCleanup { }
    }

    It 'counts only unique actionable standalone Entra targets' {
        $record = [PSCustomObject]@{
            Decision = 'Candidate'; EntraAction = 'Remove'; EntraObjectId = 'obj1'
            Platform = 'iOS'; AutopilotPresent = $false; ReasonCode = 'Stale'
        }
        $blocked = [PSCustomObject]@{
            Decision = 'Candidate'; EntraAction = 'Remove'; EntraObjectId = 'obj2'
            Platform = 'Windows'; AutopilotPresent = $true; ReasonCode = 'Stale'
        }
        $review = [PSCustomObject]@{
            Decision = 'ManualReview'; EntraAction = 'None'; EntraObjectId = 'obj3'
            Platform = 'Windows'; AutopilotPresent = $false; ReasonCode = 'LowConfidenceMatch'
        }
        Show-CleanupSummary -EvaluatedDevices @($record, $record, $blocked, $review) `
            -CutoffDateUtc ([datetime]::UtcNow) -DaysInactive 180 -OutputPath $TestDrive `
            -TenantId tenant1 -Mode Automatic -Simulation $true
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -Exactly -ParameterFilter {
            $Object -eq '  Entra objects to remove:      1'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 0 -ParameterFilter {
            $Object -like '*Windows with Autopilot*' -or $Object -like '*Autopilot records to remove*'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq 'Mode: Automatic; WhatIf: True'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq 'No tenant DELETE requests will be sent.'
        }
    }

    It 'shows zero targets for empty input and an explicit Audit warning' {
        Show-CleanupSummary -EvaluatedDevices @() -CutoffDateUtc ([datetime]::UtcNow) `
            -DaysInactive 180 -OutputPath $TestDrive
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq '  Entra objects to remove:      0'
        }
        Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
            $Object -eq 'No tenant DELETE requests will be sent.'
        }
    }

    It 'separates protection and review categories' {
        $records = @(
            foreach ($reason in 'AutopilotProtected','ProtectedDevice','OnPremisesSyncProtected','UnsupportedPlatform','RecentActivityDetected') {
                [PSCustomObject]@{ Decision = 'Excluded'; ReasonCode = $reason }
            }
            foreach ($reason in 'MissingAllActivity','MissingOperatingSystem','LowConfidenceMatch','AmbiguousAutopilotMatch') {
                [PSCustomObject]@{ Decision = 'ManualReview'; ReasonCode = $reason }
            }
        )
        Show-CleanupSummary -EvaluatedDevices $records -CutoffDateUtc ([datetime]::UtcNow) `
            -DaysInactive 180 -OutputPath $TestDrive
        foreach ($line in @(
            '  Autopilot-backed (retained):   1', '  Explicitly protected:         1',
            '  On-premises sync protected:   1', '  Low-confidence AP matches:    1',
            '  Total excluded:               5', '  Total manual review:          4'
        )) {
            Should -Invoke Write-Host -ModuleName StaleDeviceCleanup -Times 1 -ParameterFilter {
                $Object -eq $line
            }
        }
    }
}

Describe 'Export-ReportCsv UTC serialization' {
    It 'preserves full precision and original values for <Kind>' -TestCases @(
        @{ Kind = 'Utc' }, @{ Kind = 'Local' }, @{ Kind = 'Unspecified' }, @{ Kind = 'Offset' }
    ) {
        param($Kind)
        $utc = [datetime]::new(2026, 4, 9, 18, 51, 36, [DateTimeKind]::Utc).AddTicks(5885471)
        $timestamp = switch ($Kind) {
            Utc { $utc }
            Local { $utc.ToLocalTime() }
            Unspecified { [datetime]::SpecifyKind($utc, [DateTimeKind]::Unspecified) }
            Offset { [datetimeoffset]::new($utc).ToOffset([timespan]::FromHours(2)) }
        }
        $record = [PSCustomObject][ordered]@{
            TimestampUtc = $timestamp; Text = '2026-04-09 18:51:36'
            MissingUtc = $null; Count = 7
        }
        $path = Join-Path $TestDrive 'timestamps.csv'
        Export-ReportCsv -InputObject @($record) -Path $path
        $csv = Import-Csv $path
        $csv.TimestampUtc | Should -BeExactly '2026-04-09T18:51:36.5885471Z'
        $csv.Text | Should -BeExactly $record.Text
        $csv.MissingUtc | Should -BeNullOrEmpty
        $csv.Count | Should -Be '7'
        ($csv.PSObject.Properties.Name -join ',') | Should -Be 'TimestampUtc,Text,MissingUtc,Count'
        $record.TimestampUtc | Should -Be $timestamp
        $record.TimestampUtc.GetType() | Should -Be $timestamp.GetType()
        if ($timestamp -is [datetime]) { $record.TimestampUtc.Kind | Should -Be $timestamp.Kind }
    }

    It 'rejects an unspecified date without an explicit UTC field contract' {
        $record = [PSCustomObject]@{ Timestamp = [datetime]::new(2026, 4, 9) }
        { Export-ReportCsv -InputObject @($record) -Path (Join-Path $TestDrive 'ambiguous.csv') } |
            Should -Throw '*no timezone*'
        Test-Path (Join-Path $TestDrive 'ambiguous.csv') | Should -BeFalse
    }
}

Describe 'Export-CleanupReports' {
    BeforeEach {
        $script:testOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "sdc-test-$(New-Guid)"
        New-Item -Path $script:testOutputPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Path $script:testOutputPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes all required report files even when there are no candidates' {
        Export-CleanupReports -AllEvaluatedDevices @() -OutputPath $script:testOutputPath

        $expectedFiles = @(
            'AllEvaluatedDevices.csv', 'DeletionCandidates.csv', 'DeletedDevices.csv',
            'UnknownDevices.csv', 'AmbiguousMatches.csv', 'ExcludedDevices.csv', 'ErrorDevices.csv',
            'OnPremisesSyncedReview.csv', 'ADSyncedDevices.csv', 'AutopilotProtectedDevices.csv'
        )
        foreach ($file in $expectedFiles) {
            Test-Path (Join-Path $script:testOutputPath $file) | Should -Be $true
        }
        (Get-Content (Join-Path $script:testOutputPath 'OnPremisesSyncedReview.csv') -TotalCount 1) | Should -Match 'EntraObjectId.*ReasonDescription.*SourceADDeletionSafety'
    }

    It 'writes DeletionCandidates.csv containing only Candidate-decision rows' {
        $devices = @(
            [PSCustomObject]@{ RunId = 'r1'; Decision = 'Candidate'; MatchStatus = 'Unmatched'; ErrorMessage = $null; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; DeviceName = 'A' }
            [PSCustomObject]@{ RunId = 'r1'; Decision = 'Excluded'; MatchStatus = 'Unmatched'; ErrorMessage = $null; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; DeviceName = 'B' }
        )
        Export-CleanupReports -AllEvaluatedDevices $devices -OutputPath $script:testOutputPath
        $candidates = Import-Csv (Join-Path $script:testOutputPath 'DeletionCandidates.csv')
        $candidates.Count | Should -Be 1
        $candidates[0].DeviceName | Should -Be 'A'
    }

    It 'writes only stale devices blocked by on-premises sync protection to the review CSV' {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
        $devices = @(
            (New-TestEntraDevice -Id 'stale-sync' -DeviceId 'device-stale' -DisplayName 'STALE-SYNC' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-300) -OnPremisesSyncEnabled $true),
            (New-TestEntraDevice -Id 'recent-sync' -DeviceId 'device-recent' -DisplayName 'RECENT-SYNC' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-30) -OnPremisesSyncEnabled $true),
            (New-TestEntraDevice -Id 'missing-sync' -DeviceId 'device-missing' -DisplayName 'MISSING-SYNC' -OnPremisesSyncEnabled $true)
        )
        $evaluated = Get-StaleDeviceCandidates -EntraDevices $devices -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'

        Export-CleanupReports -AllEvaluatedDevices $evaluated -OutputPath $script:testOutputPath

        $review = @(Import-Csv (Join-Path $script:testOutputPath 'OnPremisesSyncedReview.csv'))
        $review.Count | Should -Be 1
        $review[0].EntraObjectId | Should -Be 'stale-sync'
        $review[0].ReasonCode | Should -Be 'OnPremisesSyncProtected'
        $review[0].SourceADDeletionSafety | Should -Be 'NotAssessed'
        $summary = New-RunSummary -RunId r1 -Mode Audit -StartTimeUtc $cutoff -CutoffDateUtc $cutoff `
            -DaysInactive 180 -AllEvaluatedDevices $evaluated
        $json = $summary | ConvertTo-Json
        $jsonCutoff = [regex]::Match($json, '"CutoffDateUtc"\s*:\s*"([^"]+)"').Groups[1].Value
        @(Import-Csv (Join-Path $script:testOutputPath 'ExcludedDevices.csv')).Count | Should -Be 1
        foreach ($name in 'AllEvaluatedDevices', 'ADSyncedDevices', 'OnPremisesSyncedReview') {
            $row = @(Import-Csv (Join-Path $script:testOutputPath "$name.csv") |
                Where-Object EntraObjectId -eq 'stale-sync')[0]
            $row.CutoffDateUtc | Should -BeExactly $jsonCutoff
            $row.EffectiveLastActivityUtc | Should -BeExactly $evaluated[0].EffectiveLastActivityUtc.ToString('o')
        }
        $evaluated[0].CutoffDateUtc | Should -BeOfType ([datetime])
    }
}

Describe 'New-RunSummary' {
    It 'produces the expected count fields' {
        $devices = @(
            [PSCustomObject]@{ Decision = 'Candidate'; EntraRemovalStatus = 'Removed'; AutopilotRemovalStatus = 'Removed'; ErrorMessage = $null }
            [PSCustomObject]@{ Decision = 'Excluded'; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; ErrorMessage = $null }
            [PSCustomObject]@{ Decision = 'ManualReview'; EntraRemovalStatus = 'NotAttempted'; AutopilotRemovalStatus = 'NotAttempted'; ErrorMessage = 'oops' }
        )
        $summary = New-RunSummary -RunId 'r1' -Mode 'Audit' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices $devices

        $summary.TotalEvaluated | Should -Be 3
        $summary.TotalCandidates | Should -Be 1
        $summary.TotalExcluded | Should -Be 1
        $summary.TotalManualReview | Should -Be 1
        $summary.TotalEntraDevicesRemoved | Should -Be 1
        $summary.TotalErrors | Should -Be 1
        $summary.TotalAutopilotRemovalSubmitted | Should -Be 0
    }

    It 'counts an AlreadyRemoved Autopilot identity as removed' {
        $device = [PSCustomObject]@{
            Decision = 'Candidate'
            EntraRemovalStatus = 'Removed'
            AutopilotRemovalStatus = 'AlreadyRemoved'
            ErrorMessage = $null
        }
        $summary = New-RunSummary -RunId 'r2' -Mode 'Interactive' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @($device)

        $summary.TotalEntraDevicesRemoved | Should -Be 1
        $summary.TotalAutopilotRemoved | Should -Be 1
    }

    It 'counts an accepted Autopilot submission separately from completed removal' {
        $device = [PSCustomObject]@{
            Decision = 'Candidate'
            EntraRemovalStatus = 'NotAttempted'
            AutopilotRemovalStatus = 'RemovalSubmitted'
            ErrorMessage = $null
        }
        $summary = New-RunSummary -RunId 'r3' -Mode 'Automatic' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @($device)

        $summary.TotalAutopilotRemovalSubmitted | Should -Be 1
        $summary.TotalAutopilotRemoved | Should -Be 0
        $summary.TotalEntraDevicesRemoved | Should -Be 0
    }

    It 'reports stale on-premises review count and explicit override usage' {
        $reviewDevice = [PSCustomObject]@{
            Decision = 'Excluded'
            ReasonCode = 'OnPremisesSyncProtected'
            EntraRemovalStatus = 'NotAttempted'
            AutopilotRemovalStatus = 'NotAttempted'
            ErrorMessage = $null
        }
        $summary = New-RunSummary -RunId 'r5' -Mode 'Audit' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @($reviewDevice) -AllowOnPremisesSyncedDeletion $true

        $summary.TotalOnPremisesSyncedReview | Should -Be 1
        $summary.AllowOnPremisesSyncedDeletion | Should -BeTrue
    }

    It 'counts scrapped-device outcomes by unique serial and object ids' {
        $scrappedRecords = @(
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = $null; EntraObjectId = $null; AutopilotRemovalStatus = 'RemovalSubmitted'; IntuneRemovalStatus = 'NotApplicable'; EntraRemovalStatus = 'NotApplicable'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = 'intune1'; EntraObjectId = $null; AutopilotRemovalStatus = 'RemovalSubmitted'; IntuneRemovalStatus = 'Removed'; EntraRemovalStatus = 'NotApplicable'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = $null; EntraObjectId = 'entra1'; AutopilotRemovalStatus = 'RemovalSubmitted'; IntuneRemovalStatus = 'NotApplicable'; EntraRemovalStatus = 'Removed'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial2'; MatchStatus = 'NotFound'; AutopilotIdentityId = $null; IntuneManagedDeviceId = $null; EntraObjectId = $null; AutopilotRemovalStatus = 'NotAttempted'; IntuneRemovalStatus = 'NotAttempted'; EntraRemovalStatus = 'NotAttempted'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial3'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap3'; IntuneManagedDeviceId = $null; EntraObjectId = 'entra3'; AutopilotRemovalStatus = 'RemovalFailed'; IntuneRemovalStatus = 'NotApplicable'; EntraRemovalStatus = 'SkippedAutopilotSubmissionFailed'; ErrorMessage = 'rejected' },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial3'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap3'; IntuneManagedDeviceId = $null; EntraObjectId = $null; AutopilotRemovalStatus = 'RemovalFailed'; IntuneRemovalStatus = 'NotApplicable'; EntraRemovalStatus = 'NotApplicable'; ErrorMessage = 'rejected' }
        )

        $summary = New-RunSummary -RunId 'r4' -Mode 'Interactive' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @() -ScrappedDeviceRecords $scrappedRecords

        $summary.ScrappedWorkflow | Should -BeTrue
        $summary.TotalScrappedSerials | Should -Be 3
        $summary.TotalScrappedMatchedSerials | Should -Be 2
        $summary.TotalScrappedNotFoundSerials | Should -Be 1
        $summary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 1
        $summary.TotalScrappedAutopilotRemovalFailed | Should -Be 1
        $summary.TotalScrappedIntuneDevicesRemoved | Should -Be 1
        $summary.TotalScrappedEntraDevicesRemoved | Should -Be 1
        $summary.TotalScrappedEntraDevicesBlockedByAutopilot | Should -Be 1
        $summary.TotalScrappedErrors | Should -Be 1
        $summary.TotalErrors | Should -Be 1
    }

    It 'counts accepted and already-absent scrapped targets once by object ID' {
        $records = @(
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = 'intune1'; EntraObjectId = 'entra1'; AutopilotRemovalStatus = 'RemovalSubmitted'; IntuneRemovalStatus = 'AlreadyRemoved'; EntraRemovalStatus = 'AlreadyRemoved'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial1'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap1'; IntuneManagedDeviceId = 'intune1'; EntraObjectId = 'entra1'; AutopilotRemovalStatus = 'RemovalSubmitted'; IntuneRemovalStatus = 'AlreadyRemoved'; EntraRemovalStatus = 'AlreadyRemoved'; ErrorMessage = $null },
            [PSCustomObject]@{ NormalizedSerialNumber = 'serial2'; MatchStatus = 'Matched'; AutopilotIdentityId = 'ap2'; IntuneManagedDeviceId = 'intune2'; EntraObjectId = 'entra2'; AutopilotRemovalStatus = 'AlreadyRemoved'; IntuneRemovalStatus = 'Removed'; EntraRemovalStatus = 'Removed'; ErrorMessage = $null }
        )

        $summary = New-RunSummary -RunId 'r6' -Mode 'Automatic' -StartTimeUtc (Get-Date).ToUniversalTime() -CutoffDateUtc (Get-Date).ToUniversalTime() -DaysInactive 180 -AllEvaluatedDevices @() -ScrappedDeviceRecords $records

        $summary.TotalScrappedAutopilotRemovalSubmitted | Should -Be 1
        $summary.TotalScrappedAutopilotAlreadyRemoved | Should -Be 1
        $summary.TotalScrappedAutopilotRemovalFailed | Should -Be 0
        $summary.TotalScrappedIntuneDevicesRemoved | Should -Be 1
        $summary.TotalScrappedIntuneDevicesAlreadyRemoved | Should -Be 1
        $summary.TotalScrappedIntuneDevicesFailed | Should -Be 0
        $summary.TotalScrappedEntraDevicesRemoved | Should -Be 1
        $summary.TotalScrappedEntraDevicesAlreadyRemoved | Should -Be 1
        $summary.TotalScrappedEntraDevicesFailed | Should -Be 0
        $summary.TotalScrappedEntraDevicesBlockedByAutopilot | Should -Be 0
    }
}

Describe 'AllEvaluatedDevices.csv required fields' {
    It 'includes the required evaluated-device columns' {
        $indexes = New-DeviceIndexes -IntuneDevices @() -AutopilotDevices @()
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-180)
        $device = New-TestEntraDevice -Id '1' -DeviceId 'd1' -DisplayName 'W1' -ApproximateLastSignInDateTime (Get-Date).ToUniversalTime().AddDays(-250)
        $eval = Get-StaleDeviceCandidates -EntraDevices @($device) -Indexes $indexes -CutoffDateUtc $cutoff -RunId 'r1'

        $requiredFields = @(
            'RunId', 'EvaluationTimestampUtc', 'DeviceName', 'Platform', 'EntraObjectId', 'EntraDeviceId',
            'IntunePresent', 'AutopilotPresent', 'EffectiveLastActivityUtc', 'ActivitySource', 'DaysInactive',
            'CutoffDateUtc', 'MatchStatus', 'MatchMethod', 'MatchConfidence', 'Decision', 'ReasonCode',
            'ReasonDescription', 'AutopilotRemovalStatus', 'EntraRemovalStatus', 'ErrorMessage'
        )
        $properties = $eval[0].PSObject.Properties.Name
        foreach ($field in $requiredFields) {
            $properties | Should -Contain $field
        }
    }
}
