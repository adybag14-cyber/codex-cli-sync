"""Preserve the SQLx migration bytes used by published Windows custom builds."""
import argparse
from pathlib import Path


ATTRIBUTE = "codex-rs/state/**/*.sql text eol=crlf"


def normalize(source_root):
    root = Path(source_root).resolve()
    state = root / "codex-rs" / "state"
    git_dir = root / ".git"
    if not state.is_dir() or not git_dir.is_dir() or git_dir.is_symlink():
        raise ValueError("Expected a dedicated upstream Git checkout with codex-rs/state")
    paths = sorted(p for directory in state.iterdir()
                   if directory.is_dir() and (directory.name == "migrations" or directory.name.endswith("_migrations"))
                   for p in directory.glob("*.sql"))
    if not paths:
        raise ValueError("No SQLx migrations found")
    originals = {}
    changes = {}
    for path in paths:
        if path.is_symlink() or not path.resolve().is_relative_to(state.resolve()):
            raise ValueError(f"Migration escapes the checkout: {path}")
        raw = path.read_bytes()
        lf = raw.replace(b"\r\n", b"\n")
        if b"\r" in lf:
            raise ValueError(f"Unsupported standalone carriage return in {path}")
        originals[path] = raw
        changes[path] = lf.replace(b"\n", b"\r\n")
    # Match the checkout filter as well, so git diff/check remain clean even
    # when the developer's global core.autocrlf setting is false.
    attributes = git_dir / "info" / "attributes"
    old_attributes = attributes.read_bytes() if attributes.exists() else None
    text = (old_attributes or b"").decode("utf-8")
    if ATTRIBUTE not in text.splitlines():
        text = text.rstrip("\r\n") + ("\n" if text else "") + ATTRIBUTE + "\n"
    originals[attributes] = old_attributes
    changes[attributes] = text.encode("utf-8")
    written = []
    try:
        for path, value in changes.items():
            if value != originals[path]:
                path.parent.mkdir(parents=True, exist_ok=True)
                written.append(path)
                path.write_bytes(value)
    except BaseException:
        for path in reversed(written):
            if originals[path] is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(originals[path])
        raise
    return len(paths), sum(path != attributes for path in written)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True)
    count, changed = normalize(parser.parse_args().source_root)
    print(f"Verified Windows SQLx migration format: {count} migrations, {changed} normalized to CRLF.")
