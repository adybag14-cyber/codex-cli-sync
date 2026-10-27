"""Fail-closed compatibility contracts for the reviewed Guardian type migration."""
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("guardian_bridge", Path(__file__).with_name("patch-guardian-section-content.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

COMPOSITION = "enum SectionContent { Transcript(TranscriptRecord), Other(ContentItem), }"
PROFILE = "pub fn prepare_transcript(&self) -> PreparedTranscript {}"
TEST = "let transcript = profile.render_transcript(collected.transcript_entries(), 0);"
SOURCE = r"""use crate::composition::SectionContent;
fn deduplicate_transcript_instructions() {
    matches!(&item.content, ContentItem::InputText { text }
        if text.strip_suffix('\n') == Some(assistant_omission.as_str()));
    let start = Budgeted::required(ContentItem::InputText {
        text: assistant_start.to_owned(),
    });
    let end = Budgeted::required(
        ContentItem::InputText {
            text: assistant_end.to_owned(),
        },
    );
}
fn retain_new_instructions() {
    matches!(&item.content, ContentItem::InputText { text }
        if text == assistant_start || text == assistant_end);
}
"""


class GuardianContracts(unittest.TestCase):
    def test_reviewed_profile_layouts_patch_and_reapply_identically(self):
        for profile_path in bridge.PROFILE_PATHS:
            for newline in ("\n", "\r\n"):
                with self.subTest(profile=profile_path, newline=newline), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    files = {bridge.SOURCE: SOURCE, bridge.COMPOSITION: COMPOSITION,
                             profile_path: PROFILE, bridge.CACHE_TEST: TEST}
                    for name, value in files.items():
                        path = root / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(value.replace("\n", newline).encode())
                    self.assertTrue(bridge.patch(root))
                    first = {name: (root / name).read_bytes() for name in files}
                    self.assertFalse(bridge.patch(root))
                    self.assertEqual(first, {name: (root / name).read_bytes() for name in files})
                    self.assertIn(b'profile.prepare_transcript(', first[bridge.CACHE_TEST])
                    self.assertEqual(first[profile_path], PROFILE.encode())

    def test_missing_or_ambiguous_profile_rejects_before_source_writes(self):
        for profiles in ((), bridge.PROFILE_PATHS):
            with self.subTest(profiles=profiles), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                files = {bridge.SOURCE: SOURCE, bridge.COMPOSITION: COMPOSITION, bridge.CACHE_TEST: TEST}
                files.update({name: PROFILE for name in profiles})
                for name, value in files.items():
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(value.encode())
                with self.assertRaisesRegex(ValueError, "profile source is (missing|ambiguous)"):
                    bridge.patch(root)
                self.assertEqual(files, {name: (root / name).read_bytes().decode() for name in files})

    def test_old_expressions_are_wrapped_and_reapplication_is_identical(self):
        fixed = bridge.patched_source(SOURCE, COMPOSITION)
        self.assertEqual(fixed.count("SectionContent::Other("), 4)
        self.assertEqual(bridge.patched_source(fixed, COMPOSITION), fixed)
        self.assertIn("text.strip_suffix('\\n') == Some(assistant_omission.as_str())", fixed)

    def test_crlf_and_unrelated_text_are_preserved(self):
        original = (SOURCE + "// unrelated: retain all user restrictions\n").replace("\n", "\r\n")
        fixed = bridge.patched_source(original, COMPOSITION)
        self.assertNotIn("\n", fixed.replace("\r\n", ""))
        self.assertTrue(fixed.endswith("// unrelated: retain all user restrictions\r\n"))

    def test_legacy_source_without_split_context_is_unchanged(self):
        legacy = "fn deduplicate_transcript_instructions() { self.remove_delivered_instructions(&[]); }\n"
        self.assertEqual(bridge.patched_source(legacy, COMPOSITION), legacy)

    def test_ambiguous_old_or_fixed_expression_is_rejected(self):
        for source in (SOURCE, bridge.patched_source(SOURCE, COMPOSITION)):
            with self.subTest(source=source[:25]), self.assertRaisesRegex(ValueError, "exactly one"):
                bridge.patched_source(source + source, COMPOSITION)

    def test_unknown_representation_and_entry_points_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "representation changed"):
            bridge.patched_source(SOURCE, COMPOSITION.replace("Other(ContentItem)", "Other(String)"))
        with self.assertRaisesRegex(ValueError, "entry points changed"):
            bridge.patched_source(SOURCE.replace("retain_new_instructions", "different_entry"), COMPOSITION)

    def test_partial_upstream_fix_is_completed(self):
        partial = SOURCE.replace("matches!(&item.content, ContentItem::InputText { text }",
                                 "matches!(&item.content, SectionContent::Other(ContentItem::InputText { text })", 1)
        self.assertEqual(bridge.patched_source(partial, COMPOSITION), bridge.patched_source(SOURCE, COMPOSITION))

    def test_upstream_fixed_string_conversion_is_byte_identical(self):
        source = bridge.patched_source(SOURCE, COMPOSITION)
        for marker in ("start", "end"):
            source = re.sub(rf"SectionContent::Other\(ContentItem::InputText\s*\{{\s*text:\s*assistant_{marker}\.to_owned\(\),\s*\}}\)",
                            f"assistant_{marker}.to_owned().into()", source)
        composition = COMPOSITION + "\nimpl From<String> for SectionContent { fn from(text: String) -> Self { Self::Other(ContentItem::InputText { text }) } }"
        self.assertEqual(bridge.patched_source(source, composition), source)
        with self.assertRaisesRegex(ValueError, "conversion changed"):
            bridge.patched_source(source, COMPOSITION)

    def test_renamed_test_api_preserves_arguments_and_legacy_provider(self):
        self.assertEqual(bridge.patched_cache_test(TEST, PROFILE),
                         TEST.replace("profile.render_transcript(", "profile.prepare_transcript("))
        self.assertEqual(bridge.patched_cache_test(TEST, "pub fn render_transcript("), TEST)
        with self.assertRaisesRegex(ValueError, "API changed"):
            bridge.patched_cache_test(TEST + TEST, PROFILE)

    def test_late_test_api_drift_does_not_write_production_source(self):
        with tempfile.TemporaryDirectory(prefix="guardian-bridge-contract-") as directory:
            root = Path(directory)
            files = {bridge.SOURCE: SOURCE, bridge.COMPOSITION: COMPOSITION,
                     bridge.PROFILE: PROFILE, bridge.CACHE_TEST: TEST + TEST}
            for name, value in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value.encode())
            with self.assertRaisesRegex(ValueError, "API changed"):
                bridge.patch(root)
            self.assertEqual(files, {name: (root / name).read_bytes().decode() for name in files})


if __name__ == "__main__":
    unittest.main()
