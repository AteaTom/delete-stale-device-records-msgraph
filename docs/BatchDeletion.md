# Device deletion batching

All production deletions use the [Microsoft Graph v1.0 JSON batching
contract](https://learn.microsoft.com/graph/json-batching): at most 20
independent DELETE requests per envelope, not 20 physical devices. `BatchSize`
accepts 1-20. Requests and responses are correlated by unique ID, not
position. Outer HTTP 200 is not proof of successful removal.

## Public functions

| Function | Responsibility |
| --- | --- |
| `New-DeviceDeletionPlan` | Pure planner consuming validated records; deduplicates IDs, records Intune prerequisites and computes a SHA-256 content hash. |
| `Invoke-DeviceDeletionPlan` | Guarded phased execution of an explicitly approved plan; returns per-object results. |
| `Set-DeviceDeletionResults` | Fans unique-operation results back into report rows without performing Graph calls. |
| `Test-DeviceDeletionOutcome` | Bounded read-only verification of an exact identity in the approved tenant. |
| `Assert-DeviceCleanupContext` | Validates tenant, delegated authentication, public-cloud environment and required scopes. |

The module includes `src\DeviceDeletionBatch.ps1`; import the module manifest,
not this implementation file directly. The planner is not a CSV classification
replacement. Only the existing classification/resolution pipeline should
supply its input. Low-level function callers must explicitly validate their
candidates, review the plan, and supply its exact `ApprovalHash`,
`-ConfirmDeletion` and non-Audit `Mode` before execution.

## Workflow policy

Stale cleanup plans only eligible Entra objects without Autopilot. Scrapped
cleanup plans Intune removal, Windows Autopilot identity removal, then eligible
Entra removal.
All required Intune operations for the serial must succeed before Autopilot.
Entra prerequisites include required Intune removals and accepted Autopilot
DELETE responses for all associated identities. Read-back does not run between
the Autopilot and Entra phases. Optional `-VerifyDeletion` runs after all
planned DELETE operations and records absence separately from API acceptance;
it does not gate dependent Entra targets. No arbitrary batch
`dependsOn` graph is constructed and no serial-based `deleteDevices` action
is used.

Protection, supported client platforms, ambiguity handling and the stale
180-day minimum are enforced before batch planning and are not changed by the
transport.

## Confirmation and durable evidence

The script writes `DeletionPlan.json` before interactive confirmation. The
console displays the connected tenant, unique operation count and plan hash.
Interactive still requires the exact word `DELETE`; Automatic still requires
`-ConfirmDeletion`. Audit submits no destructive envelopes.

The executor deep-copies the plan, validates its hash, workflow, IDs,
prerequisites and age (default 30 minutes), and checks context/scopes before
each destructive envelope. It calls `ShouldProcess` per target. Declined
targets never become successful prerequisites. WhatIf uses the same planning
and phase simulation, creates local journal evidence, and submits no
destructive Graph requests. The hash binds content, not an approver's identity;
protect the report directory using appropriate access controls.

`DeletionJournal.jsonl` is reserved using exclusive create-new semantics.
Intent is persisted before submission; responses and final results are appended
afterward. Reusing a journal is rejected rather than replaying it. It records
tenant/run/hash, timestamp, submitted IDs, attempts, status and errors.
Even if execution throws, final report generation reads the journal to retain
partial outcomes. An incomplete or corrupted journal requires manual review,
not automatic replay.

## Partial failures and retries

Batching is not atomic. Successfully removed records are not rolled back.
Recognized HTTP 204 is API success; Autopilot uses `RemovalSubmitted` rather
than claiming immediate disappearance. Entra 404 is `AlreadyAbsent`, not
“deleted by this run.” Intune/Autopilot 404 is not silently accepted.

Only 429/503/504 subrequests enter the bounded retry queue (default five
attempts and 300 seconds of elapsed/backoff budget per chunk). Honor
`Retry-After`, including HTTP-date values, with exponential backoff and jitter
as needed. A permanent failure is logged and is not retried.
The elapsed budget is rechecked after backoff before another envelope is sent.
Authorization failure, unexpected/missing/duplicate response identity or
malformed response stops further execution. An envelope failure is
`OutcomeUnknown`, never automatic success.

The executor temporarily disables SDK envelope retries using
[`Set-MgRequestContext -MaxRetry 0`](https://learn.microsoft.com/powershell/module/microsoft.graph.authentication/set-mgrequestcontext?view=graph-powershell-1.0)
and restores the prior value in `finally`. Do not concurrently run other
Graph work in the same PowerShell process while this executor is active.
If restoring SDK retry settings fails, received per-object outcomes are still
journaled and remaining execution stops. A restoration error does not replace
a known DELETE response or hide an original request failure.
Only failed, individually identified transient subrequests are re-batched.
Lost envelope responses must be reconciled read-only before a new run.
Batch and verification requests use relative `/v1.0/...` SDK routes.
Absolute URLs can mutate the Graph SDK environment (observed locally with
Authentication 2.37.0), leaving the authentication endpoint empty when
retry configuration resets the HTTP client. This can fail a later envelope
with `Invalid URI`; relative routes preserve the connected environment.
See [Microsoft throttling guidance](https://learn.microsoft.com/graph/throttling#throttling-and-batching).

## Optional verification

`-VerifyDeletion` optionally enables bounded final verification after deletion
phases. It is separate from dependency handling: an accepted Autopilot DELETE
is the prerequisite for related Entra removal. Remaining successful IDs are
read at most three times with five-second intervals. An exact-route read-back
404 becomes `VerifiedAbsent`; continued visibility becomes
`VerificationPending`; denied/failed reads become `OutcomeUnknown`, with a
logged error. These are separate verification fields, not replacements for
the original DELETE status. Verification uncertainty produces a non-success
run outcome. Portal absence/appearance is not the API verification contract.

This is not an atomic pre-delete activity recheck. Plans expire and cannot
grow after approval, but activity can change after discovery and timestamps
remain approximate. No rollback, universal conditional-delete guarantee, or
automatic recovery/replay is claimed.

## Rollout and validation

Offline Pester tests mock Graph, including raw requests and SDK retry controls.
Use the complete suite and repository analyzer configuration:

```powershell
Invoke-Pester -Path '.\tests' -Output Detailed
Invoke-ScriptAnalyzer -Path '.\src' -Recurse -Settings '.\PSScriptAnalyzerSettings.psd1'
```

No live tenant behavior is established by these tests. Before production,
explicitly validate disposable lab identities, consent/roles, exact batch
routes, permission errors, partial outcomes, eventual consistency and
verification. Never infer a performance multiplier from the 20-request limit.
One envelope is in flight at a time.

### Operator-run validation procedure

Do not replay an interrupted plan. Preserve its plan, journal, reports and
separate read-only reconciliation results. Historical `OutcomeUnknown`
entries remain evidence even after a later read establishes presence.
Current-tenant remaining candidates are not disposable validation fixtures.

Start a fresh PowerShell 7 process in the feature worktree and import
`.\src\StaleDeviceCleanup.psd1 -Force` before use. This clears SDK state from
older absolute-URL requests. Supply an explicit tenant GUID and confirm the
displayed tenant and delegated authentication on every run.

Run fresh discovery with read scopes only:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -TenantId '<tenant-guid>' `
    -Mode Audit -DaysInactive 1100 `
    -OutputPath '.\output\batch-audit-validation'
```

Choose the inactivity threshold appropriate to the reviewed policy (never
below 180 days). Check the candidate report, classifications, newest activity,
protection, IDs, ISO UTC CSV dates, and agreement with the plan/summary.
An Audit run creates no deletion journal. It requests read scopes, but an
existing consented session may contain additional scopes.

Simulate execution using the same tenant and threshold:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -TenantId '<tenant-guid>' `
    -Mode Automatic -ConfirmDeletion -WhatIf -DaysInactive 1100 `
    -BatchSize 1 `
    -OutputPath '.\output\batch-whatif-validation'
```

Keep `-WhatIf` present: without it this command performs real deletion.
This simulation can request write-scope consent. Require `WhatIf` outcomes,
zero journal attempts/submitted IDs, zero removed counts and matching target
sets (or explain changes from new discovery). It does not validate HTTP batch
submission, server authorization, throttling or deletion verification.

**Real deletion validation requires separate administrator authorization
and disposable lab records.** Use a dedicated lab tenant whose entire eligible
set has been reviewed. The script has no arbitrary target allowlist: if any
candidate is not an approved disposable fixture, stop.

To exercise the second-envelope fix, use at least two naturally eligible
disposable lab Entra objects and `BatchSize 1`. Never fabricate inactivity,
weaken the 180-day minimum or bypass protection to create fixtures. If safe
eligible fixtures are unavailable, defer live deletion.

Only the authorized operator runs the following, after reviewing a fresh lab
Audit and WhatIf. It performs irreversible deletion:

```powershell
$beforeRetry = [int](Get-MgRequestContext).MaxRetry
.\src\Invoke-StaleDeviceCleanup.ps1 -TenantId '<lab-tenant-guid>' `
    -Mode Interactive -DaysInactive 180 `
    -BatchSize 1 -VerifyDeletion -OutputPath '.\output\lab-batch-validation'
$runExitCode = $LASTEXITCODE
$afterRetry = [int](Get-MgRequestContext).MaxRetry
```

Review the newly displayed target set and hash before typing `DELETE`. Use
the same agreed threshold in all lab stages. This creates a new approved
plan, not a replay of the historical current-tenant plan.

Acceptance requires at least two completed envelopes, no invalid-URI errors,
the expected connected cloud environment remaining usable, unchanged
`MaxRetry`, zero run errors, and matching unique operation IDs/statuses across
the plan, journal and reports. Each successful disposable identity should
have `VerifiedAbsent` from exact-ID read-back; HTTP 204 alone is acceptance,
not proof of observed absence. Record the SDK version and observed evidence;
do not interpret this small exercise as a performance benchmark.

Stop on any unknown outcome, authorization error, inconsistent evidence or
pending verification. Reconcile exact IDs read-only in the approved tenant,
save separate results, and do not automatically replay or switch transports.
Scrapped Intune/Autopilot dependency behavior needs its own separately
authorized disposable Windows lab fixtures; an Entra-only exercise does not
validate those routes. Production rollout remains a separate operator decision.

Microsoft recommends a disable/grace-period policy for ordinary stale devices
and appropriate retirement of MDM-managed devices:
[stale-device guidance](https://learn.microsoft.com/entra/identity/devices/manage-stale-devices).
This change does not introduce a grace-period ledger or remote wipe/retire
actions. Ordinary standalone Entra deletion remains direct after existing
eligibility checks; review that operational policy separately.
