# Optional one-request text worker. It cannot edit files or execute model tool calls.
[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'),
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$AgentId = ([Guid]::NewGuid().ToString('N')),
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Description,
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$PromptFile,
    [ValidateRange(1,32768)][int]$MaxTokens=2000
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
. (Join-Path $PSScriptRoot 'task-common.ps1')
if (-not $env:OPENROUTER_API_KEY) { throw 'Set OPENROUTER_API_KEY in this terminal before starting a task.' }
$promptPath = (Resolve-Path -LiteralPath $PromptFile).ProviderPath
# Get-Content strings carry filesystem metadata that PS 5.1 may serialize into JSON.
$prompt = [IO.File]::ReadAllText($promptPath, [Text.Encoding]::UTF8)
$taskArgs = @{StateRoot=$StateRoot; TaskId=$TaskId; AgentId=$AgentId; Name=$Name; Description=$Description; Model=$Model}
Write-AgentTask @taskArgs -Status working
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $body = @{model=$Model; messages=@(@{role='user'; content=$prompt}); max_tokens=$MaxTokens; stream=$false} | ConvertTo-Json -Depth 6
    $response = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/chat/completions' -Method Post -TimeoutSec 120 -ContentType 'application/json; charset=utf-8' -Headers @{Authorization=('Bearer ' + $env:OPENROUTER_API_KEY)} -Body ([Text.Encoding]::UTF8.GetBytes($body))
    if ($response.error -or -not $response.choices -or $null -eq $response.choices[0].message.content) { throw 'OpenRouter returned no text result.' }
    $resultPath = Join-Path $StateRoot ('task-results\' + (Get-StateKey ($TaskId + [char]0 + $AgentId)) + '.json')
    Write-AtomicJson $resultPath @{task_id=$TaskId; agent_id=$AgentId; model=$response.model; text=$response.choices[0].message.content; finish_reason=$response.choices[0].finish_reason}
    $cost = $null; $tokens = $null
    if ($response.usage) { $cost=$response.usage.cost; $tokens=$response.usage.total_tokens }
    if ($response.model) { $taskArgs.Model=[string]$response.model }
    $status = if ($response.choices[0].finish_reason -eq 'length') { 'blocked' } else { 'done' }
    Write-AgentTask @taskArgs -Status $status -CostUsd $cost -TotalTokens $tokens
    if ($status -eq 'blocked') { Write-Warning 'The answer reached the output limit. Review the partial result before continuing.' }
    Write-Output ([string]$response.choices[0].message.content)
    Write-Output "Result saved: $resultPath"
} catch {
    Write-AgentTask @taskArgs -Status failed
    # Never persist or echo API headers, prompts or raw provider error bodies.
    throw 'OpenRouter task failed. Check connectivity, the model ID and your OpenRouter account. The board records the failure.'
}
