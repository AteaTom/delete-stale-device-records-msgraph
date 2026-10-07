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

Autopilot-backed objects are protected from ordinary stale cleanup. Explicit
`-ScrappedDevices` cleanup permits safely correlated Entra deletion only after
all dependencies succeed and related Autopilot absence is verified. Do not
delete Entra manually merely because deregistration was accepted.

For `ScrappedDeviceResults.csv`, `RemovalSubmitted` means the v1.0 Autopilot
identity DELETE accepted the removal request. The script does not wait for the
portal to synchronize. Microsoft notes that deregistration can take time; use
**Sync** and **Refresh** in the Intune Autopilot devices view if the record
remains visible. `RemovalFailed` means the identity DELETE failed;
`BlockedDependency` means a required Intune removal did not succeed.
Entra uses `BlockedDependency` if any required operation or verification fails.
`VerificationPending` means bounded exact-ID read-back still found the
Autopilot record; it is not a completed cleanup. Independent targets continue.
Preserve reports and reconcile exact IDs read-only before deciding on a new run.

## RunSummary planned and completed removal counts differ

The two Entra counts report different stages of the run:

- `TotalEntraDevicesToRemove` is the planned count: evaluated candidates whose
  `EntraAction` is `Remove`. It can be nonzero in Audit mode, with `-WhatIf`,
  or when an execution-mode gate prevents deletion.
- `TotalEntraDevicesRemoved` counts devices whose Entra removal completed and
  whose `EntraRemovalStatus` is `Removed`.

The completed count can therefore be lower than the planned count when no
destructive operation was authorized, `-WhatIf` was used, discovery or
permissions prevented deletion, an object was already absent, or an Entra
removal failed. Check `Mode`, `WhatIfMode`, `ConfirmationGranted`,
`DiscoveryComplete`, `ExitCode`, per-device removal statuses, and
`ExecutionLog.txt` to see why planned removals were not completed.

## Autopilot removal reports a missing bulk route

Current versions use the supported individual identity DELETE endpoint. Update
to the latest project version before retrying.

## Entra devices are disabled instead of removed

Direct removal is expected for an eligible standalone stale device.
Entra device deletion is irreversible; associated BitLocker recovery keys
must be backed up or no longer needed. `DeviceLifecycleState.json` is not a
30-day deletion gate. Autopilot-backed objects are now excluded.

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
multiple records without enough corroborating stable relationships; the tool
never guesses which one to delete,
so nothing is removed for that serial number — resolve the duplicate manually
in the Intune/Autopilot portal first. `NotFound` means the serial number did
not match any Autopilot identity, Intune managed device, or Entra device
object. Entra serial correlation depends on current Intune/Autopilot
references. Once those source records are gone, an Entra object may remain
but can no longer be identified by serial. Preserve earlier result reports;
NotFound does not establish complete historical cleanup. Historical reports
are not automatically replayed as deletion input.

## Scrapped-device Intune removal fails with a permission error

Removing an Intune managed device requires
`DeviceManagementManagedDevices.ReadWrite.All`, which is only requested when
`-ScrappedDevices` is supplied in a destructive mode. Entra deletion also needs
`Directory.AccessAsUser.All` and a supported role. Re-consent if the
account previously only had the read-only Intune scope.

## Scrapped parameter binding or CSV header errors

Use `-ScrappedDevices`, remove `-DaysInactive`, and supply a CSV with a unique
`SerialNumber` column. Default input is `config\scrappeddevices.csv`, resolved
relative to the repository containing the script. Move any existing input from
`src` to `config`, or supply its path using `-ScrappedDeviceCsvPath`.
The example CSV is not used automatically. Path-only invocation was intentionally removed in 1.2.0 so existing
automation cannot silently gain Entra deletion. `-AllowLegacyScrappedDeviceFormat`
explicitly permits the old headerless input, not the old deletion behavior.

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

JsonBatch separately checks every subresponse. It retries only failed transient
subrequests, honors their Retry-After headers, and restores SDK retry settings
after temporarily disabling envelope retries. See [BatchDeletion.md](BatchDeletion.md).

## Batch outcome unknown, invalid response, or journal already exists

Stop and inspect `DeletionJournal.jsonl` and the final reports. Some operations
may already have completed. Reconcile exact IDs read-only in the approved
tenant before another destructive run. Do not delete the journal and replay
an envelope blindly. Expired or modified plans must be regenerated and reviewed.
Failed read-back is not evidence of absence.

Once exact-ID read-only reconciliation is complete, run a new Audit rather
than resubmitting the old plan. Compare remaining candidate IDs with historical
unknown/unattempted IDs and investigate unexpected additions. A present
object is not automatically authorized for deletion.
Use the [operator validation procedure](BatchDeletion.md#operator-run-validation-procedure)
for fresh Audit/WhatIf checks and separately authorized disposable-lab testing.
Do not use remaining current-tenant candidates as test fixtures.

### Invalid URI after the first batch

Earlier batch code used absolute request URLs. Graph Authentication 2.37.0
can leave its internal environment without an authentication endpoint after
such a request; resetting SDK retries then exposes the invalid URI on the
next envelope. Batch and verification code now uses relative SDK routes.
The warning includes the underlying error.

Do not assume the whole run failed without changes: inspect the journal for
successful earlier chunks and unknown outcomes. Preserve all run artifacts.
Start a fresh PowerShell process to clear affected SDK state and load the
updated module before read-only reconciliation. Do not replay deletion until
unknown outcomes have been reconciled and a new plan has been reviewed.

## Pester tests fail with "Connect-MgGraph is not recognized"

Tests must never call real Graph cmdlets. Ensure `Mock` is applied inside the
correct module scope (`-ModuleName StaleDeviceCleanup`) and that the
Microsoft.Graph modules are at least stub-importable in the test environment.
