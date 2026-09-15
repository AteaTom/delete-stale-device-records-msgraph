# Dot-sourced by the *.Tests.ps1 files. Not itself a test file.

function New-TestEntraDevice {
    <#
        .SYNOPSIS
        Builds a fully-populated fake Entra device object (all properties
        that Get-StaleDeviceCandidates reads) so that Set-StrictMode -Version
        Latest does not fail on properties the test doesn't care about.
    #>
    param(
        [string]$Id = (New-Guid).ToString(),
        [string]$DeviceId = (New-Guid).ToString(),
        [string]$DisplayName = 'TEST-DEVICE',
        [string]$OperatingSystem = 'Windows',
        [string]$OperatingSystemVersion = '10.0.19045',
        [bool]$AccountEnabled = $true,
        [string]$TrustType = 'AzureAd',
        [string]$ProfileType = 'RegisteredDevice',
        $ApproximateLastSignInDateTime = $null,
        [bool]$OnPremisesSyncEnabled = $false,
        $OnPremisesLastSyncDateTime = $null,
        $RegistrationDateTime = (Get-Date).ToUniversalTime().AddYears(-1),
        [bool]$IsManaged = $false,
        [bool]$IsCompliant = $false,
        [string]$Manufacturer = 'Contoso',
        [string]$Model = 'TestModel'
    )

    return [PSCustomObject]@{
        Id                             = $Id
        DeviceId                       = $DeviceId
        DisplayName                    = $DisplayName
        OperatingSystem                = $OperatingSystem
        OperatingSystemVersion         = $OperatingSystemVersion
        AccountEnabled                 = $AccountEnabled
        TrustType                      = $TrustType
        ProfileType                    = $ProfileType
        ApproximateLastSignInDateTime  = $ApproximateLastSignInDateTime
        OnPremisesSyncEnabled          = $OnPremisesSyncEnabled
        OnPremisesLastSyncDateTime     = $OnPremisesLastSyncDateTime
        RegistrationDateTime           = $RegistrationDateTime
        IsManaged                      = $IsManaged
        IsCompliant                    = $IsCompliant
        Manufacturer                   = $Manufacturer
        Model                          = $Model
    }
}
