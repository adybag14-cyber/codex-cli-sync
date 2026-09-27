Set-StrictMode -Version Latest

function New-WindowsCodexPackage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$BinaryDir,
        [Parameter(Mandatory = $true)][string]$RipgrepPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$Target = 'x86_64-pc-windows-msvc'
    )

    $builder = Join-Path $SourceRoot 'scripts/build_codex_package.py'
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
        throw "Upstream canonical package builder is missing: $builder"
    }
    # All inputs are prebuilt; the upstream builder neither compiles nor downloads.
    # Do not pass --force: an occupied destination must not be deleted implicitly.
    $previousRepoRoot = $env:CODEX_REPO_ROOT
    try {
        $env:CODEX_REPO_ROOT = [IO.Path]::GetFullPath($SourceRoot)
        & python $builder --target $Target --variant codex --package-version $Version `
            --package-dir $Destination `
            --entrypoint-bin (Join-Path $BinaryDir 'codex.exe') `
            --code-mode-host-bin (Join-Path $BinaryDir 'codex-code-mode-host.exe') `
            --codex-command-runner-bin (Join-Path $BinaryDir 'codex-command-runner.exe') `
            --codex-windows-sandbox-setup-bin (Join-Path $BinaryDir 'codex-windows-sandbox-setup.exe') `
            --rg-bin $RipgrepPath | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Upstream canonical package builder failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $previousRepoRoot) { Remove-Item Env:CODEX_REPO_ROOT -ErrorAction SilentlyContinue }
        else { $env:CODEX_REPO_ROOT = $previousRepoRoot }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Destination 'codex-package.json') -Raw | ConvertFrom-Json
    if ($manifest.layoutVersion -ne 1 -or $manifest.version -ne $Version -or
        $manifest.target -ne $Target -or $manifest.variant -ne 'codex' -or
        $manifest.entrypoint -ne 'bin/codex.exe' -or
        $manifest.resourcesDir -ne 'codex-resources' -or $manifest.pathDir -ne 'codex-path') {
        throw 'Upstream package layout changed; review installer and smoke-test compatibility before publishing.'
    }
    return $manifest
}
