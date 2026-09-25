@{
    # Copy to Settings.psd1 (or reference directly) and customize per tenant.
    # This file is documentation/example only; Invoke-StaleDeviceCleanup.ps1
    # does not read it automatically. Wire values into your own scheduled
    # task wrapper script if desired (see examples/Invoke-Automatic.ps1).

    DaysInactive               = 180
    Mode                       = 'Audit'
    OutputPath                 = '.\output'
    TenantId                   = ''
    ProtectedDeviceIdFile      = '.\config\ProtectedDevices.example.csv'
    ProtectedDeviceNamePattern = @('BREAKGLASS-*', 'PAW-*', 'ADMIN-*', 'KIOSK-CRITICAL-*')
    ScrappedDeviceCsvPath      = '.\src\SkrotadeDatorer.csv'
}
