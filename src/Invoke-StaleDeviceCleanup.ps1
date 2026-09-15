#Requires -Version 7.0
<#
    .SYNOPSIS
    Identifies, reports on, and (with explicit confirmation) removes stale
    Microsoft Entra ID device objects and their associated Windows Autopilot
    registrations.

    .DESCRIPTION
    Discovers Windows, iOS, and Android device records in Microsoft Entra ID,
    correlates them with Intune managed-device and Windows Autopilot records,
    calculates each device's effective last activity, and classifies devices
    as deletion candidates, excluded, or requiring manual review.

    Intune managed-device records are never deleted by the activity-based
    stale-device workflow. The explicit scrapped-device workflow is the only
    path that removes Intune records.

    ALWAYS RUN AUDIT MODE FIRST AND REVIEW ALL GENERATED REPORTS BEFORE USING
    A DESTRUCTIVE MODE.

    .PARAMETER DaysInactive
    Number of days of inactivity before a device is considered stale. Minimum
    and default value is 180. A timestamp exactly equal to the cutoff is
    treated as stale (inclusive comparison).

    .PARAMETER DaysDisabled
    Number of days an Entra device must remain disabled before it becomes
    eligible for removal. The disable date is persisted under OutputPath.

    .PARAMETER Mode
    Audit (default, never deletes), Interactive (requires typing DELETE), or
    Automatic (requires -ConfirmDeletion, no prompt).

    .PARAMETER OutputPath
    Root folder under which a timestamped run folder is created for reports
    and logs. Defaults to .\output.

    .PARAMETER TenantId
    Optional tenant id to validate the connected Graph context against.

    .PARAMETER ConfirmDeletion
    Required in Automatic mode to allow deletion to proceed. Has no effect in
    Audit or Interactive mode.

    .PARAMETER IncludeDisabledDevices
    Retained for compatibility. Disabled Entra objects are now always tracked
    so that -DaysDisabled can determine when removal is allowed.

    .PARAMETER ProtectedDeviceIdFile
    Path to a CSV file containing EntraObjectId, EntraDeviceId, SerialNumber,
    and/or DeviceName columns. Matching devices are always excluded.

    .PARAMETER ProtectedDeviceNamePattern
    One or more wildcard patterns (e.g. 'PAW-*') for device names that must
    always be excluded from deletion.

    .PARAMETER AllowOnPremisesSyncedDeletion
    Advanced override. When specified, on-premises synchronized devices are
    NOT automatically protected. Use with extreme caution; a synchronized
    object may reappear if its source object remains on-premises.

    .PARAMETER ScrappedDeviceCsvPath
    Path to a recurring CSV/text file containing one physically scrapped
    device serial number per line (header optional). Every serial number that
    matches a Windows Autopilot identity, Intune managed device, and/or Entra
    device object is submitted for removal from the applicable systems,
    independent of activity, disabled-state, or platform. Intune records are
    removed first, then Autopilot serials are submitted through Microsoft's
    bulk deleteDevices action. An accepted submission permits the related
    Entra cleanup without waiting for Autopilot portal synchronization.
    Ambiguous (duplicate serial) or unmatched
    entries are reported but never acted on. Duplicate rows in the input file
    are ignored case-insensitively and counted in the pre-deletion summary.
    Subject to the same Mode/
    -WhatIf/-ConfirmDeletion gating as the stale-device workflow; unlike the
    stale-device workflow, this is the one path that also removes Intune
    managed-device records.

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Audit -DaysInactive 180

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 365 -Verbose

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 180 -WhatIf

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Automatic -DaysInactive 365 -ConfirmDeletion

    .NOTES
    Exit codes:
      0 completed successfully
      1 completed with per-device errors
      2 validation or configuration failure
      3 authentication or authorization failure
      4 incomplete discovery, deletion blocked
      5 administrator cancelled
      6 destructive operation failed
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateRange(180, [int]::MaxValue)]
    [int]$DaysInactive = 180,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$DaysDisabled = 30,

    [ValidateSet('Audit', 'Interactive', 'Automatic')]
    [string]$Mode = 'Audit',

    [string]$OutputPath = '.\output',

    [string]$TenantId,

    [switch]$ConfirmDeletion,

    [switch]$IncludeDisabledDevices,

    [string]$ProtectedDeviceIdFile,

    [string[]]$ProtectedDeviceNamePattern = @(),

    [switch]$AllowOnPremisesSyncedDeletion,

    [string]$ScrappedDeviceCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'StaleDeviceCleanup.psd1'
# Avoid -Force when the module is already loaded (e.g. under Pester with mocks
# injected into the existing module scope) so mocked commands are preserved.
$loadedModule = Get-Module -Name 'StaleDeviceCleanup'
$removeAutopilotCommand = Get-Command -Name 'Remove-WindowsAutopilotRecord' -ErrorAction SilentlyContinue
$getScrappedSerialsCommand = Get-Command -Name 'Get-ScrappedDeviceSerialNumbers' -ErrorAction SilentlyContinue
$showScrappedSummaryCommand = Get-Command -Name 'Show-ScrappedDeviceSummary' -ErrorAction SilentlyContinue
$submitAutopilotBulkCommand = Get-Command -Name 'Submit-WindowsAutopilotBulkRemoval' -ErrorAction SilentlyContinue
$moduleIsCurrent = $loadedModule `
    -and $removeAutopilotCommand `
    -and $removeAutopilotCommand.Parameters.ContainsKey('SuppressErrorLog') `
    -and $getScrappedSerialsCommand `
    -and $getScrappedSerialsCommand.Parameters.ContainsKey('Statistics') `
    -and $showScrappedSummaryCommand `
    -and $showScrappedSummaryCommand.Parameters.ContainsKey('CsvDuplicateCount') `
    -and $submitAutopilotBulkCommand
if (-not $moduleIsCurrent) {
    Import-Module -Name $modulePath -Force
}

$runContext = Initialize-ProjectExecution -OutputPath $OutputPath
$runId = $runContext.RunId
$resolvedOutputPath = $runContext.OutputPath
$logPath = $runContext.LogPath
$startTimeUtc = $runContext.StartTimeUtc
$statePath = Join-Path -Path $OutputPath -ChildPath 'DeviceLifecycleState.json'

$exitCode = 0
$discoveryComplete = $true
$confirmationGranted = $false
$allEvaluatedDevices = @()
$scrappedDeviceRecords = @()
$cutoffDateUtc = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)
$permissionCheck = [PSCustomObject]@{ HasAllRequired = $false; MissingScopes = @(); GrantedScopes = @() }
$deviceLifecycleState = @{}

try {
    Write-CleanupLog -Message "Invoke-StaleDeviceCleanup starting. Version=$scriptVersion PSVersion=$($PSVersionTable.PSVersion) Mode=$Mode DaysInactive=$DaysInactive WhatIf=$([bool]$WhatIfPreference) RunId=$runId" -Level INFO -LogPath $logPath
    $deviceLifecycleState = Get-DeviceLifecycleState -StatePath $statePath

    if ($Mode -eq 'Automatic' -and -not $ConfirmDeletion) {
        Write-CleanupLog -Message 'Automatic mode requires -ConfirmDeletion. Deletion will not be attempted; only discovery and reporting will run.' -Level WARNING -LogPath $logPath
    }

    Test-Prerequisites | Out-Null

    Write-CleanupLog -Message "Cutoff date (UTC): $($cutoffDateUtc.ToString('o')). Timestamps less than or equal to the cutoff are treated as stale." -Level INFO -LogPath $logPath

    # Audit mode only ever requests read scopes. Destructive modes request read/write.
    $readScopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All')
    $writeScopes = @('Device.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
    # Intune managed-device records are only ever removed via the scrapped-device workflow.
    if ($ScrappedDeviceCsvPath) { $writeScopes += 'DeviceManagementManagedDevices.ReadWrite.All' }
    $requestedScopes = if ($Mode -eq 'Audit') { $readScopes } else { $readScopes + $writeScopes }

    Connect-DeviceCleanupGraph -TenantId $TenantId -Scopes $requestedScopes -LogPath $logPath | Out-Null

    $permissionCheck = Test-GraphPermissions -RequiredScopes $requestedScopes
    Write-CleanupLog -Message "Granted scopes: $($permissionCheck.GrantedScopes -join ', ')" -Level INFO -LogPath $logPath
    if (-not $permissionCheck.HasAllRequired) {
        Write-CleanupLog -Message "Missing required Graph scope(s): $($permissionCheck.MissingScopes -join ', ')" -Level WARNING -LogPath $logPath
        if ($Mode -ne 'Audit') {
            Write-CleanupLog -Message 'Required write permissions are missing. Deletion will not be attempted; only discovery and reporting will run.' -Level WARNING -LogPath $logPath
        }
    }

    # Load protected device list.
    $protectedEntraObjectIds = @()
    $protectedEntraDeviceIds = @()
    $protectedSerialNumbers = @()
    $protectedDeviceNames = @()
    if ($ProtectedDeviceIdFile) {
        if (-not (Test-Path -LiteralPath $ProtectedDeviceIdFile)) {
            throw "ProtectedDeviceIdFile '$ProtectedDeviceIdFile' was not found."
        }
        $protectedRows = Import-Csv -LiteralPath $ProtectedDeviceIdFile
        $protectedEntraObjectIds = @($protectedRows | Where-Object { $_.PSObject.Properties.Name -contains 'EntraObjectId' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId)
        $protectedEntraDeviceIds = @($protectedRows | Where-Object { $_.PSObject.Properties.Name -contains 'EntraDeviceId' -and $_.EntraDeviceId } | Select-Object -ExpandProperty EntraDeviceId)
        $protectedSerialNumbers = @($protectedRows | Where-Object { $_.PSObject.Properties.Name -contains 'SerialNumber' -and $_.SerialNumber } | Select-Object -ExpandProperty SerialNumber)
        $protectedDeviceNames = @($protectedRows | Where-Object { $_.PSObject.Properties.Name -contains 'DeviceName' -and $_.DeviceName } | Select-Object -ExpandProperty DeviceName)
        Write-CleanupLog -Message "Loaded $($protectedRows.Count) protected device entries from '$ProtectedDeviceIdFile'." -Level INFO -LogPath $logPath
    }

    # Discovery. A failure here aborts all destructive operations.
    try {
        $entraDevices = Get-EntraDeviceRecords -LogPath $logPath
        $intuneDevices = Get-IntuneManagedDeviceRecords -LogPath $logPath
        $autopilotDevices = Get-WindowsAutopilotRecords -LogPath $logPath
    } catch {
        $discoveryComplete = $false
        Write-CleanupLog -Message "Global discovery failed: $($_.Exception.Message)" -Level ERROR -LogPath $logPath
        $exitCode = 4
        throw
    }

    $indexes = New-DeviceIndexes -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices

    if ($ScrappedDeviceCsvPath) {
        $scrappedCsvStatistics = $null
        $scrappedSerialNumbers = Get-ScrappedDeviceSerialNumbers -Path $ScrappedDeviceCsvPath -Statistics ([ref]$scrappedCsvStatistics)
        Write-CleanupLog -Message "Loaded $($scrappedSerialNumbers.Count) unique scrapped device serial number(s) from '$ScrappedDeviceCsvPath'; ignored $($scrappedCsvStatistics.DuplicateRowCount) duplicate CSV row(s)." -Level INFO -LogPath $logPath
        $scrappedDeviceRecords = Resolve-ScrappedDeviceRecords -SerialNumbers $scrappedSerialNumbers -EntraDevices $entraDevices `
            -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices -RunId $runId
        $scrappedMatchedRecords = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')
        $scrappedMatched = @($scrappedMatchedRecords | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedAmbiguous = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'Ambiguous' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedNotFound = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'NotFound' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedAutopilotTargets = @($scrappedMatchedRecords | Where-Object AutopilotIdentityId | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedIntuneTargets = @($scrappedMatchedRecords | Where-Object IntuneManagedDeviceId | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedEntraTargets = @($scrappedMatchedRecords | Where-Object EntraObjectId | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        Write-CleanupLog -Message "Scrapped device resolution: InputSerials=$($scrappedSerialNumbers.Count) MatchedSerials=$scrappedMatched AmbiguousSerials=$scrappedAmbiguous NotFoundSerials=$scrappedNotFound; AutopilotTargets=$scrappedAutopilotTargets IntuneTargets=$scrappedIntuneTargets EntraTargets=$scrappedEntraTargets." -Level INFO -LogPath $logPath

        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        Show-ScrappedDeviceSummary -ScrappedDeviceRecords $scrappedDeviceRecords -OutputPath $resolvedOutputPath `
            -CsvDuplicateCount $scrappedCsvStatistics.DuplicateRowCount

        switch ($Mode) {
            'Audit' {
                Write-CleanupLog -Message 'Scrapped-device branch: audit mode, no deletions were attempted.' -Level SUCCESS -LogPath $logPath
                Write-Host 'Scrapped-device branch: audit mode, no deletions were attempted.'
                return
            }
            'Interactive' {
                if (-not $discoveryComplete -or -not $permissionCheck.HasAllRequired) {
                    Write-CleanupLog -Message 'Scrapped-device branch: skipping confirmation because discovery is incomplete or permissions are insufficient.' -Level WARNING -LogPath $logPath
                    return
                }
                $confirmationGranted = Request-DeletionConfirmation
                if (-not $confirmationGranted) {
                    Write-CleanupLog -Message 'Scrapped-device branch: administrator did not confirm deletion. No changes were made.' -Level INFO -LogPath $logPath
                    $exitCode = 5
                    return
                }
            }
            'Automatic' {
                if (-not $ConfirmDeletion) {
                    Write-CleanupLog -Message 'Scrapped-device branch: automatic mode without -ConfirmDeletion. No changes were made.' -Level WARNING -LogPath $logPath
                    $exitCode = 2
                    return
                }
                if (-not $discoveryComplete -or -not $permissionCheck.HasAllRequired) {
                    Write-CleanupLog -Message 'Scrapped-device branch: automatic mode is blocked because discovery is incomplete or permissions are insufficient.' -Level WARNING -LogPath $logPath
                    $exitCode = 4
                    return
                }
                $confirmationGranted = $true
            }
        }

        Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $scrappedDeviceRecords -LogPath $logPath -WhatIf:$WhatIfPreference

        $scrappedSubmittedAutopilot = @($scrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'RemovalSubmitted' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedRemovedIntune = @($scrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'Removed' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedRemovedEntra = @($scrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'Removed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        Write-CleanupLog -Message "Scrapped device removals completed: Autopilot submissions accepted=$scrappedSubmittedAutopilot; Intune removed=$scrappedRemovedIntune; Entra removed=$scrappedRemovedEntra." -Level INFO -LogPath $logPath
        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        if (@($scrappedDeviceRecords | Where-Object { $_.ErrorMessage }).Count -gt 0 -and $exitCode -eq 0) { $exitCode = 6 }
        return
    }

    $allEvaluatedDevices = Get-StaleDeviceCandidates -EntraDevices $entraDevices -Indexes $indexes -CutoffDateUtc $cutoffDateUtc `
        -RunId $runId -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
        -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
        -ProtectedNamePatterns $ProtectedDeviceNamePattern -IncludeDisabledDevices:$IncludeDisabledDevices `
        -DeviceLifecycleState $deviceLifecycleState -DaysDisabled $DaysDisabled `
        -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion

    $newlyTrackedDisabled = 0
    foreach ($evaluatedDevice in $allEvaluatedDevices) {
        if ($evaluatedDevice.EntraAccountEnabled -eq $false -and -not $deviceLifecycleState.ContainsKey([string]$evaluatedDevice.EntraObjectId)) {
            $deviceLifecycleState[[string]$evaluatedDevice.EntraObjectId] = $startTimeUtc.ToString('o')
            $evaluatedDevice.DisabledSinceUtc = $startTimeUtc
            $evaluatedDevice.DaysDisabled = 0
            $newlyTrackedDisabled++
        }
    }
    Save-DeviceLifecycleState -State $deviceLifecycleState -StatePath $statePath
    Write-CleanupLog -Message "Lifecycle state loaded from '$statePath'. Newly tracked disabled Entra object(s): $newlyTrackedDisabled." -Level INFO -LogPath $logPath
    $plannedDisableCount = @($allEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.EntraAction -eq 'Disable' }).Count
    $plannedRemoveCount = @($allEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.EntraAction -eq 'Remove' }).Count
    Write-CleanupLog -Message "Lifecycle actions planned: Entra object(s) to disable=$plannedDisableCount; Entra object(s) to remove=$plannedRemoveCount." -Level INFO -LogPath $logPath

    # Reports must exist before any confirmation prompt, in every mode.
    Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
    Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')

    Show-CleanupSummary -EvaluatedDevices $allEvaluatedDevices -CutoffDateUtc $cutoffDateUtc -DaysInactive $DaysInactive -DaysDisabled $DaysDisabled -OutputPath $resolvedOutputPath

    $shouldAttemptDeletion = $false
    switch ($Mode) {
        'Audit' {
            Write-CleanupLog -Message 'Audit mode: no changes were made.' -Level SUCCESS -LogPath $logPath
            Write-Host 'Audit mode: no changes were made.'
        }
        'Interactive' {
            if (-not $discoveryComplete -or -not $permissionCheck.HasAllRequired) {
                Write-CleanupLog -Message 'Skipping confirmation prompt because discovery is incomplete or permissions are insufficient.' -Level WARNING -LogPath $logPath
            } else {
                $confirmationGranted = Request-DeletionConfirmation
                if ($confirmationGranted) {
                    $shouldAttemptDeletion = $true
                } else {
                    Write-CleanupLog -Message 'Administrator did not confirm deletion. No changes were made.' -Level INFO -LogPath $logPath
                    $exitCode = 5
                }
            }
        }
        'Automatic' {
            if (-not $ConfirmDeletion) {
                Write-CleanupLog -Message 'Automatic mode without -ConfirmDeletion: no changes were made.' -Level WARNING -LogPath $logPath
                $exitCode = 2
            } elseif (-not $discoveryComplete -or -not $permissionCheck.HasAllRequired) {
                Write-CleanupLog -Message 'Automatic mode: discovery incomplete or permissions insufficient. No changes were made.' -Level WARNING -LogPath $logPath
                $exitCode = 4
            } else {
                $confirmationGranted = $true
                $shouldAttemptDeletion = $true
            }
        }
    }

    if ($shouldAttemptDeletion -and $discoveryComplete) {
        $candidates = @($allEvaluatedDevices | Where-Object Decision -eq 'Candidate')
        $deletionErrors = 0
        $autopilotCandidates = @($candidates | Where-Object {
                $_.Platform -eq 'Windows' -and $_.AutopilotPresent -and $_.MatchConfidence -eq 'High'
            })
        $autopilotSerials = @($autopilotCandidates | Where-Object AutopilotSerialNumber | Select-Object -ExpandProperty AutopilotSerialNumber -Unique)
        $bulkStatesBySerial = @{}
        $bulkSubmissionError = $null

        if ($autopilotSerials.Count -gt 0) {
            Write-CleanupLog -Message "Submitting $($autopilotSerials.Count) unique stale-device serial number(s) for bulk Autopilot removal." -Level INFO -LogPath $logPath
            try {
                $bulkStates = @(Submit-WindowsAutopilotBulkRemoval -SerialNumbers $autopilotSerials -LogPath $logPath -WhatIf:$WhatIfPreference -Confirm:$false)
                foreach ($bulkState in $bulkStates) {
                    $normalizedSerial = ConvertTo-NormalizedSerialNumber -SerialNumber $bulkState.serialNumber
                    if ($normalizedSerial) { $bulkStatesBySerial[$normalizedSerial] = $bulkState }
                }
            } catch {
                $bulkSubmissionError = $_.Exception.Message
                Write-CleanupLog -Message "Stale-device Autopilot bulk removal request failed: $bulkSubmissionError" -Level ERROR -LogPath $logPath
            }
        }

        foreach ($candidate in $autopilotCandidates) {
            if ($WhatIfPreference) {
                $candidate.AutopilotRemovalStatus = 'WhatIf'
                continue
            }

            $normalizedSerial = ConvertTo-NormalizedSerialNumber -SerialNumber $candidate.AutopilotSerialNumber
            $bulkState = if ($normalizedSerial -and $bulkStatesBySerial.ContainsKey($normalizedSerial)) { $bulkStatesBySerial[$normalizedSerial] } else { $null }
            $deletionState = if ($bulkState -and $bulkState.deletionState) { $bulkState.deletionState.ToString().ToLowerInvariant() } else { 'missing' }
            if ($deletionState -eq 'accepted') {
                $candidate.AutopilotRemovalStatus = 'RemovalSubmitted'
            } else {
                $candidate.AutopilotRemovalStatus = 'RemovalFailed'
                $candidate.ErrorMessage = if ($bulkSubmissionError) {
                    $bulkSubmissionError
                } elseif (-not $normalizedSerial) {
                    'The matched Autopilot identity has no usable serial number for bulk removal.'
                } elseif ($bulkState -and $bulkState.errorMessage) {
                    $bulkState.errorMessage
                } else {
                    "Autopilot bulk removal returned state '$deletionState'."
                }
                Write-CleanupLog -Message "Stale-device Autopilot bulk removal was not accepted for serial '$($candidate.AutopilotSerialNumber)' and Entra object '$($candidate.EntraObjectId)': $($candidate.ErrorMessage)" -Level ERROR -LogPath $logPath
                $deletionErrors++
            }
        }

        foreach ($candidate in $candidates) {
            try {
                if (-not $candidate.AutopilotPresent) {
                    $candidate.AutopilotRemovalStatus = 'NotApplicable'
                }

                $autopilotAccepted = -not $candidate.AutopilotPresent -or $candidate.AutopilotRemovalStatus -in 'RemovalSubmitted', 'WhatIf'
                if ($autopilotAccepted -and $candidate.EntraAction -eq 'Disable') {
                    $entraDisabled = Disable-EntraDeviceRecord -EntraObjectId $candidate.EntraObjectId -LogPath $logPath -WhatIf:$WhatIfPreference -Confirm:$false
                    if ($WhatIfPreference) {
                        $candidate.EntraDisableStatus = 'WhatIf'
                    } elseif ($entraDisabled) {
                        $candidate.EntraDisableStatus = 'Disabled'
                        $candidate.EntraRemovalStatus = 'NotYetEligible'
                        $deviceLifecycleState[[string]$candidate.EntraObjectId] = (Get-Date).ToUniversalTime().ToString('o')
                        $candidate.DisabledSinceUtc = Get-SafeUtcTimestamp -Value $deviceLifecycleState[[string]$candidate.EntraObjectId]
                        $candidate.DaysDisabled = 0
                        Write-CleanupLog -Message "Disabled Entra device object '$($candidate.EntraObjectId)' ('$($candidate.DeviceName)')." -Level SUCCESS -LogPath $logPath
                    } else {
                        $candidate.EntraDisableStatus = 'Skipped'
                    }
                } elseif ($candidate.AutopilotPresent -and $candidate.AutopilotRemovalStatus -in 'RemovalSubmitted', 'WhatIf' -and $candidate.EntraAction -eq 'Remove') {
                    $candidate.EntraRemovalStatus = 'PendingAutopilotRemoval'
                    Write-CleanupLog -Message "Autopilot removal was accepted for '$($candidate.AutopilotIdentityId)'; permanent Entra removal for '$($candidate.EntraObjectId)' is deferred until a later discovery confirms the Autopilot record is absent." -Level INFO -LogPath $logPath
                } elseif ($autopilotAccepted -and $candidate.EntraAction -eq 'Remove') {
                    $entraRemoved = Remove-EntraDeviceRecord -EntraObjectId $candidate.EntraObjectId -LogPath $logPath -WhatIf:$WhatIfPreference -Confirm:$false
                    if ($WhatIfPreference) {
                        $candidate.EntraRemovalStatus = 'WhatIf'
                    } elseif ($entraRemoved) {
                        $candidate.EntraRemovalStatus = 'Removed'
                        $deviceLifecycleState.Remove([string]$candidate.EntraObjectId)
                        Write-CleanupLog -Message "Removed Entra device object '$($candidate.EntraObjectId)' ('$($candidate.DeviceName)')." -Level SUCCESS -LogPath $logPath
                    } else {
                        $candidate.EntraRemovalStatus = 'Skipped'
                    }
                } else {
                    $candidate.EntraRemovalStatus = 'SkippedAutopilotSubmissionFailed'
                }
            } catch {
                $deletionErrors++
                $candidate.ErrorMessage = $_.Exception.Message
                Write-CleanupLog -Message "Failed to process deletion for Entra device '$($candidate.EntraObjectId)': $($_.Exception.Message)" -Level ERROR -LogPath $logPath
            }
        }

        # Re-write reports so DeletedDevices.csv and status columns reflect the outcome.
        Save-DeviceLifecycleState -State $deviceLifecycleState -StatePath $statePath
        $disabledCount = @($allEvaluatedDevices | Where-Object EntraDisableStatus -eq 'Disabled').Count
        $removedCount = @($allEvaluatedDevices | Where-Object EntraRemovalStatus -eq 'Removed').Count
        $autopilotSubmittedCount = @($allEvaluatedDevices | Where-Object AutopilotRemovalStatus -eq 'RemovalSubmitted').Count
        Write-CleanupLog -Message "Lifecycle actions completed: Autopilot removal submission(s) accepted=$autopilotSubmittedCount; Entra object(s) disabled=$disabledCount; Entra object(s) removed=$removedCount." -Level INFO -LogPath $logPath
        Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath

        if ($deletionErrors -gt 0 -and $exitCode -eq 0) { $exitCode = 6 }
    }

    if ($exitCode -eq 0 -and @($allEvaluatedDevices | Where-Object { $_.ErrorMessage }).Count -gt 0) {
        $exitCode = 1
    }
} catch {
    Write-CleanupLog -Message "Unhandled error: $($_.Exception.Message)" -Level ERROR -LogPath $logPath
    if ($exitCode -eq 0) { $exitCode = 3 }
} finally {
    $runSummary = New-RunSummary -RunId $runId -Mode $Mode -StartTimeUtc $startTimeUtc -CutoffDateUtc $cutoffDateUtc `
        -DaysInactive $DaysInactive -DaysDisabled $DaysDisabled -AllEvaluatedDevices $allEvaluatedDevices -WhatIfMode ([bool]$WhatIfPreference) `
        -ScrappedDeviceRecords $scrappedDeviceRecords -ConfirmationGranted $confirmationGranted -DiscoveryComplete $discoveryComplete -ExitCode $exitCode

    Complete-ProjectExecution -RunSummary $runSummary -OutputPath $resolvedOutputPath -LogPath $logPath
}

exit $exitCode
