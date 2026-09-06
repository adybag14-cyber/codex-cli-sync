[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-UpstreamMcpServer.ps1")

# Import only the pure patch functions, not the patcher's main source mutation.
$patchTokens = $null
$patchErrors = $null
$patchAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "patch-codex-windows-custom.ps1"), [ref]$patchTokens, [ref]$patchErrors)
if ($patchErrors.Count) { throw "Windows patcher has syntax errors: $patchErrors" }
foreach ($functionName in @('Get-Text', 'Set-Text', 'Insert-AfterOnce', 'Set-WindowsToolPermissionsBypass', 'Set-WindowsExecPolicyBypass')) {
    $definition = $patchAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $false)
    if (-not $definition) { throw "Missing patch function $functionName" }
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
    foreach ($signature in @(
        "    session: &Session,`n    cwd: &Path,",
        "    session: &Session,`n    environment_id: &str,`n    cwd: &std::path::Path,",
        "    session: &Session,`r`n    environment: &TurnEnvironment,`r`n    cwd: &PathUri,"
    )) {
        $rust = @"
pub(super) async fn apply_granted_turn_permissions(
$signature
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
    Write-Host "Passed $testCount upstream compatibility contract tests."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notlike 'codex-upstream-contract-*') {
        throw "Unsafe fixture cleanup path: $resolvedFixtureRoot"
    }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
