# delete-stale-device-records-msgraph

Enterprise-grade PowerShell 7 tooling to safely identify, report on, and
optionally remove stale device records from **Microsoft Entra ID** and
**Windows Autopilot**, using the Microsoft Graph PowerShell SDK.

> ⚠️ **ALWAYS RUN AUDIT MODE FIRST AND REVIEW ALL GENERATED REPORTS BEFORE
> USING A DESTRUCTIVE MODE.**

## Purpose

Many organizations accumulate stale Windows, iOS, and Android device records
in Microsoft Entra ID and Windows Autopilot long after the physical devices
are retired. This tool discovers those records, correlates them safely across
Entra ID, Intune, and Autopilot, and produces detailed reports before ever
deleting anything.

## Safety model

- Defaults to **Audit** mode, which never deletes anything.
- `-DaysInactive` cannot be set below **180**; stale devices are removed
  directly after the safety checks.
- Stale Entra devices are removed directly after the safety checks. Microsoft
  Entra device deletion is irreversible and removes associated recovery keys.
  Ensure BitLocker recovery keys are backed up or no longer needed.
  `DeviceLifecycleState.json` is not a deletion gate.
- Every destructive function implements `SupportsShouldProcess`; `-WhatIf`
  and `-Confirm` are honored throughout.
- Reports are written **before** any confirmation prompt, in every mode.
- Interactive mode requires typing the exact word `DELETE`; anything else
  (including Enter, `Y`, or `YES`) cancels safely.
- Automatic mode requires an explicit `-ConfirmDeletion` switch and never
  prompts.
- Autopilot-backed devices are protected from activity-based deletion
  (`AutopilotProtected`). They require explicit hardware deregistration.
- The explicit scrapped-device workflow removes Intune records first, submits
  each unique Autopilot identity through the supported identity DELETE, and
  removes safely correlated Entra objects once Autopilot accepts each DELETE.
  Failed or declined Intune removal blocks related Autopilot deregistration.
  HTTP 204 permits continuation without read-back; unexpected HTTP 200
  requires exact-ID read-back returning 404 before Entra removal.
- Journal-based resumption creates a new Entra-only plan from original
  approved IDs; it never replays Intune or Autopilot DELETE requests.
- Incomplete discovery (a failed Graph call for an entire data set) blocks
  all deletion for the run.
- **Intune managed-device records are never deleted** by the activity-based
  stale-device workflow. The only exception is the explicit
  `-ScrappedDevices` workflow below, which is opt-in per run and acts
  only on serial numbers you provide.
  Intune data is used only as a correlation and activity source.

## Supported platforms

Windows (client), iOS, and Android only. Windows Server, Linux, macOS,
ChromeOS, and any device with a missing/ambiguous operating system are
excluded or routed to manual review — never auto-deleted.

## How activity is calculated

`EffectiveLastActivityUtc` is the **newest** of:

- Intune `managedDevice.lastSyncDateTime`
- Entra `device.approximateLastSignInDateTime`

An older timestamp never overrides a newer one, regardless of source. A
missing Intune record does **not** make an Entra device "unknown" — an
Entra-only device with an old `approximateLastSignInDateTime` is a valid
deletion candidate. A device is only routed to manual review
(`MissingAllActivity`) when **both** sources are missing.

`approximateLastSignInDateTime` is an **approximate** signal published by
Microsoft Entra ID and must not be presented as guaranteed proof of device
usage or inactivity. See [docs/DecisionLogic.md](docs/DecisionLogic.md) for
full details, including worked examples and the cutoff rule (a timestamp
exactly equal to the cutoff is treated as stale — inclusive comparison).

## Correlation strategy

Devices are matched using stable identifiers only (Entra `deviceId` ↔ Intune
`azureADDeviceId`, Autopilot `azureActiveDirectoryDeviceId`/`managedDeviceId`,
then normalized serial number as a last resort). Device name is **never** a
destructive match key. Ambiguous matches (duplicate serials, multiple
Autopilot records for one device) block deletion for all involved records and
are exported to `AmbiguousMatches.csv`. Autopilot matches are excluded or
routed to manual review rather than deleted by stale cleanup. See
[docs/DecisionLogic.md](docs/DecisionLogic.md).

For the scrapped-device CSV workflow, the serial-number list is treated as the
authoritative hardware-retirement input, not permission to bypass protection.
Serial-only collisions, conflicting stable identifiers, protected devices,
servers, unsupported platforms and missing platform evidence fail closed.
Multiple records require corroborating stable relationships to one device.

## Autopilot removal order

Only explicit scrapped hardware can be deregistered: remove Intune records
first, then submit the Autopilot identity DELETE after successful prerequisites.
Once Graph accepts the Autopilot DELETE (HTTP 204), explicit scrapped cleanup
continues to remove safely correlated Entra objects without waiting for a
read-back check. Optional `-VerifyDeletion` performs bounded post-operation
read-back and does not gate dependent Entra removals.
An unexpected Autopilot HTTP 200 instead requires confirmed absence using up
to three immediate exact-ID GETs with five-second intervals. Unresolved
identities continue to block related Entra removal. There is no additional
verification sweep or automatic DELETE replay.
This is an intentional hardware-retirement exception to Microsoft's advice
against routine manual Entra deletion after deregistration:
[deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview#deregister-a-device). See
[docs/Architecture.md](docs/Architecture.md).

### Resume Entra cleanup after delayed Autopilot removal

Use `-ResumeLatest` to locate the latest valid scrapped journal automatically
under `-OutputPath` (default `.\output`):

```powershell
# Read-only preview using the automatically selected original run.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest

# Select the source automatically, then request fresh approval.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest -Mode Interactive
```

Only immediate run subfolders are searched. Selection uses the approved plan
creation time, not folder modification time. Runs without journals, completed
targets and Entra-only resume runs are skipped; invalid/incomplete journals
are skipped with a warning. A source must have unattempted/blocked Entra
targets with original Autopilot dependencies. The selected path is displayed
and logged. If eligible journals span tenants, specify `-TenantId`; tied latest
timestamps require `-ResumeFromRunPath`. No eligible source means an explicit
error before Graph connection, never a fallback to normal stale cleanup.
Selection only locates a source; current inventory and all resume safety
checks below still apply. It does not merge multiple original runs.

When Autopilot disappears later, retain the original run folder and use its
approved object IDs rather than trying to rediscover links by serial number:

```powershell
# Read-only preview; creates new reports and a new Entra-only plan.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeFromRunPath '.\output\20261028-104650'

# Rechecks the original run and asks for fresh approval before Entra deletion.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeFromRunPath '.\output\20261028-104650' -Mode Interactive
```

Resume requires the original `DeletionPlan.json`, a completed
`DeletionJournal.jsonl`, and `ScrappedDeviceResults.csv` to agree. It verifies
the same tenant, reloads current inventories, reapplies protection, and checks
each original Autopilot ID once read-only. Only a 404 allows an otherwise
eligible Entra target into the new plan. Current management/re-registration,
ambiguous or changed identifiers, and unresolved Intune prerequisites block it.
Autopilot and Intune DELETE requests are never replayed. A previously attempted
Entra DELETE with an uncertain result is not resumed automatically.

Pass the original protection CSVs/name patterns and any intended AD-sync
override again: prior command-line protection settings are not stored or
inherited. The original source files are never modified. Always point at the
original scrapped run, not the new Entra-only preview/run. Resume is explicit
hardware retirement, not inactivity classification; `-DaysInactive` and
`-ScrappedDevices` cannot be combined with either resume selector.
`-ResumeLatest` and `-ResumeFromRunPath` are also mutually exclusive.

### Choosing a workflow

| Intent | Selector | Possible DELETE targets |
| --- | --- | --- |
| Find inactive devices | `-DaysInactive 1200` (or omit for 180) | Eligible standalone Entra objects |
| Retire reviewed physical hardware | `-ScrappedDevices` and serial CSV | Intune, Windows Autopilot, safely correlated Entra |
| Finish a known scrapped run | `-ResumeFromRunPath '<original run>'` | Remaining eligible Windows Entra objects only |
| Find the latest resumable scrapped run | `-ResumeLatest` | Same as explicit resume; one original run |

All selectors default to Audit. Resume never runs implicitly during ordinary
inactivity or scrapped cleanup, never applies an inactivity threshold, and
does not poll until deregistration finishes.

For the inactivity-to-retirement workflow: run inactivity Audit/Interactive,
review `AutopilotProtectedDevices.csv`, and place only explicitly retired
hardware serials in the scrapped input. Run scrapped Audit, then approved
scrapped cleanup. If delayed Autopilot removal blocks Entra, use resume Audit
later, review the selected source and new targets, then approve resume
separately. An old inactivity value such as 1200 days is not a resume filter.

```powershell
# Custom search/output root, explicit tenant, and freshly supplied protection.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest -Mode Audit `
    -OutputPath '.\output\retirement' -TenantId '<tenant-guid>' `
    -ProtectedDeviceIdFile '.\config\ProtectedDevices.csv' `
    -ProtectedDeviceNamePattern 'PAW-*','BREAKGLASS-*'

# Simulate the same workflow without tenant DELETE requests.
.\src\Invoke-StaleDeviceCleanup.ps1 -ResumeLatest -Mode Automatic `
    -ConfirmDeletion -WhatIf -OutputPath '.\output\retirement' `
    -TenantId '<tenant-guid>' -ProtectedDeviceIdFile '.\config\ProtectedDevices.csv' `
    -ProtectedDeviceNamePattern 'PAW-*','BREAKGLASS-*'
```

Paths are relative to the current working directory unless absolute.
`-OutputPath` is both the search root for `-ResumeLatest` and the destination
for new run folders; explicit resume can read a different source folder.
Each invocation reselects/rechecks independently. Use `-ResumeFromRunPath`
to pin the reviewed source if newer runs could appear before approval.
Without `-WhatIf`, Automatic plus `-ConfirmDeletion` performs real Entra
deletion with no prompt.

Parameter descriptions and runnable examples are also available locally:

```powershell
Get-Help .\src\Invoke-StaleDeviceCleanup.ps1 -Full
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
Get-Help Get-LatestDeviceCleanupResumeSource -Full
Get-Help Read-DeviceCleanupResumeSource -Full
Get-Help Resolve-DeviceCleanupResumeRecords -Full
```

## Prerequisites

- PowerShell 7.0 or later.
- Microsoft Graph PowerShell SDK modules:
  `Microsoft.Graph.Authentication`, `Microsoft.Graph.Identity.DirectoryManagement`,
  `Microsoft.Graph.DeviceManagement`, `Microsoft.Graph.DeviceManagement.Enrollment`.

```powershell
Install-Module -Name Microsoft.Graph.Authentication,Microsoft.Graph.Identity.DirectoryManagement,Microsoft.Graph.DeviceManagement,Microsoft.Graph.DeviceManagement.Enrollment -Scope CurrentUser
```

## Permissions

See [docs/Permissions.md](docs/Permissions.md) for the verified permission
model, including the difference between Audit (read-only scopes) and
destructive modes (read/write scopes), Entra role considerations, and Intune
licensing requirements.

## Installation

Clone or copy this repository, then run the module import check:

```powershell
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
```

## First safe run (Audit)

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 `
    -Mode Audit `
    -DaysInactive 180 `
    -OutputPath '.\output' `
    -Verbose
```

## Interactive examples

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 365 -Verbose
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive -DaysInactive 180 -WhatIf
```

## Automatic mode warning

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Automatic -DaysInactive 365 -ConfirmDeletion
```

Automatic mode performs **real deletions** with no prompt once
`-ConfirmDeletion` is supplied (unless `-WhatIf` is also supplied). Only use
this after repeated Audit runs have been reviewed and protected-device lists
are configured. `ShouldProcess`/`-WhatIf`/`-Confirm` are still honored.

## Reports

Each run creates `output\<yyyyMMdd-HHmmss>\` (with a run-ID suffix on collision) containing
`DeletionCandidates.csv`, `DeletedDevices.csv`, `UnknownDevices.csv`,
`AmbiguousMatches.csv`, `ExcludedDevices.csv`, `ADSyncedDevices.csv`,
`AutopilotProtectedDevices.csv`, `ErrorDevices.csv`, `ActionResults.csv`,
`AllEvaluatedDevices.csv`, `ScrappedDeviceResults.csv`, `RunSummary.json`, and
`ExecutionLog.txt`. See [docs/Reporting.md](docs/Reporting.md).

AD-sync and Autopilot-protected exclusions are routed to separate reports and
removed from `ExcludedDevices.csv`; all remain in `AllEvaluatedDevices.csv`.
Existing primary-reason precedence is unchanged. `OnPremisesSyncedReview.csv`
remains as a deprecated compatibility alias of `ADSyncedDevices.csv`.
The normal log ends with reconciled device/action totals; per-operation outcomes
are in `ActionResults.csv`, and routine diagnostic detail uses `-Verbose`/`-Debug`.

## Batch deletion

Before confirmation, the workflow-specific summary shows tenant, mode,
WhatIf and planned operations. Stale cleanup lists only planned standalone Entra
deletions; Autopilot-backed devices appear as retained. Scrapped cleanup
counts serials with actual targets and unique Intune/Autopilot/Entra DELETE
operations separately, with Intune and accepted Autopilot DELETE requests as
the prerequisites for Entra deletion.
Audit and WhatIf clearly indicate that no tenant DELETE requests are sent.

All approved deletions use Microsoft Graph v1.0 JSON batching. Each envelope
contains at most 20 operations (`-BatchSize` accepts 1-20). Classification and
confirmation are unchanged; batches are not transactions. Every subresponse
is checked by request ID, and only identified transient subrequest failures
are retried. A failed or uncertain batch is never replayed through a different
deletion path.

```powershell
# Review the same plan without performing tenant writes.
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Automatic -ConfirmDeletion `
    -BatchSize 20 -WhatIf

# Optional bounded read-back after Audit/report review and explicit lab validation:
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive `
    -BatchSize 20 -VerifyDeletion
```

Runs write a tenant-bound `DeletionPlan.json` before confirmation and an
append-only `DeletionJournal.jsonl` during execution. Plan hashes prevent
post-approval target changes; they are not approver signatures. The executor
rejects plans older than 30 minutes and checks delegated context/scopes before
each envelope. A timeout, invalid response or authorization failure stops
remaining execution; reconcile the journal before another destructive run.

`-VerifyDeletion` reads each successful target at most three times, five
seconds apart. `VerifiedAbsent` is distinct from DELETE acceptance and portal
synchronization. See
[docs/BatchDeletion.md](docs/BatchDeletion.md) for limits, safeguards and testing.

Batching changes only the deletion transport: classification, protection, and
correlation remain unchanged. No serial-based Autopilot bulk action is used.

## Scrapped devices (explicit serial-number removal)

For physically scrapped hardware, select `-ScrappedDevices`. This separate
parameter set **does not accept `-DaysInactive`** and never evaluates activity.
Audit remains the default. Maintain `config\scrappeddevices.csv` (resolved
relative to the repository containing the script, not the working directory)
with a required `SerialNumber` column, or specify
`-ScrappedDeviceCsvPath` as an override:

```csv
SerialNumber
SYNTHETIC-SCRAP-001
SYNTHETIC-SCRAP-002
```

The default file is intentionally not populated or committed with tenant data.
Create it from `config\scrappeddevices.example.csv` and replace the synthetic
serials with reviewed physical-retirement instructions before use.
Move existing `src\scrappeddevices.csv` input to `config\scrappeddevices.csv`,
or continue using it through an explicit `-ScrappedDeviceCsvPath` override.
The script does not fall back to the old location or the example file.

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Audit
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Automatic `
  -ConfirmDeletion -WhatIf
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Interactive `
  -ScrappedDeviceCsvPath '.\config\scrappeddevices.csv'
```

Repeated CSV rows are removed case-insensitively before correlation, preserving
the first occurrence and file order. The summary reports how many duplicate
rows were ignored; blank rows and the required header are not counted as
duplicates.

Safely correlated serials may target all three services; only Windows targets
Autopilot. Multiple records are eligible only when stable relationships
corroborate one device. Serial-only collisions remain `Ambiguous`. Protected,
unsupported, missing-platform, synchronized (unless explicitly overridden), or
conflicting-identifier matches are `Excluded`. Device names never prove identity.

This is the only workflow in the project that removes Intune managed-device
records, and it only ever acts on the serial numbers you explicitly listed.
It follows Microsoft's deregistration order by removing unique Intune records
first and then submitting each unique Autopilot identity through the supported
identity DELETE only if required Intune removals succeeded. A failed or skipped
prerequisite blocks dependent operations. HTTP 204 accepted Autopilot deletion is
reported as `RemovalSubmitted`; the successful Graph DELETE response is
sufficient to proceed with corresponding Entra
deletion. `-VerifyDeletion` optionally performs exact-ID read-back
after all planned DELETE operations; its result is diagnostic and does not
gate the dependency sequence. Failed/declined Autopilot removal still blocks
Entra deletion, while independent targets continue.
The workflow uses the same
Mode/`-WhatIf`/`-ConfirmDeletion` gating as the rest of the tool and does not
run the standard stale-device lifecycle in the same execution. Before
confirmation, the console shows the exact unique target counts, and
`ScrappedDeviceResults.csv` contains the object-level details.

**Breaking migration in 1.2.0:** path-only scrapped commands are rejected
instead of silently gaining Entra deletion. Add `-ScrappedDevices`, remove
`-DaysInactive`, and add a `SerialNumber` header. To explicitly retain the old
headerless input format:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Audit `
  -ScrappedDeviceCsvPath '.\src\ScrappedDevice.csv' `
  -AllowLegacyScrappedDeviceFormat
```

This compatibility option changes parsing only; confirmed runs use the new
all-service policy. Input serials cannot rediscover Entra records after both
Intune and Autopilot correlation evidence is gone. `NotFound` is not proof that
the Entra object is absent. Preserve the original plan, final journal and
report for [journal-based resumption](#resume-entra-cleanup-after-delayed-autopilot-removal).
Historical targets are never replayed with their old approval: explicit resume
validates them and creates a fresh Entra-only plan requiring new approval.

Microsoft reference: [Windows Autopilot deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview#deregister-a-device)

## Protected-device configuration

Use `-ProtectedDeviceIdFile` (see `config/ProtectedDevices.example.csv`) and
`-ProtectedDeviceNamePattern` (e.g. `BREAKGLASS-*`, `PAW-*`, `ADMIN-*`,
`KIOSK-CRITICAL-*`) to permanently exclude specific devices. These are not
enabled by default — you must configure them explicitly.

## On-premises synchronization warning

Devices with `onPremisesSyncEnabled = $true` are **excluded from automatic
deletion by default**, because deleting the cloud object is not a permanent
remediation — the object can reappear on the next sync if the source object
still exists on-premises. An advanced override,
`-AllowOnPremisesSyncedDeletion`, exists for administrators who have already
addressed the on-premises source; use it only with a full understanding of
the consequences.

## Troubleshooting

See [docs/Troubleshooting.md](docs/Troubleshooting.md).

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Completed successfully |
| 1 | Completed with per-device errors |
| 2 | Validation or configuration failure (e.g. Automatic mode without `-ConfirmDeletion`) |
| 3 | Unhandled run error, including authentication, invalid resume source or no eligible latest journal |
| 4 | Incomplete discovery; deletion blocked |
| 5 | Administrator cancelled (Interactive mode) |
| 6 | Destructive operation failed |

## Known limitations

- Autopilot `lastContactedDateTime` is collected for reporting only and is
  not currently used as an authoritative activity source.
- National/sovereign cloud environments have not been validated.
- Intune managed-device deletion is available only in explicit scrapped
  cleanup; inactivity cleanup and resume never delete Intune records.
- Resume requires a consistent original scrapped plan, final journal and
  report. Audit-only, incomplete and Entra-only runs cannot supply the needed
  original Autopilot submission evidence.
- Latest-source selection uses original journals, not a cross-run completion
  ledger. The same source can be selected again after a later resume; fresh
  inventory prevents adding Entra objects already absent. Older original
  runs are not merged or automatically advanced through.
- Resume does not retry uncertain prior Entra DELETEs, retry failed Intune
  deletion, or restore missing correlation evidence by name. Such cases
  require manual investigation. No live behavior is guaranteed by offline tests.

## Testing

```powershell
Install-Module -Name Pester -RequiredVersion 5.5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests
```

No test connects to a real tenant or performs a real deletion; all Graph
cmdlets are mocked.
`tests\Resume.Tests.ps1` covers source integrity, automatic selection,
tenant/timestamp ambiguity, current management/protection, exact-ID read-back,
fresh approval, Audit/WhatIf and Entra-only execution.
Use `-PassThru` and check `FailedCount` when a shell exit code is needed:

```powershell
$result = Invoke-Pester -Path '.\tests' -Output Detailed -PassThru
if ($result.FailedCount -gt 0) { throw 'Offline Pester suite failed.' }
```

## PSScriptAnalyzer

```powershell
Install-Module -Name PSScriptAnalyzer -Force -SkipPublisherCheck
Invoke-ScriptAnalyzer -Path '.\src' -Recurse -Settings '.\PSScriptAnalyzerSettings.psd1'
```
