# Reporting

Every execution creates a timestamped folder: `output\<yyyyMMdd-HHmmss>\`.
The lifecycle ledger is stored at the output root as
`DeviceLifecycleState.json` so it survives across timestamped runs.

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
| `ScrappedDeviceResults.csv` | One row per actual object to remove for each serial from `-ScrappedDeviceCsvPath`, expanded when a serial is Autopilot-authoritative; empty (headers only) when the parameter is not supplied |
| `RunSummary.json` | Machine-readable run outcome (counts, exit code, timestamps) |
| `ExecutionLog.txt` | Human-readable structured log (DEBUG/INFO/WARNING/ERROR/SUCCESS) |

## Evaluated-device columns

See `AllEvaluatedDevices.csv` header for the authoritative list; it matches
the field list documented in the project specification, including
`EffectiveLastActivityUtc`, `ActivitySource`, `MatchConfidence`,
`ReasonCode`, `ReasonDescription`, `EntraAction`, `EntraDisableStatus`,
`AutopilotRemovalStatus`, and `EntraRemovalStatus`. Timestamps are ISO 8601
UTC. `DisabledSinceUtc` and `DaysDisabled` describe the persisted lifecycle
age used for removal eligibility.

Autopilot removal statuses include `Removed`, `AlreadyRemoved`,
`RemovalInProgress`, `RemovalUnconfirmed`, `Skipped`, and `NotAttempted`.
`AlreadyRemoved` means Graph explicitly reported that the identity had already
been deleted and the matched Entra removal was allowed to continue.

Entra lifecycle statuses include `Disabled`, `NotYetEligible`, `WhatIf`,
`Skipped`, and `NotAttempted`. `RunSummary.json` includes planned and completed
counts for both disabling and removal, and `ExecutionLog.txt` records the same
counts at planning and completion.

## Scrapped-device columns

`ScrappedDeviceResults.csv` includes: `InputSerialNumber`,
`NormalizedSerialNumber`, `MatchStatus` (`Matched`/`Ambiguous`/`NotFound`),
`AmbiguityReason`, `AutopilotIdentityId`, `AutopilotEnrollmentState`,
`IntuneManagedDeviceId`, `IntuneDeviceName`, `EntraObjectId`,
`EntraDeviceName`, and per-target `AutopilotRemovalStatus`,
`IntuneRemovalStatus`, `EntraRemovalStatus` (`Removed`, `AlreadyRemoved`,
`RemovalUnconfirmed`, `SkippedAutopilotNotRemoved`, `WhatIf`, `Skipped`,
`NotApplicable`, `NotAttempted`).

When a serial exists in Autopilot, the script expands the serial to include
all related Entra and Intune objects for that same serial, so the report is the
exact object set that will be deleted. When no Autopilot authority exists,
only unambiguous single matches are reported as `Matched`; duplicate serials
without Autopilot authority remain `Ambiguous` and are never acted on.
Only `Matched` rows are ever acted on.

Before mode validation or an interactive deletion prompt, the console summary
shows unique counts for input and matched serial numbers, the number of
case-insensitive duplicate CSV rows ignored, exact unique Autopilot/Intune/Entra
records to remove, and ambiguous/not-found serials. Blank rows and the optional
header are excluded from the duplicate count.
`ScrappedDeviceResults.csv` is written first so its object-level rows can be
reviewed before confirmation.

## Reason codes

`MissingAllActivity`, `UnsupportedPlatform`, `MissingOperatingSystem`,
`AmbiguousAutopilotMatch`, `DuplicateSerialNumber`, `LowConfidenceMatch`,
`ProtectedDevice`, `RecentActivityDetected`, `DisabledTracking`,
`DisabledForThreshold`, `Stale`.

(`IncompleteGraphData`, `ConflictingIdentifiers`, and `GraphReadError` are
reserved reason codes for future per-device error handling refinements.)
