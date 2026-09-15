# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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

- Serialize Autopilot bulk request bodies to explicit JSON before calling
  `Invoke-MgGraphRequest`, preventing PowerShell's adapted string properties
  from causing a self-referencing serialization loop.
- Count scrapped-device completion and run-summary outcomes by unique serial or
  object ID instead of expanded report rows, and log each failed serial once.
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
