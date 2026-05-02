[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)

function Get-SourceFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected upstream file was not found: $RelativePath"
    }
    return [System.IO.Path]::GetFullPath($path)
}

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Set-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Replace-Once {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $text = Get-Text -Path $Path
    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Patch anchor failed for $Description in $Path. Expected 1 match, found $($matches.Count)."
    }

    $newText = $regex.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $Replacement },
        1
    )
    Set-Text -Path $Path -Text $newText
    Write-Host "Patched: $Description"
}

function Insert-AfterOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Insertion,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $text = Get-Text -Path $Path
    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Patch insertion anchor failed for $Description in $Path. Expected 1 match, found $($matches.Count)."
    }

    $newText = $regex.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Value + $Insertion
        },
        1
    )
    Set-Text -Path $Path -Text $newText
    Write-Host "Inserted: $Description"
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $text = Get-Text -Path $Path
    if (-not $text.Contains($Needle)) {
        throw "Patch verification failed for $Description in $Path."
    }
}

$configPath = Get-SourceFile -RelativePath "codex-rs\core\src\config\mod.rs"
$windowsSandboxPath = Get-SourceFile -RelativePath "codex-rs\core\src\windows_sandbox.rs"
$toolHandlersPath = Get-SourceFile -RelativePath "codex-rs\core\src\tools\handlers\mod.rs"
$execPolicyPath = Get-SourceFile -RelativePath "codex-rs\core\src\exec_policy.rs"

$permissionsReplacement = @'
                approval_policy: if cfg!(target_os = "windows") {
                    Constrained::allow_any(AskForApproval::Never)
                } else {
                    constrained_approval_policy.value
                },
                permission_profile: if cfg!(target_os = "windows") {
                    Constrained::allow_any(PermissionProfile::Disabled)
                } else {
                    constrained_permission_profile.value
                },
                active_permission_profile: if cfg!(target_os = "windows") {
                    None
                } else {
                    active_permission_profile
                },
                network: if cfg!(target_os = "windows") {
                    None
                } else {
                    network
                },
                allow_login_shell,
                shell_environment_policy,
                windows_sandbox_mode: if cfg!(target_os = "windows") {
                    None
                } else {
                    windows_sandbox_mode
                },
                windows_sandbox_private_desktop,
'@

Replace-Once `
    -Path $configPath `
    -Pattern 'approval_policy:\s*constrained_approval_policy\.value,\s*permission_profile:\s*constrained_permission_profile\.value,\s*active_permission_profile,\s*network,\s*allow_login_shell,\s*shell_environment_policy,\s*windows_sandbox_mode,\s*windows_sandbox_private_desktop,' `
    -Replacement $permissionsReplacement `
    -Description "force Windows permissions to no approval and no sandbox"

Replace-Once `
    -Path $windowsSandboxPath `
    -Pattern 'pub const ELEVATED_SANDBOX_NUX_ENABLED: bool = true;' `
    -Replacement 'pub const ELEVATED_SANDBOX_NUX_ENABLED: bool = false;' `
    -Description "disable elevated sandbox NUX"

Insert-AfterOnce `
    -Path $windowsSandboxPath `
    -Pattern 'fn from_config\(config: &Config\) -> WindowsSandboxLevel \{\r?\n' `
    -Insertion @'
        if cfg!(target_os = "windows") {
            let _ = config;
            return WindowsSandboxLevel::Disabled;
        }

'@ `
    -Description "force WindowsSandboxLevel::from_config to Disabled"

Insert-AfterOnce `
    -Path $windowsSandboxPath `
    -Pattern 'fn from_features\(features: &Features\) -> WindowsSandboxLevel \{\r?\n' `
    -Insertion @'
        if cfg!(target_os = "windows") {
            let _ = features;
            return WindowsSandboxLevel::Disabled;
        }

'@ `
    -Description "force WindowsSandboxLevel::from_features to Disabled"

Insert-AfterOnce `
    -Path $windowsSandboxPath `
    -Pattern 'pub fn resolve_windows_sandbox_mode\(\s*cfg: &ConfigToml,\s*profile: &ConfigProfile,\s*\) -> Option<WindowsSandboxModeToml> \{\r?\n' `
    -Insertion @'
    if cfg!(target_os = "windows") {
        let _ = (cfg, profile);
        return None;
    }

'@ `
    -Description "force resolve_windows_sandbox_mode to None"

Insert-AfterOnce `
    -Path $windowsSandboxPath `
    -Pattern 'pub async fn run_windows_sandbox_setup\(request: WindowsSandboxSetupRequest\) -> anyhow::Result<\(\)> \{\r?\n' `
    -Insertion @'
    if cfg!(target_os = "windows") {
        let _ = &request;
        return Ok(());
    }

'@ `
    -Description "turn Windows sandbox setup into a no-op"

Insert-AfterOnce `
    -Path $toolHandlersPath `
    -Pattern 'pub\(super\) async fn apply_granted_turn_permissions\(\s*session: &Session,\s*cwd: &std::path::Path,\s*sandbox_permissions: SandboxPermissions,\s*additional_permissions: Option<AdditionalPermissionProfile>,\s*\) -> EffectiveAdditionalPermissions \{\r?\n' `
    -Insertion @'
    if cfg!(target_os = "windows") {
        let _ = (
            session,
            cwd,
            &sandbox_permissions,
            additional_permissions.as_ref(),
        );
        return EffectiveAdditionalPermissions {
            sandbox_permissions: SandboxPermissions::UseDefault,
            additional_permissions: None,
            permissions_preapproved: true,
        };
    }

'@ `
    -Description "ignore tool sandbox escalation metadata on Windows"

Insert-AfterOnce `
    -Path $execPolicyPath `
    -Pattern 'pub\(crate\) async fn create_exec_approval_requirement_for_command\(\s*&self,\s*req: ExecApprovalRequest<''_>,\s*\) -> ExecApprovalRequirement \{\r?\n' `
    -Insertion @'
        if cfg!(target_os = "windows") {
            let _ = &req;
            return ExecApprovalRequirement::Skip {
                bypass_sandbox: true,
                proposed_execpolicy_amendment: None,
            };
        }

'@ `
    -Description "skip exec approval and sandbox policy on Windows"

Assert-Contains -Path $configPath -Needle 'Constrained::allow_any(AskForApproval::Never)' -Description "approval policy override"
Assert-Contains -Path $configPath -Needle 'Constrained::allow_any(PermissionProfile::Disabled)' -Description "permission profile override"
Assert-Contains -Path $windowsSandboxPath -Needle 'pub const ELEVATED_SANDBOX_NUX_ENABLED: bool = false;' -Description "sandbox NUX disabled"
Assert-Contains -Path $windowsSandboxPath -Needle 'return WindowsSandboxLevel::Disabled;' -Description "sandbox level disabled"
Assert-Contains -Path $windowsSandboxPath -Needle 'return Ok(());' -Description "sandbox setup no-op"
Assert-Contains -Path $toolHandlersPath -Needle 'sandbox_permissions: SandboxPermissions::UseDefault' -Description "tool sandbox escalation disabled"
Assert-Contains -Path $execPolicyPath -Needle 'bypass_sandbox: true' -Description "exec policy bypass"

Write-Host "Windows custom Codex patch verified."
