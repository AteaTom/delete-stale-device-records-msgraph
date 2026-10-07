function Get-DeviceDeletionPlanHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Plan)

    $content = [ordered]@{
        RunId = $Plan.RunId
        TenantId = $Plan.TenantId
        CreatedUtc = $Plan.CreatedUtc
        Workflow = $Plan.Workflow
        Operations = @($Plan.Operations)
    } | ConvertTo-Json -Depth 20 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function New-DeviceDeletionPlan {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('Stale', 'Scrapped')][string]$Workflow,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $operations = @{}
    foreach ($record in $Records) {
        $targets = @()
        if ($Workflow -eq 'Stale') {
            if ($record.Decision -eq 'Candidate' -and $record.EntraAction -eq 'Remove' -and -not $record.AutopilotPresent) {
                $targets = @([PSCustomObject]@{ Resource = 'Entra'; ObjectId = $record.EntraObjectId })
            }
        } elseif ($record.MatchStatus -eq 'Matched') {
            if ($record.IntuneManagedDeviceId) {
                $targets += [PSCustomObject]@{ Resource = 'Intune'; ObjectId = $record.IntuneManagedDeviceId }
            }
            if ($record.AutopilotIdentityId) {
                $targets += [PSCustomObject]@{ Resource = 'Autopilot'; ObjectId = $record.AutopilotIdentityId }
            }
        }
        foreach ($target in $targets) {
            if ([string]$target.ObjectId -notmatch '^[A-Za-z0-9-]+$') {
                throw "Invalid $($target.Resource) object ID in deletion plan."
            }
            $key = "$($target.Resource)-$($target.ObjectId)".ToLowerInvariant()
            if (-not $operations.ContainsKey($key)) {
                $operations[$key] = [PSCustomObject][ordered]@{
                    Id = $key
                    Resource = $target.Resource
                    ObjectId = [string]$target.ObjectId
                    Dependencies = @()
                }
            }
            if ($target.Resource -eq 'Autopilot') {
                $intuneIds = @($Records | Where-Object {
                    $_.MatchStatus -eq 'Matched' -and $_.NormalizedSerialNumber -eq $record.NormalizedSerialNumber -and $_.IntuneManagedDeviceId
                } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique)
                $operations[$key].Dependencies = @(
                    @($operations[$key].Dependencies) + @($intuneIds | ForEach-Object { "intune-$_".ToLowerInvariant() }) |
                        Sort-Object -Unique
                )
            }
        }
    }
    $plan = [PSCustomObject][ordered]@{
        RunId = $RunId
        TenantId = $TenantId
        CreatedUtc = [datetime]::UtcNow.ToString('o')
        Workflow = $Workflow
        Operations = @($operations.Values | Sort-Object Id)
        Hash = ''
    }
    $plan.Hash = Get-DeviceDeletionPlanHash -Plan $plan
    return $plan
}

function Get-DeviceOperationUri {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$Operation)

    if ([string]$Operation.ObjectId -notmatch '^[A-Za-z0-9-]+$') { throw 'Invalid object ID in operation.' }
    switch ($Operation.Resource) {
        'Entra' { return "/devices/$($Operation.ObjectId)" }
        'Intune' { return "/deviceManagement/managedDevices/$($Operation.ObjectId)" }
        'Autopilot' { return "/deviceManagement/windowsAutopilotDeviceIdentities/$($Operation.ObjectId)" }
        default { throw "Unsupported deletion resource '$($Operation.Resource)'." }
    }
}

function Assert-DeviceDeletionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [Parameter(Mandatory)][object[]]$Operations
    )

    $scopes = @{
        Entra = 'Directory.AccessAsUser.All'
        Intune = 'DeviceManagementManagedDevices.ReadWrite.All'
        Autopilot = 'DeviceManagementServiceConfig.ReadWrite.All'
    }
    Assert-DeviceCleanupContext -TenantId $Plan.TenantId -RequiredScopes @($Operations | ForEach-Object { $scopes[$_.Resource] })
}

function Assert-DeviceCleanupContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [AllowEmptyCollection()][string[]]$RequiredScopes = @()
    )
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $TenantId -or $context.AuthType -ne 'Delegated') {
        throw 'Deletion blocked: Graph tenant or delegated authentication differs from the approved plan.'
    }
    if ($context.PSObject.Properties['Environment'] -and $context.Environment -ne 'Global') {
        throw 'Deletion is validated only for the public Microsoft Graph cloud.'
    }
    foreach ($scope in $RequiredScopes) {
        if (@($context.Scopes) -notcontains $scope) {
            throw "Deletion blocked: missing scope '$scope'."
        }
    }
}

function ConvertFrom-DeviceDeletionBatchResponse {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][object]$Response,
        [Parameter(Mandatory)][object[]]$Operations
    )

    $entries = @()
    if ($Response.PSObject.Properties['responses']) { $entries = @($Response.responses) }
    $expected = @{}
    foreach ($operation in $Operations) { $expected[$operation.Id] = $operation }
    $unexpected = @($entries | Where-Object {
        -not $_ -or -not $_.PSObject.Properties['id'] -or -not $expected.ContainsKey([string]$_.id)
    }).Count -gt 0
    foreach ($operation in $Operations) {
        $matchingEntries = @($entries | Where-Object { $_ -and $_.PSObject.Properties['id'] -and $_.id -eq $operation.Id })
        $status = 'OutcomeUnknown'
        $httpStatus = 0
        $message = 'Missing, duplicate, unexpected, or malformed batch response.'
        $retryAfter = 0.0
        if (-not $unexpected -and $matchingEntries.Count -eq 1 -and $matchingEntries[0].PSObject.Properties['status']) {
            $entry = $matchingEntries[0]
            $parsedStatus = 0
            if ([int]::TryParse([string]$entry.status, [ref]$parsedStatus)) { $httpStatus = $parsedStatus }
            $message = ''
            if ($entry.PSObject.Properties['body'] -and $entry.body) {
                $message = $entry.body | ConvertTo-Json -Depth 10 -Compress
            }
            if ($httpStatus -eq 204 -and $message) {
                $message = "DELETE response contains an unexpected body: $message"
            } elseif ($httpStatus -eq 204) {
                $status = if ($operation.Resource -eq 'Autopilot') { 'RemovalSubmitted' } else { 'Removed' }
            } elseif ($httpStatus -eq 404 -and $operation.Resource -eq 'Entra') {
                $status = 'AlreadyAbsent'
                $message = ''
            } elseif ($httpStatus -in 429, 503, 504) {
                $status = 'RetryPending'
            } elseif ($httpStatus -ge 400 -and $httpStatus -le 599) {
                $status = 'RemovalFailed'
            } else {
                $message = "Unexpected HTTP status '$httpStatus'; outcome is not established."
            }
            if (($status -in 'RemovalFailed', 'RetryPending') -and -not $message) {
                $message = "Graph DELETE returned HTTP $httpStatus."
            }
            if ($entry.PSObject.Properties['headers'] -and $entry.headers) {
                $headerValue = $null
                if ($entry.headers -is [System.Collections.IDictionary]) {
                    $headerValue = $entry.headers['Retry-After']
                } else {
                    $header = $entry.headers.PSObject.Properties |
                        Where-Object Name -eq 'Retry-After' | Select-Object -First 1
                    if ($header) { $headerValue = $header.Value }
                }
                if ($null -ne $headerValue) {
                    $seconds = 0.0
                    $date = [datetimeoffset]::MinValue
                    if ([double]::TryParse([string]$headerValue, [ref]$seconds) -and $seconds -ge 0) {
                        $retryAfter = $seconds
                    } elseif ([datetimeoffset]::TryParse([string]$headerValue, [ref]$date)) {
                        $retryAfter = [Math]::Max(0, ($date - [datetimeoffset]::UtcNow).TotalSeconds)
                    }
                }
            }
        }
        [PSCustomObject]@{
            Id = $operation.Id
            Resource = $operation.Resource
            ObjectId = $operation.ObjectId
            Status = $status
            HttpStatus = $httpStatus
            ErrorMessage = $message
            RetryAfterSeconds = $retryAfter
            Attempts = 0
            VerificationStatus = 'NotRequested'
        }
    }
}

function Invoke-DeviceDeletionPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [Parameter(Mandatory)][string]$ApprovalHash,
        [ValidateSet('Audit', 'Interactive', 'Automatic')][string]$Mode = 'Audit',
        [switch]$ConfirmDeletion,
        [ValidateRange(1, 20)][int]$BatchSize = 20,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [ValidateRange(1, 3600)][int]$RetryBudgetSeconds = 300,
        [ValidateRange(1, 1440)][int]$MaxPlanAgeMinutes = 30,
        [switch]$VerifyDeletion,
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$LogPath
    )

    # Deep-copy before approval validation; later caller mutation cannot expand this execution.
    $snapshot = [PSCustomObject][ordered]@{
        RunId = [string]$Plan.RunId
        TenantId = [string]$Plan.TenantId
        CreatedUtc = [string]$Plan.CreatedUtc
        Workflow = [string]$Plan.Workflow
        Operations = @($Plan.Operations | ForEach-Object {
            [PSCustomObject][ordered]@{
                Id = [string]$_.Id; Resource = [string]$_.Resource; ObjectId = [string]$_.ObjectId
                Dependencies = @($_.Dependencies | ForEach-Object { [string]$_ })
            }
        })
        Hash = [string]$Plan.Hash
    }
    if ($snapshot.Hash -cne $ApprovalHash -or (Get-DeviceDeletionPlanHash -Plan $snapshot) -cne $ApprovalHash) {
        throw 'Deletion blocked: the approved plan hash does not match its contents.'
    }
    $created = [datetimeoffset]::Parse($snapshot.CreatedUtc)
    if ($created -gt [datetimeoffset]::UtcNow -or ([datetimeoffset]::UtcNow - $created).TotalMinutes -gt $MaxPlanAgeMinutes) {
        throw 'Deletion blocked: plan is expired or has a future creation time.'
    }
    $operations = @($snapshot.Operations)
    $byId = @{}
    foreach ($operation in $operations) {
        Get-DeviceOperationUri -Operation $operation | Out-Null
        if ($operation.Id -ne "$($operation.Resource)-$($operation.ObjectId)".ToLowerInvariant() -or $byId.ContainsKey($operation.Id)) {
            throw 'Deletion blocked: invalid or duplicate operation ID.'
        }
        if (($snapshot.Workflow -eq 'Stale' -and $operation.Resource -ne 'Entra') -or
            ($snapshot.Workflow -eq 'Scrapped' -and $operation.Resource -eq 'Entra') -or
            $snapshot.Workflow -notin 'Stale', 'Scrapped') {
            throw 'Deletion blocked: operation violates the workflow policy.'
        }
        $byId[$operation.Id] = $operation
    }
    foreach ($operation in $operations) {
        foreach ($dependency in $operation.Dependencies) {
            if (-not $byId.ContainsKey($dependency) -or $operation.Resource -ne 'Autopilot' -or $byId[$dependency].Resource -ne 'Intune') {
                throw 'Deletion blocked: invalid prerequisite in plan.'
            }
        }
    }
    $results = @{}
    foreach ($operation in $operations) {
        $results[$operation.Id] = [PSCustomObject]@{
            Id = $operation.Id; Resource = $operation.Resource; ObjectId = $operation.ObjectId
            Status = 'NotAttempted'; HttpStatus = 0; ErrorMessage = ''; RetryAfterSeconds = 0; Attempts = 0
            VerificationStatus = 'NotRequested'
        }
    }
    if ($Mode -eq 'Audit' -or -not $ConfirmDeletion) {
        Write-CleanupLog -Message 'No destructive batch submitted: Audit mode or explicit approval absent.' -Level INFO -LogPath $LogPath
        return @($operations | ForEach-Object { $results[$_.Id] })
    }
    $JournalPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JournalPath)
    if (Test-Path -LiteralPath $JournalPath) {
        throw 'Deletion blocked: journal already exists. Reconcile the earlier run rather than replaying a plan.'
    }
    $journalFile = [System.IO.File]::Open($JournalPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $journalFile.Dispose()
    $saveJournal = {
        param([string]$EventName, [object[]]$Submitted = @())
        [PSCustomObject]@{
            TimestampUtc = [datetime]::UtcNow.ToString('o')
            RunId = $snapshot.RunId; TenantId = $snapshot.TenantId; PlanHash = $ApprovalHash
            Event = $EventName; SubmittedIds = @($Submitted | ForEach-Object Id)
            Results = @($operations | ForEach-Object { $results[$_.Id] })
        } | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $JournalPath -Encoding utf8 -ErrorAction Stop -WhatIf:$false
    }
    & $saveJournal 'Approved'
    try {
        foreach ($phase in 'Intune', 'Autopilot', 'Entra') {
            $pending = [System.Collections.Generic.List[object]]::new()
            foreach ($operation in @($operations | Where-Object Resource -eq $phase)) {
                $blocked = @($operation.Dependencies | Where-Object {
                    $results[$_].Status -ne 'Removed' -and -not ($WhatIfPreference -and $results[$_].Status -eq 'WhatIf')
                }).Count -gt 0
                if ($blocked) {
                    $results[$operation.Id].Status = 'BlockedDependency'
                    $results[$operation.Id].ErrorMessage = 'Required Intune removal did not succeed.'
                } elseif ($PSCmdlet.ShouldProcess("Tenant $($snapshot.TenantId): $phase/$($operation.ObjectId)", 'Delete approved device record')) {
                    $pending.Add($operation)
                } else {
                    $results[$operation.Id].Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
                }
            }
            while ($pending.Count -gt 0) {
                $chunk = @($pending | Select-Object -First $BatchSize)
                $pending.RemoveRange(0, $chunk.Count)
                $retry = @($chunk)
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                while ($retry.Count -gt 0) {
                    if ($results[$retry[0].Id].Attempts -gt 0 -and $timer.Elapsed.TotalSeconds -ge $RetryBudgetSeconds) {
                        foreach ($operation in $retry) {
                            $results[$operation.Id].Status = 'RemovalFailed'
                            $results[$operation.Id].ErrorMessage = 'Transient retry budget exhausted.'
                        }
                        break
                    }
                    Assert-DeviceDeletionContext -Plan $snapshot -Operations $retry
                    if (([datetimeoffset]::UtcNow - $created).TotalMinutes -gt $MaxPlanAgeMinutes) {
                        throw 'Deletion blocked: plan expired during execution.'
                    }
                    foreach ($operation in $retry) {
                        $results[$operation.Id].Status = 'OutcomeUnknown'
                        $results[$operation.Id].Attempts++
                    }
                    & $saveJournal 'Submitting' $retry
                    $requests = @($retry | ForEach-Object {
                        @{ id = $_.Id; method = 'DELETE'; url = Get-DeviceOperationUri -Operation $_ }
                    })
                    $body = @{ requests = $requests } | ConvertTo-Json -Depth 10 -Compress
                    $restoreError = ''
                    try {
                        $previousMaxRetry = [int](Get-MgRequestContext).MaxRetry
                        try {
                            # SDK envelope retries can replay already-completed subrequests.
                            Set-MgRequestContext -MaxRetry 0 -Confirm:$false -ErrorAction Stop | Out-Null
                            # Relative routes avoid SDK absolute-URI environment mutation.
                            $response = Invoke-MgGraphRequest -Method POST -Uri '/v1.0/$batch' `
                                -Body $body -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
                        } finally {
                            try {
                                Set-MgRequestContext -MaxRetry $previousMaxRetry -Confirm:$false -ErrorAction Stop | Out-Null
                            } catch {
                                $restoreError = Get-GraphErrorMessage -ErrorRecord $_
                            }
                        }
                    } catch {
                        $message = Get-GraphErrorMessage -ErrorRecord $_
                        if ($restoreError) { $message += " SDK retry restoration also failed: $restoreError" }
                        foreach ($operation in $retry) {
                            $results[$operation.Id].ErrorMessage = "Envelope outcome unknown: $message"
                        }
                        & $saveJournal 'EnvelopeFailed'
                        throw "Batch response unavailable: $message Reconcile the journal read-only; no envelope was replayed."
                    }
                    $parsed = @(ConvertFrom-DeviceDeletionBatchResponse -Response $response -Operations $retry)
                    foreach ($result in $parsed) {
                        $result.Attempts = $results[$result.Id].Attempts
                        $results[$result.Id] = $result
                        if ($result.Status -notin 'Removed', 'RemovalSubmitted', 'AlreadyAbsent') {
                            Write-CleanupLog -Message "Batch operation '$($result.Id)': $($result.Status), HTTP $($result.HttpStatus). $($result.ErrorMessage)" -Level WARNING -LogPath $LogPath
                        }
                    }
                    & $saveJournal 'Response'
                    if ($restoreError) {
                        throw "SDK retry restoration failed: $restoreError Received batch outcomes were journaled; remaining execution stopped."
                    }
                    if (@($parsed | Where-Object { $_.HttpStatus -in 401, 403 -or $_.Status -eq 'OutcomeUnknown' }).Count -gt 0) {
                        throw 'Batch authorization or response integrity failure; remaining execution stopped.'
                    }
                    $retry = @($retry | Where-Object { $results[$_.Id].Status -eq 'RetryPending' })
                    if ($retry.Count -gt 0) {
                        $attempt = ($retry | ForEach-Object { $results[$_.Id].Attempts } | Measure-Object -Maximum).Maximum
                        $delay = [Math]::Max(
                            ($retry | ForEach-Object { $results[$_.Id].RetryAfterSeconds } | Measure-Object -Maximum).Maximum,
                            [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0)
                        if ($attempt -ge $MaxAttempts -or $timer.Elapsed.TotalSeconds + $delay -gt $RetryBudgetSeconds) {
                            foreach ($operation in $retry) {
                                $results[$operation.Id].Status = 'RemovalFailed'
                                $results[$operation.Id].ErrorMessage = 'Transient retry budget exhausted.'
                            }
                            $retry = @()
                        } else {
                            Start-Sleep -Seconds $delay
                        }
                    }
                }
                & $saveJournal 'ChunkCompleted'
            }
            & $saveJournal 'PhaseCompleted'
        }
        if ($VerifyDeletion -and -not $WhatIfPreference) {
            foreach ($operation in $operations) {
                $result = $results[$operation.Id]
                if ($result.Status -in 'Removed', 'RemovalSubmitted', 'AlreadyAbsent') {
                    $verification = Test-DeviceDeletionOutcome -Operation $operation -TenantId $snapshot.TenantId -LogPath $LogPath
                    $result.VerificationStatus = $verification.Status
                    if ($verification.ErrorMessage) { $result.ErrorMessage = $verification.ErrorMessage }
                    & $saveJournal 'Verification'
                }
            }
        }
    } catch {
        Write-CleanupLog -Message $_.Exception.Message -Level ERROR -LogPath $LogPath
        throw
    } finally {
        foreach ($result in $results.Values) {
            if ($result.Status -eq 'RetryPending') {
                $result.Status = 'RemovalFailed'
                $result.ErrorMessage = 'Execution stopped before transient retry completed.'
            }
        }
        & $saveJournal 'Final'
    }
    return @($operations | ForEach-Object { $results[$_.Id] })
}

function Test-DeviceDeletionOutcome {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Operation,
        [Parameter(Mandatory)][string]$TenantId,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3,
        [Parameter(Mandatory)][string]$LogPath
    )

    $uri = '/v1.0' + (Get-DeviceOperationUri -Operation $Operation)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $context = Get-MgContext
        if (-not $context -or $context.TenantId -ne $TenantId -or $context.AuthType -ne 'Delegated' -or
            ($context.PSObject.Properties['Environment'] -and $context.Environment -ne 'Global')) {
            throw 'Verification blocked: Graph context differs from the approved tenant/environment.'
        }
        $response = $null
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType HttpResponseMessage -SkipHttpErrorCheck -ErrorAction Stop
            if ([int]$response.StatusCode -eq 404) {
                return [PSCustomObject]@{ Status = 'VerifiedAbsent'; ErrorMessage = '' }
            }
            if ([int]$response.StatusCode -ne 200) {
                throw "Read-back returned HTTP $([int]$response.StatusCode); absence is not established."
            }
        } catch {
            Write-CleanupLog -Message "Verification for '$($Operation.Id)' failed: $($_.Exception.Message)" -Level WARNING -LogPath $LogPath
            return [PSCustomObject]@{ Status = 'OutcomeUnknown'; ErrorMessage = $_.Exception.Message }
        } finally {
            if ($response -is [System.IDisposable]) { $response.Dispose() }
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
    }
    Write-CleanupLog -Message "Verification pending for '$($Operation.Id)': record still visible." -Level WARNING -LogPath $LogPath
    return [PSCustomObject]@{ Status = 'VerificationPending'; ErrorMessage = 'Record still visible after bounded read-back.' }
}

function Set-DeviceDeletionResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Stale', 'Scrapped')][string]$Workflow,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results
    )

    $byId = @{}
    foreach ($result in $Results) { $byId[$result.Id] = $result }
    foreach ($record in $Records) {
        if ($Workflow -eq 'Scrapped' -and $record.EntraObjectId) { $record.EntraRemovalStatus = 'ManualReview' }
        $fields = if ($Workflow -eq 'Stale') {
            @(@{ Resource = 'Entra'; IdField = 'EntraObjectId'; StatusField = 'EntraRemovalStatus' })
        } else {
            @(@{ Resource = 'Intune'; IdField = 'IntuneManagedDeviceId'; StatusField = 'IntuneRemovalStatus' },
                @{ Resource = 'Autopilot'; IdField = 'AutopilotIdentityId'; StatusField = 'AutopilotRemovalStatus' })
        }
        foreach ($field in $fields) {
            $record | Add-Member -NotePropertyName "$($field.Resource)VerificationStatus" -NotePropertyValue 'NotRequested' -Force
            $key = "$($field.Resource)-$($record.($field.IdField))".ToLowerInvariant()
            if ($byId.ContainsKey($key)) {
                $result = $byId[$key]
                $record.($field.StatusField) = $result.Status
                $record | Add-Member -NotePropertyName "$($field.Resource)VerificationStatus" -NotePropertyValue $result.VerificationStatus -Force
                if ($result.ErrorMessage) { $record.ErrorMessage = $result.ErrorMessage }
            }
        }
    }
}
