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

function Ensure-RustCrateRecursionLimit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Minimum = 256
    )

    $text = Get-Text -Path $Path
    $pattern = '(?m)^#!\[recursion_limit\s*=\s*"(?<value>\d+)"\]\s*\r?\n'
    $match = [regex]::Match($text, $pattern)
    if ($match.Success) {
        $current = [int]$match.Groups['value'].Value
        if ($current -ge $Minimum) {
            Write-Host "Kept: Rust recursion limit $current in $Path"
            return $false
        }
        $regex = [regex]::new($pattern)
        $text = $regex.Replace($text, "#![recursion_limit = `"$Minimum`"]`n", 1)
    } else {
        $text = "#![recursion_limit = `"$Minimum`"]`n" + $text
    }

    Set-Text -Path $Path -Text $text
    Write-Host "Patched: raise Rust recursion limit to $Minimum in $Path"
    return $true
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

function Replace-Optional {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $text = Get-Text -Path $Path
    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $matches = $regex.Matches($text)
    if ($matches.Count -eq 0) {
        Write-Host "Skipped optional patch: $Description"
        return
    }
    if ($matches.Count -ne 1) {
        throw "Optional patch anchor failed for $Description in $Path. Expected 0 or 1 matches, found $($matches.Count)."
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

function Find-MatchingBrace {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$OpenBraceIndex
    )

    $depth = 0
    for ($i = $OpenBraceIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq "{") {
            $depth++
        } elseif ($ch -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }

    throw "Could not find matching closing brace."
}

function Set-RustStructFieldInitializer {
    param(
        [Parameter(Mandatory = $true)][string]$Block,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $escapedFieldName = [regex]::Escape($FieldName)
    $fieldRegex = [regex]::new("(?m)^(\s*$escapedFieldName\s*:\s*)")
    $matches = $fieldRegex.Matches($Block)
    if ($matches.Count -eq 0) {
        $shorthandRegex = [regex]::new("(?m)^(\s*)$escapedFieldName\s*,")
        $shorthandMatches = $shorthandRegex.Matches($Block)
        if ($shorthandMatches.Count -eq 1) {
            $match = $shorthandMatches[0]
            $prefix = $match.Groups[1].Value + $FieldName + ": "
            return $Block.Substring(0, $match.Index) + $prefix + $Replacement + $Block.Substring($match.Index + $match.Length - 1)
        }

        throw "Expected exactly one '$FieldName' field in Rust struct block, found 0 named initializers and $($shorthandMatches.Count) shorthand initializers."
    }

    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$FieldName' field in Rust struct block, found $($matches.Count)."
    }

    $match = $matches[0]
    $valueStart = $match.Index + $match.Length
    $depth = 0
    for ($i = $valueStart; $i -lt $Block.Length; $i++) {
        $ch = $Block[$i]
        if ($ch -eq "(" -or $ch -eq "{" -or $ch -eq "[") {
            $depth++
        } elseif ($ch -eq ")" -or $ch -eq "}" -or $ch -eq "]") {
            $depth--
        } elseif ($ch -eq "," -and $depth -eq 0) {
            return $Block.Substring(0, $valueStart) + $Replacement + $Block.Substring($i)
        }
    }

    throw "Could not find initializer terminator for Rust field '$FieldName'."
}

function Set-ConfigPermissionsForWindowsCustom {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = Get-Text -Path $Path
    $permissionsMatch = [regex]::Match($text, 'permissions\s*:\s*Permissions\s*\{')
    if (-not $permissionsMatch.Success) {
        return $false
    }

    $openBrace = $text.IndexOf("{", $permissionsMatch.Index)
    $closeBrace = Find-MatchingBrace -Text $text -OpenBraceIndex $openBrace
    $blockStart = $openBrace + 1
    $block = $text.Substring($blockStart, $closeBrace - $blockStart)

    $block = Set-RustStructFieldInitializer -Block $block -FieldName "approval_policy" -Replacement @'
if cfg!(target_os = "windows") {
                    Constrained::allow_any(AskForApproval::Never)
                } else {
                    constrained_approval_policy.value
                }
'@

    $block = Set-RustStructFieldInitializer -Block $block -FieldName "permission_profile_state" -Replacement @'
if cfg!(target_os = "windows") {
                    PermissionProfileState::from_constrained_legacy(
                        Constrained::allow_any(PermissionProfile::Disabled),
                    )
                    .map_err(std::io::Error::from)?
                } else {
                    permission_profile_state
                }
'@

    $block = Set-RustStructFieldInitializer -Block $block -FieldName "network" -Replacement @'
if cfg!(target_os = "windows") {
                    None
                } else {
                    network
                }
'@

    $block = Set-RustStructFieldInitializer -Block $block -FieldName "windows_sandbox_mode" -Replacement @'
if cfg!(target_os = "windows") {
                    None
                } else {
                    windows_sandbox_mode
                }
'@

    $newText = $text.Substring(0, $blockStart) + $block + $text.Substring($closeBrace)
    Set-Text -Path $Path -Text $newText
    Write-Host "Patched: force Windows permissions to no approval and no sandbox"
    return $true
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

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $text = Get-Text -Path $Path
    if ($text.Contains($Needle)) {
        throw "Patch verification failed for $Description in $Path."
    }
}

function Disable-WindowsSandboxOnboardingHint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = Get-Text -Path $Path
    $marker = '// codex-cli-sync: Windows custom build never shows the sandbox onboarding hint.'
    if ($text.Contains($marker)) {
        Write-Host "Kept: Windows sandbox onboarding hint is already disabled"
        return $true
    }

    if (-not $text.Contains('show_windows_create_sandbox_hint')) {
        Write-Host "Skipped optional patch: upstream removed the Windows sandbox onboarding hint"
        return $false
    }

    $currentPattern = '(?ms)#\[cfg\(target_os\s*=\s*"windows"\)\]\s*let\s+show_windows_create_sandbox_hint\s*=\s*remote_project_trust\.is_none\(\)\s*&&\s*crate::windows_sandbox::level_from_config\(&config\)\s*==\s*WindowsSandboxLevel::Disabled;'
    $currentRegex = [regex]::new($currentPattern)
    $currentMatches = $currentRegex.Matches($text)
    if ($currentMatches.Count -eq 1) {
        $replacement = @'
#[cfg(target_os = "windows")]
        let show_windows_create_sandbox_hint = {
            // codex-cli-sync: Windows custom build never shows the sandbox onboarding hint.
            let _ = remote_project_trust.is_none()
                && crate::windows_sandbox::level_from_config(&config)
                    == WindowsSandboxLevel::Disabled;
            false
        };
'@
        $newText = $currentRegex.Replace(
            $text,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement },
            1
        )
        Set-Text -Path $Path -Text $newText
        Write-Host "Patched: disable current Windows sandbox onboarding hint"
        return $true
    }
    if ($currentMatches.Count -gt 1) {
        throw "Windows sandbox onboarding patch found multiple current-form anchors in $Path."
    }

    $legacyPattern = 'let\s+show_windows_create_sandbox_hint\s*=\s*crate::windows_sandbox::level_from_config\(&config\)\s*==\s*WindowsSandboxLevel::Disabled;'
    $legacyRegex = [regex]::new($legacyPattern)
    $legacyMatches = $legacyRegex.Matches($text)
    if ($legacyMatches.Count -eq 1) {
        $replacement = @'
let show_windows_create_sandbox_hint = {
            // codex-cli-sync: Windows custom build never shows the sandbox onboarding hint.
            let _ =
                crate::windows_sandbox::level_from_config(&config) == WindowsSandboxLevel::Disabled;
            false
        };
'@
        $newText = $legacyRegex.Replace(
            $text,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement },
            1
        )
        Set-Text -Path $Path -Text $newText
        Write-Host "Patched: disable legacy Windows sandbox onboarding hint"
        return $true
    }
    if ($legacyMatches.Count -gt 1) {
        throw "Windows sandbox onboarding patch found multiple legacy anchors in $Path."
    }

    $falseOnly = [regex]::Matches($text, '(?m)^\s*let\s+show_windows_create_sandbox_hint\s*=\s*false;\s*$')
    $hasWindowsHintExpression = $text.Contains('crate::windows_sandbox::level_from_config(&config) == WindowsSandboxLevel::Disabled')
    if ($falseOnly.Count -ge 1 -and -not $hasWindowsHintExpression) {
        Write-Host "Kept: upstream already hard-disables the Windows sandbox onboarding hint"
        return $false
    }

    throw "Upstream Windows sandbox onboarding hint contract changed in $Path; variable still exists but no supported safe form was recognized."
}

function Set-LoginCallbackPortForWindowsCustom {
    param(
        [Parameter(Mandatory = $true)][string]$ServerPath,
        [Parameter(Mandatory = $true)][string]$TestPath
    )

    Replace-Once `
        -Path $ServerPath `
        -Pattern 'const\s+DEFAULT_PORT\s*:\s*u16\s*=\s*\d+\s*;\s*(?://[^\r\n]*(?:\r?\n))*\s*const\s+FALLBACK_PORT\s*:\s*u16\s*=\s*\d+\s*;' `
        -Replacement @'
const DEFAULT_PORT: u16 = 1455;
// Keep in sync with the Codex CLI Hydra redirect URI allow-list.
const FALLBACK_PORT: u16 = 1457;
'@ `
        -Description "keep login callback server on registered OAuth redirect ports"

    Replace-Once `
        -Path $ServerPath `
        -Pattern 'let\s+(?<name>is_[A-Za-z0-9_]+)\s*=\s*err\s*\r?\n\s*\.downcast_ref::<io::Error>\(\)\s*\r?\n\s*\.map\(\|io_err\|\s*(?:io_err\.kind\(\)\s*==\s*io::ErrorKind::AddrInUse|\{\s*matches!\(\s*io_err\.kind\(\),\s*io::ErrorKind::AddrInUse(?:\s*\|\s*io::ErrorKind::PermissionDenied)?\s*\)\s*\})\s*\)\s*\r?\n\s*\.unwrap_or\(false\);' `
        -Replacement @'
let is_port_unavailable = err
                    .downcast_ref::<io::Error>()
                    .map(|io_err| {
                        matches!(
                            io_err.kind(),
                            io::ErrorKind::AddrInUse | io::ErrorKind::PermissionDenied
                        )
                    })
                    .unwrap_or(false);
'@ `
        -Description "treat Windows access-denied port reservations as fallback candidates"

    Replace-Once `
        -Path $ServerPath `
        -Pattern 'if\s+is_[A-Za-z0-9_]+\s*\{' `
        -Replacement 'if is_port_unavailable {' `
        -Description "use registered fallback port for unavailable login callback ports"

    Replace-Optional `
        -Path $ServerPath `
        -Pattern '"default login callback port is unavailable; falling back to [^"]+"' `
        -Replacement '"default login callback port is unavailable; falling back to the registered fallback port"' `
        -Description "update login fallback diagnostic"

    Replace-Once `
        -Path $TestPath `
        -Pattern 'const\s+DEFAULT_LOGIN_PORT\s*:\s*u16\s*=\s*\d+\s*;\r?\nconst\s+FALLBACK_LOGIN_PORT\s*:\s*u16\s*=\s*\d+\s*;' `
        -Replacement @'
const DEFAULT_LOGIN_PORT: u16 = 1455;
const FALLBACK_LOGIN_PORT: u16 = 1457;
'@ `
        -Description "update login callback test constants"
}

$configPath = Get-SourceFile -RelativePath "codex-rs\core\src\config\mod.rs"
$windowsSandboxPath = Get-SourceFile -RelativePath "codex-rs\core\src\windows_sandbox.rs"
$toolHandlersPath = Get-SourceFile -RelativePath "codex-rs\core\src\tools\handlers\mod.rs"
$execPolicyPath = Get-SourceFile -RelativePath "codex-rs\core\src\exec_policy.rs"
$loginServerPath = Get-SourceFile -RelativePath "codex-rs\login\src\server.rs"
$loginServerE2ePath = Get-SourceFile -RelativePath "codex-rs\login\tests\suite\login_server_e2e.rs"
$tuiLibPath = Get-SourceFile -RelativePath "codex-rs\tui\src\lib.rs"
$onboardingScreenPath = Get-SourceFile -RelativePath "codex-rs\tui\src\onboarding\onboarding_screen.rs"
$mcpServerLibPath = Get-SourceFile -RelativePath "codex-rs\mcp-server\src\lib.rs"

$mcpServerRecursionLimitPatched = Ensure-RustCrateRecursionLimit -Path $mcpServerLibPath -Minimum 256

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

if (-not (Set-ConfigPermissionsForWindowsCustom -Path $configPath)) {
    Replace-Once `
        -Path $configPath `
        -Pattern 'approval_policy:\s*constrained_approval_policy\.value,\s*permission_profile:\s*constrained_permission_profile\.value,\s*active_permission_profile,\s*network,\s*allow_login_shell,\s*shell_environment_policy,\s*windows_sandbox_mode,\s*windows_sandbox_private_desktop,' `
        -Replacement $permissionsReplacement `
        -Description "force Windows permissions to no approval and no sandbox"
}

Set-LoginCallbackPortForWindowsCustom -ServerPath $loginServerPath -TestPath $loginServerE2ePath

# The original elevated-sandbox NUX kill switch was removed upstream in July 2026.
# Keep supporting older revisions, but patch the active startup and onboarding
# decisions as the durable contract on newer revisions.
Replace-Optional `
    -Path $windowsSandboxPath `
    -Pattern 'pub const ELEVATED_SANDBOX_NUX_ENABLED: bool = true;' `
    -Replacement 'pub const ELEVATED_SANDBOX_NUX_ENABLED: bool = false;' `
    -Description "disable legacy elevated sandbox NUX kill switch"

Replace-Once `
    -Path $tuiLibPath `
    -Pattern 'let\s+should_prompt_windows_sandbox_nux_at_startup\s*=\s*\(trust_decision_was_made\s*&&\s*windows_sandbox_level\s*==\s*WindowsSandboxLevel::Disabled\)\s*\|\|\s*required_elevated_sandbox_needs_setup;' `
    -Replacement @'
let should_prompt_windows_sandbox_nux_at_startup = {
        let _ = (
            &trust_decision_was_made,
            &windows_sandbox_level,
            &required_elevated_sandbox_needs_setup,
        );
        false
    };
'@ `
    -Description "disable Windows sandbox startup NUX prompt"

$sandboxOnboardingHintManaged = Disable-WindowsSandboxOnboardingHint -Path $onboardingScreenPath

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
    -Pattern 'pub fn resolve_windows_sandbox_mode\(\s*cfg: &ConfigToml,?\s*(?:profile: &ConfigProfile,?\s*)?\) -> Option<WindowsSandboxModeToml> \{\r?\n' `
    -Insertion @'
    if cfg!(target_os = "windows") {
        let _ = cfg;
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
    -Pattern 'pub\(super\) async fn apply_granted_turn_permissions\(\s*session: &Session,\s*(?:environment_id: &str,\s*)?cwd: &(?:std::path::)?Path,\s*sandbox_permissions: SandboxPermissions,\s*additional_permissions: Option<AdditionalPermissionProfile>,\s*\) -> EffectiveAdditionalPermissions \{\r?\n' `
    -Insertion @'
    if cfg!(target_os = "windows") {
        let _ = (
            session,
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

Assert-Contains -Path $mcpServerLibPath -Needle '#![recursion_limit = "256"]' -Description "mcp-server recursion limit"
Assert-Contains -Path $configPath -Needle 'Constrained::allow_any(AskForApproval::Never)' -Description "approval policy override"
Assert-Contains -Path $configPath -Needle 'Constrained::allow_any(PermissionProfile::Disabled)' -Description "permission profile override"
Assert-Contains -Path $tuiLibPath -Needle 'let should_prompt_windows_sandbox_nux_at_startup = {' -Description "sandbox startup NUX disabled"
if ($sandboxOnboardingHintManaged) {
    Assert-Contains -Path $onboardingScreenPath -Needle '// codex-cli-sync: Windows custom build never shows the sandbox onboarding hint.' -Description "sandbox onboarding hint disabled"
}
Assert-Contains -Path $windowsSandboxPath -Needle 'return WindowsSandboxLevel::Disabled;' -Description "sandbox level disabled"
Assert-Contains -Path $windowsSandboxPath -Needle 'return Ok(());' -Description "sandbox setup no-op"
Assert-Contains -Path $toolHandlersPath -Needle 'sandbox_permissions: SandboxPermissions::UseDefault' -Description "tool sandbox escalation disabled"
Assert-Contains -Path $execPolicyPath -Needle 'bypass_sandbox: true' -Description "exec policy bypass"
Assert-Contains -Path $loginServerPath -Needle 'const DEFAULT_PORT: u16 = 1455;' -Description "registered default login callback port"
Assert-Contains -Path $loginServerPath -Needle 'const FALLBACK_PORT: u16 = 1457;' -Description "registered fallback login callback port"
Assert-Contains -Path $loginServerE2ePath -Needle 'const DEFAULT_LOGIN_PORT: u16 = 1455;' -Description "registered default login callback test port"
Assert-Contains -Path $loginServerE2ePath -Needle 'const FALLBACK_LOGIN_PORT: u16 = 1457;' -Description "registered fallback login callback test port"
Assert-Contains -Path $loginServerPath -Needle 'io::ErrorKind::PermissionDenied' -Description "login callback access-denied fallback"
Assert-NotContains -Path $loginServerPath -Needle 'const DEFAULT_PORT: u16 = 16455;' -Description "unregistered login callback default port"
Assert-NotContains -Path $loginServerPath -Needle 'const FALLBACK_PORT: u16 = 0;' -Description "unregistered port-zero login callback fallback"
Assert-NotContains -Path $loginServerE2ePath -Needle 'const DEFAULT_LOGIN_PORT: u16 = 16455;' -Description "unregistered login callback test default port"
Assert-NotContains -Path $loginServerE2ePath -Needle 'const FALLBACK_LOGIN_PORT: u16 = 0;' -Description "unregistered port-zero login callback test fallback"

Write-Host "Windows custom Codex patch verified."
