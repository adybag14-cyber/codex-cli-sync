[CmdletBinding()]
param(
    [string]$UpstreamRepo = "openai/codex",
    [string]$UpstreamRef = "main",
    [string]$WindowsTarget = "x86_64-pc-windows-msvc",
    [string]$StateDir = (Join-Path $PSScriptRoot "..\state"),
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "..\out"),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$WorkspaceDir = [System.IO.Path]::GetFullPath($WorkspaceDir)
$scriptRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)

function Write-ActionOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [string]$WorkingDirectory = $PWD.Path
    )

    Push-Location $WorkingDirectory
    try {
        & git @Args
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Get-UpstreamHead {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $remote = "https://github.com/$Repo.git"
    $candidates = @(
        "refs/heads/$Ref",
        "refs/tags/$Ref",
        $Ref
    )

    foreach ($candidate in $candidates) {
        $output = & git ls-remote $remote $candidate
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-remote failed for $remote $candidate"
        }
        $line = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($line.Count -gt 0) {
            return ([string]$line[0]).Split("`t")[0]
        }
    }

    throw "Could not resolve upstream ref '$Ref' from $remote."
}

function Set-CargoWorkspaceVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CargoTomlPath,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $text = [System.IO.File]::ReadAllText($CargoTomlPath)
    $regex = [regex]::new('(?ms)(^\[workspace\.package\]\s*.*?^version\s*=\s*")[^"]+(")')
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Unable to locate a single [workspace.package] version in $CargoTomlPath."
    }

    $updated = $regex.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Groups[1].Value + $Version + $match.Groups[2].Value
        },
        1
    )
    [System.IO.File]::WriteAllText($CargoTomlPath, $updated, [System.Text.UTF8Encoding]::new($false))
}

function Set-PackageJsonVersionIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$PackageJsonPath,
        [Parameter(Mandatory = $true)][string]$Version
    )

    if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
        return
    }

    $json = Get-Content -Path $PackageJsonPath -Raw | ConvertFrom-Json
    $json.version = $Version
    $json | ConvertTo-Json -Depth 20 | Set-Content -Path $PackageJsonPath -Encoding utf8
}

function New-CustomVersion {
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmm")
    return "0.0.0-custom.$stamp"
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 20
    Set-Content -Path $Path -Value $json -Encoding utf8
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $headers = @{
        "Accept"               = "application/octet-stream"
        "User-Agent"           = "codex-cli-sync"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $OutFile
}

function Install-RipgrepWindowsX64 {
    param([Parameter(Mandatory = $true)][string]$DestinationPath)

    $headers = @{
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "codex-cli-sync"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/BurntSushi/ripgrep/releases/latest" -Headers $headers
    $asset = @($release.assets | Where-Object {
        [string]$_.name -match '^ripgrep-.*-x86_64-pc-windows-msvc\.zip$'
    } | Select-Object -First 1)

    if ($asset.Count -eq 0) {
        throw "Could not find a ripgrep x86_64-pc-windows-msvc release asset."
    }

    $downloadDir = Join-Path $WorkspaceDir "ripgrep"
    $zipPath = Join-Path $downloadDir ([string]$asset[0].name)
    $extractDir = Join-Path $downloadDir "extract"
    if (Test-Path -LiteralPath $downloadDir) {
        Remove-Item -Recurse -Force -LiteralPath $downloadDir
    }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    Download-File -Uri ([string]$asset[0].browser_download_url) -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $rg = Get-ChildItem -Path $extractDir -Recurse -Filter rg.exe | Select-Object -First 1
    if ($null -eq $rg) {
        throw "Downloaded ripgrep asset did not contain rg.exe."
    }

    Copy-Item -LiteralPath $rg.FullName -Destination $DestinationPath -Force
    & $DestinationPath --version | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged rg.exe did not run successfully."
    }
}

function Copy-RequiredBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Build output not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null

$generatedAt = [DateTime]::UtcNow.ToString("o")
$latestShaPath = Join-Path $StateDir "latest-custom-main-sha.txt"
$latestStatePath = Join-Path $StateDir "latest-custom-main.json"
$sourceDir = Join-Path $WorkspaceDir "codex-upstream"
$remoteUrl = "https://github.com/$UpstreamRepo.git"
$upstreamSha = Get-UpstreamHead -Repo $UpstreamRepo -Ref $UpstreamRef
$upstreamShortSha = $upstreamSha.Substring(0, 12)
$customVersion = New-CustomVersion
$releaseTag = "custom-windows-x64-$upstreamShortSha"
$rollingTag = "latest-windows-x64-custom"

Write-ActionOutput -Name "changed" -Value "false"
Write-ActionOutput -Name "upstream_repo" -Value $UpstreamRepo
Write-ActionOutput -Name "upstream_ref" -Value $UpstreamRef
Write-ActionOutput -Name "upstream_sha" -Value $upstreamSha
Write-ActionOutput -Name "upstream_short_sha" -Value $upstreamShortSha
Write-ActionOutput -Name "custom_version" -Value $customVersion
Write-ActionOutput -Name "release_tag" -Value $releaseTag
Write-ActionOutput -Name "rolling_tag" -Value $rollingTag
Write-ActionOutput -Name "generated_at" -Value $generatedAt
Write-ActionOutput -Name "bundle_path" -Value ""
Write-ActionOutput -Name "manifest_path" -Value ""
Write-ActionOutput -Name "install_script_path" -Value ""

$currentSha = ""
if (Test-Path -LiteralPath $latestShaPath -PathType Leaf) {
    $currentSha = (Get-Content -Path $latestShaPath -Raw).Trim()
}

Write-Host "Upstream $UpstreamRepo $UpstreamRef resolves to $upstreamSha."
if (-not $Force -and $currentSha -eq $upstreamSha) {
    Write-Host "State already points at $upstreamSha. Skipping custom build."
    return
}

if (Test-Path -LiteralPath (Join-Path $sourceDir ".git") -PathType Container) {
    Invoke-Git -WorkingDirectory $sourceDir -Args @("remote", "set-url", "origin", $remoteUrl)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("fetch", "--no-tags", "--depth", "1", "origin", $upstreamSha)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("checkout", "--detach", "FETCH_HEAD")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("reset", "--hard", "FETCH_HEAD")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("clean", "-ffdx", "-e", "codex-rs/target/")
} else {
    if (Test-Path -LiteralPath $sourceDir) {
        Remove-Item -Recurse -Force -LiteralPath $sourceDir
    }
    Invoke-Git -WorkingDirectory $WorkspaceDir -Args @("clone", "--no-tags", "--depth", "1", $remoteUrl, $sourceDir)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("fetch", "--no-tags", "--depth", "1", "origin", $upstreamSha)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("checkout", "--detach", "FETCH_HEAD")
}

Set-CargoWorkspaceVersion -CargoTomlPath (Join-Path $sourceDir "codex-rs\Cargo.toml") -Version $customVersion
Set-PackageJsonVersionIfPresent -PackageJsonPath (Join-Path $sourceDir "codex-cli\package.json") -Version $customVersion

& (Join-Path $scriptRoot "patch-codex-windows-custom.ps1") -SourceRoot $sourceDir
if ($LASTEXITCODE -ne 0) {
    throw "Custom patch script failed."
}

Invoke-Git -WorkingDirectory $sourceDir -Args @("diff", "--check")

Push-Location (Join-Path $sourceDir "codex-rs")
try {
    cargo build --release --target $WindowsTarget --bin codex --bin codex-command-runner --bin codex-windows-sandbox-setup
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$targetDir = Join-Path $sourceDir "codex-rs\target\$WindowsTarget\release"
$releaseWorkspace = Join-Path $WorkspaceDir "custom-$upstreamShortSha"
$payloadName = "codex-windows-x64-custom-$upstreamShortSha"
$payloadRoot = Join-Path $releaseWorkspace $payloadName
$resourcesDir = Join-Path $payloadRoot "codex-resources"
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.zip"))
$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.manifest.json"))
$installScriptPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "install-custom-windows-x64.ps1"))

if (Test-Path -LiteralPath $releaseWorkspace) {
    Remove-Item -Recurse -Force -LiteralPath $releaseWorkspace
}
if (Test-Path -LiteralPath $bundlePath) {
    Remove-Item -Force -LiteralPath $bundlePath
}
if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -Force -LiteralPath $manifestPath
}

New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
Copy-RequiredBinary -Source (Join-Path $targetDir "codex.exe") -Destination (Join-Path $payloadRoot "codex.exe")
Copy-RequiredBinary -Source (Join-Path $targetDir "codex-command-runner.exe") -Destination (Join-Path $resourcesDir "codex-command-runner.exe")
Copy-RequiredBinary -Source (Join-Path $targetDir "codex-windows-sandbox-setup.exe") -Destination (Join-Path $resourcesDir "codex-windows-sandbox-setup.exe")
Install-RipgrepWindowsX64 -DestinationPath (Join-Path $resourcesDir "rg.exe")
Set-Content -Path (Join-Path $payloadRoot "VERSION.txt") -Value ($customVersion + "`n") -Encoding utf8

$upstreamInstaller = Join-Path $sourceDir "scripts\install\install.ps1"
if (Test-Path -LiteralPath $upstreamInstaller -PathType Leaf) {
    Copy-Item -LiteralPath $upstreamInstaller -Destination $installScriptPath -Force
} else {
    Set-Content -Path $installScriptPath -Value "# Upstream install.ps1 was not present in this Codex revision.`n" -Encoding utf8
}

$versionOutput = & (Join-Path $payloadRoot "codex.exe") --version
if ($LASTEXITCODE -ne 0) {
    throw "Packaged codex.exe --version failed with exit code $LASTEXITCODE"
}
if (-not ([string]$versionOutput).Contains($customVersion)) {
    throw "Packaged codex.exe version '$versionOutput' did not include expected custom version '$customVersion'."
}
Write-Host "Packaged $versionOutput"

Compress-Archive -Path $payloadRoot -DestinationPath $bundlePath -CompressionLevel Optimal

$bundleSha256 = Get-FileSha256 -Path $bundlePath
$manifest = [ordered]@{
    upstream_repo      = $UpstreamRepo
    upstream_ref       = $UpstreamRef
    upstream_sha       = $upstreamSha
    custom_version     = $customVersion
    windows_target     = $WindowsTarget
    generated_at_utc   = $generatedAt
    release_tag        = $releaseTag
    rolling_tag        = $rollingTag
    artifact           = [ordered]@{
        name   = [System.IO.Path]::GetFileName($bundlePath)
        sha256 = $bundleSha256
    }
    patch_contract     = [ordered]@{
        approval_policy            = "AskForApproval::Never on Windows"
        runtime_permission_profile = "PermissionProfile::Disabled on Windows"
        windows_sandbox_mode       = "None on Windows"
        windows_sandbox_level      = "WindowsSandboxLevel::Disabled on Windows"
        windows_sandbox_setup      = "No-op on Windows"
        exec_approval_requirement  = "Skip with bypass_sandbox=true on Windows"
        tool_sandbox_escalation    = "UseDefault and preapproved on Windows"
    }
    release_files      = @(
        [ordered]@{ name = [System.IO.Path]::GetFileName($bundlePath); sha256 = $bundleSha256 },
        [ordered]@{ name = [System.IO.Path]::GetFileName($manifestPath); sha256 = "" },
        [ordered]@{ name = [System.IO.Path]::GetFileName($installScriptPath); sha256 = Get-FileSha256 -Path $installScriptPath }
    )
}

Save-JsonFile -Path $manifestPath -Value $manifest
$manifestHash = Get-FileSha256 -Path $manifestPath
$manifest.release_files[1].sha256 = $manifestHash
Save-JsonFile -Path $manifestPath -Value $manifest
Save-JsonFile -Path $latestStatePath -Value $manifest
Set-Content -Path $latestShaPath -Value ($upstreamSha + "`n") -Encoding utf8

Write-ActionOutput -Name "changed" -Value "true"
Write-ActionOutput -Name "bundle_path" -Value $bundlePath
Write-ActionOutput -Name "manifest_path" -Value $manifestPath
Write-ActionOutput -Name "install_script_path" -Value $installScriptPath

Write-Host "Custom bundle created at $bundlePath"
