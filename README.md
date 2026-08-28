# herdr-agentpanel

A self-healing agent dashboard for [Herdr](https://herdr.dev) terminal workspaces on
Windows. Every tab of every workspace gets a live 49-column **AgentPanel** showing which
AI coding agents you can call and how much of their quota is left — plus a plain-English
status board for a multi-agent build team.

Built (and battle-tested the hard way) with PowerShell 5.1 and the `herdr` CLI only —
no other dependencies.

## Components

| Script | Role |
|---|---|
| `agents-catalogue.ps1` | The panel itself. Every 60s probes which agent CLIs are installed, authenticated, or free (config/credential file checks, `ollama list`, per-provider overrides), reads `limits.json`, and renders grouped sections: `AVAILABLE` (green/yellow/red by % of subscription used, `?` = unknown), `NOT AVAILABLE`, plus Herdr-integration groups (`MANAGED` / `DETECT-ONLY` / `PANE-ONLY` / `NO CLI`). |
| `ensure-agentpanel.ps1` | The watcher. Every 15s ensures every tab of every workspace has exactly one panel (creates missing ones at exactly 49 columns), prints a heartbeat line per cycle, caps creation at 3 panels/cycle. |
| `agents-feed.ps1` | The status board. Renders `agents-status.json` (agent name → plain-English task description) in a pane that resizes itself to fit its content (4–20 rows). Entries are removed when an agent finishes. |
| `probe-usage.ps1` | The quota prober. Finds *idle* codex/copilot agents in Herdr panes, sends `/status` / `/usage` into their TUIs, parses the rendered percentage, and merges it into `limits.json` — which colors the panel. Hard exclusion list keeps it away from your own sessions. |

## Install

Copy the four scripts to `%USERPROFILE%\.herdr\`, then from any Herdr pane:

```powershell
# the watcher (creates panels everywhere, keeps them alive)
herdr pane run <pane-id> "powershell -NoProfile -ExecutionPolicy Bypass -File '%USERPROFILE%\.herdr\ensure-agentpanel.ps1'"

# the status board (pass the pane id it runs in)
herdr pane run <pane-id> "powershell -NoProfile -ExecutionPolicy Bypass -File '%USERPROFILE%\.herdr\agents-feed.ps1' -PaneId <pane-id>"
```

Survive reboots by registering the watcher at logon (run yourself — one line):

```
schtasks /Create /F /TN HerdrAgentPanelWatcher /SC ONLOGON /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%USERPROFILE%\.herdr\ensure-agentpanel.ps1\""
```

Adjust the availability probe table in `agents-catalogue.ps1` (config paths, overrides) and
the pane exclusion list in `probe-usage.ps1` for your machine.

## Hard-won Herdr CLI semantics (0.7.5-preview)

- `pane split --ratio R` — R is the fraction the **original** pane keeps; the new pane gets `1-R`.
- `pane resize --amount F` — F is a fraction of the **total** dimension; rounds to whole cells (sub-cell amounts do nothing).
- `pane list` has **no** `--tab` flag — fetch per workspace, filter by `tab_id`.
- `pane process-info` reports only the pane's wrapper shell, never children started via `pane run` — detect what runs in a pane by its **content**, not its process.
- Output that leaves an alternate-screen TUI is unrecoverable via `pane read` — anything important must go to a file.
- `pane move` within the same tab is a no-op (`reason: same_tab`) — bounce via `--new-tab` and back.

## Threat model

`docs/layout-threat-assessment.md` is a ranked list of everything that can make this layout
disappear or misbehave (reboot without persistence, watcher-pane closure, detection-miss
duplicate storms, dead working directories after drive loss, prober mis-targeting, …), each
with mitigation — many verified by live incident. Raw per-agent assessments and the build's
wayfinder map are alongside it in `docs/`.

## Credits

Built by a multi-agent team orchestrated from Claude Code: Claude Fable (manager/reviewer),
Claude Sonnet and Haiku subagents (build, fixes, verification), OpenAI Codex (catalogue v2,
code review), GitHub Copilot (ops threat list), Grok (red-team), and a local
Ollama/qwen2.5:3b (text piecework). Human direction throughout by the repo owner.
