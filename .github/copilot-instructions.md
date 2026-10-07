# GitHub Copilot Instructions

Read and follow the repository root `AGENTS.md` before making any changes.

`AGENTS.md` defines the authoritative:

- architecture conventions

- PowerShell conventions

- Microsoft Graph conventions

- safety invariants

- testing requirements

- Pester requirements

- PSScriptAnalyzer requirements

- Definition of Done

This repository contains destructive device-cleanup capabilities.

Safety takes precedence over implementation convenience.

Before modifying code:

1. Read `AGENTS.md`.

2. Inspect existing implementation.

3. Inspect relevant Pester tests.

4. Preserve all documented safety invariants.

Before declaring work complete:

1. Run the complete offline Pester suite.

2. Run PSScriptAnalyzer.

3. Review `git diff`.

4. Report actual test results.

5. Explicitly state whether any live tenant was contacted.

Never weaken tests or safety controls merely to make an implementation succeed.

Never perform real tenant deletion unless explicitly requested and protected by

the repository's established safety mechanisms.
