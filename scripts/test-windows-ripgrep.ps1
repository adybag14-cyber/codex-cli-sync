Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-WindowsRipgrep.ps1')
$originalGh = $env:GH_TOKEN
$originalGitHub = $env:GITHUB_TOKEN
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-ripgrep-contract-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Contract ($caught -and $caught.Contains($Message)) "Expected rejection: $Message"
}

try {
    $env:GH_TOKEN = ''
    $env:GITHUB_TOKEN = ''
    Assert-Contract (-not (Get-GitHubApiHeaders).ContainsKey('Authorization')) 'Anonymous local request was not supported'
    $env:GITHUB_TOKEN = 'fixture-actions-token'
    Assert-Contract ((Get-GitHubApiHeaders).Authorization -ceq 'Bearer fixture-actions-token') 'Actions token was not selected'
    $env:GH_TOKEN = 'fixture-gh-token'
    Assert-Contract ((Get-GitHubApiHeaders).Authorization -ceq 'Bearer fixture-gh-token') 'GH_TOKEN did not take precedence'

    New-Item -ItemType Directory -Path (Join-Path $fixture 'payload') -Force | Out-Null
    $fixtureExe = Join-Path $fixture 'payload/rg.exe'
    [IO.File]::WriteAllText($fixtureExe, 'fixture executable')
    $fixtureZip = Join-Path $fixture 'fixture.zip'
    Compress-Archive -LiteralPath $fixtureExe -DestinationPath $fixtureZip
    $fixtureHash = (Get-FileHash -LiteralPath $fixtureZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $release = [pscustomobject]@{
        tag_name = '15.2.0'
        assets = @([pscustomobject]@{
            name = 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
            digest = "sha256:$fixtureHash"
            browser_download_url = 'https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
        })
    }
    Assert-Contract ((Resolve-WindowsRipgrepAsset $release).Sha256 -ceq $fixtureHash) 'Valid asset digest was not resolved'
    $release.assets[0].digest = $null
    Assert-Rejected { Resolve-WindowsRipgrepAsset $release } 'must have a GitHub SHA-256 digest'
    $release.assets[0].digest = "sha256:$fixtureHash"
    $release.assets += $release.assets[0]
    Assert-Rejected { Resolve-WindowsRipgrepAsset $release } 'exactly one'
    $release.assets = @($release.assets[0])
    $originalUrl = $release.assets[0].browser_download_url
    $release.assets[0].browser_download_url = 'https://example.invalid/rg.zip'
    Assert-Rejected { Resolve-WindowsRipgrepAsset $release } 'does not match'
    $release.assets[0].browser_download_url = $originalUrl

    $downloads = 0
    $apiFailure = $false
    $invalidDownload = $false
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec)
        Assert-Contract ($Uri -ceq 'https://api.github.com/repos/BurntSushi/ripgrep/releases/latest') 'Wrong API endpoint'
        Assert-Contract ($Headers.Authorization -ceq 'Bearer fixture-gh-token') 'API request omitted authentication'
        if ($script:apiFailure) { throw 'fixture API unavailable' }
        return $script:release
    }
    function Invoke-WebRequest {
        param($Uri, $OutFile, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec)
        Assert-Contract (-not $Headers.ContainsKey('Authorization')) 'API token leaked to asset download'
        $script:downloads++
        if ($script:invalidDownload) { [IO.File]::WriteAllText($OutFile, 'damaged download') }
        else { Copy-Item -LiteralPath $script:fixtureZip -Destination $OutFile }
    }
    function Test-RipgrepExecutable {
        param($Path)
        Assert-Contract ((Get-Content -LiteralPath $Path -Raw) -ceq 'fixture executable') 'Wrong extracted executable'
    }

    $cache = Join-Path $fixture 'cache'
    $destination = Join-Path $fixture 'package-rg.exe'
    $first = Install-RipgrepWindowsX64 -DestinationPath $destination -CacheDirectory $cache
    Assert-Contract ($downloads -eq 1 -and $first.archive_sha256 -ceq $fixtureHash) 'Initial install did not verify the archive'
    $second = Install-RipgrepWindowsX64 -DestinationPath $destination -CacheDirectory $cache
    Assert-Contract ($downloads -eq 1 -and $second.executable_sha256 -ceq $first.executable_sha256) 'Valid cache was not reused'
    $archive = Join-Path (Join-Path $cache $fixtureHash) $release.assets[0].name
    [IO.File]::WriteAllText($archive, 'damaged cached archive')
    Install-RipgrepWindowsX64 -DestinationPath $destination -CacheDirectory $cache | Out-Null
    Assert-Contract ($downloads -eq 2) 'Corrupted cache was accepted'

    [IO.File]::WriteAllText($archive, 'damaged cache again')
    $invalidDownload = $true
    Assert-Rejected { Install-RipgrepWindowsX64 -DestinationPath $destination -CacheDirectory $cache } 'SHA-256 does not match'
    Assert-Contract ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $first.executable_sha256) 'Failed download replaced the packaged executable'
    Assert-Contract (@(Get-ChildItem -LiteralPath $cache -Recurse -Filter '*.partial').Count -eq 0) 'Partial download was retained'
    $apiFailure = $true
    Assert-Rejected { Install-RipgrepWindowsX64 -DestinationPath $destination -CacheDirectory $cache } 'API unavailable'
    Assert-Contract (@(Get-ChildItem -LiteralPath $cache -Recurse -Directory -Filter 'extract-*').Count -eq 0) 'Extraction directory was retained'
    Write-Host "Passed $passed Windows ripgrep acquisition contracts."
} finally {
    $env:GH_TOKEN = $originalGh
    $env:GITHUB_TOKEN = $originalGitHub
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\', '/') -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^codex-ripgrep-contract-[0-9a-f]{32}$') {
        throw "Unsafe contract cleanup path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
