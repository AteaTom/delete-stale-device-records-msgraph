#Requires -Version 7.0
<#
    .SYNOPSIS
    Interactive run. Requires typing DELETE at the confirmation prompt before
    anything is removed. Run with -WhatIf first to preview the exact Graph
    calls that would be made.
#>
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Invoke-StaleDeviceCleanup.ps1'

# Add -ScrappedDeviceCsvPath '.\src\SkrotadeDatorer.csv' to also remove Autopilot,
# Intune, and Entra records for physically scrapped devices listed by serial number.
# When the serial exists in Autopilot, all linked Entra and Intune records for that
# serial are expanded into the exact deletion set; duplicates without Autopilot
# authority remain Ambiguous and are skipped.
& $scriptPath `
    -Mode Interactive `
    -DaysInactive 365 `
    -DaysDisabled 30 `
    -OutputPath '.\output' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.example.csv' `
    -ProtectedDeviceNamePattern @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*') `
    -WhatIf `
    -Verbose
