# Exercise reconciliation repeatedly against a stateful fake Herdr server.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agentpanel-common.ps1')
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ensure-agentpanel.ps1'),[ref]$tokens,[ref]$parseErrors)
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $fn.Extent.Text }
$script:checks=0
function Assert {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"}; $script:checks++; Write-Host "PASS: $Message"}
$testRoot=Join-Path $env:TEMP ('agentpanel-cycle-' + [Guid]::NewGuid().ToString('N'))
try {
    $StateRoot=$testRoot; $AgentPanelScriptDirectory=$repo
    $SessionDir=Join-Path $testRoot 'session'; $LedgerFile=Join-Path $SessionDir 'panel-panes.json'; $FlagFile=Join-Path $SessionDir 'panels-hidden'
    $Config=Get-AgentPanelConfig $StateRoot
    $script:Ledger=@(); $script:NextId=0; $script:DeadToken=''; $script:Creates=0; $script:Closed=@(); $script:ShellStart=[DateTime]::UtcNow
    $script:MockPanes=@(
        [pscustomobject]@{pane_id='source1';tab_id='t1';workspace_id='w1';agent=$null;agent_status=$null;label='work'},
        [pscustomobject]@{pane_id='source2';tab_id='t2';workspace_id='w1';agent=$null;agent_status=$null;label='work'}
    )
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{ProcessId=10;ParentProcessId=1;CreationDate=$script:ShellStart;Name='powershell.exe'} }
    function Get-HerdrJson {
        param([string[]]$ArgList)
        switch ($ArgList[0]+' '+$ArgList[1]) {
            'workspace list' {return @{result=@{workspaces=@(@{workspace_id='w1'})}}}
            'pane list' {return @{result=@{panes=$script:MockPanes}}}
            'pane get' {return @{result=@{pane=($script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[2]} | Select-Object -First 1)}}}
            'pane process-info' {return @{result=@{process_info=@{shell_pid=10}}}}
            'pane layout' {
                $target=$script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[3]} | Select-Object -First 1
                $panes=@($script:MockPanes | Where-Object {$_.tab_id -eq $target.tab_id} | ForEach-Object {
                    $width=if($_.label -like 'agentpanel:*'){49}else{160}
                    @{pane_id=$_.pane_id;rect=@{width=$width;height=28;x=0;y=0}}
                })
                return @{result=@{layout=@{panes=$panes;splits=@();area=@{width=210;height=28}}}}
            }
            'pane split' {
                $source=$script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[2]} | Select-Object -First 1
                $script:NextId++
                $new=[pscustomobject]@{pane_id=('new'+$script:NextId);tab_id=$source.tab_id;workspace_id='w1';agent=$null;agent_status=$null;label=''}
                $script:MockPanes+=$new
                return @{result=@{pane=$new}}
            }
            default {throw "Unexpected fake request: $ArgList"}
        }
    }
    function Invoke-HerdrCommand {
        param([string[]]$ArgList)
        switch ($ArgList[1]) {
            rename {($script:MockPanes | Where-Object {$_.pane_id -eq $ArgList[2]}).label=$ArgList[3]}
            run {}
            close {$script:Closed+=$ArgList[2]; $script:MockPanes=@($script:MockPanes | Where-Object {$_.pane_id -ne $ArgList[2]})}
            swap {}
            resize {}
            default {throw "Unexpected fake mutation: $ArgList"}
        }
    }
    function Test-PanelHealthy {param($Entry) return $Entry.token -ne $script:DeadToken}
    Invoke-PanelIteration
    Assert ($script:Creates -eq 3 -and $script:Ledger.Count -eq 3) 'first cycle creates two catalogues and one board'
    Invoke-PanelIteration
    Assert ($script:Creates -eq 0 -and $script:Ledger.Count -eq 3) 'repeating reconciliation creates no extra panes'
    $script:Ledger=@(Get-PanelLedger)
    Invoke-PanelIteration
    Assert ($script:Creates -eq 0) 'watcher restart reuses persisted ownership without duplicate panes'

    $first=$script:Ledger | Where-Object {$_.role -eq 'catalogue'} | Select-Object -First 1
    $script:DeadToken=$first.token; $deadId=$first.pane_id
    Invoke-PanelIteration
    Assert ($script:Closed -contains $deadId -and $script:Creates -eq 1 -and $script:Ledger.Count -eq 3) 'unhealthy owned renderer is replaced without accumulating a pane'
    $script:DeadToken=''

    $script:Creates=0
    $null=New-OwnedPanel $script:MockPanes[0] catalogue
    Assert ($script:Ledger.Count -eq 4) 'duplicate fixture exists before reconciliation'
    Invoke-PanelIteration
    Assert ($script:Ledger.Count -eq 3 -and $script:Creates -eq 0) 'verified duplicate is removed without another split'

    Write-AtomicJson $FlagFile @{hidden=$true}
    Invoke-PanelIteration
    Assert ($script:Ledger.Count -eq 1 -and $script:Ledger[0].role -eq 'board') 'hide closes only catalogues and preserves the restore board'
    Remove-Item -LiteralPath $FlagFile
    Invoke-PanelIteration
    Assert ($script:Ledger.Count -eq 3 -and $script:Creates -eq 2) 'show restores catalogues while reusing the surviving board'
    Write-Host "$script:checks reconciliation checks passed against the fake server."
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot); $parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('agentpanel-cycle-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
