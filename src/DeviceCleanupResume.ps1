function Get-LatestDeviceCleanupResumeSource {
    <#
        .SYNOPSIS
        Locally selects the newest validated scrapped source with pending Entra targets.
        .DESCRIPTION
        Searches immediate Path subfolders by approved plan creation time, not
        directory modification time. Invalid sources warn and are skipped.
        Tenant ambiguity and tied latest timestamps fail closed. Selection is
        not approval or current eligibility; no Graph calls or tenant writes occur.
        .PARAMETER Path
        Run-folder root, normally the entrypoint OutputPath.
        .PARAMETER TenantId
        Optional exact tenant filter; required to disambiguate multiple tenants.
        .PARAMETER LogPath
        Current run log for skipped sources and selected source evidence.
        .OUTPUTS
        PSCustomObject with Path, Source (validated artifacts) and Created.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TenantId,
        [Parameter(Mandatory)][string]$LogPath
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop) {
        $journalPath = Join-Path $directory.FullName 'DeletionJournal.jsonl'
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { continue }
        try {
            $source = Read-DeviceCleanupResumeSource -Path $directory.FullName
            $created = [datetimeoffset]::Parse($source.Plan.CreatedUtc)
            if ($created -gt [datetimeoffset]::UtcNow) { throw 'Source plan has a future creation time.' }
        } catch {
            Write-CleanupLog -Message "Event=ResumeSourceSkipped SourcePath=$($directory.FullName) Reason=$($_.Exception.Message)" -Level WARNING -LogPath $LogPath
            continue
        }
        if ($TenantId -and $source.Plan.TenantId -ne $TenantId) { continue }
        $pending = @($source.Plan.Operations | Where-Object {
            $_.Resource -eq 'Entra' -and $source.Results[$_.Id].Attempts -eq 0 -and
            $source.Results[$_.Id].Status -in 'BlockedDependency', 'NotAttempted' -and
            @($_.Dependencies | Where-Object { $source.Operations[$_].Resource -eq 'Autopilot' }).Count -gt 0
        })
        if ($pending.Count -eq 0) { continue }
        $candidates.Add([PSCustomObject]@{ Path = $directory.FullName; Source = $source; Created = $created })
    }
    if ($candidates.Count -eq 0) {
        throw "Resume blocked: no valid scrapped journal with pending Entra targets found under '$Path'."
    }
    if (@($candidates | ForEach-Object { $_.Source.Plan.TenantId } | Sort-Object -Unique).Count -gt 1) {
        throw 'Resume blocked: matching journals belong to multiple tenants. Specify -TenantId or -ResumeFromRunPath.'
    }
    $selected = $candidates | Sort-Object Created -Descending | Select-Object -First 1
    if (@($candidates | Where-Object Created -eq $selected.Created).Count -gt 1) {
        throw 'Resume blocked: latest source timestamp is ambiguous. Specify -ResumeFromRunPath.'
    }
    Write-CleanupLog -Message "Event=ResumeSourceSelected SourceRunId=$($selected.Source.Plan.RunId) SourcePath=$($selected.Path) SourcePlanHash=$($selected.Source.Plan.Hash)" -LogPath $LogPath
    return $selected
}

function Read-DeviceCleanupResumeSource {
    <#
        .SYNOPSIS
        Validates an original scrapped plan, final journal and report locally.
        .DESCRIPTION
        Requires matching hash/run/tenant, complete unique results and report
        targets/dependencies reconstructing the plan. Preserves source files.
        A final journal is not proof every removal succeeded. No old approval
        is renewed and no Graph request is made.
        .PARAMETER Path
        Original run folder containing DeletionPlan.json, DeletionJournal.jsonl
        ending in Event=Final, and ScrappedDeviceResults.csv.
        .OUTPUTS
        PSCustomObject with Plan, Results, Records and Operations indexes.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Path)

    $planJson = Get-Content -LiteralPath (Join-Path $Path 'DeletionPlan.json') -Raw -ErrorAction Stop
    $plan = $planJson | ConvertFrom-Json -ErrorAction Stop
    # Preserve the exact timestamp string used in the approved hash on all PowerShell 7 versions.
    $document = [System.Text.Json.JsonDocument]::Parse($planJson)
    try { $plan.CreatedUtc = $document.RootElement.GetProperty('CreatedUtc').GetString() }
    finally { $document.Dispose() }
    $journal = Get-Content -LiteralPath (Join-Path $Path 'DeletionJournal.jsonl') -Tail 1 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $records = @(Import-Csv -LiteralPath (Join-Path $Path 'ScrappedDeviceResults.csv') -ErrorAction Stop)
    if ($plan.Workflow -ne 'Scrapped' -or
        $plan.Hash -cne (Get-DeviceDeletionPlanHash -Plan $plan) -or
        $journal.Event -ne 'Final' -or $journal.PlanHash -cne $plan.Hash -or
        $journal.RunId -ne $plan.RunId -or $journal.TenantId -ne $plan.TenantId) {
        throw 'Resume blocked: source plan and final journal must match a completed scrapped-workflow execution.'
    }
    if (@($records | Where-Object RunId -ne $plan.RunId).Count) {
        throw 'Resume blocked: source report belongs to a different run.'
    }
    $reconstructed = New-DeviceDeletionPlan -TenantId $plan.TenantId -RunId $plan.RunId -Workflow Scrapped -Records $records
    if (($reconstructed.Operations | ConvertTo-Json -Depth 20 -Compress) -cne
        ($plan.Operations | ConvertTo-Json -Depth 20 -Compress)) {
        throw 'Resume blocked: source report targets or dependencies differ from the approved plan.'
    }
    $byId = @{}
    foreach ($operation in $plan.Operations) { $byId[$operation.Id] = $operation }
    $results = @{}
    foreach ($result in $journal.Results) {
        if (-not $byId.ContainsKey($result.Id) -or $results.ContainsKey($result.Id) -or
            $result.Resource -ne $byId[$result.Id].Resource -or $result.ObjectId -ne $byId[$result.Id].ObjectId) {
            throw 'Resume blocked: invalid or duplicate source journal result.'
        }
        $results[$result.Id] = $result
    }
    if ($results.Count -ne $byId.Count) { throw 'Resume blocked: source journal results are incomplete.' }
    return [PSCustomObject]@{ Plan = $plan; Results = $results; Records = $records; Operations = $byId }
}

function Resolve-DeviceCleanupResumeRecords {
    <#
        .SYNOPSIS
        Revalidates original Entra targets for a new Entra-only retirement plan.
        .DESCRIPTION
        Uses a validated source and complete fresh inventories. Rechecks unique
        original object/device IDs, Windows client scope, current management,
        serial re-registration, explicit protection and default sync protection.
        Requires successful original Intune prerequisites and exact-ID Autopilot
        GET absence (404) after a recorded HTTP 200/204 DELETE attempt.
        Shared read-back checks are cached; visible/failed reads fail closed.
        Emits report rows, not deletion commands. Previously attempted Entra
        operations are not resumed. No inactivity threshold is evaluated.
        .PARAMETER Source
        Validated output from Read-DeviceCleanupResumeSource.
        .PARAMETER RunId
        New run ID; original evidence is retained in Source-prefixed fields.
        .PARAMETER LogPath
        Current run log for target eligibility and Autopilot read-back outcomes.
        .OUTPUTS
        Report rows for New-DeviceDeletionPlan with Workflow Scrapped. Matched
        rows contain only Entra deletion targets; exclusions retain source IDs.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Source,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntraDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$IntuneDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AutopilotDevices,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$ProtectedEntraObjectIds = @(),
        [string[]]$ProtectedEntraDeviceIds = @(),
        [string[]]$ProtectedSerialNumbers = @(),
        [string[]]$ProtectedDeviceNames = @(),
        [string[]]$ProtectedNamePatterns = @(),
        [switch]$AllowOnPremisesSyncedDeletion,
        [Parameter(Mandatory)][string]$LogPath
    )

    Assert-DeviceCleanupContext -TenantId $Source.Plan.TenantId
    $byObjectId = @{}
    $byDeviceId = @{}
    foreach ($device in $EntraDevices) {
        if ($device.Id) {
            if (-not $byObjectId.ContainsKey([string]$device.Id)) { $byObjectId[[string]$device.Id] = [System.Collections.Generic.List[object]]::new() }
            $byObjectId[[string]$device.Id].Add($device)
        }
        if ($device.DeviceId) {
            $key = [string]$device.DeviceId
            if (-not $byDeviceId.ContainsKey($key)) { $byDeviceId[$key] = [System.Collections.Generic.List[object]]::new() }
            $byDeviceId[$key].Add($device)
        }
    }
    $indexes = New-DeviceIndexes -IntuneDevices $IntuneDevices -AutopilotDevices $AutopilotDevices
    $protectionIndex = New-DeviceProtectionIndex -ProtectedEntraObjectIds $ProtectedEntraObjectIds `
        -ProtectedEntraDeviceIds $ProtectedEntraDeviceIds -ProtectedSerialNumbers $ProtectedSerialNumbers `
        -ProtectedDeviceNames $ProtectedDeviceNames -ProtectedNamePatterns $ProtectedNamePatterns
    $sourceRows = @{}
    foreach ($row in $Source.Records) {
        if (-not $row.EntraObjectId) { continue }
        if (-not $sourceRows.ContainsKey($row.EntraObjectId)) { $sourceRows[$row.EntraObjectId] = [System.Collections.Generic.List[object]]::new() }
        $sourceRows[$row.EntraObjectId].Add($row)
    }
    $verificationById = @{}
    $currentSerials = @{}
    foreach ($managedDevice in $IntuneDevices) {
        $serialKey = ConvertTo-NormalizedSerialNumber -SerialNumber $managedDevice.SerialNumber
        if ($serialKey) { $currentSerials[$serialKey] = $true }
    }
    foreach ($autopilotDevice in $AutopilotDevices) {
        $serialKey = ConvertTo-NormalizedSerialNumber -SerialNumber $autopilotDevice.SerialNumber
        if ($serialKey) { $currentSerials[$serialKey] = $true }
    }
    foreach ($operation in $Source.Plan.Operations) {
        if ($operation.Resource -ne 'Entra' -or $Source.Results[$operation.Id].Attempts -ne 0 -or
            $Source.Results[$operation.Id].Status -notin 'BlockedDependency', 'NotAttempted') { continue }
        $rows = $sourceRows[$operation.ObjectId]
        $serial = [string]$rows[0].InputSerialNumber
        $autopilotDependencies = @($operation.Dependencies | Where-Object { $Source.Operations[$_].Resource -eq 'Autopilot' })
        $record = [PSCustomObject][ordered]@{
            RunId = $RunId; InputSerialNumber = $serial
            NormalizedSerialNumber = ConvertTo-NormalizedSerialNumber -SerialNumber $serial
            MatchStatus = 'Excluded'; AmbiguityReason = ''
            AutopilotIdentityId = $null; AutopilotEnrollmentState = $null
            IntuneManagedDeviceId = $null; IntuneDeviceName = $null
            EntraObjectId = $null; EntraDeviceName = $null; EntraDeviceId = $null
            AutopilotRemovalStatus = 'NotAttempted'; IntuneRemovalStatus = 'NotAttempted'
            EntraRemovalStatus = 'NotAttempted'; ErrorMessage = $null
            CorrelationMethod = 'PriorApprovedEntraObjectId'
            SourceRunId = $Source.Plan.RunId; SourcePlanHash = $Source.Plan.Hash
            SourceEntraObjectId = $operation.ObjectId
            SourceAutopilotIdentityIds = ($autopilotDependencies | ForEach-Object { $Source.Operations[$_].ObjectId }) -join ';'
        }
        $reason = $null
        if (-not $byObjectId.ContainsKey($operation.ObjectId)) {
            $record.MatchStatus = 'NotFound'
            $reason = 'EntraAlreadyAbsent'
        } elseif ($byObjectId[$operation.ObjectId].Count -ne 1) {
            $reason = 'AmbiguousEntraObjectId'
        } else {
            $device = $byObjectId[$operation.ObjectId][0]
            $platform = Resolve-DevicePlatform -OperatingSystem $device.OperatingSystem
            if ($autopilotDependencies.Count -eq 0) { $reason = 'NoOriginalAutopilotDependency' }
            elseif ($platform -ne 'Windows') { $reason = 'UnsupportedOrMissingPlatform' }
            elseif (-not $device.DeviceId -or $device.DeviceId -eq [guid]::Empty.ToString() -or
                $byDeviceId[[string]$device.DeviceId].Count -ne 1 -or
                @($rows | Where-Object { -not $_.EntraDeviceId -or $_.EntraDeviceId -ne $device.DeviceId }).Count) {
                $reason = 'ConflictingIdentifiers'
            } elseif ($device.OnPremisesSyncEnabled -and -not $AllowOnPremisesSyncedDeletion) {
                $reason = 'OnPremisesSyncProtected'
            } else {
                $correlation = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $indexes -Platform $platform
                if ($correlation.MatchStatus -ne 'Unmatched') { $reason = 'CurrentManagementOrAmbiguousCorrelation' }
            }
            foreach ($row in $rows) {
                $serialKey = ConvertTo-NormalizedSerialNumber -SerialNumber $row.InputSerialNumber
                if (-not $serialKey) { $reason = 'InvalidSerialNumber' }
                elseif ($currentSerials.ContainsKey($serialKey)) { $reason = 'CurrentManagementOrAmbiguousCorrelation' }
                $protection = Test-DeviceProtection -Device $device -IntuneSerialNumber $row.InputSerialNumber -ProtectionIndex $protectionIndex
                if ($protection.IsProtected) { $reason = 'ProtectedDevice' }
            }
            if (-not $reason) {
                foreach ($dependencyId in $operation.Dependencies) {
                    $dependency = $Source.Operations[$dependencyId]
                    $priorResult = $Source.Results[$dependencyId]
                    if ($dependency.Resource -eq 'Intune') {
                        if ($priorResult.Status -notin 'Removed', 'AlreadyRemoved', 'AlreadyAbsent') { $reason = 'IntunePrerequisiteUnresolved' }
                    } elseif ($dependency.Resource -eq 'Autopilot') {
                        if ($priorResult.HttpStatus -notin 200, 204 -or $priorResult.Attempts -lt 1) {
                            $reason = 'AutopilotPrerequisiteUnresolved'
                        } else {
                            if (-not $verificationById.ContainsKey($dependencyId)) {
                                $verificationById[$dependencyId] = Test-DeviceDeletionOutcome -Operation $dependency `
                                    -TenantId $Source.Plan.TenantId -MaxAttempts 1 -LogPath $LogPath
                                Write-CleanupLog -Message "Event=ResumeAutopilotVerification SourceRunId=$($Source.Plan.RunId) AutopilotIdentityId=$($dependency.ObjectId) Outcome=$($verificationById[$dependencyId].Status)" -LogPath $LogPath
                            }
                            $verification = $verificationById[$dependencyId]
                            if ($verification.Status -ne 'VerifiedAbsent') {
                                $reason = 'AutopilotAbsenceNotVerified'
                                $record.ErrorMessage = $verification.ErrorMessage
                            }
                        }
                    } else { throw 'Resume blocked: unexpected source dependency resource.' }
                }
            }
            if (-not $reason) {
                $record.MatchStatus = 'Matched'
                $record.EntraObjectId = $device.Id
                $record.EntraDeviceId = $device.DeviceId
                $record.EntraDeviceName = $device.DisplayName
            }
        }
        if ($reason) { $record.AmbiguityReason = $reason }
        Write-CleanupLog -Message "Event=ResumeTarget SourceRunId=$($Source.Plan.RunId) EntraObjectId=$($operation.ObjectId) MatchStatus=$($record.MatchStatus) Reason=$reason" -LogPath $LogPath
        $record
    }
}
