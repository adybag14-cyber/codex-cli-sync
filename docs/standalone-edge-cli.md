# Edge without the desktop app

`codex-edge` starts the selected custom Codex CLI locally and connects it to a
pinned Microsoft Playwright MCP process through private STDIO. That process
launches the installed Microsoft Edge browser. Neither the ChatGPT desktop app
nor its browser permission pipe or signing identity is used by this pipeline.

This is a separate browser backend from the desktop's CUA/IAB integration. It
uses an isolated Edge automation context, so it does not attach to existing
personal tabs or import saved website credentials. It runs headless with the
browser sandbox enabled. Browser state lasts for the MCP session and is discarded
when that session closes. Website sign-ins are separate from Codex sign-in.

The CLI uses its existing login from the selected `CODEX_HOME`. The browser MCP
server does not need an OAuth login: STDIO is the local child-process connection,
not a public HTTP endpoint. An MCP `auth_status` of `unsupported` describes the
absence of an OAuth interface, not a failed Codex login.

## Install

Requirements: the custom CLI with profile-file support, Microsoft Edge, and
Node.js 20 or newer. The pinned MCP package declares Node 18 support, but its
locked Playwright dependencies require Node 20.

From this repository:

```powershell
npm ci --prefix tools/CodexEdgeBrowser --omit=dev --ignore-scripts
./scripts/Install-CodexEdge.ps1 -CliPath C:/absolute/path/to/custom/bin/codex.exe
```

From a Windows release that includes the runtime:

```powershell
./codex-resources/Install-CodexEdge.ps1 -CliPath "$PWD/bin/codex.exe"
```

The installer creates a versioned runtime, a `codex-edge.config.toml` profile,
and `codex-edge.ps1` beside the selected CLI. It preserves base config and refuses
to overwrite an unmanaged profile. Reinstall for the selected executable after
a custom CLI update.

## Use

```powershell
codex-edge --edge-status
codex-edge
codex-edge resume <task-id>
```

The status command reports desktop-context variable names only if any remain,
then runs the normal CLI login-status command. A correct independent launch
reports an empty list and uses the same account already signed into the CLI.

The profile enables `codex_edge` and disables desktop-only browser tools and the
older browser endpoints only for this profile. Other base settings, model choice,
hooks, and non-desktop integrations are inherited. Use the `codex_edge` MCP tools
for browsing. This MCP release can export snapshots to files; read the exact
returned snapshot path to identify elements before interaction.

`codex-edge` strips inherited desktop pipe/context variables and uses the local
CLI rather than `--remote`. It does not forge signed desktop approvals, change
the desktop's browser settings, or weaken the existing desktop integration.

If the current task runs through `codex-desktop`, exit that session before
resuming it with `codex-edge`. Closing the desktop while still attached to its
shared server ends that old connection. Once the task uses `codex-edge`, the
desktop is not part of the Edge browser process lifecycle.

## Checks

```powershell
python scripts/test-codex-edge-runtime.py --runtime tools/CodexEdgeBrowser --output out/edge-checks
python scripts/test-codex-edge-install.py --cli C:/absolute/path/to/custom/bin/codex.exe --runtime tools/CodexEdgeBrowser
```

The runtime check removes desktop context, starts the actual pinned MCP server,
navigates the installed Edge to a loopback fixture, clicks an observed element,
reads the visible result, checks `navigator.userAgent`, saves a screenshot, and
closes the browser and server. It does not use a mock browser or model.

On 7 November 2026, eight runtime checks passed locally with Edge reporting
`Edg/156.0.0.0`. A real `codex-edge exec` run also completed with exit code 0,
used `codex_edge` for all browser actions, verified the click result, saved its
screenshot, and closed the test browser. The existing CLI login remained ChatGPT
authenticated with all desktop connection variables absent. The desktop process
was still hosting the original conversation during those tests; the final
desktop-closed check follows the conversation's switch to `codex-edge`.

A native `codex-edge resume` of a previously desktop-backed diagnostic task also
passed: it used `codex_edge` to open `about:blank`, read `Edg/156.0.0.0`, close the
browser, and exit with code 0. Five installer checks passed against the actual
custom CLI in a disposable home, including preservation of base config and
refusal to overwrite a user-managed profile.

The pinned dependencies are recorded with npm integrity hashes. Packaging uses
`npm ci --ignore-scripts`, runs the runtime and installer checks, and records
their counts and the lockfile hash in the release manifest.

References: [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp)
and [Microsoft Playwright MCP](https://github.com/microsoft/playwright-mcp).
