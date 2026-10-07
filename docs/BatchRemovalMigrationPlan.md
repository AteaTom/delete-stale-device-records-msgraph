# Experimental batch-removal migration plan

Status: proposal only. No runtime behavior, Graph permissions, or deletion
defaults are changed by this document.

Prepared against module version `1.0.2` and repository baseline `e158cec` on
2026-10-06.

## Recommendation and scope

Reintroduce Windows Autopilot's serial-number-based `deleteDevices` action as
an explicitly selected experimental backend behind the existing safety
pipeline. Keep individual identity DELETE as the default and rollback path
until offline coverage, lab validation, and an owner-approved production pilot
justify promotion.

This plan interprets "experimental batch removal" as the Autopilot bulk action
previously implemented in this repository, not Microsoft Graph JSON `$batch`.
Initially replace only the Autopilot submission transport. Keep
`Remove-EntraDeviceRecord` and `Remove-IntuneManagedDeviceRecord` unchanged;
batching those systems is a separate follow-up, not a prerequisite.

Do not combine the stale-device and scrapped-device workflows. Stale cleanup
must still never delete Intune records; only the explicit scrapped-device
workflow may do so.

## Current implementation and lessons from history

| Surface | Current behavior / migration relevance |
| --- | --- |
| `src\Invoke-StaleDeviceCleanup.ps1` | Discovers all three systems, reports before confirmation, gates destructive modes, and calls `Submit-WindowsAutopilotIdentityRemoval` for High-confidence Windows candidates before individual Entra deletion. |
| `src\StaleDeviceCleanup.psm1` | `Submit-WindowsAutopilotIdentityRemoval` deduplicates identity IDs, calls `Remove-WindowsAutopilotRecord`, and returns identity-level status objects. |
| `Invoke-ScrappedDeviceRemoval` | Removes unique Intune records first, submits unique Autopilot identities, then removes unique Entra objects. Its row-level dependency handling needs strengthening before serial-level bulk results can safely authorize downstream cleanup. |
| Module manifest and script compatibility check | Export the identity helper and verify loaded module version/signatures. Both need updating when adding the experimental backend. |
| `tests\Safety.Tests.ps1`, `tests\ScrappedDevices.Tests.ps1`, `tests\Summary.Tests.ps1` | Cover mode gates, WhatIf, ordering, individual failures, deduplication, and reporting. Extend these rather than replacing existing coverage. |
| Historical commits `ee32827` and `9cf805d` | Introduced chunked bulk removal and explicit JSON serialization. Reuse lessons, not an unreviewed restoration of the old implementation. |
| Historical commit `0edbe0e` | Removed the bulk helper and switched production workflows to identity DELETE. The changelog describes the bulk route as unsupported; its claim that the helper remains is not true of the current source. |

Some comments/log messages still describe bulk chunks although the code sends
individual DELETE requests. Correct these when implementing the migration.
Do not treat changelog descriptions of old adaptive splitting or lifecycle
behavior as evidence that those mechanisms exist today.

## Microsoft API evidence and unresolved questions

Official documentation retrieved on 2026-10-06 describes:

| Mechanism | Documented contract | Implication |
| --- | --- | --- |
| Autopilot bulk action | `POST /v1.0/deviceManagement/windowsAutopilotDeviceIdentities/deleteDevices`, JSON body containing a `serialNumbers` string collection, and HTTP `200` with a `value` collection. | Use the documented v1.0 route in an isolated adapter. Route availability in the intended tenant remains unverified. |
| Bulk result | `serialNumber`, `deviceRegistrationId`, `deletionState`, `errorMessage`; states are `unknown`, `failed`, `accepted`, `error`. | HTTP `200` is not per-device success. `accepted` must not be reported as confirmed absence. |
| Individual identity DELETE | HTTP `204`; delegated permission `DeviceManagementServiceConfig.ReadWrite.All`. | Retain the supported existing backend and its safety gates. |
| Graph JSON `$batch` | Up to 20 subrequests, response correlation by request ID, individual statuses independent of outer HTTP `200`. | This is a different mechanism; its 20-request limit does not establish the serial limit for `deleteDevices`. |

The bulk-action page unusually lists read permissions for a destructive
action. Do not weaken the repository's write-scope gate based on that table.
Resolve the effective permission/role requirement using official guidance
and an explicitly authorized lab test before enabling real bulk submissions.
Audit must remain read-only and must never invoke this POST.

The retrieved bulk documentation does not specify a maximum serial count,
an idempotency guarantee, completion polling semantics, or whether
`deviceRegistrationId` is interchangeable with the discovered identity ID.
These are validation questions, not assumptions to encode as facts.

## Required safety contract

The transport change must preserve the 180-day minimum, newest trusted
activity signal, missing-evidence protection, identifier-based correlation,
protected-device exclusions, server exclusions, and Windows-only Autopilot
handling. Incomplete discovery or insufficient permissions must block writes.

Serial-based removal can address a broader set than identity-based removal.
Before sending a serial, compare its full discovered Autopilot identity set
with the exact approved target set. If another identity with that serial is
protected, ambiguous, out of scope, or not approved, block the entire serial.
Do not silently switch that serial to another backend.

For scrapped records, model dependencies explicitly by normalized serial and
unique object IDs, rather than relying on the first Autopilot identity copied
onto expanded report rows. A related Entra object may proceed only when every
required Autopilot identity for its group is satisfied. Shared Entra targets
must satisfy every dependency before being removed once.

The existing scrapped branch describes removal regardless of platform and
does not apply the stale branch's protection evaluation. That is in tension
with `AGENTS.md`'s global protection/platform invariants. Resolve this with
the owner before enabling the experimental backend for that branch; do not
copy the discrepancy into a new transport or expand eligibility implicitly.

## Proposed design

### Explicit backend selection

Add a proposed script parameter
`-AutopilotRemovalBackend Identity|BulkExperimental`, defaulting to `Identity`.
Pass it explicitly into the scrapped workflow as well. Backend selection
does not constitute deletion consent: Interactive still requires exact
`DELETE`, Automatic still requires `-ConfirmDeletion`, and Audit never writes.

Retain the existing identity helper. Introduce a shared dispatcher, proposed
as `Submit-WindowsAutopilotRemoval`, with an isolated
`Submit-WindowsAutopilotBulkRemoval` adapter. Both backends receive the same
already validated target/dependency plan; neither reclassifies stale devices.
Use `SupportsShouldProcess` and `ConfirmImpact = 'High'` on write-capable
entry points. Do not introduce a new SDK package unless actually required;
the existing Graph Authentication module provides the raw-request transport.

Export only the functions needed by the established public module pattern.
Update `FunctionsToExport`, `Export-ModuleMember`, module version, script
version, and loaded-module compatibility checks together.

### Planning, submission, and reconciliation

1. Build one non-destructive operation plan from the existing evaluated
   candidates or resolved scrapped records. Preserve original serial strings
   for submission; use `ConvertTo-NormalizedSerialNumber` for comparison.
   Reject invalid targets explicitly, deduplicate IDs/serials, and retain all
   dependency edges and evidence. Produce the same plan in Audit and WhatIf.
2. Before confirmation, show tenant ID, selected backend, unique serial count,
   exact Autopilot/Intune/Entra target counts, and blocked groups in reports.
   Validate the connected tenant again immediately before the first write.
3. Submit serial chunks sequentially. Start the lab pilot at 10 serials per
   chunk; propose an initial application cap of 100 after validation. These
   are project safety settings, not documented Microsoft limits. Validate
   any proposed `-AutopilotBulkBatchSize` and do not add parallel submission
   in the first release.
4. Serialize a plain `serialNumbers` string array to explicit JSON, including
   zero/one/many-target handling. Empty input produces no POST. Do not reuse
   PowerShell-adapted objects that caused the historical serialization issue.
5. Normalize dictionary and object responses into one result per approved
   identity. Join by normalized requested serial and verified registration
   mapping. Missing, duplicate/conflicting, unexpected, or malformed results
   must block the affected group and produce explicit diagnostics; never use
   "last response wins." An unmappable response blocks the whole chunk.
6. Treat `accepted` as submitted/pending. For the experimental backend,
   require read-only verification that all required identities are absent
   before related Entra deletion. Bound polling and elapsed time; expiry or
   a read failure leaves Entra untouched and reports a pending/unknown result.
   Alternatively defer reconciliation to a later discovery, but re-evaluate
   activity, protection, correlation, permissions, and operator consent then.

Requiring confirmed absence is a deliberate conservative behavior difference
from today's identity path, which proceeds after a successful DELETE response.
Gate it with the experimental backend and document it before release. Do not
restore the obsolete disable/retention lifecycle as part of this migration.

### Result contract and error handling

Keep existing fields `IdentityId`, `SerialNumber`, `Status`, `ErrorMessage`.
Add structured backend, chunk/attempt ID, raw deletion state, registration ID,
HTTP/Graph error code, and confirmation timestamp where available.

Distinguish planned WhatIf, declined confirmation (`Skipped`), submitted,
confirmed absent, already absent, failed, and indeterminate outcomes.
`WhatIf` is never real authorization for downstream deletion. A declined
`ShouldProcess` must not be mislabeled WhatIf. Handle verified `AlreadyRemoved`
consistently in both workflows without treating arbitrary failures as absence.

Reuse `Invoke-GraphWithRetry` where safe, but review its replay behavior for
this POST. Retry only documented transient rejection cases with bounded
attempts/backoff and `Retry-After`. Do not replay accepted successes or a
timeout/connection loss with an unknown server-side outcome until read-only
reconciliation and validated idempotency rules make that safe.

Treat authorization and unavailable-route failures as backend-wide blockers.
Do not automatically switch to identity DELETE mid-run. Preserve results,
stop further bulk submissions where the failure is systemic, and require a
fresh reviewed run for rollback. Independent chunks may continue only after
isolated, determinate input failures; do not recursively split every `400`.

Persist operation outcomes after each chunk and rewrite device reports during
finalization. Unprocessed, pending, or indeterminate intended operations must
not result in exit code `0`; use the existing nonzero contract, initially `6`,
and document its extension. Avoid logging tokens or authentication headers.

## Implementation sequence and acceptance gates

| Phase | Work and affected surfaces | Exit gate |
| --- | --- | --- |
| 1. Establish contract and validate API | Resolve permission/role, tenant route, serial scope, registration mapping, retry semantics, and scrapped safety conflicts. Define backend/result/dependency contracts. | Owner-approved scope and recorded lab evidence; no production bulk writes. |
| 2. Add isolated backend | Implement non-destructive plan builder, dispatcher, bulk adapter, bounded chunking, strict parser, and reconciliation in `src\StaleDeviceCleanup.psm1`. Add dedicated `tests\BatchRemoval.Tests.ps1` and extend `tests\TestHelpers.ps1` mocks. | Unit acceptance matrix below passes; existing identity behavior remains covered. |
| 3. Wire both workflows | Update `src\Invoke-StaleDeviceCleanup.ps1`, `Invoke-ScrappedDeviceRemoval`, exports/version checks, confirmation previews, and dependency gates. Keep scrapped integration blocked until phase 1 conflicts are resolved. | End-to-end mocks prove mode safety, full dependency ordering, and equivalent approved targets. |
| 4. Make outcomes auditable | Update report writers, `New-RunSummary`, finalization, and unique-object counters. Update README, Architecture, DecisionLogic, Permissions, Reporting, Troubleshooting, CHANGELOG, example settings/wrappers. | Submitted is distinct from removed; partial/interrupted runs remain reportable and nonzero. Example settings remain documentation-only, not automatically loaded. |
| 5. Authorized lab pilot | Audit and WhatIf first; explicitly consented destructive tests against disposable Windows lab records, progressing through 1, 10, and boundary-sized chunks. Validate real response shapes and eventual consistency. | No unexpected target, no blocked-group Entra write, and every intended object has a reconciled outcome. |
| 6. Controlled production opt-in | Owner-approved small capped cohort, reviewed reports, configured protection, monitored outcomes, and identity-backend rollback procedure. | Promotion requires documented safety and performance evidence; changing the default is a separate approval/release. |

Phases 2-4 depend on the agreed phase 1 contract; phase 5 requires all offline
gates from phases 2-4; phase 6 requires successful phase 5 evidence.
Read-only investigation and mock development do not authorize live deletion.

## Offline acceptance matrix

All Graph operations, including `Invoke-MgGraphRequest` and verification GETs,
must be mocked. Mock sleep for retry/polling tests.

| Area | Required assertions |
| --- | --- |
| Safety parity | Threshold 179 rejected; 180 accepted; recent activity wins; missing evidence, ambiguous correlation, protected devices, servers, unsupported platforms, and non-Windows Autopilot inputs cannot become bulk targets. |
| Operator intent | Both backends in Audit, WhatIf (including `-Confirm:$false`), cancelled Interactive, unconfirmed Automatic, wrong tenant, missing permissions, and incomplete discovery issue no destructive requests, including POST. |
| Chunk boundaries | At configured size N test 0, 1, N-1, N, N+1, and 2N+1 targets; assert exact JSON shape, ceiling(targets/N) POST count, serial order, and no chunk over the cap. |
| Target scope | Case/whitespace normalization, missing serial/identity, duplicate IDs/serials, shared serial with an unapproved identity, and expanded scrapped rows never broaden the approved deletion set. |
| Response parsing | Mixed `accepted`/`failed`/`unknown`/`error`, missing `value`, empty response, missing fields, reordered entries, extra serials, duplicate/conflicting states, and unknown registration IDs fail closed where required. |
| Reconciliation | Accepted is not removed; read-confirmed absence unblocks only its dependencies; polling timeout/read error leaves Entra untouched. Every identity for a multi-identity serial must be satisfied. |
| Failure isolation | Isolated chunk failure does not overwrite other outcomes; systemic 401/403/unavailable route stops submission; bounded transient retries honor delay; uncertain delivery is not blindly replayed or silently sent through identity fallback. |
| Ordering | Stale: Autopilot satisfaction before Entra; never Intune DELETE. Scrapped: successful required Intune cleanup before Autopilot, then all Autopilot dependencies before Entra. Failed prerequisites block descendants. |
| Reporting/recovery | Exact unique-object counts, submitted versus confirmed removed, skipped versus WhatIf, pending/unknown nonzero exit, persisted partial progress, and fresh eligibility/consent on rerun. |
| Compatibility | Existing identity selection/default behavior, exports, older loaded-module reload, report consumers, and separate early-return scrapped branch remain covered. No tests removed or weakened. |

For every implementation phase, run the complete offline suite and configured
static analysis, review all warnings, and inspect the diff for unintended
destructive calls:

```powershell
Import-Module Pester -RequiredVersion 5.5.0
Invoke-Pester -Path .\tests -Output Detailed -PassThru

Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The existing `.github\workflows\powershell-tests.yml` already runs these tools.
Do not add live integration tests to default CI. Any integration entry point
must be disabled by default, display the lab tenant, and require explicit
administrator authorization for destructive fixtures.

## Performance and rollback

For S approved unique serials and chunk size N, the intended submission count
is ceiling(S/N), excluding retries and verification. Measure total duration,
submission and verification calls, throttling, retry counts, pending results,
and per-object outcomes against comparable disposable lab cohorts. Do not run
both destructive backends against the same targets as a comparison.

Bulk submission may reduce network round trips without reducing backend work
or overall duration; polling and throttling can negate the gain. No speedup
claim or default promotion should precede measurement.

Rollback means selecting `Identity` on a fresh run after inspecting saved
outcomes and rediscovering targets. Reapply eligibility, protection, permission,
and confirmation checks. Rollback cannot undo completed deletions and is not
an automatic replay of the original target list.

## Baseline validation for this planning change

The full offline suite was executed with Pester `5.5.0`:
**Passed: 102; Failed: 0; Skipped: 0.**

Configured repository-wide PSScriptAnalyzer `1.25.0` returned **0 errors and
7 warnings**, all existing `PSAvoidGlobalVars` findings in test fixtures:
`tests\Safety.Tests.ps1` lines 345, 365, 369 and
`tests\ScrappedDevices.Tests.ps1` lines 178, 180, 183, 194.
No suppressions or unrelated test changes were made.

Only mocked/offline tests and official documentation retrieval were used.
No lab or production tenant was contacted. Endpoint availability, real
permissions, serial targeting, and completion behavior remain unvalidated;
phase 1 and the authorized lab pilot are mandatory before promotion.

## References

- [Autopilot deleteDevices action (v1.0)](https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-deletedevices?view=graph-rest-1.0)
- [deletedWindowsAutopilotDeviceState](https://learn.microsoft.com/graph/api/resources/intune-enrollment-deletedwindowsautopilotdevicestate?view=graph-rest-1.0)
- [Individual Autopilot identity DELETE](https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-delete?view=graph-rest-1.0)
- [Microsoft Graph JSON batching](https://learn.microsoft.com/graph/json-batching)
- [Windows Autopilot deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview#deregister-a-device)
