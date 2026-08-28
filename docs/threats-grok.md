1. Detection miss -> duplicate-panel storm — H — Detect by pane title/command (agents-catalogue.ps1) plus a lockfile, never by screen text; refuse a second split in a tab that already has a catalogue process.
2. Watcher pane closed or reboot with no schtasks — H — Register a user logon task; if the watcher pane vanishes, respawn it from a second watchdog or Herdr session hook, not from the same pane.
3. Prober types /status or /usage into a user or busy pane — H — Allow-list dedicated probe panes only; use agent prompt after a fresh idle check; drop hardcoded pane IDs and the ESC/backspace/enter cleanup.
4. Inverted split ratio + tiny pane wraps the header — H — Pin width with an absolute resize to 49 cols after split; treat width < 40 as panel broken, close extras, do not split again.
5. Split of tabPanes[0] bisects a live agent — M — Split only a shell pane (or the existing panel neighbor); never split a pane with agent_status working/blocked.
6. New pane inherits a dead cwd (vanished drive) — M — Always pane split --cwd $HOME (or a known-live path); if process-info shows the shell exited, close and recreate on C:.
7. Clear-Host / wrap / clock format hides AgentPanel HH:mm for a full 15s poll — M — Marker must survive refresh (title, env, or a line that is not cleared); read --source detection, not a 40-line regex on recent.
8. Feed self-resize fights the watcher and steals agent rows — M — Cap the board to a fixed 49xN; disable direction-probe resizes; only the watcher may change layout, and only when a panel is missing.
