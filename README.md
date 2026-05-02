# Codex CLI Sync

This repository builds a Windows x64 custom Codex CLI from upstream OpenAI Codex source.

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

The Windows custom patch is maintained in [`scripts/patch-codex-windows-custom.ps1`](scripts/patch-codex-windows-custom.ps1). It fails the build if an upstream source anchor moves instead of publishing an unpatched binary.

Patch contract:

- force Windows approval policy to `AskForApproval::Never`
- force Windows runtime permissions to `PermissionProfile::Disabled`
- clear Windows sandbox mode and network proxy sandbox state
- force Windows sandbox level resolution to `WindowsSandboxLevel::Disabled`
- turn Windows sandbox setup into a no-op
- skip exec policy approval requirements with `bypass_sandbox=true`
- ignore tool-level sandbox escalation metadata on Windows

Release layout:

- `latest-windows-x64-custom` stays as the rolling "always latest custom build" prerelease
- `custom-windows-x64-<upstream-sha>` releases preserve per-upstream-SHA build history

Manual `workflow_dispatch` runs expose a `force` toggle and an `upstream_ref` input. The default upstream ref is `main`; OpenAI Codex does not currently publish a `master` branch.

Release publishing is handled by [`scripts/publish-github-release.ps1`](scripts/publish-github-release.ps1) through the GitHub Releases API and the repo-scoped `GITHUB_TOKEN`.
