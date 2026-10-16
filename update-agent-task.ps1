[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $env:USERPROFILE '.herdr'),
    [Parameter(Mandatory=$true)][string]$TaskId, [Parameter(Mandatory=$true)][string]$AgentId,
    [Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][string]$Description,
    [ValidateSet('working','idle','blocked','done','failed')][string]$Status='working',
    [string]$Provider='openrouter', [string]$Model, [string]$ParentAgentId, [string]$PaneId,
    [string]$Eta, [Nullable[double]]$CostUsd, [Nullable[long]]$TotalTokens, [long]$Sequence=0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agentpanel-common.ps1')
. (Join-Path $PSScriptRoot 'task-common.ps1')
$PSBoundParameters['StateRoot'] = $StateRoot
Write-AgentTask @PSBoundParameters
