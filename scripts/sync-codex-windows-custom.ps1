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

function Get-SingleLineSummary {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [int]$MaxLength = 1000
    )

    $summary = ($Text -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
    if ($summary.Length -gt $MaxLength) {
        return $summary.Substring(0, $MaxLength - 3) + "..."
    }
    return $summary
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

    if ($Ref -match '^[0-9a-fA-F]{40}$') {
        return $Ref.ToLowerInvariant()
    }

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

    $text = [System.IO.File]::ReadAllText($PackageJsonPath)
    $regex = [regex]::new('(?m)^(\s*"version"\s*:\s*")[^"]+(")')
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Unable to locate a single package.json version in $PackageJsonPath."
    }

    $updated = $regex.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Groups[1].Value + $Version + $match.Groups[2].Value
        },
        1
    )
    [System.IO.File]::WriteAllText($PackageJsonPath, $updated, [System.Text.UTF8Encoding]::new($false))
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

function Install-RustyV8WindowsArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $cargoLockPath = Join-Path $SourceDir "codex-rs\Cargo.lock"
    if (-not (Test-Path -LiteralPath $cargoLockPath -PathType Leaf)) {
        throw "Could not find the upstream Cargo.lock needed to resolve rusty_v8: $cargoLockPath"
    }

    $cargoLock = [System.IO.File]::ReadAllText($cargoLockPath)
    $v8Match = [regex]::Match(
        $cargoLock,
        '(?ms)^\[\[package\]\]\r?\nname = "v8"\r?\nversion = "(?<version>[^"]+)"'
    )
    if (-not $v8Match.Success) {
        throw "Could not resolve the locked v8 crate version from $cargoLockPath"
    }

    $v8Version = $v8Match.Groups['version'].Value
    $profile = "ptrcomp_sandbox_release"
    $releaseTag = "rusty-v8-v$v8Version"
    $baseUrl = "https://github.com/openai/codex/releases/download/$releaseTag"
    $artifactDir = Join-Path $WorkspaceDir "rusty-v8\$v8Version\$Target"
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

    $archiveName = "rusty_v8_${profile}_${Target}.lib.gz"
    $bindingName = "src_binding_${profile}_${Target}.rs"
    $checksumsName = "rusty_v8_${profile}_${Target}.sha256"
    $archivePath = Join-Path $artifactDir $archiveName
    $bindingPath = Join-Path $artifactDir $bindingName
    $checksumsPath = Join-Path $artifactDir $checksumsName

    if (-not (Test-Path -LiteralPath $checksumsPath -PathType Leaf)) {
        Download-File -Uri "$baseUrl/$checksumsName" -OutFile $checksumsPath
    }

    $checksumLines = @(Get-Content -LiteralPath $checksumsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($checksumLines.Count -ne 2) {
        throw "Expected exactly two rusty_v8 checksums in $checksumsPath, found $($checksumLines.Count)."
    }

    $expectedHashes = @{}
    foreach ($line in $checksumLines) {
        $checksumMatch = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>[^\\/]+)$')
        if (-not $checksumMatch.Success) {
            throw "Invalid rusty_v8 checksum line: $line"
        }
        $expectedHashes[$checksumMatch.Groups['name'].Value] = $checksumMatch.Groups['hash'].Value.ToLowerInvariant()
    }

    foreach ($asset in @(
        [pscustomobject]@{ Name = $archiveName; Path = $archivePath },
        [pscustomobject]@{ Name = $bindingName; Path = $bindingPath }
    )) {
        if (-not $expectedHashes.ContainsKey($asset.Name)) {
            throw "The rusty_v8 checksum manifest does not contain $($asset.Name)."
        }

        $needsDownload = -not (Test-Path -LiteralPath $asset.Path -PathType Leaf)
        if (-not $needsDownload) {
            $needsDownload = (Get-FileSha256 -Path $asset.Path) -ne $expectedHashes[$asset.Name]
        }
        if ($needsDownload) {
            Download-File -Uri "$baseUrl/$($asset.Name)" -OutFile $asset.Path
        }

        $actualHash = Get-FileSha256 -Path $asset.Path
        if ($actualHash -ne $expectedHashes[$asset.Name]) {
            throw "rusty_v8 checksum mismatch for $($asset.Name): expected $($expectedHashes[$asset.Name]), got $actualHash"
        }
    }

    Write-Host "Verified Codex rusty_v8 $v8Version artifacts for $Target."
    return [pscustomobject]@{
        Version       = $v8Version
        ReleaseTag    = $releaseTag
        ArchivePath   = $archivePath
        ArchiveName   = $archiveName
        ArchiveSha256 = $expectedHashes[$archiveName]
        BindingPath   = $bindingPath
        BindingName   = $bindingName
        BindingSha256 = $expectedHashes[$bindingName]
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
$releaseWorkspace = Join-Path $WorkspaceDir "custom-$upstreamShortSha"
$payloadName = "codex-windows-x64-custom-$upstreamShortSha"
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.zip"))
$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.manifest.json"))
$installScriptPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "install-custom-windows-x64.ps1"))

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
Write-ActionOutput -Name "has_bundle" -Value "false"
Write-ActionOutput -Name "patch_status" -Value "not_run"
Write-ActionOutput -Name "patch_error_summary" -Value ""

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
    Invoke-Git -WorkingDirectory $sourceDir -Args @("reset", "--hard")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("clean", "-ffdx", "-e", "codex-rs/target/")
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

try {
    & (Join-Path $scriptRoot "patch-codex-windows-custom.ps1") -SourceRoot $sourceDir
    if ($LASTEXITCODE -ne 0) {
        throw "Custom patch script failed with exit code $LASTEXITCODE."
    }

    Invoke-Git -WorkingDirectory $sourceDir -Args @("diff", "--check")
} catch {
    $patchErrorSummary = Get-SingleLineSummary -Text ([string]$_.Exception.Message)
    $failureManifest = [ordered]@{
        upstream_repo          = $UpstreamRepo
        upstream_ref           = $UpstreamRef
        upstream_sha           = $upstreamSha
        custom_version         = $customVersion
        windows_target         = $WindowsTarget
        generated_at_utc       = $generatedAt
        release_tag            = $releaseTag
        rolling_tag            = $rollingTag
        patch_status           = "failed"
        custom_patches_failed  = $true
        patch_error_summary    = $patchErrorSummary
        artifact               = $null
        release_note           = "CUSTOM PATCHES FAILED. No Codex binary was built or uploaded for this upstream SHA."
        patch_contract         = [ordered]@{
            required_outcome         = "Windows custom patches must apply before a binary can be published."
            login_callback           = "Expected registered OAuth redirect ports 1455 and 1457, with PermissionDenied fallback handling."
            openai_request_metadata  = "Expected content_item_kinds to be omitted from OpenAI request payloads while internal annotations remain available."
            code_mode_host           = "Expected codex-code-mode-host.exe to be built, packaged, and smoke-tested."
        }
        release_files          = @(
            [ordered]@{ name = [System.IO.Path]::GetFileName($manifestPath); sha256 = $null }
        )
    }

    Save-JsonFile -Path $manifestPath -Value $failureManifest
    Write-ActionOutput -Name "changed" -Value "true"
    Write-ActionOutput -Name "manifest_path" -Value $manifestPath
    Write-ActionOutput -Name "patch_status" -Value "failed"
    Write-ActionOutput -Name "patch_error_summary" -Value $patchErrorSummary
    Write-Host "CUSTOM PATCHES FAILED: $patchErrorSummary"
    Write-Host "Patch failure manifest created at $manifestPath"
    return
}

$rustyV8Artifacts = Install-RustyV8WindowsArtifacts -SourceDir $sourceDir -Target $WindowsTarget

Push-Location (Join-Path $sourceDir "codex-rs")
try {
    $compatibilityTest = "suite::client::openai_stateless_responses_requests_preserve_item_turn_metadata_across_turns"
    $previousRustMinStack = $env:RUST_MIN_STACK
    try {
        # Match upstream Windows CI so the aggregated core test binary does not overflow the
        # platform's smaller default test-thread stack before reaching the focused assertion.
        $env:RUST_MIN_STACK = "8388608"
        cargo test -p codex-core --test all $compatibilityTest -- --exact
        if ($LASTEXITCODE -ne 0) {
            throw "OpenAI request metadata compatibility test failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $previousRustMinStack) {
            Remove-Item Env:RUST_MIN_STACK -ErrorAction SilentlyContinue
        } else {
            $env:RUST_MIN_STACK = $previousRustMinStack
        }
    }

    $previousRustyV8Archive = $env:RUSTY_V8_ARCHIVE
    $previousRustyV8Binding = $env:RUSTY_V8_SRC_BINDING_PATH
    try {
        $env:RUSTY_V8_ARCHIVE = $rustyV8Artifacts.ArchivePath
        $env:RUSTY_V8_SRC_BINDING_PATH = $rustyV8Artifacts.BindingPath
        cargo build --release --target $WindowsTarget --bin codex --bin codex-command-runner --bin codex-windows-sandbox-setup --bin codex-code-mode-host
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $previousRustyV8Archive) {
            Remove-Item Env:RUSTY_V8_ARCHIVE -ErrorAction SilentlyContinue
        } else {
            $env:RUSTY_V8_ARCHIVE = $previousRustyV8Archive
        }
        if ($null -eq $previousRustyV8Binding) {
            Remove-Item Env:RUSTY_V8_SRC_BINDING_PATH -ErrorAction SilentlyContinue
        } else {
            $env:RUSTY_V8_SRC_BINDING_PATH = $previousRustyV8Binding
        }
    }
} finally {
    Pop-Location
}

$targetDir = Join-Path $sourceDir "codex-rs\target\$WindowsTarget\release"
$payloadRoot = Join-Path $releaseWorkspace $payloadName
$resourcesDir = Join-Path $payloadRoot "codex-resources"

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
Copy-RequiredBinary -Source (Join-Path $targetDir "codex-code-mode-host.exe") -Destination (Join-Path $resourcesDir "codex-code-mode-host.exe")
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

$codeModeHostHelp = & (Join-Path $resourcesDir "codex-code-mode-host.exe") --help
if ($LASTEXITCODE -ne 0) {
    throw "Packaged codex-code-mode-host.exe --help failed with exit code $LASTEXITCODE"
}
$codeModeHostHelpText = [string]::Join("`n", [string[]]$codeModeHostHelp)
if (-not $codeModeHostHelpText.Contains("--listen")) {
    throw "Packaged codex-code-mode-host.exe help did not include the expected --listen option."
}
Write-Host "Packaged codex-code-mode-host.exe smoke test passed."

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
    patch_status       = "applied"
    custom_patches_failed = $false
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
        login_callback_port        = "Registered OAuth redirect ports 1455 and 1457, with PermissionDenied fallback handling"
        openai_request_metadata    = "Preserve internal annotations while omitting unsupported content_item_kinds from OpenAI request payloads"
        code_mode_host             = "Bundled under codex-resources and smoke-tested with --help"
    }
    rusty_v8           = [ordered]@{
        version         = $rustyV8Artifacts.Version
        release_tag     = $rustyV8Artifacts.ReleaseTag
        archive_name    = $rustyV8Artifacts.ArchiveName
        archive_sha256  = $rustyV8Artifacts.ArchiveSha256
        binding_name    = $rustyV8Artifacts.BindingName
        binding_sha256  = $rustyV8Artifacts.BindingSha256
    }
    release_files      = @(
        [ordered]@{ name = [System.IO.Path]::GetFileName($bundlePath); sha256 = $bundleSha256 },
        [ordered]@{ name = [System.IO.Path]::GetFileName($manifestPath); sha256 = $null },
        [ordered]@{ name = [System.IO.Path]::GetFileName($installScriptPath); sha256 = Get-FileSha256 -Path $installScriptPath }
    )
}

Save-JsonFile -Path $manifestPath -Value $manifest
Save-JsonFile -Path $latestStatePath -Value $manifest
Set-Content -Path $latestShaPath -Value ($upstreamSha + "`n") -Encoding utf8

Write-ActionOutput -Name "changed" -Value "true"
Write-ActionOutput -Name "bundle_path" -Value $bundlePath
Write-ActionOutput -Name "manifest_path" -Value $manifestPath
Write-ActionOutput -Name "install_script_path" -Value $installScriptPath
Write-ActionOutput -Name "has_bundle" -Value "true"
Write-ActionOutput -Name "patch_status" -Value "applied"

Write-Host "Custom bundle created at $bundlePath"
