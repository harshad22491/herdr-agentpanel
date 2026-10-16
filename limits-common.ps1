# limits-common.ps1
# Shared freshness rules for limits.json, dot-sourced by probe-usage.ps1 (writer)
# and agents-catalogue.ps1 (reader).
#
# limits.json maps provider name -> entry. An entry is either
#   - a bare number (legacy: percent used; its age is the file's mtime), or
#   - an object { pct, at, [resets_at] } with ISO-8601 round-trip timestamps.
# A quota reading is only meaningful until the provider's window resets, so an
# entry past its resets_at - or older than the TTL when no reset time is known -
# is dropped and the catalogue shows the provider as unknown ('?') again.
#
# PowerShell 5.1 compatible. Pure ASCII.

$LimitTtlHours = 6

function ConvertFrom-RoundTripTime {
    param([string]$Text)
    if (-not $Text) { return $null }
    try {
        return [DateTime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function New-LimitEntry {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0,100)][double]$Pct,
        [DateTime]$Now = (Get-Date).ToUniversalTime(),
        [object]$ResetsAt = $null
    )
    if ([double]::IsNaN($Pct) -or [double]::IsInfinity($Pct)) { throw 'Invalid percentage.' }
    $entry = [ordered]@{
        pct = $Pct
        at  = $Now.ToString('o')
    }
    if ($ResetsAt -is [DateTime]) {
        $entry['resets_at'] = ([DateTime]$ResetsAt).ToString('o')
    }
    return $entry
}

function Test-LimitEntryFresh {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][DateTime]$FileTime
    )
    $ttl = [TimeSpan]::FromHours($LimitTtlHours)

    # Legacy bare number: the only age we know is the file's.
    if ($Entry -is [ValueType] -or $Entry -is [string]) {
        return ($FileTime -le $Now -and ($Now - $FileTime) -lt $ttl)
    }

    $resetsAt = ConvertFrom-RoundTripTime ([string]$Entry.resets_at)
    $at = ConvertFrom-RoundTripTime ([string]$Entry.at)
    if ($null -eq $at) { return $false }
    $at = $at.ToUniversalTime()
    if ($at -gt $Now -or ($Now - $at) -ge $ttl) { return $false }
    return ($null -eq $resetsAt -or $Now -lt $resetsAt.ToUniversalTime())
}

function Read-FreshLimits {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [DateTime]$Now = (Get-Date).ToUniversalTime()
    )
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        if (-not $raw -or $raw.Trim().Length -eq 0) { return $result }
        $obj = $raw | ConvertFrom-Json
        $fileTime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        foreach ($prop in $obj.PSObject.Properties) {
            $entry = $prop.Value
            if ($null -eq $entry) { continue }
            if (-not (Test-LimitEntryFresh -Entry $entry -Now $Now.ToUniversalTime() -FileTime $fileTime)) { continue }
            $pct = if ($entry -is [ValueType] -or $entry -is [string]) { $entry } else { $entry.pct }
            if ($null -eq $pct) { continue }
            try {
                $number = [double]$pct
                if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 100) { continue }
                $result[$prop.Name] = $number
            } catch { continue }
        }
    } catch {
        return @{}
    }
    return $result
}

# Parses a provider's own reset hint out of its status output:
#   codex:   "... 0% left (resets 18:54)"      -> next occurrence of that wall-clock time
#   copilot: "... 1% used - resets in 3 days"  -> now + N days/hours/minutes
function Get-ResetTime {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [DateTime]$Now = (Get-Date)
    )
    if ($Text -match '(?i)resets\s+in\s+(\d+)\s*(day|hour|minute|min|d|h|m)s?\b') {
        $n = [int]$Matches[1]
        switch -Regex ($Matches[2].ToLower()) {
            '^(day|d)$'         { return $Now.AddDays($n) }
            '^(hour|h)$'        { return $Now.AddHours($n) }
            '^(minute|min|m)$'  { return $Now.AddMinutes($n) }
        }
    }
    if ($Text -match '(?i)resets\s+(?:at\s+)?(\d{1,2}):(\d{2})') {
        if ([int]$Matches[1] -gt 23 -or [int]$Matches[2] -gt 59) { return $null }
        $candidate = [DateTime]::new($Now.Year, $Now.Month, $Now.Day, [int]$Matches[1], [int]$Matches[2], 0, $Now.Kind)
        if ($candidate -le $Now) { $candidate = $candidate.AddDays(1) }
        return $candidate
    }
    return $null
}
