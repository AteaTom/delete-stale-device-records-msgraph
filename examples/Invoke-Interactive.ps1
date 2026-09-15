#Requires -Version 7.0
<#
    .SYNOPSIS
    Interactive run. Requires typing DELETE at the confirmation prompt before
    anything is removed. Run with -WhatIf first to preview the exact Graph
    calls that would be made.
#>
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)

# Add -ScrappedDeviceCsvPath '.\src\SkrotadeDatorer.csv' to also remove Autopilot,
# Intune, and Entra records for physically scrapped devices listed by serial number.
& '.\src\Invoke-StaleDeviceCleanup.ps1' `
    -Mode Interactive `
    -DaysInactive 365 `
    -DaysDisabled 30 `
    -OutputPath '.\output' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.example.csv' `
    -ProtectedDeviceNamePattern @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*') `
    -WhatIf `
    -Verbose
