[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CliPath,
    [string]$RuntimeDirectory,
    [string]$NodePath = (Get-Command node -ErrorAction Stop).Source,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\CodexCliSync\EdgeBrowser')
)
$ErrorActionPreference = 'Stop'
if (-not $RuntimeDirectory) {
    $bundled = Join-Path $PSScriptRoot 'edge-browser'
    $RuntimeDirectory = if (Test-Path -LiteralPath (Join-Path $bundled 'package-lock.json')) { $bundled } else {
        Join-Path $PSScriptRoot '..\tools\CodexEdgeBrowser'
    }
}
$cli = (Resolve-Path -LiteralPath $CliPath).Path
$node = (Resolve-Path -LiteralPath $NodePath).Path
$sourceRuntime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$sourceMcp = Join-Path $sourceRuntime 'node_modules\@playwright\mcp\cli.js'
if (-not (Test-Path -LiteralPath $sourceMcp -PathType Leaf)) {
    throw 'The pinned Edge MCP runtime is not installed. Run npm ci --omit=dev --ignore-scripts in tools/CodexEdgeBrowser or use the packaged runtime.'
}
$inspectionHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
try {
    $env:CODEX_HOME = [IO.Path]::GetFullPath($CodexHome)
    $existingServersJson = & $cli mcp list --json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the base MCP configuration.' }
}
finally {
    if ($null -eq $inspectionHome) { Remove-Item -LiteralPath 'Env:CODEX_HOME' -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $inspectionHome }
}
$existingServers = $existingServersJson | ConvertFrom-Json
$nodeVersion = & $node --version
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 20) { throw 'Node.js 20 or newer is required by the pinned Playwright runtime.' }
$edgeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
)
if (-not ($edgeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) { throw 'Microsoft Edge is not installed.' }

$profileName = 'codex-edge'
$homePath = [IO.Path]::GetFullPath($CodexHome)
New-Item -ItemType Directory -Path $homePath -Force | Out-Null
$profilePath = Join-Path $homePath ($profileName + '.config.toml')
$marker = '# Managed by Install-CodexEdge.ps1'
if ((Test-Path -LiteralPath $profilePath) -and -not ([IO.File]::ReadAllText($profilePath).StartsWith($marker))) {
    throw "An unmanaged profile already exists at $profilePath; it was not changed."
}
$versionDirectory = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
New-Item -ItemType Directory -Path $versionDirectory | Out-Null
foreach ($name in @('package.json', 'package-lock.json', 'node_modules')) {
    Copy-Item -LiteralPath (Join-Path $sourceRuntime $name) -Destination $versionDirectory -Recurse
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-CodexEdge.ps1') -Destination $versionDirectory
$mcp = Join-Path $versionDirectory 'node_modules\@playwright\mcp\cli.js'
$outputDirectory = Join-Path $homePath 'tmp\codex-edge-output'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
function ConvertTo-TomlPath([string]$Value) { return "'" + $Value.Replace('\','/') + "'" }
foreach ($value in @($node,$mcp,$outputDirectory)) { if ($value.Contains("'")) { throw 'A component path contains an unsupported single quote.' } }
$disabledSections = foreach ($server in $existingServers) {
    if ($server.name -notin @('node_repl','cua_repl','playwright','chrome-devtools')) { continue }
    # Disabled entries still require a valid transport during config parsing.
    # Copy only its public command or URL; never copy headers, tokens or env.
    $transportLine = if ($server.transport.type -eq 'stdio') {
        $value = [string]$server.transport.command
        if ($value.Contains("'")) { throw 'A disabled MCP command contains an unsupported single quote.' }
        'command = ' + (ConvertTo-TomlPath $value)
    } elseif ($server.transport.type -eq 'streamable_http') {
        $uri = [uri]$server.transport.url
        if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsoluteUri.Contains("'")) {
            throw 'A legacy browser server URL contains private parameters; automatic profile generation stopped.'
        }
        'url = ' + (ConvertTo-TomlPath $uri.AbsoluteUri)
    } else { throw 'Unknown browser MCP transport in base configuration.' }
    "[mcp_servers.$($server.name)]`n$transportLine`nenabled = false`n"
}
$text = @"
$marker
# Independent Edge uses a private STDIO child and an isolated browser context.
# Desktop-only integrations are disabled for this profile, not in base config.
[mcp_servers.codex_edge]
command = $(ConvertTo-TomlPath $node)
args = [$(ConvertTo-TomlPath $mcp), '--browser', 'msedge', '--headless', '--isolated', '--sandbox', '--output-dir', $(ConvertTo-TomlPath $outputDirectory)]
startup_timeout_sec = 30
tool_timeout_sec = 120
enabled = true

$($disabledSections -join "`n")

[plugins."unified-computer-use@openai-bundled"]
enabled = false
[plugins."computer-use@openai-bundled"]
enabled = false
[plugins."browser@openai-bundled"]
enabled = false
[plugins."browser-use@openai-bundled"]
enabled = false
"@
if (Test-Path -LiteralPath $profilePath) { Copy-Item -LiteralPath $profilePath -Destination (Join-Path $versionDirectory 'previous-profile.toml') }
[IO.File]::WriteAllText($profilePath, $text + "`n", [Text.UTF8Encoding]::new($false))
$metadata = @{cliPath=$cli;nodePath=$node;mcpPath=$mcp;codexHome=$homePath;profileName=$profileName}
[IO.File]::WriteAllText((Join-Path $versionDirectory 'edge-launcher.json'), ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$launcherPath = Join-Path ([IO.Path]::GetDirectoryName($cli)) 'codex-edge.ps1'
if (Test-Path -LiteralPath $launcherPath) { Copy-Item -LiteralPath $launcherPath -Destination (Join-Path $versionDirectory 'previous-codex-edge.ps1') }
$target = (Join-Path $versionDirectory 'Start-CodexEdge.ps1').Replace("'", "''")
[IO.File]::WriteAllText($launcherPath, "& '$target' @args`nexit `$LASTEXITCODE`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{command=$launcherPath;runtime=$versionDirectory;profile=$profilePath;cli=$cli;node=$node;browser='msedge';transport='stdio';desktopRequired=$false;browserProfile='isolated'} | ConvertTo-Json
