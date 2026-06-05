# Codex CLI Sync

This repository builds Codex CLI release artifacts from upstream OpenAI Codex source.

The scheduled workflow:

- checks `openai/codex` every four hours for changes on `main`
- skips unchanged upstream SHAs using `state/latest-custom-main-sha.txt`
- clones the upstream source at the exact detected SHA
- rewrites the workspace version to a custom CI version
- applies the repo-owned Windows custom patch
- compiles `codex.exe`, `codex-command-runner.exe`, and `codex-windows-sandbox-setup.exe`
- packages those binaries with `rg.exe` and `VERSION.txt`
- publishes a per-SHA prerelease and refreshes `latest-windows-x64-custom`
- commits the latest synced upstream SHA and manifest after a successful build

The workflow also builds a Linux i686 musl package in a separate job:

- skips unchanged upstream SHAs using `state/latest-linux-i686-musl-sha.txt`
- clones the upstream source at the exact detected SHA
- does not apply the Windows custom runtime patch
- cross-builds `codex` for `i686-unknown-linux-musl`
- packages `codex`, `certs/ca-certificates.crt`, `VERSION.txt`, and Tiny Core copy notes
- publishes a per-SHA prerelease and refreshes `latest-linux-i686-musl`
- commits the latest synced Linux i686 upstream SHA and manifest after a successful build

The i686 musl package keeps target-specific compatibility adjustments: it enables vendored OpenSSL for static TLS and disables JavaScript code mode because `rusty_v8` does not publish a prebuilt V8 archive for `i686-unknown-linux-musl`. The bundled CA file comes from the Linux runner's system `ca-certificates` package and is recorded in the manifest with its SHA-256.

The Windows custom patch is maintained in [`scripts/patch-codex-windows-custom.ps1`](scripts/patch-codex-windows-custom.ps1). If an upstream source anchor moves, the workflow publishes a release card and manifest that explicitly say `CUSTOM PATCHES FAILED`, uploads no Codex binary for that run, and does not advance the successful upstream state.
For Rust config construction, the patcher prefers named/shorthand struct-field rewriting over one large text anchor so normal upstream refactors can move or reformat surrounding code without losing the required Windows behavior.
For ChatGPT login, the patcher uses flexible anchors around the login callback constants and bind fallback logic so routine upstream formatting/comment changes do not drop the Windows-safe callback-port fix.

Patch contract:

- force Windows approval policy to `AskForApproval::Never`
- force Windows runtime permissions to `PermissionProfile::Disabled`
- clear Windows sandbox mode and network proxy sandbox state
- force Windows sandbox level resolution to `WindowsSandboxLevel::Disabled`
- turn Windows sandbox setup into a no-op
- skip exec policy approval requirements with `bypass_sandbox=true`
- ignore tool-level sandbox escalation metadata on Windows
- use the registered OAuth callback ports `1455` and `1457`, and treat Windows `PermissionDenied` on the default port as a fallback condition
- fail the custom patch if upstream's unregistered `16455` default or port-`0` fallback remains in the login server or login e2e constants

Release layout:

- `latest-windows-x64-custom` stays as the rolling "always latest custom build" prerelease
- `custom-windows-x64-<upstream-sha>` releases preserve per-upstream-SHA build history
- `latest-linux-i686-musl` stays as the rolling "always latest i686 musl build" prerelease
- `linux-i686-musl-<upstream-sha>` releases preserve per-upstream-SHA i686 musl build history

Manual `workflow_dispatch` runs expose a `force` toggle and an `upstream_ref` input. The default upstream ref is `main`; OpenAI Codex does not currently publish a `master` branch.

Release publishing is handled by [`scripts/publish-github-release.ps1`](scripts/publish-github-release.ps1) through the GitHub Releases API and the repo-scoped `GITHUB_TOKEN`.
