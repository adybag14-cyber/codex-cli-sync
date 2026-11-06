import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("migration_format", Path(__file__).with_name("normalize-windows-migrations.py"))
normalizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(normalizer)


class MigrationFormatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-sql-format-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".git" / "info").mkdir(parents=True)
        self.state = self.root / "codex-rs" / "state"
        self.folder = self.state / "migrations"
        self.folder.mkdir(parents=True)
        self.file = self.folder / "0001_threads.sql"
        self.lf = b"CREATE TABLE threads (\n    id TEXT PRIMARY KEY\n);\n"
        self.file.write_bytes(self.lf)

    def test_matches_published_windows_checksum_and_is_repeatable(self):
        expected = self.lf.replace(b"\n", b"\r\n")
        self.assertEqual(normalizer.normalize(self.root), (1, 1))
        self.assertEqual(hashlib.sha384(self.file.read_bytes()).digest(), hashlib.sha384(expected).digest())
        self.assertEqual(normalizer.normalize(self.root), (1, 0))

    def test_all_migration_stores_are_normalized(self):
        for folder in ["logs_migrations", "memory_migrations", "goals_migrations", "queue_migrations", "thread_history_migrations"]:
            path = self.state / folder / "0001_initial.sql"
            path.parent.mkdir()
            path.write_bytes(self.lf)
        unrelated = self.state / "example.sql"
        unrelated.write_bytes(self.lf)
        self.assertEqual(normalizer.normalize(self.root), (6, 6))
        self.assertEqual(unrelated.read_bytes(), self.lf)

    def test_unknown_line_endings_fail_before_any_write(self):
        bad = self.folder / "0002_unknown.sql"
        bad.write_bytes(b"SELECT\r1;\n")
        with self.assertRaises(ValueError):
            normalizer.normalize(self.root)
        self.assertEqual(self.file.read_bytes(), self.lf)
        self.assertFalse((self.root / ".git/info/attributes").exists())

    def test_preserves_existing_checkout_attributes(self):
        attributes = self.root / ".git/info/attributes"
        attributes.write_bytes(b"*.png binary\n")
        normalizer.normalize(self.root)
        self.assertEqual(attributes.read_text().splitlines(), ["*.png binary", normalizer.ATTRIBUTE])

    def test_git_reports_no_sql_change_with_autocrlf_disabled(self):
        # Use Git's index without needing a commit identity or touching global config.
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "core.autocrlf=false", "add", "codex-rs"], check=True)
        normalizer.normalize(self.root)
        result = subprocess.run(["git", "-C", str(self.root), "-c", "core.autocrlf=false", "diff", "--exit-code"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout.decode())


if __name__ == "__main__":
    unittest.main()
