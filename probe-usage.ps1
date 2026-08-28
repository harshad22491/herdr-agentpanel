# probe-usage.ps1
# Harvests real usage-limit percentages from live agent TUIs running in Herdr
# panes (codex and copilot) and writes them to limits.json next to this
# script, as an object mapping provider name -> percent-used number (0-100).
# The AgentPanel catalogue reads that file.
#
# PowerShell 5.1 compatible. Pure ASCII. No ternary / null-coalescing used.

[CmdletBinding()]
param(
    [switch]$Loop
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LimitsPath = Join-Path $ScriptDir 'limits.json'

# Hard exclusions: never touch these panes, they are user sessions.
$ExcludedPanes = @('w8:p2', 'w5:p1', 'w8:p1')

# ---------------------------------------------------------------------------
# herdr CLI wrapper
# ---------------------------------------------------------------------------

function Invoke-HerdrRaw {
    param(
        [Parameter(Mandatory = $true)][string[]]$CmdArgs
    )
    $output = & herdr @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("herdr " + ($CmdArgs -join ' ') + " failed with exit code " + $LASTEXITCODE)
    }
    return $output
}

function Get-HerdrAgentList {
    $raw = Invoke-HerdrRaw -CmdArgs @('agent', 'list')
    $text = $raw -join "`n"
    $obj = $text | ConvertFrom-Json
    return $obj.result.agents
}

# ---------------------------------------------------------------------------
# Candidate selection
# ---------------------------------------------------------------------------
# Per herdr's own model, 'idle' and 'done' are the same underlying idle
# state ('done' is idle-before-being-seen by the focused UI). Both are safe
# targets. 'working' means busy and must not be touched (except the
# copilot poll-and-wait path below).

function Find-IdleAgent {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][array]$Agents
    )
    foreach ($a in $Agents) {
        if ($a.agent -ne $Kind) { continue }
        if ($ExcludedPanes -contains $a.pane_id) { continue }
        if ($a.agent_status -eq 'idle' -or $a.agent_status -eq 'done') {
            return $a
        }
    }
    return $null
}

function Find-AnyAgent {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][array]$Agents
    )
    foreach ($a in $Agents) {
        if ($a.agent -ne $Kind) { continue }
        if ($ExcludedPanes -contains $a.pane_id) { continue }
        return $a
    }
    return $null
}

# ---------------------------------------------------------------------------
# Pane input cleanup
# ---------------------------------------------------------------------------

function Clear-PaneInput {
    param([Parameter(Mandatory = $true)][string]$PaneId)
    try {
        Invoke-HerdrRaw -CmdArgs @('pane', 'send-keys', $PaneId, 'esc') | Out-Null
        Start-Sleep -Milliseconds 500
        $check = Invoke-HerdrRaw -CmdArgs @('pane', 'read', $PaneId, '--source', 'visible', '--lines', '12')
        $checkText = $check -join "`n"
        # Stray typed text shows up right after the input-box prompt marker
        # as a non-placeholder token (e.g. a partially typed slash command).
        $promptMarkerPattern = '(?m)^\s*(?:' + [char]0x203A + '|>)\s*/\S'
        if ($checkText -match $promptMarkerPattern) {
            for ($i = 0; $i -lt 24; $i++) {
                Invoke-HerdrRaw -CmdArgs @('pane', 'send-keys', $PaneId, 'backspace') | Out-Null
            }
            Invoke-HerdrRaw -CmdArgs @('pane', 'send-keys', $PaneId, 'enter') | Out-Null
        }
    } catch {
        Write-Warning ("Clear-PaneInput: best-effort cleanup failed for " + $PaneId + ": " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Output parsers
# ---------------------------------------------------------------------------

# codex /status prints a "5h limit:" bar with a "<N>% left" figure, e.g.:
#   5h limit:             [XXXXXXXXXXXXXXXXXXXX] 0% left (resets 18:54)
# percent-used = 100 - percent-left. When the account is fully exhausted the
# CLI additionally shows a banner containing "hit your usage limit", which
# is treated as an explicit 100% marker if the bar line cannot be parsed.
function Parse-CodexPercentUsed {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -match '(?im)5h limit:\s*(?:\[[^\]]*\]\s*)?(\d+)%\s*left') {
        $left = [int]$Matches[1]
        $used = 100 - $left
        return $used
    }
    if ($Text -match '(?im)hit your usage limit') {
        return 100
    }
    return $null
}

# copilot /usage prints a "Plan" line with a "<N>% used" figure, e.g.:
#   Plan       XXXXXXXXXXXXXXXXXXXX 1% used - resets in 3 days
function Parse-CopilotPercentUsed {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -match '(?im)Plan\s+.*?(\d+)%\s*used') {
        return [int]$Matches[1]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

function Probe-Codex {
    param([Parameter(Mandatory = $true)][array]$Agents)

    $agent = Find-IdleAgent -Kind 'codex' -Agents $Agents
    if (-not $agent) {
        Write-Warning "codex: no idle/done candidate agent found (excluding w8:p2, w5:p1); skipping this run."
        return $null
    }

    $paneId = $agent.pane_id
    Write-Host ("codex: probing pane " + $paneId)

    Invoke-HerdrRaw -CmdArgs @('pane', 'send-text', $paneId, '/status') | Out-Null
    Invoke-HerdrRaw -CmdArgs @('pane', 'send-keys', $paneId, 'enter') | Out-Null
    Start-Sleep -Seconds 5

    $out = Invoke-HerdrRaw -CmdArgs @('pane', 'read', $paneId, '--lines', '40')
    $text = $out -join "`n"

    Clear-PaneInput -PaneId $paneId

    $pct = Parse-CodexPercentUsed -Text $text
    if ($null -eq $pct) {
        Write-Warning ("codex: could not parse a percent-used figure from pane " + $paneId + " output; skipping.")
        return $null
    }

    Write-Host ("codex: parsed percent used = " + $pct)
    return $pct
}

function Probe-Copilot {
    param([Parameter(Mandatory = $true)][array]$Agents)

    $agent = Find-AnyAgent -Kind 'copilot' -Agents $Agents
    if (-not $agent) {
        Write-Warning "copilot: no candidate agent found (excluding w8:p2, w5:p1); skipping this run."
        return $null
    }

    $paneId = $agent.pane_id
    $agentName = $agent.name
    if (-not $agentName) { $agentName = $agent.agent_session.value }

    if ($agent.agent_status -eq 'working') {
        Write-Host ("copilot: " + $agentName + " is busy; polling up to 3 minutes for idle...")
        $deadline = (Get-Date).AddMinutes(3)
        $isIdle = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            $rawGet = Invoke-HerdrRaw -CmdArgs @('agent', 'get', $agentName)
            $infoText = $rawGet -join "`n"
            $info = $infoText | ConvertFrom-Json
            $status = $info.result.agent.agent_status
            if ($status -eq 'idle' -or $status -eq 'done') {
                $isIdle = $true
                break
            }
        }
        if (-not $isIdle) {
            Write-Warning ("copilot: " + $agentName + " stayed busy for 3 minutes; skipping this run.")
            return $null
        }
    }

    Write-Host ("copilot: probing pane " + $paneId + " (agent " + $agentName + ")")

    Invoke-HerdrRaw -CmdArgs @('pane', 'send-text', $paneId, '/usage') | Out-Null
    Invoke-HerdrRaw -CmdArgs @('pane', 'send-keys', $paneId, 'enter') | Out-Null
    Start-Sleep -Seconds 5

    $out = Invoke-HerdrRaw -CmdArgs @('pane', 'read', $paneId, '--lines', '40')
    $text = $out -join "`n"

    Clear-PaneInput -PaneId $paneId

    $pct = Parse-CopilotPercentUsed -Text $text
    if ($null -eq $pct) {
        Write-Warning ("copilot: could not parse a percent-used figure from pane " + $paneId + " output; skipping.")
        return $null
    }

    Write-Host ("copilot: parsed percent used = " + $pct)
    return $pct
}

# ---------------------------------------------------------------------------
# limits.json merge/write
# ---------------------------------------------------------------------------

function Update-LimitsFile {
    param([Parameter(Mandatory = $true)][hashtable]$Results)

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $LimitsPath) {
        try {
            $raw = Get-Content -LiteralPath $LimitsPath -Raw
            if ($raw -and $raw.Trim().Length -gt 0) {
                $obj = $raw | ConvertFrom-Json
                foreach ($prop in $obj.PSObject.Properties) {
                    $existing[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Warning ("limits.json: existing file could not be parsed; starting fresh. Error: " + $_.Exception.Message)
        }
    }

    foreach ($key in $Results.Keys) {
        if ($null -ne $Results[$key]) {
            $existing[$key] = $Results[$key]
        }
    }

    $json = $existing | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($LimitsPath, $json, [System.Text.Encoding]::ASCII)
}

# ---------------------------------------------------------------------------
# Cycle / loop driver
# ---------------------------------------------------------------------------

function Invoke-ProbeCycle {
    try {
        $agents = Get-HerdrAgentList

        $results = @{}
        $results['codex'] = Probe-Codex -Agents $agents
        $results['copilot'] = Probe-Copilot -Agents $agents

        Update-LimitsFile -Results $results
        Write-Host "Cycle complete."
    } catch {
        Write-Warning ("Probe cycle failed: " + $_.Exception.Message)
    }
}

if ($Loop) {
    while ($true) {
        Invoke-ProbeCycle
        Start-Sleep -Seconds 600
    }
} else {
    Invoke-ProbeCycle
}
