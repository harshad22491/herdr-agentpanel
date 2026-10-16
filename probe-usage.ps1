# Probe only explicitly configured dedicated agents. Never clean up user input.
[CmdletBinding()]
param([switch]$Loop, [string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
. (Join-Path $PSScriptRoot 'limits-common.ps1')
$Config = Get-AgentPanelConfig $StateRoot
$LimitsPath = Join-Path $StateRoot 'limits.json'

function Parse-CodexPercentUsed {
    param([string]$Text)
    if ($Text -match '(?im)^\s*5h limit:\s*(?:\[[^\]]*\]\s*)?(\d+)%\s*left') {
        $left = [int]$Matches[1]
        if ($left -le 100) { return (100 - $left) }
    }
    return $null
}
function Parse-CopilotPercentUsed {
    param([string]$Text)
    if ($Text -match '(?im)^\s*Plan\s+.*?(\d+)%\s*used') {
        $used = [int]$Matches[1]
        if ($used -le 100) { return $used }
    }
    return $null
}
function Get-ProbeAgent {
    param([string]$Kind)
    $name = [string]$Config.probeAgents[$Kind]
    if (-not $name) { return $null }
    $agent = (Get-HerdrJson @('agent','get',$name)).result.agent
    if (-not $agent -or $agent.name -ne $name -or $agent.agent -ne $Kind -or
        $agent.agent_status -notin @('idle','done') -or $Config.excludedPanes -contains $agent.pane_id) { return $null }
    return $agent
}
function Invoke-UsageProbe {
    param([ValidateSet('codex','copilot')][string]$Kind)
    $agent = Get-ProbeAgent $Kind
    if (-not $agent) { return $null }
    # Re-resolve immediately before submitting; never wait with an old pane ID.
    $fresh = Get-ProbeAgent $Kind
    if (-not $fresh -or $fresh.pane_id -ne $agent.pane_id -or
        $fresh.agent_session.value -ne $agent.agent_session.value) { return $null }
    $command = if ($Kind -eq 'codex') { '/status' } else { '/usage' }
    # Herdr validates the target and rejects a blocked agent before submitting.
    $null = Invoke-HerdrCommand @('agent','prompt',$fresh.name,$command)
    Start-Sleep -Seconds 5
    $after = (Get-HerdrJson @('agent','get',$fresh.name)).result.agent
    if ($after.pane_id -ne $fresh.pane_id -or $after.agent -ne $Kind -or
        $after.agent_session.value -ne $fresh.agent_session.value) { return $null }
    $text = (Invoke-HerdrCommand @('agent','read',$fresh.name,'--source','visible','--lines','40')) -join "`n"
    $pct = if ($Kind -eq 'codex') { Parse-CodexPercentUsed $text } else { Parse-CopilotPercentUsed $text }
    if ($null -eq $pct) { Write-Warning "$Kind quota could not be read; previous reading will age normally."; return $null }
    # Parse the reset hint on the same quota line, not another window's hint.
    $linePattern = if ($Kind -eq 'codex') { '^\s*5h limit:' } else { '^\s*Plan\s+' }
    $quotaLine = ($text -split "`n" | Where-Object { $_ -match $linePattern } | Select-Object -First 1)
    return @{pct=$pct; resets_at=(Get-ResetTime -Text $quotaLine)}
}
function Update-LimitsFile {
    param([hashtable]$Results)
    Invoke-StateLock $LimitsPath {
        $existing = @{}
        if (Test-Path -LiteralPath $LimitsPath) {
            # Invalid JSON is an error, never permission to overwrite other providers.
            $fileTime = (Get-Item -LiteralPath $LimitsPath).LastWriteTimeUtc
            $obj = Get-Content -LiteralPath $LimitsPath -Raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $obj.PSObject.Properties) {
                $value = $prop.Value
                if ($value -is [ValueType] -or $value -is [string]) {
                    # Preserve legacy observation age when another provider updates.
                    try { $value = New-LimitEntry -Pct ([double]$value) -Now $fileTime } catch { continue }
                }
                $existing[$prop.Name] = $value
            }
        }
        foreach ($name in $Results.Keys) {
            $reading = $Results[$name]
            if ($null -ne $reading) { $existing[$name] = New-LimitEntry -Pct $reading.pct -ResetsAt $reading.resets_at }
        }
        Write-AtomicJson $LimitsPath $existing
    }
}
function Invoke-ProbeCycle {
    $results = @{}
    foreach ($kind in @('codex','copilot')) {
        try { $reading = Invoke-UsageProbe $kind; if ($null -ne $reading) { $results[$kind]=$reading } }
        catch { Write-Warning "$kind probe failed; no input cleanup will be attempted." }
    }
    if ($results.Count) { Update-LimitsFile $results }
}
if ($env:HERDR_ENV -ne '1') { throw 'Run quota probing inside Herdr, after configuring dedicated probe agents.' }
do {
    $Config = Get-AgentPanelConfig $StateRoot
    Invoke-StateLock (Join-Path (Get-PanelSessionDirectory $StateRoot) 'probe.lock') { Invoke-ProbeCycle }
    if ($Loop) { Start-Sleep -Seconds 600 }
} while ($Loop)
