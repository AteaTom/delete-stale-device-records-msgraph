# Changelog

All notable changes to this project are documented in this file.

## [1.2.0] - Unreleased

### Changed

- Separate explicit `-ScrappedDevices` retirement from inactivity cleanup.
  `-DaysInactive` is unavailable in that parameter set and scrapped reports
  contain no inactivity threshold or cutoff. Ordinary stale cleanup is unchanged.
- Breaking migration: old path-only scrapped commands require
  `-ScrappedDevices`; strict CSV requires a `SerialNumber` header. Optional
  `-AllowLegacyScrappedDeviceFormat` explicitly permits headerless input.
- Remove safely correlated scrapped Entra objects after Intune removal and
  successful Autopilot DELETE acceptance, in both Individual and JsonBatch.
  Failed prerequisites block dependent operations; independent targets
  continue. Destructive scrapped runs now require delegated
  `Directory.AccessAsUser.All` in addition to Intune scopes.
- Autopilot read-back no longer gates Entra deletion after Graph accepts the
  DELETE; optional JsonBatch `-VerifyDeletion` remains post-operation reporting.
- Permit multiple records only when stable relationships corroborate one
  physical device; retain protection, platform, synchronization and ambiguity
  gates. Report complete, partial, blocked, pending and simulated outcomes.

### Added

- Offline parameter-binding, CSV, correlation, all-service, dependency and
  partial-failure regression coverage; synthetic input sample.

## [1.1.0]

### Changed

- Align pre-confirmation summaries with separate stale/scrapped workflows:
  remove obsolete Autopilot stale-deletion lines, distinguish target serials
  from unique operations and retained Entra records, and show execution context.
- Protect Autopilot-backed devices from activity-based deletion. Explicit
  scrapped cleanup now removes Intune then Autopilot, leaves Entra objects for
  review, and blocks deregistration when required Intune removal fails.
- Apply protection, client-platform scope, duplicate-serial ambiguity and
  conflicting-identifier checks to scrapped hardware; serial input no longer
  bypasses these safety rules.
- Use the currently documented `Directory.AccessAsUser.All` permission for
  delegated Entra DELETE; scrapped-only runs request no Entra write scope.
  Administrator consent and live authorization remain subject to lab validation.

### Added

- Opt-in `JsonBatch` deletion transport, 1-20 operation envelopes, tenant-bound
  hashed plans, per-object ShouldProcess, phased dependencies, durable journals,
  finite subrequest retries, and optional bounded read-back verification.
  Individual SDK calls remain the default; no live tenant validation performed.
- Offline batch regression coverage and updated lifecycle safety expectations.

### Fixed

- Preserve received batch outcomes when restoring SDK retry settings fails,
  stop remaining execution, and retain both errors if the request also failed.
- Serialize typed CSV timestamps with explicit UTC and full fractional
  precision without changing classification objects or historical artifacts.
- Use relative SDK routes for batch submission and verification to avoid
  absolute-URL environment mutation causing invalid authentication URIs on
  later envelopes. Surface the original envelope error without replaying it.

## [1.0.2] - 2026-09-29

### Fixed

- `-ProtectedDeviceIdFile`'s `DeviceName` column now supports wildcard patterns
  (e.g. `PAW*`), matching the behavior of `-ProtectedDeviceNamePattern`.
  Previously it only matched exact, literal device names.

## [1.0.1] - 2026-09-22

### Added

- `-ScrappedDeviceCsvPath` parameter: given a recurring CSV/text file of one
  physically scrapped device serial number per line, removes every matching
  Windows Autopilot identity, Intune managed device, and Entra device object,
  independent of activity, disabled-state, or platform. This is the only
  workflow in the project that removes Intune managed-device records; the
  activity-based stale-device workflow still never deletes Intune records.
  Ambiguous (duplicate serial) or unmatched entries are reported to
  `ScrappedDeviceResults.csv` but never acted on. Subject to the same
  Mode/`-WhatIf`/`-ConfirmDeletion` gating, and to the Autopilot-before-Entra
  safety order, as the rest of the tool.

### Changed

- Treat Microsoft Graph `404 Request_ResourceNotFound` responses from Entra
  device deletion as successful idempotent completion when the object was
  removed after discovery or by an earlier operation. Other Graph failures
  continue to fail the run. Version the module as `1.0.1` and reload older
  in-memory module versions so this behavior takes effect in existing shells.
- Replace production use of the unsupported Autopilot `deleteDevices` action
  with individual Windows Autopilot identity DELETE requests. The bulk helper
  remains only for isolated diagnostics/tests; stale and scrapped workflows no
  longer depend on its route existing in the tenant.
- Serialize Autopilot bulk request bodies to explicit JSON before calling
  `Invoke-MgGraphRequest`, preventing PowerShell's adapted string properties
  from causing a self-referencing serialization loop.
- Count scrapped-device completion and run-summary outcomes by unique serial or
  object ID instead of expanded report rows, and log each failed serial once.
- Persist partial lifecycle state and rewrite reports during finalization so an
  interrupted destructive run cannot lose successful disable timestamps or
  report exit code 0 with unprocessed candidates.
- Adaptively split Autopilot chunks that return `400 Bad Request` and stop after
  five consecutive single-serial failures to isolate bad input without causing
  an unbounded request storm. Include Graph response details in error logs.
- Replace serial, per-device Autopilot DELETE confirmation in the
  scrapped-device and stale-device workflows with Microsoft's v1.0
  `deleteDevices` bulk action. Unique Intune records are removed first in the
  scrapped workflow; an `accepted` bulk state permits deduplicated cleanup
  without waiting for eventual portal consistency. Failed or missing bulk
  states block the related Entra action.
- Split Autopilot `deleteDevices` submissions into sequential chunks of at most
  100 unique serial numbers. Retry and failure handling is isolated per chunk,
  allowing later chunks to continue when one request fails.
- Remove the obsolete `-AutopilotDeletionRetryAttempts` and
  `-AutopilotDeletionRetryDelaySeconds` parameters. Active stale Entra objects
  can be disabled after an accepted bulk submission, while permanent Entra
  deletion is deferred until a later discovery confirms Autopilot absence.
- Deduplicate Autopilot, Intune, and Entra operations independently so repeated
  object rows cannot submit or remove the same tenant object more than once.
- Separate the scrapped-device CSV workflow into an explicit early-return branch.
  When `-ScrappedDeviceCsvPath` is supplied, the script resolves the serials,
  validates mode/confirmation, performs the scrapped-device deletion flow, and
  exits before the standard stale-device lifecycle runs in the same execution.
- Make the scrapped-device CSV workflow Autopilot-authoritative: when a serial
  exists in Windows Autopilot, every related Intune and Entra object for that
  serial is expanded into the exact deletion set, and duplicate serials without
  Autopilot authority remain `Ambiguous` and are skipped.
- Ensure `ScrappedDeviceResults.csv` and the scrapped-device summary report the
  exact objects that will be removed, rather than a misleading tenant-wide
  stale-device summary. Display the deduplicated serial and object counts before
  mode validation and interactive deletion confirmation.
- Deduplicate repeated matches so the same object is not reported or deleted
  multiple times in the same scrapped-device run.
- Deduplicate repeated CSV serial-number rows case-insensitively before
  correlation and show the ignored duplicate-row count in the pre-deletion
  summary and execution log.
- Replace direct Entra deletion for newly stale devices with a two-stage
  lifecycle: stale active objects are disabled first, then removed only after
  `-DaysDisabled` days have elapsed. The disable timestamps are persisted in
  `DeviceLifecycleState.json` under the configured output root.
- Add `Update-MgDevice`-based disabling and log planned/completed counts for
  Entra objects to disable and remove in the console, `ExecutionLog.txt`, and
  `RunSummary.json`.
- Reduce duplicate logging for expected Autopilot deletion states and reload
  an older in-memory module definition when required parameters are missing.
- Extend the in-memory module compatibility check to include the scrapped CSV
  statistics and summary parameters, preventing stale PowerShell sessions from
  failing with an unknown `Statistics` parameter.

## [1.0.0] - 2026-09-01

### Added

- Initial implementation of `Invoke-StaleDeviceCleanup.ps1` and the
  `StaleDeviceCleanup` module.
- Discovery of Microsoft Entra ID devices, Intune managed devices, and
  Windows Autopilot device identities via Microsoft Graph PowerShell SDK
  (v1.0 endpoints).
- Safe, identifier-based correlation across the three data sources with
  explicit confidence levels and ambiguity handling.
- Effective-last-activity calculation using the newest of Intune
  `lastSyncDateTime` and Entra `approximateLastSignInDateTime`.
- Platform classification (Windows/iOS/Android) with exclusion of servers,
  Linux, macOS, and ChromeOS.
- Protected-device list and name-pattern exclusion controls.
- Audit, Interactive, and Automatic execution modes with `ShouldProcess`
  support throughout.
- Autopilot-first deletion order with bounded verification polling.
- Full CSV/JSON/log reporting, written before any confirmation prompt.
- Pester 5 test suite covering safety-critical behavior, with all Graph
  calls mocked.
- PSScriptAnalyzer configuration and GitHub Actions CI workflow.
