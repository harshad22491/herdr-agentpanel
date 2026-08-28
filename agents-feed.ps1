param([Parameter(Mandatory=$true)][string]$PaneId)

# Global state: track which resize direction grows the pane
$script:ResizeGrowsUp = $null

function Read-AgentStatus {
    $path = Join-Path $env:USERPROFILE '.herdr\agents-status.json'
    if (-not (Test-Path $path)) {
        return @{}
    }

    try {
        $content = Get-Content -Path $path -Raw -ErrorAction Stop
        $json = ConvertFrom-Json -InputObject $content -ErrorAction Stop
        $agents = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $agents[$prop.Name] = $prop.Value
        }
        return $agents
    }
    catch {
        return @{}
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
        [hashtable]$Agents
    )

    $lines = @()
    $timeStr = (Get-Date).ToString("HH:mm:ss")
    $lines += "TEAM ACTIVITY  $timeStr"

    if ($Agents.Count -eq 0) {
        $lines += "All quiet - no agents working."
    }
    else {
        $sortedNames = $Agents.Keys | Sort-Object
        foreach ($name in $sortedNames) {
            $desc = $Agents[$name]
            $effWidth = 45 - ($name.Length + 4)
            if ($effWidth -lt 20) { $effWidth = 20 }
            $wrapped = Wrap-Text -Text $desc -Width $effWidth

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
        $lineCount = Render-Board -Agents $agents
        $desiredHeight = $lineCount + 3
        if ($desiredHeight -lt 4) {
            $desiredHeight = 4
        }
        if ($desiredHeight -gt 20) {
            $desiredHeight = 20
        }

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

    Start-Sleep -Seconds 5
}
