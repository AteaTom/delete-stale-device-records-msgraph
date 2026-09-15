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

            $message = $errorRecord.Exception.Message
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
        if ($ProtectedDeviceNames -contains $Device.DisplayName) {
            return [PSCustomObject]@{ IsProtected = $true; Reason = 'Device name matches the protected device list.' }
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
        [hashtable]$DeviceLifecycleState = @{},
        [int]$DaysDisabled = 30,
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

        $disabledSinceUtc = $null
        $daysDisabled = $null
        $hasDisabledSince = $false
        if ($device.AccountEnabled -eq $false -and $DeviceLifecycleState.ContainsKey([string]$device.Id)) {
            $disabledSinceUtc = Get-SafeUtcTimestamp -Value $DeviceLifecycleState[[string]$device.Id]
            if ($disabledSinceUtc) {
                $daysDisabled = [Math]::Floor(($nowUtc - $disabledSinceUtc).TotalDays)
                $hasDisabledSince = $true
            }
        }

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
            $decision = 'ManualReview'; $reasonCode = 'LowConfidenceMatch'; $reasonDescription = "Autopilot match confidence '$($correlation.MatchConfidence)' is below the High threshold required for automatic Autopilot deletion."
        } elseif ($device.AccountEnabled -eq $false -and $hasDisabledSince -and $daysDisabled -ge $DaysDisabled) {
            $decision = 'Candidate'; $reasonCode = 'DisabledForThreshold'; $reasonDescription = "Device has been disabled for at least $DaysDisabled day(s)."; $entraAction = 'Remove'
        } elseif ($device.AccountEnabled -eq $false) {
            $decision = 'Excluded'; $reasonCode = 'DisabledTracking'; $reasonDescription = 'Device is disabled and has not yet reached the configured disabled-device retention period.'
        } elseif (-not $activity.EffectiveLastActivityUtc) {
            $decision = 'ManualReview'; $reasonCode = 'MissingAllActivity'; $reasonDescription = 'No authoritative activity timestamp (Intune lastSyncDateTime or Entra approximateLastSignInDateTime) is available.'
        } elseif ($activity.EffectiveLastActivityUtc -gt $CutoffDateUtc) {
            $decision = 'Excluded'; $reasonCode = 'RecentActivityDetected'; $reasonDescription = 'Effective last activity is newer than the inactivity threshold.'
        } elseif ($device.OnPremisesSyncEnabled -eq $true -and -not $AllowOnPremisesSyncedDeletion) {
            $decision = 'Excluded'; $reasonCode = 'ProtectedDevice'; $reasonDescription = 'Device is synchronized from on-premises Active Directory and is protected by default.'
        } else {
            $decision = 'Candidate'; $reasonCode = 'Stale'; $reasonDescription = 'Effective last activity is older than or equal to the configured inactivity threshold.'; $entraAction = 'Disable'
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
            DisabledSinceUtc                        = $disabledSinceUtc
            DaysDisabled                            = $daysDisabled
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
        [int]$DaysDisabled = 30,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $candidates = $EvaluatedDevices | Where-Object Decision -eq 'Candidate'
    $windowsWithAutopilot = @($candidates | Where-Object { $_.Platform -eq 'Windows' -and $_.AutopilotPresent })
    $windowsWithoutAutopilot = @($candidates | Where-Object { $_.Platform -eq 'Windows' -and -not $_.AutopilotPresent })
    $ios = @($candidates | Where-Object Platform -eq 'iOS')
    $android = @($candidates | Where-Object Platform -eq 'Android')
    $toDisable = @($candidates | Where-Object EntraAction -eq 'Disable')
    $toRemove = @($candidates | Where-Object EntraAction -eq 'Remove')

    $excluded = $EvaluatedDevices | Where-Object Decision -eq 'Excluded'
    $manualReview = $EvaluatedDevices | Where-Object Decision -eq 'ManualReview'

    Write-Host ''
    Write-Host 'Stale-device cleanup summary'
    Write-Host "Cutoff date UTC: $($CutoffDateUtc.ToString('o'))"
    Write-Host "Inactivity threshold: $DaysInactive days"
    Write-Host "Disabled-device retention: $DaysDisabled days"
    Write-Host ''
    Write-Host 'Deletion candidates:'
    Write-Host ("  Windows with Autopilot:       {0}" -f $windowsWithAutopilot.Count)
    Write-Host ("  Windows without Autopilot:    {0}" -f $windowsWithoutAutopilot.Count)
    Write-Host ("  iOS:                          {0}" -f $ios.Count)
    Write-Host ("  Android:                      {0}" -f $android.Count)
    Write-Host ("  Entra objects to disable:     {0}" -f $toDisable.Count)
    Write-Host ("  Entra objects to remove:      {0}" -f $toRemove.Count)
    Write-Host ("  Autopilot records to remove:  {0}" -f $windowsWithAutopilot.Count)
    Write-Host ''
    Write-Host 'Excluded or manual review:'
    Write-Host ("  Missing all activity:         {0}" -f @($manualReview | Where-Object ReasonCode -eq 'MissingAllActivity').Count)
    Write-Host ("  Ambiguous matches:            {0}" -f @($manualReview | Where-Object { $_.ReasonCode -in 'AmbiguousAutopilotMatch', 'DuplicateSerialNumber' }).Count)
    Write-Host ("  Protected devices:            {0}" -f @($excluded | Where-Object ReasonCode -eq 'ProtectedDevice').Count)
    Write-Host ("  Server / unsupported:         {0}" -f @($excluded | Where-Object ReasonCode -eq 'UnsupportedPlatform').Count)
    Write-Host ("  Recent activity detected:     {0}" -f @($excluded | Where-Object ReasonCode -eq 'RecentActivityDetected').Count)
    Write-Host ("  Missing operating system:     {0}" -f @($manualReview | Where-Object ReasonCode -eq 'MissingOperatingSystem').Count)
    Write-Host ''
    Write-Host "Reports have been written to:"
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
        [Parameter(Mandatory)][string]$Path
    )

    $items = @($InputObject | Where-Object { $_ })
    if ($items.Count -gt 0) {
        $items | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    } else {
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }
}

function Get-DeviceLifecycleState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$StatePath
    )

    $state = @{}
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $state
    }

    $content = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $state
    }

    $parsed = $content | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in $parsed.PSObject.Properties) {
        $state[$property.Name] = [string]$property.Value.DisabledSinceUtc
    }
    return $state
}

function Save-DeviceLifecycleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    $parentPath = Split-Path -Parent $StatePath
    if ($parentPath) {
        New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
    }

    $serialized = [ordered]@{}
    foreach ($key in ($State.Keys | Sort-Object)) {
        $serialized[$key] = [ordered]@{ DisabledSinceUtc = $State[$key] }
    }
    $serialized | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding utf8
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

    Export-ReportCsv -InputObject $AllEvaluatedDevices -Path (Join-Path $OutputPath 'AllEvaluatedDevices.csv')
    Export-ReportCsv -InputObject $candidates -Path (Join-Path $OutputPath 'DeletionCandidates.csv')
    Export-ReportCsv -InputObject $deleted -Path (Join-Path $OutputPath 'DeletedDevices.csv')
    Export-ReportCsv -InputObject $manualReview -Path (Join-Path $OutputPath 'UnknownDevices.csv')
    Export-ReportCsv -InputObject $ambiguous -Path (Join-Path $OutputPath 'AmbiguousMatches.csv')
    Export-ReportCsv -InputObject $excluded -Path (Join-Path $OutputPath 'ExcludedDevices.csv')
    Export-ReportCsv -InputObject $errors -Path (Join-Path $OutputPath 'ErrorDevices.csv')
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
        [int]$DaysDisabled = 30,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllEvaluatedDevices,
        [bool]$WhatIfMode = $false,
        [bool]$ConfirmationGranted = $false,
        [bool]$DiscoveryComplete = $true,
        [int]$ExitCode = 0
    )

    $candidates = @($AllEvaluatedDevices | Where-Object Decision -eq 'Candidate')
    $excluded = @($AllEvaluatedDevices | Where-Object Decision -eq 'Excluded')
    $manualReview = @($AllEvaluatedDevices | Where-Object Decision -eq 'ManualReview')
    $toDisable = @($AllEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.PSObject.Properties['EntraAction'] -and $_.EntraAction -eq 'Disable' })
    $toRemove = @($AllEvaluatedDevices | Where-Object { $_.Decision -eq 'Candidate' -and $_.PSObject.Properties['EntraAction'] -and $_.EntraAction -eq 'Remove' })
    $disabledEntra = @($AllEvaluatedDevices | Where-Object { $_.PSObject.Properties['EntraDisableStatus'] -and $_.EntraDisableStatus -eq 'Disabled' })
    $deletedEntra = @($AllEvaluatedDevices | Where-Object EntraRemovalStatus -eq 'Removed')
    $deletedAutopilot = @($AllEvaluatedDevices | Where-Object AutopilotRemovalStatus -in 'Removed', 'AlreadyRemoved')
    $errors = @($AllEvaluatedDevices | Where-Object { $_.ErrorMessage })

    return [PSCustomObject][ordered]@{
        RunId                     = $RunId
        Mode                      = $Mode
        WhatIfMode                = $WhatIfMode
        StartTimeUtc              = $StartTimeUtc.ToString('o')
        EndTimeUtc                = $EndTimeUtc.ToString('o')
        CutoffDateUtc             = $CutoffDateUtc.ToString('o')
        DaysInactiveThreshold     = $DaysInactive
        DaysDisabledThreshold     = $DaysDisabled
        DiscoveryComplete         = $DiscoveryComplete
        TotalEvaluated            = $AllEvaluatedDevices.Count
        TotalCandidates           = $candidates.Count
        TotalExcluded             = $excluded.Count
        TotalManualReview         = $manualReview.Count
        TotalEntraDevicesToDisable = $toDisable.Count
        TotalEntraDevicesToRemove  = $toRemove.Count
        TotalEntraDevicesDisabled  = $disabledEntra.Count
        TotalEntraDevicesRemoved  = $deletedEntra.Count
        TotalAutopilotRemoved     = $deletedAutopilot.Count
        TotalErrors               = $errors.Count
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
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Scrapped device file '$Path' was not found."
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
    $serials = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($line in $lines) {
        $value = $line.Trim().Trim(',').Trim('"').Trim()
        if (-not $value) { continue }
        if ($value.ToLowerInvariant() -in @('serialnumber', 'serial number', 'serial')) { continue }
        $key = $value.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $serials.Add($value)
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
        [Parameter(Mandatory)][string]$RunId
    )

    $intuneBySerial = @{}
    foreach ($d in $IntuneDevices) {
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

        $matchStatus = 'NotFound'
        $ambiguityReason = $null
        if ($autopilotMatches.Count -gt 1 -or $intuneMatches.Count -gt 1 -or $entraMatches.Count -gt 1) {
            $matchStatus = 'Ambiguous'
            $ambiguityReason = 'DuplicateSerialNumber'
        } elseif ($autopilotMatches.Count -eq 1 -or $intuneMatches.Count -eq 1 -or $entraMatches.Count -eq 1) {
            $matchStatus = 'Matched'
        }

        $autopilotMatch = if ($autopilotMatches.Count -eq 1) { $autopilotMatches[0] } else { $null }
        $intuneMatch = if ($intuneMatches.Count -eq 1) { $intuneMatches[0] } else { $null }
        $entraMatch = if ($entraMatches.Count -eq 1) { $entraMatches[0] } else { $null }

        $results.Add([PSCustomObject][ordered]@{
            RunId                    = $RunId
            InputSerialNumber        = $inputSerial
            NormalizedSerialNumber   = $normalized
            MatchStatus              = $matchStatus
            AmbiguityReason          = $ambiguityReason
            AutopilotIdentityId      = if ($autopilotMatch) { $autopilotMatch.Id } else { $null }
            AutopilotEnrollmentState = if ($autopilotMatch) { $autopilotMatch.EnrollmentState } else { $null }
            IntuneManagedDeviceId    = if ($intuneMatch) { $intuneMatch.Id } else { $null }
            IntuneDeviceName         = if ($intuneMatch) { $intuneMatch.DeviceName } else { $null }
            EntraObjectId            = if ($entraMatch) { $entraMatch.Id } else { $null }
            EntraDeviceName          = if ($entraMatch) { $entraMatch.DisplayName } else { $null }
            AutopilotRemovalStatus   = 'NotAttempted'
            IntuneRemovalStatus      = 'NotAttempted'
            EntraRemovalStatus       = 'NotAttempted'
            ErrorMessage             = $null
        })
    }

    return , $results
}

#endregion Scrapped device cleanup

#region Deletion (guarded by ShouldProcess)

function Disable-EntraDeviceRecord {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$EntraObjectId,
        [string]$LogPath
    )

    if ($PSCmdlet.ShouldProcess($EntraObjectId, 'Disable Microsoft Entra ID device object')) {
        $body = @{ accountEnabled = $false }
        Invoke-GraphWithRetry -OperationName 'Update-MgDevice' -LogPath $LogPath -ScriptBlock {
            Update-MgDevice -DeviceId $EntraObjectId -BodyParameter $body -ErrorAction Stop
        }
        return $true
    }
    return $false
}

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

function Wait-WindowsAutopilotRemoval {
    <#
        .SYNOPSIS
        Polls Graph with bounded, increasing delay until the Autopilot
        identity is confirmed removed (Graph returns not-found), or gives up.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WindowsAutopilotDeviceIdentityId,
        [int]$MaxAttempts = 6,
        [int]$InitialDelaySeconds = 5,
        [string]$LogPath
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $delay = [Math]::Min(60, $InitialDelaySeconds * [Math]::Pow(2, $attempt - 1))
        Start-Sleep -Seconds $delay
        try {
            Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $WindowsAutopilotDeviceIdentityId -ErrorAction Stop | Out-Null
            if ($LogPath) { Write-CleanupLog -Message "Autopilot identity '$WindowsAutopilotDeviceIdentityId' still present after attempt $attempt of $MaxAttempts." -Level DEBUG -LogPath $LogPath }
        } catch {
            if ($LogPath) { Write-CleanupLog -Message "Autopilot identity '$WindowsAutopilotDeviceIdentityId' confirmed removed after attempt $attempt." -Level SUCCESS -LogPath $LogPath }
            return $true
        }
    }
    return $false
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
        [string]$LogPath
    )

    if ($PSCmdlet.ShouldProcess($EntraObjectId, 'Remove Microsoft Entra ID device object')) {
        Invoke-GraphWithRetry -OperationName 'Remove-MgDevice' -LogPath $LogPath -ScriptBlock {
            # Note: Remove-MgDevice's -DeviceId parameter expects the Entra directory object id, not device.deviceId.
            Remove-MgDevice -DeviceId $EntraObjectId -ErrorAction Stop
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
        [string]$LogPath
    )

    if ($PSCmdlet.ShouldProcess($ManagedDeviceId, 'Remove Intune managed device')) {
        Invoke-GraphWithRetry -OperationName 'Remove-MgDeviceManagementManagedDevice' -LogPath $LogPath -ScriptBlock {
            Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $ManagedDeviceId -ErrorAction Stop
        }
        return $true
    }
    return $false
}

function Invoke-ScrappedDeviceRemoval {
    <#
        .SYNOPSIS
        Removes the Autopilot, Intune, and Entra records for each Matched
        scrapped-device record, in that order. Entra removal is skipped for a
        device whose Autopilot removal could not be confirmed, mirroring the
        Autopilot-first safety rule used for stale-device removal. Ambiguous
        and NotFound records are left untouched.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScrappedDeviceRecords,
        [string]$LogPath,
        [int]$AutopilotDeletionRetryAttempts = 3,
        [int]$AutopilotDeletionRetryDelaySeconds = 30
    )

    foreach ($record in @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Matched')) {
        try {
            $autopilotBlocking = $false

            if ($record.AutopilotIdentityId) {
                Write-CleanupLog -Message "Removing Autopilot identity '$($record.AutopilotIdentityId)' for scrapped device serial '$($record.InputSerialNumber)'." -Level INFO -LogPath $LogPath
                $alreadyRemoved = $false
                try {
                    Remove-WindowsAutopilotRecord -WindowsAutopilotDeviceIdentityId $record.AutopilotIdentityId -LogPath $LogPath -SuppressErrorLog -WhatIf:$WhatIfPreference -Confirm:$false | Out-Null
                } catch {
                    if ($_.Exception.Message -match 'ZtdDeviceAlreadyDeleted|already been deleted') {
                        $alreadyRemoved = $true
                    } elseif ($_.Exception.Message -notmatch 'ZtdDeviceDeletionInProgess|currently in progress') {
                        throw
                    }
                }

                if ($WhatIfPreference) {
                    $record.AutopilotRemovalStatus = 'WhatIf'
                } elseif ($alreadyRemoved) {
                    $record.AutopilotRemovalStatus = 'AlreadyRemoved'
                    Write-CleanupLog -Message "Autopilot deletion confirmed for '$($record.AutopilotIdentityId)'." -Level SUCCESS -LogPath $LogPath
                } else {
                    $confirmed = $false
                    for ($attempt = 1; $attempt -le $AutopilotDeletionRetryAttempts; $attempt++) {
                        if ($attempt -gt 1) {
                            Write-CleanupLog -Message "Waiting $AutopilotDeletionRetryDelaySeconds second(s) before Autopilot deletion confirmation attempt $attempt of $AutopilotDeletionRetryAttempts for '$($record.AutopilotIdentityId)'." -Level DEBUG -LogPath $LogPath
                            Start-Sleep -Seconds $AutopilotDeletionRetryDelaySeconds
                        }
                        try {
                            Remove-WindowsAutopilotRecord -WindowsAutopilotDeviceIdentityId $record.AutopilotIdentityId -LogPath $LogPath -SuppressErrorLog -Confirm:$false | Out-Null
                        } catch {
                            if ($_.Exception.Message -match 'ZtdDeviceAlreadyDeleted|already been deleted') {
                                $confirmed = $true
                                break
                            } elseif ($_.Exception.Message -notmatch 'ZtdDeviceDeletionInProgess|currently in progress') {
                                throw
                            }
                        }
                    }

                    if ($confirmed) {
                        $record.AutopilotRemovalStatus = 'AlreadyRemoved'
                        Write-CleanupLog -Message "Autopilot deletion confirmed for '$($record.AutopilotIdentityId)'." -Level SUCCESS -LogPath $LogPath
                    } else {
                        $record.AutopilotRemovalStatus = 'RemovalUnconfirmed'
                        $record.ErrorMessage = 'Autopilot removal was accepted but could not be confirmed within the retry budget.'
                        $autopilotBlocking = $true
                        Write-CleanupLog -Message "Autopilot removal for '$($record.AutopilotIdentityId)' could not be confirmed; Intune and Entra removal skipped for serial '$($record.InputSerialNumber)'." -Level ERROR -LogPath $LogPath
                    }
                }
            } else {
                $record.AutopilotRemovalStatus = 'NotApplicable'
            }

            if ($record.IntuneManagedDeviceId) {
                if ($autopilotBlocking) {
                    $record.IntuneRemovalStatus = 'SkippedAutopilotNotRemoved'
                } else {
                    $intuneRemoved = Remove-IntuneManagedDeviceRecord -ManagedDeviceId $record.IntuneManagedDeviceId -LogPath $LogPath -WhatIf:$WhatIfPreference -Confirm:$false
                    if ($WhatIfPreference) {
                        $record.IntuneRemovalStatus = 'WhatIf'
                    } elseif ($intuneRemoved) {
                        $record.IntuneRemovalStatus = 'Removed'
                        Write-CleanupLog -Message "Removed Intune managed device '$($record.IntuneManagedDeviceId)' for scrapped device serial '$($record.InputSerialNumber)'." -Level SUCCESS -LogPath $LogPath
                    } else {
                        $record.IntuneRemovalStatus = 'Skipped'
                    }
                }
            } else {
                $record.IntuneRemovalStatus = 'NotApplicable'
            }

            if ($record.EntraObjectId) {
                if ($autopilotBlocking) {
                    $record.EntraRemovalStatus = 'SkippedAutopilotNotRemoved'
                } else {
                    $entraRemoved = Remove-EntraDeviceRecord -EntraObjectId $record.EntraObjectId -LogPath $LogPath -WhatIf:$WhatIfPreference -Confirm:$false
                    if ($WhatIfPreference) {
                        $record.EntraRemovalStatus = 'WhatIf'
                    } elseif ($entraRemoved) {
                        $record.EntraRemovalStatus = 'Removed'
                        Write-CleanupLog -Message "Removed Entra device object '$($record.EntraObjectId)' for scrapped device serial '$($record.InputSerialNumber)'." -Level SUCCESS -LogPath $LogPath
                    } else {
                        $record.EntraRemovalStatus = 'Skipped'
                    }
                }
            } else {
                $record.EntraRemovalStatus = 'NotApplicable'
            }
        } catch {
            $record.ErrorMessage = $_.Exception.Message
            Write-CleanupLog -Message "Failed to process scrapped device serial '$($record.InputSerialNumber)': $($_.Exception.Message)" -Level ERROR -LogPath $LogPath
        }
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
    'Request-DeletionConfirmation',
    'Export-ReportCsv',
    'Get-DeviceLifecycleState',
    'Save-DeviceLifecycleState',
    'Export-CleanupReports',
    'New-RunSummary',
    'Get-ScrappedDeviceSerialNumbers',
    'Resolve-ScrappedDeviceRecords',
    'Disable-EntraDeviceRecord',
    'Remove-WindowsAutopilotRecord',
    'Wait-WindowsAutopilotRemoval',
    'Remove-EntraDeviceRecord',
    'Remove-IntuneManagedDeviceRecord',
    'Invoke-ScrappedDeviceRemoval',
    'Initialize-ProjectExecution',
    'Complete-ProjectExecution'
)
