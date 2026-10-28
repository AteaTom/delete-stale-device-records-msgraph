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

Autopilot-backed devices are never deregistered by activity-based cleanup.
Windows devices with a Medium/Low-confidence Autopilot match are
routed to manual review (`ReasonCode = LowConfidenceMatch`) rather than
deleted.

## Scrapped-device serial matching

The `-ScrappedDevices` parameter set is intentionally independent from the
stale-device activity evaluation. It takes the CSV serials as the authoritative
input, resolves them only against the already-discovered Entra, Intune, and
Autopilot records, and then exits early before the standard stale-device
lifecycle executes for that run.

`-DaysInactive` cannot bind in this parameter set and is not used in scrapped
initialization, logging or summaries. Default input is `config\scrappeddevices.csv`,
resolved relative to the repository containing the script,
with a required `SerialNumber` column. An explicit
`-AllowLegacyScrappedDeviceFormat` permits the old headerless text format.

CSV serials are deduplicated case-insensitively before correlation. The first
occurrence and its casing are preserved; each later occurrence is ignored and
counted as a duplicate CSV row in the summary.

- A serial must identify an unambiguous client device. Multiple Intune or
  Autopilot records require corroborating stable relationships to one device;
  serial-only collisions and multiple Entra objects for one device ID fail closed.
- Protected IDs/serials/names, servers, unsupported or missing platforms, and
  conflicting stable IDs exclude the entire serial. Synchronized Entra records
  are protected unless the existing explicit advanced override is supplied.
  Related records with a different serial cannot be bypassed. Conflicting
  supported platforms also fail closed, including without Autopilot.
- For a valid match, emit object-level rows for Intune/Autopilot targets and
  related Entra targets. Stable IDs are resolved before deletion removes the
  source correlation evidence. Device names never establish a link.
- If no match is found in any source, the row is marked `NotFound` and no
  deletion is attempted.

The summary shows unique approved Intune/Autopilot/Entra targets
counts before confirmation, rather than a tenant-wide stale-device summary.

After confirmation, the scrapped-device operation follows this order:

1. Remove each unique matched Intune managed-device record once.
2. Submit every unique Autopilot identity once through the supported identity
   DELETE endpoint. Failed or declined required Intune removals block
   Autopilot for the serial.
3. Treat documented HTTP 204 as accepted, sufficient to proceed without
   waiting for portal or API read-back visibility. Unexpected HTTP 200 is
   not success: up to three exact-ID GETs, five seconds apart, must establish
   404 absence. Visible/error outcomes block related Entra targets; there is
   no second sweep or automatic DELETE replay.
4. Remove every safely correlated eligible Entra target. Intune or Autopilot
   prerequisite failure blocks related Entra; independent targets continue.
   WhatIf simulates this dependency transition without making DELETE calls.
5. Optional `-VerifyDeletion` reads exact successful target IDs after planned
   deletions and records absence separately from API acceptance. It does not
   gate dependent Entra removal.

Entra deletion here is an intentional exception for explicit physical
retirement, not routine cleanup after Autopilot deregistration. Microsoft's
[deregistration guidance](https://learn.microsoft.com/autopilot/registration-overview)
advises against routine manual Entra deletion. Synchronized devices may
reappear if their on-premises AD source remains; source AD is never modified.

Without either Intune or Autopilot evidence a serial cannot identify an Entra
object. NotFound therefore means no reliable match in current discovery, not
proof of complete historical cleanup. Preserve original reports for manual
reconciliation; no historical report is implicitly replayed.

## Journal-based Entra resumption

`-ResumeFromRunPath` or `-ResumeLatest` explicitly selects retirement
continuation, not inactivity evaluation. The inactivity threshold is not
reapplied, and no new hardware is selected from a serial CSV.

Source validation requires `Workflow=Scrapped`, the original plan content
hash, matching run/tenant/hash in the last journal entry with `Event=Final`,
complete unique per-operation results, and report rows that reconstruct the
same operations/dependencies. A final checkpoint means execution ended with
recorded outcomes, not that every removal succeeded. An old original plan
can supply evidence; only the newly created plan receives fresh approval and
the normal execution-age limit.

Only Entra operations with zero previous attempts and status
`BlockedDependency` or `NotAttempted` are considered. For a present target:

1. The original Entra object ID must identify exactly one current Windows
   client. Its nonzero device ID must be unique and match all saved rows.
2. Current Intune/Autopilot correlation must be unmatched. Each original
   serial must be valid and absent from both current management inventories;
   this blocks re-registration even when references changed.
3. Current explicit ID/serial/name protection and default AD-sync protection
   apply. Supply protection options and any intended sync override again;
   they are not inherited from the earlier command.
4. An original Autopilot dependency is required. Every required Intune
   result must already be successful/already absent. Every original Autopilot
   dependency must have a recorded DELETE attempt with HTTP 200/204.
5. Exact-ID read-only verification of each original Autopilot dependency
   must return 404. A visible object, permission error or failed read does
   not establish absence. Shared dependency checks are cached for this run.

An eligible row is `Matched` and contributes only an Entra target to the new
plan. An absent Entra object is `NotFound` with `EntraAlreadyAbsent`, no
DELETE target and no claim that this run removed it. Other rejected targets
are `Excluded`. Previously attempted Entra operations, including unknown
outcomes, are not automatically resumed. No Intune/Autopilot DELETE is replayed.
These checks use current inventory, not an atomic pre-delete guarantee.

`-ResumeLatest` first searches immediate `-OutputPath` subfolders locally.
Among validated sources with qualifying Entra operations and Autopilot
dependencies, it picks the newest plan creation time. No journal/no qualifying
targets means skip; invalid sources warn and skip. Multiple eligible tenants
require `-TenantId`, and a tied latest timestamp requires an explicit path.
This is source selection, not proof that its targets will pass the checks
above. It neither merges original runs nor falls back to inactivity cleanup.

## Decision precedence (evaluated in order per device)

1. `Server` / `Unsupported` platform → **Excluded** (`UnsupportedPlatform`)
2. `Unknown` platform (missing/ambiguous OS) → **ManualReview** (`MissingOperatingSystem`)
3. Protected by id/serial/name/pattern → **Excluded** (`ProtectedDevice`)
4. Ambiguous correlation → **ManualReview** (`AmbiguousAutopilotMatch` / `DuplicateSerialNumber`)
5. Windows device with a non-High-confidence Autopilot match → **ManualReview** (`LowConfidenceMatch`)
6. High-confidence Autopilot match → **Excluded** (`AutopilotProtected`)
7. No authoritative activity timestamp at all → **ManualReview** (`MissingAllActivity`)
8. Effective last activity newer than cutoff → **Excluded** (`RecentActivityDetected`)
9. On-premises synchronized, override not set → **Excluded** (`OnPremisesSyncProtected`); the source AD object's deletion safety is not assessed.
10. Otherwise → **Candidate** (`Stale`, action `Remove`)

## Lifecycle order

`DeviceLifecycleState.json` is retained for compatibility and reporting. Direct
Entra removal is direct after the safety checks and does not depend on a
disabled timestamp or retention gate.

Each lifecycle `Candidate` is a standalone Entra object with the established
platform, activity, protection and ambiguity checks satisfied. Only its Entra
object is deleted after approval; Intune remains an activity/correlation source.
No stale candidate is sent to Autopilot deletion.

Batch deletion freezes the approved target set, rechecks context before each
envelope and records partial outcomes. It does not change classification.
See [BatchDeletion.md](BatchDeletion.md).
