function Read-DeviceDeletionJournal {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $last = $null
    foreach ($line in [System.IO.File]::ReadLines($resolvedPath)) { $last = $line }
    if ([string]::IsNullOrWhiteSpace($last)) { throw 'Deletion journal has no final record.' }
    $journal = ConvertFrom-Json -InputObject $last -ErrorAction Stop
    if ($journal.Event -ne 'Final' -or
        ($journal.PSObject.Properties['SchemaVersion'] -and $journal.SchemaVersion -ne 2)) {
        throw 'Deletion journal is incomplete or has an unsupported schema; manual reconciliation is required.'
    }
    return $journal
}

function Open-DeviceCleanupEvidence {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TenantId
    )

    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($TenantId.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $file = Join-Path $root "$key.json"
    # The persistent lock also records initialization: missing evidence after initialization is an error.
    $lock = [System.IO.File]::Open("$file.lock", [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $devices = @{}
        if ([System.IO.File]::Exists($file)) {
            $document = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop
            if ($document.SchemaVersion -ne 1 -or $document.TenantId -ne $TenantId -or $document.Devices -isnot [array]) {
                throw 'Safety evidence schema or tenant mismatch.'
            }
            foreach ($device in $document.Devices) {
                if ($device.ObjectId -isnot [string] -or -not $device.ObjectId -or $devices.ContainsKey([string]$device.ObjectId) -or
                    $device.DeviceId -isnot [string] -or $device.ActivityUnknown -isnot [bool] -or
                    $device.Ambiguous -isnot [bool] -or $device.SerialNumbers -isnot [array] -or
                    (-not $device.DeviceId -and -not $device.Ambiguous) -or
                    ($null -ne $device.LastActivityUtc -and -not (Get-SafeUtcTimestamp $device.LastActivityUtc))) {
                    throw 'Invalid or duplicate device safety evidence.'
                }
                foreach ($serial in $device.SerialNumbers) {
                    if (-not (ConvertTo-NormalizedSerialNumber $serial)) { throw 'Invalid serial safety evidence.' }
                }
                $devices[[string]$device.ObjectId] = $device
            }
        } elseif ($lock.Length -gt 0) {
            throw 'Required safety evidence is missing. Restore the evidence store before cleanup.'
        }
        return [PSCustomObject]@{ Path = $file; TenantId = $TenantId; Devices = $devices; Lock = $lock }
    } catch {
        $lock.Dispose()
        throw
    }
}

function Update-DeviceCleanupEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Evidence,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntraDevices,
        [Parameter(Mandatory)][PSCustomObject]$Indexes
    )

    $counts = @{}
    foreach ($device in $EntraDevices) {
        if ($device.DeviceId) {
            $id = [string]$device.DeviceId
            if (-not $counts.ContainsKey($id)) { $counts[$id] = 0 }
            $counts[$id]++
        }
    }
    foreach ($device in $EntraDevices) {
        if (-not $device.Id) { continue }
        $id = [string]$device.Id
        $deviceId = [string]$device.DeviceId
        $previous = $Evidence.Devices[$id]
        $ambiguous = -not $deviceId -or $counts[$deviceId] -ne 1
        if ($previous -and ($previous.DeviceId -ne $deviceId -or $previous.Ambiguous)) { $ambiguous = $true }
        $timestamps = [System.Collections.Generic.List[datetime]]::new()
        $serials = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $unknown = $false
        if ($previous) {
            $time = Get-SafeUtcTimestamp $previous.LastActivityUtc
            if ($time) { $timestamps.Add($time) }
            foreach ($serial in $previous.SerialNumbers) { $serials.Add([string]$serial) | Out-Null }
            $unknown = $previous.ActivityUnknown
        }
        $time = Get-SafeUtcTimestamp $device.ApproximateLastSignInDateTime
        if ($time) { $timestamps.Add($time) }
        $managedMatches = @{}
        if ($deviceId -and $Indexes.IntuneByAadDeviceId.ContainsKey($deviceId)) {
            $directMatches = $Indexes.IntuneByAadDeviceId[$deviceId]
            if ($directMatches.Count -ne 1) { $ambiguous = $true }
            foreach ($managed in $directMatches) { $managedMatches[[string]$managed.Id] = $managed }
        }
        if ($deviceId -and $Indexes.AutopilotByAadDeviceId.ContainsKey($deviceId)) {
            foreach ($autopilot in $Indexes.AutopilotByAadDeviceId[$deviceId]) {
                $serial = ConvertTo-NormalizedSerialNumber $autopilot.SerialNumber
                if ($serial) { $serials.Add($serial) | Out-Null }
                if ($autopilot.ManagedDeviceId -and $Indexes.IntuneById.ContainsKey([string]$autopilot.ManagedDeviceId)) {
                    $managed = $Indexes.IntuneById[[string]$autopilot.ManagedDeviceId]
                    if ($managed.AzureAdDeviceId -and $managed.AzureAdDeviceId -ne $deviceId) { $ambiguous = $true }
                    $managedMatches[[string]$managed.Id] = $managed
                }
            }
        }
        if ($managedMatches.Count -gt 1) { $ambiguous = $true }
        foreach ($managed in $managedMatches.Values) {
            $serial = ConvertTo-NormalizedSerialNumber $managed.SerialNumber
            if ($serial) { $serials.Add($serial) | Out-Null }
            $time = if ($managed.PSObject.Properties['LastSyncDateTime']) { Get-SafeUtcTimestamp $managed.LastSyncDateTime }
            if ($time) { $timestamps.Add($time) } else { $unknown = $true }
        }
        $latest = $timestamps | Sort-Object -Descending | Select-Object -First 1
        $Evidence.Devices[$id] = [PSCustomObject]@{
            ObjectId = $id; DeviceId = $deviceId; SerialNumbers = @($serials | Sort-Object)
            LastActivityUtc = if ($latest) { $latest.ToString('o') } else { $null }
            ActivityUnknown = $unknown; Ambiguous = $ambiguous
        }
    }
    $temporary = "$($Evidence.Path).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = [PSCustomObject]@{
            SchemaVersion = 1; TenantId = $Evidence.TenantId
            Devices = @($Evidence.Devices.Values | Sort-Object ObjectId)
        } | ConvertTo-Json -Depth 10 -Compress
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [System.IO.File]::Move($temporary, $Evidence.Path, $true)
        $Evidence.Lock.SetLength(1)
        $Evidence.Lock.Flush($true)
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}
