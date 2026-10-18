"""Contracts for the shared metadata patch, including unsupported source refusal."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('metadata_patch', Path(__file__).with_name('patch-openai-request-metadata.py'))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


def protocol(modern):
    field = '    pub content_item_metadata: Option<Vec<ContentItemMetadata>>,\n' if modern else ''
    sanitizer = patcher.SANITIZER
    if modern:
        sanitizer = sanitizer.replace('metadata_value.content_item_kinds = None;',
                                      'metadata_value.content_item_kinds = None;\n        metadata_value.content_item_metadata = None;')
    return ('''pub struct InternalChatMessageMetadataPassthrough {
    pub turn_id: Option<String>,
    pub create_time: Option<Number>,
    pub content_item_kinds: Option<Vec<ContentItemKind>>,
''' + field + '}\nimpl ResponseItem {\n' + sanitizer + '\n}\n')


CLIENT = '''fn build_request() {
        if !is_openai {
            item.clear_internal_chat_message_metadata_passthrough();
        }
}
'''
TESTS = '''#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn openai_stateless_responses_requests_preserve_item_turn_metadata_across_turns() {
    assert_eq!(item_turn_id("turn two"), Some(second_turn_id));
}
'''


class MetadataContracts(unittest.TestCase):
    def test_legacy_and_attribution_sources_use_upstream_sanitizer(self):
        for modern in (False, True):
            with self.subTest(modern=modern):
                client, tests = patcher.transform(protocol(modern), CLIENT, TESTS)
                self.assertIn(patcher.BOUNDARY + '        if !is_openai {', client)
                self.assertTrue(client.endswith(CLIENT[CLIENT.index('        if !is_openai {'):]))
                self.assertIn('["content_item_kinds", "content_item_metadata"]', tests)
                self.assertEqual('_across_turns_lite()' in tests, modern)
                self.assertEqual(patcher.transform(protocol(modern), client, tests), (client, tests))

    def test_lite_test_uses_advertised_transport_and_checks_replayed_timestamps(self):
        _, tests = patcher.transform(protocol(True), CLIENT, TESTS)
        self.assertIn('model_info.use_responses_lite = true;', tests)
        self.assertIn('"content_item_metadata": [],', tests)
        self.assertIn('json!(assistant_create_time)', tests)
        self.assertIn('test.submit_turn("lite turn two")', tests)

    def test_crlf_is_preserved(self):
        client, tests = patcher.transform(protocol(True).replace('\n', '\r\n'),
                                          CLIENT.replace('\n', '\r\n'), TESTS.replace('\n', '\r\n'))
        for text in (client, tests):
            self.assertNotIn('\n', text.replace('\r\n', ''))

    def test_incomplete_or_unsafe_upstream_sanitizer_is_rejected(self):
        for source in (protocol(True).replace('metadata_value.content_item_metadata = None;', ''),
                       protocol(True).replace('metadata_value.content_item_kinds = None;', ''),
                       protocol(True).replace('metadata_value.content_item_kinds = None;', 'metadata_value.turn_id = None;'),
                       protocol(True).replace('if metadata_value == &InternalChatMessageMetadataPassthrough::default()', 'if true'),
                       protocol(True) + protocol(True)):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patcher.transform(source, CLIENT, TESTS)

    def test_missing_duplicate_and_misplaced_boundary_is_rejected(self):
        for client in (CLIENT.replace('if !is_openai', 'if other_provider'), CLIENT + CLIENT,
                       patcher.BOUNDARY + CLIENT.replace('fn build_request() {', 'fn build_request() {\n')):
            with self.subTest(client=client), self.assertRaises(ValueError):
                patcher.transform(protocol(True), client, TESTS)

    def test_late_regression_anchor_failure_writes_nothing(self):
        with tempfile.TemporaryDirectory(prefix='codex-metadata-contract-') as directory:
            root = Path(directory)
            contents = {patcher.PROTOCOL: protocol(True), patcher.CLIENT: CLIENT, patcher.TESTS: TESTS + TESTS}
            for relative, text in contents.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding='utf-8')
            before = {path: (root / path).read_bytes() for path in contents}
            with self.assertRaises(ValueError):
                patcher.patch(root)
            self.assertEqual(before, {path: (root / path).read_bytes() for path in contents})


if __name__ == '__main__':
    unittest.main()
