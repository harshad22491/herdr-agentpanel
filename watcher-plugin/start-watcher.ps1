# Launcher invoked by the agentpanel-watcher herdr plugin on workspace.created
# and tab.focused (the latter fires in bursts, and is what revives the watcher
# after a session restore — restore/attach emit no workspace.created at all).
# Guards: atomic lock with stale-break + already-running check.
# The real watcher lives at %USERPROFILE%\.herdr\ensure-agentpanel.ps1 and runs
# in a visible herdr tab so its heartbeat stays observable.

$lockDir = Join-Path $env:USERPROFILE '.herdr\watcher-startup.lock'

# Stale-lock break: a crashed invocation would otherwise hold the lock forever
# and silently disable every future autostart. Normal holders finish in ~25s.
try {
    $existing = Get-Item -LiteralPath $lockDir -ErrorAction Stop
    if (((Get-Date) - $existing.CreationTime).TotalSeconds -gt 90) {
        Remove-Item -Path $lockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    # Lock doesn't exist; nothing to break
}

try {
    New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
} catch {
    exit 0
}

try {
    Start-Sleep -Seconds 3

    # Already running? Look for a powershell process running the watcher script.
    $running = $false
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine.Contains('ensure-agentpanel.ps1')) {
                $running = $true
                break
            }
        }
    } catch {
        $running = $false
    }

    if (-not $running) {
        $wsResp = herdr workspace list | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $wsResp.result.workspaces) {
            $wsId = $wsResp.result.workspaces[0].workspace_id
            $tabResp = herdr tab create --workspace $wsId --cwd $env:USERPROFILE --label watcher --no-focus | ConvertFrom-Json
            if ($LASTEXITCODE -eq 0) {
                $paneId = $tabResp.result.root_pane.pane_id
                $watcher = Join-Path $env:USERPROFILE '.herdr\ensure-agentpanel.ps1'
                herdr pane run $paneId "powershell -NoProfile -ExecutionPolicy Bypass -File '$watcher'" | Out-Null
            }
        }
    }
} finally {
    Start-Sleep -Seconds 20
    Remove-Item -Path $lockDir -Recurse -Force -ErrorAction SilentlyContinue
}
