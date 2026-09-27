"""Integration checks for the .NET companion using disposable package fixtures."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--doctor", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    executable = args.doctor.resolve()
    upstream = args.source_root.resolve()
    passed = 0

    def run(*arguments, succeeds=True):
        nonlocal passed
        result = subprocess.run([str(executable), *map(str, arguments)],
                                capture_output=True, text=True, encoding="utf-8", timeout=75)
        if (result.returncode == 0) != succeeds:
            raise AssertionError(f"{arguments}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        passed += 1
        return result.stdout

    run("self-test")
    with tempfile.TemporaryDirectory(prefix="codex-sync-doctor-test-") as temporary:
        root = Path(temporary)
        service = root / "browser-service.mjs"
        service.write_text('const protocols=Object.freeze(["http:","https:"]); navigation_url_policy_blocked;', encoding="utf-8")
        info = json.loads(run("inspect-browser", service))
        assert info["verification"] == "unknown-bundle-version"
        assert info["confirmedNavigationProtocols"] is None
        assert len(info["candidateProtocolDeclarations"]) == 1
        assert service.read_text(encoding="utf-8").startswith("const protocols=")
        assert '"https://example.com"' in run("suggest-origin", "https://example.com/path")
        run("suggest-origin", "file:///C:/probe.html", succeeds=False)
        legacy = root / "legacy"
        destination = root / "canonical"
        resources = legacy / "codex-resources"
        resources.mkdir(parents=True)
        names = ["codex.exe", "codex-resources/codex-code-mode-host.exe", "codex-resources/rg.exe",
                 "codex-resources/codex-command-runner.exe", "codex-resources/codex-windows-sandbox-setup.exe"]
        for name in names:
            (legacy / name).write_bytes(("DISPOSABLE NONEXECUTABLE FIXTURE: " + name).encode())
        (legacy / "VERSION.txt").write_text("1.2.3\n", encoding="utf-8")
        originals = {name: (legacy / name).read_bytes() for name in names}
        repaired = json.loads(run("repair-package", legacy, destination, upstream))
        assert repaired["binariesPreserved"] and not repaired["activeInstallationChanged"]
        inspected = json.loads(run("inspect-package", destination))
        assert inspected["version"] == "1.2.3" and len(inspected["files"]) == 5
        assert {name: (legacy / name).read_bytes() for name in names} == originals
        run("repair-package", legacy, destination, upstream, succeeds=False)
        run("repair-package", legacy, legacy / "nested", upstream, succeeds=False)
        run("inspect-package", legacy, succeeds=False)
        (destination / "bin/codex-code-mode-host.exe").unlink()
        run("inspect-package", destination, succeeds=False)
        metadata_path = destination / "codex-package.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["entrypoint"] = "../../unexpected.exe"
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        run("inspect-package", destination, succeeds=False)
        (legacy / "VERSION.txt").write_text("invalid-version\n", encoding="utf-8")
        run("repair-package", legacy, root / "invalid-version", upstream, succeeds=False)
        assert not (root / "invalid-version").exists()
    print(f"Passed {passed} companion integration checks plus its 9 origin-rule self-tests.")


if __name__ == "__main__":
    main()
