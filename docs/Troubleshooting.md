# Troubleshooting

## "Missing required Microsoft Graph PowerShell module(s)"

Install the modules named in the error message, for example:

```powershell
Install-Module -Name Microsoft.Graph.Authentication,Microsoft.Graph.Identity.DirectoryManagement,Microsoft.Graph.DeviceManagement,Microsoft.Graph.DeviceManagement.Enrollment -Scope CurrentUser
```

## "Connected tenant '...' does not match the requested TenantId"

You authenticated to a different tenant than the one passed via `-TenantId`.
Run `Disconnect-MgGraph` and re-run the script.

## "Missing required Graph scope(s)"

The signed-in account (or the app registration behind `Connect-MgGraph`)
was not granted one of the scopes listed in
[Permissions.md](Permissions.md). In Audit mode this is a warning only; in
Interactive/Automatic mode, deletion is skipped until the scopes are granted.

## Run exits with code 4 (incomplete discovery)

One of the three discovery calls (`Get-MgDevice`,
`Get-MgDeviceManagementManagedDevice`,
`Get-MgDeviceManagementWindowsAutopilotDeviceIdentity`) failed entirely. Check
`ExecutionLog.txt` for the underlying Graph error. No deletion is attempted
when this occurs.

## Autopilot removal reported but Entra device still exists

Check `AutopilotRemovalStatus` and `EntraRemovalStatus` in
`AllEvaluatedDevices.csv`. `AutopilotRemovalStatus = RemovalSubmitted` means
Graph accepted asynchronous deletion. For an active stale object, Entra can be
disabled immediately. For an eligible disabled object,
`EntraRemovalStatus = PendingAutopilotRemoval` means permanent deletion is
intentionally deferred. Run the tool again later; normal discovery must show
that Autopilot is absent before Entra is permanently removed.

For `ScrappedDeviceResults.csv`, `RemovalSubmitted` means the v1.0 Autopilot
bulk endpoint accepted the serial for asynchronous deletion. The script does
not wait for the portal to synchronize. Microsoft notes that deregistration
can take time; use **Sync** and **Refresh** in the Intune Autopilot devices view
if the record remains visible. `RemovalFailed` means Graph rejected the bulk
submission and the related Entra removal was intentionally skipped.

Autopilot bulk submissions are split into sequential chunks of at most 100
unique serial numbers. Transient Graph failures are retried per chunk. If one
chunk still fails, its serials receive `RemovalFailed`, while later chunks
continue and retain their own results.

## Entra devices are disabled instead of removed

This is expected for a newly stale active device. The first eligible run sets
`accountEnabled = false` and records the timestamp in
`DeviceLifecycleState.json` under the configured output root. The device is
not eligible for Entra removal until `DaysDisabled` has elapsed. Keep this
file with the output root between scheduled runs; deleting it restarts the
retention clock for already-disabled devices.

`ExecutionLog.txt` records planned and completed counts for both actions. The
same values are available in `RunSummary.json` as
`TotalEntraDevicesToDisable`, `TotalEntraDevicesToRemove`,
`TotalEntraDevicesDisabled`, and `TotalEntraDevicesRemoved`.

## A scrapped-device serial number shows as Ambiguous or NotFound

Check `ScrappedDeviceResults.csv`. `Ambiguous` means the serial number matched
more than one record in at least one source (e.g. duplicate serial numbers
across two Autopilot identities); the tool never guesses which one to delete,
so nothing is removed for that serial number — resolve the duplicate manually
in the Intune/Autopilot portal first. `NotFound` means the serial number did
not match any Autopilot identity, Intune managed device, or Entra device
object (already removed, or never enrolled) — no action is needed.

## Scrapped-device Intune removal fails with a permission error

Removing an Intune managed device requires
`DeviceManagementManagedDevices.ReadWrite.All`, which is only requested when
`-ScrappedDeviceCsvPath` is supplied in a destructive mode. Re-consent if the
account previously only had the read-only Intune scope.

## A parameter cannot be found that matches parameter name Statistics

This means an older `StaleDeviceCleanup` module is still loaded in the current
PowerShell session while a newer script file is running. Current versions
detect the missing scrapped-device parameters and reload the local module
automatically. Pull the latest project files and run the command again. For an
older checkout, start a new PowerShell session or run:

```powershell
Remove-Module StaleDeviceCleanup -Force -ErrorAction SilentlyContinue
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
```

## Throttling (HTTP 429)

`Invoke-GraphWithRetry` automatically retries transient 429/503/504 responses
with exponential backoff (or `Retry-After` when supplied), up to 5 attempts
by default. Persistent throttling after 5 attempts surfaces as a terminating
error for that operation.

## Pester tests fail with "Connect-MgGraph is not recognized"

Tests must never call real Graph cmdlets. Ensure `Mock` is applied inside the
correct module scope (`-ModuleName StaleDeviceCleanup`) and that the
Microsoft.Graph modules are at least stub-importable in the test environment.
