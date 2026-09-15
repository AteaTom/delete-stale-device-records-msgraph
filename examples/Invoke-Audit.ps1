#Requires -Version 7.0
<#
    .SYNOPSIS
    Safe, non-destructive audit run. Always start here.
#>
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)

& '.\src\Invoke-StaleDeviceCleanup.ps1' `
    -Mode Audit `
    -DaysInactive 180 `
    -DaysDisabled 30 `
    -OutputPath '.\output' `
    -Verbose
