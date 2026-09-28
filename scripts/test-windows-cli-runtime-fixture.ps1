param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [string]$WorkspaceDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out/runtime-ci-fixture')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exercise the real runtime probe on hosted runners without another Rust build.
# This immutable pre-#9 fixture intentionally lacks visible debug subcommands;
# the actual release gate still uses --require-visible-debug on its fresh binary.
$fixtureTag = 'custom-windows-x64-814de47b69dd'
$fixtureName = 'codex-windows-x64-custom-814de47b69dd'
$expectedZipSha256 = 'fed496ab73a0185b373bb943ecf254e89dd6c88e6fd6277dd06656ac3abdf8d3'
$expectedVersion = '0.0.0-custom.202609270520'
$source = [IO.Path]::GetFullPath($SourceRoot)
$workspace = [IO.Path]::GetFullPath($WorkspaceDir)
if (Test-Path -LiteralPath $workspace) {
    throw "Refusing to overwrite an existing runtime fixture workspace: $workspace"
}
New-Item -ItemType Directory -Path $workspace | Out-Null
$zipPath = Join-Path $workspace 'fixture.zip'
$uri = "https://github.com/adybag14-cyber/codex-cli-sync/releases/download/$fixtureTag/$fixtureName.zip"
Invoke-WebRequest -Uri $uri -OutFile $zipPath -MaximumRetryCount 2
if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedZipSha256) {
    throw 'Published runtime fixture checksum does not match the pinned SHA-256.'
}
$expanded = Join-Path $workspace 'expanded'
Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded
$fixture = Join-Path $expanded $fixtureName
$version = (Get-Content -LiteralPath (Join-Path $fixture 'VERSION.txt') -Raw).Trim()
if ($version -ne $expectedVersion) {
    throw "Published runtime fixture version mismatch: $version"
}

# The historical archive has a flat entrypoint. Repack these exact binaries with
# the same canonical upstream generator used by the current release pipeline.
$binaryDir = Join-Path $workspace 'binaries'
New-Item -ItemType Directory -Path $binaryDir | Out-Null
Copy-Item -LiteralPath (Join-Path $fixture 'codex.exe') -Destination $binaryDir
foreach ($file in @('codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe')) {
    Copy-Item -LiteralPath (Join-Path $fixture "codex-resources/$file") -Destination $binaryDir
}
$package = Join-Path $workspace 'package'
. (Join-Path $PSScriptRoot 'New-WindowsCodexPackage.ps1')
New-WindowsCodexPackage -SourceRoot $source -BinaryDir $binaryDir `
    -RipgrepPath (Join-Path $fixture 'codex-resources/rg.exe') -Destination $package -Version $version | Out-Null
$reportPath = Join-Path $workspace 'runtime-checks.json'
& python (Join-Path $PSScriptRoot 'test-windows-cli-runtime.py') `
    --package $package --source-root $source --output $reportPath
if ($LASTEXITCODE -ne 0) {
    throw "Real packaged Windows runtime fixture failed with exit code $LASTEXITCODE"
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.daemonProbe.tokenElevated) {
    if ($report.daemonProbe.mode -ne 'elevated_rejection' -or $report.daemonProbe.lifecycleExercised -or
        $report.checks -notcontains 'isolated_daemon_rejects_elevated_start' -or
        $report.checks -notcontains 'isolated_daemon_remains_stopped') {
        throw 'Elevated runner did not verify and accurately report the daemon security rejection.'
    }
} elseif ($report.daemonProbe.mode -ne 'non_elevated_lifecycle' -or -not $report.daemonProbe.lifecycleExercised) {
    throw 'Non-elevated runner did not exercise the real daemon lifecycle.'
}
Write-Host "Verified published fixture $fixtureTag ($expectedZipSha256)."
Write-Host "Runtime report: $reportPath"
