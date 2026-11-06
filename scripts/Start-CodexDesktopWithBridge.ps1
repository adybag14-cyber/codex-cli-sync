[CmdletBinding()]
param([string]$DesktopPath)

$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'codex-desktop-bridge.exe'
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    throw 'Run the copy of this launcher installed beside codex-desktop-bridge.exe.'
}
if (-not $DesktopPath) {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) { throw 'The installed OpenAI desktop package was not found. Supply -DesktopPath explicitly.' }
    $DesktopPath = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
}
$resolvedDesktop = (Resolve-Path -LiteralPath $DesktopPath).Path
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" |
    Where-Object { $_.ExecutablePath -eq $resolvedDesktop })
if ($running.Count -gt 0) {
    throw 'The desktop app is already running. Quit it fully first; this launcher does not terminate open tasks.'
}
$previousCli = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')
$previousForce = [Environment]::GetEnvironmentVariable('CODEX_APP_SERVER_FORCE_CLI', 'Process')
try {
    # The desktop's supported executable override starts the real shared server
    # as its child. The desktop itself supplies its browser host environment.
    $env:CODEX_CLI_PATH = $bridge
    $env:CODEX_APP_SERVER_FORCE_CLI = '1'
    $process = Start-Process -FilePath $resolvedDesktop -PassThru -WindowStyle Hidden
    [pscustomobject]@{desktopPid = $process.Id; bridge = $bridge} | ConvertTo-Json -Compress
}
finally {
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $previousCli, 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_APP_SERVER_FORCE_CLI', $previousForce, 'Process')
}
