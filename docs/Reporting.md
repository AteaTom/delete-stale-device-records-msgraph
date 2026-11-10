# Reporting

Each invocation creates `output\<yyyyMMdd-HHmmss>\` under `-OutputPath`,
adding a run-ID suffix on collision. CSVs use UTF-8 and are written even when
empty. Initial reports precede approval; final reports reconcile journal
outcomes. Existing run folders are not rewritten.

| File | Contents |
| --- | --- |
| `AllEvaluatedDevices.csv` | Every normal-run Entra evaluation, activity, correlation, reason and action |
| `DeletionCandidates.csv` | Candidate subset, not proof of completed deletion |
| `DeletedDevices.csv` | Newly removed normal-run devices |
| `UnknownDevices.csv` | ManualReview subset |
| `AmbiguousMatches.csv` | Ambiguous correlation subset |
| `ADSyncedDevices.csv` | Primary reason OnPremisesSyncProtected; SourceADDeletionSafety=NotAssessed |
| `OnPremisesSyncedReview.csv` | Deprecated compatibility alias; do not double-count |
| `AutopilotProtectedDevices.csv` | Primary reason AutopilotProtected |
| `ExcludedDevices.csv` | Other exclusions, excluding the two dedicated protection reports |
| `ErrorDevices.csv` | Evaluated devices with errors |
| `ScrappedDeviceResults.csv` | Scrapped object-level correlation/results, exclusions and lookup failures; empty for normal cleanup |
| `ActionResults.csv` | One row per unique planned DELETE operation |
| `RunSummary.json` | Final run, workflow, counts, timestamps and exit code |
| `ExecutionLog.txt` | Timestamped operational events, warnings and reconciled completion totals |
| `DeletionPlan.json` | Tenant/run/workflow, creation time, operation IDs, prerequisites and content hash |
| `DeletionJournal.jsonl` | Append-only intent, delta outcomes and full final checkpoint |

## Interpreting the two-run workflow

Scrapped plans and action CSVs contain **Intune/Autopilot only**. Related
Entra identifiers remain informational in scrapped rows; their
`EntraRemovalStatus` stays `NotAttempted`. The console displays Entra objects
as retained, not planned DELETEs. Successful deregistration submission is
`RemovalSubmitted`; it is not proof of service/portal disappearance.

| Scrapped CleanupOutcome | Meaning |
| --- | --- |
| Pending | An Autopilot request was accepted, or optional Intune read-back remains pending |
| Complete | All applicable Intune/Autopilot targets have terminal successful outcomes; does not claim Entra removal |
| DeferredToInactivity | Correlated row has no Intune/Autopilot target; Entra is retained |
| Partial | Some applicable service targets succeeded and another failed/unresolved |
| Blocked | Failure/unresolved outcome without successful targets |
| Simulated | Applicable operations were WhatIf |
| Excluded / NotFound / LookupFailed / NotAttempted | Safety exclusion, no reliable current match, discovery failure, or no submission |

Accepted Autopilot submission alone can yield exit 0 with Pending serials.
HTTP 200 remains OutcomeUnknown and yields a non-success result; neither
portal absence nor a removed object is inferred. `-VerifyDeletion` never
reads Autopilot. Intune verification failure/pending remains visible in
verification fields and affects the exit result.

The later normal run creates its own reports and Entra-only plan. It uses
fresh discovery, retained safety evidence, `DaysInactive` and all protections.
Scrapped reports and journals are not replayed for Entra deletion.
`-ResumeLatest` / `-ResumeFromRunPath` explicitly throw before initialization.

## Activity and protection evidence

Normal report columns include platform, Entra IDs, current Intune/Autopilot
associations, activity, cutoff, correlation confidence, reason and statuses.
`RetainedSerialNumbers` exposes retained serial associations used for
protection. `ActivitySource=RetainedActivityEvidence` identifies a retained
timestamp newer than current signals. `UnresolvedSafetyEvidence` identifies
missing historical Intune activity, conflicting/changed IDs or unsafe retained
serial associations requiring manual review.

Durable evidence lives in `-EvidencePath`, default repository-relative `.state`,
**not** in temporary run reports. Protect/back up this directory and retain it
across upgrades and changes of output location. It is not approval or a queue.
`SafetyEvidenceSaved` records its path and device count before execution.
See [Architecture.md](Architecture.md) for atomic updates and corruption checks.

Dates export as invariant UTC round-trip strings, preserving fractional
seconds. Typed local/offset dates are converted to UTC; unspecified dates
require an explicitly UTC field contract. Historical timezone-free CSV dates
must not be guessed as precise UTC evidence. Names are informational only.

## Action and summary reconciliation

Action fields include RunId, Workflow, FinalizedTimestampUtc, OperationId,
Resource, ObjectId, DeviceName, EntraDeviceId, SerialNumber, Action, ReasonCode,
Outcome, Attempts, HttpStatus, VerificationStatus and sanitized ErrorMessage.
Finalization time is not deletion time; use journal timestamps for submission.

`TotalPlannedActions` equals action rows and the sum of `ActionOutcomes`.
`TotalAttemptedActions` counts unique operations with Attempts > 0;
`TotalRetryAttempts` counts extra submission attempts. Audit/WhatIf attempts
are zero. `Removed` is distinct from `AlreadyAbsent`, `RemovalSubmitted`
and verification evidence. Historical VerifiedAbsent Autopilot statuses remain
readable but new scrapped runs do not generate them by polling.

Scrapped Entra-removal summary counters are retained for report compatibility
and remain zero in new runs. Related Entra IDs remain informational in scrapped CSV rows.
Scrapped summaries omit DaysInactiveThreshold/CutoffDateUtc; normal summaries
include them. Pending, Complete, Partial, Blocked and other serial totals use
unique normalized serials, not expanded correlation-row counts.
`TotalRunErrors` can overlap device/serial errors; do not add them as unique
errors.

For normal runs:

```text
TotalEvaluated = TotalCandidates + TotalExcluded + TotalManualReview
TotalExcluded = ADSyncedDevices rows + AutopilotProtectedDevices rows + ExcludedDevices rows
```

Routing uses each device's primary reason, not a second classification pass.
Protection/ambiguity can precede Autopilot; Autopilot precedes AD-sync.

## Live logging and journal readers

Follow `ExecutionLog.txt` with `Get-Content -LiteralPath '<run>\ExecutionLog.txt' -Wait`.
Resolution logs inventory counts, indexes, progress every 100 serials and
elapsed time. Export and plan building have separate boundary events.
Deletion logs start, service phases, batch submissions, retries, per-operation
ActionResult progress, and terminal ActionAttention warnings. The completion
block and summary JSON share the same finalized counts. Cancelled, error-free
runs show a concise cancellation message while retaining detailed log evidence.

Successful scope lists and discovery-start details use Verbose; Debug uses
the debug stream. Neither is duplicated into the normal log. Error bodies
are restricted to sanitized code/message, not raw payloads or credentials;
embedded line breaks/quotes are escaped in text logs.

New journal records have SchemaVersion=2. Approved/Final are full checkpoints;
Submitting/Response/Verification contain affected-operation updates. Do not
treat intermediate records as complete snapshots. `Read-DeviceDeletionJournal`
streams to a final checkpoint and rejects malformed/incomplete final records.
Legacy full final checkpoints remain readable for investigation. See
[BatchDeletion.md](BatchDeletion.md) for the schema and recovery contract.
