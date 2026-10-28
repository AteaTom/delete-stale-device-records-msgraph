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

    ResumeFromRunPath selects an original scrapped run explicitly; ResumeLatest
    selects the latest validated source under OutputPath by plan creation time.
    Both reload current inventories/protection, verify original Autopilot IDs
    read-only, and create a fresh Entra-only plan requiring new approval.
    Neither replays Intune/Autopilot DELETEs or runs inactivity classification.
    Original plan, final journal and report are preserved. Re-supply protection
    options; prior command-line settings are not inherited.

    ALWAYS RUN AUDIT MODE FIRST AND REVIEW ALL GENERATED REPORTS BEFORE USING
    A DESTRUCTIVE MODE.

    .PARAMETER DaysInactive
    Number of days of inactivity before a device is considered stale. Minimum
    and default value is 180. A timestamp exactly equal to the cutoff is
    treated as stale (inclusive comparison). Available only in the default
    inactivity parameter set; cannot be combined with -ScrappedDevices,
    -ResumeFromRunPath or -ResumeLatest.

    .PARAMETER Mode
    Audit (default, never deletes), Interactive (requires typing DELETE), or
    Automatic (requires -ConfirmDeletion, no prompt).

    .PARAMETER OutputPath
    Root folder under which a timestamped run folder is created for reports
    and logs. Defaults to .\output relative to the current working directory.
    Also the immediate-subfolder source search root for -ResumeLatest.
    An existing timestamp folder is preserved using a run-ID suffix.

    .PARAMETER TenantId
    Optional tenant id to validate the connected Graph context against.
    Resume defaults to the original source tenant and rejects a mismatch.
    With -ResumeLatest this also filters eligible local source journals.

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
    HTTP 204 is accepted; unexpected HTTP 200 requires exact-ID read-back
    returning 404. Unresolved identities block dependent Entra deletion.
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

    .PARAMETER BatchSize
    Maximum independent operations per JSON batch, from 1 through 20.

    .PARAMETER ResumeFromRunPath
    Resumes remaining Entra targets from a previous scrapped run folder.
    Reads its approved plan, final journal and ScrappedDeviceResults.csv.
    Rechecks current inventory/protection and exact Autopilot IDs read-only.
    Creates a new Entra-only plan requiring fresh approval. Audit is default.
    Pass the original protection options again; they are not inherited.
    Requires DeletionPlan.json, DeletionJournal.jsonl ending in Event=Final,
    and ScrappedDeviceResults.csv with matching original targets/dependencies.
    Only unattempted/blocked Windows Entra targets with original Autopilot
    dependencies qualify. Current management/re-registration, changed or
    ambiguous identifiers, protection and failed read-back block deletion.
    Mutually exclusive with ResumeLatest, ScrappedDevices and DaysInactive.

    .PARAMETER ResumeLatest
    Finds the latest valid scrapped journal with pending Entra targets in
    immediate subfolders of OutputPath. Uses approved plan creation time.
    Requires TenantId if eligible journals belong to multiple tenants.
    All resume checks and fresh approval requirements remain unchanged.
    Invalid/incomplete sources warn and are skipped; no eligible source is
    an error before Graph connection, never fallback to stale cleanup.
    Tied latest timestamps require ResumeFromRunPath. Does not merge sources,
    poll for completion or update old journals with later resume outcomes.
    Each invocation selects anew; use ResumeFromRunPath to pin a reviewed run.

    .PARAMETER VerifyDeletion
    Optional bounded read-back of successful IDs after batch deletion.
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

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest
    Finds the latest eligible source under .\output and previews Entra targets
    in Audit mode. Reads Graph but never submits tenant DELETE requests.

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest -Mode Interactive -OutputPath '.\output\retirement' -TenantId '<tenant-guid>'
    Searches immediate subfolders of the specified root, displays the source,
    rechecks eligibility and requires typing DELETE for the new Entra-only plan.

    .EXAMPLE
    .\Invoke-StaleDeviceCleanup.ps1 -ResumeFromRunPath '.\output\20261028-104650' -Mode Automatic -ConfirmDeletion -WhatIf
    Pins the original source and simulates Entra-only execution without DELETEs.
    Removing WhatIf would allow real deletion without an interactive prompt.

    .NOTES
    Exit codes:
      0 completed successfully
      1 completed with per-device errors
      2 validation or configuration failure
      3 unhandled run error, including authentication or invalid resume source
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

    [Parameter(Mandatory, ParameterSetName = 'Resume')]
    [string]$ResumeFromRunPath,

    [Parameter(Mandatory, ParameterSetName = 'ResumeLatest')]
    [switch]$ResumeLatest,

    [ValidateRange(1, 20)]
    [int]$BatchSize = 20,

    [switch]$VerifyDeletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.3.0'
$requiredModuleVersion = [version]'1.3.0'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'StaleDeviceCleanup.psd1'
# Avoid -Force when the module is already loaded (e.g. under Pester with mocks
# injected into the existing module scope) so mocked commands are preserved.
$loadedModule = Get-Module -Name 'StaleDeviceCleanup'
$newRunSummaryCommand = Get-Command -Name 'New-RunSummary' -ErrorAction SilentlyContinue
$getScrappedSerialsCommand = Get-Command -Name 'Get-ScrappedDeviceSerialNumbers' -ErrorAction SilentlyContinue
$showScrappedSummaryCommand = Get-Command -Name 'Show-ScrappedDeviceSummary' -ErrorAction SilentlyContinue
$showCleanupSummaryCommand = Get-Command -Name 'Show-CleanupSummary' -ErrorAction SilentlyContinue
$batchCommand = Get-Command -Name 'Invoke-DeviceDeletionPlan' -ErrorAction SilentlyContinue
$scrappedResolverCommand = Get-Command -Name 'Resolve-ScrappedDeviceRecords' -ErrorAction SilentlyContinue
$moduleIsCurrent = $loadedModule `
    -and $loadedModule.Version -eq $requiredModuleVersion `
    -and $newRunSummaryCommand `
    -and $newRunSummaryCommand.Parameters.ContainsKey('AllowOnPremisesSyncedDeletion') `
    -and $newRunSummaryCommand.Parameters.ContainsKey('ActionRecords') `
    -and (Get-Command -Name 'Get-CleanupActionRecords' -ErrorAction SilentlyContinue) `
    -and $getScrappedSerialsCommand `
    -and $getScrappedSerialsCommand.Parameters.ContainsKey('Statistics') `
    -and $getScrappedSerialsCommand.Parameters.ContainsKey('AllowLegacyFormat') `
    -and $showScrappedSummaryCommand `
    -and $showScrappedSummaryCommand.Parameters.ContainsKey('CsvDuplicateCount') `
    -and $showScrappedSummaryCommand.Parameters.ContainsKey('Simulation') `
    -and $showCleanupSummaryCommand `
    -and $showCleanupSummaryCommand.Parameters.ContainsKey('Simulation') `
    -and $batchCommand `
    -and $batchCommand.Parameters.ContainsKey('OperationLabels') `
    -and $scrappedResolverCommand `
    -and $scrappedResolverCommand.Parameters.ContainsKey('LogPath') `
    -and (Get-Command -Name 'Get-DeviceDeletionLogLabel' -ErrorAction SilentlyContinue)
if ($PSCmdlet.ParameterSetName -in 'Resume', 'ResumeLatest' -and
    (-not (Get-Command -Name 'Read-DeviceCleanupResumeSource' -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name 'Resolve-DeviceCleanupResumeRecords' -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name 'Get-LatestDeviceCleanupResumeSource' -ErrorAction SilentlyContinue))) {
    $moduleIsCurrent = $false
}
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
$results = @()
$runErrorCount = 0
$cleanupReportsWritten = $false
$scrappedReportWritten = $false
$connectedContext = $null
$resumeSource = $null
$resumeWorkflow = $PSCmdlet.ParameterSetName -in 'Resume', 'ResumeLatest'
$scrappedWorkflow = $PSCmdlet.ParameterSetName -in 'Scrapped', 'Resume', 'ResumeLatest'
if ($PSCmdlet.ParameterSetName -eq 'ResumeLatest' -and -not $ResumeLatest) {
    throw '-ResumeLatest must be explicitly enabled.'
}
if ($scrappedWorkflow -and -not $resumeWorkflow -and -not $ScrappedDevices) {
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

    Test-Prerequisites | Out-Null

    if ($resumeWorkflow) {
        if ($ResumeLatest) {
            $latestSource = Get-LatestDeviceCleanupResumeSource -Path $OutputPath -TenantId $TenantId -LogPath $logPath
            $ResumeFromRunPath = $latestSource.Path
            $resumeSource = $latestSource.Source
        } else {
            $resumeSource = Read-DeviceCleanupResumeSource -Path $ResumeFromRunPath
        }
        if ($TenantId -and $TenantId -ne $resumeSource.Plan.TenantId) {
            throw 'Resume blocked: requested tenant differs from the original approved tenant.'
        }
        $TenantId = $resumeSource.Plan.TenantId
        Write-Host "Journal-based Entra resumption from run $($resumeSource.Plan.RunId), path '$ResumeFromRunPath'. Prior approval is not reused."
        Write-CleanupLog -Message "Event=ResumeStarted SourceRunId=$($resumeSource.Plan.RunId) SourcePlanHash=$($resumeSource.Plan.Hash) SourcePath=$ResumeFromRunPath" -LogPath $logPath
    }

    if (-not $scrappedWorkflow) {
        Write-CleanupLog -Message "Cutoff date (UTC): $($cutoffDateUtc.ToString('o')). Timestamps less than or equal to the cutoff are treated as stale." -Level INFO -LogPath $logPath
    }

    # Audit mode only ever requests read scopes. Destructive modes request read/write.
    $readScopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementServiceConfig.Read.All')
    $writeScopes = @('Directory.AccessAsUser.All')
    # Intune managed-device records are only ever removed via the scrapped-device workflow.
    if ($scrappedWorkflow -and -not $resumeWorkflow) {
        $writeScopes += @('DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All')
    }
    $requestedScopes = if ($Mode -eq 'Audit') { $readScopes } else { $readScopes + $writeScopes }

    $connectedContext = Connect-DeviceCleanupGraph -TenantId $TenantId -Scopes $requestedScopes -LogPath $logPath
    Write-Host "Connected tenant: $($connectedContext.TenantId); authentication: $($connectedContext.AuthType)."

    $permissionCheck = Test-GraphPermissions -RequiredScopes $requestedScopes
    Write-CleanupLog -Message "Granted scopes: $($permissionCheck.GrantedScopes -join ', ')" -Level VERBOSE -LogPath $logPath
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
        Write-CleanupLog -Message "Loaded $($protectedRows.Count) protected device entries." -Level INFO -LogPath $logPath
        Write-CleanupLog -Message "Protected device input: '$ProtectedDeviceIdFile'." -Level VERBOSE -LogPath $logPath
    }

    if ($resumeWorkflow) {
        $scrappedSerialNumbers = @($resumeSource.Records | Select-Object -ExpandProperty InputSerialNumber -Unique)
        $scrappedCsvStatistics = [PSCustomObject]@{ DuplicateRowCount = 0 }
        $ScrappedDeviceCsvPath = Join-Path $ResumeFromRunPath 'ScrappedDeviceResults.csv'
    } elseif ($scrappedWorkflow) {
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
        $discoveryMessage = if ($_.Exception.Data['CleanupErrorLogged']) {
            "Event=DiscoveryIncomplete Service=$discoveryService DeletionBlocked=True; see preceding Graph failure."
        } else { "Global discovery failed: $($_.Exception.Message)" }
        Write-CleanupLog -Message $discoveryMessage -Level ERROR -LogPath $logPath
        $_.Exception.Data['CleanupErrorLogged'] = $true
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

    if ($scrappedWorkflow) {
        Write-CleanupLog -Message "Loaded $($scrappedSerialNumbers.Count) unique scrapped device serial number(s) from '$ScrappedDeviceCsvPath'; ignored $($scrappedCsvStatistics.DuplicateRowCount) duplicate CSV row(s)." -Level INFO -LogPath $logPath
        if ($resumeWorkflow) {
            $scrappedDeviceRecords = @(Resolve-DeviceCleanupResumeRecords -Source $resumeSource -EntraDevices $entraDevices `
                -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices -RunId $runId `
                -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
                -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
                -ProtectedNamePatterns $ProtectedDeviceNamePattern -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion `
                -LogPath $logPath)
        } else {
            $scrappedDeviceRecords = Resolve-ScrappedDeviceRecords -SerialNumbers $scrappedSerialNumbers -EntraDevices $entraDevices `
                -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices -RunId $runId `
                -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
                -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
                -ProtectedNamePatterns $ProtectedDeviceNamePattern -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion `
                -LogPath $logPath
        }
        $scrappedMatchedRecords = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')
        $scrappedMatched = @($scrappedMatchedRecords | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedAmbiguous = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'Ambiguous' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedNotFound = @($scrappedDeviceRecords | Where-Object MatchStatus -eq 'NotFound' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        $scrappedAutopilotTargets = @($scrappedMatchedRecords | Where-Object AutopilotIdentityId | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        $scrappedIntuneTargets = @($scrappedMatchedRecords | Where-Object IntuneManagedDeviceId | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        $scrappedEntraTargets = @($scrappedMatchedRecords | Where-Object EntraObjectId | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        Write-CleanupLog -Message "Scrapped device resolution: InputSerials=$($scrappedSerialNumbers.Count) MatchedSerials=$scrappedMatched AmbiguousSerials=$scrappedAmbiguous NotFoundSerials=$scrappedNotFound; AutopilotTargets=$scrappedAutopilotTargets IntuneTargets=$scrappedIntuneTargets EntraTargets=$scrappedEntraTargets." -Level INFO -LogPath $logPath

        Set-ScrappedDeviceOutcomes -Records $scrappedDeviceRecords
        Write-CleanupLog -Message "Event=ReportExportStarted Report=ScrappedDeviceResults.csv Rows=$($scrappedDeviceRecords.Count)" -LogPath $logPath
        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        $scrappedReportWritten = $true
        Write-CleanupLog -Message 'Event=ReportExportCompleted Report=ScrappedDeviceResults.csv' -LogPath $logPath
        Show-ScrappedDeviceSummary -ScrappedDeviceRecords $scrappedDeviceRecords -OutputPath $resolvedOutputPath `
            -CsvDuplicateCount $scrappedCsvStatistics.DuplicateRowCount -TenantId $connectedContext.TenantId `
            -Mode $Mode -Simulation ([bool]$WhatIfPreference)
        Write-CleanupLog -Message 'Event=DeletionPlanStarted Workflow=Scrapped' -LogPath $logPath
        $deletionPlan = New-DeviceDeletionPlan -TenantId $connectedContext.TenantId -RunId $runId -Workflow Scrapped -Records $scrappedDeviceRecords
        Write-CleanupLog -Message "Event=DeletionPlanCompleted Workflow=Scrapped Operations=$($deletionPlan.Operations.Count)" -LogPath $logPath
        $deletionPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'DeletionPlan.json') -Encoding utf8 -WhatIf:$false
        $approvalHash = $deletionPlan.Hash
        Write-Host "Tenant: $($deletionPlan.TenantId); unique operations: $($deletionPlan.Operations.Count); plan hash: $approvalHash"

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

        $results = @(Invoke-DeviceDeletionPlan -Plan $deletionPlan -ApprovalHash $approvalHash -Mode $Mode `
            -ConfirmDeletion:$confirmationGranted -BatchSize $BatchSize -JournalPath $journalPath -LogPath $logPath `
            -OperationLabels (Get-DeviceDeletionLogLabel -Records $scrappedDeviceRecords) `
            -WhatIf:$WhatIfPreference -Confirm:$false -VerifyDeletion:$VerifyDeletion)
        $scrappedReportWritten = $false
        Set-DeviceDeletionResults -Workflow Scrapped -Records $scrappedDeviceRecords -Results $results

        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        $scrappedReportWritten = $true
        if (@($scrappedDeviceRecords | Where-Object { $_.ErrorMessage }).Count -gt 0 -and $exitCode -eq 0) { $exitCode = 6 }
        return
    }

    $indexes = New-DeviceIndexes -IntuneDevices $intuneDevices -AutopilotDevices $autopilotDevices
    $allEvaluatedDevices = Get-StaleDeviceCandidates -EntraDevices $entraDevices -Indexes $indexes -CutoffDateUtc $cutoffDateUtc `
        -RunId $runId -ProtectedEntraObjectIds $protectedEntraObjectIds -ProtectedEntraDeviceIds $protectedEntraDeviceIds `
        -ProtectedSerialNumbers $protectedSerialNumbers -ProtectedDeviceNames $protectedDeviceNames `
        -ProtectedNamePatterns $ProtectedDeviceNamePattern -IncludeDisabledDevices:$IncludeDisabledDevices `
        -AllowOnPremisesSyncedDeletion:$AllowOnPremisesSyncedDeletion
    if ($null -eq $allEvaluatedDevices) { $allEvaluatedDevices = @() }

    $plannedRemoveCount = @($allEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.EntraAction -eq 'Remove' }).Count
    Write-CleanupLog -Message "Lifecycle actions planned: Entra object(s) to remove=$plannedRemoveCount." -Level INFO -LogPath $logPath

    # Reports must exist before any confirmation prompt, in every mode.
    Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
    $cleanupReportsWritten = $true
    Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
    $scrappedReportWritten = $true

    Show-CleanupSummary -EvaluatedDevices $allEvaluatedDevices -CutoffDateUtc $cutoffDateUtc -DaysInactive $DaysInactive `
        -OutputPath $resolvedOutputPath -TenantId $connectedContext.TenantId -Mode $Mode `
        -Simulation ([bool]$WhatIfPreference)
    $deletionPlan = New-DeviceDeletionPlan -TenantId $connectedContext.TenantId -RunId $runId -Workflow Stale -Records $allEvaluatedDevices
    $deletionPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $resolvedOutputPath 'DeletionPlan.json') -Encoding utf8 -WhatIf:$false
    $approvalHash = $deletionPlan.Hash
    Write-Host "Tenant: $($deletionPlan.TenantId); unique operations: $($deletionPlan.Operations.Count); plan hash: $approvalHash"

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
        $results = @(Invoke-DeviceDeletionPlan -Plan $deletionPlan -ApprovalHash $approvalHash -Mode $Mode `
            -ConfirmDeletion:$confirmationGranted -BatchSize $BatchSize -JournalPath $journalPath -LogPath $logPath `
            -OperationLabels (Get-DeviceDeletionLogLabel -Records $allEvaluatedDevices) `
            -WhatIf:$WhatIfPreference -Confirm:$false -VerifyDeletion:$VerifyDeletion)
        $cleanupReportsWritten = $false
        Set-DeviceDeletionResults -Workflow Stale -Records $allEvaluatedDevices -Results $results
        $deletionErrors = @($results | Where-Object { $_.Status -in 'RemovalFailed', 'OutcomeUnknown', 'BlockedDependency' }).Count

        # Re-write reports so DeletedDevices.csv and status columns reflect the outcome.
        Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
        $cleanupReportsWritten = $true

        if ($deletionErrors -gt 0 -and $exitCode -eq 0) { $exitCode = 6 }
    }

    if ($exitCode -eq 0 -and @($allEvaluatedDevices | Where-Object { $_.ErrorMessage }).Count -gt 0) {
        $exitCode = 1
    }
} catch {
    $runErrorCount++
    if (-not $_.Exception.Data['CleanupErrorLogged']) {
        Write-CleanupLog -Message "Unhandled error: $($_.Exception.Message)" -Level ERROR -LogPath $logPath
    }
    if ($exitCode -eq 0) { $exitCode = 3 }
} finally {
    if ($deletionPlan -and (Test-Path -LiteralPath $journalPath)) {
        $journal = Get-Content -LiteralPath $journalPath -Tail 1 | ConvertFrom-Json
        if ($journal.PlanHash -cne $approvalHash -or $journal.TenantId -ne $deletionPlan.TenantId) {
            throw 'Deletion journal does not match the approved plan.'
        }
        $records = @()
        if ($scrappedWorkflow) { $records = @($scrappedDeviceRecords) }
        else { $records = @($allEvaluatedDevices) }
        $results = @($journal.Results)
        if ($scrappedWorkflow) { $scrappedReportWritten = $false }
        else { $cleanupReportsWritten = $false }
        Set-DeviceDeletionResults -Workflow $deletionPlan.Workflow -Records $records -Results $results
    }
    if (-not $cleanupReportsWritten) {
        Export-CleanupReports -AllEvaluatedDevices $allEvaluatedDevices -OutputPath $resolvedOutputPath
        $cleanupReportsWritten = $true
    }
    if (-not $scrappedReportWritten) {
        Set-ScrappedDeviceOutcomes -Records $scrappedDeviceRecords
        Export-ReportCsv -InputObject $scrappedDeviceRecords -Path (Join-Path $resolvedOutputPath 'ScrappedDeviceResults.csv')
        $scrappedReportWritten = $true
    }
    if ($scrappedWorkflow -and $confirmationGranted -and -not $WhatIfPreference -and $exitCode -eq 0 -and
        @($scrappedDeviceRecords | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.CleanupOutcome -ne 'Complete' }).Count) {
        $exitCode = 6
    }
    $actionSourceRecords = if ($scrappedWorkflow) { @($scrappedDeviceRecords) } else { @($allEvaluatedDevices) }
    $actionRecords = @(Get-CleanupActionRecords -Plan $deletionPlan -Results $results -Records $actionSourceRecords)
    $summaryParameters = if ($scrappedWorkflow) { @{ ScrappedDevices = $true } } else { @{ CutoffDateUtc = $cutoffDateUtc; DaysInactive = $DaysInactive } }
    $runSummary = New-RunSummary @summaryParameters -RunId $runId -Mode $Mode -StartTimeUtc $startTimeUtc `
        -AllEvaluatedDevices $allEvaluatedDevices -WhatIfMode ([bool]$WhatIfPreference) `
        -ScrappedDeviceRecords $scrappedDeviceRecords -AllowOnPremisesSyncedDeletion ([bool]$AllowOnPremisesSyncedDeletion) `
        -ConfirmationGranted $confirmationGranted -DiscoveryComplete $discoveryComplete -ExitCode $exitCode -ActionRecords $actionRecords `
        -TenantId $(if ($connectedContext) { $connectedContext.TenantId } else { $TenantId }) -RunErrorCount $runErrorCount

    if ($resumeWorkflow -and $resumeSource) {
        $runSummary | Add-Member -NotePropertyName SourceRunId -NotePropertyValue $resumeSource.Plan.RunId
        $runSummary | Add-Member -NotePropertyName SourcePlanHash -NotePropertyValue $resumeSource.Plan.Hash
    }

    Complete-ProjectExecution -RunSummary $runSummary -OutputPath $resolvedOutputPath -LogPath $logPath -ActionRecords $actionRecords
}

exit $exitCode
