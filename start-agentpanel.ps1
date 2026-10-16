param([string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'), [switch]$Show, [switch]$Automatic)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
if ($env:HERDR_ENV -ne '1') { throw 'Open Herdr first, then run this command in one of its PowerShell panes.' }
$sessionDir = Get-PanelSessionDirectory $StateRoot
$disabledPath = Join-Path $sessionDir 'disabled'
if ($Automatic -and (Test-Path -LiteralPath $disabledPath)) { return }
if (-not $Automatic -and (Test-Path -LiteralPath $disabledPath)) { Remove-Item -LiteralPath $disabledPath -Force }
if ($Show) { Set-PanelsHidden $StateRoot $false }
$watcherName = 'Local\AgentPanel-Watcher-' + (Get-StateKey $sessionDir.ToLowerInvariant())
Invoke-StateLock (Join-Path $sessionDir 'startup.lock') {
    $mutex = New-Object Threading.Mutex($false,$watcherName)
    $free = $false
    try {
        try { $free=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $free=$true }
        if (-not $free) { Write-Host 'AgentPanel is already running.'; return }
    } finally { if ($free) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    $watcher = Join-Path $PSScriptRoot 'ensure-agentpanel.ps1'
    $command = "& '" + $watcher.Replace("'","''") + "' -StateRoot '" + $StateRoot.Replace("'","''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $child = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru
    for ($i=0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        if ($child.HasExited) { throw 'Watcher exited during startup. Run ensure-agentpanel.ps1 in a Herdr pane to see the error.' }
        $check = New-Object Threading.Mutex($false,$watcherName)
        $free = $false
        try {
            try { $free=$check.WaitOne(0) } catch [Threading.AbandonedMutexException] { $free=$true }
            if (-not $free) { Write-Host 'AgentPanel started. Panels will appear shortly.'; return }
        } finally { if ($free) { $check.ReleaseMutex() }; $check.Dispose() }
    }
    throw 'Watcher has not confirmed startup. Check watcher-health.json before retrying.'
}
