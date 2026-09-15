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
- `-DaysInactive` cannot be set below **180**; stale active devices are
  disabled before they can be removed.
- `-DaysDisabled` controls how long an Entra device must remain disabled before
  removal. The default is **30 days**. The timestamp is persisted in
  `DeviceLifecycleState.json` under the configured output root.
- Every destructive function implements `SupportsShouldProcess`; `-WhatIf`
  and `-Confirm` are honored throughout.
- Reports are written **before** any confirmation prompt, in every mode.
- Interactive mode requires typing the exact word `DELETE`; anything else
  (including Enter, `Y`, or `YES`) cancels safely.
- Automatic mode requires an explicit `-ConfirmDeletion` switch and never
  prompts.
- Windows Autopilot identities are removed and **verified** before the
  corresponding Entra device is disabled or removed. Graph's
  `ZtdDeviceAlreadyDeleted` response is treated as confirmation. A
  `ZtdDeviceDeletionInProgess` response is retried; if it remains unresolved,
  the Entra device is **not** deleted.
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

## Autopilot-first deletion order

For each Windows lifecycle candidate with a High-confidence Autopilot match:
remove the Autopilot identity → confirm with an idempotent DELETE, retrying
bounded `DeletionInProgress` responses → only then disable or remove the Entra
device according to its lifecycle action. See
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
Set-Location -LiteralPath 'C:\Users\Tom Eriksson\source\repos\delete-stale-device-records-msgraph'
Import-Module .\src\StaleDeviceCleanup.psd1 -Force
```

## First safe run (Audit)

```powershell
Set-Location -LiteralPath 'C:\Users\Tom Eriksson\source\repos\delete-stale-device-records-msgraph'

.\src\Invoke-StaleDeviceCleanup.ps1 `
    -Mode Audit `
    -DaysInactive 180 `
    -OutputPath '.\output' `
    -Verbose
```

Autopilot deletion confirmation retries default to 3 attempts with a
30-second delay. Override them when the Autopilot backend needs more time:

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 `
  -Mode Interactive `
  -DaysInactive 2370 `
  -AutopilotDeletionRetryAttempts 6 `
  -AutopilotDeletionRetryDelaySeconds 60 `
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
skipped automatically), for example `src/SkrotadeDatorer.csv`, and pass it
via `-ScrappedDeviceCsvPath`. This workflow is entirely independent of
`-DaysInactive`/`-DaysDisabled` and the stale-device evaluation: a matched
serial number is removed regardless of how recently the device was used,
even if it would otherwise be excluded as "recent activity detected":

```powershell
.\src\Invoke-StaleDeviceCleanup.ps1 -Mode Interactive `
  -ScrappedDeviceCsvPath '.\src\SkrotadeDatorer.csv'
```

Every serial number that resolves to a Windows Autopilot identity, an Intune
managed device, and/or an Entra device object is removed from all three —
regardless of activity, disabled-state, or platform. A serial number matching
more than one record in any single source is reported as `Ambiguous` and left
untouched; a serial number matching nothing is reported as `NotFound`. This
is the only workflow in the project that removes Intune managed-device
records, and it only ever acts on the serial numbers you explicitly listed.
It follows the same Mode/`-WhatIf`/`-ConfirmDeletion` gating, and the same
Autopilot-before-Entra safety order, as the rest of the tool.

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
