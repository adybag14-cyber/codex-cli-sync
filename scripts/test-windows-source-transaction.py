"""Exercise complete patch success and late failures against real upstream source."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    args = parser.parse_args()
    script = Path(__file__).with_name('patch-codex-windows-custom.ps1')
    patch_source = script.read_text(encoding='utf-8')
    input_section = patch_source.split('$patchInputs = @(', 1)[1].split('Invoke-SourcePatchTransaction', 1)[0]
    paths = sorted(set(re.findall(r"'(codex-rs/[^']+)'", input_section)))
    source = args.source_root.resolve()
    raw = {}
    for path in paths:
        value = subprocess.run(['git', '-C', str(source), 'show', f'HEAD:{path}'], capture_output=True)
        if value.returncode == 0:
            raw[path] = value.stdout
        elif path not in {'codex-rs/mcp-server/Cargo.toml', 'codex-rs/mcp-server/src/lib.rs', 'codex-rs/cli/Cargo.toml',
                         'codex-rs/guardian-context/src/retained_instructions.rs', 'codex-rs/guardian-context/src/composition.rs',
                         'codex-rs/guardian-context/tests/cache_prefix.rs', 'codex-rs/guardian-context/src/profile.rs'}:
            raise AssertionError(f'Missing required upstream source: {path}')
    if not raw:
        raise AssertionError('No upstream transaction inputs discovered')

    scenarios = ['late-daemon-export-drift', 'ambiguous-permissions', 'higher-recursion-limit', 'repeat-complete-patch']
    guardian_path = 'codex-rs/guardian-context/src/retained_instructions.rs'
    if b'assistant_end.to_owned()' in raw.get(guardian_path, b''):
        scenarios.append('guardian-constructor-drift')
    for scenario in scenarios:
        with tempfile.TemporaryDirectory(prefix='codex-real-patch-contract-') as directory:
            root = Path(directory)
            for path, value in raw.items():
                if scenario == 'late-daemon-export-drift' and path == 'codex-rs/app-server-daemon/src/lib.rs':
                    value += b'\npub mod unreviewed_autostart;\n'
                if scenario == 'ambiguous-permissions' and path == 'codex-rs/core/src/config/mod.rs':
                    value += b'\npermissions: Permissions {}\n'
                if scenario == 'guardian-constructor-drift' and path == guardian_path:
                    value = value.replace(b'assistant_end.to_owned()', b'assistant_end.to_string()', 1)
                if scenario == 'higher-recursion-limit' and path in {'codex-rs/tui/src/lib.rs', 'codex-rs/exec/src/lib.rs'}:
                    value = re.sub(rb'^#!\[recursion_limit\s*=\s*"\d+"\]\r?\n', b'', value, flags=re.M)
                    value = b'#![recursion_limit = "512"]\n' + value
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(value)
            unrelated = root / 'unrelated-user-file.txt'
            unrelated.write_bytes(b'preserve this unrelated file\r\n')
            before = {path: (root / path).read_bytes() for path in raw}
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), '-SourceRoot', str(root)],
                                    capture_output=True, text=True, timeout=90)
            if scenario in ('higher-recursion-limit', 'repeat-complete-patch'):
                if result.returncode:
                    raise AssertionError(result.stdout + result.stderr)
                if scenario == 'higher-recursion-limit':
                    for path in ('codex-rs/tui/src/lib.rs', 'codex-rs/exec/src/lib.rs'):
                        if not (root / path).read_bytes().startswith(b'#![recursion_limit = "512"]'):
                            raise AssertionError('Full patch did not preserve the higher recursion limit')
                else:
                    first = {path: (root / path).read_bytes() for path in raw}
                    repeated = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), '-SourceRoot', str(root)],
                                              capture_output=True, text=True, timeout=90)
                    if repeated.returncode or first != {path: (root / path).read_bytes() for path in raw}:
                        raise AssertionError(f'Complete patch reapplication failed or changed bytes: {repeated.stdout}{repeated.stderr}')
            else:
                diagnostic = {'late-daemon-export-drift': 'public exports changed',
                              'ambiguous-permissions': 'Multiple permission constructors',
                              'guardian-constructor-drift': 'Guardian assistant end constructor'}[scenario]
                if result.returncode == 0 or diagnostic not in result.stdout + result.stderr:
                    raise AssertionError(f'{scenario} did not reject the intended drift: {result.stdout}{result.stderr}')
                if before != {path: (root / path).read_bytes() for path in raw}:
                    raise AssertionError(f'{scenario} partially patched upstream source')
            if unrelated.read_bytes() != b'preserve this unrelated file\r\n':
                raise AssertionError('Patch modified an unrelated file')
            print(f'Passed complete source transaction scenario: {scenario}')
    print(f'Passed {len(scenarios)} real-source patch transaction scenarios against {len(raw)} inputs.')


if __name__ == '__main__':
    main()
