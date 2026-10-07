function Get-GitHubApiHeaders {
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'codex-cli-sync'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers.Authorization = "Bearer $token"
    }
    return $headers
}

function Resolve-WindowsRipgrepAsset {
    param([Parameter(Mandatory)][object]$Release)
    $assets = @($Release.assets | Where-Object {
        $_.name -cmatch '^ripgrep-[0-9][A-Za-z0-9.+-]*-x86_64-pc-windows-msvc\.zip$'
    })
    if ($assets.Count -ne 1) {
        throw 'Expected exactly one ripgrep x86_64-pc-windows-msvc ZIP asset.'
    }
    $asset = $assets[0]
    if (-not $asset.PSObject.Properties['digest'] -or
        [string]$asset.digest -cnotmatch '^sha256:(?<hash>[0-9a-f]{64})$') {
        throw 'Ripgrep release asset must have a GitHub SHA-256 digest.'
    }
    $sha256 = $Matches.hash
    if ([string]$Release.tag_name -cnotmatch '^v?[0-9][A-Za-z0-9.+-]*$') {
        throw 'Unexpected ripgrep release tag.'
    }
    $url = "https://github.com/BurntSushi/ripgrep/releases/download/$($Release.tag_name)/$($asset.name)"
    if ([string]$asset.browser_download_url -cne $url) {
        throw 'Ripgrep asset URL does not match the selected release.'
    }
    return [pscustomobject]@{
        Name = [string]$asset.name
        Tag = [string]$Release.tag_name
        Url = $url
        Sha256 = $sha256
    }
}

function Test-RipgrepExecutable {
    param([Parameter(Mandatory)][string]$Path)
    & $Path --version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Downloaded rg.exe did not run successfully.' }
}

function Install-RipgrepWindowsX64 {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$CacheDirectory
    )
    # Authenticate only this API request. Never forward its bearer token to a
    # release download or its redirected asset-storage host.
    $request = @{
        Uri = 'https://api.github.com/repos/BurntSushi/ripgrep/releases/latest'
        Headers = Get-GitHubApiHeaders
        TimeoutSec = 60
        MaximumRetryCount = 2
        RetryIntervalSec = 2
    }
    $asset = Resolve-WindowsRipgrepAsset -Release (Invoke-RestMethod @request)
    $cache = [IO.Path]::GetFullPath($CacheDirectory)
    $assetDirectory = Join-Path $cache $asset.Sha256
    New-Item -ItemType Directory -Force -Path $assetDirectory | Out-Null
    $archive = Join-Path $assetDirectory $asset.Name
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.Sha256) {
        $partial = Join-Path $assetDirectory ("download-" + [guid]::NewGuid().ToString('N') + '.partial')
        try {
            $download = @{
                Uri = $asset.Url
                OutFile = $partial
                Headers = @{ 'User-Agent' = 'codex-cli-sync' }
                TimeoutSec = 120
                MaximumRetryCount = 2
                RetryIntervalSec = 2
            }
            Invoke-WebRequest @download
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.Sha256) {
                throw 'Ripgrep archive SHA-256 does not match its release asset digest.'
            }
            Move-Item -LiteralPath $partial -Destination $archive -Force
        } finally {
            if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force }
        }
    }

    $extract = [IO.Path]::GetFullPath((Join-Path $assetDirectory ('extract-' + [guid]::NewGuid().ToString('N'))))
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $extract
        $executables = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter rg.exe)
        if ($executables.Count -ne 1) { throw 'Ripgrep ZIP must contain exactly one rg.exe.' }
        Test-RipgrepExecutable -Path $executables[0].FullName
        Copy-Item -LiteralPath $executables[0].FullName -Destination $DestinationPath -Force
    } finally {
        # This invocation owns only this generated extraction directory.
        if ([IO.Path]::GetDirectoryName($extract) -cne $assetDirectory -or
            [IO.Path]::GetFileName($extract) -cnotmatch '^extract-[0-9a-f]{32}$') {
            throw "Unsafe ripgrep extraction cleanup path: $extract"
        }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    }
    return [ordered]@{
        release_tag = $asset.Tag
        asset_name = $asset.Name
        archive_sha256 = $asset.Sha256
        executable_sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
