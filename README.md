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

The i686 musl package keeps target-specific compatibility adjustments: it enables vendored OpenSSL for static TLS, uses the lock-based atomic fallback required by Zig's 32-bit musl linker, clears restored `openssl-sys` target artifacts so cached builds pick up those C flags, forces `lzma-sys` to compile its bundled liblzma instead of accepting the runner host's pkg-config archive, enables BLAKE3's pure Rust path for i686, raises the `codex-mcp-server` recursion limit to 256 where current upstream release builds require it, and normalizes Linux sandbox syscall constants for 32-bit musl compilation. Before doing any Rusty V8 work, the sync script resolves the actual target-specific `codex-cli` Cargo graph. Current upstream no longer includes `v8` in that graph, so CI skips the obsolete multi-gigabyte Rusty V8 source/cache path. If upstream makes `v8` a real `codex-cli` dependency again, the existing audited i686 Rusty V8 source-build compatibility path is enabled automatically and verifies the produced archive as real 32-bit i386. The bundled CA file comes from the Linux runner's system `ca-certificates` package and is recorded in the manifest with its SHA-256.

The Windows custom patch is maintained in [`scripts/patch-codex-windows-custom.ps1`](scripts/patch-codex-windows-custom.ps1). If an upstream source anchor moves, the workflow publishes a release card and manifest that explicitly say `CUSTOM PATCHES FAILED`, uploads no Codex binary for that run, and does not advance the successful upstream state.
For Rust config construction, the patcher prefers named/shorthand struct-field rewriting over one large text anchor so normal upstream refactors can move or reformat surrounding code without losing the required Windows behavior.
For ChatGPT login, the patcher uses flexible anchors around the login callback constants and bind fallback logic so routine upstream formatting/comment changes do not drop the Windows-safe callback-port fix.
For Windows sandbox onboarding, the patcher recognizes both the legacy and current upstream forms, preserves newly-added trust conditions as a deliberately-unused expression, and treats an upstream-removed hint as already satisfied instead of failing on a vanished text anchor.

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

Manual `workflow_dispatch` runs expose `force`, `upstream_ref`, `run_target`, and `dry_run` inputs. `run_target` can isolate either failing build, while `dry_run` suppresses release/state mutations but still builds and uploads artifacts. The default upstream ref is `main`; OpenAI Codex does not currently publish a `master` branch.

Release publishing is handled by [`scripts/publish-github-release.ps1`](scripts/publish-github-release.ps1) through the GitHub Releases API and the repo-scoped `GITHUB_TOKEN`.
