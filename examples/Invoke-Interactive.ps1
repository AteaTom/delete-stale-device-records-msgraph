#Requires -Version 7.0
<#
    .SYNOPSIS
    Interactive run. Requires typing DELETE at the confirmation prompt before
    anything is removed. Run with -WhatIf first to preview the exact Graph
    calls that would be made.
#>
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Invoke-StaleDeviceCleanup.ps1'

# For explicit retirement replace -DaysInactive with -ScrappedDevices.
# Default input is config\scrappeddevices.csv with a SerialNumber header.
# Audit first. Scrapped mode retains Entra; a later normal run applies DaysInactive.
# Reuse the same -EvidencePath across runs if overriding its repository-relative default.
& $scriptPath `
    -Mode Interactive `
    -DaysInactive 365 `
    -OutputPath '.\output' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.example.csv' `
    -ProtectedDeviceNamePattern @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*') `
    -WhatIf `
    -Verbose
