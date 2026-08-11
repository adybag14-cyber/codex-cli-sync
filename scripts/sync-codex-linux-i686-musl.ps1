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
. (Join-Path $PSScriptRoot "Patch-RustyV8I686Abi.ps1")
. (Join-Path $PSScriptRoot "Patch-RustyV8I686NativeMusl.ps1")

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

    $updatedText = ($text.TrimEnd() + $addition + "`n").Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText(
        $CargoTomlPath,
        $updatedText,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $true
}

function Enable-I686MuslBlake3PureFeature {
    param([Parameter(Mandatory = $true)][string]$CargoTomlPath)

    $text = [System.IO.File]::ReadAllText($CargoTomlPath)
    $sectionPattern = '(?ms)^\[target\.i686-unknown-linux-musl\.dependencies\]\r?\n.*?(?=^\[|\z)'
    $entryPattern = '(?m)^\s*blake3\s*='
    $dependencyLine = 'blake3 = { version = "1", features = ["pure"] }'
    $sectionMatch = [regex]::Match($text, $sectionPattern)

    if ($sectionMatch.Success) {
        if ($sectionMatch.Value -match $entryPattern) {
            return $false
        }

        $section = $sectionMatch.Value.TrimEnd("`r", "`n")
        $replacement = $section + [Environment]::NewLine + $dependencyLine + [Environment]::NewLine
        $text = $text.Substring(0, $sectionMatch.Index) + $replacement + $text.Substring($sectionMatch.Index + $sectionMatch.Length)
    } else {
        $addition = [Environment]::NewLine + [Environment]::NewLine +
            '# Force pure Rust BLAKE3 for 32-bit musl builds; zig clang rejects the AVX512 C path for i686.' + [Environment]::NewLine +
            '[target.i686-unknown-linux-musl.dependencies]' + [Environment]::NewLine +
            $dependencyLine + [Environment]::NewLine
        $text = $text.TrimEnd() + $addition
    }

    $text = $text.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText(
        $CargoTomlPath,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $true
}
function Ensure-RustCrateRecursionLimit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Minimum = 256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Rust crate root not found: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^#!\[recursion_limit\s*=\s*"(?<value>\d+)"\]\s*\r?\n'
    $match = [regex]::Match($text, $pattern)
    if ($match.Success) {
        $current = [int]$match.Groups['value'].Value
        if ($current -ge $Minimum) {
            Write-Host "Kept Rust recursion limit $current in $Path."
            return $false
        }
        $regex = [regex]::new($pattern)
        $text = $regex.Replace($text, "#![recursion_limit = `"$Minimum`"]`n", 1)
    } else {
        $text = "#![recursion_limit = `"$Minimum`"]`n" + $text
    }

    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Raised Rust recursion limit to $Minimum in $Path."
    return $true
}

function Get-CargoLockedPackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CargoLockPath,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    if (-not (Test-Path -LiteralPath $CargoLockPath -PathType Leaf)) {
        throw "Cargo.lock not found: $CargoLockPath"
    }

    $text = [System.IO.File]::ReadAllText($CargoLockPath)
    $pattern = '(?ms)^\[\[package\]\]\s*\r?\nname\s*=\s*"' + [regex]::Escape($PackageName) + '"\s*\r?\nversion\s*=\s*"(?<version>[^"]+)"'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) {
        throw "Package '$PackageName' was not found in $CargoLockPath"
    }
    return $match.Groups['version'].Value
}

function Get-CargoRegistryCrateSource {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $registrySourceRoot = Join-Path $cargoHome 'registry/src'
    if (-not (Test-Path -LiteralPath $registrySourceRoot -PathType Container)) {
        throw "Cargo registry source directory not found: $registrySourceRoot"
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $registrySourceRoot -Directory -ErrorAction Stop |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "$PackageName-$Version" -ErrorAction SilentlyContinue
            }
    )
    foreach ($candidate in $candidates) {
        $manifestPath = Join-Path $candidate.FullName 'Cargo.toml'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }
        $manifestText = [System.IO.File]::ReadAllText($manifestPath)
        if ($manifestText -match '(?m)^name\s*=\s*"' + [regex]::Escape($PackageName) + '"\s*$' -and
            $manifestText -match '(?m)^version\s*=\s*"' + [regex]::Escape($Version) + '"\s*$') {
            return $candidate.FullName
        }
    }

    throw "Could not locate $PackageName $Version in $registrySourceRoot after cargo fetch."
}

function Restore-RustyV8IcuDataBlob {
    param(
        [Parameter(Mandatory = $true)][string]$V8Version,
        [Parameter(Mandatory = $true)][string]$RustyV8SourceDir
    )

    $knownMetadata = @{
        '149.2.0' = [ordered]@{
            icu_commit = 'ee5f27adc28bd3f15b2c293f726d14d2e336cbd5'
            git_blob = 'd1a12cb93065157498a11ff5f4b9a6501ee22506'
            bytes = [int64]10822192
            sha256 = '1cf67874b5a87a8363a86fb3f81e3cbbed54d389062dab8fb52308d5cf8c8612'
        }
        '150.4.0' = [ordered]@{
            icu_commit = 'ee5f27adc28bd3f15b2c293f726d14d2e336cbd5'
            git_blob = 'd1a12cb93065157498a11ff5f4b9a6501ee22506'
            bytes = [int64]10822192
            sha256 = '1cf67874b5a87a8363a86fb3f81e3cbbed54d389062dab8fb52308d5cf8c8612'
        }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rusty-v8-icu-{0}-{1}" -f $V8Version, [guid]::NewGuid().ToString('N'))
    $rustyV8Repo = Join-Path $tempRoot 'rusty-v8'
    $icuRepo = Join-Path $tempRoot 'icu'
    $archivePath = Join-Path $tempRoot 'icu-data.tar'
    $extractRoot = Join-Path $tempRoot 'extract'
    $targetPath = Join-Path $RustyV8SourceDir 'third_party/icu/common/icudtl.dat'
    $restored = $false

    New-Item -ItemType Directory -Force -Path $rustyV8Repo, $icuRepo, $extractRoot | Out-Null
    try {
        & git -C $rustyV8Repo init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialise the temporary rusty_v8 metadata repository.' }
        & git -C $rustyV8Repo remote add origin 'https://github.com/denoland/rusty_v8.git'
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the rusty_v8 metadata remote.' }
        & git -C $rustyV8Repo fetch --quiet --depth 1 origin "refs/tags/v$V8Version"
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch rusty_v8 tag v$V8Version." }

        $icuTreeEntry = [string](& git -C $rustyV8Repo ls-tree FETCH_HEAD third_party/icu)
        if ($LASTEXITCODE -ne 0 -or $icuTreeEntry -notmatch '^160000 commit (?<sha>[0-9a-f]{40})\s+third_party/icu$') {
            throw "Could not resolve the ICU submodule revision from rusty_v8 v$V8Version. Output: $icuTreeEntry"
        }
        $icuCommit = $Matches['sha']

        & git -C $icuRepo init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialise the temporary ICU repository.' }
        & git -C $icuRepo remote add origin 'https://chromium.googlesource.com/chromium/deps/icu.git'
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Chromium ICU remote.' }
        & git -C $icuRepo fetch --quiet --depth 1 origin $icuCommit
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch Chromium ICU revision $icuCommit." }

        $expectedGitBlob = ([string](& git -C $icuRepo rev-parse 'FETCH_HEAD:common/icudtl.dat')).Trim()
        if ($LASTEXITCODE -ne 0 -or $expectedGitBlob -notmatch '^[0-9a-f]{40}$') {
            throw "Could not resolve common/icudtl.dat at ICU revision $icuCommit."
        }

        $existingMatches = $false
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $existingGitBlob = ([string](& git hash-object $targetPath)).Trim()
            $existingMatches = $LASTEXITCODE -eq 0 -and $existingGitBlob -eq $expectedGitBlob
        }

        if (-not $existingMatches) {
            & git -C $icuRepo archive --format=tar -o $archivePath FETCH_HEAD common/icudtl.dat
            if ($LASTEXITCODE -ne 0) { throw "Could not archive common/icudtl.dat from ICU revision $icuCommit." }
            & tar -xf $archivePath -C $extractRoot
            if ($LASTEXITCODE -ne 0) { throw 'Could not extract the ICU data archive.' }
            $extractedPath = Join-Path $extractRoot 'common/icudtl.dat'
            if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) {
                throw "Extracted ICU data file not found: $extractedPath"
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
            Copy-Item -LiteralPath $extractedPath -Destination $targetPath -Force
            $restored = $true
        }

        $actualGitBlob = ([string](& git hash-object $targetPath)).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualGitBlob -ne $expectedGitBlob) {
            throw "ICU data Git blob verification failed: expected $expectedGitBlob, got $actualGitBlob"
        }
        $item = Get-Item -LiteralPath $targetPath
        $sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($knownMetadata.ContainsKey($V8Version)) {
            $known = $knownMetadata[$V8Version]
            if ($icuCommit -ne $known.icu_commit -or
                $actualGitBlob -ne $known.git_blob -or
                $item.Length -ne $known.bytes -or
                $sha256 -ne $known.sha256) {
                throw "Known rusty_v8 $V8Version ICU metadata mismatch. Commit=$icuCommit Blob=$actualGitBlob Bytes=$($item.Length) SHA256=$sha256"
            }
        }

        Write-Host "Verified rusty_v8 $V8Version ICU data: commit=$icuCommit blob=$actualGitBlob bytes=$($item.Length) sha256=$sha256 restored=$restored"
        return [pscustomobject]@{
            path = $targetPath
            restored = $restored
            icu_commit = $icuCommit
            git_blob = $actualGitBlob
            bytes = [int64]$item.Length
            sha256 = $sha256
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-RustyV8ChromiumRustVendor {
    param(
        [Parameter(Mandatory = $true)][string]$V8Version,
        [Parameter(Mandatory = $true)][string]$RustyV8SourceDir
    )

    $knownMetadata = @{
        '149.2.0' = [ordered]@{
            rust_commit = '2b055f4ecac78bbf34a0d34217c699b7b09b44dd'
            vendor_tree = '2d3dd155f076c848a7311679d0015524e338c937'
            files = 9548
        }
        '150.4.0' = [ordered]@{
            rust_commit = '26e8ff47f18a8d28d6187a04b6a16cb7332356f8'
            vendor_tree = '9c8187695bd7cf8af33ed975228b68944ffaac39'
            files = 10606
        }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rusty-v8-rust-vendor-{0}-{1}" -f $V8Version, [guid]::NewGuid().ToString('N'))
    $rustyV8Repo = Join-Path $tempRoot 'rusty-v8'
    $chromiumRustRepo = Join-Path $tempRoot 'chromium-rust'
    $archivePath = Join-Path $tempRoot 'chromium-rust-vendor.tar'
    $extractRoot = Join-Path $tempRoot 'extract'
    $targetRustRoot = Join-Path $RustyV8SourceDir 'third_party/rust'
    $targetVendor = Join-Path $targetRustRoot 'chromium_crates_io/vendor'
    $markerPath = Join-Path $RustyV8SourceDir '.codex-cli-sync-rust-vendor.json'
    $restored = $false

    $sentinels = @(
        'chromium_crates_io/vendor/icu_calendar_data-v2/build.rs',
        'chromium_crates_io/vendor/cxx-v1/include/cxx.h',
        'chromium_crates_io/vendor/serde-v1/src/lib.rs'
    )

    New-Item -ItemType Directory -Force -Path $rustyV8Repo, $chromiumRustRepo, $extractRoot | Out-Null
    try {
        & git -C $rustyV8Repo init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialise the temporary rusty_v8 metadata repository for Chromium Rust.' }
        & git -C $rustyV8Repo remote add origin 'https://github.com/denoland/rusty_v8.git'
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the rusty_v8 metadata remote for Chromium Rust.' }
        & git -C $rustyV8Repo fetch --quiet --depth 1 origin "refs/tags/v$V8Version"
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch rusty_v8 tag v$V8Version for Chromium Rust metadata." }

        $rustTreeEntry = [string](& git -C $rustyV8Repo ls-tree FETCH_HEAD third_party/rust)
        if ($LASTEXITCODE -ne 0 -or $rustTreeEntry -notmatch '^160000 commit (?<sha>[0-9a-f]{40})\s+third_party/rust$') {
            throw "Could not resolve the Chromium Rust submodule revision from rusty_v8 v$V8Version. Output: $rustTreeEntry"
        }
        $rustCommit = $Matches['sha']

        & git -C $chromiumRustRepo init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialise the temporary Chromium Rust repository.' }
        & git -C $chromiumRustRepo remote add origin 'https://chromium.googlesource.com/chromium/src/third_party/rust'
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Chromium Rust remote.' }
        & git -C $chromiumRustRepo fetch --quiet --depth 1 --filter=blob:none origin $rustCommit
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch Chromium Rust revision $rustCommit." }

        $vendorTree = ([string](& git -C $chromiumRustRepo rev-parse 'FETCH_HEAD:chromium_crates_io/vendor')).Trim()
        if ($LASTEXITCODE -ne 0 -or $vendorTree -notmatch '^[0-9a-f]{40}$') {
            throw "Could not resolve chromium_crates_io/vendor at Chromium Rust revision $rustCommit."
        }
        $vendorFileCount = @(& git -C $chromiumRustRepo ls-tree -r --name-only FETCH_HEAD chromium_crates_io/vendor).Count
        if ($LASTEXITCODE -ne 0 -or $vendorFileCount -lt 1) {
            throw "Chromium Rust vendor tree $vendorTree is empty."
        }

        if ($knownMetadata.ContainsKey($V8Version)) {
            $known = $knownMetadata[$V8Version]
            if ($rustCommit -ne $known.rust_commit -or $vendorTree -ne $known.vendor_tree -or $vendorFileCount -ne $known.files) {
                throw "Known rusty_v8 $V8Version Chromium Rust metadata mismatch. Commit=$rustCommit Tree=$vendorTree Files=$vendorFileCount"
            }
        }

        $markerMatches = $false
        $marker = $null
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                $markerMatches =
                    $marker.v8_version -eq $V8Version -and
                    $marker.rust_commit -eq $rustCommit -and
                    $marker.vendor_tree -eq $vendorTree -and
                    [int]$marker.files -eq $vendorFileCount
            } catch {
                $markerMatches = $false
            }
        }
        foreach ($sentinel in $sentinels) {
            if (-not (Test-Path -LiteralPath (Join-Path $targetRustRoot $sentinel) -PathType Leaf)) {
                $markerMatches = $false
            }
        }

        $archiveSha256 = if ($markerMatches -and $marker.PSObject.Properties['archive_sha256']) { [string]$marker.archive_sha256 } else { $null }
        $archiveBytes = if ($markerMatches -and $marker.PSObject.Properties['archive_bytes']) { [int64]$marker.archive_bytes } else { [int64]0 }
        if (-not $markerMatches) {
            & git -C $chromiumRustRepo archive --format=tar -o $archivePath FETCH_HEAD chromium_crates_io/vendor
            if ($LASTEXITCODE -ne 0) { throw "Could not archive Chromium Rust vendor tree $vendorTree." }
            $archiveItem = Get-Item -LiteralPath $archivePath
            $archiveBytes = [int64]$archiveItem.Length
            $archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            & tar -xf $archivePath -C $extractRoot
            if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Chromium Rust vendor archive.' }
            $extractedVendor = Join-Path $extractRoot 'chromium_crates_io/vendor'
            if (-not (Test-Path -LiteralPath $extractedVendor -PathType Container)) {
                throw "Extracted Chromium Rust vendor directory not found: $extractedVendor"
            }
            Remove-Item -LiteralPath $targetVendor -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetVendor) | Out-Null
            Move-Item -LiteralPath $extractedVendor -Destination $targetVendor
            $restored = $true
        }

        $sentinelBlobs = [ordered]@{}
        foreach ($sentinel in $sentinels) {
            $targetPath = Join-Path $targetRustRoot $sentinel
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw "Chromium Rust vendor sentinel is missing after restoration: $targetPath"
            }
            $expectedBlob = ([string](& git -C $chromiumRustRepo rev-parse "FETCH_HEAD:$sentinel")).Trim()
            $actualBlob = ([string](& git hash-object $targetPath)).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualBlob -ne $expectedBlob) {
                throw "Chromium Rust vendor sentinel verification failed for $sentinel. Expected=$expectedBlob Actual=$actualBlob"
            }
            $sentinelBlobs[$sentinel] = $actualBlob
        }

        $markerData = [ordered]@{
            v8_version = $V8Version
            rust_commit = $rustCommit
            vendor_tree = $vendorTree
            files = $vendorFileCount
            archive_bytes = $archiveBytes
            archive_sha256 = $archiveSha256
            sentinel_blobs = $sentinelBlobs
        }
        [System.IO.File]::WriteAllText(
            $markerPath,
            ($markerData | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false)
        )

        Write-Host "Verified rusty_v8 $V8Version Chromium Rust vendor: commit=$rustCommit tree=$vendorTree files=$vendorFileCount restored=$restored"
        return [pscustomobject]@{
            path = $targetVendor
            restored = $restored
            rust_commit = $rustCommit
            vendor_tree = $vendorTree
            files = $vendorFileCount
            archive_bytes = $archiveBytes
            archive_sha256 = $archiveSha256
            sentinel_blobs = $sentinelBlobs
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Enable-I686MuslRustyV8SourceBuild {
    param([Parameter(Mandatory = $true)][string]$CodexRsDir)

    $codeModeCargoToml = Join-Path $CodexRsDir 'code-mode/Cargo.toml'
    $cargoLockPath = Join-Path $CodexRsDir 'Cargo.lock'
    if (-not (Test-Path -LiteralPath $codeModeCargoToml -PathType Leaf)) {
        throw "Required code-mode manifest not found: $codeModeCargoToml"
    }

    $codeModeManifest = [System.IO.File]::ReadAllText($codeModeCargoToml)
    $requiredI686Contract = @(
        'sandbox = ["v8/v8_enable_sandbox"]',
        'deno_core_icudata = { workspace = true }',
        'v8 = { workspace = true }'
    )

    $foundContractEntries = @()
    $missingContractEntries = @()
    foreach ($required in $requiredI686Contract) {
        if ($codeModeManifest.Contains($required)) {
            $foundContractEntries += $required
        } else {
            $missingContractEntries += $required
        }
    }

    if ($foundContractEntries.Count -eq 0) {
        Write-Host "Detected updated code-mode manifest contract (legacy i686 rusty-v8 entries removed); skipping strict validation."
    } elseif ($missingContractEntries.Count -gt 0) {
        $missing = $missingContractEntries -join ', '
        throw "Upstream code-mode dependency contract changed partially; missing '$missing' in $codeModeCargoToml"
    }

    if ($foundContractEntries.Count -eq $requiredI686Contract.Count) {
        Write-Host "Detected legacy code-mode dependency contract; continuing with strict i686 rusty-v8 path."
    }

    $v8Version = Get-CargoLockedPackageVersion -CargoLockPath $cargoLockPath -PackageName 'v8'
    $env:V8_FROM_SOURCE = '1'
    $env:PYTHON = if ($env:PYTHON) { $env:PYTHON } else { 'python3' }
    Remove-Item Env:CLANG_BASE_PATH -ErrorAction SilentlyContinue
    $env:LIBCLANG_PATH = if ($env:LIBCLANG_PATH) { $env:LIBCLANG_PATH } else { '/usr/lib/llvm-19/lib' }
    $env:NINJA = if ($env:NINJA) { $env:NINJA } else { '/usr/bin/ninja' }
    $env:PRINT_GN_ARGS = '1'
    $env:NUM_JOBS = if ($env:NUM_JOBS) { $env:NUM_JOBS } else { '2' }
    $env:GN_ARGS = if ($env:GN_ARGS) {
        $env:GN_ARGS
    } else {
        'v8_target_cpu="x86" use_sysroot=false treat_warnings_as_errors=false'
    }

    Write-Host "Configured rusty_v8 $v8Version to build from source for i686 Linux."
    Write-Host "rusty_v8 GN_ARGS: $env:GN_ARGS"
    Write-Host "rusty_v8 compiler: Chromium bundled Clang/Compiler-RT (CLANG_BASE_PATH intentionally unset)."
    return $v8Version
}

function Remove-StaleRustyV8GnOutput {
    param(
        [Parameter(Mandatory = $true)][string]$CodexRsDir,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$V8Version
    )

    $gnOutDir = Join-Path $CodexRsDir "target/$Target/release/gn_out"
    $argsPath = Join-Path $gnOutDir 'args.gn'
    if (-not (Test-Path -LiteralPath $argsPath -PathType Leaf)) {
        return $false
    }

    $argsText = [System.IO.File]::ReadAllText($argsPath)
    $usesForcedSystemClang = $argsText -match 'clang_base_path\s*=\s*"/usr/lib/llvm-[^"]+"'
    $usesTargetMuslHeaders = $argsText -match 'rusty_v8_zig_lib_dir\s*=\s*"[^"]+"'
    $usesIsolatedSnapshotToolchain = $argsText -match 'v8_snapshot_toolchain\s*=\s*"//build/toolchain/linux:clang_x86_v8_x86_glibc"'
    $usesMatchingRustyV8Version = $argsText -match ('rusty_v8_crate_version\s*=\s*"' + [regex]::Escape($V8Version) + '"')
    $usesMatchingUpstreamMuslRustPath =
        $V8Version -ne '150.4.0' -or
        ($argsText -match 'use_musl\s*=\s*true' -and
         $argsText -match 'rust_prebuilt_stdlib\s*=\s*false')

    $toolchainPath = Join-Path $gnOutDir 'toolchain.ninja'
    $usesLibcxxCompatibleMuslHeaderOrder = $false
    $usesLibcxxMuslConfiguration = $false
    $usesBundledCompilerBuiltinHeaders = $false
    if (Test-Path -LiteralPath $toolchainPath -PathType Leaf) {
        $toolchainText = [System.IO.File]::ReadAllText($toolchainPath)
        $usesLibcxxCompatibleMuslHeaderOrder =
            $toolchainText.Contains('-idirafter') -and
            $toolchainText.Contains('/libc/include/generic-musl')
        $usesLibcxxMuslConfiguration = $toolchainText.Contains('-DANDROID_HOST_MUSL')
        $usesBundledCompilerBuiltinHeaders =
            $toolchainText.Contains('-nostdlibinc') -and
            -not ($toolchainText -match '(^|\s)-nostdinc(\s|$)') -and
            -not ($toolchainText -match '-idirafter[^\s]*/lib/include(?=\s|$)')
    }

    $usesMatchingGeneratedRustTarget = $V8Version -ne '150.4.0'
    if ($V8Version -eq '150.4.0') {
        $targetRustCorePath = Join-Path $gnOutDir 'obj/build/rust/std/rules/core.ninja'
        if (Test-Path -LiteralPath $targetRustCorePath -PathType Leaf) {
            $targetRustCoreText = [System.IO.File]::ReadAllText($targetRustCorePath)
            $usesMatchingGeneratedRustTarget =
                $targetRustCoreText.Contains('--target=i686-unknown-linux-musl') -and
                -not $targetRustCoreText.Contains('--target=i686-unknown-linux-gnu')
        }
    }

    $usesGlibcSnapshotCompilerCommands = $false
    $snapshotCompilerProbePath = Join-Path $gnOutDir 'clang_x86_v8_x86_glibc/obj/v8/v8_init.ninja'
    if (Test-Path -LiteralPath $snapshotCompilerProbePath -PathType Leaf) {
        $snapshotCompilerProbeText = [System.IO.File]::ReadAllText($snapshotCompilerProbePath)
        $usesGlibcSnapshotCompilerCommands =
            $snapshotCompilerProbeText.Contains('--target=i386-unknown-linux-gnu') -and
            -not $snapshotCompilerProbeText.Contains('--target=i386-unknown-linux-musl') -and
            -not $snapshotCompilerProbeText.Contains('-DANDROID_HOST_MUSL') -and
            -not $snapshotCompilerProbeText.Contains('-nostdlibinc') -and
            -not ($snapshotCompilerProbeText -match '-idirafter[^\s]*/libc/include')
    }

    if (-not $usesForcedSystemClang -and
        $usesTargetMuslHeaders -and
        $usesIsolatedSnapshotToolchain -and
        $usesMatchingRustyV8Version -and
        $usesMatchingUpstreamMuslRustPath -and
        $usesMatchingGeneratedRustTarget -and
        $usesGlibcSnapshotCompilerCommands -and
        $usesLibcxxCompatibleMuslHeaderOrder -and
        $usesLibcxxMuslConfiguration -and
        $usesBundledCompilerBuiltinHeaders) {
        return $false
    }

    $reasons = @()
    if ($usesForcedSystemClang) {
        $reasons += 'forced an incompatible system Clang'
    }
    if (-not $usesTargetMuslHeaders) {
        $reasons += 'did not compile target objects against Zig musl headers'
    }
    if (-not $usesIsolatedSnapshotToolchain) {
        $reasons += 'did not isolate the runnable x86 snapshot toolchain on glibc'
    }
    if (-not $usesMatchingRustyV8Version) {
        $reasons += "was generated for a different rusty_v8 version than $V8Version"
    }
    if (-not $usesMatchingUpstreamMuslRustPath) {
        $reasons += 'did not enable the audited upstream musl Rust target path'
    }
    if (-not $usesMatchingGeneratedRustTarget) {
        $reasons += 'did not generate i686-unknown-linux-musl Rust compiler commands'
    }
    if (-not $usesGlibcSnapshotCompilerCommands) {
        $reasons += 'generated snapshot compiler commands that were not isolated on i386 glibc'
    }
    if (-not $usesLibcxxCompatibleMuslHeaderOrder) {
        $reasons += 'placed Zig musl headers before libc++ compatibility wrappers'
    }
    if (-not $usesLibcxxMuslConfiguration) {
        $reasons += 'did not enable Chromium libc++ musl configuration'
    }
    if (-not $usesBundledCompilerBuiltinHeaders) {
        $reasons += 'mixed Zig intrinsic headers with Chromium Clang'
    }

    Remove-Item -LiteralPath $gnOutDir -Recurse -Force
    Write-Host "Removed stale rusty_v8 GN output because it $($reasons -join '; '): $gnOutDir"
    return $true
}

function Enable-I686MuslLinuxSandboxSyscallBuild {
    param([Parameter(Mandatory = $true)][string]$CodexRsDir)

    $landlockPath = Join-Path $CodexRsDir "linux-sandbox/src/landlock.rs"
    if (-not (Test-Path -LiteralPath $landlockPath -PathType Leaf)) {
        throw "Required linux sandbox file not found: $landlockPath"
    }

    $text = [System.IO.File]::ReadAllText($landlockPath)
    $originalText = $text

    $text = $text.Replace(
        @'
    fn deny_syscall(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: i64) {
        rules.insert(nr, vec![]); // empty rule vec = unconditional match
    }
'@,
        @'
    fn deny_syscall<T>(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: T)
    where
        T: Into<i64>,
    {
        rules.insert(nr.into(), vec![]); // empty rule vec = unconditional match
    }
'@
    )

    $text = $text.Replace(
        "            deny_syscall(&mut rules, libc::SYS_accept);",
        @'
            #[cfg(not(all(target_arch = "x86", target_env = "musl")))]
            deny_syscall(&mut rules, libc::SYS_accept);
'@
    )

    $text = $text.Replace(
        "            rules.insert(libc::SYS_socket, vec![unix_only_rule.clone()]);",
        "            rules.insert(libc::SYS_socket.into(), vec![unix_only_rule.clone()]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![unix_only_rule]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![unix_only_rule]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socket, vec![deny_non_ip_socket]);",
        "            rules.insert(libc::SYS_socket.into(), vec![deny_non_ip_socket]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![deny_unix_socketpair]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![deny_unix_socketpair]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![deny_non_unix_socketpair]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![deny_non_unix_socketpair]);"
    )

    if ($text -eq $originalText) {
        throw "Linux sandbox syscall compatibility patch did not change $landlockPath"
    }

    [System.IO.File]::WriteAllText(
        $landlockPath,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )

    return $true
}

function Set-I686MuslBuildEnvironment {
    $env:OPENSSL_STATIC = "1"
    $env:AWS_LC_SYS_NO_JITTER_ENTROPY = "1"
    $env:PKG_CONFIG_ALLOW_CROSS = "1"
    # lzma-sys otherwise accepts the runner host's pkg-config result during a
    # cross build and links /usr/lib/x86_64-linux-gnu/liblzma.a into i686.
    $env:LZMA_API_STATIC = "1"
    $env:LIBLZMA_NO_PKG_CONFIG = "1"
    $env:CARGO_BUILD_JOBS = "2"

    # Zig's i686 musl libatomic does not provide __atomic_is_lock_free. OpenSSL
    # 3.5's pthread atomics skip that code path when BROKEN_CLANG_ATOMICS is set.
    $opensslAtomicFallbackFlags = @("-D__STDC_NO_ATOMICS__", "-DBROKEN_CLANG_ATOMICS")
    foreach ($flag in $opensslAtomicFallbackFlags) {
        if ([string]::IsNullOrWhiteSpace($env:CFLAGS_i686_unknown_linux_musl)) {
            $env:CFLAGS_i686_unknown_linux_musl = $flag
        } elseif ($env:CFLAGS_i686_unknown_linux_musl -notmatch [regex]::Escape($flag)) {
            $env:CFLAGS_i686_unknown_linux_musl = "$($env:CFLAGS_i686_unknown_linux_musl) $flag"
        }
    }

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

$codexRsDir = Join-Path $sourceDir "codex-rs"
$cliCargoTomlPath = Join-Path $codexRsDir "cli/Cargo.toml"
$addedVendoredOpenSsl = Enable-I686MuslVendoredOpenSsl -CargoTomlPath $cliCargoTomlPath
$enabledBlake3Pure = Enable-I686MuslBlake3PureFeature -CargoTomlPath $cliCargoTomlPath
$rustyV8Version = Enable-I686MuslRustyV8SourceBuild -CodexRsDir $codexRsDir
$mcpServerRecursionLimitPatched = Ensure-RustCrateRecursionLimit -Path (Join-Path $codexRsDir "mcp-server/src/lib.rs") -Minimum 256
$patchedLinuxSandboxSyscalls = Enable-I686MuslLinuxSandboxSyscallBuild -CodexRsDir $codexRsDir
Set-I686MuslBuildEnvironment

Push-Location $codexRsDir
try {
    & rustup show active-toolchain
    if ($LASTEXITCODE -ne 0) {
        throw "rustup show active-toolchain failed with exit code $LASTEXITCODE"
    }

    & rustup target add $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target add $LinuxTarget failed with exit code $LASTEXITCODE"
    }

    $installedTargets = @(& rustup target list --installed)
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target list --installed failed with exit code $LASTEXITCODE"
    }
    if ($installedTargets -notcontains $LinuxTarget) {
        throw "Rust target $LinuxTarget is not installed after rustup target add."
    }

    Write-Host "i686 OpenSSL CFLAGS: $env:CFLAGS_i686_unknown_linux_musl"
    Write-Host "Building rusty_v8 $rustyV8Version from source for $LinuxTarget (V8_FROM_SOURCE=$env:V8_FROM_SOURCE)."

    & rustc --print target-libdir --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "rustc could not resolve target libdir for $LinuxTarget."
    }

    Write-Host "Clearing cached openssl-sys artifacts so i686 OpenSSL CFLAGS are applied."
    cargo clean --package openssl-sys --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "cargo clean for openssl-sys failed with exit code $LASTEXITCODE"
    }

    Write-Host "Clearing cached lzma-sys artifacts so bundled i686 liblzma is rebuilt."
    cargo clean --package lzma-sys --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "cargo clean for lzma-sys failed with exit code $LASTEXITCODE"
    }

    cargo fetch --locked --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "cargo fetch failed with exit code $LASTEXITCODE"
    }
    $rustyV8SourceDir = Get-CargoRegistryCrateSource -PackageName 'v8' -Version $rustyV8Version
    $rustyV8IcuData = Restore-RustyV8IcuDataBlob -V8Version $rustyV8Version -RustyV8SourceDir $rustyV8SourceDir
    $rustyV8RustVendor = Restore-RustyV8ChromiumRustVendor -V8Version $rustyV8Version -RustyV8SourceDir $rustyV8SourceDir
    $rustyV8I686Abi = Patch-RustyV8I686Abi -V8Version $rustyV8Version -RustyV8SourceDir $rustyV8SourceDir
    $rustyV8I686NativeMusl = Patch-RustyV8I686NativeMusl -V8Version $rustyV8Version -RustyV8SourceDir $rustyV8SourceDir
    $removedStaleV8GnOutput = Remove-StaleRustyV8GnOutput -CodexRsDir $codexRsDir -Target $LinuxTarget -V8Version $rustyV8Version
    cargo zigbuild --release --package codex-cli --bin codex --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "cargo zigbuild failed with exit code $LASTEXITCODE"
    }

    $lzmaBuildOutputs = @(
        Get-ChildItem -LiteralPath (Join-Path $codexRsDir "target/$LinuxTarget/release/build") `
            -Directory -Filter 'lzma-sys-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'output' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if ($lzmaBuildOutputs.Count -eq 0) {
        throw "lzma-sys build output was not produced for $LinuxTarget."
    }
    $lzmaBuildOutputText = ($lzmaBuildOutputs | ForEach-Object {
        [System.IO.File]::ReadAllText($_)
    }) -join "`n"
    if ($lzmaBuildOutputText -match '(?m)cargo:rustc-link-search=native=/(usr/)?lib/(x86_64|aarch64|i[3-6]86)-linux-gnu') {
        throw "lzma-sys selected a host-architecture system library during the $LinuxTarget cross build."
    }
    if ($lzmaBuildOutputText -notmatch '(?m)cargo:rustc-link-lib=(static=)?lzma') {
        throw "lzma-sys did not report its bundled liblzma link contract for $LinuxTarget."
    }
    Write-Host "Verified bundled target liblzma for $LinuxTarget."
} finally {
    Pop-Location
}

$targetDir = Join-Path $sourceDir "codex-rs/target/$LinuxTarget/release"
$v8ArchivePath = Join-Path $targetDir "gn_out/obj/librusty_v8.a"
$v8GnArgsPath = Join-Path $targetDir "gn_out/args.gn"
if (-not (Test-Path -LiteralPath $v8ArchivePath -PathType Leaf)) {
    throw "rusty_v8 source archive was not produced: $v8ArchivePath"
}
if (-not (Test-Path -LiteralPath $v8GnArgsPath -PathType Leaf)) {
    throw "rusty_v8 GN args were not produced: $v8GnArgsPath"
}
$v8GnArgsText = [System.IO.File]::ReadAllText($v8GnArgsPath)
if ($v8GnArgsText -notmatch 'target_cpu\s*=\s*"x86"' -or $v8GnArgsText -notmatch 'v8_target_cpu\s*=\s*"x86"') {
    throw "rusty_v8 GN output is not configured for x86: $v8GnArgsPath"
}

$env:V8_ARCHIVE_PATH = $v8ArchivePath
$env:V8_MEMBER_PATH = "/tmp/rusty-v8-i686-member-$PID.o"
$v8ObjectFileOutput = [string](& bash -lc @'
set -euo pipefail
member="$(ar t "$V8_ARCHIVE_PATH" | head -n 1)"
test -n "$member"
ar p "$V8_ARCHIVE_PATH" "$member" > "$V8_MEMBER_PATH"
file "$V8_MEMBER_PATH"
rm -f "$V8_MEMBER_PATH"
'@)
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect a member of the rusty_v8 archive."
}
Write-Host $v8ObjectFileOutput
if ($v8ObjectFileOutput -notmatch 'ELF 32-bit' -or $v8ObjectFileOutput -notmatch 'Intel 80386') {
    throw "rusty_v8 archive is not a real 32-bit i386 build: $v8ObjectFileOutput"
}

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

Compatibility note:
  JavaScript code mode is included. rusty_v8 is compiled from source as a real
  32-bit x86 V8 static archive during the GitHub Actions build.

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
    compatibility_patches      = @(
        [ordered]@{
            name    = "build_rusty_v8_from_source_for_i686_musl"
            applied = $env:V8_FROM_SOURCE -eq "1"
            reason  = "rusty_v8 $rustyV8Version has no published i686-unknown-linux-musl archive, so CI builds the real x86 V8 archive from source."
            effect  = "JavaScript code mode remains enabled in the i686 musl package."
        },
        [ordered]@{
            name    = "raise_mcp_server_recursion_limit"
            applied = $true
            reason  = "Current upstream codex-mcp-server type queries exceed Rust's default recursion depth in release builds."
            effect  = "codex-mcp-server builds deterministically with recursion_limit 256."
        },
        [ordered]@{
            name   = "i686_musl_linux_sandbox_syscall_compile_fix"
            applied = [bool]$patchedLinuxSandboxSyscalls
            reason = "libc syscall constants are i32 on i686 musl and libc does not expose SYS_accept for this target."
            effect = "Linux sandbox syscall table code compiles for the i686 musl release target."
        },
        [ordered]@{
            name   = "i686_musl_blake3_pure_compile_fix"
            applied = [bool]$enabledBlake3Pure
            reason = "blake3 compiles AVX512 C intrinsics on 32-bit x86 by default, and zig clang rejects that path for i686 musl."
            effect = "blake3 uses its pure Rust fallback for this target so the i686 musl release can compile."
        },
        [ordered]@{
            name    = "build_bundled_liblzma_for_i686_musl"
            applied = $env:LZMA_API_STATIC -eq "1" -and $env:LIBLZMA_NO_PKG_CONFIG -eq "1"
            reason  = "Cross-enabled pkg-config can select the Linux runner's x86_64 liblzma archive while linking the i686 musl executable."
            effect  = "lzma-sys compiles and links its bundled target liblzma, and the build rejects host-architecture search paths."
        }
    )
    build_adjustments          = [ordered]@{
        vendored_openssl_for_i686_musl = [bool]$addedVendoredOpenSsl
        blake3_pure_for_i686_musl = [bool]$enabledBlake3Pure
        rusty_v8_built_from_source_for_i686_musl = $env:V8_FROM_SOURCE -eq "1"
        rusty_v8_version = $rustyV8Version
        rusty_v8_gn_args = $env:GN_ARGS
        rusty_v8_num_jobs = $env:NUM_JOBS
        rusty_v8_compiler_toolchain = "Chromium bundled Clang/Compiler-RT"
        rusty_v8_clang_base_path_forced = $false
        rusty_v8_stale_system_clang_gn_output_removed = [bool]$removedStaleV8GnOutput
        rusty_v8_icu_data_path = $rustyV8IcuData.path
        rusty_v8_icu_data_restored = [bool]$rustyV8IcuData.restored
        rusty_v8_icu_revision = $rustyV8IcuData.icu_commit
        rusty_v8_icu_git_blob = $rustyV8IcuData.git_blob
        rusty_v8_icu_bytes = [int64]$rustyV8IcuData.bytes
        rusty_v8_icu_sha256 = $rustyV8IcuData.sha256
        rusty_v8_chromium_rust_vendor_path = $rustyV8RustVendor.path
        rusty_v8_chromium_rust_vendor_restored = [bool]$rustyV8RustVendor.restored
        rusty_v8_chromium_rust_revision = $rustyV8RustVendor.rust_commit
        rusty_v8_chromium_rust_vendor_tree = $rustyV8RustVendor.vendor_tree
        rusty_v8_chromium_rust_vendor_files = [int]$rustyV8RustVendor.files
        rusty_v8_chromium_rust_vendor_archive_bytes = [int64]$rustyV8RustVendor.archive_bytes
        rusty_v8_chromium_rust_vendor_archive_sha256 = $rustyV8RustVendor.archive_sha256
        rusty_v8_chromium_rust_vendor_sentinel_blobs = $rustyV8RustVendor.sentinel_blobs
        rusty_v8_i686_abi_patch = $rustyV8I686Abi
        rusty_v8_i686_native_musl_patch = $rustyV8I686NativeMusl
        mcp_server_recursion_limit_256 = $true
        mcp_server_recursion_limit_text_changed = [bool]$mcpServerRecursionLimitPatched
        rusty_v8_archive_path = $v8ArchivePath
        rusty_v8_archive_member_file_output = $v8ObjectFileOutput
        linux_sandbox_syscalls_patched_for_i686_musl = [bool]$patchedLinuxSandboxSyscalls
        openssl_no_c11_atomics_for_i686_musl = $true
        openssl_broken_clang_atomics_for_i686_musl = $true
        openssl_sys_cleaned_for_i686_musl = $true
        lzma_sys_bundled_for_i686_musl = $env:LZMA_API_STATIC -eq "1"
        lzma_sys_host_pkg_config_disabled = $env:LIBLZMA_NO_PKG_CONFIG -eq "1"
        lzma_sys_cleaned_for_i686_musl = $true
        lzma_sys_build_outputs = @($lzmaBuildOutputs)
        cargo_build_jobs              = $env:CARGO_BUILD_JOBS
        ca_certificates_bundle_source  = $caCertPath
        cargo_command                  = "cargo zigbuild --release --package codex-cli --bin codex --target $LinuxTarget"
    }
    verification              = [ordered]@{
        version_output = $versionOutput
        file_output    = $fileOutput
        rusty_v8_object_file_output = $v8ObjectFileOutput
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
