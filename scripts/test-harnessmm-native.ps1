param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-CargoContractTest.ps1')
$filter = 'harnessmm::harnessmm_tests::'
$listing = @(& cargo test --locked -p codex-core --lib $filter -- --list 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) { throw ($listing -join [Environment]::NewLine) }
$names = @(Assert-CargoContractTestSelection -Listing $listing -Filter $filter)
$output = @(& cargo test --locked -p codex-core --lib $filter -- 2>&1 | ForEach-Object { "$_"; Write-Host "$_" })
if ($LASTEXITCODE -ne 0) { throw 'HarnessMM native tests failed.' }
Assert-CargoContractTestResult -Output $output -SelectedCount $names.Count
[ordered]@{ package='codex-core'; kind='lib'; filter=$filter; tests=$names; selected_count=$names.Count; passed=$true } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding utf8
