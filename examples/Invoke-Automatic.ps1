#Requires -Version 7.0
<#
    .SYNOPSIS
    Unattended run suitable for a scheduled task. WARNING: this example, if
    -WhatIf is removed, will perform REAL deletions once -ConfirmDeletion is
    supplied. Review all reports from an Audit run before ever enabling this.
#>
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Invoke-StaleDeviceCleanup.ps1'

& $scriptPath `
    -Mode Automatic `
    -DaysInactive 365 `
    -DaysDisabled 30 `
    -OutputPath '.\output' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.example.csv' `
    -ProtectedDeviceNamePattern @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*') `
    -ConfirmDeletion `
    -WhatIf `
    -Verbose
