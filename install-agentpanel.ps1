[CmdletBinding()]
param([string]$Destination = (Join-Path $env:USERPROFILE '.herdr\agentpanel'), [string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'))
$ErrorActionPreference = 'Stop'
$destinationPath = [IO.Path]::GetFullPath($Destination)
[IO.Directory]::CreateDirectory($destinationPath) | Out-Null
$files = @('agentpanel-common.ps1','limits-common.ps1','task-common.ps1','agents-catalogue.ps1',
    'agents-feed.ps1','ensure-agentpanel.ps1','probe-usage.ps1','start-agentpanel.ps1','stop-agentpanel.ps1',
    'update-agent-task.ps1','invoke-openrouter-task.ps1','agentpanel.example.json','agents-status.example.json')
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot $file
    $target = Join-Path $destinationPath $file
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
}
$pluginTarget = Join-Path $destinationPath 'watcher-plugin'
[IO.Directory]::CreateDirectory($pluginTarget) | Out-Null
foreach ($file in @('herdr-plugin.toml','start-watcher.ps1')) {
    $source = Join-Path (Join-Path $PSScriptRoot 'watcher-plugin') $file
    $target = Join-Path $pluginTarget $file
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
}
[IO.Directory]::CreateDirectory($StateRoot) | Out-Null
$configPath = Join-Path $StateRoot 'agentpanel.json'
if (-not (Test-Path -LiteralPath $configPath)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'agentpanel.example.json') -Destination $configPath }
Write-Host "Installed to $destinationPath"
$quotedDestination = $destinationPath.Replace("'","''")
$quotedState = $StateRoot.Replace("'","''")
$quotedPlugin = $pluginTarget.Replace("'","''")
Write-Host "In a Herdr PowerShell pane, run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$quotedDestination\start-agentpanel.ps1' -StateRoot '$quotedState'"
Write-Host "Optional automatic startup (default state folder): herdr plugin link '$quotedPlugin'"
