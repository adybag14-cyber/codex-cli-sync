"""Add default-enabled native HarnessMM without replacing provider, auth or tool dispatch.

All source-shape checks complete before writes. Unknown and partial integrations
reject. The overlay is repository-owned, and replay preserves exact source bytes.
"""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MODULE = "codex-rs/core/src/harnessmm.rs"
MARKER = "// codex-cli-sync: native HarnessMM sampling substitution."
TURN_SOURCE = "codex-rs/core/src/session/turn.rs"
LEGACY_RESULT = "SamplingRequestResult { needs_follow_up: true, last_agent_message: None }"
EDITS = {
    "codex-rs/core/src/lib.rs": [
        ("mod function_tool;", "mod function_tool;\nmod harnessmm;"),
    ],
    "codex-rs/features/src/lib.rs": [
        ("pub enum Feature {", "pub enum Feature {\n    /// Reuse literal terminal decisions at native sampling boundaries.\n    HarnessMm,"),
        ("pub const FEATURES: &[FeatureSpec] = &[", "pub const FEATURES: &[FeatureSpec] = &[\n    FeatureSpec {\n        id: Feature::HarnessMm,\n        key: \"harnessmm\",\n        stage: Stage::UnderDevelopment,\n        default_enabled: true,\n    },"),
    ],
    "codex-rs/core/src/tools/spec_plan.rs": [
        ("    if turn_context.config.update_plan_enabled {\n        registry.add(PlanHandler);\n    }",
         "    if turn_context.config.update_plan_enabled {\n        registry.add(PlanHandler);\n    }\n\n    if features.enabled(Feature::HarnessMm) && features.enabled(Feature::ShellTool) {\n        registry.add_with_exposure(crate::harnessmm::HarnessMmHandler, ToolExposure::DirectModelOnly);\n    }"),
    ],
    "codex-rs/core/src/tools/registry.rs": [
        ("                tool.on_tool_result_accepted(&invocation, result.result.as_ref());",
         "                tool.on_tool_result_accepted(&invocation, result.result.as_ref());\n                crate::harnessmm::observe(&invocation, result.result.as_ref());"),
    ],
    "codex-rs/core/src/session/turn.rs": [
        ("    let _code_mode_worker = sess.services.code_mode_service.start_turn_worker(",
         "    " + MARKER + "\n    if crate::harnessmm::try_reuse(&sess, &step_context, &tool_runtime, &input, &cancellation_token).await? {\n        return Ok((SamplingRequestResult { needs_follow_up: true, last_agent_message: None }, Vec::new()));\n    }\n    let _code_mode_worker = sess.services.code_mode_service.start_turn_worker("),
    ],
}


def source_edits(relative, text):
    """Match the result type before inserting a replay return for that layout."""
    edits = EDITS[relative]
    if relative != TURN_SOURCE:
        return edits
    definitions = re.findall(r"\bstruct\s+SamplingRequestResult\s*\{([^{}]*)\}", text)
    if len(definitions) != 1:
        raise ValueError("Expected one SamplingRequestResult definition")
    body = re.sub(r"//[^\n]*", "", definitions[0])
    fields = [re.sub(r"\s+", "", field) for field in body.split(",") if field.strip()]
    legacy = {"needs_follow_up:bool", "last_agent_message:Option<String>"}
    current = legacy | {"mailbox_preempted:bool"}
    if len(fields) != len(set(fields)) or set(fields) not in (legacy, current):
        raise ValueError("Unsupported SamplingRequestResult fields; review upstream before patching")
    # A reused terminal decision did not receive or drain mailbox input.
    result = LEGACY_RESULT if set(fields) == legacy else LEGACY_RESULT.replace(
        "last_agent_message:", "mailbox_preempted: false, last_agent_message:")
    return [(before, after.replace(LEGACY_RESULT, result)) for before, after in edits]


def transform(text, before, after, path):
    if text.count(after) == 1 and before not in text.replace(after, ""):
        return text
    if text.count(before) != 1 or after in text:
        raise ValueError(f"Unsupported HarnessMM source boundary: {path}")
    return text.replace(before, after, 1)


def patch(source):
    source = Path(source).resolve()
    originals = {}
    changes = {}
    for relative, edits in EDITS.items():
        path = source / relative
        raw = path.read_bytes()
        originals[path] = raw
        newline = "\r\n" if b"\r\n" in raw else "\n"
        text = raw.decode().replace("\r\n", "\n")
        for before, after in source_edits(relative, text):
            text = transform(text, before, after, relative)
        changes[path] = text.replace("\n", newline).encode()
    overlay = (ROOT / "patches/harnessmm/harnessmm.rs").read_bytes()
    module = source / MODULE
    originals[module] = module.read_bytes() if module.exists() else None
    if originals[module] not in (None, overlay):
        raise ValueError("Existing HarnessMM module differs from the reviewed overlay")
    # An existing module requires a complete replay, never a partial integration.
    replay = [originals[path] == value for path, value in changes.items()]
    if any(replay) != all(replay) or (all(replay) != (originals[module] is not None)):
        raise ValueError("Partial HarnessMM integration; refusing to repair unknown source")
    changes[module] = overlay
    written = []
    try:
        for path, original in originals.items():
            current = path.read_bytes() if path.exists() else None
            if current != original:
                raise ValueError(f"Source changed during HarnessMM planning: {path}")
        for path, value in changes.items():
            if value != originals[path]:
                written.append(path)
                path.write_bytes(value)
    except BaseException:
        for path in reversed(written):
            if originals[path] is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(originals[path])
        raise
    return len(written)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()
    print(f"HarnessMM: committed {patch(args.source_root)} source files; feature defaults on")
