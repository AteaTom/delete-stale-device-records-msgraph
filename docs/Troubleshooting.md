# Troubleshooting

## Autopilot was submitted but Entra still exists

This is expected. `-ScrappedDevices` now deletes Intune records and submits
Autopilot deregistration only. It never deletes Entra or waits for Autopilot.
Microsoft documents that deregistration can take time and may leave an Entra
object behind. Do not delete Entra merely because submission was accepted.

Later, run normal inactivity Audit with the same evidence directory and
protection settings:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Audit -DaysInactive 180
```

Review the candidate IDs and reasons, then separately approve normal cleanup.
Autopilot-backed devices remain protected. Recent/missing activity, explicit
protection, ambiguous state and default AD-sync protection still block deletion.
`-ResumeLatest` and `-ResumeFromRunPath` now explicitly fail; replace scheduled
resume commands with normal inactivity Audit first, not another scrapped run.

## HTTP 200 instead of 204 from Autopilot DELETE

The [API reference](https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-delete?view=graph-rest-1.0)
documents 204. A batch envelope's 200 is not its subrequest status.
An individual DELETE's unexpected 200 is OutcomeUnknown, not success.
The script records it without polling or automatically replaying the DELETE.
Reconcile exact identity IDs read-only using the intended tenant; retain
journals and sanitized diagnostics. Offline tests cannot explain a live
service response.

## Required safety evidence is missing, corrupt or locked

Keep the same `-EvidencePath` across runs and back up the entire directory.
The default is `.state` beside `src`, independent of OutputPath and the current
working directory. It stores tenant-bound activity and serial associations.

An initialized JSON missing while its lock marker remains is an error.
Malformed/schema-mismatched evidence or failed saves also block execution.
Restore trusted evidence; do not delete the marker or reset data to make a run
pass. Loss of the entire directory is indistinguishable from first installation.
When moving hosts or upgrading checkouts, explicitly point to the existing
protected evidence directory.

The exclusive tenant lock is held during execution. Wait for the existing run
to finish; do not start an overlapping destructive run. Another tenant has a
separate store. Lock files remain after normal completion as initialization
markers; their existence alone does not mean a process is active.

`UnresolvedSafetyEvidence` means identity/activity uncertainty, including
historical Intune records with missing sync timestamps or changed IDs. Such
flags intentionally persist after record removal. Investigate rather than
clearing them automatically. Supply stable Entra IDs in protection files when
historical serial links are unavailable. A fresh installation cannot recover
evidence deleted before this version; review historical reports before approval.

## Slow preparation or finalization

Resolution runs locally after three complete inventories; indexed lookups
avoid scanning every inventory for each serial. Logs identify resolution
progress, export and plan-building boundaries. CPU activity alone is not proof
of healthy progress. Already-running processes continue using their loaded code.

New scrapped execution does not sleep per Autopilot identity. Optional
`-VerifyDeletion` still performs bounded per-ID Intune read-back and can be
slow on large Intune batches. Omit it unless needed.

Version 2 journals use deltas plus full initial/final checkpoints, rather than
full results at every event. Finalization streams giant JSONL lines instead
of using slow `Get-Content -Tail`. Do not manually edit legacy journals.

## Batch unknown outcome, plan expired or journal already exists

Some operations may have completed. Preserve all artifacts and reconcile
exact IDs read-only before another destructive run. Do not remove the journal
and replay an envelope blindly. Expired/modified plans require new discovery,
review and approval; plan expiry is not automatically extended.
Unknown envelope results are never automatically retried. Only identified
transient subrequests enter the bounded retry queue. Failed read-back is not
evidence of absence. See [BatchDeletion.md](BatchDeletion.md).

Interrupted journals without a valid Final checkpoint require manual
reconciliation. Historical journals are evidence, not deletion authorization.

## Exclusions, action counts and Pending outcomes

Use ADSyncedDevices.csv and AutopilotProtectedDevices.csv for dedicated
protection categories; remaining exclusions go to ExcludedDevices.csv.
AllEvaluatedDevices.csv retains every normal evaluation.
OnPremisesSyncedReview.csv is an alias, not an additional category.

ActionResults.csv lists planned/attempted outcomes by unique service ID.
Submission, newly removed, already absent, simulated and unresolved are
different outcomes. Planned counts may exceed completed counts because of
Audit/WhatIf, declined approval, protections, failures or unattempted work.
Pending after accepted Autopilot deregistration is expected and can exit 0.
OutcomeUnknown is not success. See [Reporting.md](Reporting.md).

## A scrapped serial is Ambiguous or NotFound

Ambiguous means insufficient stable corroboration; resolve conflicting records
before approving. NotFound means no reliable current serial match, not proof
that residual Entra records disappeared. Entra rows are correlation context,
not scrapped DELETE targets. Use normal inactivity cleanup later.

## Missing modules, scopes or wrong tenant

Install the exact modules reported by Test-Prerequisites:

```powershell
Install-Module -Name Microsoft.Graph.Authentication,Microsoft.Graph.Identity.DirectoryManagement,Microsoft.Graph.DeviceManagement,Microsoft.Graph.DeviceManagement.Enrollment -Scope CurrentUser
```

Disconnect and reconnect if the authenticated tenant differs from TenantId.
Destructive scrapped mode needs Intune and Autopilot write scopes, not Entra
write scope. Normal deletion needs the documented delegated Entra permission
and supported role. Audit requests read scopes only.
See [Permissions.md](Permissions.md) for consent/RBAC/licensing.
Failed global inventory retrieval blocks all deletions (exit 4).

## CSV input or old module mismatch

Use `-ScrappedDevices` without `-DaysInactive`, supply a unique SerialNumber
column, and move real input to `config\scrappeddevices.csv` or explicitly
override its path. No fallback to old/example files exists. Headerless input
requires AllowLegacyScrappedDeviceFormat.

Current scripts reload incompatible modules. For an older loaded checkout,
start a fresh PowerShell process or explicitly import the matching manifest:

```powershell
Remove-Module StaleDeviceCleanup -Force -ErrorAction SilentlyContinue
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
```

Graph SDK requests use relative routes to avoid earlier absolute-URI
environment mutation. If SDK state is already damaged, preserve outcomes and
start a fresh process for read-only reconciliation; do not assume nothing
was deleted.

## Throttling and offline tests

Recognized 429/503/504 responses receive bounded retries honoring Retry-After.
Batch retries apply only to identified failed subrequests; SDK envelope retries
are disabled temporarily to avoid replay. Persistent failures remain visible.

Pester mocks every Graph operation. Missing mock/stub commands must be fixed
in the test harness, never by connecting to a tenant. Run the full suite and
PSScriptAnalyzer as documented in [README.md](..\README.md).
