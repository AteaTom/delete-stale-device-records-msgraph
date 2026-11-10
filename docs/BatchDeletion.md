# Batch deletion

## Plans and safety

All destructive Graph calls use v1.0 JSON batching through
`Invoke-MgGraphRequest`. Each envelope holds at most 20 operations, not
necessarily 20 computers. `-BatchSize` accepts 1-20.
[Microsoft's batch reference](https://learn.microsoft.com/graph/json-batching)
defines per-request IDs, independent statuses and throttling.

Before confirmation, the script exports reports and `DeletionPlan.json`,
displays tenant, mode, WhatIf, unique operation counts and SHA-256 plan hash.
The executor deep-copies and validates the approved plan. Hashes bind content,
not approver identity; protect artifacts using filesystem access controls.

| Workflow | Allowed resources and dependencies |
| --- | --- |
| Stale | Entra only |
| Scrapped | Intune then Autopilot; Autopilot can depend only on Intune |

Entra operations in a scrapped plan are rejected even with a valid content
hash. Each envelope checks delegated context, public cloud, tenant, scopes
and the 30-minute plan lifetime. No automatic approval renewal occurs.
Audit/unapproved runs never submit destructive envelopes. Per-target
ShouldProcess, WhatIf and explicit administrator intent remain required.

## Deregistration submission

Scrapped cleanup removes each unique Intune target first. Failed or declined
prerequisites block its Autopilot identity; independent identities continue.
There is **no Entra phase** for scrapped mode.

The [Autopilot identity DELETE reference](https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-delete?view=graph-rest-1.0)
documents HTTP 204. This means `RemovalSubmitted`, not completed deregistration.
HTTP 200 is unexpected and remains `OutcomeUnknown`, with diagnostic error
text where supplied. It causes no immediate GETs, sleeps or automatic DELETE
retry. Autopilot completion is never polled, including with `-VerifyDeletion`.

The next normal run reloads inventories and evaluates remaining Entra objects
against inactivity and protection rules. Resume selectors are retired;
historical plans/journals never bypass inactivity classification.

## Responses, retries and verification

The outer batch HTTP 200 is not per-operation success. Subresponses are
correlated by ID; missing, duplicate, unexpected or malformed identities fail
closed. Authorization failures stop remaining execution. Unknown envelopes
are journaled and never automatically replayed.

Only identified 429/503/504 subrequests enter the bounded retry queue:
default five attempts and 300 seconds per chunk, honoring numeric/HTTP-date
Retry-After with exponential backoff and jitter. Permanent failures do not
retry. SDK envelope retries are temporarily disabled and restored because an
envelope retry could replay already completed subrequests. SDK routes remain
relative to avoid environment mutation from absolute request URLs.

Entra 404 is `AlreadyAbsent`, not newly removed. Intune/Autopilot 404 is not
silently treated as successful removal. Preserve uncertain outcomes and
reconcile exact IDs read-only before approving a new run.

`-VerifyDeletion` optionally reads successful Intune/Entra IDs up to three
times with five-second intervals. 404 establishes `VerifiedAbsent`; continued
visibility is `VerificationPending`; failed/denied reads are `OutcomeUnknown`.
The verification result is separate from the DELETE outcome. Optional
per-target verification can be slow on large Intune batches; it does not
provide an atomic pre-delete guarantee.

## Journal schema and recovery

The journal is created exclusively; an existing journal cannot be reused.
Version 2 JSONL records contain `SchemaVersion`, timestamp, run, tenant,
plan hash, event, submitted IDs and results:

- `Approved` and `Final` contain full ordered result checkpoints.
- `Submitting` records the affected IDs and uncertain submission intent before
  the Graph request.
- `Response` contains parsed outcomes for that submitted batch before optional
  verification.
- `Verification` contains the changed verified operation.
- Chunk/phase/envelope-failure markers may have no result entries; the final
  checkpoint retains the complete state, including failures and unattempted IDs.

Do not interpret delta events as full snapshots. Finalization streams the
journal and uses only a valid final checkpoint. It rejects malformed,
incomplete or unsupported-schema final records rather than selecting an
older success. Legacy unversioned full final checkpoints remain readable via
`Read-DeviceDeletionJournal` for investigation. Interrupted runs without a final
checkpoint require manual reconciliation, not automatic replay.

## Operator run-validation procedure

1. Run Audit with the intended tenant, evidence directory and protections.
   Review platform, activity, stable IDs, exclusions and exact target counts.
2. Run WhatIf with the same workflow and settings. Confirm zero destructive
   requests and scrapped plans containing no Entra operations.
3. Preserve reports and evidence. Do not start overlapping destructive runs
   or clear journals/state to bypass an error.
4. Only with separate authorization, validate a very small set of disposable
   lab devices (`-BatchSize 1`). Never use production candidates as test fixtures.
5. After deregistration completes, run normal inactivity Audit, review the
   remaining Entra candidates and obtain fresh approval.

Offline checks:

```powershell
$result = Invoke-Pester -Path '.\tests' -Output Detailed -PassThru
if ($result.FailedCount) { throw 'Offline suite failed.' }
Invoke-ScriptAnalyzer -Path '.\src' -Recurse -Settings '.\PSScriptAnalyzerSettings.psd1'
```

Offline mocks cannot establish live Graph propagation timing or validate
tenant consent/RBAC.
