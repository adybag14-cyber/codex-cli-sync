[CmdletBinding()]
param(
    [string]$UpstreamRepo = "openai/codex",
    [string]$UpstreamRef = "main",
    [string]$LinuxTarget = "i686-unknown-linux-musl",
    [string]$StateDir = (Join-Path $PSScriptRoot "..\state"),
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "..\out"),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($LinuxTarget -ne "i686-unknown-linux-musl") {
    throw "Unsupported Linux target: $LinuxTarget"
}

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$WorkspaceDir = [System.IO.Path]::GetFullPath($WorkspaceDir)

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

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Enable-I686MuslVendoredOpenSsl {
    param([Parameter(Mandatory = $true)][string]$CargoTomlPath)

    $text = [System.IO.File]::ReadAllText($CargoTomlPath)
    if ($text -match '\[target\.i686-unknown-linux-musl\.dependencies\][\s\S]*?openssl-sys\s*=') {
        return $false
    }

    $addition = @'

# Build OpenSSL from source for 32-bit musl builds.
[target.i686-unknown-linux-musl.dependencies]
openssl-sys = { workspace = true, features = ["vendored"] }
'@

    [System.IO.File]::WriteAllText(
        $CargoTomlPath,
        $text.TrimEnd() + $addition + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $true
}

function New-ZigMuslCompilerWrappers {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        throw "zig is required to cross-build $LinuxTarget."
    }

    New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
    $cc = Join-Path $ToolRoot "zigcc"
    $cxx = Join-Path $ToolRoot "zigcxx"

    $ccText = @'
#!/usr/bin/env bash
set -euo pipefail

args=()
skip_next=0
pending_include=0
for arg in "$@"; do
  if [[ "${pending_include}" -eq 1 ]]; then
    pending_include=0
    if [[ "${arg}" == /usr/include || "${arg}" == /usr/include/* ]]; then
      args+=("-idirafter" "${arg}")
    else
      args+=("-I" "${arg}")
    fi
    continue
  fi

  if [[ "${skip_next}" -eq 1 ]]; then
    skip_next=0
    continue
  fi

  case "${arg}" in
    --target)
      skip_next=1
      continue
      ;;
    --target=*|-target=*|-target)
      if [[ "${arg}" == "-target" ]]; then
        skip_next=1
      fi
      continue
      ;;
    -I)
      pending_include=1
      continue
      ;;
    -I/usr/include|-I/usr/include/*)
      args+=("-idirafter" "${arg#-I}")
      continue
      ;;
    -Wp,-U_FORTIFY_SOURCE)
      args+=("-U_FORTIFY_SOURCE")
      continue
      ;;
  esac
  args+=("${arg}")
done

exec zig cc -target i686-linux-musl "${args[@]}" -fno-sanitize=undefined
'@

    $cxxText = $ccText -replace 'exec zig cc -target i686-linux-musl', 'exec zig c++ -target i686-linux-musl'

    Set-Content -Path $cc -Value $ccText -Encoding utf8
    Set-Content -Path $cxx -Value $cxxText -Encoding utf8
    & chmod +x $cc $cxx
    if ($LASTEXITCODE -ne 0) {
        throw "chmod failed for Zig compiler wrappers."
    }

    return [pscustomobject]@{
        Cc  = [System.IO.Path]::GetFullPath($cc)
        Cxx = [System.IO.Path]::GetFullPath($cxx)
    }
}

function Set-I686MuslBuildEnvironment {
    param([Parameter(Mandatory = $true)][object]$Wrappers)

    $env:CC = $Wrappers.Cc
    $env:CXX = $Wrappers.Cxx
    $env:TARGET_CC = $Wrappers.Cc
    $env:TARGET_CXX = $Wrappers.Cxx
    $env:CC_i686_unknown_linux_musl = $Wrappers.Cc
    $env:CXX_i686_unknown_linux_musl = $Wrappers.Cxx
    $env:CARGO_TARGET_I686_UNKNOWN_LINUX_MUSL_LINKER = $Wrappers.Cc
    $env:CMAKE_C_COMPILER = $Wrappers.Cc
    $env:CMAKE_CXX_COMPILER = $Wrappers.Cxx
    $env:CFLAGS = "-pthread"
    $env:CXXFLAGS = "-pthread"
    $env:CMAKE_ARGS = "-DCMAKE_HAVE_THREADS_LIBRARY=1 -DCMAKE_USE_PTHREADS_INIT=1 -DCMAKE_THREAD_LIBS_INIT=-pthread -DTHREADS_PREFER_PTHREAD_FLAG=ON"
    $env:OPENSSL_STATIC = "1"
    $env:AWS_LC_SYS_NO_JITTER_ENTROPY = "1"
    $env:PKG_CONFIG_ALLOW_CROSS = "1"

    $rustFlags = "-C target-feature=+crt-static -C strip=symbols"
    if ([string]::IsNullOrWhiteSpace($env:RUSTFLAGS)) {
        $env:RUSTFLAGS = $rustFlags
    } else {
        $env:RUSTFLAGS = "$($env:RUSTFLAGS) $rustFlags"
    }
}

function Get-CaCertificatesBundle {
    $candidates = @(
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "Could not find a system CA certificates bundle to include."
}

function Invoke-TarGzip {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -Force -LiteralPath $ArchivePath
    }

    Push-Location $WorkingDirectory
    try {
        & tar -czf $ArchivePath $EntryName
        if ($LASTEXITCODE -ne 0) {
            throw "tar failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null

$generatedAt = [DateTime]::UtcNow.ToString("o")
$latestShaPath = Join-Path $StateDir "latest-linux-i686-musl-sha.txt"
$latestStatePath = Join-Path $StateDir "latest-linux-i686-musl.json"
$sourceDir = Join-Path $WorkspaceDir "codex-upstream-linux-i686"
$remoteUrl = "https://github.com/$UpstreamRepo.git"
$upstreamSha = Get-UpstreamHead -Repo $UpstreamRepo -Ref $UpstreamRef
$upstreamShortSha = $upstreamSha.Substring(0, 12)
$releaseTag = "linux-i686-musl-$upstreamShortSha"
$rollingTag = "latest-linux-i686-musl"
$payloadName = "codex-linux-i686-musl-$upstreamShortSha"
$releaseWorkspace = Join-Path $WorkspaceDir "linux-i686-musl-$upstreamShortSha"
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.tar.gz"))
$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.manifest.json"))

Write-ActionOutput -Name "changed" -Value "false"
Write-ActionOutput -Name "upstream_repo" -Value $UpstreamRepo
Write-ActionOutput -Name "upstream_ref" -Value $UpstreamRef
Write-ActionOutput -Name "upstream_sha" -Value $upstreamSha
Write-ActionOutput -Name "upstream_short_sha" -Value $upstreamShortSha
Write-ActionOutput -Name "linux_target" -Value $LinuxTarget
Write-ActionOutput -Name "release_tag" -Value $releaseTag
Write-ActionOutput -Name "rolling_tag" -Value $rollingTag
Write-ActionOutput -Name "generated_at" -Value $generatedAt
Write-ActionOutput -Name "bundle_path" -Value ""
Write-ActionOutput -Name "manifest_path" -Value ""
Write-ActionOutput -Name "version_output" -Value ""

$currentSha = ""
if (Test-Path -LiteralPath $latestShaPath -PathType Leaf) {
    $currentSha = (Get-Content -Path $latestShaPath -Raw).Trim()
}

Write-Host "Upstream $UpstreamRepo $UpstreamRef resolves to $upstreamSha."
if (-not $Force -and $currentSha -eq $upstreamSha) {
    Write-Host "State already points at $upstreamSha. Skipping Linux i686 musl build."
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

$cliCargoTomlPath = Join-Path $sourceDir "codex-rs/cli/Cargo.toml"
$addedVendoredOpenSsl = Enable-I686MuslVendoredOpenSsl -CargoTomlPath $cliCargoTomlPath
$wrappers = New-ZigMuslCompilerWrappers -ToolRoot (Join-Path $WorkspaceDir "i686-musl-tools")
Set-I686MuslBuildEnvironment -Wrappers $wrappers

Push-Location (Join-Path $sourceDir "codex-rs")
try {
    cargo build --release --target $LinuxTarget --bin codex
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$targetDir = Join-Path $sourceDir "codex-rs/target/$LinuxTarget/release"
$codexPath = Join-Path $targetDir "codex"
if (-not (Test-Path -LiteralPath $codexPath -PathType Leaf)) {
    throw "Build output not found: $codexPath"
}

& chmod 0755 $codexPath
if ($LASTEXITCODE -ne 0) {
    throw "chmod failed for built codex binary."
}

$fileOutput = ""
if (Get-Command file -ErrorAction SilentlyContinue) {
    $fileOutput = [string](& file $codexPath)
    Write-Host $fileOutput
}

$versionOutput = [string](& $codexPath --version)
if ($LASTEXITCODE -ne 0) {
    throw "Built i686 codex --version failed with exit code $LASTEXITCODE"
}
Write-Host "Built $versionOutput"

$payloadRoot = Join-Path $releaseWorkspace $payloadName
$certsDir = Join-Path $payloadRoot "certs"
if (Test-Path -LiteralPath $releaseWorkspace) {
    Remove-Item -Recurse -Force -LiteralPath $releaseWorkspace
}
if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -Force -LiteralPath $manifestPath
}
New-Item -ItemType Directory -Force -Path $certsDir | Out-Null

$caCertPath = Get-CaCertificatesBundle
Copy-RequiredFile -Source $codexPath -Destination (Join-Path $payloadRoot "codex")
Copy-RequiredFile -Source $caCertPath -Destination (Join-Path $certsDir "ca-certificates.crt")
& chmod 0755 (Join-Path $payloadRoot "codex")
if ($LASTEXITCODE -ne 0) {
    throw "chmod failed for packaged codex binary."
}

Set-Content -Path (Join-Path $payloadRoot "VERSION.txt") -Value ($versionOutput + "`n") -Encoding utf8
Set-Content -Path (Join-Path $payloadRoot "README.TINYCORE.txt") -Value @"
Codex Linux i686 musl package

Files:
- codex
- certs/ca-certificates.crt

Tiny Core example:
  install -m 755 codex /home/tc/codex
  mkdir -p /home/tc/certs /usr/local/etc/ssl/certs
  install -m 644 certs/ca-certificates.crt /home/tc/certs/ca-certificates.crt
  cp /home/tc/certs/ca-certificates.crt /usr/local/etc/ssl/cacert.pem
  cp /home/tc/certs/ca-certificates.crt /usr/local/etc/ssl/certs/ca-certificates.crt
"@ -Encoding utf8

Invoke-TarGzip -WorkingDirectory $releaseWorkspace -ArchivePath $bundlePath -EntryName $payloadName

$bundleSha256 = Get-FileSha256 -Path $bundlePath
$codexSha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "codex")
$caCertSha256 = Get-FileSha256 -Path (Join-Path $certsDir "ca-certificates.crt")
$manifest = [ordered]@{
    upstream_repo              = $UpstreamRepo
    upstream_ref               = $UpstreamRef
    upstream_sha               = $upstreamSha
    linux_target               = $LinuxTarget
    generated_at_utc           = $generatedAt
    release_tag                = $releaseTag
    rolling_tag                = $rollingTag
    custom_runtime_patches     = "not_applied"
    build_adjustments          = [ordered]@{
        vendored_openssl_for_i686_musl = [bool]$addedVendoredOpenSsl
        ca_certificates_bundle_source  = $caCertPath
        zig_cc_target                  = "i686-linux-musl"
    }
    verification              = [ordered]@{
        version_output = $versionOutput
        file_output    = $fileOutput
    }
    artifact                  = [ordered]@{
        name   = [System.IO.Path]::GetFileName($bundlePath)
        sha256 = $bundleSha256
    }
    packaged_files            = @(
        [ordered]@{ path = "codex"; sha256 = $codexSha256 },
        [ordered]@{ path = "certs/ca-certificates.crt"; sha256 = $caCertSha256 },
        [ordered]@{ path = "VERSION.txt"; sha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "VERSION.txt") },
        [ordered]@{ path = "README.TINYCORE.txt"; sha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "README.TINYCORE.txt") }
    )
    release_files             = @(
        [ordered]@{ name = [System.IO.Path]::GetFileName($bundlePath); sha256 = $bundleSha256 },
        [ordered]@{ name = [System.IO.Path]::GetFileName($manifestPath); sha256 = $null }
    )
}

Save-JsonFile -Path $manifestPath -Value $manifest
Save-JsonFile -Path $latestStatePath -Value $manifest
Set-Content -Path $latestShaPath -Value ($upstreamSha + "`n") -Encoding utf8

Write-ActionOutput -Name "changed" -Value "true"
Write-ActionOutput -Name "bundle_path" -Value $bundlePath
Write-ActionOutput -Name "manifest_path" -Value $manifestPath
Write-ActionOutput -Name "version_output" -Value $versionOutput

Write-Host "Linux i686 musl bundle created at $bundlePath"
