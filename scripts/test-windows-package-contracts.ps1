[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'New-WindowsCodexPackage.ps1')
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$root = Join-Path $tempPrefix ('codex-package-contract-' + [guid]::NewGuid().ToString('N'))
try {
    $binaryDir = Join-Path $root 'inputs'
    [IO.Directory]::CreateDirectory($binaryDir) | Out-Null
    foreach ($name in @('codex.exe', 'codex-code-mode-host.exe', 'codex-exec-server.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe', 'rg.exe')) {
        [IO.File]::WriteAllText((Join-Path $binaryDir $name), "NONEXECUTABLE DISPOSABLE INPUT $name")
    }
    $arguments = @{ BinaryDir = $binaryDir; RipgrepPath = (Join-Path $binaryDir 'rg.exe'); Version = '0.161.0-202610031234' }
    New-WindowsCodexPackage -SourceRoot $SourceRoot -Destination (Join-Path $root 'real-package') @arguments | Out-Null
    if (Test-UpstreamExecServerPackage -SourceRoot $SourceRoot) {
        $execServer = Join-Path $binaryDir 'codex-exec-server.exe'
        $saved = [IO.File]::ReadAllBytes($execServer)
        Remove-Item -LiteralPath $execServer
        $rejected = $false
        try { New-WindowsCodexPackage -SourceRoot $SourceRoot -Destination (Join-Path $root 'missing-exec-input') @arguments | Out-Null }
        catch { $rejected = $_.Exception.Message.Contains('requires a prebuilt codex-exec-server.exe') }
        [IO.File]::WriteAllBytes($execServer, $saved)
        if (-not $rejected) { throw 'Missing prebuilt exec-server was not rejected before assembly.' }
    }

    $fakeSource = Join-Path $root 'changed-builder'
    [IO.Directory]::CreateDirectory((Join-Path $fakeSource 'scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fakeSource 'scripts/codex_package')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeSource 'scripts/codex_package/cli.py'), 'parser.add_argument("--entrypoint-bin", type=str)')
    $builder = @'
import json
from pathlib import Path
import shutil
import sys
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
root = Path(args['--package-dir'])
files = {
    'bin/codex.exe': '--entrypoint-bin',
    'bin/codex-code-mode-host.exe': '--code-mode-host-bin',
    'codex-resources/codex-command-runner.exe': '--codex-command-runner-bin',
    'codex-resources/codex-windows-sandbox-setup.exe': '--codex-windows-sandbox-setup-bin',
    'codex-path/rg.exe': '--rg-bin',
}
if '--exec-server-bin' in args:
    files['bin/codex-exec-server.exe'] = '--exec-server-bin'
for relative, flag in files.items():
    output = root / relative
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args[flag], output)
(root / 'codex-package.json').write_text(json.dumps({
    'layoutVersion': 1, 'version': args['--package-version'], 'target': args['--target'],
    'variant': 'codex', 'entrypoint': 'bin/codex.exe', 'resourcesDir': 'codex-resources', 'pathDir': 'codex-path',
    **({'execServer': 'bin/codex-exec-server.exe'} if '--exec-server-bin' in args else {}),
}))
CHANGED_BEHAVIOR
'@
    foreach ($case in @(
        @{ Name = 'tampered-binary'; Change = "(root / 'bin/codex.exe').write_bytes(b'changed by upstream builder')" },
        @{ Name = 'missing-host'; Change = "(root / 'bin/codex-code-mode-host.exe').unlink()" }
    )) {
        [IO.File]::WriteAllText((Join-Path $fakeSource 'scripts/build_codex_package.py'), $builder.Replace('CHANGED_BEHAVIOR', $case.Change))
        $rejected = $false
        try { New-WindowsCodexPackage -SourceRoot $fakeSource -Destination (Join-Path $root $case.Name) @arguments | Out-Null }
        catch { $rejected = $_.Exception.Message.Contains('changed the required binary or its path') }
        if (-not $rejected) { throw "Package builder drift was not rejected: $($case.Name)" }
    }
    [IO.Directory]::CreateDirectory((Join-Path $fakeSource 'scripts/codex_package')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeSource 'scripts/codex_package/cli.py'), 'parser.add_argument("--exec-server-bin", type=str)')
    foreach ($case in @(
        @{ Name = 'tampered-exec-server'; Change = "(root / 'bin/codex-exec-server.exe').write_bytes(b'tampered')" },
        @{ Name = 'missing-exec-server'; Change = "(root / 'bin/codex-exec-server.exe').unlink()" }
    )) {
        [IO.File]::WriteAllText((Join-Path $fakeSource 'scripts/build_codex_package.py'), $builder.Replace('CHANGED_BEHAVIOR', $case.Change))
        $rejected = $false
        try { New-WindowsCodexPackage -SourceRoot $fakeSource -Destination (Join-Path $root $case.Name) @arguments | Out-Null }
        catch { $rejected = $_.Exception.Message.Contains('changed the required binary or its path') }
        if (-not $rejected) { throw "Exec-server builder drift was not rejected: $($case.Name)" }
    }
    [IO.File]::WriteAllText((Join-Path $fakeSource 'scripts/build_codex_package.py'), $builder.Replace('CHANGED_BEHAVIOR', "import subprocess; subprocess.run([args['--cargo']], check=True)"))
    $rejected = $false
    try { New-WindowsCodexPackage -SourceRoot $fakeSource -Destination (Join-Path $root 'unexpected-build') @arguments | Out-Null }
    catch { $rejected = $_.Exception.Message.Contains('canonical package builder failed') }
    if (-not $rejected) { throw 'Unexpected source compilation during assembly was not blocked.' }
    Write-Host 'Passed package builder contracts: real upstream, required prebuilt inputs, and binary identity checks.'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    if (-not $resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedRoot) -notmatch '^codex-package-contract-[0-9a-f]{32}$') { throw 'Unsafe package fixture cleanup.' }
    if ([IO.Directory]::Exists($resolvedRoot)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
