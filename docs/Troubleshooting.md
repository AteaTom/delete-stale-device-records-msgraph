# Troubleshooting

## Finding exclusions and failed actions

Use `ADSyncedDevices.csv` and `AutopilotProtectedDevices.csv` for the two
dedicated protection categories. They no longer appear in `ExcludedDevices.csv`;
the complete record remains in `AllEvaluatedDevices.csv`. A device associated
with both follows the existing primary reason (Autopilot before AD-sync).
`OnPremisesSyncedReview.csv` is a compatibility alias, not another category.

Use `ActionResults.csv` for unique planned operations, including their final
outcomes, attempts, HTTP statuses and verification state. Terminal failures,
unknown outcomes and blocked dependencies produce `Event=ActionAttention`
warnings in `ExecutionLog.txt`. The final console/log block and
`RunSummary.json` use the same counts; neither simulated nor already-absent
objects count as newly removed. `RunErrors` can be nonzero even when there are
no evaluated-device rows.

Successful scope lists, discovery starts and individual batch response detail
now require `-Verbose`; DEBUG uses `-Debug`. Those streams are not duplicated
in the normal log. The deletion journal remains the submission/retry evidence.
See [Reporting.md](Reporting.md#administrator-logging-and-reconciliation).

## Scrapped-device preparation takes a long time with CPU activity

Serial correlation and initial report generation run locally after discovery;
they do not call Graph. Earlier versions scanned the complete Intune and
Autopilot inventories for every input serial, including repeatedly rebuilding
the same managed-device ID list inside the Intune scan. Plan building also
repeatedly scanned all correlation rows. Large CSVs combined with large tenant
inventories could therefore spend many minutes on CPU-bound preparation,
without new log lines. CPU activity alone cannot establish that a run is
healthy or identify its current step.

Current code indexes stable references and groups plan rows once, while
retaining all related records for conflict detection. It logs resolution
progress every 100 input serials, elapsed time, and separate initial CSV
export/plan-building boundaries. Follow `ExecutionLog.txt` with
`Get-Content -LiteralPath '<run folder>\ExecutionLog.txt' -Wait` to distinguish
these stages from Graph batch submission. Already-running processes continue
using their loaded code; changing files does not accelerate that run.
Before starting another run, preserve reports and the journal and establish
whether any DELETE was submitted. Do not start overlapping destructive runs.

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
all dependencies succeed: Autopilot HTTP 204 is accepted, while unexpected
HTTP 200 requires verified absence. Do not
delete Entra manually merely because deregistration was accepted.

For `ScrappedDeviceResults.csv`, `RemovalSubmitted` means the v1.0 Autopilot
identity DELETE accepted the removal request. Related Entra deletion may then
proceed; optional `-VerifyDeletion` is a later diagnostic read-back and does
not gate that dependency. The script does not wait for the portal to
synchronize. Microsoft notes that deregistration can take time; use
**Sync** and **Refresh** in the Intune Autopilot devices view if the record
remains visible. `RemovalFailed` means the identity DELETE failed;
`BlockedDependency` means a required Intune removal did not succeed.
Entra uses `BlockedDependency` if any required operation or verification fails.
`VerificationPending` means bounded exact-ID read-back still found the
Autopilot record; it is not a completed cleanup. Independent targets continue.
Preserve reports and reconcile exact IDs read-only before deciding on a new run.

If an Autopilot DELETE subrequest returns HTTP 200 instead of the documented
204, the executor does not assume success or replay the DELETE. It immediately
checks that exact Autopilot identity: `VerifiedAbsent` means the read-back
returned 404 and the Entra dependency may continue; a visible identity or
failed read-back leaves the outcome unresolved and blocks dependent Entra
deletion. The immediate check uses up to three GETs with five-second intervals;
there is no additional sweep or automatic DELETE replay.

If Autopilot disappears later but Entra remains, first preview:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeFromRunPath '.\output\<original-run>'
```

Then use the same source with `-Mode Interactive` for fresh approval. Re-supply
the original protection options. This uses the approved Entra object IDs even
when serial discovery no longer finds their links, reloads current inventory,
and verifies the original Autopilot IDs read-only. Visible/failed read-back,
current management or re-registration, protection and unresolved prerequisites
still block deletion. No Intune/Autopilot DELETE is replayed.
Missing/incomplete/inconsistent source files or a previously uncertain Entra
DELETE require manual investigation. Keep the original run unchanged.

To avoid entering the source path, use `-ResumeLatest` instead of
`-ResumeFromRunPath`. It searches immediate subfolders of `-OutputPath`
(default `.\output`) and logs/displays its selection. Invalid journals are
warned about and skipped; no eligible journal is an error, not permission to
start another cleanup workflow. If multiple tenants have eligible journals,
specify `-TenantId`. Use an explicit source path when latest timestamps tie
or you intend to resume a different original run.

### Resume selects no journal, an older journal, or the same journal again

Audit runs have no deletion journal. Latest selection also ignores Entra-only
resume runs and sources without qualifying unattempted/blocked Entra targets.
It uses original plan creation time, not directory name, modification time,
or the most recent arbitrary execution. Invalid/incomplete sources are skipped
with `ResumeSourceSkipped` warnings; review those warnings rather than deleting
or editing evidence to make a source eligible.

`-OutputPath` is the immediate-folder search root and new report destination.
It is not a recursive search. For example, runs under `.\output\retirement`
require that exact root. Relative paths start at the current working directory.
Use `-ResumeFromRunPath` if the intended source is outside the root.

The original journal is immutable and is not updated by later resume runs.
It may therefore remain the latest source after successful resumption.
Fresh inventory marks now-absent Entra targets `NotFound`/`EntraAlreadyAbsent`
and does not delete them again. Selection does not automatically advance
through or combine older runs. Choose an older source explicitly when needed.
Before approving, check the displayed source path, tenant and new target IDs.

### Resume excludes an expected Entra target

See `AmbiguityReason` and source-linkage columns in
`ScrappedDeviceResults.csv`, plus `ResumeTarget` and
`ResumeAutopilotVerification` in the new log. A serial still present anywhere
in Intune/Autopilot blocks resumption even if its device references changed.
`AutopilotAbsenceNotVerified` covers both still-visible identities and read
errors: HTTP 403, timeout or other failed reads are not absence.

Do not remove protections or repeat earlier DELETEs to force eligibility.
Re-supply protection options, verify the original object/device IDs, and
investigate re-registration, sync, unsupported platforms and unresolved
Intune prerequisites. Previously attempted Entra DELETEs are deliberately
excluded from automatic recovery. A newly generated plan does not make an
uncertain historical operation safe to replay.

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
are not automatically replayed as deletion input. Use the explicit resume
workflow with the original plan, final journal and report when applicable;
it requires fresh validation and approval, not just a CSV.

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

Batch deletion separately checks every subresponse. It retries only failed transient
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
