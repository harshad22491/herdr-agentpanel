# Herdr Panel Layout Threat Assessment

| Rank | Threat | Likelihood | Impact | Mitigation |
|---:|---|---|---|---|
| 1 | Watcher death stops layout and pane health observation. | High | High | Supervise the watcher, restart it automatically, and alert on missed heartbeats. |
| 2 | Reboot without persistence loses workspaces, tabs, panes, and startup commands. | High | High | Persist layout metadata and restore it idempotently at login. |
| 3 | Drive loss or remount invalidates pane working directories. | Medium | High | Validate cwds on restore, fall back safely, and report failed paths. |
| 4 | Duplicate-panel runaway creates panes on repeated retries or reconnects. | Medium | High | Reconcile by stable identities and enforce a hard pane limit. |
| 5 | Prober types into the wrong pane due to stale focus or identity. | Medium | High | Use opaque pane IDs, verify context/cwd, and check expected output. |
| 6 | Quota exhaustion blocks new panes, commands, logs, or state writes. | Medium | High | Track quotas, reserve recovery capacity, cap retention, and alert early. |
| 7 | Herdr server stop leaves pane processes unmanaged. | Medium | High | Health-check and restart the server, then reconcile orphaned panes. |
| 8 | User closes panes still expected by the saved layout. | High | Medium | Detect closure and offer intentional restore instead of silent recreation. |
| 9 | Stale persisted IDs route commands to newly assigned panes. | Medium | High | Treat IDs as opaque/non-reusable and reconcile using durable roles. |
| 10 | Concurrent clients overwrite each other's layout mutations. | Medium | High | Serialize writes and reject stale revisions with a conflict. |
| 11 | Resize or geometry changes hide output or make panels unusable. | Medium | Medium | Enforce minimum dimensions and validate geometry after changes. |
| 12 | Restore starts duplicate agents or commands in occupied panes. | Medium | High | Inspect process/agent state and launch only when readiness is confirmed. |
| 13 | Malformed or partial layout state blocks restoration. | Low | High | Write atomically, validate schema/version, and retain a known-good snapshot. |
| 14 | Pane closure during a command leaves stale monitors and retry loops. | Medium | Medium | Cancel operations on lifecycle events and cap retries with backoff. |
| 15 | Unbounded output/scrollback exhausts memory and slows the panel. | Medium | Medium | Cap buffers, retain bounded history, sample noisy probes, and expose telemetry. |
