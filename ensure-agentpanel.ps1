# This script watches the Herdr terminal workspace manager and creates an AgentPanel pane in the first tab of every workspace if missing.
# It polls every 15 seconds to ensure the AgentPanel is always up-to-date.
# Detection is content-based: a pane counts as the panel if its last 12 lines contain "AgentPanel".
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.herdr\ensure-agentpanel.ps1"

$ErrorActionPreference = 'Stop'

$AgentPanelMarker = 'agents-catalogue.ps1'
$AgentPanelScriptPath = (Join-Path $env:USERPROFILE '.herdr\agents-catalogue.ps1')
$AgentPanelLaunchCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File '$AgentPanelScriptPath'"
$PollSeconds = 15
$AgentPanelHeaderRegex = 'AgentPanel\s+[0-9]{2}:[0-9]{2}'

$FlagFile = Join-Path $env:USERPROFILE '.herdr\panels-hidden'
$LedgerFile = Join-Path $env:USERPROFILE '.herdr\panel-panes.json'
$KeepFile = Join-Path $env:USERPROFILE '.herdr\panel-keep.txt'

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

function Get-PanelLedger {
    if (-not (Test-Path -LiteralPath $LedgerFile -PathType Leaf)) { return @() }
    try {
        $raw = Get-Content -Raw -LiteralPath $LedgerFile -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $json) { return @() }
        return @($json)
    }
    catch {
        return @()
    }
}

function Set-PanelLedger {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Ledger
    )

    try {
        if ($Ledger.Count -eq 0) {
            '[]' | Set-Content -LiteralPath $LedgerFile -Encoding ascii
        }
        else {
            ($Ledger | ConvertTo-Json) | Set-Content -LiteralPath $LedgerFile -Encoding ascii
        }
    }
    catch {
        # Ignore ledger write failures
    }
}

function Add-PanelLedgerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PaneId
    )

    $ledger = @(Get-PanelLedger) + $PaneId
    Set-PanelLedger -Ledger $ledger
}

function Get-KeepPaneIds {
    if (-not (Test-Path -LiteralPath $KeepFile -PathType Leaf)) { return @() }
    try {
        $lines = Get-Content -LiteralPath $KeepFile -ErrorAction Stop
        return @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    }
    catch {
        return @()
    }
}

function Close-PaneQuiet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PaneId
    )

    try {
        $null = & herdr pane close $PaneId 2>$null
    }
    catch {
        # Ignore close failures
    }
}

function Invoke-HiddenModeIteration {
    # Close every pane the watcher created (from the ledger), then clear it
    $ledger = Get-PanelLedger
    foreach ($paneId in $ledger) {
        if ($paneId) { Close-PaneQuiet -PaneId $paneId }
    }
    Set-PanelLedger -Ledger @()

    # Also close any pre-ledger AgentPanel panes, except ones explicitly kept
    $keepIds = Get-KeepPaneIds
    try {
        $workspaceResp = Get-HerdrJson -ArgList @('workspace', 'list')
        $workspaces = $workspaceResp.result.workspaces
        if ($workspaces) {
            foreach ($workspace in $workspaces) {
                $workspaceId = $workspace.workspace_id
                if (-not $workspaceId) { continue }

                $allPanes = $null
                try {
                    $allPanesResp = Get-HerdrJson -ArgList @('pane', 'list', '--workspace', $workspaceId)
                    $allPanes = @($allPanesResp.result.panes)
                }
                catch {
                    continue
                }
                if (-not $allPanes -or $allPanes.Count -eq 0) { continue }

                foreach ($pane in $allPanes) {
                    $paneId = $pane.pane_id
                    if (-not $paneId) { continue }
                    if ($keepIds -contains $paneId) { continue }

                    try {
                        $content = Invoke-HerdrCommand -ArgList @('pane', 'read', $paneId, '--lines', '40')
                        if ($content -and ([string]::Join("`n", $content)) -match $AgentPanelHeaderRegex) {
                            Close-PaneQuiet -PaneId $paneId
                        }
                    }
                    catch {
                        # Continue to next pane if read fails
                    }
                }
            }
        }
    }
    catch {
        # Swallow errors enumerating workspaces/panes in hidden mode
    }

    $timestamp = Get-Date -Format HH:mm:ss
    Write-Host "heartbeat $timestamp - panels hidden"

    Invoke-EnsureStatusBoard -FallbackToFirstPane
}

function Invoke-EnsureStatusBoard {
    param(
        [switch]$FallbackToFirstPane
    )

    $AgentsFeedScriptPath = (Join-Path $env:USERPROFILE '.herdr\agents-feed.ps1')

    try {
        $workspaceResp = Get-HerdrJson -ArgList @('workspace', 'list')
        $workspaces = $workspaceResp.result.workspaces
        if (-not $workspaces) { return }
    }
    catch {
        return
    }

    # Order workspaces: focused first (if the field is available), then the rest.
    $focusedWorkspaces = @($workspaces | Where-Object { $_.focused })
    $otherWorkspaces = @($workspaces | Where-Object { -not $_.focused })
    $orderedWorkspaces = @($focusedWorkspaces + $otherWorkspaces)

    # 1. Detection: does a status-board pane already exist anywhere?
    foreach ($workspace in $orderedWorkspaces) {
        $workspaceId = $workspace.workspace_id
        if (-not $workspaceId) { continue }

        $allPanes = $null
        try {
            $allPanesResp = Get-HerdrJson -ArgList @('pane', 'list', '--workspace', $workspaceId)
            $allPanes = @($allPanesResp.result.panes)
        }
        catch {
            continue
        }
        if (-not $allPanes -or $allPanes.Count -eq 0) { continue }

        foreach ($pane in $allPanes) {
            $paneId = $pane.pane_id
            if (-not $paneId) { continue }
            try {
                $content = Invoke-HerdrCommand -ArgList @('pane', 'read', $paneId, '--lines', '40')
                if ($content -and ([string]::Join("`n", $content)) -match 'TEAM ACTIVITY') {
                    return
                }
            }
            catch {
                # Continue to next pane if read fails
            }
        }
    }

    # 2. No board pane found anywhere: find a home tab, wherever an AgentPanel already
    # lives, preferring the focused workspace.
    $panelPaneId = $null
    foreach ($workspace in $orderedWorkspaces) {
        if ($panelPaneId) { break }
        $workspaceId = $workspace.workspace_id
        if (-not $workspaceId) { continue }

        $allPanes = $null
        try {
            $allPanesResp = Get-HerdrJson -ArgList @('pane', 'list', '--workspace', $workspaceId)
            $allPanes = @($allPanesResp.result.panes)
        }
        catch {
            continue
        }
        if (-not $allPanes -or $allPanes.Count -eq 0) { continue }

        foreach ($pane in $allPanes) {
            $paneId = $pane.pane_id
            if (-not $paneId) { continue }
            try {
                $content = Invoke-HerdrCommand -ArgList @('pane', 'read', $paneId, '--lines', '40')
                if ($content -and ([string]::Join("`n", $content)) -match $AgentPanelHeaderRegex) {
                    $panelPaneId = $paneId
                    break
                }
            }
            catch {
                # Continue to next pane if read fails
            }
        }
    }

    # In hidden mode there may be no panel pane at all (they were all closed above).
    # Fall back to the first pane of the focused workspace's first tab, so the board
    # still exists as the "restore" button.
    if ((-not $panelPaneId) -and $FallbackToFirstPane -and $orderedWorkspaces.Count -gt 0) {
        try {
            $fallbackWorkspaceId = $orderedWorkspaces[0].workspace_id
            if ($fallbackWorkspaceId) {
                $tabResp = Get-HerdrJson -ArgList @('tab', 'list', '--workspace', $fallbackWorkspaceId)
                $tabs = $tabResp.result.tabs
                if ($tabs -and $tabs.Count -gt 0) {
                    $firstTabId = $tabs[0].tab_id
                    $allPanesResp = Get-HerdrJson -ArgList @('pane', 'list', '--workspace', $fallbackWorkspaceId)
                    $allPanes = @($allPanesResp.result.panes)
                    $tabPanes = @($allPanes | Where-Object { $_.tab_id -eq $firstTabId })
                    if ($tabPanes.Count -gt 0) {
                        $panelPaneId = $tabPanes[0].pane_id
                    }
                }
            }
        }
        catch {
            # Give up silently this cycle
        }
    }

    if (-not $panelPaneId) { return }

    try {
        $splitResp = Get-HerdrJson -ArgList @('pane', 'split', $panelPaneId, '--direction', 'down', '--ratio', '0.5', '--no-focus')
        $newPaneId = $splitResp.result.pane.pane_id
        if ($newPaneId) {
            $runCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File '$AgentsFeedScriptPath' -PaneId $newPaneId"
            $null = Invoke-HerdrCommand -ArgList @('pane', 'run', $newPaneId, $runCommand)
        }
    }
    catch {
        # Give up silently this cycle
    }
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
                    if ($content -and ([string]::Join("`n", $content)) -match $AgentPanelHeaderRegex) {
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

            # Ratio is relative to the pane BEING SPLIT, not the tab area:
            # use the target pane's own current width so the new pane gets exactly 49.
            $ratio = 0.64
            try {
                $layoutResp = Get-HerdrJson -ArgList @('pane', 'layout', '--pane', $targetPaneId)
                $targetWidth = $null
                foreach ($lp in $layoutResp.result.layout.panes) {
                    if ($lp.pane_id -eq $targetPaneId) { $targetWidth = $lp.rect.width; break }
                }
                if ($null -ne $targetWidth -and $targetWidth -gt 55) {
                    $ratio = [math]::Round(1 - (49 / $targetWidth), 4)
                } elseif ($null -ne $targetWidth) {
                    # Target too narrow to host a 49-col panel; skip this tab this cycle.
                    continue
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
                    Add-PanelLedgerEntry -PaneId $newPaneId
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

    Invoke-EnsureStatusBoard
}

while ($true) {
    try {
        if (Test-Path -LiteralPath $FlagFile -PathType Leaf) {
            Invoke-HiddenModeIteration
        }
        else {
            Invoke-EnsureAgentPanelIteration
        }
    }
    catch {
        # Swallow all errors for this iteration (server down, JSON parse failure,
        # transient herdr CLI error, etc.) so the watcher loop never dies.
    }

    Start-Sleep -Seconds $PollSeconds
}
