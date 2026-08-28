param([Parameter(Mandatory=$true)][string]$PaneId)

# Global state: track which resize direction grows the pane
$script:ResizeGrowsUp = $null

function Read-AgentStatus {
    $path = (Join-Path $env:USERPROFILE '.herdr\agents-status.json')
    if (-not (Test-Path $path)) {
        return @{}
    }

    try {
        $content = Get-Content -Path $path -Raw -ErrorAction Stop
        $json = ConvertFrom-Json -InputObject $content -ErrorAction Stop
        $agents = @{}

        # Check if new schema with "agents" property exists
        if ($json.PSObject.Properties.Name -contains "agents") {
            foreach ($prop in $json.agents.PSObject.Properties) {
                $value = $prop.Value
                # Handle both string and object formats
                if ($value -is [string]) {
                    $agents[$prop.Name] = @{ Desc = $value; Eta = $null }
                }
                else {
                    $agents[$prop.Name] = @{ Desc = $value.desc; Eta = $value.eta }
                }
            }
        }
        else {
            # Old flat format: treat each property as agent name -> description
            foreach ($prop in $json.PSObject.Properties) {
                $agents[$prop.Name] = @{ Desc = $prop.Value; Eta = $null }
            }
        }
        return $agents
    }
    catch {
        return @{}
    }
}

function Get-LiveAgents {
    try {
        $output = & herdr agent list 2>$null
        if ($LASTEXITCODE -ne 0) {
            return @()
        }

        $json = $output | ConvertFrom-Json -ErrorAction Stop
        $liveAgents = @()

        if ($json.result -and $json.result.agents) {
            foreach ($agent in $json.result.agents) {
                if ($agent.pane_id -eq 'w8:p2') {
                    continue
                }

                $displayName = if ($agent.name -and $agent.name.Length -gt 0) { $agent.name } else { $agent.agent }

                $liveAgents += @{
                    DisplayName = $displayName
                    Kind = $agent.agent
                    Status = $agent.agent_status
                    PaneId = $agent.pane_id
                }
            }
        }

        return $liveAgents
    }
    catch {
        return @()
    }
}

function Wrap-Text {
    param(
        [string]$Text,
        [int]$Width = 45
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @("")
    }

    $lines = @()
    $words = $Text -split '\s+' | Where-Object { $_.Length -gt 0 }
    if ($words.Count -eq 0) {
        return @("")
    }

    $currentLine = ""

    foreach ($word in $words) {
        if ($currentLine.Length -eq 0) {
            $currentLine = $word
        }
        elseif (($currentLine.Length + 1 + $word.Length) -le $Width) {
            $currentLine += " $word"
        }
        else {
            $lines += $currentLine
            $currentLine = $word
        }
    }

    if ($currentLine.Length -gt 0) {
        $lines += $currentLine
    }

    return $lines
}

function Get-PaneLayout {
    try {
        $output = & herdr pane layout --pane $PaneId 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $json = $output | ConvertFrom-Json -ErrorAction Stop
        return $json
    }
    catch {
        return $null
    }
}

function Resize-Pane {
    param(
        [int]$DesiredHeight,
        [int]$CurrentHeight,
        [int]$TotalHeight
    )

    $diff = [Math]::Abs($DesiredHeight - $CurrentHeight)
    if ($diff -lt 2) {
        return $true
    }

    # Determine resize direction
    $direction = if ($DesiredHeight -gt $CurrentHeight) { "up" } else { "down" }

    # If we haven't tested direction yet, test it on first resize
    if ($script:ResizeGrowsUp -eq $null) {
        & herdr pane resize --pane $PaneId --direction "up" --amount 0.02 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        Start-Sleep -Milliseconds 100
        $testLayout = Get-PaneLayout
        if ($testLayout -ne $null) {
            $testPane = $null
            foreach ($pane in $testLayout.result.layout.panes) {
                if ($pane.pane_id -eq $PaneId) {
                    $testPane = $pane
                    break
                }
            }

            if ($testPane -ne $null) {
                if ($testPane.rect.height -gt $CurrentHeight) {
                    $script:ResizeGrowsUp = $true
                }
                else {
                    $script:ResizeGrowsUp = $false
                }
            }
        }

        # Undo test resize
        & herdr pane resize --pane $PaneId --direction "down" --amount 0.02 2>$null
        Start-Sleep -Milliseconds 100
    }

    # Use determined direction (swap if needed based on test)
    if ($script:ResizeGrowsUp -eq $false) {
        if ($direction -eq "up") {
            $direction = "down"
        }
        else {
            $direction = "up"
        }
    }

    $fraction = $diff / $TotalHeight
    if ($fraction -gt 0.3) {
        $fraction = 0.3
    }

    & herdr pane resize --pane $PaneId --direction $direction --amount $fraction 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Render-Board {
    param(
        [hashtable]$ManualAgents
    )

    $lines = @()
    $timeStr = (Get-Date).ToString("HH:mm:ss")
    $lines += "TEAM ACTIVITY  $timeStr"

    $liveAgents = Get-LiveAgents

    if ($liveAgents.Count -gt 0) {
        foreach ($agent in $liveAgents) {
            $displayName = $agent.DisplayName
            $kind = $agent.Kind
            $status = $agent.Status

            $statusWord = switch ($status) {
                "working" { "busy on a task" }
                "idle" { "ready for a new task" }
                "blocked" { "stuck waiting on something" }
                "done" { "just finished a task" }
                default { $status }
            }

            $statusText = "$displayName - $statusWord"
            $effWidth = 45 - 2
            $wrapped = @(Wrap-Text -Text $statusText -Width $effWidth)

            for ($i = 0; $i -lt $wrapped.Count; $i++) {
                if ($i -eq 0) {
                    $lines += "- $($wrapped[$i])"
                }
                else {
                    $lines += "  $($wrapped[$i])"
                }
            }
        }
    }

    $liveDisplayNames = @()
    if ($liveAgents.Count -gt 0) {
        $liveDisplayNames = $liveAgents | ForEach-Object { $_.DisplayName }
    }

    if ($ManualAgents.Count -gt 0) {
        $sortedNames = $ManualAgents.Keys | Sort-Object
        foreach ($name in $sortedNames) {
            if ($liveDisplayNames -contains $name) {
                continue
            }

            $agentData = $ManualAgents[$name]
            # Handle both new format (object with Desc/Eta) and legacy string format
            if ($agentData -is [string]) {
                $desc = $agentData
                $eta = $null
            }
            else {
                $desc = $agentData.Desc
                $eta = $agentData.Eta
            }
            $effWidth = 45 - ($name.Length + 4)
            if ($effWidth -lt 20) { $effWidth = 20 }
            $fullDesc = $desc
            if ($eta) { $fullDesc = "$desc (should take $eta)" }
            $wrapped = @(Wrap-Text -Text $fullDesc -Width $effWidth)

            for ($i = 0; $i -lt $wrapped.Count; $i++) {
                if ($i -eq 0) {
                    $lines += "- $name`: $($wrapped[$i])"
                }
                else {
                    $lines += "  $($wrapped[$i])"
                }
            }
        }
    }

    # Render "next" task if present in JSON
    $nextPath = (Join-Path $env:USERPROFILE '.herdr\agents-status.json')
    if (Test-Path $nextPath) {
        try {
            $content = Get-Content -Path $nextPath -Raw -ErrorAction Stop
            $json = ConvertFrom-Json -InputObject $content -ErrorAction Stop

            # Check if "next" property exists and has a task
            if ($json.PSObject.Properties.Name -contains "next" -and $json.next -and $json.next.task) {
                $lines += "----"
                $nextTask = $json.next.task
                $nextAgent = $json.next.agent
                $nextEta = $json.next.eta

                # Wrap the NEXT line
                $nextTaskWrapped = @(Wrap-Text -Text "Up next: $nextTask" -Width 45)
                for ($i = 0; $i -lt $nextTaskWrapped.Count; $i++) {
                    $lines += $nextTaskWrapped[$i]
                }

                # Render agent and ETA on next line
                if ($nextAgent) {
                    if ($nextEta) {
                        $agentLineWrapped = @(Wrap-Text -Text "$nextAgent will handle it, expected in $nextEta" -Width 43)
                        foreach ($al in $agentLineWrapped) { $lines += "  $al" }
                    }
                    else {
                        $lines += "  -> $nextAgent"
                    }
                }
            }
        }
        catch {
            # Silently ignore JSON read errors
        }
    }

    if ($liveAgents.Count -eq 0 -and $ManualAgents.Count -eq 0) {
        $lines += "All quiet - no agents working."
    }

    $flagFile = Join-Path $HOME '.herdr\panels-hidden'
    if (Test-Path -LiteralPath $flagFile -PathType Leaf) {
        $lines += "Panels hidden - press h here to show"
    }

    Clear-Host

    # Render with colors
    Write-Host $lines[0] -ForegroundColor Cyan

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $colonPos = $line.IndexOf(":")
        if ($colonPos -gt 0) {
            $colorPart = $line.Substring(0, $colonPos)
            $restPart = $line.Substring($colonPos)
            Write-Host $colorPart -ForegroundColor Green -NoNewline
            Write-Host $restPart
        }
        else {
            Write-Host $line
        }
    }

    return $lines.Count
}

# Main loop
while ($true) {
    try {
        $agents = Read-AgentStatus
        $lineCount = Render-Board -ManualAgents $agents
        # Fixed split: the board always holds half the column (user preference),
        # panel above gets the other half.
        $desiredHeight = 14

        $layout = Get-PaneLayout
        if ($layout -ne $null) {
            $paneInfo = $null
            $panes = $layout.result.layout.panes
            foreach ($pane in $panes) {
                if ($pane.pane_id -eq $PaneId) {
                    $paneInfo = $pane
                    break
                }
            }

            if ($paneInfo -ne $null) {
                $currentHeight = $paneInfo.rect.height
                $totalHeight = $layout.result.layout.area.height
                $desiredHeight = [Math]::Floor($totalHeight / 2)

                $heightDiff = [Math]::Abs($desiredHeight - $currentHeight)
                if ($heightDiff -ge 2) {
                    Resize-Pane -DesiredHeight $desiredHeight -CurrentHeight $currentHeight -TotalHeight $totalHeight
                }
            }
        }
    }
    catch {
        # Continue on any error
    }

    for ($i = 0; $i -lt 5; $i++) {
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
                if (Test-Path -LiteralPath $flagFile -PathType Leaf) {
                    Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
                }
                else {
                    Set-Content -LiteralPath $flagFile -Value (Get-Date -Format 'u')
                }
            }
        }

        Start-Sleep -Seconds 1
    }
}
