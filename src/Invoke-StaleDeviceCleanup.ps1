#Requires -Version 7.0
<#
    .SYNOPSIS
    Identifies, reports on, and (with explicit confirmation) removes stale
    standalone Microsoft Entra ID device objects. Explicit scrapped hardware
    cleanup deregisters Intune and Windows Autopilot records separately.

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
    treated as stale (inclusive comparison). Available only in the default
    inactivity parameter set; cannot be combined with -ScrappedDevices.

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
    Retained for compatibility.

    .PARAMETER ProtectedDeviceIdFile
    Path to a CSV file containing EntraObjectId, EntraDeviceId, SerialNumber,
    and/or DeviceName columns. Matching devices are always excluded. DeviceName
    values support the same wildcard syntax as -ProtectedDeviceNamePattern
    (e.g. 'PAW*'), as well as literal names.

    .PARAMETER ProtectedDeviceNamePattern
    One or more wildcard patterns (e.g. 'PAW-*') for device names that must
    always be excluded from deletion.

    .PARAMETER AllowOnPremisesSyncedDeletion
    Advanced override. When specified, on-premises synchronized devices are
    NOT automatically protected. Use with extreme caution; a synchronized
    object may reappear if its source object remains on-premises.

    .PARAMETER ScrappedDevices
    Selects explicit hardware retirement, without any inactivity evaluation.
    Removes safely correlated Intune records, then Windows Autopilot identities,
    then Entra objects after all related Autopilot DELETE requests are accepted.
    Failed prerequisites block dependent targets; independent targets continue.
    Protection, platform, synchronization and ambiguity checks remain. Audit
    is still the default; this switch alone never deletes.

    .PARAMETER ScrappedDeviceCsvPath
    Optional input override for -ScrappedDevices. Defaults to
    config\scrappeddevices.csv relative to the repository containing this script.
    Requires a unique SerialNumber column. Empty serials
    are ignored and duplicates are counted and deduplicated case-insensitively.
    Path-only invocation is no longer supported.

    .PARAMETER AllowLegacyScrappedDeviceFormat
    Explicitly accepts the old headerless, one-serial-per-line text format.
    Requires -ScrappedDevices. This controls input parsing, not deletion policy.

    .PARAMETER DeletionTransport
    Individual (default) uses SDK deletion cmdlets. JsonBatch is an opt-in
    transport with tenant-bound plans, per-object results and durable journals.

    .PARAMETER BatchSize
    Maximum independent operations per JSON batch, from 1 through 20.

    .PARAMETER VerifyDeletion
    Optional bounded read-back of successful IDs, supported only with JsonBatch.
    Observed absence is recorded separately from DELETE acceptance.

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Audit -DaysInactive 180

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 365 -Verbose

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 180 -WhatIf

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -Mode Automatic -DaysInactive 365 -ConfirmDeletion

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Audit

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Automatic -ConfirmDeletion -WhatIf

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
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Inactivity')]
param(
    [Parameter(ParameterSetName = 'Inactivity')]
    [ValidateRange(180, [int]::MaxValue)]
    [int]$DaysInactive = 180,

    [ValidateSet('Audit', 'Interactive', 'Automatic')]
    [string]$Mode = 'Audit',

    [string]$OutputPath = '.\output',

    [string]$TenantId,

    [switch]$ConfirmDeletion,

    [switch]$IncludeDisabledDevices,

    [string]$ProtectedDeviceIdFile,

    [string[]]$ProtectedDeviceNamePattern = @(),

    [switch]$AllowOnPremisesSyncedDeletion,

    [Parameter(Mandatory, ParameterSetName = 'Scrapped')]
    [switch]$ScrappedDevices,

    [Parameter(ParameterSetName = 'Scrapped')]
    [string]$ScrappedDeviceCsvPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\scrappeddevices.csv'),

    [Parameter(ParameterSetName = 'Scrapped')]
    [switch]$AllowLegacyScrappedDeviceFormat,

    [ValidateSet('Individual', 'JsonBatch')]
    [string]$DeletionTransport = 'Individual',

    [ValidateRange(1, 20)]
    [int]$BatchSize = 20,

    [switch]$VerifyDeletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($VerifyDeletion -and $DeletionTransport -ne 'JsonBatch') {
    throw '-VerifyDeletion requires -DeletionTransport JsonBatch.'
}

$scriptVersion = '1.2.0'
$requiredModuleVersion = [version]'1.2.0'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'StaleDeviceCleanup.psd1'
# Avoid -Force when the module is already loaded (e.g. under Pester with mocks
# injected into the existing module scope) so mocked commands are preserved.
$loadedModule = Get-Module -Name 'StaleDeviceCleanup'
$removeAutopilotCommand = Get-Command -Name 'Remove-WindowsAutopilotRecord' -ErrorAction SilentlyContinue
$newRunSummaryCommand = Get-Command -Name 'New-RunSummary' -ErrorAction SilentlyContinue
$getScrappedSerialsCommand = Get-Command -Name 'Get-ScrappedDeviceSerialNumbers' -ErrorAction SilentlyContinue
$showScrappedSummaryCommand = Get-Command -Name 'Show-ScrappedDeviceSummary' -ErrorAction SilentlyContinue
$showCleanupSummaryCommand = Get-Command -Name 'Show-CleanupSummary' -ErrorAction SilentlyContinue
$submitAutopilotIdentityCommand = Get-Command -Name 'Submit-WindowsAutopilotIdentityRemoval' -ErrorAction SilentlyContinue
$scrappedBatchRemovalCommand = Get-Command -Name 'Invoke-ScrappedDeviceBatchRemoval' -ErrorAction SilentlyContinue
$batchCommand = Get-Command -Name 'Invoke-DeviceDeletionPlan' -ErrorAction SilentlyContinue
$moduleIsCurrent = $loadedModule `
    -and $loadedModule.Version -eq $requiredModuleVersion `
    -and $removeAutopilotCommand `
    -and $removeAutopilotCommand.Parameters.ContainsKey('SuppressErrorLog') `
    -and $newRunSummaryCommand `
    -and $newRunSummaryCommand.Parameters.ContainsKey('AllowOnPremisesSyncedDeletion') `
    -and $getScrappedSerialsCommand `
    -and $getScrappedSerialsCommand.Parameters.ContainsKey('Statistics') `
    -and $getScrappedSerialsCommand.Parameters.ContainsKey('AllowLegacyFormat') `
    -and $showScrappedSummaryCommand `
    -and $showScrappedSummaryCommand.Parameters.ContainsKey('CsvDuplicateCount') `
    -and $showScrappedSummaryCommand.Parameters.ContainsKey('Simulation') `
    -and $showCleanupSummaryCommand `
    -and $showCleanupSummaryCommand.Parameters.ContainsKey('Simulation') `
    -and $submitAutopilotIdentityCommand `
    -and $scrappedBatchRemovalCommand `
    -and $batchCommand
if (-not $moduleIsCurrent) {
    Import-Module -Name $modulePath -Force
}

$runContext = Initialize-ProjectExecution -OutputPath $OutputPath
$runId = $runContext.RunId
$resolvedOutputPath = $runContext.OutputPath
$logPath = $runContext.LogPath
$startTimeUtc = $runContext.StartTimeUtc
$exitCode = 0
$discoveryComplete = $true
$confirmationGranted = $false
$allEvaluatedDevices = @()
$scrappedDeviceRecords = @()
$scrappedWorkflow = $PSCmdlet.ParameterSetName -eq 'Scrapped'
if ($scrappedWorkflow -and -not $ScrappedDevices) {
    throw '-ScrappedDevices must be explicitly enabled.'
}
if (-not $scrappedWorkflow) {
    $cutoffDateUtc = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)
}
$permissionCheck = [PSCustomObject]@{ HasAllRequired = $false; MissingScopes = @(); GrantedScopes = @() }
$deletionPlan = $null
$approvalHash = ''
$journalPath = Join-Path $resolvedOutputPath 'DeletionJournal.jsonl'

try {
    $workflowDescription = if ($scrappedWorkflow) { 'Workflow=Scrapped' } else { "Workflow=Inactivity DaysInactive=$DaysInactive" }
    Write-CleanupLog -Message "Invoke-StaleDeviceCleanup starting. Version=$scriptVersion PSVersion=$($PSVersionTable.PSVersion) Mode=$Mode $workflowDescription WhatIf=$([bool]$WhatIfPreference) RunId=$runId" -Level INFO -LogPath $logPath
    if ($Mode -eq 'Automatic' -and -not $ConfirmDeletion) {
        Write-CleanupLog -Message 'Automatic mode requires -ConfirmDeletion. Deletion will not be attempted; only discovery and reporting will run.' -Level WARNING -LogPath $logPath
    }

    Test-Prerequisites | Out-Null

    if (-not $scrappedWorkflow) {
        Write-CleanupLog -Message "Cutoff date (UTC): $($cutoffDateUtc.ToString('o')). Timestamps less than or equal to the cutoff are treated as stale." -Level INFO -LogPath $logPath
    }

    # Audit mode only ever requests read scopes. Destructive modes request read/write.
    $readScopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All')
    $writeScopes = @('Directory.AccessAsUser.All')
    # Intune managed-device records are only ever removed via the scrapped-device workflow.
    if ($scrappedWorkflow) {
        $writeScopes += @('DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
    }
    $requestedScopes = if ($Mode -eq 'Audit') { $readScopes } else { $readScopes + $writeScopes }

    $connectedContext = Connect-DeviceCleanupGraph -TenantId $TenantId -Scopes $requestedScopes -LogPath $logPath
    Write-Host "Connected tenant: $($connectedContext.TenantId); authentication: $($connectedContext.AuthType)."

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

    if ($scrappedWorkflow) {
        $scrappedCsvStatistics = $null
        $scrappedSerialNumbers = Get-ScrappedDeviceSerialNumbers -Path $ScrappedDeviceCsvPath -Statistics ([ref]$scrappedCsvStatistics) `
            -AllowLegacyFormat:$AllowLegacyScrappedDeviceFormat
    }
    # Discovery. A failure here aborts all destructive operations.
    $discoveryStates = @{ Entra = 'NotAttempted'; Intune = 'NotAttempted'; Autopilot = 'NotAttempted' }
    $discoveryService = 'Entra'
    try {
        $entraDevices = Get-EntraDeviceRecords -LogPath $logPath
        $discoveryStates.Entra = 'LookupSucceededCorrelationBlocked'
        $discoveryService = 'Intune'
        $intuneDevices = Get-IntuneManagedDeviceRecords -LogPath $logPath
        $discoveryStates.Intune = 'LookupSucceededCorrelationBlocked'
        $discoveryService = 'Autopilot'
        $autopilotDevices = Get-WindowsAutopilotRecords -LogPath $logPath
        $discoveryStates.Autopilot = 'LookupSucceededCorrelationBlocked'
    } catch {
        $discoveryComplete = $false
        $discoveryStates[$discoveryService] = 'FailedLookup'
        Write-CleanupLog -Message "Global discovery failed: $($_.Exception.Message)" -Level ERROR -LogPath $logPath
        if ($scrappedWorkflow) {
            $scrappedDeviceRecords = Resolve-ScrappedDeviceRecords -SerialNumbers $scrappedSerialNumbers -EntraDevices @() `
                -IntuneDevices @() -AutopilotDevices @() -RunId $runId
            foreach ($record in $scrappedDeviceRecords) {
                $record.MatchStatus = 'LookupFailed'
                $record.ErrorMessage = 'Required service discovery failed; no destructive operations are permitted.'
                foreach ($service in @('Entra', 'Intune', 'Autopilot')) {
                    $record | Add-Member -NotePropertyName "${service}LookupStatus" -NotePropertyValue $discoveryStates[$service]
                }
            }
        }
        $exitCode = 4
        throw
    }

    $indexes = New-DeviceIndexes -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices

    if ($scrappedWorkflow) {
        Write-CleanupLog -Message "Loaded $($scrappedSerialNumbers.Count) unique scrapped device serial number(s) from '$ScrappedDeviceCsvPath'; ignored $($scrappedCsvStatistics.DuplicateRowCount) duplicate CSV row(s)." -Level INFO -LogPath $logPath
        $scrappedDeviceRecords = Resolve-ScrappedDeviceRecords -SerialNumbers $scrappedSerialNumbers -EntraDevices $entraDevices `
            -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices -RunId $runId `
            -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
            -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
            -ProtectedNamePatterns $ProtectedDeviceNamePattern -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion
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
            -CsvDuplicateCount $scrappedCsvStatistics.DuplicateRowCount -TenantId $connectedContext.TenantId `
            -Mode $Mode -Simulation ([bool]$WhatIfPreference) -DeletionTransport $DeletionTransport
        if ($DeletionTransport -eq 'JsonBatch') {
            $deletionPlan = New-DeviceDeletionPlan -TenantId $connectedContext.TenantId -RunId $runId -Workflow Scrapped -Records $scrappedDeviceRecords
            $deletionPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'DeletionPlan.json') -Encoding utf8 -WhatIf:$false
            $approvalHash = $deletionPlan.Hash
            Write-Host "Tenant: $($deletionPlan.TenantId); unique operations: $($deletionPlan.Operations.Count); plan hash: $approvalHash"
        }

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

        if ($DeletionTransport -eq 'JsonBatch') {
            $results = @(Invoke-DeviceDeletionPlan -Plan $deletionPlan -ApprovalHash $approvalHash -Mode $Mode `
                -ConfirmDeletion:$confirmationGranted -BatchSize $BatchSize -JournalPath $journalPath -LogPath $logPath `
                -WhatIf:$WhatIfPreference -Confirm:$false -VerifyDeletion:$VerifyDeletion)
            Set-DeviceDeletionResults -Workflow Scrapped -Records $scrappedDeviceRecords -Results $results
        } else {
            Assert-DeviceCleanupContext -TenantId $connectedContext.TenantId -RequiredScopes $requestedScopes
            Invoke-ScrappedDeviceRemoval -ScrappedDeviceRecords $scrappedDeviceRecords -LogPath $logPath `
                -ExpectedTenantId $connectedContext.TenantId -WhatIf:$WhatIfPreference -Confirm:$false
        }

        $scrappedSubmittedAutopilot = @($scrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'RemovalSubmitted' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedAlreadyRemovedAutopilot = @($scrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'AlreadyRemoved' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedFailedAutopilot = @($scrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'RemovalFailed' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedRemovedIntune = @($scrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'Removed' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedAlreadyRemovedIntune = @($scrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'AlreadyRemoved' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedFailedIntune = @($scrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'RemovalFailed' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedRemovedEntra = @($scrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'Removed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        $scrappedAlreadyRemovedEntra = @($scrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -in 'AlreadyRemoved', 'AlreadyAbsent' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        $scrappedFailedEntra = @($scrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'RemovalFailed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        $scrappedBlockedEntra = @($scrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'BlockedDependency' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        Write-CleanupLog -Message "Scrapped device removals completed: Autopilot accepted=$scrappedSubmittedAutopilot, already absent=$scrappedAlreadyRemovedAutopilot, failed=$scrappedFailedAutopilot; Intune removed=$scrappedRemovedIntune, already absent=$scrappedAlreadyRemovedIntune, failed=$scrappedFailedIntune; Entra removed=$scrappedRemovedEntra, already absent=$scrappedAlreadyRemovedEntra, failed=$scrappedFailedEntra, blocked by Autopilot=$scrappedBlockedEntra." -Level INFO -LogPath $logPath
        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        if (@($scrappedDeviceRecords | Where-Object { $_.ErrorMessage }).Count -gt 0 -and $exitCode -eq 0) { $exitCode = 6 }
        return
    }

    $allEvaluatedDevices = Get-StaleDeviceCandidates -EntraDevices $entraDevices -Indexes $indexes -CutoffDateUtc $cutoffDateUtc `
        -RunId $runId -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
        -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
        -ProtectedNamePatterns $ProtectedDeviceNamePattern -IncludeDisabledDevices:$IncludeDisabledDevices `
        -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion

    $plannedRemoveCount = @($allEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.EntraAction -eq 'Remove' }).Count
    Write-CleanupLog -Message "Lifecycle actions planned: Entra object(s) to remove=$plannedRemoveCount." -Level INFO -LogPath $logPath

    # Reports must exist before any confirmation prompt, in every mode.
    Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
    Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')

    Show-CleanupSummary -EvaluatedDevices $allEvaluatedDevices -CutoffDateUtc $cutoffDateUtc -DaysInactive $DaysInactive `
        -OutputPath $resolvedOutputPath -TenantId $connectedContext.TenantId -Mode $Mode `
        -Simulation ([bool]$WhatIfPreference) -DeletionTransport $DeletionTransport
    if ($DeletionTransport -eq 'JsonBatch') {
        $deletionPlan = New-DeviceDeletionPlan -TenantId $connectedContext.TenantId -RunId $runId -Workflow Stale -Records $allEvaluatedDevices
        $deletionPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'DeletionPlan.json') -Encoding utf8 -WhatIf:$false
        $approvalHash = $deletionPlan.Hash
        Write-Host "Tenant: $($deletionPlan.TenantId); unique operations: $($deletionPlan.Operations.Count); plan hash: $approvalHash"
    }

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
        if ($DeletionTransport -eq 'JsonBatch') {
            $results = @(Invoke-DeviceDeletionPlan -Plan $deletionPlan -ApprovalHash $approvalHash -Mode $Mode `
                -ConfirmDeletion:$confirmationGranted -BatchSize $BatchSize -JournalPath $journalPath -LogPath $logPath `
                -WhatIf:$WhatIfPreference -Confirm:$false -VerifyDeletion:$VerifyDeletion)
            Set-DeviceDeletionResults -Workflow Stale -Records $allEvaluatedDevices -Results $results
            $deletionErrors = @($results | Where-Object { $_.Status -in 'RemovalFailed', 'OutcomeUnknown', 'BlockedDependency' }).Count
        } else {
            foreach ($candidate in $candidates) {
                try {
                    Assert-DeviceCleanupContext -TenantId $connectedContext.TenantId -RequiredScopes $requestedScopes
                    if ($candidate.AutopilotPresent -or $candidate.EntraAction -ne 'Remove') {
                        throw 'Candidate violates the standalone Entra removal policy.'
                    }
                    $candidate.AutopilotRemovalStatus = 'NotApplicable'
                    $entraRemoved = Remove-EntraDeviceRecord -EntraObjectId $candidate.EntraObjectId -LogPath $logPath -WhatIf:$WhatIfPreference -Confirm:$false
                    if ($WhatIfPreference) {
                        $candidate.EntraRemovalStatus = 'WhatIf'
                    } elseif ($entraRemoved) {
                        $candidate.EntraRemovalStatus = 'Removed'
                        Write-CleanupLog -Message "Removed Entra device object '$($candidate.EntraObjectId)' ('$($candidate.DeviceName)')." -Level SUCCESS -LogPath $logPath
                    } else {
                        $candidate.EntraRemovalStatus = 'Skipped'
                    }
                } catch {
                    $deletionErrors++
                    $candidate.ErrorMessage = $_.Exception.Message
                    Write-CleanupLog -Message "Failed to process deletion for Entra device '$($candidate.EntraObjectId)': $($_.Exception.Message)" -Level ERROR -LogPath $logPath
                }
            }
        }

        # Re-write reports so DeletedDevices.csv and status columns reflect the outcome.
        $removedCount = @($allEvaluatedDevices | Where-Object EntraRemovalStatus -eq 'Removed').Count
        $autopilotSubmittedCount = @($allEvaluatedDevices | Where-Object AutopilotRemovalStatus -in 'RemovalSubmitted', 'AlreadyRemoved').Count
        Write-CleanupLog -Message "Lifecycle actions completed: Autopilot removal submission(s) accepted=$autopilotSubmittedCount; Entra object(s) disabled=0; Entra object(s) removed=$removedCount." -Level INFO -LogPath $logPath
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
    if ($deletionPlan -and (Test-Path -LiteralPath $journalPath)) {
        $journal = Get-Content -LiteralPath $journalPath -Tail 1 | ConvertFrom-Json
        if ($journal.PlanHash -cne $approvalHash -or $journal.TenantId -ne $deletionPlan.TenantId) {
            throw 'Deletion journal does not match the approved plan.'
        }
        $records = if ($scrappedWorkflow) { $scrappedDeviceRecords } else { $allEvaluatedDevices }
        Set-DeviceDeletionResults -Workflow $deletionPlan.Workflow -Records $records -Results @($journal.Results)
    }
    Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
    Set-ScrappedDeviceOutcomes -Records $scrappedDeviceRecords
    if ($scrappedWorkflow -and $confirmationGranted -and -not $WhatIfPreference -and $exitCode -eq 0 -and
        @($scrappedDeviceRecords | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.CleanupOutcome -ne 'Complete' }).Count) {
        $exitCode = 6
    }
    Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
    $summaryParameters = if ($scrappedWorkflow) { @{ ScrappedDevices = $true } } else { @{ CutoffDateUtc = $cutoffDateUtc; DaysInactive = $DaysInactive } }
    $runSummary = New-RunSummary @summaryParameters -RunId $runId -Mode $Mode -StartTimeUtc $startTimeUtc `
        -AllEvaluatedDevices $allEvaluatedDevices -WhatIfMode ([bool]$WhatIfPreference) `
        -ScrappedDeviceRecords $scrappedDeviceRecords -AllowOnPremisesSyncedDeletion ([bool]$AllowOnPremisesSyncedDeletion) `
        -ConfirmationGranted $confirmationGranted -DiscoveryComplete $discoveryComplete -ExitCode $exitCode

    Complete-ProjectExecution -RunSummary $runSummary -OutputPath $resolvedOutputPath -LogPath $logPath
}

exit $exitCode
