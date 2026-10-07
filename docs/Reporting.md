# Reporting

Every execution creates a timestamped folder: `output\<yyyyMMdd-HHmmss>\`.
Legacy lifecycle files may exist at the output root but are not used as a
deletion gate.

All CSV files use UTF-8 encoding and are written even when empty (guaranteed
by `Export-ReportCsv`). Every row includes the run's `RunId`.

| File | Contents |
| --- | --- |
| `AllEvaluatedDevices.csv` | Every Entra device evaluated, with full detail and `Decision` |
| `DeletionCandidates.csv` | Subset with `Decision = Candidate` — written **before** any confirmation prompt |
| `DeletedDevices.csv` | Subset where `EntraRemovalStatus` = `Removed`, or `AutopilotRemovalStatus` is `Removed`/`AlreadyRemoved` |
| `UnknownDevices.csv` | Subset with `Decision = ManualReview` |
| `AmbiguousMatches.csv` | Subset with `MatchStatus = Ambiguous` |
| `ExcludedDevices.csv` | Other `Decision = Excluded` records, excluding `OnPremisesSyncProtected` and `AutopilotProtected` |
| `ADSyncedDevices.csv` | Devices excluded with primary reason `OnPremisesSyncProtected`; includes `SourceADDeletionSafety = NotAssessed` |
| `AutopilotProtectedDevices.csv` | Devices excluded with primary reason `AutopilotProtected`, including correlation and AD-sync evidence |
| `ErrorDevices.csv` | Subset with a non-null `ErrorMessage` |
| `OnPremisesSyncedReview.csv` | Compatibility alias of `ADSyncedDevices.csv`; deprecated name retained for existing consumers |
| `ScrappedDeviceResults.csv` | Object-level Intune/Autopilot/Entra targets and outcomes, plus excluded/ambiguous/unmatched or lookup-failed serials; empty outside scrapped cleanup |
| `RunSummary.json` | Machine-readable run outcome (counts, exit code, timestamps) |
| `ExecutionLog.txt` | Human-readable timestamped INFO/WARNING/ERROR/SUCCESS events and final summary; verbose/debug detail is not written here |
| `ActionResults.csv` | One final row per unique planned DELETE operation, including unattempted or simulated targets |
| `DeletionPlan.json` | Tenant/run/workflow, creation time, unique operations, prerequisites and SHA-256 hash; written before confirmation |
| `DeletionJournal.jsonl` | Append-only submission intent, per-ID outcomes, attempts and final/verification checkpoints |

## Administrator logging and reconciliation

All new reports use the existing run folder and UTF-8 CSV helper. Protection
reports and `ActionResults.csv` have stable headers even when empty.
CSV reports are snapshots: written before confirmation where applicable and
overwritten with final results within that run, never appended. Execution
events and the deletion journal remain append-only within the run. Historical
artifacts are not migrated or rewritten.

Protection routing uses the classifier's existing **primary reason**, not a
second eligibility evaluation. Autopilot protection precedes AD-sync protection:
a device associated with both goes only to `AutopilotProtectedDevices.csv`,
with `OnPremisesSyncEnabled` retained. Explicit protection and unsafe correlation
can take precedence; those records retain their existing reason/report routing.
Recent or missing activity on an AD-synced device does not make it an
`OnPremisesSyncProtected` record. The explicit AD-sync override is unchanged.

`AllEvaluatedDevices.csv` still contains every evaluated device. Reconcile:

```text
TotalEvaluated = TotalCandidates + TotalExcluded + TotalManualReview
TotalExcluded = ADSyncedDevices rows + AutopilotProtectedDevices rows + ExcludedDevices rows
```

This intentionally changes `ExcludedDevices.csv` membership. Consumers needing
all exclusions must filter `AllEvaluatedDevices.csv` by `Decision = Excluded`,
or combine the three mutually exclusive reports. Do not also count the
compatibility alias. The scrapped workflow continues to report exclusions in
`ScrappedDeviceResults.csv`; Autopilot presence is not protection from an
explicit, safely correlated scrapped cleanup.

Device reports identify the run, evaluation time, friendly name, platform,
Entra object/device IDs, available Intune/Autopilot IDs and serials, primary
reason/description, correlation confidence, activity evidence and action
outcome. Names are for recognition, never correlation authority. Missing values
stay empty rather than being guessed.

`ActionResults.csv` is finalized after journal recovery and includes `RunId`,
`Workflow`, `FinalizedTimestampUtc`, `OperationId`, `Resource`, `ObjectId`,
`DeviceName`, available `EntraDeviceId` and `SerialNumber`, `Action`,
`ReasonCode`, `Outcome`, `Attempts`, `HttpStatus`, `VerificationStatus` and
sanitized `ErrorMessage`. The timestamp describes finalization, **not** the
time of deletion; use journal timestamps for submission/checkpoint evidence.
Expanded scrapped rows are collapsed by the plan's unique resource/object ID.

The completion block is written to the console and normal log from the same
finalized `RunSummary.json` data. Additive fields include `TenantId`,
`TotalADSyncedDevices`, `TotalAutopilotProtectedDevices`,
`TotalOtherExcludedDevices`, `ExclusionsByReason`, `ManualReviewByReason`,
`ScrappedExclusionsByReason`, `TotalPlannedActions`, `TotalAttemptedActions`,
`TotalRetryAttempts`, `ActionOutcomes`, `ActionsByResource`,
`TotalVerificationPending`, `TotalVerificationUnknown` and `TotalRunErrors`.
Existing JSON fields keep their meaning.
When an administrator cancels Interactive confirmation (exit code 5), with no
attempted deletions or reported errors, the console instead shows
`Deletion cancelled. No changes were made.` and the report path. This applies
to both workflows, including `-WhatIf`. The detailed completion block remains
in `ExecutionLog.txt`, and JSON/CSV reports are still finalized with unattempted
actions recorded as `NotAttempted`. Runs with errors retain the detailed console
summary so cancellation does not hide failures.
Direct module callers must supply finalized `ActionRecords` to
`New-RunSummary` and `Complete-ProjectExecution` for operation totals and the
action CSV; the script obtains these through `Get-CleanupActionRecords`.

`ActionOutcomes` counts final statuses; its values sum to `TotalPlannedActions`
and to `ActionResults.csv` rows. An attempted action has `Attempts > 0`, counted
once even if retried; `TotalRetryAttempts` counts extra submission attempts.
Submission intent without a trustworthy response remains `OutcomeUnknown`,
not success. Audit/WhatIf actions have zero actual submission attempts.
`Removed` is distinct from `AlreadyAbsent`/`AlreadyRemoved` and
`RemovalSubmitted`; accepted Autopilot submission does not establish absence.
Verification uncertainty remains separate from the DELETE outcome.
`TotalRunErrors` counts errors reaching the run-level catch, including failures
before any device can be evaluated; it can overlap device/serial errors and
must not be added to them as a unique-error total.

Normal logging keeps successful discovery counts, tenant identity, planning,
authorization/safety gates, retry-round warnings, terminal operation failures,
verification uncertainty and the completion summary. Each failed/unknown/blocked
operation has a final `Event=ActionAttention` warning with run, resource,
object ID, outcome, attempts, HTTP status and reason. A failed retry budget is
visible even when no final Graph response exists. Successful individual results
are in the action CSV and journal, not repeated in the normal log.

Discovery starts, successful scope lists, protected-input paths and individual
batch responses use `-Verbose`; DEBUG uses the debug stream. Neither diagnostic
level is appended to `ExecutionLog.txt`. Preserve diagnostic streams using your
PowerShell wrapper when needed; the journal still retains submission and retry
evidence. Graph response detail is restricted to error code/message, not raw
response dumps. Credential fields and bearer values are redacted from log/error
text, and embedded newlines/quotes are escaped in text events.
Credential redaction handles escaped quotes, and verification error text is
sanitized before it reaches the journal or device CSV reports.
Do not deliberately
include credentials, tokens or unrelated personal data in diagnostic messages.
Log-file write failures remain visible as warnings.

## Evaluated-device columns

Pre-confirmation summaries are workflow-specific. Both display tenant, mode,
WhatIf state and transport. Audit and WhatIf explicitly state that no tenant
DELETE requests will be sent; displayed targets are planned, not completed.

Stale cleanup shows unique actionable Entra objects by platform, with
Autopilot-backed devices listed as retained rather than deletion candidates.
Explicit protection and on-premises sync protection have separate counts.
No Intune or Autopilot deletion is planned by this workflow.

Scrapped cleanup shows matched serials separately from serials with actual
Intune/Autopilot/Entra DELETE targets. Counts of unique objects sum to DELETE
operations, not physical devices. Required Intune success before Autopilot and
accepted Autopilot DELETE requests before Entra are displayed explicitly.
These are alternatives, not combined workflows: `-ScrappedDevices` bypasses
stale cleanup.

See `AllEvaluatedDevices.csv` header for the authoritative list; it matches
the field list documented in the project specification, including
`EffectiveLastActivityUtc`, `ActivitySource`, `MatchConfidence`,
`ReasonCode`, `ReasonDescription`, `EntraAction`, `EntraDisableStatus`,
`AutopilotRemovalStatus`, and `EntraRemovalStatus`. Timestamps are ISO 8601
UTC. Legacy lifecycle columns may remain in historical reports; they are no
longer used as a removal gate.

CSV export serializes typed `DateTime` and `DateTimeOffset` values as invariant
UTC round-trip strings, for example `2026-04-09T18:51:36.5885471Z`, preserving
fractional seconds. Local dates and offset-aware dates are converted to UTC.
An unspecified `DateTime` is treated as UTC only when its field name ends in
`Utc`; unspecified dates without that contract raise an export error.
Existing strings and nulls are not reinterpreted, and source objects remain
typed and unchanged.

Historical CSV files may contain timezone-free, second-precision dates from
default PowerShell formatting. Do not parse those as local timestamps or
infer lost precision; use matching JSON/log evidence where available.
Preserve historical run artifacts unchanged.

Autopilot-backed lifecycle records are excluded (`AutopilotProtected`) or sent
to manual review. Stale cleanup never submits an Autopilot DELETE.

Entra lifecycle statuses include `Removed`, `AlreadyAbsent` (batch-specific
idempotent completion, not deletion by this run), `RemovalFailed`,
`OutcomeUnknown`, `Declined`, `WhatIf`, `Skipped`, and
`NotAttempted`. `RunSummary.json` includes planned and completed removal
counts, and `ExecutionLog.txt` records the same counts at planning and
completion. `RunSummary.json` also includes
`TotalAutopilotRemovalSubmitted` separately from `TotalAutopilotRemoved`.
It also records `TotalOnPremisesSyncedReview` and whether the explicit
`AllowOnPremisesSyncedDeletion` override was enabled.
`TotalEntraDevicesAlreadyAbsent` counts batch idempotent completion separately
from records deleted by this run. Scrapped runs also include
`TotalScrappedExcludedSerials` and `TotalScrappedEntraToRemove`.
Scrapped summaries omit `DaysInactiveThreshold` and `CutoffDateUtc` entirely,
including empty-input and error runs. `ScrappedWorkflow` explicitly identifies
the chosen parameter set, not merely the presence of result rows.

`OnPremisesSyncedReview.csv` contains only otherwise-stale devices excluded
because they are synchronized from on-premises Active Directory. It includes
the Entra identifiers and available activity, sync, Intune, and Autopilot
evidence for an administrator to investigate in source AD. The
`SourceADDeletionSafety` field is always `NotAssessed`: this report is not a
recommendation or authorization to delete an AD computer object. This script
does not inspect or modify source Active Directory.

## Scrapped-device columns

`ScrappedDeviceResults.csv` includes: `InputSerialNumber`,
`NormalizedSerialNumber`, `MatchStatus` (`Matched`/`Ambiguous`/`NotFound`/`Excluded`/`LookupFailed`),
`AmbiguityReason`, `AutopilotIdentityId`, `AutopilotEnrollmentState`,
`IntuneManagedDeviceId`, `IntuneDeviceName`, `EntraObjectId`,
`EntraDeviceId`, `EntraDeviceName`, `CorrelationMethod`, and per-target `AutopilotRemovalStatus`,
`IntuneRemovalStatus`, `EntraRemovalStatus`. Scrapped-device Autopilot states
include `RemovalSubmitted`, `AlreadyRemoved`, `RemovalFailed`, `Declined`,
`WhatIf`, and `NotApplicable`.
Intune states include `Removed`, `AlreadyRemoved`, `RemovalFailed`, `OutcomeUnknown`, `Declined`,
`WhatIf`, `Skipped`, `NotApplicable`, and `NotAttempted`. Autopilot also uses
`BlockedDependency` when required Intune removal did not succeed.
Entra uses `Removed`, `AlreadyAbsent`, `RemovalFailed`, `BlockedDependency`,
`WhatIf`, `Declined`, `NotApplicable` and `NotAttempted`.
`AlreadyAbsent` is not counted as deletion by this run.

`IntuneLookupStatus`, `AutopilotLookupStatus` and `EntraLookupStatus` distinguish
`Found`, `NotFound`, `SkippedUnsafeCorrelation` and `FailedLookup`. On incomplete
inventory discovery, earlier successful services report
`LookupSucceededCorrelationBlocked`; later services report `NotAttempted`.
Incomplete discovery prevents all writes and does not establish absence.
Repeated rows share a per-serial `CleanupOutcome`: `Complete`, `Partial`,
`Blocked`, `Pending`, `Simulated`, `Excluded`, `NotFound`, `LookupFailed` or
`NotAttempted`. `Complete` requires every target to have a successful or
already-absent outcome, with Autopilot absence verified. Accepted-but-unverified
Autopilot removal (including `AlreadyRemoved`) is pending, not complete.
When optional final verification is requested, continued visibility produces
`Pending` and denied/failed read-back produces `Blocked` or `Partial`, never
`Complete`, even when DELETE was accepted. Confirmed unresolved cleanup exits
nonzero; Audit and WhatIf never claim real cleanup.

`RemovalSubmitted` means the supported Autopilot identity DELETE succeeded.
It confirms submission, not immediate disappearance from the Autopilot portal;
the service completes that work asynchronously.

For scrapped-device runs, the completion log and `RunSummary.json` count
Autopilot submissions, already-absent and failed objects, Intune removals,
and Entra removed, already-absent, failed and blocked objects by unique nonempty
object ID, not by expanded CSV row.
The summary also includes unique input, matched,
ambiguous, not-found, and error serial counts. This prevents one serial
expanded across multiple object rows from inflating completion totals.

Deletion uses Graph JSON batches of at most 20 unique target operations.
Identified transient failures are retried within bounded limits, and a failed
target is reported individually while processing continues for unrelated
targets where safe.

Only safely corroborated matches are reported as `Matched`; serial-only
collisions remain `Ambiguous`. Protection, unsupported/missing platforms,
synchronization protection and conflicting identifiers produce `Excluded`,
with the reason in `AmbiguityReason`.
Only `Matched` rows are ever acted on.

Before mode validation or an interactive deletion prompt, the console summary
shows unique counts for input and matched serial numbers, the number of
case-insensitive duplicate CSV rows ignored, exact unique Intune/Autopilot
records and Entra objects to remove, and ambiguous/excluded/not-found
serials. Blank rows and the required
header are excluded from the duplicate count.
`ScrappedDeviceResults.csv` is written first so its object-level rows can be
reviewed before confirmation.

## Reason codes

`MissingAllActivity`, `UnsupportedPlatform`, `MissingOperatingSystem`,
`AmbiguousAutopilotMatch`, `DuplicateSerialNumber`, `LowConfidenceMatch`,
`ProtectedDevice`, `OnPremisesSyncProtected`, `AutopilotProtected`, `RecentActivityDetected`, `DisabledTracking`,
`Stale`.

(`IncompleteGraphData`, `ConflictingIdentifiers`, and `GraphReadError` are
reserved reason codes for future per-device error handling refinements.)

## Batch outcomes and verification

The journal preserves partial outcomes if batching stops or throws. Requests
missing a trustworthy result remain `OutcomeUnknown`; do not rerun deletion
blindly. `AlreadyAbsent` is not counted as newly removed.

Optional `EntraVerificationStatus`, `IntuneVerificationStatus` and
`AutopilotVerificationStatus` distinguish `NotRequested`, `VerifiedAbsent`,
`VerificationPending` and `OutcomeUnknown` from the DELETE operation status.
Batch result mapping includes these columns on every row, using `NotRequested`
when no verification result applies, so CSV column selection cannot omit them.
Denied or unsuccessful read-back never establishes absence. Verification
uncertainty is logged and results in a non-success run outcome.
See [BatchDeletion.md](BatchDeletion.md).

Accepted Autopilot DELETE responses permit dependent Entra operations;
optional final `VerifyDeletion` read-back occurs afterward and does not gate
that dependency. Simulations report `NotRequested`, never `VerifiedAbsent`.
If correlation evidence is gone, `NotFound` is not proof
that an historical Entra object was deleted.
