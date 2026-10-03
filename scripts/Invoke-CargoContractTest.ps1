function Assert-CargoContractTestSelection {
    param([string[]]$Listing, [string]$Filter, [switch]$Exact)
    $names = @($Listing | ForEach-Object {
        if ($_ -match '^(?<name>\S+): test$') { $Matches.name }
    })
    if ($names.Count -eq 0) { throw "Required Cargo contract selects zero tests: $Filter" }
    if ($Exact -and ($names.Count -ne 1 -or $names[0] -cne $Filter)) {
        throw "Exact Cargo contract must select only '$Filter': $($names -join ', ')"
    }
    if (@($names | Where-Object { -not $_.Contains($Filter, [StringComparison]::Ordinal) }).Count) {
        throw "Cargo selected unexpected tests for contract: $Filter"
    }
    return $names
}

function Invoke-CargoContractTest {
    param([string]$Package, [string]$Filter, [switch]$Exact, [string]$ReportPath)
    $arguments = @('test', '-p', $Package, '--test', 'all', $Filter, '--')
    $listArguments = $arguments + @('--list')
    if ($Exact) { $listArguments += '--exact'; $arguments += '--exact' }
    $listing = @(& cargo @listArguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "Cargo contract discovery failed for ${Filter}: $($listing -join [Environment]::NewLine)" }
    $names = @(Assert-CargoContractTestSelection -Listing $listing -Filter $Filter -Exact:$Exact)
    $output = @(& cargo @arguments 2>&1 | ForEach-Object { "$_"; Write-Host "$_" })
    if ($LASTEXITCODE -ne 0) { throw "Required Cargo contract failed: $Filter" }
    Assert-CargoContractTestResult -Output $output -SelectedCount $names.Count
    if ($ReportPath) {
        [ordered]@{ package = $Package; filter = $Filter; exact = [bool]$Exact; selected_count = $names.Count; tests = $names; passed = $true } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    }
}

function Assert-CargoContractTestResult {
    param([string[]]$Output, [int]$SelectedCount)
    $summaries = @($Output | Where-Object { $_ -match '^test result: ok\.' })
    if ($summaries.Count -ne 1 -or $summaries[0] -notmatch '^test result: ok\. (?<passed>\d+) passed; (?<failed>\d+) failed; (?<ignored>\d+) ignored;' -or
        [int]$Matches.passed -ne $SelectedCount -or [int]$Matches.failed -ne 0 -or [int]$Matches.ignored -ne 0) {
        throw "Cargo contract must execute and pass all $SelectedCount selected tests; missing, ignored, or changed test result."
    }
}
