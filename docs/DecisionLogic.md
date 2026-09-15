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

## Decision precedence (evaluated in order per device)

1. `Server` / `Unsupported` platform → **Excluded** (`UnsupportedPlatform`)
2. `Unknown` platform (missing/ambiguous OS) → **ManualReview** (`MissingOperatingSystem`)
4. Protected by id/serial/name/pattern → **Excluded** (`ProtectedDevice`)
5. Ambiguous correlation → **ManualReview** (`AmbiguousAutopilotMatch` / `DuplicateSerialNumber`)
6. Windows device with a non-High-confidence Autopilot match → **ManualReview** (`LowConfidenceMatch`)
7. Disabled device with no tracked timestamp, or below `DaysDisabled` → **Excluded** (`DisabledTracking`)
8. Disabled device at or beyond `DaysDisabled` → **Candidate** (`DisabledForThreshold`, action `Remove`)
9. No authoritative activity timestamp at all → **ManualReview** (`MissingAllActivity`)
10. Effective last activity newer than cutoff → **Excluded** (`RecentActivityDetected`)
11. On-premises synchronized, override not set → **Excluded** (`ProtectedDevice`)
12. Otherwise → **Candidate** (`Stale`, action `Disable`)

## Lifecycle order

The script stores disabled timestamps in `DeviceLifecycleState.json` under the
configured output root. Entra `device` objects expose `accountEnabled`, but do
not expose a reliable disabled-at timestamp, so the ledger is required to
calculate `DaysDisabled`.

For each lifecycle `Candidate`:

1. If Windows, Autopilot-present, and `MatchConfidence = High`: remove the
   Autopilot identity (`ShouldProcess`), then issue an idempotent DELETE
   confirmation. `ZtdDeviceAlreadyDeleted` confirms the Autopilot step; a
   `ZtdDeviceDeletionInProgess` response is retried according to the configured
   retry budget before either Entra action can proceed.
2. A stale active device (`EntraAction = Disable`) is updated with
   `accountEnabled = false` and its disable timestamp is saved.
3. A disabled device at the retention threshold (`EntraAction = Remove`) is
   removed from Entra and its state entry is deleted.
4. If Autopilot removal fails or cannot be confirmed, the Entra action is not
   performed; the failure is recorded and processing continues.
5. iOS and Android candidates are never sent to any Autopilot cmdlet.
