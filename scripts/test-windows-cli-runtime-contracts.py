"""Fast regression tests for both Windows daemon privilege contracts (no model calls)."""

import ctypes
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("windows_runtime_probe", Path(__file__).with_name("test-windows-cli-runtime.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
REJECTION = ("Error: start the Windows daemon from a non-elevated terminal; "
             "shared clients must not inherit administrator privileges\n")


class DaemonFixture:
    def __init__(self, root):
        self.home = root / "home"
        self.home.mkdir()
        self.executable = root / "codex.exe"
        self.executable.write_bytes(b"exact packaged binary")
        self.managed = self.home / "packages/bin/codex.exe"
        self.managed.parent.mkdir(parents=True)
        self.managed.write_bytes(self.executable.read_bytes())
        self.calls = []
        self.stop_count = 0
        self.initial = {"status": "notRunning"}
        self.stopped = {"status": "notRunning"}
        self.started = {"status": "started", "pid": 123, "managedCodexPath": str(self.managed)}
        self.version = {"status": "running", "appServerVersion": "test-version"}
        self.raw = subprocess.CompletedProcess([], 1, "", REJECTION)
        self.start_error = None
        self.version_error = None

    def run(self, *arguments):
        assert arguments[:2] == ("app-server", "daemon")
        self.calls.append(arguments[-1])
        if arguments[-1] == "stop":
            self.stop_count += 1
            if self.stop_count == 1:
                (self.home / "app-server-daemon").mkdir()
                return json.dumps(self.initial)
            return json.dumps(self.stopped)
        if arguments[-1] == "start":
            if self.start_error:
                raise self.start_error
            return json.dumps(self.started)
        if arguments[-1] == "version":
            if self.version_error:
                raise self.version_error
            return json.dumps(self.version)
        raise AssertionError(f"Unexpected command {arguments}")

    def run_result(self, *arguments):
        assert arguments == ("app-server", "daemon", "start")
        self.calls.append("raw_start")
        return self.raw

    def check(self, elevated):
        return probe.check_isolated_daemon(
            config_home=self.home, executable=self.executable, expected_version="test-version",
            elevated=elevated, run=self.run, run_result=self.run_result,
        )


class DaemonContracts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="codex-daemon-contract-")
        self.addCleanup(temporary.cleanup)
        self.fixture = DaemonFixture(Path(temporary.name))

    def fails_and_cleans_up(self, elevated, message):
        with self.assertRaisesRegex(AssertionError, message):
            self.fixture.check(elevated)
        self.assertEqual(self.fixture.calls[-1], "stop")
        self.assertEqual(self.fixture.stop_count, 2)

    def test_elevated_runner_checks_exact_rejection_and_no_daemon(self):
        checks = self.fixture.check(True)
        self.assertEqual(checks, ["isolated_daemon_rejects_elevated_start", "isolated_daemon_remains_stopped"])
        self.assertEqual(self.fixture.calls, ["stop", "raw_start", "stop"])
        settings = json.loads((self.fixture.home / "app-server-daemon/settings.json").read_text())
        self.assertFalse(settings["remoteControlEnabled"])
        self.assertFalse(settings["updater"]["autoUpdateEnabled"])

    def test_non_elevated_runner_still_checks_full_lifecycle(self):
        self.fixture.stopped = {"status": "stopped"}
        checks = self.fixture.check(False)
        self.assertEqual(checks, ["isolated_daemon_starts_exact_packaged_binary", "isolated_daemon_stopped"])
        self.assertEqual(self.fixture.calls, ["stop", "start", "version", "stop"])

    def test_non_elevated_cleanup_accepts_already_stopped(self):
        self.assertIn("isolated_daemon_stopped", self.fixture.check(False))

    def test_elevated_success_is_a_security_failure(self):
        self.fixture.raw = subprocess.CompletedProcess([], 0, "{}", REJECTION)
        self.fails_and_cleans_up(True, "expected security rejection")

    def test_unrelated_elevated_failure_is_not_hidden(self):
        self.fixture.raw = subprocess.CompletedProcess([], 1, "", "Error: missing package")
        self.fails_and_cleans_up(True, "expected security rejection")

    def test_silent_elevated_failure_is_not_hidden(self):
        self.fixture.raw = subprocess.CompletedProcess([], 1, "", "")
        self.fails_and_cleans_up(True, "expected security rejection")

    def test_elevated_rejection_must_not_leave_daemon(self):
        self.fixture.stopped = {"status": "stopped"}
        self.fails_and_cleans_up(True, "unexpectedly left a running daemon")

    def test_missing_pid_fails(self):
        self.fixture.started.pop("pid")
        self.fails_and_cleans_up(False, "did not start")

    def test_incorrect_start_status_fails(self):
        self.fixture.started["status"] = "notRunning"
        self.fails_and_cleans_up(False, "did not start")

    def test_managed_path_must_stay_in_disposable_home(self):
        self.fixture.started["managedCodexPath"] = str(self.fixture.executable)
        self.fails_and_cleans_up(False, "escaped its disposable CODEX_HOME")

    def test_different_managed_binary_fails(self):
        self.fixture.managed.write_bytes(b"a different executable")
        self.fails_and_cleans_up(False, "exact packaged CLI binary")

    def test_incorrect_daemon_version_fails(self):
        self.fixture.version["appServerVersion"] = "wrong-version"
        self.fails_and_cleans_up(False, "wrong version")

    def test_daemon_not_running_fails(self):
        self.fixture.version["status"] = "notRunning"
        self.fails_and_cleans_up(False, "wrong version")

    def test_start_exception_still_stops_probe(self):
        self.fixture.start_error = AssertionError("start failed")
        self.fails_and_cleans_up(False, "start failed")

    def test_version_exception_still_stops_probe(self):
        self.fixture.version_error = AssertionError("version failed")
        self.fails_and_cleans_up(False, "version failed")

    def test_bad_cleanup_status_fails(self):
        self.fixture.stopped = {"status": "running"}
        self.fails_and_cleans_up(False, "was not stopped")

    def test_existing_namespace_fails_before_start(self):
        self.fixture.initial = {"status": "running"}
        with self.assertRaisesRegex(AssertionError, "unexpectedly had a daemon"):
            self.fixture.check(False)
        self.assertEqual(self.fixture.calls, ["stop"])


@unittest.skipUnless(os.name == "nt", "Win32 token API contracts")
class TokenContracts(unittest.TestCase):
    def test_live_token_query_is_boolean(self):
        self.assertIsInstance(probe.windows_token_is_elevated(), bool)

    def test_open_token_error_fails_closed(self):
        kernel, advapi = mock.MagicMock(), mock.MagicMock()
        advapi.OpenProcessToken.return_value = 0
        with mock.patch("ctypes.WinDLL", side_effect=[kernel, advapi]):
            with self.assertRaises(OSError):
                probe.windows_token_is_elevated()
        kernel.CloseHandle.assert_not_called()
        advapi.GetTokenInformation.assert_not_called()

    def test_query_token_error_closes_handle_and_fails_closed(self):
        kernel, advapi = mock.MagicMock(), mock.MagicMock()
        advapi.OpenProcessToken.return_value = 1
        advapi.GetTokenInformation.return_value = 0
        with mock.patch("ctypes.WinDLL", side_effect=[kernel, advapi]):
            with self.assertRaises(OSError):
                probe.windows_token_is_elevated()
        kernel.CloseHandle.assert_called_once()

    def test_invalid_token_size_closes_handle_and_fails_closed(self):
        kernel, advapi = mock.MagicMock(), mock.MagicMock()
        advapi.OpenProcessToken.return_value = 1
        advapi.GetTokenInformation.return_value = 1  # Leaves returned byte count at zero.
        with mock.patch("ctypes.WinDLL", side_effect=[kernel, advapi]):
            with self.assertRaisesRegex(OSError, "invalid TOKEN_ELEVATION size"):
                probe.windows_token_is_elevated()
        kernel.CloseHandle.assert_called_once()

    def test_token_values_select_correct_branch(self):
        from ctypes import wintypes
        for expected in (False, True):
            with self.subTest(elevated=expected):
                kernel, advapi = mock.MagicMock(), mock.MagicMock()
                advapi.OpenProcessToken.return_value = 1
                def information(token, kind, elevation, size, returned):
                    self.assertEqual(kind, 20)
                    elevation._obj.value = int(expected)
                    returned._obj.value = ctypes.sizeof(wintypes.DWORD)
                    return 1
                advapi.GetTokenInformation.side_effect = information
                with mock.patch("ctypes.WinDLL", side_effect=[kernel, advapi]):
                    self.assertIs(probe.windows_token_is_elevated(), expected)
                kernel.CloseHandle.assert_called_once()


if __name__ == "__main__":
    unittest.main(verbosity=2)
