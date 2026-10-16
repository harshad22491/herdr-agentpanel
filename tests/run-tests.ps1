$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$failures=@()
Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens=$null; $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
    foreach($errorItem in $parseErrors){$failures+=($_.Name+': '+$errorItem.Message)}
}
if($failures.Count){throw ($failures -join [Environment]::NewLine)}
foreach($name in @('test-limits-common.ps1','test-agentpanel.ps1','test-catalogue-recovery.ps1','test-watcher-cycle.ps1','test-workflows.ps1')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
    if($LASTEXITCODE -ne 0){throw "$name failed."}
}
Write-Host 'All syntax, regression and workflow checks passed.'
