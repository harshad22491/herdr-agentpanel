# Layout Threat Assessment (merged)

Sources: Grok red-team (architecture-specific, ~\.herdr\threats-grok.md), Copilot ops list
(~\.herdr\threats-copilot.md), and incidents actually observed on 2026-08-28. Ranked by
(likelihood x impact), incident-verified items marked [SEEN TODAY].

## What can make the layout go away

1. **Reboot / Herdr server stop with no persistence** — H/H. Nothing revives the watcher,
   panels, or board after a reboot; a server stop kills every pane process. MITIGATION:
   user-run `schtasks` logon registration (one-liner already delivered, still pending);
   until then, relaunch commands are in ~\.herdr\ scripts + memory.
2. **Watcher pane closed (by user, tab cleanup, or ctrl+c)** [SEEN TODAY x3] — H/H. The
   layout stops healing; existing panels linger but new tabs get nothing. MITIGATION:
   heartbeat line makes death visible; a second watchdog (or the schtasks task) can respawn;
   never run the watcher in a tab that gets tidied up.
3. **Detection miss -> duplicate-panel storm** [SEEN TODAY] — H/H. A squeezed/mis-sized panel
   hid its header; watcher spawned panels each cycle in both workspaces. MITIGATED: header
   regex + 40-line window + 3-per-cycle cap. STRONGER FIX (grok): detect by pane process
   (agents-catalogue.ps1 in command) or title, not screen text; lockfile per tab.
4. **Detection false-positive freeze** [SEEN TODAY] — M/M. Agent panes containing the words
   "AgentPanel HH:MM"-like text (e.g. task prompts) suppress panel creation. MITIGATED by
   header+time regex; residual risk if an agent prints that exact pattern.
5. **Dead working directory (drive vanishes)** [SEEN TODAY] — M/H. D: went offline; every
   pane whose shell sat in it broke (copilot unusable, panel/feed relaunch failures). Splits
   inherit the split pane's cwd, so new panels in such tabs are born broken. MITIGATION:
   create panes with an explicit safe --cwd; grok: treat a dead-cwd shell as broken, close
   and recreate on C:.
6. **Prober types into the wrong pane** — H/H if it happens. /status into a user's busy pane
   could submit text into a real session. MITIGATION in place: idle-only + hard exclusion
   list (all three user panes); grok's stronger form: allow-list dedicated probe panes only.
7. **Split target bisects a live agent** (grok) — M/M. The watcher splits tabPanes[0], which
   in an agent tab is the agent itself; repeated splits shrink working agents. MITIGATION:
   prefer splitting a shell pane / skip panes with agent_status working|blocked.
8. **Two resizers fight** (grok) — M/M. The board's self-resize and the watcher both mutate
   layout; interleaved they can thrash (a probe-resize was observed shrinking p1 to 12 cols).
   MITIGATION: board resize is capped 4-20 rows and only acts on 2+ row drift; grok's
   stronger form: one owner of layout mutations.
9. **Quota exhaustion of an agent provider** [SEEN TODAY: codex 100%] — M/M for the layout
   (the panel itself keeps working; agent tabs die). Panel now displays this (red).
10. **Ratio/geometry semantics traps** [SEEN TODAY x3] — M/M. split --ratio is the fraction
    the ORIGINAL pane keeps; resize --amount is a fraction of the total dimension and rounds
    to cells; sub-cell amounts round to zero. All now encoded in the scripts; any future
    hand-edit that forgets this reintroduces 14-col or 87-col panels.
11. **Stale pane IDs after tab churn** [SEEN TODAY] — M/M. Panes/tabs vanish and IDs shift
    (pF->pR->pX->p11); scripts holding hardcoded IDs (board -PaneId, prober exclusions) go
    stale. MITIGATION: pass IDs as parameters at launch; re-resolve at start; the exclusion
    list should move to name/agent-based matching.
12. **Concurrent writers on state files** — L/M. limits.json is written by the prober and
    read by every panel each minute; agents-status.json by the manager and board. Partial
    writes are tolerated (try/catch -> unknown for a cycle). Atomic temp+rename would close
    the residual gap.
13. **Scrollback loss on alternate screens** [SEEN TODAY: grok's list] — M/L. Output that
    leaves an alternate-screen TUI is unrecoverable via pane read; anything important must
    go to a file, not chat scrollback.
14. **Unbounded heartbeat scrollback** — L/L. The watcher pane accumulates heartbeat lines
    indefinitely; harmless for days, eventually heavy. Periodic Clear-Host every N cycles
    would bound it.

## Standing fragilities (accepted for v3)

- No reboot persistence until the user runs the schtasks one-liner.
- Screen-text detection (vs process/title) — better fix identified, not yet implemented.
- Board/prober hold pane IDs from launch time; a moved/recreated board needs a relaunch
  with the new ID.
