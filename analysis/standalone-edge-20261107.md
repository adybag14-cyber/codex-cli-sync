# Standalone Edge validation — 7 November 2026

The requested scope is Edge through the custom CLI with no desktop process;
the built-in in-app browser is excluded.

Components tested:

- Custom CLI `0.168.0-202611060057`, existing installed executable.
- Microsoft `@playwright/mcp` pinned to `0.0.84` with npm integrity hashes.
- Locked Playwright `1.65.0-alpha-2026-10-30`; Node.js `26.13.0`.
- Installed Edge reported `Edg/156.0.0.0` from the live browser.
- Dependency lock SHA-256:
  `871392a5ec4151fcc16355490a6d76afb8c6b46c000b4c8260ef508d38baa7d4`.

The `codex-edge` launcher selects a separate profile and starts the same custom
CLI locally. Its diagnostic child reported no desktop connection variables and
the native CLI reported `Logged in using ChatGPT`. Browser control uses the
Microsoft MCP runtime over private STDIO, with `--browser msedge --headless
--isolated --sandbox`. It has no desktop permission-service client and does not
create or copy desktop credentials.

Eight direct runtime checks passed: real MCP initialization and tool discovery,
absence of desktop context, local HTTP navigation, snapshot-derived button click,
visible changed state, Edge user-agent confirmation, screenshot output, and
browser/process cleanup (the report groups discovery and initialization).
The packaged runtime passed the same checks.

Five real-CLI installer checks passed in a disposable Codex home: base-config
preservation, valid transport overrides from that selected home, native parsing
of the generated profile, removal of inherited desktop context without login
credential copying, and refusal to overwrite an unmanaged profile/launcher.

A real `codex-edge exec` smoke turn completed with exit code 0. It said hello,
called only `codex_edge` for browser control, opened the loopback fixture, read
the exported snapshots, clicked `Verify interaction`, observed
`Interaction verified`, checked the Edge user agent, saved `standalone-cli.png`,
and closed the browser. A native TUI resume of the earlier desktop-backed
diagnostic task also opened `about:blank` through `codex_edge`, read the Edge
user agent, closed the browser, and exited with code 0.

The dependency installation/audit reported zero vulnerabilities. The 187
repository compatibility checks passed; PowerShell and workflow YAML parsed.
Packaging now includes the pinned runtime, installer, launcher, documentation,
check reports, and dependency-lock identity. CI source inputs include the lockfile
and packaged documentation while excluding generated `node_modules`.

Evidence is generated locally under `out/codex-edge-runtime-checks/`,
`out/codex-edge-cli-smoke/`, `out/standalone-edge-checks/`, and
`out/codex-edge-installer-checks.json`.

Verification limit: the original conversation still ran through the desktop
bridge while these independent child tests ran. The desktop process was not
stopped during this turn, because it currently hosts that conversation. The
remaining end-to-end check is to resume the original task using `codex-edge`,
stop the desktop, and repeat Edge navigation from that standalone session.
