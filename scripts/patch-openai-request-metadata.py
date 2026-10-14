"""Remove unsupported content attribution from OpenAI request copies on both platforms.

Reuse upstream's narrow sanitizer so turn IDs, creation times and persisted history
retain their existing semantics. Validate every source anchor before writing files.
"""
import argparse
from pathlib import Path
import re

PROTOCOL = 'codex-rs/protocol/src/models.rs'
CLIENT = 'codex-rs/core/src/client.rs'
TESTS = 'codex-rs/core/tests/suite/client.rs'
SANITIZER = '''    pub fn clear_content_item_kinds(&mut self) {
        let Some(metadata) = self.internal_chat_message_metadata_passthrough_mut() else {
            return;
        };
        let Some(metadata_value) = metadata else {
            return;
        };
        metadata_value.content_item_kinds = None;
        if metadata_value == &InternalChatMessageMetadataPassthrough::default() {
            *metadata = None;
        }
    }'''
BOUNDARY = '''        if is_openai {
            for item in &mut input {
                // codex-cli-sync: omit unsupported content attribution only on the request copy.
                item.clear_content_item_kinds();
            }
        }
'''
ASSERTIONS = '''

    for item in first_input.iter().chain(second_input.iter()) {
        for field in ["content_item_kinds", "content_item_metadata"] {
            assert!(
                item["internal_chat_message_metadata_passthrough"].get(field).is_none(),
                "OpenAI request item must omit unsupported {field} metadata: {item}"
            );
        }
    }'''
LITE_TEST = '''

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn openai_stateless_responses_requests_preserve_item_turn_metadata_across_turns_lite() {
    let server = MockServer::start().await;
    let assistant_create_time = 1_785_276_138.422709;
    let mut assistant_message = ev_assistant_message("msg-lite-1", "first lite answer");
    assistant_message["item"]["internal_chat_message_metadata_passthrough"] = json!({
        "create_time": assistant_create_time,
        "content_item_kinds": [],
        "content_item_metadata": [],
    });
    let response_mock = mount_sse_sequence(
        &server,
        vec![
            sse(vec![ev_response_created("resp-lite-1"), assistant_message, ev_completed("resp-lite-1")]),
            sse(vec![ev_response_created("resp-lite-2"), ev_completed("resp-lite-2")]),
        ],
    ).await;
    let test = test_codex()
        .with_model("gpt-5.4")
        .with_model_info_override("gpt-5.4", |model_info| {
            model_info.use_responses_lite = true;
        })
        .build(&server).await.unwrap();
    test.submit_turn("lite turn one").await.unwrap();
    test.submit_turn("lite turn two").await.unwrap();
    let requests = response_mock.requests();
    assert_eq!(requests.len(), 2);
    for request in &requests {
        let body = request.body_json();
        let input = body["input"].as_array().expect("request input");
        for item in input {
            for field in ["content_item_kinds", "content_item_metadata"] {
                assert!(
                    item["internal_chat_message_metadata_passthrough"].get(field).is_none(),
                    "OpenAI lite request must omit unsupported {field} metadata: {item}"
                );
            }
        }
        let user = input.iter().find(|item| item["content"].as_array().is_some_and(|content| {
            content.iter().any(|part| part["text"].as_str() == Some("lite turn one"))
        })).expect("replayed user message");
        assert!(user["internal_chat_message_metadata_passthrough"]["turn_id"].is_string());
        assert!(user["internal_chat_message_metadata_passthrough"]["create_time"].is_number());
    }
    let second = requests[1].body_json();
    let assistant = second["input"].as_array().unwrap().iter().find(|item| {
        item["content"].as_array().is_some_and(|content| {
            content.iter().any(|part| part["text"].as_str() == Some("first lite answer"))
        })
    }).expect("replayed assistant message");
    assert_eq!(assistant["internal_chat_message_metadata_passthrough"]["create_time"], json!(assistant_create_time));
    assert!(assistant["internal_chat_message_metadata_passthrough"]["turn_id"].is_string());
}
'''


def insert_once(text, pattern, insertion, label, before=False):
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        raise ValueError(f'OpenAI metadata {label}: expected exactly one source anchor')
    position = matches[0].start() if before else matches[0].end()
    if insertion in text:
        expected = position - len(insertion) if before else position
        if text.count(insertion) != 1 or text.find(insertion) != expected:
            raise ValueError(f'OpenAI metadata {label}: duplicated or misplaced patch')
        return text
    return text[:position] + insertion + text[position:]


def transform(protocol, client, tests):
    metadata = re.findall(r'pub struct InternalChatMessageMetadataPassthrough \{.*?^\}', protocol, re.M | re.S)
    helpers = re.findall(r'    pub fn clear_content_item_kinds\(&mut self\) \{.*?^    \}', protocol, re.M | re.S)
    if len(metadata) != 1 or len(helpers) != 1:
        raise ValueError('OpenAI metadata upstream sanitizer representation changed')
    for field in ('content_item_kinds', 'content_item_metadata'):
        if re.search(rf'pub {field}:', metadata[0]) and not re.search(rf'\.{field}\s*=\s*None;', helpers[0]):
            raise ValueError(f'OpenAI metadata upstream sanitizer does not clear {field}')
    if 'pub content_item_kinds:' not in metadata[0] or re.search(r'\.(turn_id|create_time)\s*=', helpers[0]):
        raise ValueError('OpenAI metadata upstream sanitizer would lose approved metadata')
    reviewed = helpers[0].replace('metadata_value.content_item_metadata = None;', '')
    if re.sub(r'\s+', '', reviewed) != re.sub(r'\s+', '', SANITIZER):
        raise ValueError('OpenAI metadata upstream sanitizer body changed')
    newline = '\r\n' if '\r\n' in client else '\n'
    boundary = BOUNDARY.replace('\n', newline)
    client = insert_once(client, r'^        if !is_openai \{', boundary, 'request boundary', before=True)
    newline = '\r\n' if '\r\n' in tests else '\n'
    tests = insert_once(tests, r'assert_eq!\(item_turn_id\("turn two"\), Some\(second_turn_id\)\);',
                        ASSERTIONS.replace('\n', newline), 'request regression')
    if 'pub content_item_metadata:' in metadata[0]:
        # RLite deliberately bypasses upstream's ordinary Responses metadata filter.
        # Cover that advertised model path so this regression cannot hide behind it.
        anchor = r'^#\[tokio::test\(flavor = "multi_thread", worker_threads = 2\)\]\r?\nasync fn openai_stateless_responses_requests_preserve_item_turn_metadata_across_turns\(\)'
        tests = insert_once(tests, anchor, LITE_TEST.replace('\n', newline), 'lite regression', before=True)
    return client, tests


def patch(root):
    paths = [root / path for path in (PROTOCOL, CLIENT, TESTS)]
    original = [path.read_bytes().decode('utf-8') for path in paths]
    client, tests = transform(*original)
    changed = False
    for path, old, new in zip(paths[1:], original[1:], (client, tests)):
        if old != new:
            path.write_bytes(new.encode('utf-8'))
            changed = True
    print('OpenAI request metadata compatibility verified (classifications and attribution).')
    return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    patch(parser.parse_args().source_root.resolve())
