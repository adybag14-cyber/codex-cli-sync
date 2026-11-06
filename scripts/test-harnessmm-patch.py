"""Source transaction contracts, including exact upstream replay when supplied."""
import argparse
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("patcher", Path(__file__).with_name("patch-codex-harnessmm.py"))
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)
SOURCE = None
LEGACY_FIELDS = "needs_follow_up: bool, last_agent_message: Option<String>,"
CURRENT_FIELDS = "needs_follow_up: bool, mailbox_preempted: bool, last_agent_message: Option<String>,"


def populate(root, newline="\n"):
    for relative, edits in patcher.EDITS.items():
        value = (SOURCE / relative).read_bytes().decode().replace("\r\n", "\n") if SOURCE else "\n".join(before for before, _ in edits) + "\n"
        if not SOURCE and relative == patcher.TURN_SOURCE:
            value += "struct SamplingRequestResult { " + LEGACY_FIELDS + " }\n"
        if SOURCE and (SOURCE / patcher.MODULE).exists():
            if (SOURCE / patcher.MODULE).read_bytes() != (patcher.ROOT / 'patches/harnessmm/harnessmm.rs').read_bytes():
                raise ValueError('Source contains a different HarnessMM implementation')
            for before, after in patcher.source_edits(relative, value):
                if value.count(after) != 1:
                    raise ValueError('Source contains a partial HarnessMM implementation')
                value = value.replace(after, before, 1)
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value.replace("\n", newline).encode())


def snapshot(root):
    return {str(path.relative_to(root)): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class HarnessMmPatchTests(unittest.TestCase):
    def test_mailbox_layout_initializes_false_and_replays(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            populate(root)
            path = root / patcher.TURN_SOURCE
            text = path.read_text()
            if not SOURCE:
                text = text.replace(LEGACY_FIELDS, CURRENT_FIELDS)
            elif "mailbox_preempted" not in text:
                self.skipTest("Supplied historical source predates mailbox preemption")
            path.write_text(text)
            patcher.patch(root)
            self.assertIn("mailbox_preempted: false", path.read_text())
            original = snapshot(root)
            self.assertEqual(patcher.patch(root), 0)
            self.assertEqual(snapshot(root), original)

    @unittest.skipUnless(shutil.which("rustc"), "Rust compiler is unavailable")
    def test_replay_result_typechecks_for_both_supported_layouts(self):
        for fields in [LEGACY_FIELDS, CURRENT_FIELDS]:
            with self.subTest(fields=fields), tempfile.TemporaryDirectory() as folder:
                definition = "struct SamplingRequestResult { " + fields + " }"
                after = patcher.source_edits(patcher.TURN_SOURCE, definition)[0][1]
                literal = re.search(r"SamplingRequestResult \{[^}]*\}", after).group()
                source = Path(folder) / "replay.rs"
                source.write_text(definition + "\nfn replay() -> SamplingRequestResult { " + literal + " }\n")
                result = subprocess.run(["rustc", "--crate-type", "lib", "--emit=metadata", "-o",
                                         str(Path(folder) / "replay.rmeta"), str(source)],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_result_shape_refuses_without_writing(self):
        for definition in ["struct SamplingRequestResult { needs_follow_up: bool, future: bool }",
                           "struct SamplingRequestResult { needs_follow_up: bool, mailbox_preempted: String, last_agent_message: Option<String> }"]:
            with self.subTest(definition=definition), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                populate(root)
                path = root / patcher.TURN_SOURCE
                path.write_text(re.sub(r"struct SamplingRequestResult\s*\{[^{}]*\}", definition, path.read_text()))
                original = snapshot(root)
                with self.assertRaises(ValueError):
                    patcher.patch(root)
                self.assertEqual(snapshot(root), original)

    def test_transaction_and_exact_replay(self):
        for newline in ["\n", "\r\n"]:
            with self.subTest(newline=repr(newline)), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                populate(root, newline)
                self.assertEqual(patcher.patch(root), len(patcher.EDITS) + 1)
                first = snapshot(root)
                self.assertEqual(patcher.patch(root), 0)
                self.assertEqual(snapshot(root), first)

    def test_every_unknown_boundary_refuses_without_changes(self):
        for relative, edits in patcher.EDITS.items():
            for before, _ in edits:
                with self.subTest(path=relative, anchor=before), tempfile.TemporaryDirectory() as folder:
                    root = Path(folder)
                    populate(root)
                    path = root / relative
                    path.write_bytes(path.read_bytes().replace(before.encode(), b"UNREVIEWED_UPSTREAM", 1))
                    original = snapshot(root)
                    with self.assertRaises(ValueError):
                        patcher.patch(root)
                    self.assertEqual(snapshot(root), original)

    def test_partial_or_foreign_overlay_refuses(self):
        for partial in [True, False]:
            with self.subTest(partial=partial), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                populate(root)
                if partial:
                    relative = next(iter(patcher.EDITS))
                    before, after = patcher.EDITS[relative][0]
                    path = root / relative
                    path.write_bytes(path.read_bytes().replace(before.encode(), after.encode()))
                else:
                    (root / patcher.MODULE).write_text("foreign implementation")
                original = snapshot(root)
                with self.assertRaises(ValueError):
                    patcher.patch(root)
                self.assertEqual(snapshot(root), original)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path)
    args, remaining = parser.parse_known_args()
    SOURCE = args.source_root
    unittest.main(argv=[__file__, *remaining])
