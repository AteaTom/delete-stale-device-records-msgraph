# Experimental JSON batch-removal rollout plan

Status: validation and rollout proposal for the existing implementation.
This document changes no runtime behavior, permissions, or deletion defaults.

Reviewed baseline: main commit `bdc43d5`, module/script version `1.2.0`
(unreleased in CHANGELOG). This replaces the original version `1.0.2`
proposal based on `e158cec`.

## Recommendation and scope

Validate and progressively adopt the existing `-DeletionTransport JsonBatch`
path instead of introducing another deletion backend. Keep `Individual` as
the default and as an operator-selected transport for fresh reviewed runs.
Default promotion requires a separate owner-approved release.

The implementation bundles exact-ID DELETE operations in Microsoft Graph
v1.0 JSON `$batch` envelopes. It does **not** invoke the serial-based Autopilot
`deleteDevices` action. Each envelope contains at most 20 service operations,
not 20 physical devices, and is not a transaction.

Stale and scrapped workflows remain separate. Stale cleanup removes eligible
standalone Entra objects and protects Autopilot-backed devices; explicit
scrapped cleanup can remove safely correlated Intune, Windows Autopilot and
Entra records with prerequisite checks.

Detailed current usage and failure handling live in
[BatchDeletion.md](BatchDeletion.md). This plan identifies completed work,
operator migration requirements, remaining validation, and promotion gates.
No additional backend selector, serial-bulk adapter, parallel envelopes,
eligibility change, or live tenant execution is authorized by this document.

## What changed since the original plan

| Original assumption or proposed work | Current main | Updated disposition |
| --- | --- | --- |
| Add an Autopilot `deleteDevices` adapter and serial chunks of up to 100 | Exact-ID JSON batching is implemented; the serial action is not used | Remove this proposal and its serial response-state mapping |
| Initially leave Entra/Intune batching out of scope | JsonBatch supports Entra, Intune and Autopilot under the selected workflow | Validate the implemented routes rather than add another transport |
| Add backend selection, exports and version/reload wiring | `DeletionTransport`, `BatchSize`, `VerifyDeletion`, public helpers and 1.2.0 compatibility checks exist | Mark implemented; retain regression coverage |
| Stale cleanup removes Autopilot before Entra | Autopilot-backed stale objects are protected (`AutopilotProtected`) | Adopt current policy; do not restore activity-driven deregistration |
| Scrapped CSV bypasses protection/platform rules | Resolver applies protection, client scope, synchronization, stable-ID and ambiguity gates | The former policy discrepancy is addressed in main |
| Path-only/headerless scrapped commands | Explicit `-ScrappedDevices` parameter set and strict CSV header; legacy format is opt-in | Document the breaking operator migration |
| Add complete prerequisites and Autopilot acceptance | Both transports require successful Intune prerequisites and accepted Autopilot DELETE responses before Entra | Implemented; optional final verification is diagnostic and does not gate dependencies |
| Add hashed plan, journal and bounded batch recovery | JsonBatch has approval-bound plans, exclusive journals, per-ID responses/retries and final report recovery | Mark implemented for JsonBatch, not for Individual |
| Original baseline: 102 passing tests, 7 analyzer warnings | Reviewed main: 249 passing tests, 11 existing test-fixture warnings | Replace the old validation baseline |

## Current operator contract

| Setting or workflow | Current behavior |
| --- | --- |
| Defaults | Audit mode, Individual transport, BatchSize 20 |
| `-BatchSize` | Valid range 1-20 service operations per envelope; only affects JsonBatch |
| `-VerifyDeletion` | Optional final exact-ID read-back; requires JsonBatch |
| Interactive | Exact `DELETE` confirmation after reports and target summary |
| Automatic | Explicit `-ConfirmDeletion`; WhatIf still suppresses writes |
| Inactivity | `DaysInactive` minimum 180; newest trustworthy activity wins; missing evidence, protection and ambiguity remain fail-closed |
| Scrapped | Explicit `-ScrappedDevices`; does not accept `-DaysInactive` and does not classify by activity |
| Autopilot dependencies | Mandatory bounded exact-ID absence verification in both transports before related scrapped Entra removal |

### Scrapped command and CSV migration

Existing path-only commands must add `-ScrappedDevices`, remove
`-DaysInactive`, and use a CSV with a `SerialNumber` header. Headerless input
requires explicit `-AllowLegacyScrappedDeviceFormat`. The default input path
is `config\scrappeddevices.csv`, resolved relative to the repository containing
the script, and is not populated
with tenant data by the repository. Use the synthetic example only as a
format reference.

This is explicit retirement intent, not a protection bypass. Stable
relationships must corroborate expanded multi-record sets. Protected devices,
serial-only collisions, conflicting IDs, servers, unsupported/unknown
platforms and synchronized objects without the existing override remain
excluded. Incomplete discovery is reported as `LookupFailed`, not trustworthy
`NotFound`. See [DecisionLogic.md](DecisionLogic.md).

### Permissions and execution policy

Audit requests only read scopes and submits no destructive envelope.
Delegated Entra DELETE uses `Directory.AccessAsUser.All`, not the old
`Device.ReadWrite.All` assumption. Scrapped destructive runs also request
`DeviceManagementManagedDevices.ReadWrite.All` and
`DeviceManagementServiceConfig.ReadWrite.All`. Required user roles and server
authorization must be validated separately; scope checks alone cannot prove
that a DELETE is allowed. See [Permissions.md](Permissions.md).

The scrapped sequence is required Intune removal, Autopilot identity DELETE,
accepted removal of every associated Autopilot identity, then dependent Entra
removal. Failed/declined prerequisites block descendants; safely independent
targets can continue after isolated failures. Stale cleanup never removes
Intune or Autopilot records. Autopilot remains Windows-only.

## Implemented JsonBatch safeguards

`src\DeviceDeletionBatch.ps1`, included by the module, provides
`New-DeviceDeletionPlan`, `Invoke-DeviceDeletionPlan`,
`Set-DeviceDeletionResults`, `Test-DeviceDeletionOutcome`, and
`Assert-DeviceCleanupContext`.

The existing executor deep-copies the approved content, validates its hash,
workflow, IDs, prerequisites and age, and checks tenant, delegated
authentication, public-cloud environment and scopes before envelopes.
Per-target ShouldProcess and WhatIf remain effective. A plan hash binds
content, not approver identity or a fresh activity observation; protect report
directories with suitable access controls.

Exclusive journal creation prevents reuse. Intent is persisted before
submission, and responses/partial outcomes are retained for final reporting.
Only failed, identified HTTP 429/503/504 subrequests enter finite retry queues
with attempts, elapsed budget, Retry-After and backoff. SDK envelope retries
are temporarily disabled and restored in finally. Lost responses are
`OutcomeUnknown`, not automatically replayed or sent through Individual.

Relative `/v1.0/$batch` and verification routes preserve SDK environment.
Current implementation documentation reports an absolute-URL environment
mutation issue with Authentication 2.37.0; this review did not reproduce it
against a live tenant. Validate multiple envelopes and restored retry settings
in the intended lab SDK environment. Do not run concurrent Graph work in the
same PowerShell process while the executor manages its retry context.

### Distinctions that must survive rollout

Outer HTTP 200 does not establish subrequest success. HTTP 204 establishes
API acceptance, while exact-ID read-back 404 establishes observed absence.
Autopilot acceptance remains `RemovalSubmitted`; verification is a separate
field. WhatIf, declined, unprocessed, failed and uncertain outcomes are never
reported as real deletion success.

The transports share eligibility policy but are not identical in evidence or
recovery semantics. JsonBatch creates the approved plan and durable journal;
Individual uses its existing report/log path rather than that executor.
JsonBatch treats Entra DELETE 404 as `AlreadyAbsent`, but Intune/Autopilot
DELETE 404 as failure. Individual recognizes certain already-removed cases,
including Intune 404 and the Autopilot already-deleted error.

Treat those differences as compatibility/recovery validation gates, not proof
of complete transport parity. Do not weaken the existing batch 404 tests.
Any future harmonization needs a separately approved behavior change and
offline coverage. Optional final verification also applies only to JsonBatch;
mandatory scrapped Autopilot dependency verification applies to both.

Plan expiry limits stale approval but is not atomic pre-delete activity
revalidation. Batching is not atomic, completed deletions are not rolled back,
and no universal conditional-delete or automatic replay guarantee is claimed.

## Remaining rollout phases

| Phase | Remaining work | Acceptance gate |
| --- | --- | --- |
| 1. Align documentation and baseline | Replace obsolete proposal, link beside existing JSON transport usage, explain strict scrapped migration and current permissions | Documentation matches source; no runtime changes; current offline/analyzer evidence recorded |
| 2. Establish operational readiness | Preserve regression coverage; review recovery differences, artifact access, report consumers and additional coverage below | No unresolved fail-open behavior; differences documented or assigned separate approved work; no weakened tests |
| 3. Audit and WhatIf rehearsal | Operator uses explicit tenant, reviewed classification/CSV, protection and fresh discovery; compare target sets without deletion | Audit submits no destructive requests; WhatIf has no submitted IDs/attempts or removed counts; any target-set differences explained |
| 4. Authorized disposable lab validation | Validate standalone Entra, then separately validate Windows Intune/Autopilot/Entra dependencies; begin with BatchSize 1 and multiple envelopes before boundary-sized runs | Correct routes/roles, stable SDK context and restored MaxRetry; matching exact IDs in plan/journal/reports; accepted DELETE responses and failure blocks behave correctly |
| 5. Controlled production opt-in | Separately authorized, fully reviewed small cohort with monitored outcomes and recovery evidence | No unapproved target expansion or unresolved unknown outcome; Individual remains default |
| 6. Future promotion decision | Compare measured call cost, duration and reliability on separate comparable disposable cohorts | Separate owner approval/release for a default change; no claimed speedup from the 20-request limit alone |

Phases are gated in order. This documentation revision does not execute
operator rehearsals, lab deletion, production rollout, or default promotion.
Approval of the plan is not authorization to contact or modify a tenant.

Use the detailed [operator-run validation procedure](BatchDeletion.md#operator-run-validation-procedure).
The entry point has no arbitrary target allowlist: a destructive lab run is
safe only if the entire eligible set consists of approved disposable fixtures.
Never fabricate inactivity or weaken protection to obtain fixtures.
An Entra-only lab exercise does not validate Intune/Autopilot routes.

## Offline coverage and outstanding evidence

Current tests cover safety gates, both workflows, batch sizes 0/1/20/21/41,
invalid sizes, plan hash/mutation/expiry, route injection, duplicate IDs,
tenant/auth/scope/cloud mismatch and later-envelope context changes.
They cover malformed/missing/duplicate/unexpected responses, outer-success
authorization failures, selective transient retries, Retry-After date/seconds,
retry budgets, lost envelopes, journal reuse/intent failures and SDK retry
restoration failures.

They also cover strict scrapped input, binding isolation, stable-ID
corroboration, protection/platform/sync exclusions, incomplete lookups,
all-service ordering, blocked prerequisites, denied/pending read-back,
independent targets, unique reporting and partial/unknown outcomes.
The source suites include `BatchDeletion.Tests.ps1`, `Safety.Tests.ps1`,
`ScrappedDevices.Tests.ps1`, `ScrappedWorkflow.Tests.ps1` and
`Summary.Tests.ps1`, alongside activity/correlation/platform/protection tests.

Before expanding rollout, review coverage and evidence for configured smaller
sizes and the 19-operation boundary, reordered responses, expiry during
execution, declined prerequisites, truncated/corrupt journals, recovery after
lost correlation evidence, already-absent differences, and report/exit-code
agreement. Identify existing coverage before adding tests; these are readiness
checks, not claims of established defects. Additional runtime/test changes
require their own agreed scope.

Every subsequent implementation or promotion change must run the complete
offline suite, configured analyzer, and diff review:

```powershell
Import-Module Pester -RequiredVersion 5.5.0
Invoke-Pester -Path .\tests -Output Detailed -PassThru

Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Keep integration tests disabled by default and separate from normal CI.
Mock results cannot establish endpoint-specific batching behavior, consent,
RBAC, eventual consistency, the operator's SDK environment, or performance.

## Recovery and measurement

Preserve plans, journals, reports and original errors after partial or unknown
execution. Record exact-ID read-only reconciliation separately; do not rewrite
historical unknown outcomes as if the original response had been received.
No automatic replay or destructive transport fallback is allowed.

Any later run requires fresh discovery, eligibility/protection checks,
permissions/context validation and explicit consent. If a scrapped serial
loses Intune/Autopilot linkage after partial removal, `NotFound` does not prove
that its retained Entra object is absent. Historical reports remain manual
reconciliation evidence, not automatic deletion authority.

Measure service-operation count, per-phase envelopes, verification GETs,
throttling, retries, pending/unknown outcomes and total duration.
For eligible phase counts I (Intune), A (Autopilot), E (Entra) and size N,
the no-retry submission count is
`ceiling(I/N) + ceiling(A/N) + ceiling(E/N)`, excluding blocked operations and
verification calls. Stale cleanup uses only E. Do not calculate using physical
device count or assume a 20x improvement.

Compare separate disposable cohorts; do not execute both destructive
transports against the same targets as a benchmark. Rollback means selecting
Individual for a fresh reviewed run, not undoing completed deletion.

## Validation of this revision

The reviewed main snapshot passed the complete offline Pester 5.5.0 suite:
**Passed: 249; Failed: 0; Skipped: 0.** The same results were confirmed after
integrating main and revising this documentation.

Configured repository-wide PSScriptAnalyzer 1.25.0 returned **0 errors and
11 existing warnings**, all `PSAvoidGlobalVars` in test fixtures:
`tests\Safety.Tests.ps1` lines 479, 498, 500, 501, 504, 505, 506, 513 and
`tests\ScrappedDevices.Tests.ps1` lines 435, 438, 439.
No tests or suppressions were changed.

Only offline mocked tests and official documentation retrieval were used.
No lab or production tenant was contacted. Runtime/default behavior is
unchanged by this PR relative to the reviewed main baseline. Live
authorization, route support, eventual consistency and performance remain
operator validation requirements.

## References

- [Current transport implementation and operator procedure](BatchDeletion.md)
- [Workflow architecture](Architecture.md)
- [Classification and correlation](DecisionLogic.md)
- [Permission and role requirements](Permissions.md)
- [Report contracts](Reporting.md)
- [Microsoft Graph JSON batching](https://learn.microsoft.com/graph/json-batching)
- [Microsoft Graph throttling and batching](https://learn.microsoft.com/graph/throttling#throttling-and-batching)
- [Delegated Entra device DELETE](https://learn.microsoft.com/graph/api/device-delete?view=graph-rest-1.0)
