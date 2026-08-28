# Herdr agent catalogue - live-probing pane renderer.
# Groups all Herdr agent kinds + pane-only extras by how they can be called
# from this box. Re-probes every 60s. Launch: herdr pane run <pane> ...

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
# Forced unavailable overrides verified 2026-08-28.
$availabilityOverrides = @{
    mcode = '0 credits 2026-08-28'
    kimi  = 'never authorized 2026-08-28'
}

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
    $integrated = @()
    $status = herdr integration status
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $status) {
            if ($line -match '^([a-z]+):\s*current') { $integrated += $Matches[1] }
        }
        $lastIntegrated = $integrated
    } else {
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

    $limitPct = @{}
    $limitsPath = Join-Path $HOME '.herdr\limits.json'
    if (Test-Path -LiteralPath $limitsPath -PathType Leaf) {
        try {
            $limits = Get-Content -Raw -LiteralPath $limitsPath | ConvertFrom-Json
            foreach ($property in $limits.PSObject.Properties) {
                if ($null -ne $property.Value) {
                    $limitPct[$property.Name] = [double]$property.Value
                }
            }
        } catch {
            # Invalid or unreadable limits are unknown for this cycle.
            $limitPct = @{}
        }
    }

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
        $isAvailable[$name] = $false
    }

    $available = @($allModels | Where-Object { $isAvailable[$_] })
    $notAvailable = @($allModels | Where-Object { -not $isAvailable[$_] })

    $availableDisplay = {
        param($name)
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
        if (($null -eq $pct) -or ($pct -lt 75)) { return 'Green' }
        if ($pct -le 90) { return 'Yellow' }
        return 'Red'
    }
    $plainDisplay = { param($name) return $name }

    Clear-Host
    Write-Host ("AgentPanel  {0}  [h=hide]" -f (Get-Date -Format 'HH:mm')) -ForegroundColor Cyan
    Write-WrappedSection 'AVAILABLE' $available $availableDisplay $availableColor 'Gray'
    Write-WrappedSection 'NOT AVAILABLE' $notAvailable $plainDisplay { 'DarkGray' } 'Gray'
    Write-WrappedSection 'MANAGED' $managed $plainDisplay { 'Green' } 'Green'
    Write-WrappedSection 'DETECT-ONLY' $detect $plainDisplay { 'Yellow' } 'Yellow'
    Write-WrappedSection 'PANE-ONLY' $pOnly $plainDisplay { 'Yellow' } 'Yellow' '[send-text]'
    Write-WrappedSection 'NO CLI' $noCli $plainDisplay { 'DarkGray' } 'DarkGray'

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
                $flagFile = Join-Path $HOME '.herdr\panels-hidden'
                Set-Content -LiteralPath $flagFile -Value (Get-Date -Format 'u')
                exit
            }
        }

        Start-Sleep -Seconds 1
    }
}
