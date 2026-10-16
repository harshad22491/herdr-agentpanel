# Plain PowerShell 5.1 test runner for limits-common.ps1 (no Pester dependency).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-limits-common.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'limits-common.ps1')

$script:failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("PASS  " + $Name)
    } else {
        Write-Host ("FAIL  " + $Name + "  expected=[" + $Expected + "] actual=[" + $Actual + "]") -ForegroundColor Red
        $script:failures++
    }
}

$now = [DateTime]::new(2026, 8, 31, 10, 0, 0, [DateTimeKind]::Utc)
$tmp = Join-Path $env:TEMP ('limits-test-' + [guid]::NewGuid().ToString('N') + '.json')

function Write-Limits {
    param([string]$Json, [DateTime]$Mtime)
    [System.IO.File]::WriteAllText($tmp, $Json, [System.Text.Encoding]::ASCII)
    (Get-Item -LiteralPath $tmp).LastWriteTimeUtc = $Mtime
}

# --- Legacy bare numbers: freshness comes from the file's mtime ---
Write-Limits '{"codex":100,"grok":100}' $now.AddDays(-3)
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal 0 $fresh.Count 'legacy numbers older than the TTL are dropped'

Write-Limits '{"codex":100}' $now.AddHours(-1)
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal 100 $fresh['codex'] 'legacy number within the TTL is kept'

# --- Timestamped entries ---
Write-Limits ('{"codex":{"pct":100,"at":"' + $now.AddHours(-1).ToString('o') + '","resets_at":"' + $now.AddHours(-0.5).ToString('o') + '"}}') $now
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal $false $fresh.ContainsKey('codex') 'entry whose reset time has passed is dropped'

Write-Limits ('{"codex":{"pct":100,"at":"' + $now.AddHours(-1).ToString('o') + '","resets_at":"' + $now.AddHours(2).ToString('o') + '"}}') $now
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal 100 $fresh['codex'] 'entry whose reset time is still ahead is kept'

Write-Limits ('{"copilot":{"pct":1,"at":"' + $now.AddHours(-7).ToString('o') + '"}}') $now
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal $false $fresh.ContainsKey('copilot') 'entry without reset time older than TTL is dropped'

Write-Limits ('{"copilot":{"pct":1,"at":"' + $now.AddHours(-2).ToString('o') + '"}}') $now
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal 1 $fresh['copilot'] 'entry without reset time within TTL is kept'

Write-Limits '{not json' $now
$fresh = Read-FreshLimits -Path $tmp -Now $now
Assert-Equal 0 $fresh.Count 'unparseable file yields no limits'

$fresh = Read-FreshLimits -Path ($tmp + '.missing') -Now $now
Assert-Equal 0 $fresh.Count 'missing file yields no limits'

# --- Reset-time parsing from provider output ---
$localNow = [DateTime]::new(2026, 8, 31, 10, 0, 0, [DateTimeKind]::Local)
$r = Get-ResetTime -Text '5h limit: [XXXX] 0% left (resets 18:54)' -Now $localNow
Assert-Equal ([DateTime]::new(2026, 8, 31, 18, 54, 0, [DateTimeKind]::Local)) $r 'codex reset later today'

$lateNow = [DateTime]::new(2026, 8, 31, 20, 0, 0, [DateTimeKind]::Local)
$r = Get-ResetTime -Text '5h limit: [XXXX] 0% left (resets 18:54)' -Now $lateNow
Assert-Equal ([DateTime]::new(2026, 9, 1, 18, 54, 0, [DateTimeKind]::Local)) $r 'codex reset time already passed today means tomorrow'

$r = Get-ResetTime -Text 'Plan  XXXX 1% used - resets in 3 days' -Now $localNow
Assert-Equal $localNow.AddDays(3) $r 'copilot resets in N days'

$r = Get-ResetTime -Text 'resets in 4 hours' -Now $localNow
Assert-Equal $localNow.AddHours(4) $r 'resets in N hours'

$r = Get-ResetTime -Text 'no reset info here' -Now $localNow
Assert-Equal $null $r 'no reset info yields null'

# --- Entry construction ---
$e = New-LimitEntry -Pct 42 -Now $now -ResetsAt $now.AddHours(3)
Assert-Equal 42 $e.pct 'entry carries pct'
Assert-Equal $now.ToString('o') $e.at 'entry carries at (round-trip ISO)'
Assert-Equal $now.AddHours(3).ToString('o') $e.resets_at 'entry carries resets_at'
$e = New-LimitEntry -Pct 7 -Now $now
Assert-Equal $false $e.Contains('resets_at') 'entry omits resets_at when unknown'

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) {
    Write-Host ("`n" + $script:failures + " test(s) FAILED") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll tests passed" -ForegroundColor Green
exit 0
