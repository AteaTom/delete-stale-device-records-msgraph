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
        [ValidateSet('DEBUG', 'VERBOSE', 'INFO', 'WARNING', 'ERROR', 'SUCCESS')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$LogPath
    )

    $Message = ConvertTo-CleanupLogText -Text $Message -EscapeLine
    if ($Level -eq 'DEBUG') { Write-Debug $Message; return }
    if ($Level -eq 'VERBOSE') { Write-Verbose $Message; return }
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction Stop
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

function ConvertTo-CleanupLogText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text, [switch]$EscapeLine)

    $textValue = [regex]::Replace([string]$Text, '(?i)\bBearer\s+[^\s",;]+', '[REDACTED]')
    $textValue = [regex]::Replace($textValue,
        '(?i)((?:access_token|refresh_token|client_secret|password|authorization)\s*["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:''''|[^''])*''|[^\s"'',;}]+)',
        '$1[REDACTED]')
    if ($EscapeLine) {
        return $textValue.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    }
    return $textValue
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

    Write-CleanupLog -Message "Connecting to Microsoft Graph (requested scopes: $($Scopes -join ', '))." -Level VERBOSE -LogPath $LogPath
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

function Get-GraphResponseErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Body)

    if ($Body -is [string]) {
        try {
            $Body = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
        } catch {
            Write-Debug 'Graph error detail is not valid JSON; raw response omitted.'
            return 'Unparseable Graph error detail (raw response omitted).'
        }
    }
    $errorBody = if ($Body -is [System.Collections.IDictionary]) { $Body['error'] }
        elseif ($Body.PSObject.Properties['error']) { $Body.error }
    if (-not $errorBody) { return 'Graph response body omitted (no error code/message).' }
    $details = @(
        foreach ($field in 'code', 'message') {
            $value = if ($errorBody -is [System.Collections.IDictionary]) { $errorBody[$field] }
                elseif ($errorBody.PSObject.Properties[$field]) { $errorBody.$field }
            if ($value -is [string] -and $value) { $value }
        }
    )
    if (-not $details.Count) { return 'Graph response body omitted (no error code/message).' }
    return ConvertTo-CleanupLogText -Text ($details -join ': ')
}

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
        if ($detail.StartsWith('{') -or $detail.StartsWith('[')) {
            $detail = Get-GraphResponseErrorText -Body $detail
        }
        if ($detail -and -not $messages.Contains($detail)) { $messages.Add($detail) }
    }

    if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try {
            $content = $ErrorRecord.Exception.Response.Content
            if ($content) {
                $responseBody = $content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($responseBody) {
                    $responseBody = Get-GraphResponseErrorText -Body $responseBody.Trim()
                    if (-not $messages.Contains($responseBody)) { $messages.Add($responseBody) }
                }
            }
        } catch {
            Write-Verbose "Could not read Graph response body: $($_.Exception.Message)"
        }
    }

    return ConvertTo-CleanupLogText -Text ($messages -join ' | ')
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
                    $errorRecord.Exception.Data['CleanupErrorLogged'] = $true
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

    Write-CleanupLog -Message 'Retrieving Microsoft Entra ID device records.' -Level VERBOSE -LogPath $LogPath
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

    Write-CleanupLog -Message 'Retrieving Intune managed-device records.' -Level VERBOSE -LogPath $LogPath
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

    Write-CleanupLog -Message 'Retrieving Windows Autopilot device identity records.' -Level VERBOSE -LogPath $LogPath
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
        [bool]$Simulation = $false
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
    Write-Host "Mode: $Mode; WhatIf: $Simulation"
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
        [bool]$Simulation = $false
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
    Write-Host "Mode: $Mode; WhatIf: $Simulation"
    Write-Host 'Inactivity threshold: Not used for this workflow.'
    if ($Mode -eq 'Audit' -or $Simulation) { Write-Host 'No tenant DELETE requests will be sent.' }
    Write-Host ("  Unique input serial numbers:   {0}" -f $inputSerials.Count)
    Write-Host ("  Duplicate CSV rows ignored:    {0}" -f $CsvDuplicateCount)
    Write-Host ("  Matched serial numbers:        {0}" -f $matchedSerials.Count)
    Write-Host ("  Serials with DELETE targets:   {0}" -f @($matchedRecords | Where-Object {
        $_.IntuneManagedDeviceId -or $_.AutopilotIdentityId -or $_.EntraObjectId
    } | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count)
    Write-Host ''
    Write-Host 'Planned DELETE operations (unique records, not physical devices):'
    Write-Host ("  Autopilot records:             {0}" -f $autopilotIds.Count)
    Write-Host ("  Intune managed devices:        {0}" -f $intuneIds.Count)
    Write-Host ("  Entra objects to remove:       {0}" -f $entraIds.Count)
    Write-Host ("  Total DELETE operations:       {0}" -f ($intuneIds.Count + $autopilotIds.Count + $entraIds.Count))
    Write-Host 'Order: Intune, Autopilot, Entra; failed dependencies block related targets.'
    Write-Host 'Entra removal continues after all related Autopilot DELETE requests are accepted.'
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
    $autopilotProtected = @($excluded | Where-Object { $_.PSObject.Properties['ReasonCode'] -and $_.ReasonCode -eq 'AutopilotProtected' })
    $otherExcluded = @($excluded | Where-Object { -not $_.PSObject.Properties['ReasonCode'] -or $_.ReasonCode -notin 'OnPremisesSyncProtected', 'AutopilotProtected' })
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
        'Decision', 'ReasonCode', 'ReasonDescription', 'MatchMethod', 'EntraAction', 'EntraRemovalStatus', 'ErrorMessage'
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
    Export-ReportCsv -InputObject $otherExcluded -Path (Join-Path $OutputPath 'ExcludedDevices.csv')
    Export-ReportCsv -InputObject $errors -Path (Join-Path $OutputPath 'ErrorDevices.csv')
    Export-ReportCsv -InputObject $onPremisesSyncReview -Headers $onPremisesReviewHeaders -Path (Join-Path $OutputPath 'OnPremisesSyncedReview.csv')
    Export-ReportCsv -InputObject $onPremisesSyncReview -Headers $onPremisesReviewHeaders -Path (Join-Path $OutputPath 'ADSyncedDevices.csv')
    $protectionFields = @(
        'RunId', 'EvaluationTimestampUtc', 'DeviceName', 'Platform', 'EntraObjectId', 'EntraDeviceId',
        'IntuneManagedDeviceId', 'IntuneSerialNumber', 'AutopilotIdentityId', 'AutopilotSerialNumber',
        'OnPremisesSyncEnabled', 'AutopilotPresent', 'MatchStatus', 'MatchMethod', 'MatchConfidence',
        'EffectiveLastActivityUtc', 'ActivitySource', 'DaysInactive', 'CutoffDateUtc',
        'Decision', 'ReasonCode', 'ReasonDescription', 'EntraAction', 'EntraRemovalStatus', 'ErrorMessage'
    )
    Export-ReportCsv -InputObject @($autopilotProtected | Select-Object -Property $protectionFields) `
        -Headers $protectionFields -Path (Join-Path $OutputPath 'AutopilotProtectedDevices.csv')
}

function Get-CleanupActionRecords {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()][PSCustomObject]$Plan,
        [AllowEmptyCollection()][object[]]$Results = @(),
        [AllowEmptyCollection()][object[]]$Records = @()
    )

    if (-not $Plan) { return @() }
    $byId = @{}
    foreach ($result in $Results) { $byId[$result.Id] = $result }
    $finalizedUtc = [datetime]::UtcNow.ToString('o')
    foreach ($operation in $Plan.Operations) {
        $idField = switch ($operation.Resource) {
            Entra { 'EntraObjectId' }
            Intune { 'IntuneManagedDeviceId' }
            Autopilot { 'AutopilotIdentityId' }
        }
        $related = @($Records | Where-Object { $_.PSObject.Properties[$idField] -and $_.$idField -eq $operation.ObjectId })
        $names = @(
            foreach ($row in $related) {
                foreach ($field in 'DeviceName', 'EntraDeviceName', 'IntuneDeviceName') {
                    if ($row.PSObject.Properties[$field] -and $row.$field) { $row.$field }
                }
            }
        )
        $serials = @(
            foreach ($row in $related) {
                foreach ($field in 'IntuneSerialNumber', 'AutopilotSerialNumber', 'InputSerialNumber') {
                    if ($row.PSObject.Properties[$field] -and $row.$field) { $row.$field }
                }
            }
        )
        $deviceIds = @($related | Where-Object { $_.PSObject.Properties['EntraDeviceId'] -and $_.EntraDeviceId } |
            Select-Object -ExpandProperty EntraDeviceId -Unique)
        $result = $byId[$operation.Id]
        [PSCustomObject][ordered]@{
            RunId = $Plan.RunId
            Workflow = $Plan.Workflow
            FinalizedTimestampUtc = $finalizedUtc
            OperationId = $operation.Id
            Resource = $operation.Resource
            ObjectId = $operation.ObjectId
            DeviceName = (@($names | Sort-Object -Unique) -join '; ')
            EntraDeviceId = ($deviceIds -join '; ')
            SerialNumber = (@($serials | Sort-Object -Unique) -join '; ')
            Action = 'Delete'
            ReasonCode = if ($Plan.Workflow -eq 'Stale') { 'Stale' } else { 'ExplicitScrappedCleanup' }
            Outcome = if ($result) { $result.Status } else { 'NotAttempted' }
            Attempts = if ($result) { $result.Attempts } else { 0 }
            HttpStatus = if ($result -and $result.HttpStatus) { $result.HttpStatus } else { $null }
            VerificationStatus = if ($result) { $result.VerificationStatus } else { 'NotRequested' }
            ErrorMessage = if ($result) { ConvertTo-CleanupLogText -Text $result.ErrorMessage } else { '' }
        }
    }
}

function New-RunSummary {
    <#
        .SYNOPSIS
        Builds the RunSummary.json object describing the outcome of a run.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Inactivity')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][datetime]$StartTimeUtc,
        [datetime]$EndTimeUtc = (Get-Date).ToUniversalTime(),
        [Parameter(Mandatory, ParameterSetName = 'Inactivity')][datetime]$CutoffDateUtc,
        [Parameter(Mandatory, ParameterSetName = 'Inactivity')][int]$DaysInactive,
        [Parameter(Mandatory, ParameterSetName = 'Scrapped')][switch]$ScrappedDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllEvaluatedDevices,
        [AllowEmptyCollection()][object[]]$ScrappedDeviceRecords = @(),
        [AllowEmptyCollection()][object[]]$ActionRecords = @(),
        [string]$TenantId = '',
        [ValidateRange(0, [int]::MaxValue)][int]$RunErrorCount = 0,
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
    $scrappedAlreadyRemovedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -in 'AlreadyRemoved', 'AlreadyAbsent' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedFailedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -eq 'RemovalFailed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedBlockedEntra = @($ScrappedDeviceRecords | Where-Object { $_.EntraRemovalStatus -in 'BlockedDependency', 'SkippedAutopilotSubmissionFailed' -and $_.EntraObjectId } | Select-Object -ExpandProperty EntraObjectId -Unique)
    $scrappedErrorSerials = @($ScrappedDeviceRecords | Where-Object { $_.ErrorMessage -and $_.NormalizedSerialNumber } | Select-Object -ExpandProperty NormalizedSerialNumber -Unique)

    $summary = [ordered]@{
        RunId                     = $RunId
        TenantId                  = $TenantId
        Mode                      = $Mode
        WhatIfMode                = $WhatIfMode
        StartTimeUtc              = $StartTimeUtc.ToString('o')
        EndTimeUtc                = $EndTimeUtc.ToString('o')
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
        ScrappedWorkflow          = ([bool]$ScrappedDevices -or $ScrappedDeviceRecords.Count -gt 0)
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
        TotalRunErrors            = $RunErrorCount
    }
    $summary.TotalADSyncedDevices = $onPremisesSyncReview.Count
    $summary.TotalAutopilotProtectedDevices = @($excluded | Where-Object { $_.PSObject.Properties['ReasonCode'] -and $_.ReasonCode -eq 'AutopilotProtected' }).Count
    $summary.TotalOtherExcludedDevices = $excluded.Count - $summary.TotalADSyncedDevices - $summary.TotalAutopilotProtectedDevices
    $summary.ExclusionsByReason = [ordered]@{}
    $reasonGroup = { if ($_.PSObject.Properties['ReasonCode'] -and -not [string]::IsNullOrWhiteSpace($_.ReasonCode)) { $_.ReasonCode } else { 'MissingReasonCode' } }
    foreach ($group in @($excluded | Group-Object -Property $reasonGroup | Sort-Object Name)) {
        $summary.ExclusionsByReason[$group.Name] = $group.Count
    }
    $summary.ManualReviewByReason = [ordered]@{}
    foreach ($group in @($manualReview | Group-Object -Property $reasonGroup | Sort-Object Name)) {
        $summary.ManualReviewByReason[$group.Name] = $group.Count
    }
    $summary.ScrappedExclusionsByReason = [ordered]@{}
    foreach ($group in @($ScrappedDeviceRecords | Where-Object MatchStatus -eq 'Excluded' | Group-Object AmbiguityReason | Sort-Object Name)) {
        $summary.ScrappedExclusionsByReason[$group.Name] = @($group.Group | Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
    }
    $summary.TotalPlannedActions = $ActionRecords.Count
    $summary.TotalAttemptedActions = @($ActionRecords | Where-Object Attempts -gt 0).Count
    $summary.TotalRetryAttempts = [int](($ActionRecords | ForEach-Object { [Math]::Max(0, $_.Attempts - 1) } | Measure-Object -Sum).Sum)
    $summary.ActionOutcomes = [ordered]@{}
    foreach ($status in 'Removed', 'RemovalSubmitted', 'AlreadyAbsent', 'AlreadyRemoved', 'RemovalFailed',
        'OutcomeUnknown', 'BlockedDependency', 'WhatIf', 'Declined', 'NotAttempted') {
        $summary.ActionOutcomes[$status] = @($ActionRecords | Where-Object Outcome -eq $status).Count
    }
    $summary.ActionsByResource = [ordered]@{}
    foreach ($resource in 'Entra', 'Intune', 'Autopilot') {
        $resourceRows = @($ActionRecords | Where-Object Resource -eq $resource)
        $counts = [ordered]@{ Planned = $resourceRows.Count; Attempted = @($resourceRows | Where-Object Attempts -gt 0).Count }
        foreach ($status in $summary.ActionOutcomes.Keys) {
            $counts[$status] = @($resourceRows | Where-Object Outcome -eq $status).Count
        }
        $summary.ActionsByResource[$resource] = $counts
    }
    $summary.TotalVerificationPending = @($ActionRecords | Where-Object VerificationStatus -eq 'VerificationPending').Count
    $summary.TotalVerificationUnknown = @($ActionRecords | Where-Object VerificationStatus -eq 'OutcomeUnknown').Count
    if ($PSCmdlet.ParameterSetName -eq 'Inactivity') {
        $summary.CutoffDateUtc = $CutoffDateUtc.ToString('o')
        $summary.DaysInactiveThreshold = $DaysInactive
    }
    if ($ScrappedDevices) {
        $summary.TotalScrappedEntraToRemove = $summary.TotalScrappedEntraReview
        $summary.Remove('TotalScrappedEntraReview')
        Set-ScrappedDeviceOutcomes -Records $ScrappedDeviceRecords
        foreach ($outcome in 'Complete', 'Partial', 'Blocked', 'Pending', 'Simulated', 'Excluded', 'NotFound', 'LookupFailed', 'NotAttempted') {
            $summary["TotalScrapped$outcome"] = @($ScrappedDeviceRecords | Where-Object CleanupOutcome -eq $outcome |
                Select-Object -ExpandProperty NormalizedSerialNumber -Unique).Count
        }
    }
    return [PSCustomObject]$summary
}

#endregion Reporting

#region Scrapped device cleanup

function Get-ScrappedDeviceSerialNumbers {
    <#
        .SYNOPSIS
        Reads a SerialNumber-column CSV and returns unique, trimmed serials
        in input order. Headerless text requires explicit AllowLegacyFormat.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ref]$Statistics,
        [switch]$AllowLegacyFormat
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Scrapped device file '$Path' was not found."
    }

    if ($AllowLegacyFormat) {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
    } else {
        $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new((Resolve-Path -LiteralPath $Path).ProviderPath)
        try {
            $parser.SetDelimiters(',')
            $parser.HasFieldsEnclosedInQuotes = $true
            $header = $parser.ReadFields()
            if (-not $header -or @($header | Where-Object { $_.Trim() -eq 'SerialNumber' }).Count -ne 1 -or
                @($header | Sort-Object -Unique).Count -ne $header.Count) {
                throw 'Scrapped CSV must contain a unique SerialNumber column.'
            }
            $serialColumn = [array]::FindIndex($header, [Predicate[string]]{ param($name) $name.Trim() -eq 'SerialNumber' })
            $values = [System.Collections.Generic.List[string]]::new()
            while (-not $parser.EndOfData) {
                $fields = $parser.ReadFields()
                if ($fields.Count -ne $header.Count) { throw 'Scrapped CSV row does not match its header.' }
                $values.Add($fields[$serialColumn])
            }
            $lines = $values.ToArray()
        } finally {
            $parser.Dispose()
        }
    }
    $serials = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $duplicateCount = 0
    foreach ($line in $lines) {
        $value = if ($AllowLegacyFormat) { $line.Trim().Trim(',').Trim('"').Trim() } else { $line.Trim() }
        if (-not $value) { continue }
        if ($AllowLegacyFormat -and $value.ToLowerInvariant() -in @('serialnumber', 'serial number', 'serial')) { continue }
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
        making Graph calls. Multiple records require corroborating stable
        identifiers; conflicting or serial-only collisions fail closed.
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
        [string[]]$ProtectedNamePatterns = @(),
        [switch]$AllowOnPremisesSyncedDeletion
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
    $entraByObjectId = @{}
    foreach ($e in $EntraDevices) {
        if ($e.Id) { $entraByObjectId[[string]$e.Id] = $e }
        if ($e.DeviceId -and $e.DeviceId -ne '00000000-0000-0000-0000-000000000000') {
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
            if ($intuneMatch.AzureAdDeviceId -and $intuneMatch.AzureAdDeviceId -ne '00000000-0000-0000-0000-000000000000') {
                $key = $intuneMatch.AzureAdDeviceId.ToString().ToLowerInvariant()
                if ($entraByDeviceId.ContainsKey($key)) {
                    foreach ($e in $entraByDeviceId[$key]) {
                        if (-not $entraMatchIds.Contains($e.Id)) { $entraMatchIds.Add($e.Id); $entraMatches.Add($e) }
                    }
                }
            }
        }
        foreach ($autopilotMatch in $autopilotMatches) {
            if ($autopilotMatch.AzureActiveDirectoryDeviceId -and $autopilotMatch.AzureActiveDirectoryDeviceId -ne '00000000-0000-0000-0000-000000000000') {
                $key = $autopilotMatch.AzureActiveDirectoryDeviceId.ToString().ToLowerInvariant()
                if ($entraByDeviceId.ContainsKey($key)) {
                    foreach ($e in $entraByDeviceId[$key]) {
                        if (-not $entraMatchIds.Contains($e.Id)) { $entraMatchIds.Add($e.Id); $entraMatches.Add($e) }
                    }
                }
            }
        }

        $exclusion = if (-not $normalized) { 'InvalidSerialNumber' } else { $null }
        $stableIds = @(
            @($intuneMatches | Where-Object AzureAdDeviceId | Select-Object -ExpandProperty AzureAdDeviceId)
            @($autopilotMatches | Where-Object AzureActiveDirectoryDeviceId | Select-Object -ExpandProperty AzureActiveDirectoryDeviceId)
        ) | Where-Object { $_ -and $_ -ne '00000000-0000-0000-0000-000000000000' } | Sort-Object -Unique
        $managedIds = @($intuneMatches | Select-Object -ExpandProperty Id)
        foreach ($related in $AutopilotDevices) {
            if (($related.AzureActiveDirectoryDeviceId -and $related.AzureActiveDirectoryDeviceId -in $stableIds) -or
                ($related.ManagedDeviceId -and $related.ManagedDeviceId -in $managedIds)) {
                if ((ConvertTo-NormalizedSerialNumber $related.SerialNumber) -ne $normalized) { $exclusion = 'ConflictingIdentifiers' }
            }
        }
        foreach ($related in $IntuneDevices) {
            if (($related.AzureAdDeviceId -and $related.AzureAdDeviceId -in $stableIds) -or
                ($related.Id -in @($autopilotMatches | Where-Object ManagedDeviceId | Select-Object -ExpandProperty ManagedDeviceId))) {
                if ((ConvertTo-NormalizedSerialNumber $related.SerialNumber) -ne $normalized) { $exclusion = 'ConflictingIdentifiers' }
            }
        }
        # A managed-device relationship can bridge an Autopilot identity without
        # an Entra reference, but it cannot override a conflicting reference.
        foreach ($autopilotMatch in $autopilotMatches) {
            if ($autopilotMatch.ManagedDeviceId -and $intuneById.ContainsKey([string]$autopilotMatch.ManagedDeviceId)) {
                $linked = $intuneById[[string]$autopilotMatch.ManagedDeviceId]
                if ($autopilotMatch.AzureActiveDirectoryDeviceId -and $linked.AzureAdDeviceId -and
                    $autopilotMatch.AzureActiveDirectoryDeviceId -ne $linked.AzureAdDeviceId) { $exclusion = 'ConflictingIdentifiers' }
            }
        }
        $platforms = @(
            foreach ($device in $entraMatches) { Resolve-DevicePlatform -OperatingSystem $device.OperatingSystem }
            foreach ($device in $intuneMatches) {
                $os = & $getSafeValue $device 'OperatingSystem'
                Resolve-DevicePlatform -OperatingSystem $os
            }
        )
        if (@($platforms | Where-Object { $_ -notin 'Windows', 'iOS', 'Android' }).Count -gt 0) {
            $exclusion = 'UnsupportedOrMissingPlatform'
        } elseif (@($platforms | Sort-Object -Unique).Count -gt 1 -or
            ($autopilotMatches.Count -gt 0 -and @($platforms | Where-Object { $_ -ne 'Windows' }).Count -gt 0)) {
            $exclusion = 'ConflictingPlatform'
        } elseif ($entraMatches.Count -gt 1) {
            $exclusion = 'DuplicateSerialNumber'
        } elseif ($autopilotMatches.Count -gt 1 -or $intuneMatches.Count -gt 1) {
            $references = @(
                foreach ($match in $intuneMatches) { [string]$match.AzureAdDeviceId }
                foreach ($match in $autopilotMatches) {
                    if ($match.AzureActiveDirectoryDeviceId) { [string]$match.AzureActiveDirectoryDeviceId }
                    elseif ($match.ManagedDeviceId -and $intuneById.ContainsKey([string]$match.ManagedDeviceId)) {
                        [string]$intuneById[[string]$match.ManagedDeviceId].AzureAdDeviceId
                    } else { '' }
                }
            )
            if (@($references | Where-Object { -not $_ -or $_ -eq '00000000-0000-0000-0000-000000000000' }).Count -gt 0 -or
                @($references | Sort-Object -Unique).Count -ne 1) {
                $exclusion = if ($autopilotMatches.Count -gt 1) { 'DuplicateAutopilotSerial' } else { 'DuplicateSerialNumber' }
            }
        }
        if (-not $AllowOnPremisesSyncedDeletion -and @($entraMatches | Where-Object {
            $_.PSObject.Properties['OnPremisesSyncEnabled'] -and $_.OnPremisesSyncEnabled
        }).Count -gt 0) { $exclusion = 'OnPremisesSyncProtected' }
        if (@($intuneMatches | Where-Object { -not $_.Id }).Count -gt 0 -or
            @($autopilotMatches | Where-Object { -not $_.Id }).Count -gt 0 -or
            @($entraMatches | Where-Object { -not $_.Id }).Count -gt 0) { $exclusion = 'MissingObjectId' }
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

            foreach ($autopilotMatch in @($autopilotMatches | Sort-Object Id -Unique)) {
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

            $uniqueIntuneMatches = @($intuneMatches | Sort-Object Id -Unique)
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

            $uniqueEntraMatches = @($entraMatches | Sort-Object Id -Unique)
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
                    EntraRemovalStatus       = 'NotAttempted'
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
        if ($intuneMatches.Count -gt 0 -or $entraMatches.Count -gt 0) {
            $matchStatus = 'Matched'
        }

        $entraMatch = if ($entraMatches.Count -eq 1) { $entraMatches[0] } else { $null }
        $recordsToEmit = @($null)
        if ($intuneMatches.Count -gt 0) { $recordsToEmit = $intuneMatches }
        foreach ($intuneMatch in $recordsToEmit) {
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
                EntraRemovalStatus       = 'NotAttempted'
                ErrorMessage             = $null
            })
        }
    }

    foreach ($record in $results) {
        $deviceId = if ($record.EntraObjectId -and $entraByObjectId.ContainsKey([string]$record.EntraObjectId)) {
            $entraByObjectId[[string]$record.EntraObjectId].DeviceId
        } else { $null }
        $record | Add-Member -NotePropertyName EntraDeviceId -NotePropertyValue $deviceId
        $method = if ($record.MatchStatus -ne 'Matched') { 'None' }
        elseif ($record.EntraObjectId) { 'StableDeviceIdReference' }
        else { 'ExactSerialNumber' }
        $record | Add-Member -NotePropertyName CorrelationMethod -NotePropertyValue $method
    }
    return , $results
}

#endregion Scrapped device cleanup

#region Scrapped result handling

function Add-ScrappedDeviceError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Message)
    if (-not $Record.ErrorMessage) { $Record.ErrorMessage = $Message }
    elseif ($Record.ErrorMessage -notlike "*$Message*") { $Record.ErrorMessage += " | $Message" }
}

function Set-ScrappedDeviceOutcomes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)

    foreach ($group in @($Records | Group-Object NormalizedSerialNumber)) {
        $rows = @($group.Group)
        foreach ($row in $rows) {
            if (-not $row.PSObject.Properties['AutopilotVerificationStatus']) {
                $row | Add-Member -NotePropertyName AutopilotVerificationStatus -NotePropertyValue 'NotRequested'
            }
        }
        $statuses = @(
            foreach ($row in $rows) {
                foreach ($service in @(
                    @{ Name = 'Intune'; Id = 'IntuneManagedDeviceId' },
                    @{ Name = 'Autopilot'; Id = 'AutopilotIdentityId' },
                    @{ Name = 'Entra'; Id = 'EntraObjectId' }
                )) {
                    if (-not $row.($service.Id)) { continue }
                    $status = $row.("$($service.Name)RemovalStatus")
                    $verificationProperty = $row.PSObject.Properties["$($service.Name)VerificationStatus"]
                    if ($service.Name -eq 'Autopilot' -and $status -in 'RemovalSubmitted', 'AlreadyRemoved') {
                        'Removed'
                    } elseif ($verificationProperty -and $verificationProperty.Value -in 'OutcomeUnknown', 'VerificationPending') {
                        $verificationProperty.Value
                    } else { $status }
                }
            }
        )
        $outcome = if (@($rows | Where-Object MatchStatus -eq 'LookupFailed').Count) { 'LookupFailed' }
        elseif (@($rows | Where-Object MatchStatus -in 'Ambiguous', 'Excluded').Count) { 'Excluded' }
        elseif (@($rows | Where-Object MatchStatus -eq 'NotFound').Count) { 'NotFound' }
        elseif ($statuses.Count -and @($statuses | Where-Object { $_ -notin 'Removed', 'AlreadyRemoved', 'AlreadyAbsent' }).Count -eq 0) { 'Complete' }
        elseif ($statuses.Count -and @($statuses | Where-Object { $_ -ne 'WhatIf' }).Count -eq 0) { 'Simulated' }
        elseif (@($statuses | Where-Object { $_ -in 'RemovalFailed', 'OutcomeUnknown', 'BlockedDependency', 'Declined', 'Skipped' }).Count) {
            if (@($statuses | Where-Object { $_ -in 'Removed', 'AlreadyRemoved', 'AlreadyAbsent', 'RemovalSubmitted' }).Count) { 'Partial' } else { 'Blocked' }
        } elseif ($statuses -contains 'RemovalSubmitted' -or $statuses -contains 'VerificationPending') { 'Pending' }
        else { 'NotAttempted' }
        foreach ($row in $rows) {
            $row | Add-Member -NotePropertyName CleanupOutcome -NotePropertyValue $outcome -Force
            foreach ($service in @(
                @{ Name = 'Intune'; Field = 'IntuneManagedDeviceId' },
                @{ Name = 'Autopilot'; Field = 'AutopilotIdentityId' },
                @{ Name = 'Entra'; Field = 'EntraObjectId' }
            )) {
                if ($outcome -eq 'LookupFailed' -and $row.PSObject.Properties["$($service.Name)LookupStatus"]) { continue }
                $lookup = if ($outcome -eq 'LookupFailed') { 'FailedLookup' }
                elseif ($outcome -eq 'Excluded') { 'SkippedUnsafeCorrelation' }
                elseif (@($rows | Where-Object { $_.($service.Field) }).Count) { 'Found' }
                else { 'NotFound' }
                $row | Add-Member -NotePropertyName "$($service.Name)LookupStatus" -NotePropertyValue $lookup -Force
            }
        }
    }
}

#endregion Scrapped result handling

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
        [Parameter(Mandatory)][string]$LogPath,
        [AllowEmptyCollection()][object[]]$ActionRecords = @()
    )

    $summaryPath = Join-Path -Path $OutputPath -ChildPath 'RunSummary.json'
    $RunSummary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding utf8
    $actionHeaders = @('RunId', 'Workflow', 'FinalizedTimestampUtc', 'OperationId', 'Resource', 'ObjectId',
        'DeviceName', 'EntraDeviceId', 'SerialNumber', 'Action', 'ReasonCode', 'Outcome', 'Attempts', 'HttpStatus', 'VerificationStatus', 'ErrorMessage')
    Export-ReportCsv -InputObject $ActionRecords -Headers $actionHeaders -Path (Join-Path $OutputPath 'ActionResults.csv')
    $lines = @(
        "Run summary: RunId=$($RunSummary.RunId) Tenant=$($RunSummary.TenantId) Workflow=$(if ($RunSummary.ScrappedWorkflow) { 'Scrapped' } else { 'Stale' }) Mode=$($RunSummary.Mode) WhatIf=$($RunSummary.WhatIfMode) ConfirmationGranted=$($RunSummary.ConfirmationGranted) DiscoveryComplete=$($RunSummary.DiscoveryComplete) ExitCode=$($RunSummary.ExitCode)"
    )
    if ($RunSummary.ScrappedWorkflow) {
        $lines += "Scrapped serials: Input=$($RunSummary.TotalScrappedSerials) Matched=$($RunSummary.TotalScrappedMatchedSerials) Excluded=$($RunSummary.TotalScrappedExcludedSerials) Ambiguous=$($RunSummary.TotalScrappedAmbiguousSerials) NotFound=$($RunSummary.TotalScrappedNotFoundSerials) Errors=$($RunSummary.TotalScrappedErrors)"
        $lines += "Scrapped exclusions: $(@($RunSummary.ScrappedExclusionsByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
        $lines += "Scrapped cleanup: $(@('Complete', 'Partial', 'Blocked', 'Pending', 'Simulated', 'Excluded', 'NotFound', 'LookupFailed', 'NotAttempted' | ForEach-Object { "$_=$($RunSummary.("TotalScrapped$_"))" }) -join '; ')"
    } else {
        $lines += "Evaluated=$($RunSummary.TotalEvaluated) Candidates=$($RunSummary.TotalCandidates) Excluded=$($RunSummary.TotalExcluded) ManualReview=$($RunSummary.TotalManualReview)"
        $lines += "Exclusions: $(@($RunSummary.ExclusionsByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
        $lines += "Manual review: $(@($RunSummary.ManualReviewByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
    }
    $lines += "Actions: Planned=$($RunSummary.TotalPlannedActions) Attempted=$($RunSummary.TotalAttemptedActions) RetryAttempts=$($RunSummary.TotalRetryAttempts); $(@($RunSummary.ActionOutcomes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
    if ($RunSummary.ScrappedWorkflow) {
        foreach ($resource in $RunSummary.ActionsByResource.Keys) {
            $counts = $RunSummary.ActionsByResource[$resource]
            if ($counts.Planned -gt 0) {
                $lines += "Actions [$resource]: $(@($counts.GetEnumerator() | Where-Object Value -gt 0 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
            }
        }
    }
    $lines += "VerificationPending=$($RunSummary.TotalVerificationPending) VerificationUnknown=$($RunSummary.TotalVerificationUnknown) DeviceOrSerialErrors=$($RunSummary.TotalErrors) RunErrors=$($RunSummary.TotalRunErrors)"
    $lines += "Reports: $OutputPath"
    $cancelledWithoutErrors = $RunSummary.Mode -eq 'Interactive' -and $RunSummary.ExitCode -eq 5 -and
        -not $RunSummary.ConfirmationGranted -and $RunSummary.TotalAttemptedActions -eq 0 -and
        $RunSummary.TotalErrors -eq 0 -and $RunSummary.TotalRunErrors -eq 0
    foreach ($line in $lines) {
        Write-CleanupLog -Message $line -Level INFO -LogPath $LogPath
        if (-not $cancelledWithoutErrors) {
            Write-Host $line
        }
    }
    if ($cancelledWithoutErrors) {
        Write-Host 'Deletion cancelled. No changes were made.'
        Write-Host "Reports: $OutputPath"
    }
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
    'Get-CleanupActionRecords',
    'New-RunSummary',
    'Set-ScrappedDeviceOutcomes',
    'Get-ScrappedDeviceSerialNumbers',
    'Resolve-ScrappedDeviceRecords',
    'Initialize-ProjectExecution',
    'Complete-ProjectExecution',
    'New-DeviceDeletionPlan',
    'Invoke-DeviceDeletionPlan',
    'Set-DeviceDeletionResults',
    'Test-DeviceDeletionOutcome',
    'Assert-DeviceCleanupContext'
)
