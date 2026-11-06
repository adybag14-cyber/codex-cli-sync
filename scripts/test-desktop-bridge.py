"""Exercise the bridge against a real CLI without desktop/browser credentials.

Requires Python's websockets package. No model turn or browser action is started.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus


async def check(bridge: Path, cli: Path):
    passed = []
    with tempfile.TemporaryDirectory(prefix="codex-desktop-bridge-") as temporary:
        root = Path(temporary)
        executable = root / bridge.name
        shutil.copyfile(bridge, executable)
        state = root / "private-state"
        (root / "bridge.config.json").write_text(json.dumps({
            "cliPath": str(cli), "stateRoot": str(state),
        }), encoding="utf-8")
        home = root / "home"
        home.mkdir()
        unicode_fixture = "Transport Ω 😀 line\\path\n" * 30_000
        (home / "config.toml").write_text(
            "developer_instructions = " + json.dumps(unicode_fixture, ensure_ascii=False) + "\n", encoding="utf-8")
        environment = dict(os.environ, CODEX_HOME=str(home), RUST_LOG="error", NO_COLOR="1")
        for key in list(environment):
            if key.startswith("BROWSER_USE_ACCESS_"):
                del environment[key]

        def run(*arguments):
            return subprocess.run([str(executable), *arguments], env=environment,
                                  capture_output=True, text=True, encoding="utf-8", timeout=20)

        actual_version = subprocess.check_output([str(cli), "--version"], text=True).strip()
        result = run("--version")
        assert result.returncode == 0 and result.stdout.strip() == actual_version
        passed.append("ordinary CLI version passes through unchanged")
        result = run("app-server", "--help")
        assert result.returncode == 0 and "--listen" in result.stdout
        passed.append("app-server help does not start a listener")
        startup_arguments = ["app-server", "--print-startup-config", "--startup-client-info",
                             json.dumps({"name": "desktop_bridge_startup_test", "version": "1.0"})]
        direct = subprocess.run([str(cli), *startup_arguments], env=environment,
                                capture_output=True, text=True, encoding="utf-8", timeout=20)
        result = run(*startup_arguments)
        assert direct.returncode == result.returncode == 0
        assert json.loads(direct.stdout) == json.loads(result.stdout)
        assert "configRequirements" in json.loads(result.stdout)
        passed.append("desktop startup policy response passes through unchanged before any shared server starts")

        process = await asyncio.create_subprocess_exec(
            str(executable), "app-server", "--listen", "stdio://",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=environment,
            limit=128 * 1024 * 1024,
        )
        stderr = []

        async def drain_errors():
            while line := await process.stderr.readline():
                stderr.append(line.decode("utf-8", "replace"))
                if len(stderr) > 100:
                    del stderr[0]

        draining = asyncio.create_task(drain_errors())
        record = None

        async def read_message():
            line = await asyncio.wait_for(process.stdout.readline(), 20)
            if not line:
                raise AssertionError("bridge exited before responding")
            return json.loads(line)

        async def read_until(predicate):
            for _ in range(100):
                item = await read_message()
                if predicate(item):
                    return item
            raise AssertionError("expected notification was not received")

        async def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()

        try:
            for _ in range(600):
                paths = list(state.glob("*/connection.json"))
                if paths:
                    record = json.loads(paths[0].read_text(encoding="utf-8"))
                    break
                if process.returncode is not None:
                    raise AssertionError("bridge terminated before creating a transport")
                await asyncio.sleep(0.05)
            assert record is not None, "transport startup timeout"
            assert record["endpoint"].startswith("ws://127.0.0.1:")
            assert not record["browserHostContextInherited"]
            passed.append("binds a dynamic loopback port without manufacturing browser authorization")

            for label, headers in [("missing", {}), ("wrong", {"Authorization": "Bearer invalid-test-token"})]:
                try:
                    async with connect(record["endpoint"], additional_headers=headers, proxy=None):
                        raise AssertionError("unauthorized WebSocket was accepted")
                except InvalidStatus as error:
                    assert error.response.status_code in (401, 403)
                passed.append(f"{label} transport token is rejected")

            initialize = {"clientInfo": {"name": "desktop_bridge_transport_test", "title": "Bridge transport test", "version": "1.0"},
                          "capabilities": {"experimentalApi": True}}
            await send({"id": "stdio-init", "method": "initialize", "params": initialize})
            reply = await read_until(lambda item: item.get("id") == "stdio-init")
            assert "result" in reply, reply
            await send({"method": "initialized"})
            passed.append("preserves STDIO initialize request IDs and responses")
            await send({"id": "large-config", "method": "config/read", "params": {"includeLayers": False}})
            configuration = await read_until(lambda item: item.get("id") == "large-config")
            assert configuration["result"]["config"]["developer_instructions"] == unicode_fixture
            passed.append("large Unicode JSONL response preserves every byte of the configured text")

            # This is an independent, honestly identified client. The real server
            # broadcasts its thread notification to the desktop-side connection.
            async with connect(record["endpoint"],
                               additional_headers={"Authorization": "Bearer " + record["token"]},
                               proxy=None, max_size=32 * 1024 * 1024) as socket:
                remote_init = {"clientInfo": {"name": "desktop_bridge_second_client_test", "version": "1.0"},
                               "capabilities": {"experimentalApi": True}}
                await socket.send(json.dumps({"id": 1, "method": "initialize", "params": remote_init}))
                response = json.loads(await asyncio.wait_for(socket.recv(), 20))
                assert response.get("id") == 1 and "result" in response
                await socket.send(json.dumps({"method": "initialized"}))
                await socket.send(json.dumps({"id": 2, "method": "thread/start", "params": {
                    "model": "gpt-6-astra", "cwd": str(root), "approvalPolicy": "never",
                    "sandbox": "read-only", "ephemeral": True,
                }}))
                while True:
                    response = json.loads(await asyncio.wait_for(socket.recv(), 30))
                    if response.get("id") == 2:
                        break
                assert "result" in response, response
                thread_id = response["result"]["thread"]["id"]
                notification = await read_until(lambda item: item.get("method") == "thread/started")
                assert notification["params"]["thread"]["id"] == thread_id
            passed.append("real app server reports terminal-created threads to the desktop connection")

            status = run("--bridge-status")
            assert status.returncode == 0
            statuses = json.loads(status.stdout)
            assert len(statuses) == 1 and statuses[0]["clientName"] == "desktop_bridge_transport_test"
            assert record["token"] not in status.stdout and "token" not in statuses[0]
            passed.append("status validates live process identities and omits transport secrets")
            result = run("--bridge-connect", "--version")
            assert result.returncode != 0 and "No live desktop-started" in result.stderr
            passed.append("CLI attach refuses a server without desktop browser host context")

            acl_script = root / "check-acl.ps1"
            acl_script.write_text(
                "param([string]$StatePath)\n$ErrorActionPreference='Stop'\n"
                "$a=Get-Acl -LiteralPath $StatePath\n"
                "[pscustomobject]@{Protected=$a.AreAccessRulesProtected; "
                "Sids=@($a.Access | ForEach-Object {$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value})} | ConvertTo-Json -Compress\n",
                encoding="utf-8")
            shell = shutil.which("pwsh") or shutil.which("powershell")
            acl_env = dict(os.environ)
            acl_env.pop("PSModulePath", None)
            acl = subprocess.check_output([
                shell, "-NoProfile", "-File", str(acl_script), str(state),
            ], text=True, encoding="utf-8", env=acl_env)
            permissions = json.loads(acl)
            assert permissions["Protected"] and len(permissions["Sids"]) == 2 and "S-1-5-18" in permissions["Sids"]
            assert all(sid != "S-1-1-0" for sid in permissions["Sids"])
            passed.append("transport secret directory grants access only to the current user and SYSTEM")
        finally:
            process.stdin.close()
            await asyncio.wait_for(process.wait(), 20)
            await draining
        assert process.returncode == 0, "bridge did not exit cleanly"
        assert not list(state.glob("*/connection.json"))
        assert json.loads(run("--bridge-status").stdout) == []
        passed.append("STDIO close stops its server and removes the temporary transport credential")
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    results = asyncio.run(check(args.bridge.resolve(), args.cli.resolve()))
    report = {"passed": len(results), "checks": results,
              "scope": "Real app-server transport; no desktop/browser credentials or model turns"}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
