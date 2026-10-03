# Resolve before rewriting Cargo.toml. A placeholder development workspace must
# never silently advertise 0.0.0 or a permanently hard-coded catalog version.
function Resolve-CodexCustomVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CargoTomlPath,
        [Parameter(Mandatory)][string]$UpstreamRef,
        [Parameter(Mandatory)][string]$RemoteUrl,
        [AllowEmptyCollection()][string[]]$TagLines,
        [DateTimeOffset]$Timestamp = [DateTimeOffset]::UtcNow
    )

    $text = [IO.File]::ReadAllText($CargoTomlPath)
    $sections = [regex]::Matches($text, '(?ms)^\[workspace\.package\][ \t]*\r?\n(?<body>.*?)(?=^\[|\z)')
    if ($sections.Count -ne 1) { throw 'Expected one upstream workspace.package section for version discovery.' }
    $versions = [regex]::Matches($sections[0].Groups['body'].Value, '(?m)^version[ \t]*=[ \t]*"(?<version>[^"]+)"[ \t]*(?:#[^\r\n]*)?\r?$')
    if ($versions.Count -ne 1) { throw 'Expected one upstream workspace version for version discovery.' }
    $workspaceVersion = $versions[0].Groups['version'].Value
    $preId = '(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    $semver = '(?<base>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:-' + $preId + '(?:\.' + $preId + ')*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
    if ($workspaceVersion -notmatch ('^' + $semver + '$')) { throw "Unsupported upstream workspace version '$workspaceVersion'." }
    $workspaceBase = $Matches.base
    $versionRef = $UpstreamRef -replace '^refs/tags/', ''
    $refBase = $null
    if ($versionRef -match ('^rust-v' + $semver + '$')) { $refBase = $Matches.base }
    elseif ($versionRef.StartsWith('rust-v', [StringComparison]::Ordinal)) { throw "Malformed upstream version tag '$UpstreamRef'." }
    if ($refBase -eq '0.0.0') { throw 'An explicit 0.0.0 tag cannot supply a useful custom version base.' }
    if ($refBase -and $workspaceBase -ne '0.0.0' -and $refBase -ne $workspaceBase) {
        throw "Upstream tag '$UpstreamRef' disagrees with workspace version '$workspaceVersion'."
    }
    $stableTag = $null
    if ($refBase) {
        $base = $refBase
        $source = 'upstream_ref'
    } elseif ($workspaceBase -ne '0.0.0') {
        $base = $workspaceBase
        $source = 'workspace_version'
    } else {
        if (-not $PSBoundParameters.ContainsKey('TagLines')) {
            $TagLines = @(& git ls-remote --tags $RemoteUrl 'rust-v*' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Upstream stable-tag discovery failed: $($TagLines -join ' ')" }
        }
        $stableVersions = @{}
        foreach ($line in $TagLines) {
            # Exclude prereleases, build metadata, peeled annotated-tag rows,
            # unrelated tags and historical 0.0.<timestamp> development builds.
            if ($line -match '^[0-9a-f]{40,64}\s+refs/tags/rust-v(?<v>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$') {
                $candidate = $Matches.v
                if ($candidate.StartsWith('0.0.', [StringComparison]::Ordinal)) { continue }
                $parsed = $null
                if (-not [version]::TryParse($candidate, [ref]$parsed)) { throw "Stable tag version '$candidate' is outside the supported numeric range." }
                $stableVersions[$candidate] = $parsed
            }
        }
        if ($stableVersions.Count -eq 0) { throw 'No upstream stable rust-v release tags found; refusing to guess a custom version.' }
        $latest = @($stableVersions.Values | Sort-Object -Descending)[0]
        if ($latest.Minor -eq [int]::MaxValue) { throw 'Cannot advance the upstream stable minor version.' }
        $stableTag = 'rust-v' + $latest.ToString()
        $base = '{0}.{1}.0' -f $latest.Major, ($latest.Minor + 1)
        $source = 'next_minor_after_latest_stable_tag'
    }
    $parsedBase = $null
    if (-not [version]::TryParse($base, [ref]$parsedBase)) { throw "Custom version base '$base' is outside the supported numeric range." }
    $stamp = $Timestamp.UtcDateTime.ToString('yyyyMMddHHmm', [Globalization.CultureInfo]::InvariantCulture)
    return [pscustomobject][ordered]@{
        custom_version = "$base-$stamp"
        base_version = $base
        source = $source
        latest_stable_tag = $stableTag
        upstream_workspace_version = $workspaceVersion
        upstream_ref = $UpstreamRef
        timestamp_utc = $Timestamp.UtcDateTime.ToString('o')
    }
}
