"""Bridge the October 7 retained-context expressions to SectionContent.

Only four reviewed expressions and one outdated test method are changed. Retention, source provenance,
omission notices, section ordering and authorization semantics stay intact.
Unknown or duplicate expressions fail before any source file is written.
"""
import argparse
from pathlib import Path
import re

SOURCE = "codex-rs/guardian-context/src/retained_instructions.rs"
COMPOSITION = "codex-rs/guardian-context/src/composition.rs"
PROFILE = "codex-rs/guardian-context/src/profile.rs"
CACHE_TEST = "codex-rs/guardian-context/tests/cache_prefix.rs"


def wrap_expression(text, prefix, item, suffix, label, allow_into=False):
    old = re.compile(f"(?P<prefix>{prefix})(?P<item>{item})(?P<suffix>{suffix})")
    wrapped = rf"SectionContent::Other\(\s*{item}\s*\)"
    if allow_into:
        wrapped = rf"(?:{wrapped}|{item}\s*\.into\(\))"
    fixed = re.compile(prefix + wrapped + suffix)
    old_matches, fixed_matches = list(old.finditer(text)), list(fixed.finditer(text))
    if len(old_matches) + len(fixed_matches) != 1:
        raise ValueError(f"Guardian {label}: expected exactly one reviewed old or fixed expression")
    if fixed_matches:
        return text
    match = old_matches[0]
    return text[:match.start("item")] + "SectionContent::Other(" + match.group("item") + ")" + text[match.end("item"):]


def patched_source(text, composition):
    if "assistant_start" not in text and "assistant_end" not in text:
        return text
    if not re.search(r"enum\s+SectionContent\s*\{", composition) or \
            not re.search(r"\bOther\(ContentItem\)", composition) or \
            "use crate::composition::SectionContent;" not in text:
        raise ValueError("Guardian SectionContent representation changed")
    if "fn deduplicate_transcript_instructions(" not in text or "fn retain_new_instructions(" not in text:
        raise ValueError("Guardian retained-context entry points changed")

    prefix = r"matches!\(\s*&item\.content,\s*"
    item = r"ContentItem::InputText\s*\{\s*text\s*\}"
    text = wrap_expression(text, prefix, item,
                           r"\s*if text\.strip_suffix\('\\n'\)\s*==\s*Some\(assistant_omission\.as_str\(\)\)",
                           "assistant omission match")
    text = wrap_expression(text, prefix, item,
                           r"\s*if text\s*==\s*assistant_start\s*\|\|\s*text\s*==\s*assistant_end",
                           "assistant marker match")
    for marker in ("start", "end"):
        text = wrap_expression(text, r"Budgeted::required\(\s*",
                               rf"ContentItem::InputText\s*\{{\s*text:\s*assistant_{marker}\.to_owned\(\),?\s*\}}",
                               r"\s*,?\s*\)", f"assistant {marker} constructor", allow_into=True)
    return text


def patched_cache_test(text, profile):
    if "pub fn render_transcript(" in profile:
        return text
    if "profile.render_transcript(" not in text:
        return text
    if "pub fn prepare_transcript(" not in profile or \
            text.count("profile.render_transcript(") != 1 or \
            "collected.transcript_entries()" not in text:
        raise ValueError("Guardian cache-prefix test transcript API changed")
    return text.replace("profile.render_transcript(", "profile.prepare_transcript(")


def patch(root):
    source = root / SOURCE
    if not source.is_file():
        print("Guardian retained-context bridge not needed: this source has no retained-instructions file.")
        return False
    text = source.read_bytes().decode("utf-8")
    composition_path = root / COMPOSITION
    if not composition_path.is_file():
        raise ValueError("Guardian composition source is missing")
    planned = {source: (text, patched_source(text, composition_path.read_bytes().decode("utf-8")))}
    cache_test = root / CACHE_TEST
    if cache_test.is_file():
        profile = root / PROFILE
        if not profile.is_file():
            raise ValueError("Guardian profile source is missing")
        original_test = cache_test.read_bytes().decode("utf-8")
        planned[cache_test] = (original_test, patched_cache_test(original_test, profile.read_bytes().decode("utf-8")))
    written = []
    try:
        for path, (original, updated) in planned.items():
            if original != updated:
                written.append(path)
                path.write_bytes(updated.encode("utf-8"))
    except OSError:
        for path in written:
            path.write_bytes(planned[path][0].encode("utf-8"))
        raise
    print(f"Guardian retained-context compatibility verified; changed {len(written)} source/test files.")
    return bool(written)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    patch(parser.parse_args().source_root.resolve())
