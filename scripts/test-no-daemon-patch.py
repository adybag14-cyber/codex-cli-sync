"""Patcher regression contracts; optionally exercise the exact checked-out source."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("patcher", Path(__file__).with_name("patch-codex-no-daemon.py"))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


def fixture():
    def entry(name):
        return f"pub async fn {name}() -> Result<()> {{\n    ensure_supported_platform()?;\n    original().await\n}}\n"
    return dict(zip(patcher.FILES, (
        "\n".join(export.replace('pubuse', 'pub use ').replace('pubmod', 'pub mod ') for export in sorted(patcher.PUBLIC_EXPORTS)) + "\n"
        + "".join(entry(n) for n in ("probe_app_server_version", "run", "bootstrap", "ensure_remote_control_ready",
                                  "enable_remote_control_on_socket", "start_remote_control_pairing",
                                  "set_remote_control", "run_pid_update_loop", "update"))
        + '#[cfg(any(unix, windows))]\nfn ensure_supported_platform() -> Result<()> {\n    Ok(())\n}',
        entry("start_with_features") + entry("restart_with_features"),
        entry("update_from_cli"),
        'async fn run_interactive_tui() -> std::io::Result<AppExitInfo> {\n    if interactive.no_daemon {\n    }\n}\n'
        '        Some(Subcommand::AppServer(app_server_cli)) => {\n            let AppServerCommand {\n',
        'async fn run_main_inner() -> std::io::Result<AppExitInfo> {\n    if cli.no_daemon && explicit_remote_endpoint.is_some() {\n    }\n}\n',
        'async fn maybe_probe_default_daemon_socket(codex_home: &Path) -> Option<AbsolutePathBuf> {\n    original().await\n}\n'
        '        let expected = Some(socket_path);\n',
    )))


class Contracts(unittest.TestCase):
    def test_repeat_application_preserves_bytes_and_line_endings(self):
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name, text in fixture().items():
                    (root / name).parent.mkdir(parents=True, exist_ok=True)
                    (root / name).write_bytes(text.replace("\n", newline).encode())
                patcher.patch(root)
                first = {name: (root / name).read_bytes() for name in patcher.FILES}
                patcher.patch(root)
                self.assertEqual(first, {name: (root / name).read_bytes() for name in patcher.FILES})
                if newline == "\r\n":
                    self.assertTrue(all(b"\n" not in value.replace(b"\r\n", b"") for value in first.values()))

    def test_missing_source_anchor_never_partially_writes(self):
        for broken in patcher.FILES:
            with self.subTest(file=broken), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                values = fixture()
                values[broken] = "upstream changed\n"
                for name, text in values.items():
                    (root / name).parent.mkdir(parents=True, exist_ok=True)
                    (root / name).write_text(text, encoding="utf-8")
                before = {name: (root / name).read_bytes() for name in patcher.FILES}
                with self.assertRaises(ValueError):
                    patcher.patch(root)
                self.assertEqual(before, {name: (root / name).read_bytes() for name in patcher.FILES})

    def test_lifecycle_side_effect_before_guard_is_rejected(self):
        values = fixture()
        values[patcher.FILES[0]] = values[patcher.FILES[0]].replace(
            "pub async fn run() -> Result<()> {\n    ensure_supported_platform()?;",
            "pub async fn run() -> Result<()> {\n    create_state();\n    ensure_supported_platform()?;", 1)
        with self.assertRaisesRegex(ValueError, "first-operation guard: run"):
            patcher.patched_sources(values)

    def test_new_unreviewed_public_entry_is_rejected(self):
        values = fixture()
        values[patcher.FILES[0]] += "\npub async fn new_start() -> Result<()> { start().await }\n"
        with self.assertRaisesRegex(ValueError, "public entry points changed"):
            patcher.patched_sources(values)

    def test_duplicate_anchor_is_rejected(self):
        values = fixture()
        values[patcher.FILES[-1]] *= 2
        with self.assertRaises(ValueError):
            patcher.patched_sources(values)

    def test_new_public_module_or_reexport_is_rejected(self):
        for export in ("pub mod automatic_start;", "pub use launch::unguarded_start;", "pub use launch::*;"):
            with self.subTest(export=export):
                values = fixture()
                values[patcher.FILES[0]] += "\n" + export
                with self.assertRaisesRegex(ValueError, "public exports changed"):
                    patcher.patched_sources(values)

    def test_indented_or_duplicate_public_entry_is_rejected(self):
        for declaration in ("    pub fn unreviewed() {}", "pub async fn run() -> Result<()> { ensure_supported_platform()?; }"):
            with self.subTest(declaration=declaration):
                values = fixture()
                values[patcher.FILES[0]] += "\n" + declaration
                with self.assertRaisesRegex(ValueError, "public entry points changed"):
                    patcher.patched_sources(values)


if __name__ == "__main__":
    unittest.main()
