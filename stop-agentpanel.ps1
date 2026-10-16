param([string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
if ($env:HERDR_ENV -ne '1') { throw 'Run this command inside the Herdr session you want to stop monitoring.' }
Write-AtomicJson -Path (Join-Path (Get-PanelSessionDirectory $StateRoot) 'disabled') -Value @{at=[DateTime]::UtcNow.ToString('o')}
Write-Host 'AgentPanel will stop and close verified panel panes on its next cycle. Your agents keep running.'
Write-Host 'Run start-agentpanel.ps1 to enable it again.'
