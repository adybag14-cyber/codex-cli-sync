function Publish-CodexEdgeBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$WorkspaceDir
    )
    $ErrorActionPreference = 'Stop'
    $source = Join-Path $RepositoryRoot 'tools/CodexEdgeBrowser'
    $resources = Join-Path $PackageRoot 'codex-resources'
    $runtime = Join-Path $resources 'edge-browser'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    foreach ($name in @('package.json', 'package-lock.json')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $runtime
    }
    Push-Location -LiteralPath $runtime
    try {
        & npm ci --omit=dev --ignore-scripts | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Pinned standalone Edge runtime installation failed.' }
    }
    finally { Pop-Location }
    foreach ($name in @('Install-CodexEdge.ps1', 'Start-CodexEdge.ps1')) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot "scripts/$name") -Destination $resources
    }
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'docs/standalone-edge-cli.md') -Destination $resources
    $runtimeOutput = Join-Path $WorkspaceDir 'standalone-edge-checks'
    & python (Join-Path $RepositoryRoot 'scripts/test-codex-edge-runtime.py') --runtime $runtime --output $runtimeOutput | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Standalone Edge browser runtime checks failed.' }
    $runtimeReport = Get-Content -LiteralPath (Join-Path $runtimeOutput 'runtime-checks.json') -Raw | ConvertFrom-Json
    Copy-Item -LiteralPath (Join-Path $runtimeOutput 'runtime-checks.json') -Destination (Join-Path $PackageRoot 'edge-runtime-checks.json')
    $installReportPath = Join-Path $PackageRoot 'edge-installer-checks.json'
    & python (Join-Path $RepositoryRoot 'scripts/test-codex-edge-install.py') --runtime $runtime `
        --cli (Join-Path $PackageRoot 'bin/codex.exe') --output $installReportPath | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Standalone Edge installer checks failed.' }
    $installReport = Get-Content -LiteralPath $installReportPath -Raw | ConvertFrom-Json
    $package = Get-Content -LiteralPath (Join-Path $runtime 'node_modules/@playwright/mcp/package.json') -Raw | ConvertFrom-Json
    return [ordered]@{
        included = $true
        opt_in = $true
        package = '@playwright/mcp'
        version = $package.version
        lock_sha256 = (Get-FileHash -LiteralPath (Join-Path $runtime 'package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        node_minimum_major = 20
        browser = 'msedge'
        transport = 'stdio'
        isolated_browser_context = $true
        browser_sandbox_enabled = $true
        desktop_required = $false
        installer = 'codex-resources/Install-CodexEdge.ps1'
        runtime_checks_passed = $runtimeReport.passed
        installer_checks_passed = $installReport.passed
    }
}
