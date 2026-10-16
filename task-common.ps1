# One atomic file per task/agent pair: independent agents cannot overwrite each other.
function Write-AgentTask {
    param(
        [string]$StateRoot, [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$AgentId, [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Description,
        [ValidateSet('working','idle','blocked','done','failed')][string]$Status='working',
        [string]$Provider='openrouter', [string]$Model, [string]$ParentAgentId, [string]$PaneId,
        [string]$Eta, [Nullable[double]]$CostUsd, [Nullable[long]]$TotalTokens,
        [long]$Sequence = 0
    )
    if ($null -ne $CostUsd -and ($CostUsd -lt 0 -or [double]::IsNaN($CostUsd) -or [double]::IsInfinity($CostUsd))) { throw 'Cost must be a finite non-negative number.' }
    if ($null -ne $TotalTokens -and $TotalTokens -lt 0) { throw 'Tokens cannot be negative.' }
    $key = Get-StateKey ($TaskId + [char]0 + $AgentId)
    $path = Join-Path $StateRoot ('agent-tasks\' + $key + '.json')
    $optionalProvided = @($PSBoundParameters.Keys)
    Invoke-StateLock $path {
        $old = $null
        if (Test-Path -LiteralPath $path) { $old = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
        # Sequence is optional; if used, late/replayed events cannot regress state.
        if ($Sequence -gt 0 -and $old -and $old.sequence -ge $Sequence) { return }
        if ($old -and $old.sequence -gt 0 -and $Sequence -eq 0) { throw 'This agent uses sequences; supply its next sequence number.' }
        $record = @{version=1; task_id=$TaskId; agent_id=$AgentId; name=$Name; desc=$Description;
            status=$Status; provider=$Provider; model=$Model; parent_agent_id=$ParentAgentId; pane_id=$PaneId;
            eta=$Eta; at=[DateTime]::UtcNow.ToString('o'); sequence=$Sequence;
            cost_usd=$CostUsd; total_tokens=$TotalTokens}
        if ($old -and $null -eq $CostUsd) { $record.cost_usd=$old.cost_usd }
        if ($old -and $null -eq $TotalTokens) { $record.total_tokens=$old.total_tokens }
        if ($old) {
            $optionalFields = @{Provider='provider';Model='model';ParentAgentId='parent_agent_id';PaneId='pane_id';Eta='eta'}
            foreach ($parameter in $optionalFields.Keys) {
                $field=$optionalFields[$parameter]
                if ($optionalProvided -notcontains $parameter) { $record[$field]=$old.$field }
            }
        }
        Write-AtomicJson $path $record
    }
}

function Read-AgentTasks {
    param([string]$StateRoot, [hashtable]$Config, [DateTime]$Now=[DateTime]::UtcNow)
    $directory = Join-Path $StateRoot 'agent-tasks'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($record.version -ne 1 -or -not $record.task_id -or -not $record.agent_id) { continue }
            $age = ($Now - [DateTime]::Parse($record.at).ToUniversalTime()).TotalMinutes
            if ($age -lt 0) { continue }
            if ($record.status -in @('done','failed') -and $age -gt $Config.completedTaskMinutes) { continue }
            if ($record.status -notin @('done','failed') -and $age -gt $Config.taskTtlMinutes) { $record.status='stale' }
            $record
        } catch { Write-Warning "Cannot read task record $($file.Name)." }
    }
}
