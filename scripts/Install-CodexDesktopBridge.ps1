[CmdletBinding()]
param(
    [string]$BridgeDirectory,
    [Parameter(Mandatory = $true)][string]$CliPath,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\CodexCliSync\DesktopBridge'),
    [string]$StateRoot = (Join-Path $env:USERPROFILE '.codex\desktop-bridge')
)

$ErrorActionPreference = 'Stop'
if (-not $BridgeDirectory) {
    $bundledBridge = Join-Path $PSScriptRoot 'desktop-bridge'
    $BridgeDirectory = if (Test-Path -LiteralPath (Join-Path $bundledBridge 'codex-desktop-bridge.exe')) {
        $bundledBridge
    } else {
        Join-Path $PSScriptRoot '..\out\desktop-bridge'
    }
}
$bridgeSource = Join-Path $BridgeDirectory 'codex-desktop-bridge.exe'
foreach ($path in @($CliPath, $bridgeSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required executable is missing: $path" }
}
$resolvedCli = (Resolve-Path -LiteralPath $CliPath).Path
if ([IO.Path]::GetExtension($resolvedCli) -ne '.exe') { throw 'CliPath must identify a native Codex executable.' }
$versionDirectory = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $versionDirectory -ErrorAction Stop | Out-Null
$installedBridge = Join-Path $versionDirectory 'codex-desktop-bridge.exe'
Copy-Item -LiteralPath $bridgeSource -Destination $installedBridge
$configuration = @{cliPath = $resolvedCli; stateRoot = [IO.Path]::GetFullPath($StateRoot)}
[IO.File]::WriteAllText((Join-Path $versionDirectory 'bridge.config.json'), ($configuration | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-CodexDesktopWithBridge.ps1') -Destination $versionDirectory

# Install an explicit opt-in command next to the selected custom CLI. The normal
# codex executable, PATH, desktop shortcut, plugin manifests and browser policies
# are not changed. A newly installed CLI needs this installer run for its bin.
$escapedBridge = $installedBridge.Replace("'", "''")
$launcher = "& '$escapedBridge' --bridge-connect @args`nexit `$LASTEXITCODE`n"
$launcherPath = Join-Path ([IO.Path]::GetDirectoryName($resolvedCli)) 'codex-desktop.ps1'
if (Test-Path -LiteralPath $launcherPath) {
    Copy-Item -LiteralPath $launcherPath -Destination (Join-Path $versionDirectory 'previous-codex-desktop.ps1')
}
[IO.File]::WriteAllText($launcherPath, $launcher, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    bridge = $installedBridge
    cli = $resolvedCli
    terminalCommand = $launcherPath
    desktopLauncher = (Join-Path $versionDirectory 'Start-CodexDesktopWithBridge.ps1')
    activation = 'Quit the desktop app, then run desktopLauncher. Run codex-desktop in a fresh terminal.'
    rollback = 'Quit the desktop app and reopen its normal shortcut. No persistent desktop environment override was installed.'
} | ConvertTo-Json
