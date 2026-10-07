"""Regression coverage for fixture shutdown, transient file locks and evidence."""
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("no_daemon_probe", Path(__file__).with_name("test-no-daemon-runtime.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class CleanupContracts(unittest.TestCase):
    def setUp(self):
        self.parent = tempfile.TemporaryDirectory(prefix="codex-runtime-contract-")
        self.addCleanup(self.parent.cleanup)
        self.parent_path = Path(self.parent.name).resolve()
        self.root = Path(tempfile.mkdtemp(prefix=".cx-free-", dir=self.parent_path))
        self.file = self.root / "pack.tmp"
        self.file.write_text("owned fixture", encoding="utf-8")

    def test_cleanup_removes_only_owned_root(self):
        sibling = self.parent_path / "unrelated.txt"
        sibling.write_text("keep", encoding="utf-8")
        probe.remove_fixture(self.root, self.parent_path)
        self.assertFalse(self.root.exists())
        self.assertEqual(sibling.read_text(), "keep")

    def test_cleanup_rejects_outside_parent_or_unowned_name(self):
        for parent, root in ((self.root, self.root), (self.parent_path.parent, self.parent_path)):
            with self.subTest(root=root), self.assertRaises(ValueError):
                probe.remove_fixture(root, parent)
        self.assertTrue(self.file.exists())

    def test_permanent_lock_fails_with_retained_path(self):
        with mock.patch.object(probe.shutil, "rmtree", side_effect=PermissionError(errno.EACCES, "locked")):
            with self.assertRaisesRegex(RuntimeError, "retained path"):
                probe.remove_fixture(self.root, self.parent_path, timeout=0)
        self.assertTrue(self.file.exists())

    @unittest.skipUnless(os.name == "nt", "Windows sharing violation regression")
    def test_real_windows_file_lock_is_retried_until_released(self):
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.CreateFileW(str(self.file), 0x80000000, 1, None, 3, 0x80, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        released = threading.Event()
        def release():
            kernel.CloseHandle(handle)
            released.set()
        timer = threading.Timer(0.4, release)
        timer.start()
        try:
            probe.remove_fixture(self.root, self.parent_path, timeout=3)
            self.assertTrue(released.is_set())
            self.assertFalse(self.root.exists())
        finally:
            timer.join()

    def test_cleanup_failure_keeps_successful_smoke_evidence_but_fails_run(self):
        output = self.parent_path / "report.json"
        with mock.patch.object(probe, "smoke", return_value={"passed": 14, "answer": probe.ANSWER}), \
             mock.patch.object(probe, "remove_fixture", side_effect=RuntimeError("locked")):
            with self.assertRaisesRegex(RuntimeError, "see"):
                probe.run_fixture(self.file, output, self.parent_path)
        report = json.loads(output.read_text())
        self.assertFalse(report["ok"])
        self.assertEqual(report["passed"], 14)
        self.assertEqual(report["cleanup"], "failed")
        self.assertIn("locked", report["cleanupError"])

    def test_smoke_failure_is_recorded_and_root_removed(self):
        output = self.parent_path / "report.json"
        with mock.patch.object(probe, "smoke", side_effect=AssertionError("startup failed")):
            with self.assertRaises(RuntimeError):
                probe.run_fixture(self.file, output, self.parent_path)
        report = json.loads(output.read_text())
        self.assertFalse(report["ok"])
        self.assertEqual(report["cleanup"], "removed")
        self.assertIn("startup failed", report["smokeError"])
        self.assertFalse(Path(report["fixtureRoot"]).exists())

    def test_success_is_recorded_after_cleanup(self):
        output = self.parent_path / "report.json"
        with mock.patch.object(probe, "smoke", return_value={"passed": 14}):
            report = probe.run_fixture(self.file, output, self.parent_path)
        self.assertTrue(report["ok"])
        self.assertEqual(report["cleanup"], "removed")
        self.assertFalse(Path(report["fixtureRoot"]).exists())

    def test_interrupted_smoke_is_never_reported_as_success(self):
        output = self.parent_path / "report.json"
        with mock.patch.object(probe, "smoke", side_effect=KeyboardInterrupt("interrupted")):
            with self.assertRaises(RuntimeError):
                probe.run_fixture(self.file, output, self.parent_path)
        report = json.loads(output.read_text())
        self.assertFalse(report["ok"])
        self.assertIn("KeyboardInterrupt", report["smokeError"])
        self.assertEqual(report["cleanup"], "removed")

    def test_graceful_terminal_exit_precedes_interrupts(self):
        terminal = object.__new__(probe.Terminal)
        terminal.alive = mock.Mock(side_effect=[True] + [False] * 10)
        terminal.write = mock.Mock()
        terminal.reader = mock.Mock()
        with mock.patch.object(probe.os, "name", "nt"):
            terminal.close()
        terminal.write.assert_called_once_with("/exit\r")
        terminal.reader.join.assert_called_once()


if __name__ == "__main__":
    unittest.main()
