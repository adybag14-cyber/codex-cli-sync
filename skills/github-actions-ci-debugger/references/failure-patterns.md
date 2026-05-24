# Common GitHub Actions failure patterns

## Cache failures

`actions/cache@v4` combines restore and save in one action. If restore/save is not critical, split it:

- `actions/cache/restore@v4` before the build
- `actions/cache/save@v4` after the build
- `continue-on-error: true` on both cache steps
- deterministic keys based on runner OS and relevant file hashes
- narrow restore prefixes so incompatible caches are less likely to restore

## Windows runner drift

When a workflow depends on Windows tooling, pin `runs-on` to a specific supported image such as `windows-2025` instead of `windows-latest` when GitHub announces migration behavior.

## Git push prompts

If Actions logs show `could not read Username for 'https://github.com': terminal prompts disabled`, push with the token explicitly available:

```powershell
git -c http.extraheader="AUTHORIZATION: bearer $env:GITHUB_TOKEN" push origin HEAD:$env:GITHUB_REF_NAME
```

Ensure `permissions: contents: write` and `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` are set for the step.
