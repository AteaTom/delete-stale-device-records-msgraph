# Decision logic

## Normal inactivity cleanup

The cutoff is computed once in UTC as now minus `-DaysInactive` (minimum and
default 180). The newest trustworthy current **or retained** Intune
`lastSyncDateTime` / Entra `approximateLastSignInDateTime` wins.
An effective timestamp exactly equal to the cutoff is stale.
Autopilot `lastContactedDateTime` is reporting context only.

An Entra-only device can qualify using its Entra timestamp. Missing both
sources means `MissingAllActivity`, not stale. If earlier discovery observed
an Intune record without reliable activity, that unresolved evidence remains
`UnresolvedSafetyEvidence` after Intune disappears; an older sign-in must not
silently replace unknown Intune evidence.

| Evidence at threshold 180 | Result |
| --- | --- |
| Entra sign-in 250 days ago; no current/historical Intune | Candidate if other safety checks pass |
| Entra 300 days ago; retained Intune sync 20 days ago | Excluded, `RecentActivityDetected` |
| Intune 240 days ago; current Entra 10 days ago | Excluded, `RecentActivityDetected` |
| No activity | ManualReview, `MissingAllActivity` |
| Changed device identity or unresolved historical activity | ManualReview, `UnresolvedSafetyEvidence` |
| Current or retained-serial-associated Autopilot registration | Protected or manual review; never automatically deleted |

`ActivitySource=RetainedActivityEvidence` identifies a retained timestamp that
is newer than current signals. Removing Intune does not reset the clock, nor
does deregistration create an inactivity timestamp.

### Classification and protections

1. Server/unsupported platforms are excluded; unknown platforms require review.
2. Retained serial-based protection excludes devices.
3. Current explicit ID/serial/name/pattern protection excludes devices.
   Otherwise, unresolved retained identity/activity evidence requires manual review.
4. Ambiguous correlation requires manual review.
5. Windows Autopilot matches below High confidence require manual review.
6. Autopilot-associated devices are excluded (`AutopilotProtected`), including
   registrations found through retained serials after references change.
7. Missing activity requires manual review; recent activity excludes devices.
8. Otherwise-stale AD-synced devices are excluded by default. The advanced
   explicit override never modifies source AD.
9. Only remaining devices become Entra DELETE candidates after fresh approval.

Retained serials found on a current Intune registration with a different
device reference or ambiguous association also fail closed. Evidence is not
authority to delete a replacement registration.

Supported platforms are Windows clients, iOS and Android. Operating systems
containing `server` are excluded; Linux, macOS and ChromeOS are unsupported.
No platform expansion is implied by retained evidence.

## Correlation

| Relationship | Confidence / use |
| --- | --- |
| Entra device ID to Intune Azure AD device ID | High |
| Autopilot Azure AD device ID to Entra device ID | High |
| Autopilot managed-device reference to matched Intune ID | Medium |
| Normalized valid serial | Low fallback for Autopilot correlation; retained for protection |
| Display name | Never authoritative correlation |

Multiple conflicting records, duplicate serials without stable corroboration,
changed IDs and unsupported/missing platform evidence fail closed.
Autopilot lookup/deletion applies only to Windows.

## Explicit scrapped cleanup

`-ScrappedDevices` selects a different parameter set and cannot accept
`-DaysInactive`. Input defaults to repository-relative
`config\scrappeddevices.csv`, with a unique `SerialNumber` column.
Duplicates are counted and deduplicated case-insensitively; blank serials
are ignored. Headerless input requires `-AllowLegacyScrappedDeviceFormat`.
An explicit path override never silently falls back to another file.

The serial list expresses physical-retirement intent, not permission to
bypass protection or ambiguity. Existing platform, stable correlation,
explicit protection, conflicting-ID and default AD-sync checks apply.
Multiple records require stable corroboration for the same device.
Entra IDs/names in the report provide correlation context, **not DELETE targets**.

After reports and approval:

1. Remove unique eligible Intune managed-device records.
2. Submit each unique Windows Autopilot identity only after its Intune
   prerequisites succeed. Failed/declined prerequisites block related targets.
3. Record HTTP 204 as `RemovalSubmitted`. Unexpected HTTP 200 remains
   `OutcomeUnknown`. Do not wait, assume absence or automatically replay it.
4. Retain all Entra objects and end this invocation.

A later **normal inactivity** invocation rediscovers current state and applies
the preceding inactivity rules. Still-present Autopilot registrations remain
protected. A scrapped `NotFound` means no reliable current serial match, not
proof that all historic Entra records disappeared.

`-ResumeLatest` and `-ResumeFromRunPath` now explicitly throw before Graph
connection. Original plans and journals are investigation evidence only and
never bypass `DaysInactive`.

## Durable evidence and approval

The entrypoint loads/merges and atomically saves tenant evidence before any
deletion in either workflow. Use the same `-EvidencePath` across runs; see
[Architecture.md](Architecture.md) for locking, retention and failure handling.
Retained ambiguous/missing evidence requires manual investigation, not
automatic clearing or substitution.

Plans freeze the target set and expire after 30 minutes. Execution rechecks
tenant/scopes, honors ShouldProcess and requires explicit administrator
intent. Audit/WhatIf send no destructive Graph operations. Legacy lifecycle
disabled-timestamp/retention fields do not authorize deletion.
