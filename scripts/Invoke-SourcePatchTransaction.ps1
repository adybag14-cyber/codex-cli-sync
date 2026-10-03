function Invoke-SourcePatchTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$RelativePaths,
        [Parameter(Mandatory)][scriptblock]$Patch
    )
    $source = [IO.Path]::GetFullPath($SourceRoot)
    $prefix = $source.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $stage = Join-Path $tempPrefix ('codex-patch-plan-' + [guid]::NewGuid().ToString('N'))
    $original = @{}
    $written = [Collections.Generic.List[string]]::new()
    try {
        foreach ($relative in @($RelativePaths | Sort-Object -Unique)) {
            $path = [IO.Path]::GetFullPath((Join-Path $source $relative))
            $destination = [IO.Path]::GetFullPath((Join-Path $stage $relative))
            if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $destination.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Patch input escapes its source or stage: $relative"
            }
            if (-not [IO.File]::Exists($path)) { throw "Missing patch transaction input: $relative" }
            $original[$relative] = [IO.File]::ReadAllBytes($path)
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.File]::WriteAllBytes($destination, $original[$relative])
        }
        & $Patch $stage
        # Validate every source snapshot before committing the first file.
        $changes = @{}
        foreach ($relative in $original.Keys) {
            $path = Join-Path $source $relative
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($original[$relative])) {
                throw "Source changed during patch planning; refusing to overwrite: $relative"
            }
            $bytes = [IO.File]::ReadAllBytes((Join-Path $stage $relative))
            if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($original[$relative])) { $changes[$relative] = $bytes }
        }
        foreach ($relative in $changes.Keys) {
            $written.Add($relative)
            [IO.File]::WriteAllBytes((Join-Path $source $relative), $changes[$relative])
        }
        Write-Host "Committed $($changes.Count) source files after all patch checks passed."
    } catch {
        foreach ($relative in $written) { [IO.File]::WriteAllBytes((Join-Path $source $relative), $original[$relative]) }
        throw
    } finally {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        if (-not $resolvedStage.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedStage) -notmatch '^codex-patch-plan-[0-9a-f]{32}$') { throw 'Unsafe patch stage cleanup path.' }
        if ([IO.Directory]::Exists($resolvedStage)) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
    }
}
