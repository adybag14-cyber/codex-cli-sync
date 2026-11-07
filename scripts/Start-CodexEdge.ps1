# Starts the selected custom CLI with its own local Edge MCP profile.
# This script deliberately has no param block so native CLI arguments pass through.
$ErrorActionPreference = 'Stop'
$configuration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'edge-launcher.json') -Raw | ConvertFrom-Json
$edgeArguments = @($args)
if ($edgeArguments | Where-Object { $_ -match '^--remote(?:=|$)|^--remote-auth-token-env(?:=|$)' }) {
    throw 'codex-edge starts a local CLI. Use codex-desktop for the desktop transport.'
}
if ($edgeArguments | Where-Object { $_ -in @('-p', '--profile') -or $_ -like '--profile=*' }) {
    throw 'codex-edge supplies its own profile. Use codex directly to select another profile.'
}
foreach ($path in @($configuration.cliPath, $configuration.nodePath, $configuration.mcpPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Edge CLI component is missing: $path" }
}
$profile = Join-Path $configuration.codexHome ($configuration.profileName + '.config.toml')
if (-not (Test-Path -LiteralPath $profile -PathType Leaf)) { throw "Edge CLI profile is missing: $profile" }
if ($env:CODEX_HOME -and [IO.Path]::GetFullPath($env:CODEX_HOME) -ne [IO.Path]::GetFullPath($configuration.codexHome)) {
    throw 'This Edge launcher was installed for a different CODEX_HOME. Reinstall it for the selected home.'
}

# The desktop pipe, verifier and executor identity belong to that host. None is
# needed by this independent, private-STDIO MCP service. Keep the user's own
# Codex home/login, model settings, hooks and other non-desktop configuration.
$previous = @{}
$removeExact = @(
    'CODEX_CLI_PATH', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE', 'CODEX_THREAD_ID',
    'CODEX_MCP_NODE_PATH', 'CODEX_APP_SERVER_FORCE_CLI', 'CODEX_APP_SERVER_USE_LOCAL_DAEMON',
    'CODEX_WINDOWS_REGISTERED_CORE', 'CODEX_WINDOWS_SANDBOX_PACKAGE_FAMILY',
    'CODEX_DESKTOP_BRIDGE_TRANSPORT_TOKEN'
)
$removeNames = @(Get-ChildItem Env: | Where-Object {
    $_.Name -match '^(BROWSER_USE_|CUA_REPL_|NODE_REPL_|SKY_CUA_|CODEX_APP_TOOLS_|CODEX_TASK_WORKSPACE_|PLAYWRIGHT_MCP_)' -or
    $_.Name -in $removeExact
} | Select-Object -ExpandProperty Name)
$previous['CODEX_HOME'] = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
$exitCode = 1
try {
    foreach ($name in $removeNames) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:CODEX_HOME = $configuration.codexHome
    if ($edgeArguments.Count -eq 1 -and $edgeArguments[0] -eq '--edge-status') {
        # Report only component identities and presence checks, never credentials.
        & $configuration.nodePath -e 'const names=Object.keys(process.env).filter(k=>/^(BROWSER_USE_ACCESS_|CODEX_APP_TOOLS_|CODEX_TASK_WORKSPACE_)/.test(k)); console.log(JSON.stringify({desktopContextVariablesPresent:names,transport:"stdio",browser:"msedge",profile:"isolated"}));'
        if ($LASTEXITCODE -ne 0) { throw 'Independent process environment check failed.' }
        & $configuration.cliPath login status
        $exitCode = $LASTEXITCODE
    } else {
        & $configuration.cliPath --profile $configuration.profileName @edgeArguments
        $exitCode = $LASTEXITCODE
    }
}
finally {
    foreach ($entry in $previous.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -LiteralPath ("Env:" + $entry.Key) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}
exit $exitCode
