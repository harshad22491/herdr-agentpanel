# Herdr workspace/tab event hook. Paths resolve relative to the linked plugin.
$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'start-agentpanel.ps1'
& $launcher -Automatic
