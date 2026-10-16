# Herdr agent catalogue - live-probing pane renderer.
# Groups all Herdr agent kinds + pane-only extras by how they can be called
# from this box. Re-probes every 60s. Launch: herdr pane run <pane> ...

param([string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'), [string]$OwnerToken)
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
. (Join-Path $PSScriptRoot 'limits-common.ps1')
$Config = Get-AgentPanelConfig $StateRoot
$LimitTtlHours = $Config.limitTtlHours

$kinds = @('pi','claude','codex','gemini','cursor','devin','agy','cline','omp',
           'mastracode','opencode','copilot','kimi','kiro','droid','amp','grok',
           'hermes','kilo','qodercli','maki')
# Herdr doesn't know these; drive via pane send-text + send-keys enter.
$paneOnly = @('qwen','mcode','ollama')
# Kind name != probe executable: bare `cursor` is only the IDE launcher.
$exeMap = @{ cursor = 'cursor-agent' }
$allModels = $kinds + $paneOnly

$credentialPaths = @{
    claude   = (Join-Path $HOME '.claude\.credentials.json')
    codex    = (Join-Path $HOME '.codex\auth.json')
    copilot  = (Join-Path $HOME '.copilot\config.json')
    opencode = (Join-Path $HOME '.config\opencode\opencode.jsonc')
    qwen     = (Join-Path $HOME '.qwen\settings.json')
}
$unvalidatedPaths = @{
    grok     = (Join-Path $HOME '.grok\auth.json')
    pi       = (Join-Path $HOME '.pi\agent')
    omp      = (Join-Path $HOME '.omp\agent')
    qodercli = (Join-Path $HOME '.qoder\settings.json')
    kilo     = (Join-Path $HOME '.config\kilo')
    droid    = (Join-Path $HOME '.factory')
}
$authUnvalidated = @('grok','pi','omp','qodercli','kilo','droid')
# Machine-specific overrides are optional, explicit configuration.
$availabilityOverrides = $Config.availability

function Write-WrappedSection {
    param(
        [string]$Label,
        [array]$Names,
        [scriptblock]$DisplayForName,
        [scriptblock]$ColorForName,
        [string]$HeaderColor = 'Gray',
        [string]$Suffix = ''
    )

    $prefix = '{0}({1}):' -f $Label, $Names.Count
    Write-Host -NoNewline $prefix -ForegroundColor $HeaderColor
    $lineLength = $prefix.Length

    foreach ($name in $Names) {
        $display = [string](& $DisplayForName $name)
        if (($lineLength + 1 + $display.Length) -gt 45) {
            Write-Host ''
            Write-Host -NoNewline '  '
            $lineLength = 2
        } else {
            Write-Host -NoNewline ' '
            $lineLength++
        }
        Write-Host -NoNewline $display -ForegroundColor (& $ColorForName $name)
        $lineLength += $display.Length
    }

    if ($Suffix) {
        if (($lineLength + 1 + $Suffix.Length) -gt 45) {
            Write-Host ''
            Write-Host -NoNewline '  '
        } else {
            Write-Host -NoNewline ' '
        }
        Write-Host -NoNewline $Suffix -ForegroundColor $HeaderColor
    }
    Write-Host ''
}

$lastIntegrated = @()
while ($true) {
    try {
    Write-PanelHeartbeat $StateRoot $OwnerToken 'catalogue'
    $integrated = @()
    try {
        $status = Invoke-HerdrCommand @('integration','status')
        foreach ($line in $status) {
            if ($line -match '^([a-z]+):\s*current') { $integrated += $Matches[1] }
        }
        $lastIntegrated = $integrated
    } catch {
        # herdr call failed; keep last known good instead of demoting everything
        $integrated = $lastIntegrated
    }

    $haveCli = @{}
    foreach ($k in $kinds + $paneOnly) {
        $exe = if ($exeMap.ContainsKey($k)) { $exeMap[$k] } else { $k }
        $haveCli[$k] = [bool](Get-Command $exe -ErrorAction SilentlyContinue)
    }

    $managed = @($kinds | Where-Object { ($integrated -contains $_) -and $haveCli[$_] })
    $detect  = @($kinds | Where-Object { ($integrated -notcontains $_) -and $haveCli[$_] })
    $noCli   = @($kinds | Where-Object { -not $haveCli[$_] })
    $pOnly   = @($paneOnly | Where-Object { $haveCli[$_] })

    # Only readings still inside their provider's quota window (or younger than
    # the TTL) count; anything expired is unknown again, never a stale red.
    $limitsPath = Join-Path $StateRoot 'limits.json'
    $limitPct = Read-FreshLimits -Path $limitsPath
    $staleLimits = @()
    try {
        $savedLimits = Get-Content -LiteralPath $limitsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $staleLimits = @($savedLimits.PSObject.Properties.Name | Where-Object { -not $limitPct.ContainsKey($_) })
    } catch { }

    $isAvailable = @{}
    foreach ($name in $allModels) { $isAvailable[$name] = $false }

    foreach ($name in $credentialPaths.Keys) {
        $isAvailable[$name] = Test-Path -LiteralPath $credentialPaths[$name] -PathType Leaf
    }
    foreach ($name in $unvalidatedPaths.Keys) {
        $isAvailable[$name] = Test-Path -LiteralPath $unvalidatedPaths[$name]
    }

    $geminiStatePath = Join-Path $HOME '.gemini\state.json'
    if (Test-Path -LiteralPath $geminiStatePath -PathType Leaf) {
        try {
            $geminiState = Get-Content -Raw -LiteralPath $geminiStatePath | ConvertFrom-Json
            $isAvailable['gemini'] = ($null -ne $geminiState.activeAccount)
        } catch {
            $isAvailable['gemini'] = $false
        }
    }

    $ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollamaCommand) {
        & $ollamaCommand.Source list *> $null
        $isAvailable['ollama'] = ($LASTEXITCODE -eq 0)
    }

    foreach ($name in $availabilityOverrides.Keys) {
        if ($availabilityOverrides[$name] -eq 'unavailable') { $isAvailable[$name] = $false }
        elseif ($availabilityOverrides[$name] -eq 'authenticated') { $isAvailable[$name] = $true }
    }

    # Configuration left behind after uninstalling a CLI cannot make it usable.
    foreach ($name in $allModels) { $isAvailable[$name] = $isAvailable[$name] -and $haveCli[$name] }

    $readiness = @{}
    foreach ($name in $allModels) {
        $readiness[$name] = Get-AgentReadiness -HasCli $haveCli[$name] -HasConfig $isAvailable[$name] -Override $availabilityOverrides[$name] -LocalServiceReady ($name -eq 'ollama' -and $isAvailable[$name])
    }
    $available = @($allModels | Where-Object { $readiness[$_] -eq 'available' })
    $configured = @($allModels | Where-Object { $readiness[$_] -eq 'configured' })
    $notAvailable = @($allModels | Where-Object { $readiness[$_] -eq 'unavailable' })

    $availableDisplay = {
        param($name)
        if ($staleLimits -contains $name) { return $name + '~' }
        $pct = if ($limitPct.ContainsKey($name)) { $limitPct[$name] } else { $null }
        $needsQuestion = ($name -ne 'ollama') -and
                         (($null -eq $pct) -or ($authUnvalidated -contains $name))
        if ($needsQuestion) { return $name + '?' }
        return $name
    }
    $availableColor = {
        param($name)
        if ($name -eq 'ollama') { return 'Green' }
        $pct = if ($limitPct.ContainsKey($name)) { $limitPct[$name] } else { $null }
        if ($null -eq $pct) { return 'DarkGray' }
        if ($pct -lt 75) { return 'Green' }
        if ($pct -le 90) { return 'Yellow' }
        return 'Red'
    }
    $plainDisplay = { param($name) return $name }

    Clear-Host
    Write-Host ("AgentPanel  {0}  [h=hide]" -f (Get-Date -Format 'HH:mm')) -ForegroundColor Cyan
    Write-WrappedSection 'AVAILABLE' $available $availableDisplay $availableColor 'Gray'
    Write-WrappedSection 'CONFIGURED' $configured $availableDisplay $availableColor 'Gray'
    Write-WrappedSection 'NOT AVAILABLE' $notAvailable $plainDisplay { 'DarkGray' } 'Gray'
    Write-WrappedSection 'MANAGED' $managed $plainDisplay { 'Green' } 'Green'
    Write-WrappedSection 'DETECT-ONLY' $detect $plainDisplay { 'Yellow' } 'Yellow'
    Write-WrappedSection 'PANE-ONLY' $pOnly $plainDisplay { 'Yellow' } 'Yellow' '[send-text]'
    Write-WrappedSection 'NO CLI' $noCli $plainDisplay { 'DarkGray' } 'DarkGray'
    Write-Host '? quota unknown; ~ quota stale' -ForegroundColor DarkGray
    Write-Host 'CONFIGURED: sign-in not verified' -ForegroundColor DarkGray

    for ($i = 0; $i -lt 60; $i++) {
        $keyAvailable = $false
        try {
            $keyAvailable = [console]::KeyAvailable
        }
        catch {
            $keyAvailable = $false
        }

        if ($keyAvailable) {
            $key = [console]::ReadKey($true)
            if ($key.KeyChar -eq 'h' -or $key.KeyChar -eq 'H') {
                Set-PanelsHidden $StateRoot $true
            }
        }

        Start-Sleep -Seconds 1
        if (($i % 10) -eq 0) { Write-PanelHeartbeat $StateRoot $OwnerToken 'catalogue' }
    }
    } catch {
        Clear-Host
        Write-Host 'AgentPanel - refresh unavailable' -ForegroundColor Yellow
        Write-Host 'Herdr or panel state unavailable; retrying in 10s.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}
