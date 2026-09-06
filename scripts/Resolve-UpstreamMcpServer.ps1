# This historical crate needs a recursion-limit workaround only while it exists.
# Missing files in a still-declared crate must remain errors, not silent skips.
function Resolve-UpstreamMcpServerCrateRoot {
    param([Parameter(Mandatory = $true)][string]$CodexRsDir)

    $crateDir = Join-Path $CodexRsDir "mcp-server"
    $crateManifest = Join-Path $crateDir "Cargo.toml"
    $crateRoot = Join-Path $crateDir "src/lib.rs"
    $workspaceManifest = Join-Path $CodexRsDir "Cargo.toml"
    $workspaceLock = Join-Path $CodexRsDir "Cargo.lock"
    foreach ($required in @($workspaceManifest, $workspaceLock)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Cannot establish upstream MCP crate layout: missing $required"
        }
    }

    if (Test-Path -LiteralPath $crateDir) {
        foreach ($required in @($crateManifest, $crateRoot)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                throw "Incomplete upstream codex-mcp-server crate: missing $required"
            }
        }
        if ([IO.File]::ReadAllText($crateManifest) -notmatch '(?m)^\s*name\s*=\s*["'']codex-mcp-server["'']\s*(?:#.*)?$') {
            throw "Unexpected upstream package identity in $crateManifest"
        }
        return [IO.Path]::GetFullPath($crateRoot)
    }

    $manifests = @($workspaceManifest, $workspaceLock)
    $cliManifest = Join-Path $CodexRsDir "cli/Cargo.toml"
    if (Test-Path -LiteralPath $cliManifest -PathType Leaf) {
        $manifests += $cliManifest
    }
    foreach ($manifest in $manifests) {
        if ([IO.File]::ReadAllText($manifest) -match 'codex-mcp-server|["''](?:\./)?mcp-server(?:["'']|/)') {
            throw "Incomplete upstream MCP crate removal: $manifest still references mcp-server"
        }
    }

    Write-Host "Upstream removed codex-mcp-server completely; its recursion-limit workaround is not applicable."
    return $null
}
