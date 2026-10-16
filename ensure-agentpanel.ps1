param([string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'), [switch]$Once)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
$Config = Get-AgentPanelConfig $StateRoot
$AgentPanelScriptDirectory = $PSScriptRoot
$SessionDir = Get-PanelSessionDirectory $StateRoot
$LedgerFile = Join-Path $SessionDir 'panel-panes.json'
$FlagFile = Join-Path $SessionDir 'panels-hidden'
$script:Ledger = @()
$script:Creates = 0

function Get-PanelLedger {
    if (-not (Test-Path -LiteralPath $LedgerFile)) { return @() }
    $data = Get-Content -LiteralPath $LedgerFile -Raw | ConvertFrom-Json
    if ($data.version -ne 2) { throw 'Unknown ownership ledger version; refusing to modify panes.' }
    return @($data.panes)
}

function Set-PanelLedger {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Ledger)
    Write-AtomicJson -Path $LedgerFile -Value @{version=2; panes=@($Ledger)}
}

function Get-AllPanes {
    $panes = @()
    foreach ($workspace in (Get-HerdrJson @('workspace','list')).result.workspaces) {
        $panes += @((Get-HerdrJson @('pane','list','--workspace',$workspace.workspace_id)).result.panes)
    }
    return @($panes | Where-Object { $_ -and $_.pane_id })
}

function Test-IsAgentPane {
    param($Pane)
    return [bool]$Pane.agent
}

function Get-OwnedPane {
    param($Entry, [array]$Panes)
    # A label is a locator, never sufficient permission to close a pane.
    return @($Panes | Where-Object { $_.label -eq ('agentpanel:' + $Entry.token) }) | Select-Object -First 1
}

function Test-PanelHealthy {
    param($Entry)
    $path = Join-Path $SessionDir ($Entry.token + '.json')
    if (Test-Path -LiteralPath $path) {
        try {
            $beat = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $age = ([DateTime]::UtcNow - [DateTime]::Parse($beat.at).ToUniversalTime()).TotalSeconds
            $process = Get-Process -Id $beat.process_id -ErrorAction Stop
            return ($beat.token -eq $Entry.token -and $beat.role -eq $Entry.role -and
                $process.StartTime.ToUniversalTime().ToString('o') -eq $beat.process_started -and
                $age -ge 0 -and $age -le $Config.heartbeatSeconds)
        } catch { return $false }
    }
    return (([DateTime]::UtcNow - [DateTime]::Parse($Entry.created_at).ToUniversalTime()).TotalSeconds -lt $Config.creationGraceSeconds)
}

function Test-CanCloseOwnedPane {
    param($Entry)
    try {
        $pane = (Get-HerdrJson @('pane','get',$Entry.pane_id)).result.pane
        if (-not $pane -or $pane.label -ne ('agentpanel:' + $Entry.token) -or (Test-IsAgentPane $pane)) { return $false }
        if ($Config.excludedPanes -contains $pane.pane_id) { return $false }
        $info = (Get-HerdrJson @('pane','process-info','--pane',$pane.pane_id)).result.process_info
        if (-not $Entry.shell_pid -or $info.shell_pid -ne $Entry.shell_pid) { return $false }
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $shell = $processes | Where-Object { $_.ProcessId -eq $Entry.shell_pid } | Select-Object -First 1
        if (-not $shell -or $shell.CreationDate.ToUniversalTime().ToString('o') -ne $Entry.shell_started) { return $false }
        $children = @($processes | Where-Object { $_.ParentProcessId -eq $Entry.shell_pid })
        foreach ($child in $children) {
            # Only the exact renderer command launched by us may own the shell.
            # All its descendants (e.g. a hung ollama probe) belong to that renderer.
            if ($child.Name -ne 'powershell.exe' -or $child.CommandLine -notmatch '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)') { return $false }
            $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
            if ($decoded -ne $Entry.command_text) { return $false }
        }
        return $true
    } catch { return $false }
}

function Close-OwnedPane {
    param($Entry)
    if (-not (Test-CanCloseOwnedPane $Entry)) {
        Write-Warning "Leaving pane $($Entry.pane_id): ownership or current process could not be verified."
        return $false
    }
    $null = Invoke-HerdrCommand @('pane','close',$Entry.pane_id)
    $script:Ledger = @($script:Ledger | Where-Object { $_.token -ne $Entry.token })
    Set-PanelLedger $script:Ledger
    $beatPath = Join-Path $SessionDir ($Entry.token + '.json')
    if (Test-Path -LiteralPath $beatPath) { Remove-Item -LiteralPath $beatPath -Force }
    return $true
}

function Set-PanelWidth {
    param([string]$PaneId)
    try {
        $layout = (Get-HerdrJson @('pane','layout','--pane',$PaneId)).result.layout
        $panel = @($layout.panes | Where-Object { $_.pane_id -eq $PaneId })[0]
        if (-not $panel) { return }
        $width = [int]$panel.rect.width
        if ([Math]::Abs($width - $Config.columns) -lt 2) { return }
        $split = @($layout.splits | Where-Object {
            $_.direction -eq 'right' -and $_.rect.x -le $panel.rect.x -and
            ($_.rect.x + $_.rect.width) -ge ($panel.rect.x + $width) -and
            $_.rect.y -le $panel.rect.y -and ($_.rect.y + $_.rect.height) -ge ($panel.rect.y + $panel.rect.height)
        } | Sort-Object { $_.rect.width })[0]
        if (-not $split -or $panel.rect.x -le $split.rect.x -or $split.rect.width -lt ($Config.columns + $Config.minWorkColumns)) { return }
        $delta = ($width - $Config.columns) / [double]$split.rect.width
        $direction = if ($delta -gt 0) { 'right' } else { 'left' }
        $amount = [Math]::Min(0.3,[Math]::Abs($delta)).ToString([Globalization.CultureInfo]::InvariantCulture)
        $null = Invoke-HerdrCommand @('pane','resize','--pane',$PaneId,'--direction',$direction,'--amount',$amount)
    } catch { Write-Warning "Cannot resize panel $PaneId this cycle." }
}

function New-OwnedPanel {
    param($Target, [ValidateSet('catalogue','board')][string]$Role, [string]$Direction='right', [double]$Ratio=0.5)
    if ($script:Creates -ge $Config.maxCreates) { return $null }
    $file = if ($Role -eq 'board') { 'agents-feed.ps1' } else { 'agents-catalogue.ps1' }
    $scriptPath = Join-Path $AgentPanelScriptDirectory $file
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing renderer $file." }
    $response = Get-HerdrJson @('pane','split',$Target.pane_id,'--direction',$Direction,
        '--ratio',$Ratio.ToString([Globalization.CultureInfo]::InvariantCulture),'--cwd',$env:USERPROFILE,'--no-focus')
    $newId = $response.result.pane.pane_id
    if (-not $newId) { throw 'Split returned no pane ID.' }
    # Count the split immediately, including failed launches and board creation.
    $script:Creates++
    $token = [Guid]::NewGuid().ToString('N')
    $command = New-PanelLaunchCommand $scriptPath $StateRoot $token
    $encoded = ($command -split ' ')[-1]
    $entry = [pscustomobject]@{ pane_id=$newId; tab_id=$Target.tab_id; role=$Role; token=$token;
        created_at=[DateTime]::UtcNow.ToString('o'); shell_pid=$null; shell_started=$null;
        command_text=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)) }
    $script:Ledger += $entry
    # Persist before any further operation. An interrupted launch reserves its slot.
    Set-PanelLedger $script:Ledger
    try {
        $entry.shell_pid = (Get-HerdrJson @('pane','process-info','--pane',$newId)).result.process_info.shell_pid
        if (-not $entry.shell_pid) { throw 'Cannot identify new pane shell.' }
        $shell = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $entry.shell_pid) -ErrorAction Stop
        $entry.shell_started = $shell.CreationDate.ToUniversalTime().ToString('o')
        $null = Invoke-HerdrCommand @('pane','rename',$newId,('agentpanel:' + $token))
        Set-PanelLedger $script:Ledger
        $null = Invoke-HerdrCommand @('pane','run',$newId,$command)
        return $entry
    } catch {
        Write-Warning "Panel launch failed in $newId; attempting verified cleanup."
        $null = Close-OwnedPane $entry
        return $null
    }
}

function Invoke-PanelIteration {
    $script:Creates = 0
    $panes = @(Get-AllPanes)
    $hidden = Test-Path -LiteralPath $FlagFile
    foreach ($entry in @($script:Ledger)) {
        $pane = Get-OwnedPane $entry $panes
        if (-not $pane) {
            # An unlabelled failed creation remains reserved while its pane exists.
            $pane = $panes | Where-Object { $_.pane_id -eq $entry.pane_id } | Select-Object -First 1
            if ($pane) { Write-Warning "Unverified pane $($entry.pane_id) left for manual inspection."; continue }
            $script:Ledger = @($script:Ledger | Where-Object { $_.token -ne $entry.token })
            continue
        }
        $entry.pane_id = $pane.pane_id
        $entry.tab_id = $pane.tab_id
        if (($hidden -and $entry.role -eq 'catalogue') -or -not (Test-PanelHealthy $entry)) { $null = Close-OwnedPane $entry }
    }
    Set-PanelLedger $script:Ledger
    # Remove verified duplicates, but never adopt or close panes based on screen text.
    foreach ($group in @($script:Ledger | Group-Object { if ($_.role -eq 'board') { 'board' } else { $_.tab_id } })) {
        foreach ($extra in @($group.Group | Select-Object -Skip 1)) { $null = Close-OwnedPane $extra }
    }
    $panes = @(Get-AllPanes)
    if (-not $hidden) {
        foreach ($tab in @($panes | Group-Object tab_id)) {
            $existing = @($script:Ledger | Where-Object { $_.tab_id -eq $tab.Name -and $_.role -eq 'catalogue' })
            if ($existing.Count) {
                if (Test-CanCloseOwnedPane $existing[0]) { Set-PanelWidth $existing[0].pane_id }
                continue
            }
            if ($script:Creates -ge $Config.maxCreates) { break }
            $board = $script:Ledger | Where-Object { $_.tab_id -eq $tab.Name -and $_.role -eq 'board' } | Select-Object -First 1
            if ($board -and (Test-CanCloseOwnedPane $board)) {
                $target = $panes | Where-Object { $_.pane_id -eq $board.pane_id } | Select-Object -First 1
                $new = New-OwnedPanel $target 'catalogue' 'down' 0.5
                if ($new) { $null = Invoke-HerdrCommand @('pane','swap','--source-pane',$new.pane_id,'--target-pane',$board.pane_id) }
                continue
            }
            $layout = (Get-HerdrJson @('pane','layout','--pane',$tab.Group[0].pane_id)).result.layout
            $eligible = @($tab.Group | Where-Object { $Config.excludedPanes -notcontains $_.pane_id -and $_.agent_status -notin @('working','blocked') })
            $ids = @($eligible | ForEach-Object { $_.pane_id })
            $widest = $layout.panes | Where-Object { $ids -contains $_.pane_id } | Sort-Object { $_.rect.width } -Descending | Select-Object -First 1
            if (-not $widest -or $widest.rect.width -lt ($Config.columns + $Config.minWorkColumns + 1)) { continue }
            $target = $eligible | Where-Object { $_.pane_id -eq $widest.pane_id } | Select-Object -First 1
            $null = New-OwnedPanel $target 'catalogue' 'right' (1 - ($Config.columns / [double]$widest.rect.width))
        }
    }
    # A board is global within this session and remains the restore control.
    if (-not @($script:Ledger | Where-Object { $_.role -eq 'board' }).Count -and $script:Creates -lt $Config.maxCreates) {
        $panes = @(Get-AllPanes)
        $catalogue = $script:Ledger | Where-Object { $_.role -eq 'catalogue' } | Select-Object -First 1
        $target = $null
        if ($catalogue -and (Test-CanCloseOwnedPane $catalogue)) { $target = $panes | Where-Object { $_.pane_id -eq $catalogue.pane_id } | Select-Object -First 1 }
        if (-not $target) { $target = $panes | Where-Object { $Config.excludedPanes -notcontains $_.pane_id -and $_.agent_status -notin @('working','blocked') } | Select-Object -First 1 }
        if ($target) { $null = New-OwnedPanel $target 'board' 'down' 0.5 }
    }
    $message = "heartbeat $([DateTime]::Now.ToString('HH:mm:ss')) - hidden=$hidden, splits=$script:Creates, owned=$($script:Ledger.Count)"
    Write-Host $message
    Write-AtomicJson -Path (Join-Path $SessionDir 'watcher-health.json') -Value @{ at=[DateTime]::UtcNow.ToString('o'); message=$message }
}

if ($env:HERDR_ENV -ne '1') { throw 'Run the watcher from a Herdr pane.' }
[IO.Directory]::CreateDirectory($SessionDir) | Out-Null
$mutex = New-Object Threading.Mutex($false, ('Local\AgentPanel-Watcher-' + (Get-StateKey $SessionDir.ToLowerInvariant())))
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { Write-Host 'A watcher is already running for this session.'; return }
    $script:Ledger = @(Get-PanelLedger)
    do {
        if (Test-Path -LiteralPath (Join-Path $SessionDir 'disabled')) {
            foreach ($entry in @($script:Ledger)) { $null = Close-OwnedPane $entry }
            break
        }
        try { Invoke-PanelIteration }
        catch {
            Write-Warning $_.Exception.Message
            Write-AtomicJson -Path (Join-Path $SessionDir 'watcher-health.json') -Value @{ at=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message }
        }
        if (-not $Once) { Start-Sleep -Seconds $Config.pollSeconds }
    } while (-not $Once)
} finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
