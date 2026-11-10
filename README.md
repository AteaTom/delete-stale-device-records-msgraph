# delete-stale-device-records-msgraph

PowerShell 7 tooling for conservative Microsoft Entra device cleanup and
explicit Intune/Windows Autopilot hardware retirement through Microsoft Graph.

**Always run Audit first and review the reports before authorizing deletion.**
Entra deletion is irreversible and removes associated recovery keys. Back up
BitLocker recovery keys or establish that they are no longer required.

## Two separate runs

| Intent | Selector | Possible DELETE targets |
| --- | --- | --- |
| Deregister explicitly scrapped hardware | `-ScrappedDevices` | Intune, then Windows Autopilot; never Entra |
| Remove inactive devices, including residual Entra objects | `-DaysInactive 180` (default) | Eligible Entra objects only |

Scrapped mode submits deregistration and exits without waiting for Autopilot
completion. HTTP 204 means `RemovalSubmitted`, not confirmed disappearance.
Unexpected HTTP 200 remains `OutcomeUnknown`; no automatic retry or success
claim is made. Failed/declined Intune prerequisites block related Autopilot
operations. Independent targets can continue.

Run normal inactivity cleanup later. It discovers all three inventories again.
Devices still associated with Autopilot remain protected. Once deregistration
has completed, a remaining Entra object can qualify under the inactivity
threshold and all other safety checks. It does **not** need another 180 days
from deregistration; the latest trustworthy activity determines its age.
Scrapped mode never falls through into inactivity cleanup in the same run.

Microsoft notes that deregistration is asynchronous, does not always remove
the Entra object, and advises against routine manual Entra deletion:
[Windows Autopilot deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview#deregister-a-device).
This tool leaves Entra untouched during deregistration and evaluates residual
objects separately under its normal conservative inactivity policy.

### Migration from resume-based cleanup

`-ResumeLatest` and `-ResumeFromRunPath` are retired. Both fail explicitly
before Graph connection; they never silently become normal cleanup. Resume
deletion helpers have been removed. Historical journals remain readable for
investigation, not as authorization to delete Entra without inactivity checks.
Do not replay old approved plans.

## Safety and activity

- Audit is the default and performs no tenant writes.
- Minimum inactivity is **180 days**. A timestamp exactly at the cutoff is stale.
- The newest current or retained Intune sync/Entra sign-in wins. Missing
  activity is not evidence of inactivity.
- Windows clients, iOS and Android are supported. Servers and unsupported
  platforms are excluded; unknown platforms require manual review.
- Correlation uses stable identifiers, never names as proof of identity.
  Ambiguous or conflicting records fail closed.
- Explicit ID, serial and name/pattern protection wins over eligibility.
- AD-synced devices are protected by default. The advanced
  `-AllowOnPremisesSyncedDeletion` override does not modify source AD; cloud
  objects can reappear if their source remains.
- Interactive requires the exact word `DELETE`. Automatic requires
  `-ConfirmDeletion`. WhatIf suppresses all destructive Graph requests.
- Incomplete discovery blocks deletion. Reports and exact operation counts
  are produced before approval.
- Inactivity cleanup never deletes Intune or Autopilot records.

`approximateLastSignInDateTime` is approximate, not guaranteed proof of
physical device usage. Autopilot `lastContactedDateTime` is reporting context,
not an authoritative inactivity signal.

## Durable safety evidence

The script saves tenant-scoped evidence **before any deletion**, in `.state`
beside the repository's `src` directory by default. It retains stable Entra
object/device identifiers, serial associations, the newest observed activity,
and unresolved evidence flags. Removing Intune must not discard a recent sync
or a serial association needed by later protection checks.

Use the **same `-EvidencePath` directory across runs, upgrades and scheduled
tasks**, independent of report output:

```powershell
# Example external evidence location; secure and back up this directory.
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Audit `
    -EvidencePath 'C:\ProgramData\DeviceCleanup\Evidence'
```

Evidence is not a deletion queue or old approval. Current discovery and the
normal inactivity threshold still apply. The newest retained/current activity
wins (`ActivitySource=RetainedActivityEvidence` when retained evidence is newer).
Serial associations also protect against current Autopilot re-registration.
Missing historical Intune activity, conflicting IDs or changed identities
require manual review (`UnresolvedSafetyEvidence`).

Evidence updates are atomic and flushed before execution; a tenant lock
prevents overlapping runs using the same store. Audit/WhatIf may update this
**local** store but never tenant data. Corrupt evidence, a missing initialized
data file, a concurrent lock, or a failed save blocks cleanup. Protect the
directory with appropriate ACLs and backup; it contains device identifiers and
must not be committed. Do not remove the directory or its initialization lock
files to bypass a safety error. Loss of the entire directory cannot be
distinguished from first installation: restore it before running cleanup.

On migration, this store cannot reconstruct records already deleted by an
older version. Reconcile historical reports and activity/protection evidence
before approving cleanup; do not assume a fresh store contains that history.
Use stable Entra IDs in protection files when historical serial links are
unavailable. Missing activity never becomes stale by default.

## Installation and permissions

Requires PowerShell 7 and these Graph SDK modules:

```powershell
Install-Module -Name Microsoft.Graph.Authentication,Microsoft.Graph.Identity.DirectoryManagement,Microsoft.Graph.DeviceManagement,Microsoft.Graph.DeviceManagement.Enrollment -Scope CurrentUser
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
```

Authentication is delegated and targets the public Microsoft Graph cloud.
Audit requests only read scopes. Destructive scrapped mode requests Intune
and Autopilot write scopes, **not Entra write scope**. Normal destructive
cleanup requests `Directory.AccessAsUser.All` in addition to the read scopes.
See [Permissions](docs/Permissions.md) for role, consent and licensing details.

## Operator examples

Create `config\scrappeddevices.csv` from the example using reviewed serials:

```csv
SerialNumber
SYNTHETIC-SCRAP-001
SYNTHETIC-SCRAP-002
```

The default path is repository-relative, not working-directory-relative.
`-ScrappedDeviceCsvPath` overrides it. There is no fallback to an old input
path or the example. Empty rows are ignored; duplicates are counted and
deduplicated case-insensitively. Headerless input requires the explicit
`-AllowLegacyScrappedDeviceFormat` switch; this changes parsing only.

```powershell
# First invocation: inspect retirement, simulate it, then explicitly approve.
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Audit
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Automatic -ConfirmDeletion -WhatIf
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Interactive

# Later invocation: inspect inactivity and approve only reviewed candidates.
.\src\Invoke-StaleDeviceCleanup.ps1 -DaysInactive 180 -Mode Audit
.\src\Invoke-StaleDeviceCleanup.ps1 -DaysInactive 180 -Mode Interactive

# Unattended inactivity cleanup: REAL deletion, no prompt.
.\src\Invoke-StaleDeviceCleanup.ps1 -DaysInactive 365 -Mode Automatic -ConfirmDeletion
```

Do not combine `-DaysInactive` with `-ScrappedDevices`. Supply the intended
tenant and protection configuration each time:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Audit -TenantId '<tenant-guid>' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.csv' `
    -ProtectedDeviceNamePattern 'PAW-*','BREAKGLASS-*'
```

Protection CSV columns are `EntraObjectId`, `EntraDeviceId`, `SerialNumber`
and/or `DeviceName`. DeviceName and name-pattern values support wildcards.
Example settings are documentation only, not automatically loaded.

## Batching, journals and reports

`-BatchSize` accepts 1-20 independent requests per v1.0 JSON batch.
Batches are not transactions. Only recognized transient subrequest failures
are retried; unknown envelopes are never automatically replayed.
Plans bind tenant, immutable target set, prerequisites and creation time by
hash. The 30-minute plan lifetime and per-envelope context checks remain.

Version 2 journals use full initial/final checkpoints and operation-level
updates in between. Submission intent is written before Graph; responses
are written before optional verification. Final records are read by streaming,
not the slow giant-line `Get-Content -Tail` path. Legacy final checkpoints
remain readable; incomplete/malformed records require reconciliation.

`-VerifyDeletion` optionally reads successful **Intune/Entra** IDs, at most
three times with five-second intervals. It never polls Autopilot. Avoid this
optional per-target read-back for large retirement batches unless needed.

Each invocation creates a timestamped run directory under `-OutputPath`
(default `.\output`, working-directory-relative). See
[Reporting](docs/Reporting.md) for the CSVs, summary and journal contracts.
`Pending` is expected after accepted Autopilot submission and does not by itself
mean failure. `OutcomeUnknown` is not success and needs investigation.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Completed, possibly with accepted Autopilot deregistration pending |
| 1 | Per-device errors |
| 2 | Configuration/validation failure |
| 3 | Run-level error, including evidence/authentication failure |
| 4 | Incomplete discovery or required permissions unavailable |
| 5 | Administrator cancelled |
| 6 | Destructive action or optional verification failed/unresolved |

Retired selectors throw before run initialization. Preserve reports/journals
and reconcile uncertain operations read-only before another destructive run.

## Development and validation

Read [AGENTS.md](AGENTS.md). All automated Graph calls are mocked; tests never
connect to or delete from a live tenant.

```powershell
Install-Module -Name Pester -RequiredVersion 5.5.0 -Force -SkipPublisherCheck
$result = Invoke-Pester -Path '.\tests' -Output Detailed -PassThru
if ($result.FailedCount -gt 0) { throw 'Offline Pester suite failed.' }

Install-Module -Name PSScriptAnalyzer -Force -SkipPublisherCheck
Invoke-ScriptAnalyzer -Path '.\src' -Recurse -Settings '.\PSScriptAnalyzerSettings.psd1'
```

See [Architecture](docs/Architecture.md), [Decision logic](docs/DecisionLogic.md),
[Batch deletion](docs/BatchDeletion.md) and [Troubleshooting](docs/Troubleshooting.md).
Offline validation cannot establish live propagation timing or explain a
service's unexpected HTTP 200. Live lab validation requires separate approval;
national clouds have not been validated.
