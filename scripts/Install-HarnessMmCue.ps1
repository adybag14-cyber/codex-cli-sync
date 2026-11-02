[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$SourceDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $SourceDirectory) {
    $bundled = Join-Path $PSScriptRoot 'skills/harnessmm-cue'
    $SourceDirectory = if (Test-Path -LiteralPath $bundled) { $bundled } else { Join-Path $PSScriptRoot '../skills/harnessmm-cue' }
}
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$skillsRoot = [IO.Path]::GetFullPath((Join-Path $CodexHome 'skills'))
$destination = [IO.Path]::GetFullPath((Join-Path $skillsRoot 'harnessmm-cue'))
if (-not $destination.StartsWith($skillsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid skill destination.' }
$files = @('SKILL.md', 'agents/openai.yaml')
$marker = Join-Path $destination '.codex-cli-sync-owned.json'
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$previous = if (Test-Path -LiteralPath $marker) { Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json } else { $null }
if ($previous -and $previous.owner -ne 'adybag14-cyber/codex-cli-sync:harnessmm-cue') { throw 'The existing skill has another owner.' }
foreach ($directory in @($destination, (Join-Path $destination 'agents'))) {
    if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing to replace a linked skill directory.' }
}
$hashes = [ordered]@{}
foreach ($relative in $files) {
    $source = Join-Path $SourceDirectory $relative
    $target = Join-Path $destination $relative
    $hashes[$relative] = Digest $source
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to replace a linked skill file: $relative" }
        $current = Digest $target
        $ownedHash = if ($previous -and $previous.files.PSObject.Properties[$relative]) { $previous.files.$relative } else { $null }
        if ($current -ne $hashes[$relative] -and $current -ne $ownedHash) { throw "Preserving a locally modified skill file: $relative" }
    }
}
New-Item -ItemType Directory -Path (Join-Path $destination 'agents') -Force | Out-Null
foreach ($relative in $files) {
    $source = Join-Path $SourceDirectory $relative
    $target = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $target) -or (Digest $target) -ne $hashes[$relative]) { Copy-Item -LiteralPath $source -Destination $target }
}
[ordered]@{owner='adybag14-cyber/codex-cli-sync:harnessmm-cue';files=$hashes} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $marker -Encoding utf8
[pscustomobject]@{skill='harnessmm-cue';path=$destination;files=$hashes}
