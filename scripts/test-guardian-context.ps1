param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$Locked
)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceRoot)
$report = [IO.Path]::GetFullPath($ReportPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($report)) | Out-Null
[ordered]@{ package = 'codex-guardian-context'; ok = $false; status = 'started'; locked = [bool]$Locked } |
    ConvertTo-Json | Set-Content -LiteralPath $report -Encoding utf8
if (-not (Test-Path -LiteralPath (Join-Path $source 'codex-rs/guardian-context/Cargo.toml'))) {
    throw 'Expected the reviewed upstream Guardian context crate.'
}
$arguments = @('test', '-p', 'codex-guardian-context')
if ($Locked) { $arguments += '--locked' }
Push-Location (Join-Path $source 'codex-rs')
try {
    $output = @(& cargo @arguments 2>&1 | ForEach-Object { "$_"; Write-Host "$_" })
    if ($LASTEXITCODE -ne 0) {
        [ordered]@{ package = 'codex-guardian-context'; ok = $false; status = 'failed'; exit_code = $LASTEXITCODE; diagnostics = @($output | Select-Object -Last 24) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report -Encoding utf8
        throw 'Guardian context crate compilation or tests failed.'
    }
} finally {
    Pop-Location
}
$summaries = @($output | Where-Object { $_ -match '^test result:' })
$passed = 0
foreach ($line in $summaries) {
    if ($line -notmatch '^test result: ok\. (?<passed>\d+) passed; 0 failed; 0 ignored;') {
        throw "Guardian test result was incomplete or ignored tests: $line"
    }
    $passed += [int]$Matches.passed
}
if ($passed -eq 0) { throw 'Guardian context gate executed zero tests.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($report)) | Out-Null
[ordered]@{ package = 'codex-guardian-context'; ok = $true; passed = $passed; test_binaries = $summaries.Count; locked = [bool]$Locked; summaries = $summaries } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report -Encoding utf8
Write-Host "Passed $passed Guardian context tests across $($summaries.Count) test binaries."
