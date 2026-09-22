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
The identity DELETE was accepted. Entra removal is attempted directly after
that successful Autopilot operation; a failed identity DELETE blocks Entra.

For `ScrappedDeviceResults.csv`, `RemovalSubmitted` means the v1.0 Autopilot
identity DELETE accepted the removal request. The script does not wait for the
portal to synchronize. Microsoft notes that deregistration can take time; use
**Sync** and **Refresh** in the Intune Autopilot devices view if the record
remains visible. `RemovalFailed` means the identity DELETE failed and the
related Entra removal was intentionally skipped.

## RunSummary reports fewer disabled devices than the execution log

This indicates that a destructive run ended before its normal completion
checkpoint. Current versions always persist the in-memory lifecycle state and
rewrite reports from `finally`. Unprocessed candidates receive an error, and
the run exits with code 6 instead of reporting success. For an older affected
run, recover successful IDs and their timestamps from `ExecutionLog.txt`
before using the lifecycle state for retention decisions.

Audit runs and cancelled Interactive runs do not persist newly tracked
disabled-device timestamps. The lifecycle ledger is checkpointed only after a
destructive confirmation, so pressing Enter at the confirmation prompt cannot
change the next run's summary.

## Autopilot removal reports a missing bulk route

Current versions use the supported individual identity DELETE endpoint. Update
to the latest project version before retrying.

## Entra devices are disabled instead of removed

Direct removal is expected for a stale device. Microsoft Entra keeps deleted
device objects in its deleted-device recovery window, so accidental removals
can be restored according to tenant retention policy. `DeviceLifecycleState.json`
is no longer a 30-day deletion gate.

`ExecutionLog.txt` records planned and completed removal counts. The same
values are available in `RunSummary.json` as
`TotalEntraDevicesToRemove` and `TotalEntraDevicesRemoved`.

## Entra deletion reports Request_ResourceNotFound

An Entra device can disappear between discovery and deletion because another
administrator or an earlier cleanup run already removed it. Current versions
treat Graph `404 Request_ResourceNotFound` from `Remove-MgDevice` as successful
idempotent completion because the requested end state has already been reached.
Other Graph errors, including permission failures, still fail the operation.

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
