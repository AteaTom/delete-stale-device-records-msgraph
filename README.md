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
  removes safely correlated Entra objects only after verified Autopilot absence.
  Failed or declined Intune removal blocks related Autopilot deregistration.
  Bounded exact-ID read-back gates Entra removal; pending results fail closed.
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
Explicit scrapped cleanup then removes safely correlated Entra objects only
after exact-ID read-back confirms all related Autopilot identities absent.
This is an intentional hardware-retirement exception to Microsoft's advice
against routine manual Entra deletion after deregistration:
[deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview#deregister-a-device). See
[docs/Architecture.md](docs/Architecture.md).

### Experimental batch-removal migration

See the [batch-removal migration plan](docs/BatchRemovalMigrationPlan.md) for
the proposed opt-in Autopilot bulk backend, safety gates, test coverage, and
staged lab/production rollout. This is a proposal only: individual identity
DELETE remains the current implementation, and no batch-selection parameter
is available yet.

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

Each run creates `output\<yyyyMMdd-HHmmss>\` containing
`DeletionCandidates.csv`, `DeletedDevices.csv`, `UnknownDevices.csv`,
`AmbiguousMatches.csv`, `ExcludedDevices.csv`, `ErrorDevices.csv`,
`AllEvaluatedDevices.csv`, `ScrappedDeviceResults.csv`, `RunSummary.json`, and
`ExecutionLog.txt`. See [docs/Reporting.md](docs/Reporting.md).

## Experimental JSON batch transport

Before confirmation, the workflow-specific summary shows tenant, mode,
WhatIf and transport. Stale cleanup lists only planned standalone Entra
deletions; Autopilot-backed devices appear as retained. Scrapped cleanup
counts serials with actual targets and unique Intune/Autopilot/Entra DELETE
operations separately, with dependency verification before Entra deletion.
Audit and WhatIf clearly indicate that no tenant DELETE requests are sent.

Individual SDK deletions remain the default. `-DeletionTransport JsonBatch`
packages at most 20 approved operations into each Graph v1.0 envelope.
Classification and confirmation are unchanged; batches are not transactions.
Each result is checked by request ID, and only transient failed subrequests
are retried. No automatic fallback to another destructive transport occurs.

```powershell
# Review the same plan without performing tenant writes.
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Automatic -ConfirmDeletion `
    -DeletionTransport JsonBatch -BatchSize 20 -WhatIf

# Only after Audit/report review and explicit lab validation:
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive `
    -DeletionTransport JsonBatch -BatchSize 20 -VerifyDeletion
```

Batch runs write a tenant-bound `DeletionPlan.json` before confirmation and an
append-only `DeletionJournal.jsonl` during execution. Plan hashes prevent
post-approval target changes; they are not approver signatures. The executor
rejects plans older than 30 minutes and checks delegated context/scopes before
each envelope. A timeout, invalid response or authorization failure stops
remaining execution; reconcile the journal before another destructive run.

`-VerifyDeletion` is optional and requires JsonBatch. It reads each successful
target at most three times, five seconds apart. `VerifiedAbsent` is distinct
from DELETE acceptance and portal synchronization. See
[docs/BatchDeletion.md](docs/BatchDeletion.md) for limits, safeguards and testing.

## Scrapped devices (explicit serial-number removal)

For physically scrapped hardware, select `-ScrappedDevices`. This separate
parameter set **does not accept `-DaysInactive`** and never evaluates activity.
Audit remains the default. Maintain `src\scrappeddevices.csv` (resolved beside
the script) with a required `SerialNumber` column, or specify
`-ScrappedDeviceCsvPath` as an override:

```csv
SerialNumber
SYNTHETIC-SCRAP-001
SYNTHETIC-SCRAP-002
```

The default file is intentionally not populated or committed with tenant data.
Create it from `config\scrappeddevices.example.csv` and replace the synthetic
serials with reviewed physical-retirement instructions before use.

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Audit
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Automatic `
  -ConfirmDeletion -WhatIf
.\src\Invoke-StaleDeviceCleanup.ps1 -ScrappedDevices -Mode Interactive `
  -ScrappedDeviceCsvPath '.\src\scrappeddevices.csv'
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
prerequisite blocks dependent operations. Accepted Autopilot deletion is
`RemovalSubmitted`, not proof of disappearance. Exact-ID read-back uses at
most three attempts with five-second intervals; only observed absence permits
Entra deletion. Pending/denied verification blocks Entra and produces a
non-success result, while independent targets continue. This safety gate is
mandatory in both transports and is separate from optional `-VerifyDeletion`.
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
the Entra object is absent; preserve earlier reports for manual reconciliation.
No historical report is automatically replayed or used as deletion authority.

### Calling the reusable Intune batch-removal helper

The helper accepts already-matched record objects and processes each unique
Intune managed-device ID once using individual retry-enabled Graph requests.
This is collection processing, not Microsoft Graph JSON batching. `-WhatIf`
shows the intended action without sending a Graph DELETE:

```powershell
Import-Module .\src\StaleDeviceCleanup.psd1

$records = @(
    [PSCustomObject]@{
        MatchStatus            = 'Matched'
        InputSerialNumber      = 'SCRAP-001'
        IntuneManagedDeviceId  = 'synthetic-intune-id'
        IntuneRemovalStatus    = 'NotAttempted'
        ErrorMessage           = $null
    }
)

Invoke-ScrappedDeviceBatchRemoval `
    -ScrappedDeviceRecords $records `
    -TargetType Intune `
    -WhatIf `
    -Confirm:$false

$records | Select-Object InputSerialNumber, IntuneManagedDeviceId, IntuneRemovalStatus
```

The record's status becomes `WhatIf`; non-`Matched` records and records without
an Intune ID are not removed. For normal tenant cleanup, prefer the
`-ScrappedDevices` script workflow above: it performs discovery, validation,
confirmation, dependency ordering, and reporting for all three services.

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
| 3 | Authentication or authorization failure |
| 4 | Incomplete discovery; deletion blocked |
| 5 | Administrator cancelled (Interactive mode) |
| 6 | Destructive operation failed |

## Known limitations

- Autopilot `lastContactedDateTime` is collected for reporting only and is
  not currently used as an authoritative activity source.
- National/sovereign cloud environments have not been validated.
- Intune managed-device deletion is intentionally not implemented in v1.

## Testing

```powershell
Install-Module -Name Pester -RequiredVersion 5.5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests
```

No test connects to a real tenant or performs a real deletion; all Graph
cmdlets are mocked.

## PSScriptAnalyzer

```powershell
Install-Module -Name PSScriptAnalyzer -Force -SkipPublisherCheck
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```
