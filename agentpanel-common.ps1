# Shared configuration, atomic state and renderer identity. PowerShell 5.1.
function Get-AgentPanelConfig {
    param([string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'))
    $config = @{ StateRoot = $StateRoot; pollSeconds = 15; heartbeatSeconds = 150;
        creationGraceSeconds = 90; maxCreates = 3; columns = 49; minWorkColumns = 40;
        limitTtlHours = 6; taskTtlMinutes = 15; completedTaskMinutes = 5;
        availability = @{}; probeAgents = @{}; excludedPanes = @() }
    $path = Join-Path $StateRoot 'agentpanel.json'
    if (Test-Path -LiteralPath $path) {
        $custom = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('availability','probeAgents')) {
            if ($custom.$name) { foreach ($p in $custom.$name.PSObject.Properties) { $config[$name][$p.Name] = $p.Value } }
        }
        if ($custom.excludedPanes) { $config.excludedPanes = @($custom.excludedPanes) }
        foreach ($name in @('pollSeconds','heartbeatSeconds','creationGraceSeconds','maxCreates','columns','minWorkColumns','limitTtlHours','taskTtlMinutes','completedTaskMinutes')) {
            if ($null -ne $custom.$name) {
                $value = [int]$custom.$name
                if ($value -lt 1) { throw "Configuration $name must be positive." }
                $config[$name] = $value
            }
        }
    }
    return $config
}

function Get-StateKey {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-AgentReadiness {
    param([bool]$HasCli, [bool]$HasConfig, [string]$Override, [bool]$LocalServiceReady=$false)
    if (-not $HasCli -or $Override -eq 'unavailable') { return 'unavailable' }
    if ($LocalServiceReady -or $Override -eq 'authenticated') { return 'available' }
    if ($HasConfig) { return 'configured' }
    return 'unavailable'
}

function Get-PanelSessionDirectory {
    param([string]$StateRoot)
    $session = if ($env:HERDR_SOCKET_PATH) { $env:HERDR_SOCKET_PATH } elseif ($env:HERDR_SESSION) { $env:HERDR_SESSION } else { 'default' }
    return Join-Path $StateRoot ('agentpanel-state\' + (Get-StateKey $session).Substring(0,16))
}

function Write-AtomicJson {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][AllowEmptyCollection()]$Value)
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 12
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tempPath, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tempPath, $Path) }
    } finally { if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) } }
}

function Invoke-StateLock {
    param([string]$Path, [scriptblock]$Action)
    $mutex = New-Object Threading.Mutex($false, ('Local\AgentPanel-' + (Get-StateKey ([IO.Path]::GetFullPath($Path).ToLowerInvariant()))))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for the AgentPanel state writer.' }
        & $Action
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-HerdrCommand {
    param([Parameter(Mandatory=$true)][string[]]$ArgList)
    $binary = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
    # Windows PowerShell represents native stderr as ErrorRecord objects. Capture
    # them without letting a caller's Stop preference bypass the exit-code check.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $binary @ArgList 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Herdr $($ArgList[0]) $($ArgList[1]) failed (exit $exitCode). $detail"
    }
    return $output
}

function Get-HerdrJson {
    param([Parameter(Mandatory=$true)][string[]]$ArgList)
    return ((Invoke-HerdrCommand $ArgList) -join "`n") | ConvertFrom-Json -ErrorAction Stop
}

function New-PanelLaunchCommand {
    param([string]$ScriptPath, [string]$StateRoot, [string]$Token)
    # EncodedCommand avoids differences in cmd/PowerShell quoting and spaces in paths.
    $command = "& '" + $ScriptPath.Replace("'","''") + "' -StateRoot '" + $StateRoot.Replace("'","''") + "' -OwnerToken '$Token'"
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Write-PanelHeartbeat {
    param([string]$StateRoot, [string]$OwnerToken, [string]$Role)
    if (-not $OwnerToken) { return }
    $pane = (Get-HerdrJson @('pane','current','--current')).result.pane
    if (-not $pane.pane_id) { throw 'Cannot resolve renderer pane.' }
    $process = Get-Process -Id $PID
    $record = @{ token=$OwnerToken; role=$Role; pane_id=$pane.pane_id; process_id=$PID;
        process_started=$process.StartTime.ToUniversalTime().ToString('o'); at=[DateTime]::UtcNow.ToString('o') }
    Write-AtomicJson -Path (Join-Path (Get-PanelSessionDirectory $StateRoot) "$OwnerToken.json") -Value $record
}

function Test-PanelKey {
    try { return [Console]::KeyAvailable -and ([Console]::ReadKey($true).KeyChar -in @('h','H')) }
    catch { return $false }
}

function Set-PanelsHidden {
    param([string]$StateRoot, [bool]$Hidden)
    $flag = Join-Path (Get-PanelSessionDirectory $StateRoot) 'panels-hidden'
    if ($Hidden) { Write-AtomicJson -Path $flag -Value @{ at=[DateTime]::UtcNow.ToString('o') } }
    elseif (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force }
}
