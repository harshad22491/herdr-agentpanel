$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agentpanel-common.ps1')
$testRoot=Join-Path $env:TEMP ('agentpanel-recovery-' + [Guid]::NewGuid().ToString('N'))
$oldBinary=$env:HERDR_BIN_PATH
function Assert { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"}; Microsoft.PowerShell.Utility\Write-Host "PASS: $Message" }
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $env:HERDR_BIN_PATH=Join-Path $testRoot 'mock-herdr.cmd'
    [IO.File]::WriteAllText($env:HERDR_BIN_PATH,"@echo off`r`necho {`"error`":{`"code`":`"server_not_running`"}} 1>&2`r`nexit /b 1`r`n")
    $script:caught=$null
    $leaked=@(& { try { Invoke-HerdrCommand @('pane','current','--current') } catch { $script:caught=$_ } } 2>&1)
    Assert ($leaked.Count -eq 0) 'failed native commands do not leak raw stderr into the panel'
    Assert ($script:caught.Exception.Message -match 'Herdr pane current failed \(exit 1\)' -and $script:caught.Exception.Message -match 'server_not_running') 'caught CLI error preserves exit status and diagnostic detail'
    Assert ($ErrorActionPreference -eq 'Stop') 'CLI capture preserves caller error handling'
    [IO.File]::WriteAllText($env:HERDR_BIN_PATH,"@echo off`r`necho {`"result`":{`"pane`":{`"pane_id`":`"w1:p2`"}}}`r`nexit /b 0`r`n")
    Assert ((Get-HerdrJson @('pane','current','--current')).result.pane.pane_id -eq 'w1:p2') 'successful native JSON commands still parse'

    # Execute the actual catalogue loop, ending only after an outage and recovery.
    # Keep the real heartbeat and atomic writer; fake only Herdr and local probes.
    $script:lookups=0; $script:retrySleeps=0; $script:done=$false; $script:display=@()
    function Get-HerdrJson {
        param($ArgList)
        $script:lookups++
        if($script:lookups -in @(2,3)){throw 'Herdr pane current failed (exit 1): server_not_running'}
        if($script:lookups -ge 5){$script:done=$true}
        return @{result=@{pane=@{pane_id='w1:p2'}}}
    }
    function Invoke-HerdrCommand { param($ArgList) 'codex: current' }
    function herdr { $global:LASTEXITCODE=0; 'codex: current' }
    function Get-Command { param($Name,$ErrorAction) return $null }
    function Read-FreshLimits { param($Path) return @{} }
    function Clear-Host { }
    function Write-Host { param($Object,$ForegroundColor,[switch]$NoNewline) $script:display+=[string]$Object }
    function Write-WrappedSection { param($Label,$Names,$DisplayForName,$ColorForName,$HeaderColor,$Suffix) }
    function Start-Sleep {
        param($Seconds)
        if($Seconds -eq 10){$script:retrySleeps++}
        if($script:lookups -gt 15 -or $script:retrySleeps -gt 3){throw 'Test exceeded bounded recovery attempts'}
    }
    $StateRoot=$testRoot; $OwnerToken='recovery-test'
    $kinds=@('codex'); $paneOnly=@(); $exeMap=@{}; $allModels=$kinds
    $credentialPaths=@{}; $unvalidatedPaths=@{}; $availabilityOverrides=@{}; $authUnvalidated=@(); $lastIntegrated=@()
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'agents-catalogue.ps1'),[ref]$tokens,[ref]$parseErrors)
    $loop=$ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.WhileStatementAst] } | Select-Object -Last 1
    $loopText=$loop.Extent.Text -replace '^while\s*\(\$true\)', 'while (-not $script:done)'
    & ([scriptblock]::Create($loopText))
    Assert ($script:retrySleeps -eq 2 -and $script:lookups -ge 5) 'catalogue survives periodic and startup heartbeat failures, then reconnects'
    Assert (@($script:display | Where-Object {$_ -match 'retrying in 10s'}).Count -eq 2) 'each failed refresh shows a concise retry status'
    Assert (@($script:display | Where-Object {$_ -match '^AgentPanel'}).Count -ge 2) 'normal catalogue rendering resumes after recovery'
    $heartbeat=Get-Content -LiteralPath (Join-Path (Get-PanelSessionDirectory $testRoot) "$OwnerToken.json") -Raw | ConvertFrom-Json
    Assert ($heartbeat.pane_id -eq 'w1:p2' -and $heartbeat.role -eq 'catalogue') 'reconnected renderer resumes valid ownership heartbeats'
} finally {
    $env:HERDR_BIN_PATH=$oldBinary
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('agentpanel-recovery-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
