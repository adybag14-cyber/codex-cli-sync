[CmdletBinding()]
param(
    [string]$UpstreamRepo = "openai/codex",
    [ValidateSet("x64", "arm64")]
    [string]$WindowsArch = "x64",
    [string]$StateDir = (Join-Path $PSScriptRoot "..\state"),
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "..\out"),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$WorkspaceDir = [System.IO.Path]::GetFullPath($WorkspaceDir)

function Write-ActionOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Get-LatestRustAlphaRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $headers = @{
        "User-Agent" = "codex-cli-sync"
        "Accept"     = "application/vnd.github+json"
    }

    $uri = "https://api.github.com/repos/$Repo/releases?per_page=100&page=1"
    $response = Invoke-WebRequest -Headers $headers -Uri $uri
    $releases = @($response.Content | ConvertFrom-Json)
    $candidates = @()

    foreach ($release in $releases) {
        $match = [regex]::Match([string]$release.tag_name, "^rust-v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-alpha\.(?<alpha>\d+)$")
        if (-not $match.Success) {
            continue
        }

        $candidates += [pscustomobject]@{
            Release = $release
            Major   = [int64]$match.Groups["major"].Value
            Minor   = [int64]$match.Groups["minor"].Value
            Patch   = [int64]$match.Groups["patch"].Value
            Alpha   = [int64]$match.Groups["alpha"].Value
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No Rust alpha releases were found for $Repo."
    }

    return ($candidates | Sort-Object Major, Minor, Patch, Alpha | Select-Object -Last 1).Release
}

function Get-WindowsAssetPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Arch
    )

    switch ($Arch) {
        "x64" { return @("x86_64-pc-windows-msvc", "win32-x64") }
        "arm64" { return @("aarch64-pc-windows-msvc", "win32-arm64") }
        default { throw "Unsupported Windows architecture: $Arch" }
    }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null

$latestTagPath = Join-Path $StateDir "latest-alpha-tag.txt"
$latestStatePath = Join-Path $StateDir "latest-alpha.json"
$currentTag = ""
if (Test-Path $latestTagPath) {
    $currentTag = (Get-Content -Path $latestTagPath -Raw).Trim()
}

$release = Get-LatestRustAlphaRelease -Repo $UpstreamRepo
$releaseTag = [string]$release.tag_name
$releaseUrl = [string]$release.html_url
$generatedAt = [DateTime]::UtcNow.ToString("o")

Write-Host "Latest upstream Rust alpha tag: $releaseTag"

Write-ActionOutput -Name "changed" -Value "false"
Write-ActionOutput -Name "upstream_tag" -Value $releaseTag
Write-ActionOutput -Name "upstream_url" -Value $releaseUrl
Write-ActionOutput -Name "generated_at" -Value $generatedAt
Write-ActionOutput -Name "bundle_path" -Value ""
Write-ActionOutput -Name "manifest_path" -Value ""

if (-not $Force -and $currentTag -eq $releaseTag) {
    Write-Host "State already points at $releaseTag. Skipping download."
    return
}

$assetPatterns = Get-WindowsAssetPatterns -Arch $WindowsArch
$selectedAssets = @(
    $release.assets |
        Where-Object {
            $assetName = [string]$_.name
            if ($assetName -eq "install.ps1") {
                return $true
            }

            foreach ($pattern in $assetPatterns) {
                if ($assetName -like "*$pattern*") {
                    return $true
                }
            }

            return $false
        } |
        Sort-Object name
)

if ($selectedAssets.Count -eq 0) {
    throw "No Windows $WindowsArch assets were found on release $releaseTag."
}

$bundleBaseName = "codex-windows-$WindowsArch-latest-alpha"
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$bundleBaseName.zip"))
$releaseWorkspace = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir $releaseTag))
$payloadRoot = [System.IO.Path]::GetFullPath((Join-Path $releaseWorkspace "codex-windows-$WindowsArch-$releaseTag"))
$assetsDir = [System.IO.Path]::GetFullPath((Join-Path $payloadRoot "assets"))
$bundleManifestPath = [System.IO.Path]::GetFullPath((Join-Path $payloadRoot "manifest.json"))

if (Test-Path $releaseWorkspace) {
    Remove-Item -Recurse -Force $releaseWorkspace
}

if (Test-Path $bundlePath) {
    Remove-Item -Force $bundlePath
}

New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

$headers = @{
    "User-Agent" = "codex-cli-sync"
    "Accept"     = "application/octet-stream"
}

foreach ($asset in $selectedAssets) {
    $destination = Join-Path $assetsDir $asset.name
    Write-Host "Downloading $($asset.name)"
    Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $destination
}

$manifest = [ordered]@{
    upstream_repo       = $UpstreamRepo
    upstream_tag        = $releaseTag
    upstream_release    = $releaseUrl
    upstream_published  = [string]$release.published_at
    windows_arch        = $WindowsArch
    generated_at_utc    = $generatedAt
    asset_count         = $selectedAssets.Count
    assets              = @(
        $selectedAssets | ForEach-Object {
            [ordered]@{
                name                = [string]$_.name
                size                = [int64]$_.size
                digest              = [string]$_.digest
                browser_download_url = [string]$_.browser_download_url
                updated_at          = [string]$_.updated_at
            }
        }
    )
}

$manifestJson = $manifest | ConvertTo-Json -Depth 8
Set-Content -Path $bundleManifestPath -Value $manifestJson -Encoding utf8
Set-Content -Path $latestStatePath -Value $manifestJson -Encoding utf8
Set-Content -Path $latestTagPath -Value ($releaseTag + "`n") -Encoding utf8

Compress-Archive -Path $payloadRoot -DestinationPath $bundlePath -CompressionLevel Optimal

Write-ActionOutput -Name "changed" -Value "true"
Write-ActionOutput -Name "bundle_path" -Value $bundlePath
Write-ActionOutput -Name "manifest_path" -Value $latestStatePath

Write-Host "Bundle created at $bundlePath"
