function Get-WindowsBuildRecipeFingerprint {
    param([string]$RepositoryRoot)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $inputs = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File | Where-Object { $_.Extension -in @('.ps1', '.py', '.cjs') })
    $doctor = Join-Path $root 'tools/CodexSyncDoctor'
    if (Test-Path -LiteralPath $doctor) {
        $inputs += @(Get-ChildItem -LiteralPath $doctor -File -Recurse | Where-Object {
            $_.Extension -in @('.cs', '.csproj', '.json') -and $_.FullName -notmatch '[\\/](?:bin|obj)[\\/]'
        })
    }
    $inputs += Get-Item -LiteralPath (Join-Path $root '.github/workflows/sync-codex-windows-custom.yml')
    $records = @($inputs | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-WindowsBuildStateCurrent {
    param([object]$State, [string]$StoredSha, [string]$UpstreamSha, [string]$UpstreamRepo,
          [string]$UpstreamRef, [string]$BaseVersion, [string]$Target, [string]$RecipeFingerprint)
    if ($null -eq $State -or $StoredSha -cne $UpstreamSha) { return $false }
    foreach ($name in @('upstream_sha', 'upstream_repo', 'upstream_ref', 'windows_target', 'patch_status', 'custom_patches_failed', 'version_resolution', 'build_recipe_sha256')) {
        if (-not $State.PSObject.Properties[$name]) { return $false }
    }
    if ($null -eq $State.version_resolution -or -not $State.version_resolution.PSObject.Properties['base_version']) { return $false }
    return ($State.upstream_sha -ceq $UpstreamSha -and $State.upstream_repo -ceq $UpstreamRepo -and
        $State.upstream_ref -ceq $UpstreamRef -and $State.windows_target -ceq $Target -and
        $State.patch_status -ceq 'applied' -and $State.custom_patches_failed -is [bool] -and $State.custom_patches_failed -eq $false -and
        $State.version_resolution.base_version -ceq $BaseVersion -and $State.build_recipe_sha256 -ceq $RecipeFingerprint)
}
