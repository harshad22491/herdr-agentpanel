# AgentPanel: setup and everyday use

AgentPanel gives you a small dashboard inside Herdr. It helps you see which AI assistants are set up, whether their last known allowance is running low, and what your team is doing. You keep using your assistants normally.

This version is for **native Windows with Windows PowerShell 5.1**. It does not require Python, Node, a database, or a paid OpenRouter account for the dashboard itself.

## 1. Get Herdr ready

If Herdr already opens on your computer, skip this step.

Open the [official Herdr installation page](https://herdr.dev/docs/install/) and follow its Windows instructions. Open a new terminal window afterward. Type `herdr` and press Enter. You should see the Herdr workspace.

Use a current Herdr release with the pane commands used by this project; the optional plugin requires at least 0.8.0. Windows plugin support may still depend on your Herdr release. Manual startup below is the fallback.

## 2. Install AgentPanel

Get the updated AgentPanel folder, either from the supplied download or from GitHub's green **Code > Download ZIP** button after these changes have been published. If you downloaded a ZIP, right-click it and choose **Extract All**. Open the extracted folder that contains `install-agentpanel.ps1`.

Right-click an empty part of that folder and choose **Open in Terminal**. Make sure the terminal is PowerShell. Paste this line and press Enter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-agentpanel.ps1
```

Wait for “Installed to ...”. The files go into your personal Herdr folder. You do not need administrator access. The installer keeps your existing AgentPanel settings when updating.

The command changes the execution policy only for that one PowerShell process; it does not change your computer's permanent policy.

## 3. Turn it on

Open Herdr. In one of its ordinary PowerShell panes, paste:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\start-agentpanel.ps1"
```

Give it around a minute. A panel should appear on tabs that have enough room, and a team activity board should appear in one tab. If you have many tabs, they fill gradually: the watcher creates at most three panes per pass. It avoids splitting agents that are working or waiting for approval. Widen the terminal or wait until an agent is ready if a panel does not appear.

The watcher runs quietly in the background. You can keep working in the pane where you started it. Running the command twice does not start two watchers.

## 4. Optional: start automatically with Herdr

From a Herdr PowerShell pane, paste this once:

```powershell
herdr plugin link "$env:USERPROFILE\.herdr\agentpanel\watcher-plugin"
```

After reopening Herdr, switch to a tab if the panels have not appeared yet. The plugin responds to tab focus and newly created workspaces. This starts AgentPanel when you use Herdr; it does not launch Herdr when Windows starts.

If the plugin command is unavailable in your installed Herdr release, use the manual startup command in step 3. You can check the [Herdr Windows support page](https://herdr.dev/docs/windows-beta/) before deciding whether to change release channels.

## What the panel tells you

| Label or symbol | What it means |
|---|---|
| AVAILABLE | A local service responded, or you explicitly marked an installed assistant as signed in. This is not a guarantee that every request will succeed. |
| CONFIGURED | The assistant is installed and has setup files. AgentPanel has not verified that its sign-in still works. |
| NOT AVAILABLE | The checks did not establish that the assistant is ready. You may need to install it, sign in, or update its settings. |
| NO CLI | Its command-line app was not found. |
| MANAGED | Herdr reports its integration as current. |
| DETECT-ONLY / PANE-ONLY | It has more limited Herdr integration. |
| Green / yellow / red | A recent quota reading shows less than 75%, 75–90%, or over 90% used. Ollama is green when its local service responds. |
| `?` | No usable quota reading is available. |
| `~` | A saved reading is out of date or invalid. It is not treated as a current allowance. |

Most assistants initially show `?`. That is normal. AgentPanel does not guess their allowance from your subscription name. A reading expires after six hours by default, or sooner if its reported reset time has passed.

The activity board shows live assistants and any task agents that report their work. It keeps task descriptions and estimated times beside live status. Larger teams cycle through pages automatically every five seconds.

## Hide, restore, and stop

Click inside a catalogue panel and press **h** to hide catalogue panels in the current Herdr session. The team board stays available. Click the board and press **h** to bring the panels back.

If the board is missing, run this in any ordinary Herdr PowerShell pane:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\start-agentpanel.ps1" -Show
```

To stop AgentPanel, including its team board:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\stop-agentpanel.ps1"
```

Allow one watcher cycle for shutdown. It closes only panes it can still verify as its own. It leaves your assistant sessions running. Automatic startup stays disabled for that Herdr session until you use the normal start command again.

To remove the automatic-start link:

```powershell
herdr plugin unlink agentpanel-watcher
```

## Optional: quota readings for Codex and Copilot

Quota probing is off by default. It sends a status command to an assistant, so it needs a separate assistant session reserved for this purpose. Do not use your normal working session.

Ask your coding assistant:

> Set up a dedicated quota-only session for each provider I want to monitor. Give each a unique Herdr agent name. Add those names to probeAgents in my AgentPanel settings. Do not register my working sessions as probe targets.

Once those dedicated sessions are ready, the helper can run this in a separate Herdr pane:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\probe-usage.ps1" -Loop
```

Only configured, ready agents are probed. Unknown, busy, and approval-waiting states are skipped at the readiness checks. The prober does not erase text or press Escape to clean up. Keep those sessions dedicated; the checks are not a lock against another person typing at the same instant.

## Optional: assistants using OpenRouter

OpenRouter provides model access. The program running your task creates and manages its assistants. AgentPanel can display their updates even when those assistants do not have separate terminal panes.

For example, one task might have a Researcher comparing choices and a Reviewer checking the result. The board can show both names, their task, model, progress, and the cost their runner reports. Several assistants can report at once without overwriting each other's records. If updates stop, the board says “update overdue.” Completed and failed tasks leave the board after five minutes; their saved records remain on disk.

If you already have an OpenRouter task runner, ask its coding assistant:

> Connect our task agents to AgentPanel using docs/OPENROUTER.md and update-agent-task.ps1. Report each agent separately when it starts, changes state, and finishes. Use reported cumulative cost and tokens, and keep API keys and prompts out of the dashboard records.

Connecting the board does not itself send model requests or buy credits. OpenRouter usage is billed separately from subscriptions you may have with individual assistant apps.

### Try one small text task

The included optional worker can ask a model for a text response, such as a comparison or draft. It cannot edit your project or run tools. Using it makes a real OpenRouter request and may consume your credits.

1. Sign in to OpenRouter, create an API key, and set a spending limit there. Choose a model from its model page and copy its model ID.
2. In a Herdr PowerShell pane, paste these lines. You will be asked for the key without displaying it:

```powershell
$secureKey = Read-Host "OpenRouter API key" -AsSecureString
$env:OPENROUTER_API_KEY = [Net.NetworkCredential]::new('', $secureKey).Password
```

3. Use Notepad to create a text file called `agent-task.txt` in your Documents folder. Put a small request in it and save it.
4. Paste the following, replacing `provider/model-name` with the model ID you chose:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.herdr\agentpanel\invoke-openrouter-task.ps1" -TaskId "my-first-task" -Name "Researcher" -Description "Comparing my options" -Model "provider/model-name" -PromptFile "$env:USERPROFILE\Documents\agent-task.txt" -MaxTokens 1000
```

The worker reports progress to the board, prints the answer, and tells you where it saved a copy. The key is kept in this terminal's environment, not in the project files. Close that terminal or run `Remove-Item Env:OPENROUTER_API_KEY` when finished.

The output limit controls response length; it is not a dollar spending cap. A response that reaches that limit is shown as needing attention so you can review the partial answer.

## Updating an older installation

An old watcher may still be running in a pane or through a Windows scheduled task. Stop that old watcher with Ctrl+C in its watcher pane, or disable the old **HerdrAgentPanelWatcher** task in Task Scheduler. Close the old catalogue and board panes yourself. Do this before starting the new watcher.

Then run the new installer, relink the plugin, and start AgentPanel. Old `limits.json` and `agents-status.json` data remain usable. Old pane-ID ledgers are deliberately not treated as permission to close panes. The new watcher starts a fresh ownership record.

For later updates of this version: run the stop command, wait for its panels to close, install the updated files, and start again. Your settings stay in place.

## If something looks wrong

| What you see | What to try |
|---|---|
| No panels | Run the start command from inside Herdr, widen the window, and allow a minute. A working/blocked agent may postpone creation. |
| “Run ... inside Herdr” | The command was entered in an ordinary Windows terminal. Open Herdr first and use a pane inside it. |
| A catalogue pane remains after hiding | It may have been renamed, reused, or created by the old version. The watcher leaves uncertain panes alone. Close it yourself only after checking its contents. |
| `?` or `~` beside an assistant | The allowance is unknown or outdated. This does not necessarily mean the assistant is unavailable. |
| OpenRouter agent missing | Its runner must report to AgentPanel on this Windows machine. Merely using OpenRouter does not automatically register agents. |
| “update overdue” | The task runner stopped sending updates. Check the runner; the dashboard cannot assume the task finished. |
| Several pages on the board | Wait for the next page; it cycles automatically. |

For a diagnostic message, open the `agentpanel-state` folder inside your personal `.herdr` folder. Each session has a subfolder containing `watcher-health.json`. You can open it in Notepad. Do not edit the pane ownership files.

## Should I use WSL?

For this Windows AgentPanel release, stay with native Windows. The watcher relies on Windows process checks and PowerShell, and the plugin declares Windows support. Moving these files into WSL does not convert them into a Linux version.

For a future workspace made mostly of Linux tools, WSL2 is worth considering. See [Windows or WSL?](WINDOWS-OR-WSL.md) for the practical tradeoff and migration outline.
