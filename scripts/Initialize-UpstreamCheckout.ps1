function Initialize-UpstreamCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$RemoteUrl,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $SourceDir = [IO.Path]::GetFullPath($SourceDir)
    # Actions restores only codex-rs/target, not .git. A clone into that nonempty
    # directory would fail; deleting the directory would discard the entire cache.
    # Accept only the known cache shape, without deleting any existing content.
    if (Test-Path -LiteralPath $SourceDir) {
        foreach ($entry in Get-ChildItem -LiteralPath $SourceDir -Force) {
            if ($entry.Name -cne 'codex-rs' -or -not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing to initialize over unexpected source content: $($entry.FullName)"
            }
            foreach ($child in Get-ChildItem -LiteralPath $entry.FullName -Force) {
                if ($child.Name -cne 'target' -or -not $child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Refusing to initialize over unexpected source content: $($child.FullName)"
                }
            }
        }
    } else {
        New-Item -ItemType Directory -Path $SourceDir -Force | Out-Null
    }

    & git -C $SourceDir init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Cannot initialize upstream checkout in $SourceDir" }
    & git -C $SourceDir remote add origin $RemoteUrl
    if ($LASTEXITCODE -ne 0) { throw "Cannot set upstream checkout remote" }
    & git -C $SourceDir fetch --no-tags --depth 1 origin $Commit
    if ($LASTEXITCODE -ne 0) { throw "Cannot fetch upstream commit $Commit" }
    & git -C $SourceDir checkout --detach FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "Cannot check out upstream commit $Commit" }
    Write-Host "Initialized exact upstream source while preserving any restored codex-rs/target cache."
}
