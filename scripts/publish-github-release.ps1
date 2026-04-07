[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [Parameter(Mandatory = $true)]
    [string]$TagName,
    [Parameter(Mandatory = $true)]
    [string]$ReleaseName,
    [Parameter(Mandatory = $true)]
    [string]$Body,
    [Parameter(Mandatory = $true)]
    [string[]]$Files,
    [string]$TargetCommitish = "main",
    [switch]$Prerelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    throw "GITHUB_TOKEN is required."
}

$resolvedFiles = @(
    $Files | ForEach-Object {
        $resolved = [System.IO.Path]::GetFullPath($_)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Release asset not found: $resolved"
        }

        $resolved
    }
)

function Get-GitHubHeaders {
    return @{
        "Authorization"        = "Bearer $env:GITHUB_TOKEN"
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "codex-cli-sync"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [AllowNull()]
        [object]$Payload,
        [switch]$AllowNotFound
    )

    $headers = Get-GitHubHeaders

    try {
        if ($null -ne $Payload) {
            $json = $Payload | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $json
        }

        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    } catch {
        $response = $_.Exception.Response
        if ($AllowNotFound -and $null -ne $response -and $response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            return $null
        }

        throw
    }
}

function Get-ReleaseByTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseTag
    )

    $escapedTag = [System.Uri]::EscapeDataString($ReleaseTag)
    $uri = "https://api.github.com/repos/$RepoName/releases/tags/$escapedTag"
    return Invoke-GitHubJson -Method "GET" -Uri $uri -AllowNotFound
}

function New-OrUpdateRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseTag,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseBody,
        [Parameter(Mandatory = $true)]
        [string]$Commitish,
        [Parameter(Mandatory = $true)]
        [bool]$IsPrerelease
    )

    $payload = @{
        tag_name         = $ReleaseTag
        target_commitish = $Commitish
        name             = $Name
        body             = $ReleaseBody
        draft            = $false
        prerelease       = $IsPrerelease
    }

    $existing = Get-ReleaseByTag -RepoName $RepoName -ReleaseTag $ReleaseTag
    if ($null -eq $existing) {
        $uri = "https://api.github.com/repos/$RepoName/releases"
        Write-Host "Creating release $ReleaseTag"
        return Invoke-GitHubJson -Method "POST" -Uri $uri -Payload $payload
    }

    $uri = "https://api.github.com/repos/$RepoName/releases/$($existing.id)"
    Write-Host "Updating release $ReleaseTag"
    return Invoke-GitHubJson -Method "PATCH" -Uri $uri -Payload $payload
}

function Remove-ReleaseAssetByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName,
        [Parameter(Mandatory = $true)]
        [object]$Release,
        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    $matchingAssets = @($Release.assets | Where-Object { [string]$_.name -eq $AssetName })
    foreach ($asset in $matchingAssets) {
        $uri = "https://api.github.com/repos/$RepoName/releases/assets/$($asset.id)"
        Write-Host "Deleting existing asset $AssetName"
        Invoke-GitHubJson -Method "DELETE" -Uri $uri | Out-Null
    }
}

function Get-UploadContentType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".json" { return "application/json" }
        ".zip" { return "application/zip" }
        default { return "application/octet-stream" }
    }
}

function Upload-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName,
        [Parameter(Mandatory = $true)]
        [object]$Release,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $assetName = [System.IO.Path]::GetFileName($Path)
    $matchingAssets = @($Release.assets | Where-Object { [string]$_.name -eq $assetName })
    if ($matchingAssets.Count -gt 0) {
        Remove-ReleaseAssetByName -RepoName $RepoName -Release $Release -AssetName $assetName
        Start-Sleep -Seconds 1
    }

    $uploadBase = [string]$Release.upload_url -replace "\{\?name,label\}$", ""
    $encodedName = [System.Uri]::EscapeDataString($assetName)
    $uploadUri = "$uploadBase?name=$encodedName"
    $headers = Get-GitHubHeaders
    $contentType = Get-UploadContentType -Path $Path

    Write-Host "Uploading $assetName"
    Invoke-RestMethod -Method "POST" -Uri $uploadUri -Headers $headers -ContentType $contentType -InFile $Path | Out-Null
}

$release = New-OrUpdateRelease `
    -RepoName $Repo `
    -ReleaseTag $TagName `
    -Name $ReleaseName `
    -ReleaseBody $Body `
    -Commitish $TargetCommitish `
    -IsPrerelease $Prerelease.IsPresent

foreach ($path in $resolvedFiles) {
    Upload-ReleaseAsset -RepoName $Repo -Release $release -Path $path
}

Write-Host "Release published: $($release.html_url)"
