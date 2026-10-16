$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agentpanel-common.ps1')
. (Join-Path $repo 'task-common.ps1')
$script:checks=0
function Assert { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"}; $script:checks++; Write-Host "PASS: $Message" }
$testRoot=Join-Path $env:TEMP ('agentpanel-workflow-' + [Guid]::NewGuid().ToString('N'))
$oldKey=$env:OPENROUTER_API_KEY
$jobs=@()
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $installDir=Join-Path $testRoot "User O'Brien\AgentPanel"
    $state=Join-Path $testRoot 'state'
    & (Join-Path $repo 'install-agentpanel.ps1') -Destination $installDir -StateRoot $state
    Assert ((Test-Path -LiteralPath (Join-Path $installDir 'start-agentpanel.ps1')) -and (Test-Path -LiteralPath (Join-Path $installDir 'watcher-plugin\start-watcher.ps1'))) 'installer copies complete runtime into a path with spaces and apostrophe'
    $configPath=Join-Path $state 'agentpanel.json'
    Write-AtomicJson $configPath @{columns=55}
    & (Join-Path $repo 'install-agentpanel.ps1') -Destination $installDir -StateRoot $state
    Assert ((Get-AgentPanelConfig $state).columns -eq 55) 'upgrading preserves user configuration'

    $env:OPENROUTER_API_KEY='test-key-never-sent'
    $script:RequestCount=0
    function Invoke-RestMethod {
        param($Uri,$Method,$TimeoutSec,$ContentType,$Headers,$Body)
        $script:RequestCount++
        Assert ($Uri -eq 'https://openrouter.ai/api/v1/chat/completions' -and $Method -eq 'Post') 'task uses the documented OpenRouter endpoint'
        $request=[Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Assert ($request.model -eq 'test/model' -and $request.max_tokens -eq 120 -and $request.messages[0].content -eq 'Compare two approaches.') 'task sends the selected model, task text and output limit'
        return @{model='test/model';choices=@(@{message=@{content='A useful comparison.'};finish_reason='stop'});usage=@{cost=0.007;total_tokens=73}}
    }
    $prompt=Join-Path $testRoot 'prompt.txt'
    [IO.File]::WriteAllText($prompt,'Compare two approaches.')
    & (Join-Path $installDir 'invoke-openrouter-task.ps1') -StateRoot $state -TaskId 'planning' -AgentId 'researcher' -Name 'Researcher' -Description 'Comparing approaches' -Model 'test/model' -PromptFile $prompt -MaxTokens 120
    $tasks=@(Read-AgentTasks $state (Get-AgentPanelConfig $state))
    Assert ($tasks.Count -eq 1 -and $tasks[0].status -eq 'done' -and $tasks[0].cost_usd -eq 0.007 -and $tasks[0].total_tokens -eq 73) 'complete task lifecycle records provider-reported cost and tokens'
    $resultPath=Join-Path $state ('task-results\' + (Get-StateKey ('planning' + [char]0 + 'researcher')) + '.json')
    Assert ((Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json).text -eq 'A useful comparison.') 'worker result is saved separately from dashboard state'
    $stored=(Get-ChildItem -LiteralPath $state -Recurse -File | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw}) -join ' '
    Assert (-not $stored.Contains('test-key-never-sent') -and -not $stored.Contains('Compare two approaches.')) 'API key and task prompt are absent from dashboard and result records'

    function Invoke-RestMethod { throw 'Mock provider rejection with private details' }
    $failed=$false
    try { & (Join-Path $installDir 'invoke-openrouter-task.ps1') -StateRoot $state -TaskId 'planning' -AgentId 'failed' -Name 'Worker' -Description 'Reviewing' -Model 'test/model' -PromptFile $prompt }
    catch { $failed=$true; Assert (-not $_.Exception.Message.Contains('private details')) 'provider errors do not expose raw private details' }
    $failedTask=@(Read-AgentTasks $state (Get-AgentPanelConfig $state)) | Where-Object {$_.agent_id -eq 'failed'}
    Assert ($failed -and $failedTask.status -eq 'failed') 'API failure is visible on the activity board'

    # Real parallel processes exercise the file lock and atomic replacement.
    foreach($n in 1..4) {
        $jobs+=Start-Job -ScriptBlock {
            param($scriptPath,$root,$number)
            & $scriptPath -StateRoot $root -TaskId 'parallel' -AgentId ('a'+$number) -Name ('Worker '+$number) -Description 'Independent work' -Status working -Sequence 1
            & $scriptPath -StateRoot $root -TaskId 'parallel' -AgentId ('a'+$number) -Name ('Worker '+$number) -Description 'Independent work' -Status done -Sequence 2 -CostUsd 0.01
        } -ArgumentList (Join-Path $installDir 'update-agent-task.ps1'),$state,$n
    }
    $jobs | Wait-Job -Timeout 30 | Out-Null
    foreach($job in $jobs) { Assert ($job.State -eq 'Completed') 'parallel task writer completed'; Receive-Job $job -ErrorAction Stop | Out-Null }
    $parallel=@(Read-AgentTasks $state (Get-AgentPanelConfig $state) | Where-Object {$_.task_id -eq 'parallel'})
    Assert ($parallel.Count -eq 4 -and @($parallel | Where-Object {$_.status -ne 'done'}).Count -eq 0) 'concurrent task agents retain all completed records'
    Write-Host "$script:checks workflow checks passed; all API traffic was mocked."
} finally {
    $env:OPENROUTER_API_KEY=$oldKey
    foreach($job in $jobs) { if($job.State -eq 'Running'){Stop-Job $job}; Remove-Job $job -Force }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('agentpanel-workflow-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
