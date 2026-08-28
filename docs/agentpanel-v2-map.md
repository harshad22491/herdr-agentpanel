# Wayfinder map: AgentPanel v2 (availability + limits)  [wayfinder:map]

## Destination

AgentPanel pinned to 49 cols in every workspace's first tab, showing (above the existing four
groups) AVAILABLE models colored by remaining subscription limit (green <75% used, yellow
75-90%, red 90%+) and NOT AVAILABLE (gray), with an activity-feed pane below the panel in the
main tab streaming the headless build team's progress.

## Notes

Manager: Claude Fable (this session), manager-only. Implementers: sonnet + haiku subagents
(headless), codex + copilot CLI panes as tabs, ollama via token-thrift offload. Max 10 agents.
Skills in force: grilling (done, 2 rounds), token-thrift, wayfinder.

## Decisions so far

- [Width](#): 49 columns, pinned exactly, everywhere (watcher enforces; replaces 30% ratio).
- [Layout](#): AVAILABLE/NOT AVAILABLE sections ADDED ABOVE the existing MANAGED/DETECT-ONLY/
  PANE-ONLY/NO CLI groups; colors green/yellow/red; NOT AVAILABLE gray.
- [Limit data](#): probe per provider; providers with no readable signal render green + '?'.
- [Team visibility](#): headless subagents + activity feed pane below the AgentPanel (tail of
  ~\.herdr\agent-activity.log); codex/copilot remain visible CLI tabs.

## Tickets

- R1 [research, RESOLVED 2026-08-28, corrections by fable]: availability = per-CLI config/cred
  file existence (claude .credentials.json, codex auth.json, copilot config.json, opencode
  opencode.jsonc, qwen settings.json, grok auth.json, pi/omp agent dirs, qoder settings.json,
  kilo config dir, droid .factory) + `ollama list` exit 0 + gemini special-case (state.json
  activeAccount must be non-null; currently null = NOT AVAILABLE) + known-state OVERRIDES
  (mcode: 0 credits; kimi: never authorized). Haiku's "kilo/droid/mastracode/hermes CLI not
  found" rows were WRONG (fable re-validated: all present). Unvalidated-login configs count
  as AVAILABLE with a '?' suffix.
- R2 [research, RESOLVED 2026-08-28]: NO provider exposes scriptable %-used without spending
  quota (claude: no persisted cap %; codex: live headers only; copilot: only after a billed
  prompt; opencode: local BYOK totals only; ollama: free). Per the standing Limit-data
  decision, all render green+'?' except ollama = solid green. Colored thresholds activate
  only if a provider ever ships a readable signal.
- T1 [task, blocked by R1+R2 -> codex]: catalogue script v2: new sections, colors, probes.
- T2 [task, unblocked -> copilot]: watcher v2: pin created panels to exactly 49 cols
  (split + resize to absolute width; verify on a scratch tab, then clean up).
- T3 [task, unblocked -> fable-mainloop (pane ops) + feed writer]: activity feed: log file
  ~\.herdr\agent-activity.log; pane below AgentPanel in main tab tailing it; manager appends
  one line per dispatch/completion.
- T4 [task, blocked by T1+T2 -> haiku-sub]: end-to-end verify (widths, sections, colors,
  no duplicates, feed alive).
- T7 [task, unblocked -> haiku-sub]: replace append-only feed with a live status board:
  renderer agents-feed.ps1 reads ~\.herdr\agents-status.json (agent -> plain-English task),
  shows only IN-FLIGHT agents (done = removed by manager), and resizes its own pane so
  content-heavy panes get more rows (manager updates the JSON on dispatch/completion).
- T5 [task, RESOLVED]: this tab's panel resized to 49x22, feed 49x10 below it.
- T6 [prototype, blocked by T1 -> sonnet-sub]: pane-driven /usage harvesting (user idea,
  supersedes R2's "impossible" for live-TUI probing): a probe script sends /usage (claude,
  copilot) or /status (codex) into IDLE Herdr agent panes only (never user sessions, never
  busy agents), parses the % from pane read, writes ~\.herdr\limits.json for the catalogue's
  $limitPct. Claude probe needs its own dedicated pane. Cadence + parse rules to prototype.

- T8 [task, unblocked -> haiku-sub]: watcher v3: panel in EVERY tab of every workspace
  (not just first), plus a per-cycle heartbeat line printed in the watcher pane so
  aliveness is observable (repeated silent-death ambiguity today).
- T9 [RESOLVED 2026-08-28]: merged threat assessment at ~\.herdr\layout-threat-assessment.md
  (grok's 8 architecture-specific + copilot's 15 operational + 7 incident-verified items;
  top risks: reboot w/o persistence, watcher-pane closure, detection-based duplicate storm).
  T8 also RESOLVED: every-tab watcher verified PASS by sonnet (11 tabs, 49 cols, settled).

## Not yet specified

- Refresh cadence for auth/limit probes if any prove slow (>1s): may need caching in the
  catalogue loop. Graduates after R1/R2 report probe costs.

## Out of scope

- Making in-process subagents interactive in Herdr (impossible: no terminal).
- Logon persistence for the watcher (user-run schtasks one-liner, already delivered).
