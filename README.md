# Codex CLI Sync

This repository tracks the latest OpenAI Codex Rust alpha for Windows x64.

The scheduled workflow:

- checks `openai/codex` every hour for the newest `rust-v*-alpha.*` release
- downloads all Windows x64 release assets plus `install.ps1`
- repackages them into one rolling bundle zip
- uploads the bundle as a workflow artifact
- refreshes a rolling GitHub Release named `latest-windows-x64-alpha`
- commits a small state file so unchanged hourly runs can skip work

The latest synced upstream tag is stored in `state/latest-alpha-tag.txt`.
