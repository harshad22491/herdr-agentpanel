param([string]$PaneId, [string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'), [string]$OwnerToken)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
. (Join-Path $PSScriptRoot 'task-common.ps1')
$Config = Get-AgentPanelConfig $StateRoot
$script:Page = 0
function Read-AgentStatus {
    $path = Join-Path $StateRoot 'agents-status.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{agents=@{}; next=$null} }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        $agents = @{}
        $source = if ($json.PSObject.Properties.Name -contains 'agents') { $json.agents } else { $json }
        foreach ($prop in $source.PSObject.Properties) {
            if ($prop.Name -eq 'next') { continue }
            $value = $prop.Value
            if ($value -is [string]) { $agents[$prop.Name] = @{desc=$value; eta=$null} }
            else { $agents[$prop.Name] = @{desc=$value.desc; eta=$value.eta} }
        }
        return @{agents=$agents; next=$json.next}
    } catch { return @{agents=@{}; next=$null; error='Task descriptions could not be read.'} }
}
function Get-LiveAgents {
    return @((Get-HerdrJson @('agent','list')).result.agents | Where-Object { $_ -and $Config.excludedPanes -notcontains $_.pane_id })
}
function Wrap-Text {
    param([string]$Text, [ValidateRange(1,1000)][int]$Width=45)
    $Text = ($Text -replace '[\x00-\x1f\x7f]', ' ').Trim()
    if (-not $Text) { return '' }
    while ($Text.Length -gt $Width) {
        $cut = $Text.LastIndexOf(' ', $Width)
        if ($cut -le 0) { $cut=$Width }
        $Text.Substring(0,$cut)
        $Text=$Text.Substring($cut).TrimStart()
    }
    if ($Text) { $Text }
}
function Get-StatusWords {
    param([string]$Status)
    switch ($Status) {
        working { 'working' }
        idle { 'ready' }
        blocked { 'needs your attention' }
        done { 'finished' }
        failed { 'failed' }
        stale { 'update overdue' }
        default { 'status unknown' }
    }
}
function Get-BoardLines {
    param([hashtable]$Manual, [AllowEmptyCollection()][array]$Live=@(), [AllowEmptyCollection()][array]$Tasks=@(), [int]$Width=45)
    $rows = @()
    $matched = @{}
    foreach ($agent in $Live) {
        $name = if ($agent.name) { $agent.name } else { "$($agent.agent) [$($agent.pane_id)]" }
        if (@($Tasks | Where-Object { $_.pane_id -and $_.pane_id -eq $agent.pane_id }).Count) { continue }
        $row = "$name - $(Get-StatusWords $agent.agent_status)"
        if ($Manual.agents.ContainsKey($name)) {
            $entry = $Manual.agents[$name]
            $row += ": $($entry.desc)"
            if ($entry.eta) { $row += " (about $($entry.eta))" }
            $matched[$name]=$true
        }
        $rows += $row
    }
    foreach ($name in @($Manual.agents.Keys | Sort-Object)) {
        if ($matched.ContainsKey($name)) { continue }
        $entry = $Manual.agents[$name]
        $row = $name + ': ' + $entry.desc
        if ($entry.eta) { $row += " (about $($entry.eta))" }
        $rows += $row
    }
    foreach ($task in @($Tasks | Sort-Object task_id,name)) {
        $row = "$($task.name) [$($task.task_id)] - $(Get-StatusWords $task.status): $($task.desc)"
        if ($task.eta) { $row += " (about $($task.eta))" }
        $rows += $row
        $detail = "$($task.provider) / $($task.model)"
        if ($null -ne $task.cost_usd) { $detail += ' | USD ' + ([double]$task.cost_usd).ToString('0.0000',[Globalization.CultureInfo]::InvariantCulture) }
        else { $detail += ' | cost unknown' }
        if ($null -ne $task.total_tokens) { $detail += " | $($task.total_tokens) tokens" }
        if ($task.parent_agent_id) { $detail += " | parent: $($task.parent_agent_id)" }
        $rows += $detail
    }
    if ($Manual.next.task) {
        $next = "Up next: $($Manual.next.task)"
        if ($Manual.next.agent) { $next += " - $($Manual.next.agent)" }
        if ($Manual.next.eta) { $next += " (about $($Manual.next.eta))" }
        $rows += $next
    }
    if ($Manual.error) { $rows += $Manual.error }
    if (-not $rows.Count) { $rows += 'All quiet - no agents reported.' }
    foreach ($row in $rows) { Wrap-Text $row $Width }
}
while ($true) {
    try {
        Write-PanelHeartbeat $StateRoot $OwnerToken 'board'
        $manual = Read-AgentStatus
        $live = @()
        try { $live = @(Get-LiveAgents) } catch { $manual.error='Herdr status unavailable; try again shortly.' }
        $tasks = @(Read-AgentTasks $StateRoot $Config)
        $width=45; $height=14
        try {
            $target = if ($env:HERDR_ENV -eq '1') { @('--current') } else { @('--pane',$PaneId) }
            $layout = (Get-HerdrJson (@('pane','layout') + $target)).result.layout
            $currentId = if ($env:HERDR_ENV -eq '1') { (Get-HerdrJson @('pane','current','--current')).result.pane.pane_id } else { $PaneId }
            $pane = $layout.panes | Where-Object { $_.pane_id -eq $currentId } | Select-Object -First 1
            if ($pane) { $width=[Math]::Max(8,$pane.rect.width-2); $height=[Math]::Max(4,$pane.rect.height) }
        } catch { }
        $lines = @(Get-BoardLines $manual $live $tasks $width)
        $pageSize=[Math]::Max(1,$height-3)
        $pageCount=[Math]::Max(1,[Math]::Ceiling($lines.Count/[double]$pageSize))
        $pageIndex=$script:Page % $pageCount
        Clear-Host
        Write-Host ("TEAM ACTIVITY  " + [DateTime]::Now.ToString('HH:mm:ss')) -ForegroundColor Cyan
        $lines | Select-Object -Skip ($pageIndex*$pageSize) -First $pageSize | ForEach-Object { Write-Host $_ }
        $hidden = Test-Path -LiteralPath (Join-Path (Get-PanelSessionDirectory $StateRoot) 'panels-hidden')
        $toggle = if ($hidden) { 'h: show panels' } else { 'h: hide panels' }
        Write-Host "$toggle | page $($pageIndex+1)/$pageCount" -ForegroundColor DarkGray
        $script:Page++
    } catch { Write-Warning 'Activity board could not refresh; retrying.' }
    for ($i=0; $i -lt 5; $i++) {
        if (Test-PanelKey) {
            $hidden = Test-Path -LiteralPath (Join-Path (Get-PanelSessionDirectory $StateRoot) 'panels-hidden')
            Set-PanelsHidden $StateRoot (-not $hidden)
        }
        Start-Sleep -Seconds 1
    }
}
