#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    StaleDeviceCleanup.psm1

    Core functions supporting Invoke-StaleDeviceCleanup.ps1.
    Discovery, correlation, activity evaluation, protection, reporting, and
    (guarded) deletion logic for Microsoft Entra ID / Intune / Windows Autopilot
    stale device records.

    SAFETY NOTE: No function in this module performs a destructive Graph call
    without first evaluating ShouldProcess. Discovery functions never delete.
#>

$script:RequiredGraphModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.DeviceManagement',
    'Microsoft.Graph.DeviceManagement.Enrollment'
)

$script:InvalidSerialNumbers = @(
    '0', 'unknown', 'default string', 'system serial number',
    'to be filled by o.e.m.', 'n/a', 'none', ''
)

. (Join-Path $PSScriptRoot 'DeviceDeletionBatch.ps1')

#region Logging

function Write-CleanupLog {
    <#
        .SYNOPSIS
        Writes a structured, timestamped line to the execution log and to the
        appropriate PowerShell stream. Never logs secrets or tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'SUCCESS')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$LogPath
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    } catch {
        Write-Warning "Failed to write to log file '$LogPath': $($_.Exception.Message)"
    }

    switch ($Level) {
        'ERROR' { Write-Warning $Message }
        'WARNING' { Write-Warning $Message }
        'SUCCESS' { Write-Verbose $Message }
        default { Write-Verbose $Message }
    }
}

#endregion Logging

#region Prerequisites and connection

function Test-Prerequisites {
    <#
        .SYNOPSIS
        Verifies that the required Microsoft Graph PowerShell modules are installed.
        Does not install anything automatically.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$RequiredModules = $script:RequiredGraphModules
    )

    $missing = @()
    foreach ($moduleName in $RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            $missing += $moduleName
        }
    }

    if ($missing.Count -gt 0) {
        $installCommand = "Install-Module -Name $($missing -join ',') -Scope CurrentUser"
        throw "Missing required Microsoft Graph PowerShell module(s): $($missing -join ', '). Install with: $installCommand"
    }

    return $true
}

function Connect-DeviceCleanupGraph {
    <#
        .SYNOPSIS
        Establishes a delegated Microsoft Graph connection using Connect-MgGraph.
        Never stores or logs credentials or tokens.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][string]$LogPath
    )

    $connectParams = @{
        Scopes    = $Scopes
        NoWelcome = $true
    }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }

    Write-CleanupLog -Message "Connecting to Microsoft Graph (requested scopes: $($Scopes -join ', '))." -Level INFO -LogPath $LogPath
    Connect-MgGraph @connectParams | Out-Null

    $context = Get-MgContext
    if (-not $context) {
        throw 'Failed to establish a Microsoft Graph context.'
    }

    if ($TenantId -and $context.TenantId -ne $TenantId) {
        throw "Connected tenant '$($context.TenantId)' does not match the requested TenantId '$TenantId'."
    }

    Write-CleanupLog -Message "Connected to tenant '$($context.TenantId)' as account type '$($context.AuthType)'." -Level INFO -LogPath $LogPath
    return $context
}

function Test-GraphPermissions {
    <#
        .SYNOPSIS
        Compares granted delegated scopes against the scopes required for the
        current execution mode.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string[]]$RequiredScopes
    )

    $context = Get-MgContext
    if (-not $context) {
        throw 'No Microsoft Graph context is available. Call Connect-MgGraph first.'
    }

    $granted = @($context.Scopes)
    $missing = @($RequiredScopes | Where-Object { $granted -notcontains $_ })

    return [PSCustomObject]@{
        HasAllRequired = ($missing.Count -eq 0)
        MissingScopes  = $missing
        GrantedScopes  = $granted
    }
}

#endregion Prerequisites and connection

#region Retry logic

function Get-GraphErrorMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    if ($ErrorRecord.Exception.Message) { $messages.Add($ErrorRecord.Exception.Message.Trim()) }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $detail = $ErrorRecord.ErrorDetails.Message.Trim()
        if ($detail -and -not $messages.Contains($detail)) { $messages.Add($detail) }
    }

    if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try {
            $content = $ErrorRecord.Exception.Response.Content
            if ($content) {
                $responseBody = $content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($responseBody) {
                    $responseBody = $responseBody.Trim()
                    if (-not $messages.Contains($responseBody)) { $messages.Add($responseBody) }
                }
            }
        } catch {
            Write-Verbose "Could not read Graph response body: $($_.Exception.Message)"
        }
    }

    return ($messages -join ' | ')
}

function Invoke-GraphWithRetry {
    <#
        .SYNOPSIS
        Executes a Microsoft Graph script block with bounded retry for
        transient failures (HTTP 429/503/504), honoring Retry-After when present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'GraphOperation',
        [int]$MaxRetries = 5,
        [int]$InitialDelaySeconds = 2,
        [string]$LogPath,
        [switch]$SuppressErrorLog
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            $errorRecord = $_
            $statusCode = $null

            if ($errorRecord.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
                $statusCode = $errorRecord.Exception.ResponseStatusCode
            }

            $message = Get-GraphErrorMessage -ErrorRecord $errorRecord
            $isTransient = $false
            if ($statusCode -in 429, 503, 504) { $isTransient = $true }
            if ($message -match '429|Too Many Requests|503|Service Unavailable|504|Gateway Timeout') { $isTransient = $true }

            if (-not $isTransient -or $attempt -ge $MaxRetries) {
                if ($LogPath -and -not $SuppressErrorLog) {
                    Write-CleanupLog -Message "Graph operation '$OperationName' failed after $attempt attempt(s): $message" -Level ERROR -LogPath $LogPath
                }
                throw
            }

            $retryAfterSeconds = $null
            if ($errorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $errorRecord.Exception.Response) {
                try {
                    $header = $errorRecord.Exception.Response.Headers.RetryAfter
                    if ($header -and $header.Delta) { $retryAfterSeconds = $header.Delta.Value.TotalSeconds }
                } catch {
                    # Retry-After header absent or unparsable; fall back to exponential backoff below.
                    Write-Verbose "Could not parse Retry-After header: $($_.Exception.Message)"
                }
            }

            $delaySeconds = if ($retryAfterSeconds) { $retryAfterSeconds } else { $InitialDelaySeconds * [Math]::Pow(2, $attempt - 1) }

            if ($LogPath) {
                Write-CleanupLog -Message "Graph operation '$OperationName' transient failure (attempt $attempt of $MaxRetries). Retrying in $delaySeconds second(s). $message" -Level WARNING -LogPath $LogPath
            }
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

#endregion Retry logic

#region Discovery

function Get-EntraDeviceRecords {
    <#
        .SYNOPSIS
        Retrieves all Microsoft Entra ID device objects with the properties
        required for stale-device evaluation. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [string]$LogPath
    )

    $properties = @(
        'Id', 'DeviceId', 'DisplayName', 'OperatingSystem', 'OperatingSystemVersion',
        'AccountEnabled', 'TrustType', 'ProfileType', 'ApproximateLastSignInDateTime',
        'OnPremisesSyncEnabled', 'OnPremisesLastSyncDateTime', 'RegistrationDateTime',
        'IsManaged', 'IsCompliant', 'Manufacturer', 'Model'
    )

    Write-CleanupLog -Message 'Retrieving Microsoft Entra ID device records.' -Level INFO -LogPath $LogPath
    $devices = Invoke-GraphWithRetry -OperationName 'Get-MgDevice' -LogPath $LogPath -ScriptBlock {
        Get-MgDevice -All -Property $properties -ErrorAction Stop
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($devices)) { $list.Add($d) }

    Write-CleanupLog -Message "Retrieved $($list.Count) Microsoft Entra ID device record(s)." -Level INFO -LogPath $LogPath
    return , $list
}

function Get-IntuneManagedDeviceRecords {
    <#
        .SYNOPSIS
        Retrieves all Intune managed-device records. Used only as a
        correlation and activity source; never a deletion target in v1.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [string]$LogPath
    )

    Write-CleanupLog -Message 'Retrieving Intune managed-device records.' -Level INFO -LogPath $LogPath
    $devices = Invoke-GraphWithRetry -OperationName 'Get-MgDeviceManagementManagedDevice' -LogPath $LogPath -ScriptBlock {
        Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($devices)) { $list.Add($d) }

    Write-CleanupLog -Message "Retrieved $($list.Count) Intune managed-device record(s)." -Level INFO -LogPath $LogPath
    return , $list
}

function Get-WindowsAutopilotRecords {
    <#
        .SYNOPSIS
        Retrieves all Windows Autopilot device identity records.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [string]$LogPath
    )

    Write-CleanupLog -Message 'Retrieving Windows Autopilot device identity records.' -Level INFO -LogPath $LogPath
    $devices = Invoke-GraphWithRetry -OperationName 'Get-MgDeviceManagementWindowsAutopilotDeviceIdentity' -LogPath $LogPath -ScriptBlock {
        Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All -ErrorAction Stop
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($devices)) { $list.Add($d) }

    Write-CleanupLog -Message "Retrieved $($list.Count) Windows Autopilot device identity record(s)." -Level INFO -LogPath $LogPath
    return , $list
}

#endregion Discovery

#region Normalization helpers

function ConvertTo-NormalizedSerialNumber {
    <#
        .SYNOPSIS
        Trims, lowercases, and rejects placeholder/invalid serial numbers.
        Returns $null when the serial number cannot be used as a match key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$SerialNumber
    )

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) { return $null }
    $trimmed = $SerialNumber.Trim()
    if ($script:InvalidSerialNumbers -contains $trimmed.ToLowerInvariant()) { return $null }
    return $trimmed.ToLowerInvariant()
}

function Get-SafeUtcTimestamp {
    <#
        .SYNOPSIS
        Converts a Graph timestamp value to a UTC DateTime, treating missing,
        null, or sentinel "never" values (e.g. year 0001) as no data ($null).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Value
    )

    if (-not $Value) { return $null }
    try {
        $dt = [datetime]$Value
    } catch {
        return $null
    }
    if ($dt.Year -le 1601) { return $null }
    return $dt.ToUniversalTime()
}

function Resolve-DevicePlatform {
    <#
        .SYNOPSIS
        Classifies an operating-system string into Windows, iOS, Android,
        Server, Unsupported, or Unknown. Case-insensitive, substring-based.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$OperatingSystem
    )

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) { return 'Unknown' }
    $os = $OperatingSystem.Trim().ToLowerInvariant()

    $serverIndicators = @('windows server', 'windowsserver', 'server')
    foreach ($indicator in $serverIndicators) {
        if ($os -match [regex]::Escape($indicator)) { return 'Server' }
    }

    if ($os -match 'windows') { return 'Windows' }
    if ($os -match 'ios' -or $os -match 'ipad' -or $os -match 'iphone') { return 'iOS' }
    if ($os -match 'android') { return 'Android' }
    if ($os -match 'linux' -or $os -match 'macos' -or $os -match 'mac os' -or $os -match 'chromeos' -or $os -match 'chrome os') { return 'Unsupported' }

    return 'Unknown'
}

#endregion Normalization helpers

#region Indexing and correlation

function New-DeviceIndexes {
    <#
        .SYNOPSIS
        Builds hash-table indexes over Intune and Autopilot records so that
        correlation is O(1) per Entra device instead of one Graph call each.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$IntuneDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AutopilotDevices
    )

    $intuneByAadDeviceId = @{}
    $intuneById = @{}
    foreach ($d in $IntuneDevices) {
        if ($d.AzureAdDeviceId) {
            $key = $d.AzureAdDeviceId.ToString().ToLowerInvariant()
            if (-not $intuneByAadDeviceId.ContainsKey($key)) { $intuneByAadDeviceId[$key] = [System.Collections.Generic.List[object]]::new() }
            $intuneByAadDeviceId[$key].Add($d)
        }
        if ($d.Id) { $intuneById[$d.Id.ToString().ToLowerInvariant()] = $d }
    }

    $autopilotByAadDeviceId = @{}
    $autopilotByManagedDeviceId = @{}
    $autopilotBySerial = @{}
    foreach ($a in $AutopilotDevices) {
        if ($a.AzureActiveDirectoryDeviceId) {
            $key = $a.AzureActiveDirectoryDeviceId.ToString().ToLowerInvariant()
            if (-not $autopilotByAadDeviceId.ContainsKey($key)) { $autopilotByAadDeviceId[$key] = [System.Collections.Generic.List[object]]::new() }
            $autopilotByAadDeviceId[$key].Add($a)
        }
        if ($a.ManagedDeviceId -and $a.ManagedDeviceId -ne [Guid]::Empty.ToString()) {
            $key = $a.ManagedDeviceId.ToString().ToLowerInvariant()
            if (-not $autopilotByManagedDeviceId.ContainsKey($key)) { $autopilotByManagedDeviceId[$key] = [System.Collections.Generic.List[object]]::new() }
            $autopilotByManagedDeviceId[$key].Add($a)
        }
        $serial = ConvertTo-NormalizedSerialNumber -SerialNumber $a.SerialNumber
        if ($serial) {
            if (-not $autopilotBySerial.ContainsKey($serial)) { $autopilotBySerial[$serial] = [System.Collections.Generic.List[object]]::new() }
            $autopilotBySerial[$serial].Add($a)
        }
    }

    return [PSCustomObject]@{
        IntuneByAadDeviceId        = $intuneByAadDeviceId
        IntuneById                 = $intuneById
        AutopilotByAadDeviceId     = $autopilotByAadDeviceId
        AutopilotByManagedDeviceId = $autopilotByManagedDeviceId
        AutopilotBySerial          = $autopilotBySerial
    }
}

function Resolve-DeviceCorrelation {
    <#
        .SYNOPSIS
        Correlates a single Entra device to at most one Intune record and
        (for Windows only) at most one Autopilot record, using stable
        identifiers only. Device name is never a destructive match key.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]$EntraDevice,
        [Parameter(Mandatory)][PSCustomObject]$Indexes,
        [Parameter(Mandatory)][string]$Platform
    )

    $result = [PSCustomObject]@{
        IntuneMatch          = $null
        AutopilotMatch       = $null
        MatchStatus          = 'Unmatched'
        MatchMethod          = 'None'
        MatchConfidence      = 'Unmatched'
        AmbiguityReason      = $null
    }

    if ($EntraDevice.DeviceId) {
        $key = $EntraDevice.DeviceId.ToString().ToLowerInvariant()
        if ($Indexes.IntuneByAadDeviceId.ContainsKey($key)) {
            $intuneMatches = $Indexes.IntuneByAadDeviceId[$key]
            if ($intuneMatches.Count -eq 1) {
                $result.IntuneMatch = $intuneMatches[0]
                $result.MatchMethod = 'EntraDeviceIdToIntuneAzureAdDeviceId'
                $result.MatchConfidence = 'High'
                $result.MatchStatus = 'Matched'
            } else {
                $result.MatchConfidence = 'Ambiguous'
                $result.MatchStatus = 'Ambiguous'
                $result.AmbiguityReason = 'MultipleIntuneRecordsMatchSameAzureAdDeviceId'
            }
        }
    }

    if ($Platform -eq 'Windows' -and $result.MatchStatus -ne 'Ambiguous') {
        $autopilotMatches = $null
        $method = $null
        $confidence = $null

        if ($EntraDevice.DeviceId) {
            $key = $EntraDevice.DeviceId.ToString().ToLowerInvariant()
            if ($Indexes.AutopilotByAadDeviceId.ContainsKey($key)) {
                $autopilotMatches = $Indexes.AutopilotByAadDeviceId[$key]
                $method = 'AutopilotAzureAdDeviceId'
                $confidence = 'High'
            }
        }

        if (-not $autopilotMatches -and $result.IntuneMatch -and $result.IntuneMatch.Id) {
            $key = $result.IntuneMatch.Id.ToString().ToLowerInvariant()
            if ($Indexes.AutopilotByManagedDeviceId.ContainsKey($key)) {
                $autopilotMatches = $Indexes.AutopilotByManagedDeviceId[$key]
                $method = 'AutopilotManagedDeviceId'
                $confidence = 'Medium'
            }
        }

        if (-not $autopilotMatches -and $result.IntuneMatch -and $result.IntuneMatch.SerialNumber) {
            $serial = ConvertTo-NormalizedSerialNumber -SerialNumber $result.IntuneMatch.SerialNumber
            if ($serial -and $Indexes.AutopilotBySerial.ContainsKey($serial)) {
                $autopilotMatches = $Indexes.AutopilotBySerial[$serial]
                $method = 'NormalizedSerialNumber'
                $confidence = 'Low'
            }
        }

        if ($autopilotMatches) {
            if ($autopilotMatches.Count -eq 1) {
                $result.AutopilotMatch = $autopilotMatches[0]
                $result.MatchMethod = if ($result.MatchMethod -eq 'None') { $method } else { "$($result.MatchMethod)+$method" }
                if ($result.MatchConfidence -ne 'Ambiguous') {
                    # Overall confidence is the weaker of the two match confidences.
                    $rank = @{ High = 3; Medium = 2; Low = 1 }
                    $existingRank = if ($rank.ContainsKey($result.MatchConfidence)) { $rank[$result.MatchConfidence] } else { 99 }
                    $newRank = $rank[$confidence]
                    $result.MatchConfidence = if ($newRank -lt $existingRank) { $confidence } elseif ($result.MatchConfidence -eq 'Unmatched') { $confidence } else { $result.MatchConfidence }
                }
                $result.MatchStatus = 'Matched'
            } else {
                $result.MatchConfidence = 'Ambiguous'
                $result.MatchStatus = 'Ambiguous'
                $reason = if ($method -eq 'NormalizedSerialNumber') { 'DuplicateSerialNumber' } else { 'MultipleAutopilotRecordsMatchSameDevice' }
                $result.AmbiguityReason = $reason
            }
        }
    }

    return $result
}

#endregion Indexing and correlation

#region Activity evaluation

function Get-EffectiveLastActivity {
    <#
        .SYNOPSIS
        Calculates EffectiveLastActivity as the newest of the authoritative
        activity timestamps (Intune lastSyncDateTime, Entra
        approximateLastSignInDateTime). Missing Intune data is normal and
        never overrides a newer Entra timestamp, or vice versa.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowNull()][Nullable[datetime]]$IntuneLastSyncDateTimeUtc,
        [AllowNull()][Nullable[datetime]]$EntraApproximateLastSignInDateTimeUtc
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    if ($IntuneLastSyncDateTimeUtc) { $candidates.Add([PSCustomObject]@{ Source = 'IntuneLastSyncDateTime'; Timestamp = $IntuneLastSyncDateTimeUtc }) }
    if ($EntraApproximateLastSignInDateTimeUtc) { $candidates.Add([PSCustomObject]@{ Source = 'EntraApproximateLastSignInDateTime'; Timestamp = $EntraApproximateLastSignInDateTimeUtc }) }

    if ($candidates.Count -eq 0) {
        return [PSCustomObject]@{ EffectiveLastActivityUtc = $null; ActivitySource = 'None' }
    }

    $maxTimestamp = ($candidates | Measure-Object -Property Timestamp -Maximum).Maximum
    $sources = ($candidates | Where-Object { $_.Timestamp -eq $maxTimestamp } | Select-Object -ExpandProperty Source) -join ';'

    return [PSCustomObject]@{ EffectiveLastActivityUtc = $maxTimestamp; ActivitySource = $sources }
}

#endregion Activity evaluation

#region Protection

function Test-DeviceProtection {
    <#
        .SYNOPSIS
        Determines whether a device is protected from deletion by an explicit
        protected-device list or device-name pattern.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]$Device,
        [AllowNull()][string]$IntuneSerialNumber,
        [string[]]$ProtectedEntraObjectIds = @(),
        [string[]]$ProtectedEntraDeviceIds = @(),
        [string[]]$ProtectedSerialNumbers = @(),
        [string[]]$ProtectedDeviceNames = @(),
        [string[]]$ProtectedNamePatterns = @()
    )

    if ($Device.Id -and $ProtectedEntraObjectIds -contains $Device.Id) {
        return [PSCustomObject]@{ IsProtected = $true; Reason = 'Entra object id matches the protected device list.' }
    }
    if ($Device.DeviceId -and $ProtectedEntraDeviceIds -contains $Device.DeviceId) {
        return [PSCustomObject]@{ IsProtected = $true; Reason = 'Entra device id matches the protected device list.' }
    }
    if ($IntuneSerialNumber) {
        $normalized = ConvertTo-NormalizedSerialNumber -SerialNumber $IntuneSerialNumber
        if ($normalized -and ($ProtectedSerialNumbers | ForEach-Object { ConvertTo-NormalizedSerialNumber -SerialNumber $_ }) -contains $normalized) {
            return [PSCustomObject]@{ IsProtected = $true; Reason = 'Serial number matches the protected device list.' }
        }
    }
    if ($Device.DisplayName) {
        # -like also matches plain names with no wildcard chars, so CSV DeviceName entries may contain literal names or wildcard patterns.
        foreach ($name in $ProtectedDeviceNames) {
            if ($Device.DisplayName -like $name) {
                return [PSCustomObject]@{ IsProtected = $true; Reason = 'Device name matches the protected device list.' }
            }
        }
        foreach ($pattern in $ProtectedNamePatterns) {
            if ($Device.DisplayName -like $pattern) {
                return [PSCustomObject]@{ IsProtected = $true; Reason = "Device name matches protected pattern '$pattern'." }
            }
        }
    }

    return [PSCustomObject]@{ IsProtected = $false; Reason = $null }
}

#endregion Protection

#region Evaluation orchestration

function Get-StaleDeviceCandidates {
    <#
        .SYNOPSIS
        Evaluates every Entra device against platform, correlation, activity,
        and protection rules, producing one evaluated record per device with
        a Decision of Candidate, Excluded, or ManualReview.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntraDevices,
        [Parameter(Mandatory)][PSCustomObject]$Indexes,
        [Parameter(Mandatory)][datetime]$CutoffDateUtc,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$ProtectedEntraObjectIds = @(),
        [string[]]$ProtectedEntraDeviceIds = @(),
        [string[]]$ProtectedSerialNumbers = @(),
        [string[]]$ProtectedDeviceNames = @(),
        [string[]]$ProtectedNamePatterns = @(),
        [switch]$IncludeDisabledDevices,
        [switch]$AllowOnPremisesSyncedDeletion
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nowUtc = (Get-Date).ToUniversalTime()

    foreach ($device in $EntraDevices) {
        $platform = Resolve-DevicePlatform -OperatingSystem $device.OperatingSystem
        $correlation = Resolve-DeviceCorrelation -EntraDevice $device -Indexes $Indexes -Platform $platform

        $intuneSerial = if ($correlation.IntuneMatch) { $correlation.IntuneMatch.SerialNumber } else { $null }
        $intuneLastSyncUtc = if ($correlation.IntuneMatch) { Get-SafeUtcTimestamp -Value $correlation.IntuneMatch.LastSyncDateTime } else { $null }
        $entraSignInUtc = Get-SafeUtcTimestamp -Value $device.ApproximateLastSignInDateTime

        $activity = Get-EffectiveLastActivity -IntuneLastSyncDateTimeUtc $intuneLastSyncUtc -EntraApproximateLastSignInDateTimeUtc $entraSignInUtc

        $protection = Test-DeviceProtection -Device $device -IntuneSerialNumber $intuneSerial `
            -ProtectedEntraObjectIds $ProtectedEntraObjectIds -ProtectedEntraDeviceIds $ProtectedEntraDeviceIds `
            -ProtectedSerialNumbers $ProtectedSerialNumbers -ProtectedDeviceNames $ProtectedDeviceNames `
            -ProtectedNamePatterns $ProtectedNamePatterns

        $decision = $null
        $reasonCode = $null
        $reasonDescription = $null
        $entraAction = 'None'

        if ($platform -eq 'Server') {
            $decision = 'Excluded'; $reasonCode = 'UnsupportedPlatform'; $reasonDescription = 'Operating system indicates a server platform, which is out of scope.'
        } elseif ($platform -eq 'Unsupported') {
            $decision = 'Excluded'; $reasonCode = 'UnsupportedPlatform'; $reasonDescription = 'Operating system platform is not supported by this tool.'
        } elseif ($platform -eq 'Unknown') {
            $decision = 'ManualReview'; $reasonCode = 'MissingOperatingSystem'; $reasonDescription = 'Operating system information is missing or ambiguous.'
        } elseif ($protection.IsProtected) {
            $decision = 'Excluded'; $reasonCode = 'ProtectedDevice'; $reasonDescription = $protection.Reason
        } elseif ($correlation.MatchStatus -eq 'Ambiguous') {
            $decision = 'ManualReview'
            $reasonCode = if ($correlation.AmbiguityReason -eq 'DuplicateSerialNumber') { 'DuplicateSerialNumber' } else { 'AmbiguousAutopilotMatch' }
            $reasonDescription = "Correlation is ambiguous: $($correlation.AmbiguityReason)."
        } elseif ($platform -eq 'Windows' -and $correlation.AutopilotMatch -and $correlation.MatchConfidence -ne 'High') {
            $decision = 'ManualReview'; $reasonCode = 'LowConfidenceMatch'; $reasonDescription = "Autopilot match confidence '$($correlation.MatchConfidence)' is insufficient for safe lifecycle correlation."
        } elseif ($correlation.AutopilotMatch) {
            $decision = 'Excluded'; $reasonCode = 'AutopilotProtected'; $reasonDescription = 'Autopilot-backed devices require explicit hardware deregistration, not activity-based deletion.'
        } elseif (-not $activity.EffectiveLastActivityUtc) {
            $decision = 'ManualReview'; $reasonCode = 'MissingAllActivity'; $reasonDescription = 'No authoritative activity timestamp (Intune lastSyncDateTime or Entra approximateLastSignInDateTime) is available.'
        } elseif ($activity.EffectiveLastActivityUtc -gt $CutoffDateUtc) {
            $decision = 'Excluded'; $reasonCode = 'RecentActivityDetected'; $reasonDescription = 'Effective last activity is newer than the inactivity threshold.'
        } elseif ($device.OnPremisesSyncEnabled -eq $true -and -not $AllowOnPremisesSyncedDeletion) {
            $decision = 'Excluded'; $reasonCode = 'OnPremisesSyncProtected'; $reasonDescription = 'Device is stale by available cloud activity evidence but is synchronized from on-premises Active Directory. Source AD deletion safety has not been assessed; manual review is required.'
        } else {
            $decision = 'Candidate'; $reasonCode = 'Stale'; $reasonDescription = 'Effective last activity is older than or equal to the configured inactivity threshold; the Entra device will be removed directly.'; $entraAction = 'Remove'
        }

        $daysInactive = $null
        if ($activity.EffectiveLastActivityUtc) {
            $daysInactive = [Math]::Floor(($nowUtc - $activity.EffectiveLastActivityUtc).TotalDays)
        }

        $record = [PSCustomObject][ordered]@{
            RunId                                 = $RunId
            EvaluationTimestampUtc                = $nowUtc.ToString('o')
            DeviceName                             = $device.DisplayName
            NormalizedDeviceName                   = if ($device.DisplayName) { $device.DisplayName.Trim().ToLowerInvariant() } else { $null }
            Platform                               = $platform
            OperatingSystem                        = $device.OperatingSystem
            OperatingSystemVersion                 = $device.OperatingSystemVersion
            Manufacturer                           = $device.Manufacturer
            Model                                  = $device.Model
            EntraObjectId                           = $device.Id
            EntraDeviceId                           = $device.DeviceId
            EntraAccountEnabled                     = $device.AccountEnabled
            EntraTrustType                          = $device.TrustType
            EntraProfileType                        = $device.ProfileType
            EntraApproximateLastSignInDateTimeUtc   = $entraSignInUtc
            EntraRegistrationDateTimeUtc            = Get-SafeUtcTimestamp -Value $device.RegistrationDateTime
            OnPremisesSyncEnabled                   = $device.OnPremisesSyncEnabled
            OnPremisesLastSyncDateTimeUtc           = Get-SafeUtcTimestamp -Value $device.OnPremisesLastSyncDateTime
            IntunePresent                           = [bool]$correlation.IntuneMatch
            IntuneManagedDeviceId                   = if ($correlation.IntuneMatch) { $correlation.IntuneMatch.Id } else { $null }
            IntuneAzureADDeviceId                   = if ($correlation.IntuneMatch) { $correlation.IntuneMatch.AzureAdDeviceId } else { $null }
            IntuneSerialNumber                      = $intuneSerial
            IntuneLastSyncDateTimeUtc               = $intuneLastSyncUtc
            IntuneEnrollmentDateTimeUtc             = if ($correlation.IntuneMatch) { Get-SafeUtcTimestamp -Value $correlation.IntuneMatch.EnrolledDateTime } else { $null }
            IntuneManagementAgent                   = if ($correlation.IntuneMatch) { $correlation.IntuneMatch.ManagementAgent } else { $null }
            AutopilotPresent                        = [bool]$correlation.AutopilotMatch
            AutopilotIdentityId                     = if ($correlation.AutopilotMatch) { $correlation.AutopilotMatch.Id } else { $null }
            AutopilotAzureADDeviceId                = if ($correlation.AutopilotMatch) { $correlation.AutopilotMatch.AzureActiveDirectoryDeviceId } else { $null }
            AutopilotManagedDeviceId                = if ($correlation.AutopilotMatch) { $correlation.AutopilotMatch.ManagedDeviceId } else { $null }
            AutopilotSerialNumber                   = if ($correlation.AutopilotMatch) { $correlation.AutopilotMatch.SerialNumber } else { $null }
            AutopilotEnrollmentState                = if ($correlation.AutopilotMatch) { $correlation.AutopilotMatch.EnrollmentState } else { $null }
            AutopilotLastContactedDateTimeUtc       = if ($correlation.AutopilotMatch) { Get-SafeUtcTimestamp -Value $correlation.AutopilotMatch.LastContactedDateTime } else { $null }
            EffectiveLastActivityUtc                = $activity.EffectiveLastActivityUtc
            ActivitySource                          = $activity.ActivitySource
            DaysInactive                            = $daysInactive
            DisabledSinceUtc                        = $null
            CutoffDateUtc                           = $CutoffDateUtc
            MatchStatus                             = $correlation.MatchStatus
            MatchMethod                              = $correlation.MatchMethod
            MatchConfidence                          = $correlation.MatchConfidence
            Decision                                 = $decision
            ReasonCode                               = $reasonCode
            ReasonDescription                        = $reasonDescription
            EntraAction                              = $entraAction
            EntraDisableStatus                      = 'NotAttempted'
            AutopilotRemovalStatus                   = 'NotAttempted'
            EntraRemovalStatus                       = 'NotAttempted'
            ErrorMessage                             = $null
        }

        $results.Add($record)
    }

    return , $results
}

#endregion Evaluation orchestration

#region Summary and confirmation

function Show-CleanupSummary {
    <#
        .SYNOPSIS
        Displays a human-readable, platform-grouped summary of the run to the
        console. Console output only; does not affect reports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EvaluatedDevices,
        [Parameter(Mandatory)][datetime]$CutoffDateUtc,
        [Parameter(Mandatory)][int]$DaysInactive,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$TenantId = 'Not specified',
        [ValidateSet('Audit', 'Interactive', 'Automatic')][string]$Mode = 'Audit',
        [bool]$Simulation = $false,
        [ValidateSet('Individual', 'JsonBatch')][string]$DeletionTransport = 'Individual'
    )

    $candidates = @($EvaluatedDevices | Where-Object {
        $_.Decision -eq 'Candidate' -and $_.EntraAction -eq 'Remove' -and -not $_.AutopilotPresent -and $_.EntraObjectId
    } | Sort-Object EntraObjectId -Unique)
    $windowsWithoutAutopilot = @($candidates | Where-Object Platform -eq 'Windows')
    $ios = @($candidates | Where-Object Platform -eq 'iOS')
    $android = @($candidates | Where-Object Platform -eq 'Android')
    $toRemove = @($candidates | Where-Object EntraAction -eq 'Remove')

    $excluded = $EvaluatedDevices | Where-Object Decision -eq 'Excluded'
    $manualReview = $EvaluatedDevices | Where-Object Decision -eq 'ManualReview'

    Write-Host ''
    Write-Host 'Stale-device cleanup summary'
    Write-Host "Workflow: Stale Entra cleanup; tenant: $TenantId"
    Write-Host "Mode: $Mode; WhatIf: $Simulation; transport: $DeletionTransport"
    if ($Mode -eq 'Audit' -or $Simulation) { Write-Host 'No tenant DELETE requests will be sent.' }
    Write-Host "Cutoff date UTC: $($CutoffDateUtc.ToString('o'))"
    Write-Host "Inactivity threshold: $DaysInactive days"
    Write-Host ''
    Write-Host 'Planned Entra deletions (unique objects):'
    Write-Host ("  Windows without Autopilot:    {0}" -f $windowsWithoutAutopilot.Count)
    Write-Host ("  iOS:                          {0}" -f $ios.Count)
    Write-Host ("  Android:                      {0}" -f $android.Count)
    Write-Host ("  Entra objects to remove:      {0}" -f $toRemove.Count)
    Write-Host 'No Intune or Autopilot deletion in this workflow.'
    Write-Host ''
    Write-Host 'Excluded or manual review:'
    Write-Host ("  Missing all activity:         {0}" -f @($manualReview | Where-Object ReasonCode -eq 'MissingAllActivity').Count)
    Write-Host ("  Ambiguous matches:            {0}" -f @($manualReview | Where-Object { $_.ReasonCode -in 'AmbiguousAutopilotMatch', 'DuplicateSerialNumber' }).Count)
    Write-Host ("  Autopilot-backed (retained):   {0}" -f @($excluded | Where-Object ReasonCode -eq 'AutopilotProtected').Count)
    Write-Host ("  Explicitly protected:         {0}" -f @($excluded | Where-Object ReasonCode -eq 'ProtectedDevice').Count)
    Write-Host ("  On-premises sync protected:   {0}" -f @($excluded | Where-Object ReasonCode -eq 'OnPremisesSyncProtected').Count)
    Write-Host ("  Low-confidence AP matches:    {0}" -f @($manualReview | Where-Object ReasonCode -eq 'LowConfidenceMatch').Count)
    Write-Host ("  Server / unsupported:         {0}" -f @($excluded | Where-Object ReasonCode -eq 'UnsupportedPlatform').Count)
    Write-Host ("  Recent activity detected:     {0}" -f @($excluded | Where-Object ReasonCode -eq 'RecentActivityDetected').Count)
    Write-Host ("  Missing operating system:     {0}" -f @($manualReview | Where-Object ReasonCode -eq 'MissingOperatingSystem').Count)
    Write-Host ("  Total excluded:               {0}" -f @($excluded).Count)
    Write-Host ("  Total manual review:          {0}" -f @($manualReview).Count)
    Write-Host ''
    Write-Host "Reports have been written to:"
    Write-Host "  $OutputPath"
    Write-Host ''
}

function Show-ScrappedDeviceSummary {
    <#
        .SYNOPSIS
        Displays the exact unique records targeted by the scrapped-device
        workflow before deletion confirmation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScrappedDeviceRecords,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(0, [int]::MaxValue)][int]$CsvDuplicateCount = 0,
        [string]$TenantId = 'Not specified',
        [ValidateSet('Audit', 'Interactive', 'Automatic')][string]$Mode = 'Audit',
        [bool]$Simulation = $false,
        [ValidateSet('Individual', 'JsonBatch')][string]$DeletionTransport = 'Individual'
    )

    $inputSerials = @($ScrappedDeviceRecords | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $matchedRecords = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')
    $matchedSerials = @($matchedRecords | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $autopilotIds = @($matchedRecords | Where-Object AutopilotIdentityId | Select-Object -ExpandProperty AutopilotIdentityId -Unique)
    $intuneIds = @($matchedRecords | Where-Object IntuneManagedDeviceId | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique)
    $entraIds = @($matchedRecords | Where-Object EntraObjectId | Select-Object -ExpandProperty EntraObjectId -Unique)
    $ambiguousSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Ambiguous' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $notFoundSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'NotFound' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)

    Write-Host ''
    Write-Host 'Scrapped-device cleanup summary'
    Write-Host "Workflow: Explicit scrapped hardware deregistration; tenant: $TenantId"
    Write-Host "Mode: $Mode; WhatIf: $Simulation; transport: $DeletionTransport"
    Write-Host 'Inactivity threshold: Not used for this workflow.'
    if ($Mode -eq 'Audit' -or $Simulation) { Write-Host 'No tenant DELETE requests will be sent.' }
    Write-Host ("  Unique input serial numbers:   {0}" -f $inputSerials.Count)
    Write-Host ("  Duplicate CSV rows ignored:    {0}" -f $CsvDuplicateCount)
    Write-Host ("  Matched serial numbers:        {0}" -f $matchedSerials.Count)
    Write-Host ("  Serials with DELETE targets:   {0}" -f @($matchedRecords | Where-Object {
        $_.IntuneManagedDeviceId -or $_.AutopilotIdentityId
    } | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count)
    Write-Host ''
    Write-Host 'Planned DELETE operations (unique records, not physical devices):'
    Write-Host ("  Autopilot records:             {0}" -f $autopilotIds.Count)
    Write-Host ("  Intune managed devices:        {0}" -f $intuneIds.Count)
    Write-Host ("  Total DELETE operations:       {0}" -f ($intuneIds.Count + $autopilotIds.Count))
    Write-Host ''
    Write-Host 'Retained in this workflow:'
    Write-Host ("  Entra objects for review:      {0}" -f $entraIds.Count)
    Write-Host '  Entra DELETE operations:       0'
    Write-Host 'Order: Intune first; required success before Autopilot.'
    Write-Host ''
    Write-Host 'Excluded from deletion:'
    Write-Host ("  Ambiguous serial numbers:      {0}" -f $ambiguousSerials.Count)
    Write-Host ("  Serial numbers not found:      {0}" -f $notFoundSerials.Count)
    Write-Host ("  Protected / out of scope:      {0}" -f @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Excluded' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count)
    Write-Host ''
    Write-Host 'Reports have been written to:'
    Write-Host "  $OutputPath"
    Write-Host ''
}

function Request-DeletionConfirmation {
    <#
        .SYNOPSIS
        Requires the administrator to type the exact word DELETE to proceed.
        Any other input, including Enter, Y, or YES, cancels safely.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Prompt = 'Type DELETE to continue or press Enter to cancel'
    )

    $response = Read-Host -Prompt $Prompt
    return ($null -ne $response) -and ($response.Trim() -ceq 'DELETE')
}

#endregion Summary and confirmation

#region Reporting

function Export-ReportCsv {
    <#
        .SYNOPSIS
        Writes a CSV report, guaranteeing the file exists even when the
        input collection is empty.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$InputObject,
        [AllowEmptyCollection()][string[]]$Headers = @(),
        [Parameter(Mandatory)][string]$Path
    )

    $items = @($InputObject | Where-Object { $_ })
    if ($items.Count -gt 0) {
        $exportItems = @(
            foreach ($item in $items) {
                $fields = [ordered]@{}
                foreach ($property in $item.PSObject.Properties) {
                    $value = $property.Value
                    if ($value -is [datetimeoffset]) {
                        $value = $value.UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                    } elseif ($value -is [datetime]) {
                        if ($value.Kind -eq [DateTimeKind]::Unspecified) {
                            if ($property.Name -notlike '*Utc') {
                                throw "CSV timestamp '$($property.Name)' has no timezone and no UTC field contract."
                            }
                            $value = [datetime]::SpecifyKind($value, [DateTimeKind]::Utc)
                        }
                        $value = $value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    $fields[$property.Name] = $value
                }
                [PSCustomObject]$fields
            }
        )
        $exportItems | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    } elseif ($Headers.Count -gt 0) {
        $headerObject = [ordered]@{}
        foreach ($header in $Headers) {
            $headerObject[$header] = $null
        }
        [PSCustomObject]$headerObject | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1 | Set-Content -Path $Path -Encoding utf8
    } else {
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }
}

function Export-CleanupReports {
    <#
        .SYNOPSIS
        Writes all required CSV reports for a run. Must be called before any
        deletion confirmation prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllEvaluatedDevices,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $candidates = @($AllEvaluatedDevices | Where-Object Decision -eq 'Candidate')
    $excluded = @($AllEvaluatedDevices | Where-Object Decision -eq 'Excluded')
    $manualReview = @($AllEvaluatedDevices | Where-Object Decision -eq 'ManualReview')
    $ambiguous = @($AllEvaluatedDevices | Where-Object MatchStatus -eq 'Ambiguous')
    $errors = @($AllEvaluatedDevices | Where-Object { $_.ErrorMessage })
    $deleted = @($AllEvaluatedDevices | Where-Object { $_.EntraRemovalStatus -eq 'Removed' -or $_.AutopilotRemovalStatus -in 'Removed', 'AlreadyRemoved' })
    $onPremisesReviewFields = @(
        'RunId', 'EvaluationTimestampUtc', 'EntraObjectId', 'EntraDeviceId', 'DeviceName',
        'Platform', 'OperatingSystem', 'OperatingSystemVersion', 'EntraAccountEnabled',
        'OnPremisesSyncEnabled', 'OnPremisesLastSyncDateTimeUtc', 'EffectiveLastActivityUtc',
        'ActivitySource', 'DaysInactive', 'CutoffDateUtc', 'IntunePresent',
        'IntuneManagedDeviceId', 'IntuneSerialNumber', 'AutopilotPresent',
        'AutopilotIdentityId', 'AutopilotSerialNumber', 'MatchStatus', 'MatchConfidence',
        'Decision', 'ReasonCode', 'ReasonDescription'
    )
    $onPremisesReviewHeaders = @($onPremisesReviewFields + 'SourceADDeletionSafety')
    $onPremisesSyncReview = @(
        $AllEvaluatedDevices |
            Where-Object { $_.PSObject.Properties['ReasonCode'] -and $_.ReasonCode -eq 'OnPremisesSyncProtected' } |
            Select-Object -Property ($onPremisesReviewFields + @{ Name = 'SourceADDeletionSafety'; Expression = { 'NotAssessed' } })
    )

    Export-ReportCsv -InputObject $AllEvaluatedDevices -Path (Join-Path $OutputPath 'AllEvaluatedDevices.csv')
    Export-ReportCsv -InputObject $candidates -Path (Join-Path $OutputPath 'DeletionCandidates.csv')
    Export-ReportCsv -InputObject $deleted -Path (Join-Path $OutputPath 'DeletedDevices.csv')
    Export-ReportCsv -InputObject $manualReview -Path (Join-Path $OutputPath 'UnknownDevices.csv')
    Export-ReportCsv -InputObject $ambiguous -Path (Join-Path $OutputPath 'AmbiguousMatches.csv')
    Export-ReportCsv -InputObject $excluded -Path (Join-Path $OutputPath 'ExcludedDevices.csv')
    Export-ReportCsv -InputObject $errors -Path (Join-Path $OutputPath 'ErrorDevices.csv')
    Export-ReportCsv -InputObject $onPremisesSyncReview -Headers $onPremisesReviewHeaders -Path (Join-Path $OutputPath 'OnPremisesSyncedReview.csv')
}

function New-RunSummary {
    <#
        .SYNOPSIS
        Builds the RunSummary.json object describing the outcome of a run.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][datetime]$StartTimeUtc,
        [datetime]$EndTimeUtc = (Get-Date).ToUniversalTime(),
        [Parameter(Mandatory)][datetime]$CutoffDateUtc,
        [Parameter(Mandatory)][int]$DaysInactive,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllEvaluatedDevices,
        [AllowEmptyCollection()][object[]]$ScrappedDeviceRecords = @(),
        [bool]$AllowOnPremisesSyncedDeletion = $false,
        [bool]$WhatIfMode = $false,
        [bool]$ConfirmationGranted = $false,
        [bool]$DiscoveryComplete = $true,
        [int]$ExitCode = 0
    )

    $candidates = @($AllEvaluatedDevices | Where-Object Decision -eq 'Candidate')
    $excluded = @($AllEvaluatedDevices | Where-Object Decision -eq 'Excluded')
    $manualReview = @($AllEvaluatedDevices | Where-Object Decision -eq 'ManualReview')
    $toRemove = @($AllEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.PSObject.Properties['EntraAction'] -and $_.EntraAction -eq 'Remove' })
    $onPremisesSyncReview = @($AllEvaluatedDevices | Where-Object { $_.PSObject.Properties['ReasonCode'] -and $_.ReasonCode -eq 'OnPremisesSyncProtected' })
    $deletedEntra = @($AllEvaluatedDevices | Where-Object EntraRemovalStatus -eq 'Removed')
    $deletedAutopilot = @($AllEvaluatedDevices | Where-Object AutopilotRemovalStatus -in 'Removed', 'AlreadyRemoved')
    $submittedAutopilot = @($AllEvaluatedDevices | Where-Object AutopilotRemovalStatus -eq 'RemovalSubmitted')
    $errors = @($AllEvaluatedDevices | Where-Object { $_.ErrorMessage })
    $scrappedSerials = @($ScrappedDeviceRecords | Where-Object NormalizedSerialNumber | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $scrappedMatchedSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $scrappedAmbiguousSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Ambiguous' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $scrappedNotFoundSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'NotFound' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $scrappedSubmittedAutopilot = @($ScrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'RemovalSubmitted' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique)
    $scrappedAlreadyRemovedAutopilot = @($ScrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'AlreadyRemoved' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique)
    $scrappedFailedAutopilot = @($ScrappedDeviceRecords | Where-Object { $_.AutopilotRemovalStatus -eq 'RemovalFailed' -and $_.AutopilotIdentityId } | Select-Object -ExpandProperty AutopilotIdentityId -Unique)
    $scrappedRemovedIntune = @($ScrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'Removed' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique)
    $scrappedAlreadyRemovedIntune = @($ScrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'AlreadyRemoved' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique)
    $scrappedFailedIntune = @($ScrappedDeviceRecords | Where-Object { $_.IntuneRemovalStatus -eq 'RemovalFailed' -and $_.IntuneManagedDeviceId } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique)
    $scrappedRemovedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'Removed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedAlreadyRemovedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'AlreadyRemoved' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedFailedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'RemovalFailed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedBlockedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'SkippedAutopilotSubmissionFailed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedErrorSerials = @($ScrappedDeviceRecords | Where-Object { $_.ErrorMessage -and $_.NormalizedSerialNumber } | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)

    return [PSCustomObject][ordered]@{
        RunId                     = $RunId
        Mode                      = $Mode
        WhatIfMode                = $WhatIfMode
        StartTimeUtc              = $StartTimeUtc.ToString('o')
        EndTimeUtc                = $EndTimeUtc.ToString('o')
        CutoffDateUtc             = $CutoffDateUtc.ToString('o')
        DaysInactiveThreshold     = $DaysInactive
        DiscoveryComplete         = $DiscoveryComplete
        TotalEvaluated            = $AllEvaluatedDevices.Count
        TotalCandidates           = $candidates.Count
        TotalExcluded             = $excluded.Count
        TotalManualReview         = $manualReview.Count
        TotalEntraDevicesToRemove  = $toRemove.Count
        TotalEntraDevicesRemoved  = $deletedEntra.Count
        TotalEntraDevicesAlreadyAbsent = @($AllEvaluatedDevices | Where-Object EntraRemovalStatus -eq 'AlreadyAbsent').Count
        TotalOnPremisesSyncedReview = $onPremisesSyncReview.Count
        AllowOnPremisesSyncedDeletion = $AllowOnPremisesSyncedDeletion
        TotalAutopilotRemoved     = $deletedAutopilot.Count
        TotalAutopilotRemovalSubmitted = $submittedAutopilot.Count
        ScrappedWorkflow          = ($ScrappedDeviceRecords.Count -gt 0)
        TotalScrappedSerials      = $scrappedSerials.Count
        TotalScrappedMatchedSerials = $scrappedMatchedSerials.Count
        TotalScrappedAmbiguousSerials = $scrappedAmbiguousSerials.Count
        TotalScrappedNotFoundSerials = $scrappedNotFoundSerials.Count
        TotalScrappedExcludedSerials = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Excluded' | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        TotalScrappedEntraReview = @($ScrappedDeviceRecords | Where-Object EntraObjectId | Select-Object -ExpandProperty EntraObjectId -Unique).Count
        TotalScrappedAutopilotRemovalSubmitted = $scrappedSubmittedAutopilot.Count
        TotalScrappedAutopilotAlreadyRemoved = $scrappedAlreadyRemovedAutopilot.Count
        TotalScrappedAutopilotRemovalFailed = $scrappedFailedAutopilot.Count
        TotalScrappedIntuneDevicesRemoved = $scrappedRemovedIntune.Count
        TotalScrappedIntuneDevicesAlreadyRemoved = $scrappedAlreadyRemovedIntune.Count
        TotalScrappedIntuneDevicesFailed = $scrappedFailedIntune.Count
        TotalScrappedEntraDevicesRemoved = $scrappedRemovedEntra.Count
        TotalScrappedEntraDevicesAlreadyRemoved = $scrappedAlreadyRemovedEntra.Count
        TotalScrappedEntraDevicesFailed = $scrappedFailedEntra.Count
        TotalScrappedEntraDevicesBlockedByAutopilot = $scrappedBlockedEntra.Count
        TotalScrappedErrors       = $scrappedErrorSerials.Count
        TotalErrors               = $errors.Count + $scrappedErrorSerials.Count
        ConfirmationGranted       = $ConfirmationGranted
        ExitCode                  = $ExitCode
    }
}

#endregion Reporting

#region Scrapped device cleanup

function Get-ScrappedDeviceSerialNumbers {
    <#
        .SYNOPSIS
        Reads a plain-text/CSV file of scrapped device serial numbers (one
        per line, optional header, optional quoting) and returns the unique,
        trimmed, original-case values in file order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ref]$Statistics
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Scrapped device file '$Path' was not found."
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
    $serials = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $duplicateCount = 0
    foreach ($line in $lines) {
        $value = $line.Trim().Trim(',').Trim('"').Trim()
        if (-not $value) { continue }
        if ($value.ToLowerInvariant() -in @('serialnumber', 'serial number', 'serial')) { continue }
        $key = $value.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $serials.Add($value)
        } else {
            $duplicateCount++
        }
    }
    if ($Statistics) {
        $Statistics.Value = [PSCustomObject][ordered]@{
            UniqueSerialCount = $serials.Count
            DuplicateRowCount = $duplicateCount
        }
    }
    return , $serials.ToArray()
}

function Resolve-ScrappedDeviceRecords {
    <#
        .SYNOPSIS
        Correlates a list of scrapped-device serial numbers against the
        already-discovered Entra, Intune, and Autopilot data sets, without
        making any Graph calls. Multiple matches for the same serial number
        are flagged Ambiguous and never targeted for deletion.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SerialNumbers,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntraDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$IntuneDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AutopilotDevices,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$ProtectedEntraObjectIds = @(),
        [string[]]$ProtectedEntraDeviceIds = @(),
        [string[]]$ProtectedSerialNumbers = @(),
        [string[]]$ProtectedDeviceNames = @(),
        [string[]]$ProtectedNamePatterns = @()
    )

    $intuneBySerial = @{}
    $intuneById = @{}
    foreach ($d in $IntuneDevices) {
        if ($d.Id) { $intuneById[[string]$d.Id] = $d }
        $serial = ConvertTo-NormalizedSerialNumber -SerialNumber $d.SerialNumber
        if ($serial) {
            if (-not $intuneBySerial.ContainsKey($serial)) { $intuneBySerial[$serial] = [System.Collections.Generic.List[object]]::new() }
            $intuneBySerial[$serial].Add($d)
        }
    }

    $autopilotBySerial = @{}
    foreach ($a in $AutopilotDevices) {
        $serial = ConvertTo-NormalizedSerialNumber -SerialNumber $a.SerialNumber
        if ($serial) {
            if (-not $autopilotBySerial.ContainsKey($serial)) { $autopilotBySerial[$serial] = [System.Collections.Generic.List[object]]::new() }
            $autopilotBySerial[$serial].Add($a)
        }
    }

    $entraByDeviceId = @{}
    foreach ($e in $EntraDevices) {
        if ($e.DeviceId) {
            $key = $e.DeviceId.ToString().ToLowerInvariant()
            if (-not $entraByDeviceId.ContainsKey($key)) { $entraByDeviceId[$key] = [System.Collections.Generic.List[object]]::new() }
            $entraByDeviceId[$key].Add($e)
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $getSafeValue = {
        param(
            [AllowNull()]$Object,
            [Parameter(Mandatory)][string]$PropertyName
        )

        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }

    foreach ($inputSerial in $SerialNumbers) {
        $normalized = ConvertTo-NormalizedSerialNumber -SerialNumber $inputSerial

        # Plain if/else (not an if-expression) avoids PowerShell collapsing an
        # empty-array "else" branch to $null, which would break .Count under
        # Set-StrictMode.
        $autopilotMatches = @()
        if ($normalized -and $autopilotBySerial.ContainsKey($normalized)) { $autopilotMatches = @($autopilotBySerial[$normalized]) }
        $intuneMatches = @()
        if ($normalized -and $intuneBySerial.ContainsKey($normalized)) { $intuneMatches = @($intuneBySerial[$normalized]) }

        $entraMatchIds = [System.Collections.Generic.List[string]]::new()
        $entraMatches = [System.Collections.Generic.List[object]]::new()
        foreach ($intuneMatch in $intuneMatches) {
            if ($intuneMatch.AzureAdDeviceId) {
                $key = $intuneMatch.AzureAdDeviceId.ToString().ToLowerInvariant()
                if ($entraByDeviceId.ContainsKey($key)) {
                    foreach ($e in $entraByDeviceId[$key]) {
                        if (-not $entraMatchIds.Contains($e.Id)) { $entraMatchIds.Add($e.Id); $entraMatches.Add($e) }
                    }
                }
            }
        }
        foreach ($autopilotMatch in $autopilotMatches) {
            if ($autopilotMatch.AzureActiveDirectoryDeviceId) {
                $key = $autopilotMatch.AzureActiveDirectoryDeviceId.ToString().ToLowerInvariant()
                if ($entraByDeviceId.ContainsKey($key)) {
                    foreach ($e in $entraByDeviceId[$key]) {
                        if (-not $entraMatchIds.Contains($e.Id)) { $entraMatchIds.Add($e.Id); $entraMatches.Add($e) }
                    }
                }
            }
        }

        $exclusion = $null
        $platforms = @(
            foreach ($device in $entraMatches) { Resolve-DevicePlatform -OperatingSystem $device.OperatingSystem }
            foreach ($device in $intuneMatches) {
                $os = & $getSafeValue $device 'OperatingSystem'
                Resolve-DevicePlatform -OperatingSystem $os
            }
        )
        if (@($platforms | Where-Object { $_ -notin 'Windows', 'iOS', 'Android' }).Count -gt 0) {
            $exclusion = 'UnsupportedOrMissingPlatform'
        } elseif ($autopilotMatches.Count -gt 0 -and @($platforms | Where-Object { $_ -ne 'Windows' }).Count -gt 0) {
            $exclusion = 'ConflictingPlatform'
        } elseif ($autopilotMatches.Count -gt 1) {
            $exclusion = 'DuplicateAutopilotSerial'
        } elseif (@($intuneMatches | Select-Object -ExpandProperty Id -Unique).Count -gt 1 -or $entraMatches.Count -gt 1) {
            $exclusion = 'DuplicateSerialNumber'
        }
        if ($autopilotMatches.Count -eq 1 -and $intuneMatches.Count -eq 1) {
            $autopilotManagedId = & $getSafeValue $autopilotMatches[0] 'ManagedDeviceId'
            $autopilotEntraId = & $getSafeValue $autopilotMatches[0] 'AzureActiveDirectoryDeviceId'
            if (($autopilotManagedId -and $autopilotManagedId -ne $intuneMatches[0].Id) -or
                ($autopilotEntraId -and $intuneMatches[0].AzureAdDeviceId -and $autopilotEntraId -ne $intuneMatches[0].AzureAdDeviceId)) {
                $exclusion = 'ConflictingIdentifiers'
            }
        }
        if ($autopilotMatches.Count -eq 1) {
            $managedId = & $getSafeValue $autopilotMatches[0] 'ManagedDeviceId'
            if ($managedId -and $intuneById.ContainsKey([string]$managedId)) {
                $linkedSerial = ConvertTo-NormalizedSerialNumber -SerialNumber $intuneById[[string]$managedId].SerialNumber
                if ($linkedSerial -ne $normalized) { $exclusion = 'ConflictingIdentifiers' }
            }
        }
        $protectionDevices = @($entraMatches) + @($intuneMatches | ForEach-Object {
            [PSCustomObject]@{ Id = $null; DeviceId = $_.AzureAdDeviceId; DisplayName = & $getSafeValue $_ 'DeviceName' }
        })
        $protectionDevices += @($autopilotMatches | ForEach-Object {
            [PSCustomObject]@{
                Id = $null
                DeviceId = & $getSafeValue $_ 'AzureActiveDirectoryDeviceId'
                DisplayName = $null
            }
        })
        $protectionDevices += [PSCustomObject]@{ Id = $null; DeviceId = $null; DisplayName = $null }
        foreach ($device in $protectionDevices) {
            $protection = Test-DeviceProtection -Device $device -IntuneSerialNumber $inputSerial `
                -ProtectedEntraObjectIds $ProtectedEntraObjectIds -ProtectedEntraDeviceIds $ProtectedEntraDeviceIds `
                -ProtectedSerialNumbers $ProtectedSerialNumbers -ProtectedDeviceNames $ProtectedDeviceNames `
                -ProtectedNamePatterns $ProtectedNamePatterns
            if ($protection.IsProtected) { $exclusion = 'ProtectedDevice' }
        }
        if ($exclusion) {
            $results.Add([PSCustomObject][ordered]@{
                RunId = $RunId; InputSerialNumber = $inputSerial; NormalizedSerialNumber = $normalized
                MatchStatus = $(if ($exclusion -in 'DuplicateSerialNumber', 'DuplicateAutopilotSerial') { 'Ambiguous' } else { 'Excluded' })
                AmbiguityReason = $exclusion
                AutopilotIdentityId = $null; AutopilotEnrollmentState = $null
                IntuneManagedDeviceId = $null; IntuneDeviceName = $null
                EntraObjectId = $null; EntraDeviceName = $null
                AutopilotRemovalStatus = 'NotAttempted'; IntuneRemovalStatus = 'NotAttempted'
                EntraRemovalStatus = 'NotAttempted'; ErrorMessage = $null
            })
            continue
        }

        if ($autopilotMatches.Count -gt 0) {
            # If the serial exists in Autopilot, Autopilot is the authoritative source.
            # Emit one row per unique object that belongs to the serial so the reports
            # reflect the exact set of records that will be removed.
            $matchStatus = 'Matched'
            $ambiguityReason = $null
            $rowsByKey = [System.Collections.Generic.Dictionary[string, object]]::new()
            $autopilotEnrollmentState = $null
            if ($autopilotMatches.Count -gt 0 -and $autopilotMatches[0].PSObject.Properties['EnrollmentState']) {
                $autopilotEnrollmentState = $autopilotMatches[0].EnrollmentState
            }

            foreach ($autopilotMatch in @($autopilotMatches | Select-Object -Unique -Property Id)) {
                $row = [PSCustomObject][ordered]@{
                    RunId                    = $RunId
                    InputSerialNumber        = $inputSerial
                    NormalizedSerialNumber   = $normalized
                    MatchStatus              = 'Matched'
                    AmbiguityReason          = $null
                    AutopilotIdentityId      = $autopilotMatch.Id
                    AutopilotEnrollmentState = if ($autopilotMatch.PSObject.Properties['EnrollmentState']) { $autopilotMatch.EnrollmentState } else { $autopilotEnrollmentState }
                    IntuneManagedDeviceId    = $null
                    IntuneDeviceName         = $null
                    EntraObjectId            = $null
                    EntraDeviceName          = $null
                    AutopilotRemovalStatus   = 'NotAttempted'
                    IntuneRemovalStatus      = 'NotAttempted'
                    EntraRemovalStatus       = 'NotAttempted'
                    ErrorMessage             = $null
                }
                $rowKey = [string]::Join('|', @('Autopilot', $row.AutopilotIdentityId))
                if (-not $rowsByKey.ContainsKey($rowKey)) { $rowsByKey[$rowKey] = $row }
            }

            $uniqueIntuneMatches = @($intuneMatches | Select-Object -Unique -Property Id)
            foreach ($intuneMatch in $uniqueIntuneMatches) {
                $row = [PSCustomObject][ordered]@{
                    RunId                    = $RunId
                    InputSerialNumber        = $inputSerial
                    NormalizedSerialNumber   = $normalized
                    MatchStatus              = 'Matched'
                    AmbiguityReason          = $null
                    AutopilotIdentityId      = if ($autopilotMatches.Count -gt 0) { $autopilotMatches[0].Id } else { $null }
                    AutopilotEnrollmentState = $autopilotEnrollmentState
                    IntuneManagedDeviceId    = $intuneMatch.Id
                    IntuneDeviceName         = & $getSafeValue $intuneMatch 'DeviceName'
                    EntraObjectId            = $null
                    EntraDeviceName          = $null
                    AutopilotRemovalStatus   = 'NotAttempted'
                    IntuneRemovalStatus      = 'NotAttempted'
                    EntraRemovalStatus       = 'NotAttempted'
                    ErrorMessage             = $null
                }
                $rowKey = [string]::Join('|', @('Intune', $row.IntuneManagedDeviceId))
                if (-not $rowsByKey.ContainsKey($rowKey)) { $rowsByKey[$rowKey] = $row }
            }

            $uniqueEntraMatches = @($entraMatches | Select-Object -Unique -Property Id)
            foreach ($entraMatch in $uniqueEntraMatches) {
                $row = [PSCustomObject][ordered]@{
                    RunId                    = $RunId
                    InputSerialNumber        = $inputSerial
                    NormalizedSerialNumber   = $normalized
                    MatchStatus              = 'Matched'
                    AmbiguityReason          = $null
                    AutopilotIdentityId      = if ($autopilotMatches.Count -gt 0) { $autopilotMatches[0].Id } else { $null }
                    AutopilotEnrollmentState = $autopilotEnrollmentState
                    IntuneManagedDeviceId    = $null
                    IntuneDeviceName         = $null
                    EntraObjectId            = $entraMatch.Id
                    EntraDeviceName          = & $getSafeValue $entraMatch 'DisplayName'
                    AutopilotRemovalStatus   = 'NotAttempted'
                    IntuneRemovalStatus      = 'NotAttempted'
                    EntraRemovalStatus       = 'ManualReview'
                    ErrorMessage             = $null
                }
                $rowKey = [string]::Join('|', @('Entra', $row.EntraObjectId))
                if (-not $rowsByKey.ContainsKey($rowKey)) { $rowsByKey[$rowKey] = $row }
            }

            foreach ($row in $rowsByKey.Values) { $results.Add($row) }
            continue
        }

        $matchStatus = 'NotFound'
        $ambiguityReason = $null
        if ($intuneMatches.Count -gt 1 -or $entraMatches.Count -gt 1) {
            $matchStatus = 'Ambiguous'
            $ambiguityReason = 'DuplicateSerialNumber'
        } elseif ($intuneMatches.Count -eq 1 -or $entraMatches.Count -eq 1) {
            $matchStatus = 'Matched'
        }

        $intuneMatch = if ($intuneMatches.Count -eq 1) { $intuneMatches[0] } else { $null }
        $entraMatch = if ($entraMatches.Count -eq 1) { $entraMatches[0] } else { $null }

        $results.Add([PSCustomObject][ordered]@{
            RunId                    = $RunId
            InputSerialNumber        = $inputSerial
            NormalizedSerialNumber   = $normalized
            MatchStatus              = $matchStatus
            AmbiguityReason          = $ambiguityReason
            AutopilotIdentityId      = $null
            AutopilotEnrollmentState = $null
            IntuneManagedDeviceId    = if ($intuneMatch) { $intuneMatch.Id } else { $null }
            IntuneDeviceName         = if ($intuneMatch) { & $getSafeValue $intuneMatch 'DeviceName' } else { $null }
            EntraObjectId            = if ($entraMatch) { $entraMatch.Id } else { $null }
            EntraDeviceName          = if ($entraMatch) { & $getSafeValue $entraMatch 'DisplayName' } else { $null }
            AutopilotRemovalStatus   = 'NotAttempted'
            IntuneRemovalStatus      = 'NotAttempted'
            EntraRemovalStatus       = if ($entraMatch) { 'ManualReview' } else { 'NotAttempted' }
            ErrorMessage             = $null
        })
    }

    return , $results
}

#endregion Scrapped device cleanup

#region Deletion (guarded by ShouldProcess)

function Remove-WindowsAutopilotRecord {
    <#
        .SYNOPSIS
        Removes a single Windows Autopilot device identity. Supports
        ShouldProcess; never called for iOS/Android devices.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WindowsAutopilotDeviceIdentityId,
        [string]$LogPath,
        [switch]$SuppressErrorLog
    )

    if ($PSCmdlet.ShouldProcess($WindowsAutopilotDeviceIdentityId, 'Remove Windows Autopilot device identity')) {
        Invoke-GraphWithRetry -OperationName 'Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity' -LogPath $LogPath -SuppressErrorLog:$SuppressErrorLog -ScriptBlock {
            Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $WindowsAutopilotDeviceIdentityId -ErrorAction Stop
        }
        return $true
    }
    return $false
}

function Submit-WindowsAutopilotIdentityRemoval {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [string]$LogPath,
        [string]$ExpectedTenantId
    )

    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $Targets) {
        if ([string]::IsNullOrWhiteSpace([string]$target.IdentityId) -or -not $seenIds.Add([string]$target.IdentityId)) { continue }
        $status = 'RemovalFailed'
        $errorMessage = $null
        if ($PSCmdlet.ShouldProcess($target.IdentityId, 'Remove Windows Autopilot device identity')) {
            try {
                if ($ExpectedTenantId) {
                    Assert-DeviceCleanupContext -TenantId $ExpectedTenantId -RequiredScopes @('DeviceManagementServiceConfig.ReadWrite.All')
                }
                Remove-WindowsAutopilotRecord -WindowsAutopilotDeviceIdentityId $target.IdentityId -LogPath $LogPath -SuppressErrorLog -Confirm:$false | Out-Null
                $status = 'RemovalSubmitted'
            } catch {
                $errorMessage = Get-GraphErrorMessage -ErrorRecord $_
                if ($errorMessage -match 'ZtdDeviceAlreadyDeleted|already been deleted') {
                    $status = 'AlreadyRemoved'
                    $errorMessage = $null
                    if ($LogPath) { Write-CleanupLog -Message "Autopilot identity '$($target.IdentityId)' was already removed; continuing safely." -Level INFO -LogPath $LogPath }
                } elseif ($LogPath) {
                    Write-CleanupLog -Message "Autopilot identity '$($target.IdentityId)' removal failed: $errorMessage" -Level ERROR -LogPath $LogPath
                }
            }
        } else {
            $status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
        }
        $results.Add([PSCustomObject][ordered]@{
                IdentityId   = [string]$target.IdentityId
                SerialNumber = [string]$target.SerialNumber
                Status       = $status
                ErrorMessage = $errorMessage
            })
    }
    return $results.ToArray()
}

function Remove-EntraDeviceRecord {
    <#
        .SYNOPSIS
        Removes a Microsoft Entra ID device object by its Entra object id
        (NOT the physical deviceId). Supports ShouldProcess.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$EntraObjectId,
        [string]$LogPath,
        [ref]$AlreadyRemoved,
        [switch]$SuppressErrorLog
    )

    if ($PSCmdlet.ShouldProcess($EntraObjectId, 'Remove Microsoft Entra ID device object')) {
        try {
            Invoke-GraphWithRetry -OperationName 'Remove-MgDevice' -LogPath $LogPath -SuppressErrorLog -ScriptBlock {
                # Note: Remove-MgDevice's -DeviceId parameter expects the Entra directory object id, not device.deviceId.
                Remove-MgDevice -DeviceId $EntraObjectId -ErrorAction Stop
            }
        } catch {
            $statusCode = if ($_.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') { $_.Exception.ResponseStatusCode } else { $null }
            $errorMessage = Get-GraphErrorMessage -ErrorRecord $_
            if ($statusCode -eq 404 -or $errorMessage -match 'Request_ResourceNotFound') {
                if ($AlreadyRemoved) { $AlreadyRemoved.Value = $true }
                if ($LogPath) {
                    Write-CleanupLog -Message "Entra device object '$EntraObjectId' was already absent; treating removal as complete." -Level INFO -LogPath $LogPath
                }
                return $true
            }

            if ($LogPath -and -not $SuppressErrorLog) {
                Write-CleanupLog -Message "Graph operation 'Remove-MgDevice' failed: $errorMessage" -Level ERROR -LogPath $LogPath
            }
            throw
        }
        return $true
    }
    return $false
}

function Remove-IntuneManagedDeviceRecord {
    <#
        .SYNOPSIS
        Removes a single Intune managed-device record. Only ever called for
        devices explicitly listed as scrapped hardware via the
        -ScrappedDeviceCsvPath workflow; Intune records are never removed by
        the stale-device (activity-based) lifecycle.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ManagedDeviceId,
        [string]$LogPath,
        [ref]$AlreadyRemoved,
        [switch]$SuppressErrorLog
    )

    if ($PSCmdlet.ShouldProcess($ManagedDeviceId, 'Remove Intune managed device')) {
        try {
            Invoke-GraphWithRetry -OperationName 'Remove-MgDeviceManagementManagedDevice' -LogPath $LogPath -SuppressErrorLog -ScriptBlock {
                Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $ManagedDeviceId -ErrorAction Stop
            }
        } catch {
            $statusCode = if ($_.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') { $_.Exception.ResponseStatusCode } else { $null }
            $errorMessage = Get-GraphErrorMessage -ErrorRecord $_
            if ($statusCode -eq 404 -or $errorMessage -match 'Request_ResourceNotFound|ZtdDeviceAlreadyDeleted|already been deleted') {
                if ($AlreadyRemoved) { $AlreadyRemoved.Value = $true }
                if ($LogPath) {
                    Write-CleanupLog -Message "Intune managed device '$ManagedDeviceId' was already absent; treating removal as complete." -Level INFO -LogPath $LogPath
                }
                return $true
            }
            if ($LogPath -and -not $SuppressErrorLog) {
                Write-CleanupLog -Message "Graph operation 'Remove-MgDeviceManagementManagedDevice' failed: $errorMessage" -Level ERROR -LogPath $LogPath
            }
            throw
        }
        return $true
    }
    return $false
}

function Invoke-ScrappedDeviceBatchRemoval {
    <#
        .SYNOPSIS
        Processes each unique matched Intune target once using
        individual retry-enabled Graph requests and records per-target results.
        This is collection processing, not Microsoft Graph JSON batching.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScrappedDeviceRecords,
        [Parameter(Mandatory)][ValidateSet('Intune')][string]$TargetType,
        [string]$ExpectedTenantId,
        [string]$LogPath
    )

    $targetConfiguration = @{ IdProperty = 'IntuneManagedDeviceId'; StatusProperty = 'IntuneRemovalStatus' }
    $targetStates = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $matchedRecords = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')

    foreach ($record in $matchedRecords) {
        $idProperty = $record.PSObject.Properties[$targetConfiguration.IdProperty]
        $statusProperty = $record.PSObject.Properties[$targetConfiguration.StatusProperty]
        $targetId = if ($idProperty) { [string]$idProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($targetId)) {
            if ($statusProperty) { $statusProperty.Value = 'NotApplicable' }
            continue
        }

        if ($targetStates.ContainsKey($targetId)) {
            $statusProperty.Value = $targetStates[$targetId].Status
            $record.ErrorMessage = $targetStates[$targetId].ErrorMessage
            continue
        }

        $action = 'Remove Intune managed device'
        if (-not $PSCmdlet.ShouldProcess($targetId, $action)) {
            $statusProperty.Value = if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
            $targetStates[$targetId] = [PSCustomObject]@{ Status = $statusProperty.Value; ErrorMessage = $record.ErrorMessage }
            continue
        }

        $alreadyRemoved = $false
        try {
            if ($ExpectedTenantId) {
                Assert-DeviceCleanupContext -TenantId $ExpectedTenantId -RequiredScopes @('DeviceManagementManagedDevices.ReadWrite.All')
            }
            $removed = Remove-IntuneManagedDeviceRecord -ManagedDeviceId $targetId -LogPath $LogPath `
                -AlreadyRemoved ([ref]$alreadyRemoved) -SuppressErrorLog -Confirm:$false

            if ($removed -and $alreadyRemoved) {
                $statusProperty.Value = 'AlreadyRemoved'
            } elseif ($removed) {
                $statusProperty.Value = 'Removed'
                if ($LogPath) {
                    Write-CleanupLog -Message "Removed $TargetType device record '$targetId' for scrapped device serial '$($record.InputSerialNumber)'." -Level SUCCESS -LogPath $LogPath
                }
            } else {
                $statusProperty.Value = 'Skipped'
            }
        } catch {
            $statusProperty.Value = 'RemovalFailed'
            $errorMessage = Get-GraphErrorMessage -ErrorRecord $_
            if ($record.ErrorMessage) {
                if ($record.ErrorMessage -notlike "*$errorMessage*") { $record.ErrorMessage = "$($record.ErrorMessage) | $errorMessage" }
            } else {
                $record.ErrorMessage = $errorMessage
            }
            if ($LogPath) {
                Write-CleanupLog -Message "Failed to remove $TargetType device record '$targetId' for scrapped device serial '$($record.InputSerialNumber)': $errorMessage" -Level ERROR -LogPath $LogPath
            }
        }
        $targetStates[$targetId] = [PSCustomObject]@{ Status = $statusProperty.Value; ErrorMessage = $record.ErrorMessage }
    }
}

function Invoke-ScrappedDeviceRemoval {
    <#
        .SYNOPSIS
        Removes unique Intune records before related Autopilot identities.
        Failed Intune prerequisites block deregistration. Entra objects are
        retained for manual review. Only validated Matched records are used.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScrappedDeviceRecords,
        [string]$LogPath,
        [string]$ExpectedTenantId
    )

    $matchedRecords = @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')
    if ($matchedRecords.Count -eq 0) { return }
    $targetCounts = [ordered]@{
        Autopilot = @($matchedRecords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.AutopilotIdentityId) } | Select-Object -ExpandProperty AutopilotIdentityId -Unique).Count
        Intune    = @($matchedRecords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.IntuneManagedDeviceId) } | Select-Object -ExpandProperty IntuneManagedDeviceId -Unique).Count
        Entra     = @($matchedRecords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.EntraObjectId) } | Select-Object -ExpandProperty EntraObjectId -Unique).Count
    }
    $shouldProcess = $PSCmdlet.ShouldProcess(
        "Autopilot=$($targetCounts.Autopilot), Intune=$($targetCounts.Intune) unique target(s); Entra=$($targetCounts.Entra) retained for review",
        'Deregister eligible scrapped Intune and Autopilot device records'
    )
    if (-not $shouldProcess -and -not $WhatIfPreference) {
        foreach ($record in $matchedRecords) {
            if ($record.IntuneManagedDeviceId) { $record.IntuneRemovalStatus = 'Declined' }
            if ($record.AutopilotIdentityId) { $record.AutopilotRemovalStatus = 'Declined' }
            $record.EntraRemovalStatus = if ($record.EntraObjectId) { 'ManualReview' } else { 'NotApplicable' }
        }
        return
    }

    $loggedAutopilotErrorSerials = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Invoke-ScrappedDeviceBatchRemoval -ScrappedDeviceRecords $matchedRecords -TargetType Intune `
        -ExpectedTenantId $ExpectedTenantId -LogPath $LogPath -WhatIf:$WhatIfPreference -Confirm:$false

    $blockedSerials = @($matchedRecords | Where-Object {
        $_.IntuneManagedDeviceId -and $_.IntuneRemovalStatus -notin 'Removed', 'AlreadyRemoved' -and
        -not ($WhatIfPreference -and $_.IntuneRemovalStatus -eq 'WhatIf')
    } | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)
    $autopilotTargets = @($matchedRecords | Where-Object {
        $_.AutopilotIdentityId -and $_.NormalizedSerialNumber -notin $blockedSerials
    } | ForEach-Object {
            [PSCustomObject]@{ IdentityId = $_.AutopilotIdentityId; SerialNumber = $_.InputSerialNumber }
        })
    $identityStates = @{}
    foreach ($identityState in @(Submit-WindowsAutopilotIdentityRemoval -Targets $autopilotTargets -LogPath $LogPath `
        -ExpectedTenantId $ExpectedTenantId -WhatIf:$WhatIfPreference -Confirm:$false)) {
        $identityStates[[string]$identityState.IdentityId] = $identityState
    }

    foreach ($record in $matchedRecords) {
        if ([string]::IsNullOrWhiteSpace([string]$record.AutopilotIdentityId)) {
            $record.AutopilotRemovalStatus = 'NotApplicable'
            continue
        }
        if ($record.NormalizedSerialNumber -in $blockedSerials) {
            $record.AutopilotRemovalStatus = 'BlockedDependency'
            $blockedMessage = 'Autopilot removal was blocked because required Intune removal did not succeed.'
            if ($record.ErrorMessage) {
                if ($record.ErrorMessage -notlike "*$blockedMessage*") { $record.ErrorMessage = "$($record.ErrorMessage) | $blockedMessage" }
            } else {
                $record.ErrorMessage = $blockedMessage
            }
            continue
        }

        if ($WhatIfPreference) {
            $record.AutopilotRemovalStatus = 'WhatIf'
            continue
        }

        $identityState = if ($identityStates.ContainsKey([string]$record.AutopilotIdentityId)) { $identityStates[[string]$record.AutopilotIdentityId] } else { $null }
        if ($identityState -and $identityState.Status -in 'RemovalSubmitted', 'AlreadyRemoved', 'WhatIf') {
            $record.AutopilotRemovalStatus = $identityState.Status
        } else {
            $record.AutopilotRemovalStatus = 'RemovalFailed'
            $autopilotError = if ($identityState -and $identityState.ErrorMessage) { $identityState.ErrorMessage } else { 'Autopilot identity removal was not submitted.' }
            if ($record.ErrorMessage) {
                if ($record.ErrorMessage -notlike "*$autopilotError*") { $record.ErrorMessage = "$($record.ErrorMessage) | $autopilotError" }
            } else {
                $record.ErrorMessage = $autopilotError
            }
            if ($loggedAutopilotErrorSerials.Add([string]$record.NormalizedSerialNumber)) {
                if ($LogPath) {
                    Write-CleanupLog -Message "Autopilot removal was not accepted for serial '$($record.InputSerialNumber)': $($record.ErrorMessage)" -Level ERROR -LogPath $LogPath
                }
            }
        }
    }

    foreach ($record in $matchedRecords) {
        $record.EntraRemovalStatus = if ($record.EntraObjectId) { 'ManualReview' } else { 'NotApplicable' }
    }
}

#endregion Deletion (guarded by ShouldProcess)

#region Execution lifecycle

function Initialize-ProjectExecution {
    <#
        .SYNOPSIS
        Creates the timestamped run directory and returns run context
        (RunId, OutputPath, LogPath, StartTimeUtc).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$OutputPath
    )

    $runId = [Guid]::NewGuid().ToString()
    $startTimeUtc = (Get-Date).ToUniversalTime()
    $runFolderName = $startTimeUtc.ToString('yyyyMMdd-HHmmss')
    $resolvedOutputPath = Join-Path -Path $OutputPath -ChildPath $runFolderName

    New-Item -Path $resolvedOutputPath -ItemType Directory -Force | Out-Null
    $logPath = Join-Path -Path $resolvedOutputPath -ChildPath 'ExecutionLog.txt'
    New-Item -Path $logPath -ItemType File -Force | Out-Null

    return [PSCustomObject]@{
        RunId        = $runId
        OutputPath   = $resolvedOutputPath
        LogPath      = $logPath
        StartTimeUtc = $startTimeUtc
    }
}

function Complete-ProjectExecution {
    <#
        .SYNOPSIS
        Writes the final RunSummary.json and closes out the execution log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$RunSummary,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $summaryPath = Join-Path -Path $OutputPath -ChildPath 'RunSummary.json'
    $RunSummary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding utf8

    Write-CleanupLog -Message "Run completed. ExitCode=$($RunSummary.ExitCode). Summary written to $summaryPath." -Level INFO -LogPath $LogPath
}

#endregion Execution lifecycle

Export-ModuleMember -Function @(
    'Write-CleanupLog',
    'Test-Prerequisites',
    'Connect-DeviceCleanupGraph',
    'Test-GraphPermissions',
    'Invoke-GraphWithRetry',
    'Get-EntraDeviceRecords',
    'Get-IntuneManagedDeviceRecords',
    'Get-WindowsAutopilotRecords',
    'ConvertTo-NormalizedSerialNumber',
    'Get-SafeUtcTimestamp',
    'Resolve-DevicePlatform',
    'New-DeviceIndexes',
    'Resolve-DeviceCorrelation',
    'Get-EffectiveLastActivity',
    'Test-DeviceProtection',
    'Get-StaleDeviceCandidates',
    'Show-CleanupSummary',
    'Show-ScrappedDeviceSummary',
    'Request-DeletionConfirmation',
    'Export-ReportCsv',
    'Export-CleanupReports',
    'New-RunSummary',
    'Get-ScrappedDeviceSerialNumbers',
    'Resolve-ScrappedDeviceRecords',
    'Remove-WindowsAutopilotRecord',
    'Submit-WindowsAutopilotIdentityRemoval',
    'Remove-EntraDeviceRecord',
    'Remove-IntuneManagedDeviceRecord',
    'Invoke-ScrappedDeviceBatchRemoval',
    'Invoke-ScrappedDeviceRemoval',
    'Initialize-ProjectExecution',
    'Complete-ProjectExecution'
    'New-DeviceDeletionPlan'
    'Invoke-DeviceDeletionPlan'
    'Set-DeviceDeletionResults'
    'Test-DeviceDeletionOutcome'
    'Assert-DeviceCleanupContext'
)
