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
  Entra deleted devices can be restored during the tenant's deleted-device
  retention window; `DeviceLifecycleState.json` is retained only for
  compatibility and reporting, not as a 30-day deletion gate.
- Every destructive function implements `SupportsShouldProcess`; `-WhatIf`
  and `-Confirm` are honored throughout.
- Reports are written **before** any confirmation prompt, in every mode.
- Interactive mode requires typing the exact word `DELETE`; anything else
  (including Enter, `Y`, or `YES`) cancels safely.
- Automatic mode requires an explicit `-ConfirmDeletion` switch and never
  prompts.
- High-confidence Windows Autopilot candidates use one supported identity
  DELETE per unique identity. A successful response permits direct Entra
  removal; a failed Autopilot removal blocks the related Entra deletion.
- The explicit scrapped-device workflow removes Intune records first, submits
  each unique Autopilot identity through the supported identity DELETE, and
  proceeds with explicit Entra cleanup only after a successful response.
  It does not wait for eventual Autopilot portal synchronization.
- Incomplete discovery (a failed Graph call for an entire data set) blocks
  all deletion for the run.
- **Intune managed-device records are never deleted** by the activity-based
  stale-device workflow. The only exception is the explicit
  `-ScrappedDeviceCsvPath` workflow below, which is opt-in per run and acts
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
are exported to `AmbiguousMatches.csv`. Only High-confidence Autopilot matches
are eligible for automatic Autopilot deletion. See
[docs/DecisionLogic.md](docs/DecisionLogic.md).

For the scrapped-device CSV workflow, the serial-number list is treated as the
authoritative input. If a serial exists in Windows Autopilot, all Entra and
Intune objects linked to that serial are included in the exact deletion set,
not only the first matching record. This prevents a CSV-based Autopilot serial
from being treated as a mixed-platform summary or as a single object when the
serial actually maps to multiple tenant records.

## Autopilot removal order

For each Windows lifecycle candidate with a High-confidence Autopilot match:
submit the Autopilot identity DELETE → remove the Entra object after success.
If Autopilot removal fails, Entra removal is blocked. See
[docs/Architecture.md](docs/Architecture.md).

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

Automatic mode performs **real disables and deletions** with no prompt once
`-ConfirmDeletion` is supplied (unless `-WhatIf` is also supplied). Only use
this after repeated Audit runs have been reviewed and protected-device lists
are configured. `ShouldProcess`/`-WhatIf`/`-Confirm` are still honored.

## Reports

Each run creates `output\<yyyyMMdd-HHmmss>\` containing
`DeletionCandidates.csv`, `DeletedDevices.csv`, `UnknownDevices.csv`,
`AmbiguousMatches.csv`, `ExcludedDevices.csv`, `ErrorDevices.csv`,
`AllEvaluatedDevices.csv`, `ScrappedDeviceResults.csv`, `RunSummary.json`, and
`ExecutionLog.txt`. See [docs/Reporting.md](docs/Reporting.md).

## Scrapped devices (explicit serial-number removal)

For hardware that has been physically scrapped, maintain a recurring
CSV/text file with one serial number per line (an optional header row is
skipped automatically), for example `src/ScrappedDevice.csv`, and pass it
via `-ScrappedDeviceCsvPath`. This workflow is entirely independent of
`-DaysInactive` and the stale-device evaluation: when the
parameter is supplied, the script takes the scrapped-device branch first and
returns before the standard stale lifecycle flow runs. A matched serial number
is removed regardless of how recently the device was used, even if it would
otherwise be excluded as "recent activity detected":

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive `
  -ScrappedDeviceCsvPath '.\src\ScrappedDevice.csv'
```

Repeated CSV rows are removed case-insensitively before correlation, preserving
the first occurrence and file order. The summary reports how many duplicate
rows were ignored; blank rows and the optional header are not counted as
duplicates.

Every serial number that resolves to a Windows Autopilot identity, an Intune
managed device, and/or an Entra device object is removed from all relevant
objects in those systems — regardless of activity, disabled-state, or
platform. If the serial exists in Autopilot, Autopilot is treated as the
authoritative source and all related Entra/Intune records for that serial are
expanded into the exact deletion set. Duplicate serials without Autopilot
authority remain `Ambiguous` and are left untouched; a serial matching
nothing is reported as `NotFound`.

This is the only workflow in the project that removes Intune managed-device
records, and it only ever acts on the serial numbers you explicitly listed.
It follows Microsoft's deregistration order by removing unique Intune records
first and then submitting each unique Autopilot identity through the supported
identity DELETE. The script does not poll for portal synchronization, because
that can take several minutes. A failed DELETE blocks Entra removal for that
serial. The workflow uses the same
Mode/`-WhatIf`/`-ConfirmDeletion` gating as the rest of the tool and does not
run the standard stale-device lifecycle in the same execution. Before
confirmation, the console shows the exact unique target counts, and
`ScrappedDeviceResults.csv` contains the object-level details.

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
