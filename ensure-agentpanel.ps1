# This script watches the Herdr terminal workspace manager and creates an AgentPanel pane in the first tab of every workspace if missing.
# It polls every 15 seconds to ensure the AgentPanel is always up-to-date.
# Detection is content-based: a pane counts as the panel if its last 12 lines contain "AgentPanel".
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.herdr\ensure-agentpanel.ps1"

$ErrorActionPreference = 'Stop'

$AgentPanelMarker = 'agents-catalogue.ps1'
$AgentPanelScriptPath = Join-Path $env:USERPROFILE '.herdr\agents-catalogue.ps1'
$AgentPanelLaunchCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File '$AgentPanelScriptPath'"
$PollSeconds = 15

function Invoke-HerdrCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgList
    )

    $output = & herdr @ArgList
    if ($LASTEXITCODE -ne 0) {
        throw "herdr command failed (exit code $LASTEXITCODE): herdr $($ArgList -join ' ')"
    }
    return $output
}

function Get-HerdrJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgList
    )

    $rawLines = Invoke-HerdrCommand -ArgList $ArgList
    $rawText = [string]::Join("`n", $rawLines)
    return $rawText | ConvertFrom-Json
}

function Invoke-EnsureAgentPanelIteration {
    $workspaceResp = Get-HerdrJson -ArgList @('workspace', 'list')
    $workspaces = $workspaceResp.result.workspaces
    if (-not $workspaces) { return }

    $totalTabsChecked = 0
    $totalPanelsCreated = 0

    foreach ($workspace in $workspaces) {
        $workspaceId = $workspace.workspace_id
        if (-not $workspaceId) { continue }

        $tabResp = Get-HerdrJson -ArgList @('tab', 'list', '--workspace', $workspaceId)
        $tabs = $tabResp.result.tabs
        if (-not $tabs -or $tabs.Count -eq 0) { continue }

        # pane list has no --tab flag: fetch once per workspace, filter per tab below
        $allPanes = $null
        try {
            $allPanesResp = Get-HerdrJson -ArgList @('pane', 'list', '--workspace', $workspaceId)
            $allPanes = @($allPanesResp.result.panes)
        }
        catch {
            continue
        }
        if (-not $allPanes -or $allPanes.Count -eq 0) { continue }

        # Iterate ALL tabs (not just first)
        foreach ($tab in $tabs) {
            # Safety cap: never create more than 3 panels in one cycle
            if ($totalPanelsCreated -ge 3) { break }

            $totalTabsChecked++
            $tabId = $tab.tab_id
            if (-not $tabId) { continue }

            $tabPanes = @($allPanes | Where-Object { $_.tab_id -eq $tabId })
            if ($tabPanes.Count -eq 0) { continue }

            # Check if AgentPanel exists in this tab
            $panelFound = $false
            foreach ($pane in $tabPanes) {
                try {
                    $content = Invoke-HerdrCommand -ArgList @('pane', 'read', $pane.pane_id, '--lines', '40')
                    if ($content -and ([string]::Join("`n", $content)) -match 'AgentPanel\s+[0-9]{2}:[0-9]{2}') {
                        $panelFound = $true
                        break
                    }
                }
                catch {
                    # Continue to next pane if read fails
                }
            }

            if ($panelFound) { continue }

            # Create panel in this tab
            $targetPaneId = $tabPanes[0].pane_id

            # Get the area width from a pane of THIS tab and compute the ratio for 49-column panel
            $ratio = 0.64
            try {
                $layoutResp = Get-HerdrJson -ArgList @('pane', 'layout', '--pane', $targetPaneId)
                $areaWidth = $layoutResp.result.layout.area.width
                if ($null -ne $areaWidth -and $areaWidth -gt 0) {
                    $ratio = [math]::Round(1 - (49 / $areaWidth), 4)
                }
            }
            catch {
                # Fall back to default ratio on error
            }

            try {
                $splitResp = Get-HerdrJson -ArgList @('pane', 'split', $targetPaneId, '--direction', 'right', '--ratio', $ratio.ToString(), '--no-focus')
                $newPaneId = $splitResp.result.pane.pane_id
                if ($newPaneId) {
                    $null = Invoke-HerdrCommand -ArgList @('pane', 'run', $newPaneId, $AgentPanelLaunchCommand)
                    $totalPanelsCreated++
                }
            }
            catch {
                # Skip this tab if split or run fails
            }
        }
    }

    # Heartbeat at end of cycle
    $timestamp = Get-Date -Format HH:mm:ss
    Write-Host "heartbeat $timestamp - checked $totalTabsChecked tabs, created $totalPanelsCreated panels"
}

while ($true) {
    try {
        Invoke-EnsureAgentPanelIteration
    }
    catch {
        # Swallow all errors for this iteration (server down, JSON parse failure,
        # transient herdr CLI error, etc.) so the watcher loop never dies.
    }

    Start-Sleep -Seconds $PollSeconds
}
