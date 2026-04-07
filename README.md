# Codex CLI Sync

This repository tracks the latest OpenAI Codex Rust alpha for Windows x64.

The scheduled workflow:

- checks `openai/codex` every hour for the newest `rust-v*-alpha.*` release
- downloads all Windows x64 release assets plus `install.ps1`
- repackages them into one rolling bundle zip
- publishes a versioned GitHub prerelease for each newly detected upstream tag
- uploads the bundle as a workflow artifact
- refreshes a rolling GitHub Release named `latest-windows-x64-alpha`
- commits a small state file so unchanged hourly runs can skip work

The latest synced upstream tag is stored in `state/latest-alpha-tag.txt`.

Release layout:

- `latest-windows-x64-alpha` stays as the rolling "always latest" prerelease
- `rust-v...-alpha...` releases preserve per-version history on the Releases page

The workflow also runs on pushes that touch the workflow, script, or README so release-pipeline changes get an immediate validation run without triggering on the state-file commits produced by the sync job.

Manual `workflow_dispatch` runs expose a `force` toggle that republishes the current upstream tag, which is useful for repairing or backfilling the versioned release history without waiting for a newer upstream alpha.
