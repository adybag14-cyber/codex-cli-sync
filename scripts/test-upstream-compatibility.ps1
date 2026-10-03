[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-UpstreamMcpServer.ps1")
. (Join-Path $PSScriptRoot "Initialize-UpstreamCheckout.ps1")
. (Join-Path $PSScriptRoot 'Resolve-CodexCustomVersion.ps1')
. (Join-Path $PSScriptRoot 'Invoke-SourcePatchTransaction.ps1')
. (Join-Path $PSScriptRoot 'Invoke-CargoContractTest.ps1')
. (Join-Path $PSScriptRoot 'Read-ArtifactChecksums.ps1')
. (Join-Path $PSScriptRoot 'Test-WindowsBuildState.ps1')

# Import only the pure patch functions, not the patcher's main source mutation.
$patchTokens = $null
$patchErrors = $null
$patchAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "patch-codex-windows-custom.ps1"), [ref]$patchTokens, [ref]$patchErrors)
if ($patchErrors.Count) { throw "Windows patcher has syntax errors: $patchErrors" }
foreach ($functionName in @('Get-Text', 'Set-Text', 'Insert-AfterOnce', 'Set-WindowsToolPermissionsBypass', 'Set-WindowsExecPolicyBypass', 'Disable-WindowsSandboxStartupNux', 'Show-WindowsDebugCommands', 'Assert-RustCrateRecursionLimit', 'Set-ConfigPermissionsForWindowsCustom')) {
    $definition = $patchAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $false)
    if (-not $definition) { throw "Missing patch function $functionName" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$linuxAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "sync-codex-linux-i686-musl.ps1"), [ref]$patchTokens, [ref]$patchErrors)
if ($patchErrors.Count) { throw "Linux sync script has syntax errors: $patchErrors" }
foreach ($functionName in @('Ensure-RustCrateRecursionLimit', 'Enable-I686MuslLinuxSandboxSyscallBuild')) {
    $definition = $linuxAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $false)
    if (-not $definition) { throw "Missing Linux patch function $functionName" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}

$windowsSyncAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "sync-codex-windows-custom.ps1"), [ref]$patchTokens, [ref]$patchErrors)
if ($patchErrors.Count) { throw "Windows sync script has syntax errors: $patchErrors" }
foreach ($functionName in @('Set-CargoWorkspaceVersion', 'Set-PackageJsonVersionIfPresent')) {
    $definition = $windowsSyncAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $false)
    if (-not $definition) { throw "Missing Windows sync function $functionName" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-upstream-contract-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$testCount = 0

function New-Layout {
    param([string]$Name, [hashtable]$Files)
    $root = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach ($entry in $Files.GetEnumerator()) {
        $path = Join-Path $root $entry.Key
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.File]::WriteAllText($path, $entry.Value, [Text.UTF8Encoding]::new($false))
    }
    return $root
}

function Assert-Rejected {
    param([string]$Root, [string]$ExpectedMessage)
    $message = $null
    try { Resolve-UpstreamMcpServerCrateRoot -CodexRsDir $Root | Out-Null }
    catch { $message = $_.Exception.Message }
    if (-not $message -or -not $message.Contains($ExpectedMessage)) {
        throw "Expected '$ExpectedMessage' for $Root; got '$message'"
    }
    $script:testCount++
}

try {
    $root = New-Layout -Name 'recipe-fingerprint' -Files @{
        'scripts/patch.ps1' = 'source patch'
        '.github/workflows/sync-codex-windows-custom.yml' = 'recipe'
        'tools/CodexSyncDoctor/Program.cs' = 'companion'
        'tools/CodexSyncDoctor/obj/generated.cs' = 'generated-ignored'
    }
    $fingerprint = Get-WindowsBuildRecipeFingerprint -RepositoryRoot $root
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw 'Invalid recipe fingerprint' }
    [IO.File]::WriteAllText((Join-Path $root 'tools/CodexSyncDoctor/obj/generated.cs'), 'different ignored output')
    if ((Get-WindowsBuildRecipeFingerprint -RepositoryRoot $root) -ne $fingerprint) { throw 'Build output incorrectly affected recipe identity' }
    $testCount++
    [IO.File]::WriteAllText((Join-Path $root 'scripts/patch.ps1'), 'new patch')
    if ((Get-WindowsBuildRecipeFingerprint -RepositoryRoot $root) -eq $fingerprint) { throw 'Source patch change did not invalidate build state' }
    $testCount++
    $stateArgs = @{ StoredSha = 'abc'; UpstreamSha = 'abc'; UpstreamRepo = 'openai/codex'; UpstreamRef = 'main'; BaseVersion = '0.161.0'; Target = 'x86_64-pc-windows-msvc'; RecipeFingerprint = $fingerprint }
    $state = [pscustomobject]@{ upstream_sha = 'abc'; upstream_repo = 'openai/codex'; upstream_ref = 'main'; windows_target = 'x86_64-pc-windows-msvc'; patch_status = 'applied'; custom_patches_failed = $false; version_resolution = [pscustomobject]@{ base_version = '0.161.0' }; build_recipe_sha256 = $fingerprint }
    if (-not (Test-WindowsBuildStateCurrent -State $state @stateArgs)) { throw 'Matching successful recipe was not recognized' }
    $testCount++
    foreach ($field in @('upstream_sha', 'upstream_repo', 'upstream_ref', 'windows_target', 'patch_status', 'custom_patches_failed', 'version_resolution', 'build_recipe_sha256')) {
        $changed = $state | ConvertTo-Json | ConvertFrom-Json
        if ($field -eq 'version_resolution') { $changed.version_resolution.base_version = '0.162.0' }
        elseif ($field -eq 'custom_patches_failed') { $changed.custom_patches_failed = $true }
        else { $changed.$field = 'changed' }
        if (Test-WindowsBuildStateCurrent -State $changed @stateArgs) { throw "Changed $field incorrectly skipped a rebuild" }
        $testCount++
    }
    foreach ($oldState in @($null, [pscustomobject]@{ upstream_sha = 'abc' }, [pscustomobject]@{ version_resolution = $null })) {
        if (Test-WindowsBuildStateCurrent -State $oldState @stateArgs) { throw 'Incomplete historical state incorrectly skipped a rebuild' }
        $testCount++
    }
    $stateArgs.StoredSha = 'out-of-date-sha-file'
    if (Test-WindowsBuildStateCurrent -State $state @stateArgs) { throw 'Inconsistent state files incorrectly skipped a rebuild' }
    $testCount++
    foreach ($value in @(256, 512, 1024)) {
        $root = New-Layout -Name ("recursion-verification-" + $value) -Files @{ 'lib.rs' = "#![recursion_limit = `"$value`"]`n" }
        Assert-RustCrateRecursionLimit -Path (Join-Path $root 'lib.rs')
        $testCount++
    }
    foreach ($text in @('', "#![recursion_limit = `"128`"]`n", "#![recursion_limit = `"256`"]`n#![recursion_limit = `"512`"]`n")) {
        $root = New-Layout -Name ("recursion-verification-refusal-" + $testCount) -Files @{ 'lib.rs' = $text }
        $rejected = $false
        try { Assert-RustCrateRecursionLimit -Path (Join-Path $root 'lib.rs') } catch { $rejected = $true }
        if (-not $rejected) { throw 'Missing, low, or duplicate recursion limit was accepted' }
        $testCount++
    }
    $root = New-Layout -Name 'ambiguous-permission-constructors' -Files @{ 'config.rs' = 'permissions: Permissions {}, permissions: Permissions {}' }
    $rejected = $false
    try { Set-ConfigPermissionsForWindowsCustom -Path (Join-Path $root 'config.rs') | Out-Null } catch { $rejected = $_.Exception.Message.Contains('Multiple permission constructors') }
    if (-not $rejected) { throw 'Multiple permission configuration routes were accepted' }
    $testCount++

    $hash = 'a' * 64
    foreach ($case in @(
        @{ Lines = @("$hash  archive.lib.gz", "$hash *bindings.rs") },
        @{ Lines = @("$hash  archive.lib.gz", "$hash *bindings.rs", "$hash  extra-symbols.zip", '') }
    )) {
        $hashes = Read-ArtifactChecksums -Lines $case.Lines -RequiredNames @('archive.lib.gz', 'bindings.rs')
        if ($hashes['archive.lib.gz'] -ne $hash -or $hashes['bindings.rs'] -ne $hash) { throw 'Required artifact hashes were not resolved' }
        $testCount++
    }
    foreach ($case in @(
        @{ Lines = @("$hash  archive.lib.gz") },
        @{ Lines = @("$hash  archive.lib.gz", "$hash  archive.lib.gz", "$hash  bindings.rs") },
        @{ Lines = @('bad-hash  archive.lib.gz', "$hash  bindings.rs") },
        @{ Lines = @("$hash  ../archive.lib.gz", "$hash  bindings.rs") }
    )) {
        $rejected = $false
        try { Read-ArtifactChecksums -Lines $case.Lines -RequiredNames @('archive.lib.gz', 'bindings.rs') | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'Unsafe artifact checksum manifest was accepted' }
        $testCount++
    }

    $names = @(Assert-CargoContractTestSelection -Listing @('some build diagnostic', 'suite::contract: test', 'suite::bench: benchmark', '1 test, 1 benchmark') -Filter 'suite::contract' -Exact)
    if ($names.Count -ne 1) { throw 'Exact contract test discovery failed' }
    Assert-CargoContractTestResult -Output @('test result: ok. 1 passed; 0 failed; 0 ignored; 9 filtered out; finished in 0.01s') -SelectedCount 1
    $testCount++
    $names = @(Assert-CargoContractTestSelection -Listing @('suite::tools::one: test', 'suite::tools::two: test') -Filter 'suite::tools::')
    Assert-CargoContractTestResult -Output @('test result: ok. 2 passed; 0 failed; 0 ignored; 1 filtered out; finished in 0.01s') -SelectedCount $names.Count
    $testCount++
    foreach ($case in @(@{ Lines = @('0 tests, 0 benchmarks') }, @{ Lines = @('other::test: test') }, @{ Lines = @('suite::contract: test', 'suite::contract: test') })) {
        $rejected = $false
        try { Assert-CargoContractTestSelection -Listing $case.Lines -Filter 'suite::contract' -Exact | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'Empty or incorrect Cargo contract selection was accepted' }
        $testCount++
    }
    foreach ($output in @('', 'test result: ok. 0 passed; 0 failed; 0 ignored; 1 filtered out;', 'test result: ok. 0 passed; 0 failed; 1 ignored; 0 filtered out;', 'test result: FAILED. 0 passed; 1 failed; 0 ignored;')) {
        $rejected = $false
        try { Assert-CargoContractTestResult -Output @($output) -SelectedCount 1 } catch { $rejected = $true }
        if (-not $rejected) { throw 'Missing, skipped or failed Cargo contract execution was accepted' }
        $testCount++
    }
    function cargo {
        if ($args -contains '--list') {
            $global:LASTEXITCODE = $script:cargoContractCase.ListExit
            $script:cargoContractCase.Listing
        } else {
            $script:cargoContractRuns++
            $global:LASTEXITCODE = $script:cargoContractCase.RunExit
            $script:cargoContractCase.Output
        }
    }
    try {
        foreach ($case in @(
            @{ Listing = @('suite::contract: test'); ListExit = 0; RunExit = 0; Output = 'test result: ok. 1 passed; 0 failed; 0 ignored;'; Accepted = $true; Runs = 1 },
            @{ Listing = @('0 tests, 0 benchmarks'); ListExit = 0; RunExit = 0; Output = ''; Accepted = $false; Runs = 0 },
            @{ Listing = @('suite::contract: test'); ListExit = 1; RunExit = 0; Output = ''; Accepted = $false; Runs = 0 },
            @{ Listing = @('suite::contract: test'); ListExit = 0; RunExit = 1; Output = ''; Accepted = $false; Runs = 1 },
            @{ Listing = @('suite::contract: test'); ListExit = 0; RunExit = 0; Output = 'test result: ok. 0 passed; 0 failed; 1 ignored;'; Accepted = $false; Runs = 1 }
        )) {
            $script:cargoContractCase = $case
            $script:cargoContractRuns = 0
            $accepted = $true
            try { Invoke-CargoContractTest -Package fixture -Filter 'suite::contract' -Exact }
            catch { $accepted = $false }
            if ($accepted -ne $case.Accepted -or $script:cargoContractRuns -ne $case.Runs) { throw 'Cargo contract invocation accepted a false success or ran an undiscovered test' }
            $testCount++
        }
    } finally { Remove-Item Function:cargo }
    $global:LASTEXITCODE = 0

    $root = New-Layout -Name 'transaction-refusal' -Files @{ 'first.rs' = "original`r`n"; 'last.rs' = 'original-last' }
    $rejected = $false
    try {
        Invoke-SourcePatchTransaction -SourceRoot $root -RelativePaths @('first.rs', 'last.rs') -Patch {
            param($Stage)
            [IO.File]::WriteAllText((Join-Path $Stage 'first.rs'), 'changed')
            throw 'late upstream anchor changed'
        }
    } catch { $rejected = $_.Exception.Message.Contains('late upstream anchor') }
    if (-not $rejected -or [IO.File]::ReadAllText((Join-Path $root 'first.rs')) -ne "original`r`n" -or
        [IO.File]::ReadAllText((Join-Path $root 'last.rs')) -ne 'original-last') { throw 'Failed patch partially modified its source' }
    $testCount++
    Invoke-SourcePatchTransaction -SourceRoot $root -RelativePaths @('first.rs', 'last.rs') -Patch {
        param($Stage)
        [IO.File]::WriteAllText((Join-Path $Stage 'first.rs'), 'patched-first')
        [IO.File]::WriteAllText((Join-Path $Stage 'last.rs'), 'patched-last')
    }
    if ([IO.File]::ReadAllText((Join-Path $root 'first.rs')) -ne 'patched-first' -or
        [IO.File]::ReadAllText((Join-Path $root 'last.rs')) -ne 'patched-last') { throw 'Validated patch transaction did not commit' }
    $testCount++
    $rejected = $false
    try {
        Invoke-SourcePatchTransaction -SourceRoot $root -RelativePaths @('first.rs', 'last.rs') -Patch {
            param($Stage)
            [IO.File]::WriteAllText((Join-Path $Stage 'first.rs'), 'new-patch')
            [IO.File]::WriteAllText((Join-Path $root 'last.rs'), 'external-change')
        }
    } catch { $rejected = $_.Exception.Message.Contains('Source changed during patch planning') }
    if (-not $rejected -or [IO.File]::ReadAllText((Join-Path $root 'first.rs')) -ne 'patched-first' -or
        [IO.File]::ReadAllText((Join-Path $root 'last.rs')) -ne 'external-change') { throw 'Patch transaction overwrote a changed source snapshot' }
    $testCount++
    foreach ($relative in @('../escaped.rs', 'missing.rs')) {
        $rejected = $false
        try { Invoke-SourcePatchTransaction -SourceRoot $root -RelativePaths @($relative) -Patch { throw 'must not run' } } catch { $rejected = -not $_.Exception.Message.Contains('must not run') }
        if (-not $rejected) { throw 'Invalid patch transaction input was accepted' }
        $testCount++
    }

    $root = New-Layout -Name 'version-discovery' -Files @{ 'Cargo.toml' = "[workspace.package]`nversion = `"0.0.0`"`n" }
    $versionCargo = Join-Path $root 'Cargo.toml'
    $tagPrefix = ('a' * 40) + "`trefs/tags/"
    $fixedTime = [DateTimeOffset]::Parse('2026-10-03T12:34:00+01:00')
    foreach ($case in @(
        @{ Tags = @('rust-v0.159.0'); Base = '0.160.0' },
        @{ Tags = @('rust-v0.9.0', 'rust-v0.99.0', 'rust-v0.160.2', 'rust-v0.159.9'); Base = '0.161.0' },
        @{ Tags = @('rust-v0.159.0', 'rust-v0.159.0', 'rust-v0.159.0^{}', 'rust-v0.162.0-alpha.9', 'rust-v0.0.2504291921', 'v9.0.0', 'rust-v0.160.0+build'); Base = '0.160.0' },
        @{ Tags = @('rust-v0.999.5'); Base = '0.1000.0' },
        @{ Tags = @('rust-v0.999.0', 'rust-v1.0.0'); Base = '1.1.0' },
        @{ Tags = @('rust-v2.8.9', 'rust-v1.999.999'); Base = '2.9.0' }
    )) {
        $resolution = Resolve-CodexCustomVersion -CargoTomlPath $versionCargo -UpstreamRef main -RemoteUrl unused `
            -TagLines @($case.Tags | ForEach-Object { $tagPrefix + $_ }) -Timestamp $fixedTime
        if ($resolution.base_version -ne $case.Base -or $resolution.custom_version -ne ($case.Base + '-202610031134') -or
            $resolution.source -ne 'next_minor_after_latest_stable_tag') { throw "Wrong automatic version: $($resolution | ConvertTo-Json -Compress)" }
        $testCount++
    }
    foreach ($case in @(
        @{ Workspace = '0.0.0'; Ref = 'rust-v0.160.0'; Base = '0.160.0'; Source = 'upstream_ref' },
        @{ Workspace = '0.0.0'; Ref = 'refs/tags/rust-v0.162.0-alpha.9'; Base = '0.162.0'; Source = 'upstream_ref' },
        @{ Workspace = '1.0.0-rc.2+build'; Ref = 'main'; Base = '1.0.0'; Source = 'workspace_version' },
        @{ Workspace = '0.158.1'; Ref = 'release-branch'; Base = '0.158.1'; Source = 'workspace_version' },
        @{ Workspace = '0.160.0'; Ref = 'rust-v0.160.0'; Base = '0.160.0'; Source = 'upstream_ref' }
    )) {
        [IO.File]::WriteAllText($versionCargo, "[workspace.package]`nversion = `"$($case.Workspace)`"`n")
        $resolution = Resolve-CodexCustomVersion -CargoTomlPath $versionCargo -UpstreamRef $case.Ref -RemoteUrl unused -TagLines @() -Timestamp $fixedTime
        if ($resolution.base_version -ne $case.Base -or $resolution.source -ne $case.Source) { throw 'Explicit upstream version was not preserved' }
        $testCount++
    }
    [IO.File]::WriteAllText($versionCargo, "[workspace.package]`r`nversion = `"0.160.0`" # source version`r`n`r`n[package]`r`nversion = `"9.9.9`"`r`n")
    $resolution = Resolve-CodexCustomVersion -CargoTomlPath $versionCargo -UpstreamRef main -RemoteUrl unused -TagLines @() `
        -Timestamp ([DateTimeOffset]::Parse('2028-03-01T00:05:00+02:00'))
    if ($resolution.custom_version -ne '0.160.0-202802292205') { throw 'CRLF source or UTC leap-day rollover version failed' }
    $testCount++
    [IO.File]::WriteAllText($versionCargo, "[workspace.package]`nversion = `"0.0.0`"`n")
    $rejected = $false
    try { Resolve-CodexCustomVersion -CargoTomlPath $versionCargo -UpstreamRef main -RemoteUrl (Join-Path $fixtureRoot 'missing-remote.git') | Out-Null }
    catch { $rejected = $_.Exception.Message.Contains('stable-tag discovery failed') }
    if (-not $rejected) { throw 'Failed Git tag discovery did not fail closed' }
    $testCount++
    foreach ($case in @(
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'main'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'main'; Tags = @('rust-v0.162.0-alpha.1', 'rust-v0.0.2504291921') },
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'main'; Tags = @('rust-v0.2147483647.0') },
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'main'; Tags = @('rust-v1.9999999999.0') },
        @{ Cargo = "[workspace.package]`nversion = `"0.159.0`"`n"; Ref = 'rust-v0.160.0'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"bad`"`n"; Ref = 'main'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.160.0-rc..1`"`n"; Ref = 'main'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.160.0-01`"`n"; Ref = 'main'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'rust-vwrong'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.0.0`"`n"; Ref = 'rust-v0.0.0'; Tags = @() },
        @{ Cargo = "[workspace.package]`nversion = `"0.159.0`"`nversion = `"0.160.0`"`n"; Ref = 'main'; Tags = @() },
        @{ Cargo = "[package]`nversion = `"0.159.0`"`n"; Ref = 'main'; Tags = @() }
    )) {
        [IO.File]::WriteAllText($versionCargo, $case.Cargo)
        $rejected = $false
        try { Resolve-CodexCustomVersion -CargoTomlPath $versionCargo -UpstreamRef $case.Ref -RemoteUrl unused -TagLines @($case.Tags | ForEach-Object { $tagPrefix + $_ }) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected -or [IO.File]::ReadAllText($versionCargo) -ne $case.Cargo) { throw 'Unsafe version discovery was accepted or modified source' }
        $testCount++
    }
    $customVersion = '0.160.0-202610031134'
    $semanticVersion = [Management.Automation.SemanticVersion]::Parse($customVersion)
    $catalogClientVersion = '{0}.{1}.{2}' -f $semanticVersion.Major, $semanticVersion.Minor, $semanticVersion.Patch
    if ($catalogClientVersion -ne '0.160.0') {
        throw "Custom version would advertise incompatible model catalog client version '$catalogClientVersion'"
    }
    $testCount++
    $root = New-Layout -Name 'custom-version' -Files @{
        'Cargo.toml' = "[workspace.package]`nversion = `"0.0.0`"`nedition = `"2024`"`n`n[package]`nname = `"fixture`"`nversion = `"9.8.7`"`n"
        'package.json' = "{`n  `"name`": `"fixture`",`n  `"version`": `"0.0.0`"`n}`n"
    }
    $cargoPath = Join-Path $root 'Cargo.toml'
    Set-CargoWorkspaceVersion -CargoTomlPath $cargoPath -Version $customVersion
    $cargoText = [IO.File]::ReadAllText($cargoPath)
    if (-not $cargoText.Contains("version = `"$customVersion`"") -or -not $cargoText.Contains('version = "9.8.7"')) {
        throw 'Custom Cargo workspace version was not propagated while preserving the unrelated package version'
    }
    $testCount++
    $packagePath = Join-Path $root 'package.json'
    Set-PackageJsonVersionIfPresent -PackageJsonPath $packagePath -Version $customVersion
    $package = [IO.File]::ReadAllText($packagePath) | ConvertFrom-Json
    if ($package.version -ne $customVersion -or $package.name -ne 'fixture') {
        throw 'Custom package.json version was not propagated while preserving the package name'
    }
    $testCount++
    foreach ($newline in @("`n", "`r`n")) {
        $fixture = @'
#[clap(hide = true)]
enum Unrelated { KeepHidden }
enum DebugSubcommand {
    Models(DebugModelsCommand),
    #[clap(hide = true)]
    TraceReduce(DebugTraceReduceCommand),
    #[command(hide = true)]
    ClearMemories,
}
'@ -replace '\r?\n', $newline
        $root = New-Layout -Name ("debug-visibility-" + $testCount) -Files @{ 'main.rs' = $fixture }
        $path = Join-Path $root 'main.rs'
        Show-WindowsDebugCommands -Path $path
        $patched = [IO.File]::ReadAllText($path)
        if (-not $patched.StartsWith('#[clap(hide = true)]') -or
            -not $patched.Contains('#[cfg_attr(not(target_os = "windows"), clap(hide = true))]') -or
            -not $patched.Contains('#[cfg_attr(not(target_os = "windows"), command(hide = true))]')) {
            throw 'Debug visibility patch changed unrelated commands or missed a hidden variant'
        }
        if ($newline -eq "`r`n" -and [regex]::IsMatch($patched, '(?<!\r)\n')) {
            throw 'Debug visibility patch changed CRLF line endings'
        }
        Show-WindowsDebugCommands -Path $path
        if ([IO.File]::ReadAllText($path) -ne $patched) { throw 'Debug visibility patch is not idempotent' }
        $testCount++
    }
    foreach ($fixture in @('enum Other { Models }', "enum DebugSubcommand {`n}`nenum DebugSubcommand {`n}")) {
        $root = New-Layout -Name ("debug-refusal-" + $testCount) -Files @{ 'main.rs' = $fixture }
        $path = Join-Path $root 'main.rs'
        $rejected = $false
        try { Show-WindowsDebugCommands -Path $path }
        catch { $rejected = $_.Exception.Message.Contains('Expected exactly one DebugSubcommand') }
        if (-not $rejected -or [IO.File]::ReadAllText($path) -ne $fixture) {
            throw 'Debug visibility patch did not reject source drift without changing the file'
        }
        $testCount++
    }
    $removed = New-Layout -Name "removed" -Files @{
        "Cargo.toml" = "[workspace]`nmembers = [`"cli`", `"mcp-client`"]`n"
        "Cargo.lock" = "version = 4`n"
        "cli/Cargo.toml" = "[package]`nname = `"codex-cli`"`n"
    }
    if ($null -ne (Resolve-UpstreamMcpServerCrateRoot -CodexRsDir $removed)) { throw "Removed crate must not resolve" }
    if (Test-Path -LiteralPath (Join-Path $removed "mcp-server")) { throw "Removed crate was recreated" }
    $testCount++

    $legacy = New-Layout -Name "legacy" -Files @{
        "Cargo.toml" = "[workspace]`nmembers = [`"mcp-server`"]`n"
        "Cargo.lock" = "[[package]]`nname = `"codex-mcp-server`"`nversion = `"0.0.0`"`n"
        "mcp-server/Cargo.toml" = "[package]`nname = `"codex-mcp-server`"`n"
        "mcp-server/src/lib.rs" = "pub fn legacy() {}`n"
    }
    $expected = [IO.Path]::GetFullPath((Join-Path $legacy "mcp-server/src/lib.rs"))
    if ((Resolve-UpstreamMcpServerCrateRoot -CodexRsDir $legacy) -ne $expected) { throw "Legacy crate did not resolve" }
    $testCount++

    foreach ($reference in @('"mcp-server"', "'mcp-server'", 'codex-mcp-server = { path = "mcp-server" }')) {
        $root = New-Layout -Name ("workspace-reference-" + $testCount) -Files @{
            "Cargo.toml" = "[workspace]`n$reference`n"
            "Cargo.lock" = "version = 4`n"
        }
        Assert-Rejected -Root $root -ExpectedMessage "still references mcp-server"
    }
    $root = New-Layout -Name "lock-reference" -Files @{
        "Cargo.toml" = "[workspace]`nmembers = []`n"
        "Cargo.lock" = "[[package]]`nname = `"codex-mcp-server`"`n"
    }
    Assert-Rejected -Root $root -ExpectedMessage "still references mcp-server"
    $root = New-Layout -Name "cli-reference" -Files @{
        "Cargo.toml" = "[workspace]`nmembers = [`"cli`"]`n"
        "Cargo.lock" = "version = 4`n"
        "cli/Cargo.toml" = "[dependencies]`ncodex-mcp-server = { path = `"../mcp-server`" }`n"
    }
    Assert-Rejected -Root $root -ExpectedMessage "still references mcp-server"
    foreach ($missing in @('Cargo.toml', 'Cargo.lock', 'mcp-server/Cargo.toml', 'mcp-server/src/lib.rs')) {
        $files = @{
            'Cargo.toml' = "[workspace]`nmembers = [`"mcp-server`"]`n"
            'Cargo.lock' = "version = 4`n"
            'mcp-server/Cargo.toml' = "[package]`nname = `"codex-mcp-server`"`n"
            'mcp-server/src/lib.rs' = "pub fn legacy() {}`n"
        }
        $files.Remove($missing)
        $root = New-Layout -Name ("incomplete-" + $testCount) -Files $files
        Assert-Rejected -Root $root -ExpectedMessage "missing"
    }
    $root = New-Layout -Name "wrong-package" -Files @{
        'Cargo.toml' = "[workspace]`nmembers = [`"mcp-server`"]`n"
        'Cargo.lock' = "version = 4`n"
        'mcp-server/Cargo.toml' = "[package]`nname = `"other-server`"`n"
        'mcp-server/src/lib.rs' = "pub fn other() {}`n"
    }
    Assert-Rejected -Root $root -ExpectedMessage "Unexpected upstream package identity"
    foreach ($case in @(
        @{ Async = 'async '; Signature = "    session: &Session,`n    cwd: &Path," },
        @{ Async = 'async '; Signature = "    session: &Session,`n    environment_id: &str,`n    cwd: &std::path::Path," },
        @{ Async = 'async '; Signature = "    session: &Session,`r`n    environment: &TurnEnvironment,`r`n    cwd: &PathUri," },
        @{ Async = ''; Signature = "    step_context: &StepContext,`n    environment: &TurnEnvironment,`n    cwd: &PathUri," },
        @{ Async = ''; Signature = "    step_context: &StepContext,`r`n    environment: &TurnEnvironment,`r`n    cwd: &PathUri," }
    )) {
        $rust = @"
pub(super) $($case.Async)fn apply_granted_turn_permissions(
$($case.Signature)
    sandbox_permissions: SandboxPermissions,
    additional_permissions: Option<AdditionalPermissionProfile>,
) -> EffectiveAdditionalPermissions {
    original_permission_evaluator()
}
"@
        $root = New-Layout -Name ("permissions-" + $testCount) -Files @{ 'handler.rs' = $rust }
        $path = Join-Path $root 'handler.rs'
        Set-WindowsToolPermissionsBypass -Path $path
        $patched = [IO.File]::ReadAllText($path)
        if (-not $patched.Contains('if cfg!(target_os = "windows")') -or -not $patched.Contains('permissions_preapproved: true') -or -not $patched.Contains('original_permission_evaluator()')) {
            throw "Windows permissions patch did not preserve the required behavior"
        }
        $testCount++
        Set-WindowsToolPermissionsBypass -Path $path
        if ([IO.File]::ReadAllText($path) -ne $patched) { throw 'Tool-permissions patch is not idempotent' }
        $testCount++
    }

    foreach ($rust in @(
        "pub(super) fn apply_granted_turn_permissions(unknown: &NewContext) -> EffectiveAdditionalPermissions {`n    original()`n}",
        ($patched + "`n" + $patched),
        $patched.Replace('StepContext', 'UnknownContext'),
        $patched.Replace('    // codex-cli-sync:', '    other_operation(); // codex-cli-sync:')
    )) {
        $root = New-Layout -Name ("permissions-refusal-" + $testCount) -Files @{ 'handler.rs' = $rust }
        $path = Join-Path $root 'handler.rs'
        $rejected = $false
        try { Set-WindowsToolPermissionsBypass -Path $path } catch { $rejected = $true }
        if (-not $rejected -or [IO.File]::ReadAllText($path) -ne $rust) { throw 'Unknown or ambiguous permissions layout was accepted or modified' }
        $testCount++
    }

    $legacyPolicy = @'
    pub(crate) async fn create_exec_approval_requirement_for_command(
        &self,
        req: ExecApprovalRequest<'_>,
    ) -> ExecApprovalRequirement {
        original_policy_evaluator(req)
    }
'@
    $testWrapper = "    #[cfg(test)]`n$legacyPolicy`n"
    $productionPolicy = @'
    async fn create_exec_approval_requirement_for_parsed_commands(
        &self,
        req: ExecApprovalRequest<'_>,
        ExecPolicyCommands {
            commands,
            command_origin,
        }: ExecPolicyCommands,
        command_platform: DangerousCommandPlatform,
    ) -> ExecApprovalRequirement {
        original_policy_evaluator(req)
    }
'@
    foreach ($rust in @($legacyPolicy, ($testWrapper + $productionPolicy))) {
        $root = New-Layout -Name ("exec-policy-" + $testCount) -Files @{ 'policy.rs' = $rust }
        $path = Join-Path $root 'policy.rs'
        Set-WindowsExecPolicyBypass -Path $path
        $patched = [IO.File]::ReadAllText($path)
        if (([regex]::Matches($patched, 'bypass_sandbox: true')).Count -ne 1 -or -not $patched.Contains('original_policy_evaluator(req)')) {
            throw "Exec-policy bypass contract was not preserved"
        }
        if ($rust.StartsWith($testWrapper) -and -not $patched.StartsWith($testWrapper)) {
            throw "Patched the test-only wrapper instead of the production evaluator"
        }
        $testCount++
    }
    $root = New-Layout -Name "unsupported-test-wrapper" -Files @{ 'policy.rs' = $testWrapper }
    $rejected = $false
    try { Set-WindowsExecPolicyBypass -Path (Join-Path $root 'policy.rs') }
    catch { $rejected = $_.Exception.Message.Contains('test-only exec-policy wrapper') }
    if (-not $rejected) { throw "Test-only wrapper was accepted without a production evaluator" }
    $testCount++
    foreach ($case in @(
        @{ Start = ''; Expected = 256; Changed = $true },
        @{ Start = "#![recursion_limit = `"128`"]`r`n"; Expected = 256; Changed = $true },
        @{ Start = "#![recursion_limit = `"256`"]`n"; Expected = 256; Changed = $false },
        @{ Start = "#![recursion_limit = `"512`"]`n"; Expected = 512; Changed = $false }
    )) {
        $root = New-Layout -Name ("recursion-" + $testCount) -Files @{ 'lib.rs' = ($case.Start + "pub fn preserved() {}`n") }
        $path = Join-Path $root 'lib.rs'
        $changed = Ensure-RustCrateRecursionLimit -Path $path -Minimum 256
        $patched = [IO.File]::ReadAllText($path)
        if ($changed -ne $case.Changed -or -not $patched.StartsWith("#![recursion_limit = `"$($case.Expected)`"]") -or -not $patched.Contains('pub fn preserved() {}')) {
            throw "Recursion limit was not raised/preserved correctly"
        }
        if ((Ensure-RustCrateRecursionLimit -Path $path -Minimum 256) -or [IO.File]::ReadAllText($path) -ne $patched) {
            throw "Recursion-limit patch is not idempotent"
        }
        $testCount++
    }
    # Exercise the old and new startup layouts without touching the opposite
    # platform binding. These are source contracts, not a full upstream build.
    $startupName = 'should_prompt_windows_sandbox_nux_at_startup'
    $windowsCfg = '#[cfg(target_os = "windows")]'
    $nonWindowsBinding = "    #[cfg(not(target_os = `"windows`"))]`n    let $startupName = false;"
    $legacyStartup = '(trust_decision_was_made && windows_sandbox_level == WindowsSandboxLevel::Disabled) || required_elevated_sandbox_needs_setup'
    foreach ($newline in @("`n", "`r`n")) {
        foreach ($condition in @($legacyStartup, 'trust_decision_was_made')) {
            $before = "fn sentinel_before() {}`n    $windowsCfg`n    let $startupName = $condition;`n$nonWindowsBinding`nfn sentinel_after() {}`n"
            $before = $before.Replace("`n", $newline)
            $root = New-Layout -Name ("startup-nux-" + $testCount) -Files @{ 'lib.rs' = $before }
            $path = Join-Path $root 'lib.rs'
            Disable-WindowsSandboxStartupNux -Path $path
            $patched = [IO.File]::ReadAllText($path)
            $expectedSuffix = ($nonWindowsBinding + "`nfn sentinel_after() {}`n").Replace("`n", $newline)
            if (-not $patched.StartsWith('fn sentinel_before() {}') -or -not $patched.EndsWith($expectedSuffix) -or
                -not $patched.Contains('// codex-cli-sync: Windows custom build never shows the startup sandbox NUX.') -or
                -not $patched.Contains("        false${newline}    };")) {
                throw 'Startup NUX patch did not preserve surrounding code and the non-Windows binding'
            }
            foreach ($name in @('windows_sandbox_level', 'required_elevated_sandbox_needs_setup')) {
                if ($patched.Contains("&$name") -ne ($condition -eq $legacyStartup)) {
                    throw "Startup NUX patch references the wrong layout's local: $name"
                }
            }
            if ($newline -eq "`r`n" -and [regex]::IsMatch($patched, '(?<!\r)\n')) {
                throw 'Startup NUX patch changed the CRLF line endings'
            }
            $testCount++
            Disable-WindowsSandboxStartupNux -Path $path
            if ([IO.File]::ReadAllText($path) -ne $patched) { throw 'Startup NUX patch is not idempotent' }
            $testCount++
        }
    }
    $root = New-Layout -Name 'startup-nux-whitespace' -Files @{
        'lib.rs' = "    #[cfg(target_os=`"windows`")]`n    let $startupName =`n        trust_decision_was_made ;`n$nonWindowsBinding`n"
    }
    Disable-WindowsSandboxStartupNux -Path (Join-Path $root 'lib.rs')
    $testCount++
    $windowsBinding = "    $windowsCfg`n    let $startupName = trust_decision_was_made;`n"
    foreach ($unsupported in @(
        $nonWindowsBinding,
        "    let $startupName = trust_decision_was_made;`n",
        ($windowsBinding + $windowsBinding + $nonWindowsBinding),
        ($windowsBinding.Replace('= trust_decision_was_made;', '= new_startup_policy();') + $nonWindowsBinding),
        ($windowsBinding.Replace('= trust_decision_was_made;', '= trust_decision_was_made || another_condition;') + $nonWindowsBinding),
        ($windowsBinding.Replace('= trust_decision_was_made;', '= false;') + $nonWindowsBinding),
        ($windowsBinding.Replace('target_os = "windows"', 'target_os = "linux"') + $nonWindowsBinding)
    )) {
        $root = New-Layout -Name ("startup-nux-rejected-" + $testCount) -Files @{ 'lib.rs' = $unsupported }
        $path = Join-Path $root 'lib.rs'
        $rejected = $false
        try { Disable-WindowsSandboxStartupNux -Path $path }
        catch { $rejected = $_.Exception.Message.StartsWith('Windows startup NUX') }
        if (-not $rejected -or [IO.File]::ReadAllText($path) -ne $unsupported) {
            throw 'Unknown or ambiguous startup NUX layout was not rejected without modifying its source'
        }
        $testCount++
    }

    $syscallHelper = @'
    fn deny_syscall(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: i64) {
        rules.insert(nr, vec![]); // empty rule vec = unconditional match
    }
'@
    foreach ($rule in @(
        @{ Syscall = 'socket'; Payload = 'deny_vsock.clone()' },
        @{ Syscall = 'socketpair'; Payload = 'deny_vsock' },
        @{ Syscall = 'socket'; Payload = 'unix_only_rule.clone()' },
        @{ Syscall = 'socketpair'; Payload = 'unix_only_rule' },
        @{ Syscall = 'socket'; Payload = 'deny_non_ip_socket' },
        @{ Syscall = 'socketpair'; Payload = 'deny_unix_socketpair' },
        @{ Syscall = 'socketpair'; Payload = 'deny_non_unix_socketpair' },
        @{ Syscall = 'socket'; Payload = 'renamed_rule.clone(), another_rule' }
    )) {
        foreach ($multiline in @($false, $true)) {
            $key = 'libc::SYS_' + $rule.Syscall
            $call = if ($multiline) {
                "            rules.insert(`r`n                $key,`r`n                vec![$($rule.Payload)],`r`n            );"
            } else {
                "            rules.insert($key, vec![$($rule.Payload)]);"
            }
            $root = New-Layout -Name ("sandbox-syscall-" + $testCount) -Files @{
                'linux-sandbox/src/landlock.rs' = ($syscallHelper + "`n" + $call)
            }
            Enable-I686MuslLinuxSandboxSyscallBuild -CodexRsDir $root | Out-Null
            $patched = [IO.File]::ReadAllText((Join-Path $root 'linux-sandbox/src/landlock.rs'))
            if (-not $patched.Contains($call.Replace($key, "$key.into()"))) {
                throw "Syscall key was not widened while preserving the complete $($rule.Payload) rule"
            }
            $testCount++
        }
    }
    $convertedCalls = @'
            rules.insert(libc::SYS_socket.into(), vec![deny_vsock.clone()]);
            rules.insert(libc::SYS_socketpair.into(), vec![deny_vsock]);
'@
    $root = New-Layout -Name 'sandbox-converted-keys' -Files @{
        'linux-sandbox/src/landlock.rs' = ($syscallHelper + "`n" + $convertedCalls)
    }
    Enable-I686MuslLinuxSandboxSyscallBuild -CodexRsDir $root | Out-Null
    $patched = [IO.File]::ReadAllText((Join-Path $root 'linux-sandbox/src/landlock.rs'))
    if (-not $patched.Contains($convertedCalls) -or $patched.Contains('.into().into()')) {
        throw 'Already converted socket keys were changed'
    }
    $testCount++
    foreach ($unsupportedCalls in @(
        '            renamed_rules.insert(libc::SYS_socket, vec![deny_vsock]);',
        "            rules.insert(libc::SYS_socket, vec![deny_vsock.clone()]);`n            rules.insert(libc::SYS_socketpair as _, vec![deny_vsock]);"
    )) {
        $original = $syscallHelper + "`n" + $unsupportedCalls
        $root = New-Layout -Name ("sandbox-unsupported-" + $testCount) -Files @{
            'linux-sandbox/src/landlock.rs' = $original
        }
        $rejected = $false
        try { Enable-I686MuslLinuxSandboxSyscallBuild -CodexRsDir $root | Out-Null }
        catch { $rejected = $_.Exception.Message.StartsWith('Linux sandbox socket syscall') }
        if (-not $rejected -or [IO.File]::ReadAllText((Join-Path $root 'linux-sandbox/src/landlock.rs')) -ne $original) {
            throw 'Unsupported syscall source was not rejected before writing changes'
        }
        $testCount++
    }

    $remote = New-Layout -Name 'checkout-remote' -Files @{
        'codex-rs/Cargo.toml' = "[workspace]`nmembers = []`n"
        '.gitignore' = "codex-rs/target/`n"
    }
    & git -C $remote init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed' }
    & git -C $remote add .
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git add failed' }
    & git -C $remote -c commit.gpgsign=false -c user.name='CI fixture' -c user.email='fixture@example.invalid' commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git commit failed' }
    $revision = (& git -C $remote rev-parse HEAD).Trim()
    foreach ($withCache in @($false, $true)) {
        $root = Join-Path $fixtureRoot ("checkout-" + $testCount)
        if ($withCache) {
            $root = New-Layout -Name ("checkout-" + $testCount) -Files @{ 'codex-rs/target/cache-sentinel' = 'preserved compiled artifact' }
        }
        Initialize-UpstreamCheckout -SourceDir $root -RemoteUrl $remote -Commit $revision
        if ((& git -C $root rev-parse HEAD).Trim() -ne $revision -or -not (Test-Path -LiteralPath (Join-Path $root 'codex-rs/Cargo.toml'))) {
            throw 'Upstream checkout did not materialize the exact source commit'
        }
        if ($withCache -and [IO.File]::ReadAllText((Join-Path $root 'codex-rs/target/cache-sentinel')) -ne 'preserved compiled artifact') {
            throw 'Restored target cache was lost'
        }
        $testCount++
    }
    foreach ($unexpected in @('user-file.txt', 'codex-rs/Cargo.toml')) {
        $root = New-Layout -Name ("checkout-refusal-" + $testCount) -Files @{ $unexpected = 'must remain unchanged' }
        $rejected = $false
        try { Initialize-UpstreamCheckout -SourceDir $root -RemoteUrl $remote -Commit $revision }
        catch { $rejected = $_.Exception.Message.Contains('unexpected source content') }
        if (-not $rejected -or [IO.File]::ReadAllText((Join-Path $root $unexpected)) -ne 'must remain unchanged' -or (Test-Path -LiteralPath (Join-Path $root '.git'))) {
            throw 'Unexpected non-cache source content was not preserved/rejected'
        }
        $testCount++
    }
    Write-Host "Passed $testCount upstream compatibility contract tests."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notlike 'codex-upstream-contract-*') {
        throw "Unsafe fixture cleanup path: $resolvedFixtureRoot"
    }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
