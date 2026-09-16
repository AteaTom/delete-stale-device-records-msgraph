# Decision logic

## Effective last activity

For every Entra device, the script collects the following authoritative
timestamps when available:

- `Intune managedDevice.lastSyncDateTime`
- `Entra device.approximateLastSignInDateTime`

`EffectiveLastActivityUtc` is the **newest** of the timestamps that are
actually present. Missing Intune data is a normal condition and never causes
a device to be treated as unknown by itself — an Entra-only device is
evaluated using its Entra timestamp alone.

`ActivitySource` records which source(s) produced the newest timestamp
(joined with `;` if multiple sources tie exactly).

Windows Autopilot's `lastContactedDateTime` is collected and reported for
context, but is **not** one of the authoritative sources used to compute
`EffectiveLastActivityUtc` in v1, per the project's conservative default.

### Worked examples

| Intune lastSyncDateTime | Entra approximateLastSignInDateTime | Result |
| --- | --- | --- |
| missing | 250 days old | Candidate (threshold 180) |
| 240 days old | 20 days old | Excluded — newest activity (20d) is recent |
| 30 days old | 300 days old | Excluded — newest activity (30d) is recent |
| missing | missing | ManualReview — `MissingAllActivity` |

## Cutoff calculation

```powershell
$CutoffDateUtc = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)
```

Computed once, in UTC, at the start of execution. A device whose
`EffectiveLastActivityUtc` is **less than or equal to** the cutoff is treated
as stale (inclusive comparison at the boundary).

## Platform classification

`Resolve-DevicePlatform` performs a case-insensitive, substring-based
classification of `operatingSystem`:

1. If the value contains `windows server`, `windowsserver`, or the standalone
   word `server` → `Server` (excluded).
2. Else if it contains `windows` → `Windows`.
3. Else if it contains `ios`, `ipad`, or `iphone` → `iOS`.
4. Else if it contains `android` → `Android`.
5. Else if it contains `linux`, `macos`/`mac os`, or `chromeos`/`chrome os` →
   `Unsupported` (excluded).
6. Else (missing or unrecognized) → `Unknown` (manual review, never
   auto-deleted).

## Correlation confidence

| Method | Confidence | Notes |
| --- | --- | --- |
| Entra `deviceId` = Intune `azureADDeviceId` | High | Preferred Entra↔Intune match |
| Autopilot `azureActiveDirectoryDeviceId` = Entra `deviceId` | High | Preferred Entra↔Autopilot match |
| Autopilot `managedDeviceId` = matched Intune record id | Medium | Only used when the AAD-device-id match is absent |
| Normalized, non-placeholder, unique serial number | Low | Last resort; only used for Autopilot correlation |
| Device name | Never a match key | Informational only; never drives deletion |

Multiple records matching the same key (duplicate serial numbers, multiple
Autopilot registrations for one Entra device, etc.) produce
`MatchStatus = Ambiguous` and block deletion for **all** involved records.

Only `MatchConfidence = High` may be used for **automatic Autopilot
deletion**. Windows devices with a Medium/Low-confidence Autopilot match are
routed to manual review (`ReasonCode = LowConfidenceMatch`) rather than
deleted.

## Scrapped-device serial matching

The `-ScrappedDeviceCsvPath` workflow is intentionally independent from the
stale-device activity evaluation. It takes the CSV serials as the authoritative
input, resolves them only against the already-discovered Entra, Intune, and
Autopilot records, and then exits early before the standard stale-device
lifecycle executes for that run.

CSV serials are deduplicated case-insensitively before correlation. The first
occurrence and its casing are preserved; each later occurrence is ignored and
counted as a duplicate CSV row in the summary.

- If a serial exists in Windows Autopilot, Autopilot is treated as the
  authority for that serial.
- In that case, the script expands the match to every related Entra and Intune
  object already linked to the same serial and emits one row per actual object
  being removed.
- If there are multiple matches but no Autopilot authority, the serial is marked
  `Ambiguous` and excluded from deletion.
- If no match is found in any source, the row is marked `NotFound` and no
  deletion is attempted.

This rule ensures that a CSV containing a serial that is present in Autopilot
never produces a misleading tenant-wide summary or a mixed-platform count.
Instead, the scrapped-device summary shows the exact deletion targets for the
serial that was supplied. It is displayed before interactive confirmation and
deduplicates object IDs when counting Autopilot, Intune, and Entra removals.

After confirmation, the scrapped-device operation follows this order:

1. Remove each unique matched Intune managed-device record once.
2. Submit every unique Autopilot identity once through the supported identity
   DELETE endpoint.
3. Treat a successful response as an accepted asynchronous submission and
   continue without polling for the Autopilot record to disappear.
4. Remove each unique related Entra object once. A failed identity DELETE
   blocks Entra removal for that identity's serial.

## Decision precedence (evaluated in order per device)

1. `Server` / `Unsupported` platform → **Excluded** (`UnsupportedPlatform`)
2. `Unknown` platform (missing/ambiguous OS) → **ManualReview** (`MissingOperatingSystem`)
4. Protected by id/serial/name/pattern → **Excluded** (`ProtectedDevice`)
5. Ambiguous correlation → **ManualReview** (`AmbiguousAutopilotMatch` / `DuplicateSerialNumber`)
6. Windows device with a non-High-confidence Autopilot match → **ManualReview** (`LowConfidenceMatch`)
7. No authoritative activity timestamp at all → **ManualReview** (`MissingAllActivity`)
8. Effective last activity newer than cutoff → **Excluded** (`RecentActivityDetected`)
9. On-premises synchronized, override not set → **Excluded** (`ProtectedDevice`)
10. Otherwise → **Candidate** (`Stale`, action `Remove`)

## Lifecycle order

`DeviceLifecycleState.json` is retained for compatibility and reporting. Direct
Entra removal is direct after the safety checks and does not depend on a
disabled timestamp or retention gate.

For each lifecycle `Candidate`:

1. For Windows with Autopilot and `MatchConfidence = High`, submit each unique
   Autopilot identity once through the identity DELETE endpoint.
2. If the DELETE succeeds, remove the related Entra object directly.
3. If the identity DELETE fails, skip the Entra action,
   record the failure, and continue processing.
4. iOS and Android candidates are never sent to an Autopilot DELETE.
