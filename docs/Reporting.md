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
| `ExcludedDevices.csv` | Subset with `Decision = Excluded` |
| `ErrorDevices.csv` | Subset with a non-null `ErrorMessage` |
| `OnPremisesSyncedReview.csv` | Stale client devices excluded specifically by the default on-premises sync protection; header-only when there are no such devices |
| `ScrappedDeviceResults.csv` | Object-level Intune/Autopilot/Entra targets and outcomes, plus excluded/ambiguous/unmatched or lookup-failed serials; empty outside scrapped cleanup |
| `RunSummary.json` | Machine-readable run outcome (counts, exit code, timestamps) |
| `ExecutionLog.txt` | Human-readable structured log (DEBUG/INFO/WARNING/ERROR/SUCCESS) |
| `DeletionPlan.json` | JsonBatch only: tenant/run/workflow, creation time, unique operations, prerequisites and SHA-256 hash; written before confirmation |
| `DeletionJournal.jsonl` | JsonBatch only: append-only submission intent, per-ID outcomes, attempts and final/verification checkpoints |

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
verified Autopilot absence before Entra are displayed explicitly. These are
alternatives, not combined workflows: `-ScrappedDevices` bypasses stale cleanup.

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

Individual processing sends one supported Graph request per unique target;
opt-in JsonBatch uses the same target/dependency policy. Each request uses
the existing retry policy for transient failures, and a failed target is
reported individually while processing continues for unrelated targets.

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

Scrapped Autopilot read-back is mandatory before dependent Entra operations,
not controlled by the optional final `VerifyDeletion` flag. Individual reports
include its verification status too. Simulations report `NotRequested`, never
`VerifiedAbsent`. If correlation evidence is gone, `NotFound` is not proof
that an historical Entra object was deleted.
