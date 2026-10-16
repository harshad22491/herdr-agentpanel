# herdr-agentpanel

A Windows dashboard for Herdr workspaces: assistant readiness, recent quota readings,
team activity, and task agents using OpenRouter.

<<<<<<< HEAD
Built (and battle-tested the hard way) with PowerShell 5.1 and the `herdr` CLI only —
no other dependencies for the dashboard. The optional bundled sidebar is a Rust
plugin with its own build requirements.

## Project-aware sidebar

`plugins/herdr-sidebar/` contains our modified version of
[Alex Arthurs' herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar).
It automatically follows the working pane's directory on Windows and keeps
the file explorer and Git view on the same project, including when spaces reuse
the same name. AgentPanel utility panes do not override the project directory.

See the [sidebar installation and change notes](plugins/herdr-sidebar/README.md).
The dashboard scripts and watcher remain separate and are not replaced.
=======
**Start with the [plain-language setup guide](docs/USER-GUIDE.md).**

This release uses Windows PowerShell 5.1 and the Herdr CLI. It is not a Linux/WSL
port. See [Windows or WSL?](docs/WINDOWS-OR-WSL.md) for the tradeoff.

## Install and start

From this repository's folder in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-agentpanel.ps1
```

Then, inside a Herdr PowerShell pane:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\start-agentpanel.ps1"
```

Optional autostart (Herdr >= 0.8 with Windows plugin support):

```powershell
herdr plugin link "$env:USERPROFILE\.herdr\agentpanel\watcher-plugin"
```

The plugin responds to workspace creation and tab focus. It does not launch Herdr
at Windows logon. Manual startup is available when plugin support is unavailable.

Press **h** in a catalogue panel to hide catalogues throughout the current Herdr
session. The board remains the restore control. If it is missing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\start-agentpanel.ps1" -Show
```

Stop monitoring and close verified owned panes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\stop-agentpanel.ps1"
```

For old installations, stop the old watcher/scheduled task and close old panels
before enabling this version. See the guide's upgrade instructions. Legacy pane-ID
ledgers and screen headers are never adopted as authority to close panes.
>>>>>>> 94805bb (v4: shared common modules, installer, start/stop scripts, OpenRouter task runner, tests and docs)

## Components

| File | Responsibility |
|---|---|
| `agents-catalogue.ps1` | Renders readiness, integration groups and quota freshness; emits a renderer heartbeat. |
| `ensure-agentpanel.ps1` | Owns layout changes, pane ownership, recovery and duplicate reconciliation. |
| `agents-feed.ps1` | Merges live status, manual descriptions and task-agent reports; cycles through pages without resizing the layout. |
| `agentpanel-common.ps1` | Configuration, session identity, command handling, locking and atomic JSON writes. |
| `limits-common.ps1` | Timestamp/reset parsing, percentage validation and quota expiry. |
| `probe-usage.ps1` | Opt-in probing of explicitly named dedicated Codex/Copilot agents. |
| `task-common.ps1`, `update-agent-task.ps1` | Atomic task lifecycle reports, sequence ordering and stale-state detection. |
| `invoke-openrouter-task.ps1` | Optional single-request text worker with actual reported cost/tokens. |
| `install-agentpanel.ps1`, `start-agentpanel.ps1`, `stop-agentpanel.ps1` | Installation and lifecycle controls. |
| `watcher-plugin/` | Event-based startup using the same singleton launcher. |

## Recovery and ownership

The watcher records a unique token, pane/tab identity, renderer role, shell PID,
shell start time and exact launch command. Renderers publish process identity and
timestamps separately from their displayed text. Moved panes are found by their
unique labels; screen contents are never used to identify a panel.

Before closing an owned pane, the watcher rechecks its current label, agent state,
shell identity and child processes. A renamed pane, a pane hosting an agent,
unrelated child processes, or inaccessible process information prevents closure.
Such panes are left for manual inspection; their recorded slots remain reserved.

A singleton mutex serializes watchers for each session. Each successful split
counts immediately toward the default three-per-cycle budget, including boards
and failed launches. Ownership is saved before launch. Failed launches attempt
verified cleanup; missing heartbeats trigger recovery after the startup grace.
Verified duplicates are removed. A corrupt ledger stops startup instead of
granting permission to modify unknown panes.

Panels target 49 columns while leaving at least 40 working columns. Existing
column correction and restoration above a surviving board are retained. The
board starts at half the selected column's height; its renderer does not fight
the watcher with its own resizer. Narrow tabs and working/blocked targets may
postpone creation. Geometry is subject to terminal cell rounding.

## Configuration and state

The installer copies runtime scripts into `%USERPROFILE%\.herdr\agentpanel`.
Settings live separately in `%USERPROFILE%\.herdr\agentpanel.json`.
See [agentpanel.example.json](agentpanel.example.json). Restart monitoring/renderers
after changing settings; the quota prober reloads its configuration each cycle.

- `availability`: optional provider overrides, `authenticated` or `unavailable`.
  Even an authenticated override requires the CLI. Config files alone mean
  CONFIGURED, not verified authentication.
- `probeAgents`: provider to dedicated unique Herdr agent name. Empty by default.
  Example: `{ "codex": "quota-codex", "copilot": "quota-copilot" }`.
  Reserve these sessions solely for probing; never use working user sessions.
- `excludedPanes`: optional pane IDs excluded from control, probing and the board.
- `limitTtlHours`: maximum observation age, default six hours. Known reset times
  can shorten this lifetime, never lengthen it.
- `taskTtlMinutes`: update age before an active task is marked overdue, default 15.
- `completedTaskMinutes`: how long done/failed tasks remain visible, default five.

Fresh quota is green below 75% used, yellow through 90%, and red above 90%.
Unknown quota has `?`; expired/invalid saved quota has `~`, both neutral.
Ollama's local-service readiness is separate from subscription quota.

Legacy numeric `limits.json` entries use the original file timestamp; merging
another provider converts them to timestamped entries without refreshing their age.
Updates use a lock and atomic replacement. Invalid JSON is not overwritten.

Manual descriptions use `agents-status.json`; both the old flat mapping and the
`agents`/`next` format work. See [agents-status.example.json](agents-status.example.json).
Matching live agents retain manual descriptions and ETAs.

Ownership, hidden/disabled flags and `watcher-health.json` live in session-specific
`agentpanel-state` subfolders. Quotas, manual descriptions and `agent-tasks` are shared
across this installation's sessions. Task results and reports remain local until
removed; the Git ignore file excludes runtime state.

## OpenRouter

[OpenRouter integration guide](docs/OPENROUTER.md) explains how an existing task
runner reports separate headless agents, parent/task IDs, state, models, and
cumulative cost/tokens. Reporting does not require an API key or make model calls.

The optional worker reads `OPENROUTER_API_KEY` from its environment and makes one
caller-requested model call. It prints and saves text results; it cannot execute
tools or edit the project. API usage is distinct from provider subscriptions.
Tests use mocked responses and incur no model charges.

## Verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

The suite checks syntax with Windows PowerShell 5.1, quota expiry, ownership,
split-failure cleanup, hidden-mode recovery, probe targeting, task merging,
concurrent writers, installation upgrades, and a mocked OpenRouter request.
GitHub Actions runs the same command on Windows.

Live Herdr layout behavior is not covered by mocks. Before deploying an update,
check a disposable workspace for create/hide/show, watcher restart, a closed
renderer, a renamed/reused pane, and a narrow tab. Never run these experiments
against someone's working agent panes.

## History

[Layout threat assessment](docs/layout-threat-assessment.md) and the original
[wayfinder map](docs/agentpanel-v2-map.md) retain the incident context behind this
project. The current implementation and this README supersede historical
instructions about screen detection, arbitrary quota panes and board resizing.

## Credits

<<<<<<< HEAD
The bundled sidebar is based on **Alex Arthurs'
[herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar)**, upstream commit
`13ebde8d631494f1273d8c5e3503a755047c1267` (0.10.0). Its source, screenshots,
and launch scripts retain the original
[MIT license and copyright notice](plugins/herdr-sidebar/LICENSE).
This repository adds the project-directory-following fixes described in the
[sidebar change notes](plugins/herdr-sidebar/UPSTREAM.md); it does not claim
authorship of the original sidebar.

Built by a multi-agent team orchestrated from Claude Code: Claude Fable (manager/reviewer),
Claude Sonnet and Haiku subagents (build, fixes, verification), OpenAI Codex (catalogue v2,
code review), GitHub Copilot (ops threat list), Grok (red-team), and a local
Ollama/qwen2.5:3b (text piecework). Human direction throughout by the repo owner.
=======
Originally built by a multi-agent team coordinated by the repository owner.
See the project history for contributions. MIT licensed.
>>>>>>> 94805bb (v4: shared common modules, installer, start/stop scripts, OpenRouter task runner, tests and docs)
