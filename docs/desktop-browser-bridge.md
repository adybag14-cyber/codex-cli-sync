# Desktop browser bridge for the custom Windows CLI

This opt-in adapter lets the desktop app and terminal connect to the same custom
Codex app server. It preserves the desktop's browser authorization service;
it does not issue browser permissions or copy another session's credentials.

The installed desktop app creates its browser permission pipe and signing key
and passes connection information to the core process it starts. A separately
started CLI does not inherit that context. On Windows the inspected desktop build
also skips its local-daemon transport. The adapter uses the existing executable
override and app-server WebSocket transport to share one desktop-started server.

```text
Desktop app -> bridge STDIO adapter -> custom app server <- terminal CLI
      |                                    |
      +--- unchanged signed browser host <-+
```

The adapter forwards the desktop's JSON messages without changing client names,
thread IDs, account identity, or permission decisions. The app server broadcasts
new thread notifications to the connected desktop. The desktop's existing
session/account tracking and browser settings still decide whether access is
allowed. An inherited environment is necessary but is not proof of permission.

The shared transport binds only to `127.0.0.1` and requires a fresh random
capability token. This token authenticates the app-server connection; it is not
a browser authorization token. Its temporary directory permits only the current
Windows user and SYSTEM. Status output omits the token. Closing the desktop's
STDIO connection normally stops the specific app-server child and removes its
token. Forced process termination can leave a private record; attach ignores
stale records by checking both process identities and creation times.

## Build and check

```powershell
dotnet publish tools/CodexDesktopBridge/CodexDesktopBridge.csproj `
  -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true `
  -o out/desktop-bridge
python scripts/test-desktop-bridge.py `
  --bridge out/desktop-bridge/codex-desktop-bridge.exe `
  --cli C:/absolute/path/to/custom/bin/codex.exe
```

The integration test uses an isolated Codex home and the actual custom app server.
It checks two independent clients, global thread notifications, missing/incorrect
token rejection, private ACLs, credential cleanup, large Unicode messages, the
desktop's one-shot startup-policy response, and refusal to attach without
desktop browser context. It does not log in, start a model turn, emulate a browser
permission host, or claim that browser automation has passed.

## Install and activate

```powershell
./scripts/Install-CodexDesktopBridge.ps1 -CliPath C:/absolute/path/to/custom/bin/codex.exe
```

The installer prints the desktop launcher path and installs `codex-desktop.ps1`
next to the selected custom CLI. The ordinary `codex` command remains unchanged.
The selected custom executable is pinned in the bridge configuration; rerun the
installer after installing another custom release.

Future Windows release packages bundle the adapter under
`codex-resources/desktop-bridge/` with the installer and launcher beside that
directory. From the extracted package root, run:

```powershell
./codex-resources/Install-CodexDesktopBridge.ps1 -CliPath "$PWD/bin/codex.exe"
```

Packaging runs the bridge transport checks against that release's actual CLI
and records the adapter digest and check count in the release manifest.

Finish or pause desktop work, quit the desktop app fully, then run the printed
`Start-CodexDesktopWithBridge.ps1` path. It sets the executable override only for
that desktop process. It refuses to terminate an already-running desktop.

Run `codex-desktop` in a fresh PowerShell terminal. With multiple desktop app
servers, inspect the adapter with `--bridge-status` and pass the selected
`--instance <bridgePid>` immediately after `--bridge-connect`. The attach command
rejects stale process records and servers missing desktop browser host context.

Resume the intended task in the terminal. Browser operations must still use the
normal installed Browser/CUA tool and obey its permission responses. A missing
desktop account/session association, unavailable service, or denied permission
remains an error; the adapter does not grant it.

## Rollback and live verification

Quit the desktop app and reopen its ordinary shortcut. The executable override
was process-local, so no desktop setting or environment variable needs undoing.
The installer leaves the existing Codex executable and browser plugins intact.

On 6 November 2026, the 13 transport checks passed against custom CLI
`0.168.0-202611060057`. After a desktop restart through the launcher:

- The desktop launched the installed custom server and supplied all three browser
  host variables. Account status remained ChatGPT authenticated.
- A real `gpt-6-astra` CLI turn used the unchanged CUA tool to enumerate Edge,
  create `about:blank`, inspect its accessibility state, and close the test tab.
  This exercised the actual desktop browser permission host, not a mock.
- A separate persistent CLI turn replied `Hello - browser bridge verification is ready.`
- An ephemeral CLI task had no IAB provider and returned
  `Browser is not available: iab`. IAB is tied to a desktop chat/window; the
  transport adapter does not create that UI association or claim IAB success.

A direct MCP call made outside a turn was rejected with
`Cannot verify browser access without the current turn`. This check is preserved.
Do not supply fabricated turn metadata to work around it; use a normal CLI turn.
