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
`AllEvaluatedDevices.csv`. If `AutopilotRemovalStatus = AlreadyRemoved`, Graph
confirmed that the Autopilot identity was already deleted and Entra removal was
allowed to continue. If it is `RemovalInProgress`, Graph is still processing
the delete and the configured retry budget was exhausted; Entra deletion was
intentionally skipped. If it is `RemovalUnconfirmed`, Graph accepted the
request but did not provide confirmation within the retry budget. Re-run in
Audit mode before retrying either case.

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

## Throttling (HTTP 429)

`Invoke-GraphWithRetry` automatically retries transient 429/503/504 responses
with exponential backoff (or `Retry-After` when supplied), up to 5 attempts
by default. Persistent throttling after 5 attempts surfaces as a terminating
error for that operation.

## Pester tests fail with "Connect-MgGraph is not recognized"

Tests must never call real Graph cmdlets. Ensure `Mock` is applied inside the
correct module scope (`-ModuleName StaleDeviceCleanup`) and that the
Microsoft.Graph modules are at least stub-importable in the test environment.
