# OpenRouter task agents and AgentPanel

OpenRouter is the model API, while a task runner owns agent creation, tools, scheduling and completion. Herdr recognizes terminal-based agents. In-process/headless subagents do not acquire individual Herdr panes merely because they call OpenRouter.

This implementation uses the existing activity-board seam: the runner reports a record for each `(task_id, agent_id)` pair. It works for agents with a pane, headless agents on the same Windows machine, and runners that forward their events to a local bridge. It does not scrape private sessions or discover cloud tasks automatically.

## Reporting from an existing runner

Call the installed script at dispatch, state changes and completion. Refresh long tasks at least once every few minutes; the default stale threshold is 15 minutes.

```powershell
$report = "$env:USERPROFILE\.herdr\agentpanel\update-agent-task.ps1"
& $report -TaskId 'checkout-fix' -AgentId 'research-1' -Name 'Researcher' -Description 'Comparing checkout approaches' -Provider openrouter -Model 'provider/model-id' -ParentAgentId 'manager' -Status working -Sequence 1

# After the runner finishes, report its actual cumulative accounting:
& $report -TaskId 'checkout-fix' -AgentId 'research-1' -Name 'Researcher' -Description 'Comparison complete' -Provider openrouter -Model 'provider/model-id' -ParentAgentId 'manager' -Status done -CostUsd 0.012 -TotalTokens 730 -Sequence 2
```

The numbers above illustrate reporting, not model pricing. Omit cost/tokens when unknown. Zero means reported zero; it never means missing data. Costs and tokens are cumulative totals for this agent in this task, not deltas. For multiple model calls, sum the runner's reported usage once. A later update that omits accounting preserves earlier accounting.

Use a stable agent ID, not just its display name. Give each new run its own task ID. Monotonically increasing positive sequence numbers discard late/replayed events. Once a record uses sequences, updates to that record must keep using them. Without sequences, the most recent write wins.

States: `working`, `idle`, `blocked`, `done`, `failed`. Optional fields: `ParentAgentId`, `PaneId`, `Eta`. `PaneId` is an explicit association with a Herdr agent; the board uses the task row instead of an extra generic live row for that pane. It is display data and never authorizes pane control. Different agents in the same task each get their own row. Task records are shared across this installation's Herdr sessions; hide/ownership state is session-specific.

## Storage and accounting

The reporter writes atomic UTF-8 JSON to `%USERPROFILE%\.herdr\agent-tasks\<hash>.json`, with a per-record lock. Different agents use different files. A partial or invalid record cannot erase other agents. Done/failed entries leave the visible board after five minutes by default. Stale active entries remain visible as “update overdue.” Records and optional results remain on disk until the user removes them.

OpenRouter supplies `usage.cost` and token counts in API responses; streaming usage arrives in the final SSE message. Capture these in the runner rather than estimating cost from a model's name. This is consumption accounting, separate from Codex/Copilot subscription percentages. [Official usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting)

The authenticated `/api/v1/key` endpoint can report a key's limit and remaining allowance. It does not identify your local task-agent tree. This version deliberately reports per-task consumption and does not label account credit as a subscription percentage. [Official key endpoint](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)

## Included optional worker

`invoke-openrouter-task.ps1` is a minimal, non-streaming text worker using `POST https://openrouter.ai/api/v1/chat/completions`. It reads `OPENROUTER_API_KEY` from its environment, takes a UTF-8 prompt file and a caller-selected model, records working/done/failed state, and saves the response separately in `task-results`. An output-limit finish reports `blocked`. It uses a 120-second request timeout and a bounded output-token request. There are no automatic retries that could duplicate charges.

It is useful for comparisons, summaries, review text and drafting. It is not a tool-executing coding agent or a replacement for your orchestration framework. Existing tool-capable runners should use the reporting script around their own agent lifecycle.

The dashboard never needs an API key to read reports. Keys, prompts and raw API errors are not written into dashboard records. Result text is saved locally and may itself contain sensitive information supplied by the model. Do not commit runtime state. Tests replace the network call with a fixture and make no billable requests.

## Example delegation pattern

1. A manager creates task `checkout-fix`.
2. It launches Researcher and Reviewer using its existing OpenRouter client.
3. Each reports its own ID, description, model and parent manager.
4. The manager keeps authority over tool access and file changes.
5. The runner reports completion and actual cost for each child.

The board lets a person follow that work alongside terminal-based assistants without manufacturing panes for headless agents.
