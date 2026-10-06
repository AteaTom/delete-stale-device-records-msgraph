# AGENTS.md

## Purpose

This repository contains an enterprise-grade PowerShell 7 solution for identifying,
reporting, validating, and optionally removing stale device records from:

- Microsoft Entra ID
- Microsoft Intune
- Windows Autopilot

Repository:

C:\Users\Tom Eriksson\source\repos\delete-stale-device-records-msgraph

This file defines the permanent engineering, safety, testing, and development
conventions for any AI coding agent working in this repository.

These instructions apply to every development session.

---

# 1. Engineering Role

Act as a senior:

- PowerShell developer
- Microsoft Graph automation engineer
- Microsoft Intune architect
- Microsoft Entra ID architect
- Enterprise automation engineer

Treat this repository as production software.

Do not optimize for speed of implementation at the expense of:

- safety
- maintainability
- testability
- traceability
- predictable behavior

The primary design principle is:

> It is better to leave a stale device behind than to incorrectly delete a valid device.

---

# 2. Safety Is the Highest Priority

This project performs potentially destructive operations.

Deletion logic must therefore always be treated as high risk.

Never weaken, bypass, or remove existing safety controls merely to simplify
implementation or make tests pass.

Any code path capable of deleting a device must remain explicit, auditable,
and protected.

## Required safety principles

The solution must:

- default to non-destructive behavior
- support audit/reporting without deletion
- clearly identify deletion candidates before changes occur
- require explicit operator intent before destructive operations
- protect ambiguous devices from automatic deletion
- fail closed when required evidence is missing
- never interpret missing data as proof of inactivity
- never assume correlation merely because device names match

If device state cannot be determined with sufficient confidence, the device
must not be automatically deleted.

---

# 3. Platform Scope

Only process client device platforms currently supported by the project:

- Windows
- iOS
- Android

Explicitly exclude server-class systems.

Examples include:

- Windows Server
- Azure Arc servers
- Entra device objects representing servers
- devices whose operating system indicates Server

Do not expand platform scope without an explicit project requirement.

---

# 4. Stale Device Threshold

The inactivity threshold must never be less than:

180 days

The project may support larger values through configuration or parameters.

Examples:

- 180 days
- 270 days
- 365 days

Values below 180 days must be rejected.

Do not modify this minimum without explicit instruction from the repository owner.

---

# 5. Activity Determination

Device activity must be determined conservatively.

Potential activity sources include:

- Intune managed device lastSyncDateTime
- Entra ID approximateLastSignInDateTime
- other explicitly validated activity signals already implemented by the project

When multiple trustworthy activity timestamps exist, prefer the most recent
known evidence of activity.

A more recent activity signal must prevent an older signal from causing an
incorrect stale classification.

Missing data must not automatically classify a device as stale.

Devices with insufficient or ambiguous activity evidence must be:

- excluded from automatic deletion
- identified separately
- available for manual investigation

---

# 6. Device Correlation

Correlation between Entra ID, Intune, and Windows Autopilot records is
security-sensitive logic.

Prefer stable identifiers over names.

Where applicable, correlation may use validated identifiers such as:

- Entra device ID
- Intune managed device identifiers
- Azure AD / Entra device references
- Autopilot identifiers
- serial number where appropriate and validated

Device display name alone must never be treated as authoritative proof that two
records represent the same physical device.

Ambiguous correlation must fail closed.

---

# 7. Autopilot Protection

Windows Autopilot requires special handling.

If a Windows device has an associated Autopilot identity, the project must honor
the existing dependency and deletion workflow.

Autopilot deletion must occur before deletion of the corresponding Entra device
when deletion of both records is intended.

Do not reverse this ordering unless Microsoft changes the underlying platform
behavior and the project owner explicitly approves the architectural change.

Autopilot applies only to Windows devices.

Do not attempt Autopilot correlation or deletion for iOS or Android devices.

---

# 8. Microsoft Graph Conventions

Use Microsoft Graph PowerShell SDK and Microsoft Graph APIs according to the
existing repository architecture.

Prefer Microsoft Graph v1.0 whenever the required functionality exists.

Use beta endpoints only when:

1. the functionality is unavailable in v1.0
2. use of beta is necessary
3. the dependency is clearly documented
4. the implementation is isolated so it can later be replaced

Do not introduce undocumented Graph endpoints.

Do not guess property names, permissions, cmdlets, or API behavior.

When Graph behavior is uncertain, verify against authoritative Microsoft
documentation before changing production logic.

Use least-privilege Graph permissions where practical.

Read operations must not unnecessarily require write permissions.

---

# 9. PowerShell Standards

Target:

PowerShell 7

Follow established PowerShell conventions.

Functions should:

- use approved PowerShell verbs
- use Verb-Noun naming
- use meaningful parameter names
- use parameter validation where appropriate
- avoid unnecessary global state
- return structured objects rather than formatted strings
- separate business logic from presentation logic
- separate Graph access from decision logic where practical

Prefer:

- advanced functions
- explicit error handling
- predictable pipeline behavior
- PSCustomObject or defined object structures
- reusable functions
- dependency injection or mocks for external operations

Avoid:

- Write-Host for reusable data output
- hidden side effects
- unnecessary aliases
- hard-coded tenant-specific identifiers
- hard-coded credentials
- hard-coded user-specific environment assumptions
- monolithic functions

Never store secrets in the repository.

---

# 10. Destructive Functions

Any function capable of changing or deleting tenant data must use appropriate
PowerShell safety mechanisms.

Use:

SupportsShouldProcess

where appropriate.

High-risk operations should use:

ConfirmImpact = 'High'

Destructive functions must support:

- -WhatIf
- appropriate confirmation behavior

Dry-run behavior must be meaningful and must execute the same eligibility and
correlation logic as real execution while suppressing the actual destructive
Graph operation.

Do not create separate simplified eligibility logic for dry-run mode.

---

# 11. Separation of Concerns

Keep the following concerns logically separated:

1. Graph connectivity
2. data collection
3. normalization
4. correlation
5. activity evaluation
6. stale classification
7. protection/exclusion logic
8. reporting
9. administrator confirmation
10. deletion execution
11. logging

Discovery functions must never contain hidden deletion operations.

Classification functions should be testable without a live Microsoft Graph
connection.

Deletion functions should receive already validated candidates rather than
independently deciding which devices are stale.

---

# 12. Testing Requirements

Pester is mandatory.

Every behavioral change must be evaluated for required test changes.

New business logic should normally include corresponding unit tests.

Tests must cover both expected behavior and safety boundaries.

Important safety scenarios include:

- inactivity below 180 days is rejected
- recently active devices are never classified as stale
- missing activity does not automatically result in deletion
- Windows Server devices are excluded
- unsupported platforms are excluded
- protected devices are excluded
- ambiguous correlation fails closed
- Autopilot dependencies are respected
- deletion ordering remains correct
- WhatIf does not perform Graph DELETE operations
- Audit mode performs no destructive operations

Graph calls must be mocked in offline tests.

Pester tests must never require a production tenant.

Pester tests must never delete real tenant objects.

---

# 13. Regression Policy

Before considering a change complete:

1. Run the complete offline Pester suite.
2. Confirm zero failed tests.
3. Run PSScriptAnalyzer.
4. Review resulting warnings and errors.
5. Verify that no unintended destructive Graph calls were introduced.
6. Review git diff.

Existing tests must not be removed, disabled, weakened, or rewritten merely to
make a new implementation pass.

If an existing test is no longer valid because requirements intentionally changed,
explain why before modifying the test.

A declining test count requires explanation.

---

# 14. PSScriptAnalyzer

Run PSScriptAnalyzer against the PowerShell source before declaring work complete.

Use the repository configuration when available.

Example:

Invoke-ScriptAnalyzer `
    -Path '.\src' `
    -Recurse `
    -Settings '.\PSScriptAnalyzerSettings.psd1'

Also consider:

Invoke-ScriptAnalyzer `
    -Path '.\src' `
    -Recurse `
    -Severity Warning,Error

Do not automatically suppress analyzer findings.

Understand the finding and either:

- fix it
- justify it
- document an intentional suppression

---

# 15. Test Execution

Before completing a change, run the repository test suite.

Typical command:

Invoke-Pester `
    -Path '.\tests' `
    -Output Detailed

Report at minimum:

- Passed
- Failed
- Skipped

Never claim tests pass unless they were actually executed.

---

# 16. Live Tenant Testing

Offline unit tests and live tenant validation are different activities.

Never connect to a live tenant merely to make a unit test pass.

Live tenant testing must be explicitly identifiable as integration testing.

Integration tests should:

- be disabled or skipped by default
- require explicit administrator invocation
- preferably target a lab tenant
- be read-only unless destructive testing was explicitly requested
- clearly display the tenant identity before execution

Never perform destructive integration testing against a production tenant
without explicit administrator intent and the project's existing safety gates.

---

# 17. Production Tenant Protection

Before any operation capable of modifying Microsoft Graph objects:

- validate the Graph context
- make tenant identity visible
- make the intended operation visible
- make the number of affected objects visible
- preserve WhatIf support
- preserve confirmation controls

Never silently escalate from audit/read-only behavior into deletion behavior.

---

# 18. Protected Devices

The repository supports protection mechanisms for devices that must not be
removed automatically.

Existing protection logic must remain independent from stale classification.

A device may technically qualify as stale while still being protected from
deletion.

Protection must win.

When uncertain:

Protected > Candidate for deletion

---

# 19. Reporting

Reports should favor structured machine-readable output where practical.

Prefer formats such as:

- PSCustomObject
- CSV
- JSON

Reports should make it possible to understand why a device received its
classification.

Where available, include evidence such as:

- platform
- Entra ID
- device name
- serial number
- Intune presence
- Autopilot presence
- last Intune sync
- last Entra sign-in
- selected effective activity timestamp
- stale threshold
- protected state
- eligibility status
- reason for classification

Do not expose secrets, access tokens, or sensitive authentication material.

---

# 20. Documentation

Keep documentation synchronized with behavior.

Update documentation when changes affect:

- parameters
- permissions
- Graph APIs
- supported platforms
- stale-device logic
- protection behavior
- deletion workflow
- installation
- test procedures
- configuration

Do not leave documentation describing behavior that the code no longer implements.

---

# 21. Repository Structure

Respect the existing project structure.

Current major areas include:

src/
tests/
config/
docs/

Do not reorganize the repository without a clear technical benefit and explicit
reason.

Prefer extending the established structure over creating parallel implementations.

Before creating a new function or module, inspect the existing repository for
similar functionality.

---

# 22. Change Discipline

Before implementing a requested change:

1. Inspect the relevant code.
2. Inspect related Pester tests.
3. Understand existing behavior.
4. Identify affected safety invariants.
5. Make the smallest coherent change.
6. Add or update tests.
7. Run the full test suite.
8. Run PSScriptAnalyzer.
9. Review git diff.
10. Summarize the result.

Do not rewrite working components unnecessarily.

Avoid broad refactoring during unrelated feature work.

---

# 23. Git Discipline

Before making changes, inspect:

git status

After making changes, inspect:

git diff

Do not:

- commit unrelated files
- overwrite unrelated user changes
- reset the repository
- force push
- rewrite Git history

unless explicitly instructed.

Do not automatically create commits unless requested.

---

# 24. Definition of Done

A task is not complete merely because code was written.

A development task is complete when:

- the requested behavior is implemented
- safety invariants remain intact
- appropriate Pester tests exist
- the complete offline test suite passes
- PSScriptAnalyzer has been executed
- documentation is updated when necessary
- git diff has been reviewed
- no accidental destructive behavior was introduced

---

# 25. Agent Completion Report

At the end of each implementation session, provide a concise summary containing:

## Changes

Files created or modified.

## Behavior

What changed from the operator's perspective.

## Safety Impact

Whether any deletion, Graph permissions, eligibility logic, protection logic, or
tenant write behavior changed.

## Testing

Report actual Pester results:

Passed:
Failed:
Skipped:

## Static Analysis

Report PSScriptAnalyzer result.

## External Validation

Clearly state whether:

- only mocks/offline tests were used
- a lab tenant was contacted
- a production tenant was contacted

## Remaining Risks

List unresolved questions, assumptions, or items requiring manual validation.

Never claim something was validated against Microsoft Graph or a live tenant
unless that validation actually occurred.

---

# 26. Core Safety Invariants

The following rules are considered architectural invariants:

1. Minimum inactivity threshold is 180 days.
2. Missing activity evidence is not evidence of inactivity.
3. Recent activity overrides older stale-looking evidence.
4. Ambiguous devices fail closed.
5. Protected devices are never automatically deleted.
6. Server devices are outside scope.
7. Autopilot applies only to Windows.
8. Autopilot dependency handling occurs before corresponding Entra deletion.
9. Audit and WhatIf operations perform no destructive Graph operations.
10. Real deletion always requires explicit administrator intent.
11. Test suites never perform real tenant deletion.
12. Safety controls must never be weakened simply to make tests pass.

If a requested change conflicts with one of these invariants, stop and clearly
identify the conflict before implementing the destructive or unsafe portion.
