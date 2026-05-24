---
name: github-actions-ci-debugger
description: debug and repair GitHub Actions failures from a local checkout using host/devbox tools and GitHub CLI. Use when asked to inspect a repository's Actions runs, diagnose failing jobs, patch workflow or script issues, commit/push fixes, rerun workflows, and verify that final CI runs are green. Especially useful for Windows runner, cache, release, artifact, and git authentication failures.
---

# GitHub Actions CI Debugger

Use host/devbox tools throughout. Prefer read-only inspection until a fix is identified, then make minimal patches and validate them.

## Workflow

1. Locate the checkout and confirm repo identity.
   - Use host search for the repo directory when only a GitHub URL is supplied.
   - Confirm `git remote -v`, current branch, and working-tree state.

2. Inspect GitHub Actions failures.
   - Use `gh run list --limit 10` in the checkout.
   - Use `gh run view <run_id>` for job/step status.
   - Use `gh run view <run_id> --log-failed` for failing logs.
   - Compare multiple failures before patching; distinguish transient failures from deterministic workflow issues.

3. Diagnose from the earliest failing step.
   - If a setup/cache/action step fails before project scripts run, patch workflow resilience first.
   - For `actions/cache` failures, prefer split `actions/cache/restore` and `actions/cache/save`, deterministic cache keys, narrow restore prefixes, and `continue-on-error: true` if cache is non-critical.
   - For git push failures in Actions, explicitly provide the Actions token, set bot identity, and push to `origin HEAD:$GITHUB_REF_NAME`.
   - For runner migration notices, pin to an explicit runner image when the workflow is Windows-specific.

4. Patch minimally.
   - Keep workflow names and outputs stable unless the failure requires a breaking change.
   - Avoid committing generated build outputs unless the repo already tracks them intentionally.
   - Update README or references only when they help future operators.

5. Validate locally.
   - Run YAML/syntax checks available in the repo.
   - Run PowerShell parser checks for edited `.ps1` files or workflow script blocks when feasible.
   - Run `git diff --check` before commit.

6. Commit, push, and verify remotely.
   - Commit with a concise message describing the CI fix.
   - Push the current branch.
   - Trigger a workflow with `gh workflow run <workflow-file>` when needed.
   - Poll `gh run list`/`gh run view` until the relevant run completes.
   - Report the final run conclusion and link. If verification cannot be completed, state exactly why and include the latest run status.

## Output style

Summarize:
- local checkout path
- failing run IDs and failed step(s)
- root cause
- changed files
- validation performed
- final GitHub Actions status
