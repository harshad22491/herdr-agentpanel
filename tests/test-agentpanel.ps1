$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agentpanel-common.ps1')
. (Join-Path $repo 'limits-common.ps1')
. (Join-Path $repo 'task-common.ps1')
$script:checks=0
function Assert { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++; Write-Host "PASS: $Message" }
function Import-Functions {
    param([string]$File)
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $File),[ref]$tokens,[ref]$parseErrors)
    Assert (@($parseErrors).Count -eq 0) "$File parses"
    foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
        Set-Item -Path ('Function:script:' + $fn.Name) -Value ([ScriptBlock]::Create($fn.Body.Extent.Text.Trim().Substring(1,$fn.Body.Extent.Text.Trim().Length-2)))
    }
}
$testRoot=Join-Path $env:TEMP ('agentpanel-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $StateRoot=$testRoot
    $AgentPanelScriptDirectory=$repo
    $Config=Get-AgentPanelConfig $testRoot
    $SessionDir=Join-Path $testRoot 'session'
    $LedgerFile=Join-Path $SessionDir 'panel-panes.json'
    $FlagFile=Join-Path $SessionDir 'panels-hidden'
    Import-Functions 'ensure-agentpanel.ps1'
    Set-PanelLedger -Ledger @()
    Assert (@(Get-PanelLedger).Count -eq 0) 'empty ledger can be saved and read'

    $launch=New-PanelLaunchCommand "C:\Example O'Brien\agents-feed.ps1" "C:\User With Spaces\.herdr" 'test-token'
    $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($launch -split ' ')[-1]))
    Assert ($decoded.Contains("O''Brien") -and $decoded.Contains('User With Spaces')) 'launch quoting preserves spaces and apostrophes'
    Assert ((Get-AgentReadiness $false $true 'authenticated') -eq 'unavailable') 'leftover credentials and overrides cannot make an uninstalled CLI available'
    Assert ((Get-AgentReadiness $true $true '') -eq 'configured') 'configuration alone is not authenticated availability'

    $script:Ledger=@(); $script:Creates=0; $script:MockCalls=@()
    $script:MockPanes=@(); $script:ShellStart=[DateTime]::UtcNow
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{ProcessId=10; ParentProcessId=1; CreationDate=$script:ShellStart; Name='powershell.exe'} }
    function Get-HerdrJson {
        param([string[]]$ArgList)
        switch ($ArgList[0] + ' ' + $ArgList[1]) {
            'pane split' { $id='new' + $script:Creates; $script:MockPanes+= [pscustomobject]@{pane_id=$id;tab_id='t1';label='';agent=$null}; return @{result=@{pane=@{pane_id=$id}}} }
            'pane process-info' { return @{result=@{process_info=@{shell_pid=10}}} }
            'pane get' { return @{result=@{pane=($script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[2]} | Select-Object -First 1)}} }
            default { throw "Unexpected mock JSON command: $ArgList" }
        }
    }
    function Invoke-HerdrCommand {
        param([string[]]$ArgList)
        $script:MockCalls+=($ArgList -join ' ')
        switch ($ArgList[1]) {
            rename { ($script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[2]}).label=$ArgList[3] }
            run { throw 'Mock launch failure' }
            close { $script:MockPanes=@($script:MockPanes | Where-Object {$_.pane_id -ne $ArgList[2]}) }
            default { throw "Unexpected mock command: $ArgList" }
        }
    }
    1..4 | ForEach-Object { $null=New-OwnedPanel ([pscustomobject]@{pane_id='source';tab_id='t1'}) catalogue }
    Assert ($script:Creates -eq 3) 'launch failures cannot bypass the split cap'
    Assert ($script:MockPanes.Count -eq 0 -and $script:Ledger.Count -eq 0) 'failed launches clean up verified empty shells'

    $entry=[pscustomobject]@{token='owned';pane_id='owned-pane';role='catalogue';tab_id='t1';shell_pid=10;shell_started=$script:ShellStart.ToString('o');command_text='expected'}
    $entry | Add-Member created_at ([DateTime]::UtcNow.AddMinutes(-10).ToString('o'))
    Assert (-not (Test-PanelHealthy $entry)) 'an old pane with no heartbeat is unhealthy regardless of its screen'
    $entry.created_at=[DateTime]::UtcNow.ToString('o')
    Assert (Test-PanelHealthy $entry) 'newly launched renderer receives a bounded startup grace period'
    $script:MockPanes=@([pscustomobject]@{pane_id='owned-pane';label='agentpanel:owned';agent='codex'})
    Assert (-not (Test-CanCloseOwnedPane $entry)) 'an agent in a formerly owned pane cannot be closed'
    $script:MockPanes[0].agent=$null; $script:MockPanes[0].label='my editor'
    Assert (-not (Test-CanCloseOwnedPane $entry)) 'renaming an owned pane prevents automatic closure'
    $script:MockPanes[0].label='agentpanel:owned'
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction)
        [pscustomobject]@{ProcessId=10;ParentProcessId=1;CreationDate=$script:ShellStart;Name='powershell.exe'}
        [pscustomobject]@{ProcessId=11;ParentProcessId=10;CreationDate=$script:ShellStart;Name='notepad.exe';CommandLine='notepad.exe'}
    }
    Assert (-not (Test-CanCloseOwnedPane $entry)) 'an unrelated shell child prevents automatic closure'
    Assert ($null -eq (Get-OwnedPane $entry @([pscustomobject]@{pane_id='user';label='';title='AgentPanel 12:00'}))) 'screen/title text is never adopted as ownership'
    Assert ((Get-OwnedPane $entry @([pscustomobject]@{pane_id='moved';label='agentpanel:owned'})).pane_id -eq 'moved') 'ownership follows a moved pane by its unique label'

    # Hidden mode must reach board creation even with an empty ledger.
    $script:Ledger=@(); $script:BoardCreates=0
    Write-AtomicJson $FlagFile @{hidden=$true}
    function Get-AllPanes { [pscustomobject]@{pane_id='source';tab_id='t1';agent_status='idle'} }
    function New-OwnedPanel { param($Target,$Role,$Direction,$Ratio) if ($Role -eq 'board') { $script:BoardCreates++ } }
    Invoke-PanelIteration
    Assert ($script:BoardCreates -eq 1) 'hidden mode recreates a missing restore board'

    Import-Functions 'probe-usage.ps1'
    $Config.probeAgents=@{copilot='quota-copilot'}
    $script:AgentStatus='blocked'; $script:MockCalls=@(); $script:LookupCount=0
    function Get-HerdrJson { param([string[]]$ArgList)
        $script:LookupCount++
        return @{result=@{agent=[pscustomobject]@{name='quota-copilot';agent='copilot';pane_id='probe-pane';agent_status=$script:AgentStatus;agent_session=@{value='session1'}}}}
    }
    function Invoke-HerdrCommand { param([string[]]$ArgList) $script:MockCalls+=($ArgList -join ' '); if ($ArgList[1] -eq 'read') { 'Plan xxxx 12% used - resets in 3 days' } }
    function Start-Sleep { param($Seconds,$Milliseconds) }
    $result=Invoke-UsageProbe copilot
    Assert ($null -eq $result -and $script:MockCalls.Count -eq 0) 'blocked dedicated probe receives no input'
    $script:AgentStatus='unknown'; $result=Invoke-UsageProbe copilot
    Assert ($null -eq $result -and $script:MockCalls.Count -eq 0) 'unknown probe receives no input'
    $script:AgentStatus='idle'; $Config.probeAgents=@{}; $result=Invoke-UsageProbe copilot
    Assert ($null -eq $result -and $script:MockCalls.Count -eq 0) 'unconfigured agents receive no input'
    $Config.probeAgents=@{copilot='quota-copilot'}; $result=Invoke-UsageProbe copilot
    Assert ($result.pct -eq 12 -and $script:MockCalls[0] -eq 'agent prompt quota-copilot /usage') 'idle configured probe uses guarded agent submission'
    Assert (-not ($script:MockCalls -match 'send-keys|backspace|esc')) 'prober never performs input cleanup'
    $script:LookupCount=0; $script:MockCalls=@()
    function Get-HerdrJson { param([string[]]$ArgList)
        $script:LookupCount++
        $id=if($script:LookupCount -eq 1){'old'}else{'new'}
        return @{result=@{agent=[pscustomobject]@{name='quota-copilot';agent='copilot';pane_id=$id;agent_status='idle';agent_session=@{value='session1'}}}}
    }
    $result=Invoke-UsageProbe copilot
    Assert ($null -eq $result -and $script:MockCalls.Count -eq 0) 'changed pane identity aborts the probe'

    $LimitsPath=Join-Path $testRoot 'limits.json'
    Write-AtomicJson $LimitsPath @{codex=100}
    (Get-Item -LiteralPath $LimitsPath).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-2)
    Update-LimitsFile @{copilot=@{pct=12;resets_at=$null}}
    $fresh=Read-FreshLimits $LimitsPath
    Assert (-not $fresh.ContainsKey('codex') -and $fresh.copilot -eq 12) 'updating another provider cannot rejuvenate legacy quota'
    $now=[DateTime]::UtcNow
    $old=New-LimitEntry -Pct 10 -Now $now.AddHours(-7) -ResetsAt $now.AddDays(3)
    Assert (-not (Test-LimitEntryFresh $old $now $now)) 'future reset does not bypass observation TTL'
    Write-AtomicJson $LimitsPath @{bad=@{pct='nonsense';at=$now.ToString('o')};good=(New-LimitEntry 5)}
    $fresh=Read-FreshLimits $LimitsPath
    Assert ($fresh.good -eq 5 -and -not $fresh.ContainsKey('bad')) 'one invalid quota does not hide valid providers'

    $taskArgs=@{StateRoot=$testRoot;TaskId='task-1';AgentId='a';Name='Researcher';Description='Comparing approaches';Model='provider/model'}
    Write-AgentTask @taskArgs -Status working -Sequence 1
    Write-AgentTask @taskArgs -Status done -Sequence 3 -CostUsd 0.012 -TotalTokens 120
    Write-AgentTask @taskArgs -Status working -Sequence 2
    Write-AgentTask -StateRoot $testRoot -TaskId 'task-1' -AgentId 'b' -Name 'Reviewer' -Description 'Checking results' -Status blocked
    $tasks=@(Read-AgentTasks $testRoot $Config)
    Assert ($tasks.Count -eq 2) 'two task agents retain separate records'
    $taskA=$tasks | Where-Object {$_.agent_id -eq 'a'}
    Assert ($taskA.status -eq 'done' -and $taskA.cost_usd -eq 0.012) 'late task events cannot overwrite completion or cost'
    Write-AgentTask -StateRoot $testRoot -TaskId 'task-1' -AgentId 'a' -Name 'Researcher' -Description 'Comparison complete' -Status done -Sequence 4
    $updated=@(Read-AgentTasks $testRoot $Config) | Where-Object {$_.agent_id -eq 'a'}
    Assert ($updated.model -eq 'provider/model' -and $updated.cost_usd -eq 0.012) 'state-only updates retain model and accounting'
    $later=@(Read-AgentTasks $testRoot $Config ([DateTime]::UtcNow.AddMinutes(20)))
    Assert ($later.Count -eq 1 -and $later[0].status -eq 'stale') 'completed tasks age out and missing updates become stale'

    Import-Functions 'agents-feed.ps1'
    $manual=@{agents=@{reviewer=@{desc='Fixing authentication';eta='5 minutes'}};next=$null}
    $live=@([pscustomobject]@{name='reviewer';agent='codex';agent_status='working';pane_id='p1'})
    $lines=@(Get-BoardLines $manual $live @() 100)
    Assert ($lines.Count -eq 1 -and $lines[0] -match 'Fixing authentication' -and $lines[0] -match '5 minutes') 'live status preserves manual task and ETA without duplicate row'
    $lines=@(Get-BoardLines @{agents=@{};next=$null} @() $tasks 100)
    Assert (($lines -join ' ') -match 'openrouter / provider/model' -and ($lines -join ' ') -match 'USD 0.0120') 'OpenRouter model and reported cost appear on board'
    $wrapped=@(Wrap-Text ('a'*100) 20)
    Assert ($wrapped.Count -eq 5 -and @($wrapped | Where-Object {$_.Length -gt 20}).Count -eq 0) 'long model names wrap within pane width'

    Write-Host "$script:checks checks passed. No live Herdr or provider calls were made."
} finally {
    # Delete only this test's explicitly verified temporary workspace.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $expectedParent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('agentpanel-test-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
