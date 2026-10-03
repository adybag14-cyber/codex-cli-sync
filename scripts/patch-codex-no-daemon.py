"""Disable the shared local daemon without changing the embedded/remote app-server API.

Validate the complete source contract before writing any file. Retain upstream
command parsing so old launchers receive a useful error instead of starting a
daemon or silently changing an existing managed installation.
"""

import argparse
from pathlib import Path
import re


ERROR = "The local daemon is disabled in this custom build; run codex directly."
MARKER = "// codex-cli-sync: local sessions use the embedded app server."
CONSTANT = "pub const LOCAL_DAEMON_ENABLED: bool = false;"
PUBLIC_EXPORTS = {
    "pubusebackend::windows::DetachedLaunchRestricted;",
    "pubuselaunch::restart_with_features;",
    "pubuselaunch::start_with_features;",
    "pubuseprepare_install::InstallRequest;",
    "pubuseprepare_install::update_from_cli;",
    "pubmodtelemetry;",
    "pubusebackend::BackendKind;",
}
OPTIONAL_PUBLIC_EXPORTS = {"pubusebackend::windows::is_elevated;"}


def replace_once(text, before, after, description):
    if text.count(after) == 1 and before not in text.replace(after, ""):
        return text
    if text.count(before) != 1 or after in text:
        raise ValueError(f"Unsupported upstream source: {description}")
    return text.replace(before, after, 1)


def check_entry_guard(text, name):
    pattern = rf"pub async fn {name}\([^{{]*?\) -> [^{{]+\{{\s*(?:crate::)?ensure_supported_platform\(\)\?;"
    if len(re.findall(pattern, text)) != 1:
        raise ValueError(f"Daemon entry point lost its first-operation guard: {name}")


def patched_sources(sources):
    result = dict(sources)
    daemon = "codex-rs/app-server-daemon/src/lib.rs"
    exports = re.findall(r"^\s*pub\s+(?:use|mod)\b[^;]*;", sources[daemon], re.M)
    normalized = [re.sub(r"\s+", "", item) for item in exports]
    if (set(normalized) - OPTIONAL_PUBLIC_EXPORTS != PUBLIC_EXPORTS
            or len(normalized) != len(set(normalized))):
        raise ValueError("Daemon public exports changed; review new modules and re-exported entry points")
    public_entries = {
        daemon: {"probe_app_server_version", "run", "bootstrap", "ensure_remote_control_ready",
                 "enable_remote_control_on_socket", "start_remote_control_pairing", "set_remote_control",
                 "run_pid_update_loop", "update"},
        "codex-rs/app-server-daemon/src/launch.rs": {"start_with_features", "restart_with_features"},
        "codex-rs/app-server-daemon/src/prepare_install.rs": {"update_from_cli"},
    }
    for path, expected in public_entries.items():
        entries = re.findall(r"^[ \t]*pub (?:async )?fn ([a-z_]+)\(", sources[path], re.M)
        found = set(entries)
        if found != expected or len(entries) != len(expected):
            raise ValueError(f"Daemon public entry points changed in {path}: {sorted(found ^ expected)}")
    for name in ("run", "bootstrap", "ensure_remote_control_ready", "enable_remote_control_on_socket",
                 "start_remote_control_pairing", "set_remote_control", "run_pid_update_loop", "update"):
        check_entry_guard(result[daemon], name)
    for name in ("start_with_features", "restart_with_features"):
        check_entry_guard(sources["codex-rs/app-server-daemon/src/launch.rs"], name)
    check_entry_guard(sources["codex-rs/app-server-daemon/src/prepare_install.rs"], "update_from_cli")
    before = '#[cfg(any(unix, windows))]\nfn ensure_supported_platform() -> Result<()> {\n    Ok(())\n}'
    after = (f'/// Whether this build supports a shared local daemon.\n{CONSTANT}\n\n'
             '#[cfg(any(unix, windows))]\nfn ensure_supported_platform() -> Result<()> {\n'
             f'    Err(anyhow!(\n        "{ERROR}"\n    ))\n}}')
    result[daemon] = replace_once(result[daemon], before, after, "daemon lifecycle guard")

    cli = "codex-rs/cli/src/main.rs"
    before = ") -> std::io::Result<AppExitInfo> {\n    if interactive.no_daemon {"
    after = (') -> std::io::Result<AppExitInfo> {\n'
             f'    {MARKER}\n'
             '    if remote.is_none() {\n'
             '        interactive.no_daemon = true;\n'
             '        interactive.daemon_cli_executable = None;\n'
             '    }\n'
             '    if interactive.no_daemon {')
    result[cli] = replace_once(result[cli], before, after, "interactive local launch")
    before = "        Some(Subcommand::AppServer(app_server_cli)) => {\n            let AppServerCommand {"
    after = ("        Some(Subcommand::AppServer(app_server_cli)) => {\n"
             "            if app_server_cli.managed_daemon {\n"
             f'                anyhow::bail!(\n                    "{ERROR}"\n                );\n'
             "            }\n            let AppServerCommand {")
    result[cli] = replace_once(result[cli], before, after, "managed daemon worker")

    startup = "codex-rs/tui/src/startup_orchestration.rs"
    before = ") -> std::io::Result<AppExitInfo> {\n    if cli.no_daemon && explicit_remote_endpoint.is_some() {"
    after = (') -> std::io::Result<AppExitInfo> {\n'
             f'    {MARKER}\n'
             '    cli.no_daemon |= explicit_remote_endpoint.is_none();\n'
             '    if cli.no_daemon && explicit_remote_endpoint.is_some() {')
    result[startup] = replace_once(result[startup], before, after, "standalone TUI local launch")

    tui = "codex-rs/tui/src/lib.rs"
    before = "async fn maybe_probe_default_daemon_socket(codex_home: &Path) -> Option<AbsolutePathBuf> {\n"
    after = (before + '    if !codex_app_server_daemon::LOCAL_DAEMON_ENABLED {\n'
             '        return None;\n    }\n')
    result[tui] = replace_once(result[tui], before, after, "implicit daemon socket discovery")
    result[tui] = replace_once(result[tui], "        let expected = Some(socket_path);",
                               "        let expected: Option<AbsolutePathBuf> = None;",
                               "existing socket discovery regression expectation")
    return result


FILES = (
    "codex-rs/app-server-daemon/src/lib.rs",
    "codex-rs/app-server-daemon/src/launch.rs",
    "codex-rs/app-server-daemon/src/prepare_install.rs",
    "codex-rs/cli/src/main.rs",
    "codex-rs/tui/src/startup_orchestration.rs",
    "codex-rs/tui/src/lib.rs",
)


def patch(root):
    raw = {name: (root / name).read_bytes() for name in FILES}
    original = {name: data.decode("utf-8").replace("\r\n", "\n") for name, data in raw.items()}
    changed = patched_sources(original)
    for name, text in changed.items():
        if text != original[name]:
            newline = "\r\n" if b"\r\n" in raw[name] else "\n"
            (root / name).write_bytes(text.replace("\n", newline).encode("utf-8"))
    print("Local daemon disabled: embedded local startup, no implicit socket attachment, lifecycle/updater rejected.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    patch(parser.parse_args().source_root.resolve())
