"""Exercise the standalone Edge installer with a real CLI and disposable config."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    shell = shutil.which('pwsh')
    assert shell, 'PowerShell 7 is required for this Windows installer check'
    checks = []
    with tempfile.TemporaryDirectory(prefix='codex-edge-install-') as temporary:
        root = Path(temporary).resolve()
        assert root.parent == Path(tempfile.gettempdir()).resolve()
        binary = root / 'bin' / 'codex.exe'
        binary.parent.mkdir()
        os.link(args.cli.resolve(), binary)
        home = root / 'home'
        home.mkdir()
        base = home / 'config.toml'
        original = b'model = "gpt-6-astra"\n[mcp_servers.node_repl]\ncommand = "node"\n[mcp_servers.playwright]\nurl = "http://127.0.0.1:1/mcp"\n'
        base.write_bytes(original)
        environment = dict(os.environ)
        environment.pop('CODEX_HOME', None)
        environment.pop('PSModulePath', None)
        command = [shell, '-NoProfile', '-File', str(repository / 'scripts/Install-CodexEdge.ps1'),
                   '-CliPath', str(binary), '-CodexHome', str(home),
                   '-InstallRoot', str(root / 'installed'), '-RuntimeDirectory', str(args.runtime.resolve())]
        result = subprocess.run(command, env=environment, capture_output=True, text=True, encoding='utf-8', timeout=60)
        assert result.returncode == 0, result.stderr
        installed = json.loads(result.stdout)
        profile = Path(installed['profile'])
        config = tomllib.loads(profile.read_text(encoding='utf-8'))
        assert base.read_bytes() == original
        assert config['mcp_servers']['codex_edge']['enabled']
        assert '--sandbox' in config['mcp_servers']['codex_edge']['args']
        assert '--no-sandbox' not in config['mcp_servers']['codex_edge']['args']
        checks.append('installer preserves base config and enables the sandboxed Edge STDIO runtime')
        assert not config['mcp_servers']['node_repl']['enabled']
        assert not config['mcp_servers']['playwright']['enabled']
        assert 'cua_repl' not in config['mcp_servers']
        checks.append('disabled server overrides come from the selected home, including valid transports')
        launcher = Path(installed['command'])
        result = subprocess.run([shell, '-NoProfile', '-File', str(launcher), 'mcp', 'list', '--json'],
            env=environment, capture_output=True, text=True, encoding='utf-8', timeout=30)
        assert result.returncode == 0, result.stderr
        servers = {s['name']: s for s in json.loads(result.stdout)}
        assert servers['codex_edge']['enabled'] and not servers['node_repl']['enabled']
        checks.append('the real custom CLI parses the generated profile and resolves the Edge server')
        isolated = dict(environment, BROWSER_USE_ACCESS_PIPE_PATH='unused-test-context',
                        BROWSER_USE_ACCESS_VERIFYING_IDENTITY='unused-test-context',
                        BROWSER_USE_ACCESS_EXECUTOR_ID='unused-test-context')
        result = subprocess.run([shell, '-NoProfile', '-File', str(launcher), '--edge-status'],
            env=isolated, capture_output=True, text=True, encoding='utf-8', timeout=30)
        # The disposable home is intentionally not signed in; no credentials are copied.
        first_line = result.stdout.splitlines()[0]
        assert json.loads(first_line)['desktopContextVariablesPresent'] == []
        checks.append('launcher removes inherited desktop context without creating or copying login credentials')
        saved_launcher = launcher.read_bytes()
        unmanaged = b'# user-maintained profile\nmodel = "gpt-6-astra"\n'
        profile.write_bytes(unmanaged)
        refused = subprocess.run(command, env=environment, capture_output=True, text=True, encoding='utf-8', timeout=30)
        assert refused.returncode != 0 and 'unmanaged profile' in refused.stderr
        assert profile.read_bytes() == unmanaged and launcher.read_bytes() == saved_launcher
        checks.append('installer refuses to overwrite an unmanaged profile or its existing launcher')
    report = {'passed': len(checks), 'checks': checks}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
