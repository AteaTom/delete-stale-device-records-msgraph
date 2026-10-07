@{
    # Copy to Settings.psd1 (or reference directly) and customize per tenant.
    # This file is documentation/example only; Invoke-StaleDeviceCleanup.ps1
    # does not read it automatically. Wire values into your own scheduled
    # task wrapper script if desired (see examples/Invoke-Automatic.ps1).

    DaysInactive               = 180
    Mode                       = 'Audit'
    BatchSize                  = 20
    VerifyDeletion             = $false # Optional bounded read-back after batch deletion.
    OutputPath                 = '.\output'
    TenantId                   = ''
    ProtectedDeviceIdFile      = '.\config\ProtectedDevices.example.csv'
    ProtectedDeviceNamePattern = @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*')
    # For scrapped cleanup use a separate invocation with -ScrappedDevices,
    # omitting DaysInactive. Default input: config\scrappeddevices.csv in the repository.
    # Optional -ScrappedDeviceCsvPath override; strict SerialNumber header.
}
