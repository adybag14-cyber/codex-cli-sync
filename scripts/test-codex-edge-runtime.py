"""Validate the pinned Edge MCP runtime over private STDIO, without desktop context."""

import argparse
import asyncio
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import threading


PAGE = """<!doctype html><html lang="en"><meta charset="utf-8">
<title>Codex standalone Edge verification</title>
<body><h1>Codex standalone Edge</h1>
<p>The browser is managed by the CLI through private STDIO.</p>
<button id="verify" onclick="document.getElementById('result').textContent='Interaction verified'">Verify interaction</button>
<p id="result" role="status">Ready</p></body></html>"""


def independent_environment():
    prefixes = ("BROWSER_USE_", "CUA_REPL_", "NODE_REPL_", "SKY_CUA_", "CODEX_APP_TOOLS_",
                "CODEX_TASK_WORKSPACE_", "PLAYWRIGHT_MCP_")
    exact = {"CODEX_CLI_PATH", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_THREAD_ID",
             "CODEX_MCP_NODE_PATH", "CODEX_DESKTOP_BRIDGE_TRANSPORT_TOKEN",
             "CODEX_WINDOWS_REGISTERED_CORE", "CODEX_WINDOWS_SANDBOX_PACKAGE_FAMILY",
             "GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"}
    return {k: v for k, v in os.environ.items() if not k.startswith(prefixes) and k not in exact}


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        super().do_GET()


async def check(node: str, runtime: Path, output: Path):
    output.mkdir(parents=True, exist_ok=True)
    (output / "index.html").write_text(PAGE, encoding="utf-8")
    http = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(output)))
    worker = threading.Thread(target=http.serve_forever, daemon=True)
    worker.start()
    url = f"http://127.0.0.1:{http.server_address[1]}/index.html"
    command = [node, str(runtime / "node_modules/@playwright/mcp/cli.js"),
               "--browser", "msedge", "--headless", "--isolated", "--sandbox", "--output-dir", str(output)]
    env = independent_environment()
    process = await asyncio.create_subprocess_exec(*command, cwd=output, env=env,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, limit=32 * 1024 * 1024)
    serial = 0
    errors = []

    async def drain_errors():
        while line := await process.stderr.readline():
            errors.append(line.decode("utf-8", "replace"))

    draining = asyncio.create_task(drain_errors())

    async def call(method, params):
        nonlocal serial
        serial += 1
        requested = serial
        process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": requested, "method": method, "params": params}) + "\n").encode())
        await process.stdin.drain()
        while True:
            line = await asyncio.wait_for(process.stdout.readline(), 70)
            if not line:
                raise AssertionError("Edge MCP exited before replying")
            reply = json.loads(line)
            if "method" in reply and "id" in reply:
                if reply["method"] != "roots/list":
                    raise AssertionError("Unexpected interactive request: " + reply["method"])
                process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": reply["id"], "result": {
                    "roots": [{"uri": output.as_uri(), "name": "Edge verification"}]}}) + "\n").encode())
                await process.stdin.drain()
                continue
            if reply.get("id") == requested:
                assert "error" not in reply, reply.get("error")
                return reply["result"]

    def text(result):
        return "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")

    def observation(result):
        rendered = text(result)
        # This MCP release exports snapshots as files. Read only paths actually
        # returned by the tool and only inside this disposable fixture workspace.
        for match in re.finditer(r"\[Snapshot\]\(([^)]+)\)", rendered):
            snapshot = (output / match.group(1)).resolve()
            assert snapshot.is_relative_to(output), "Snapshot escaped the test workspace"
            rendered += "\n" + snapshot.read_text(encoding="utf-8")
        return rendered

    async def tool(name, arguments):
        result = await call("tools/call", {"name": name, "arguments": arguments})
        with (output / "tool-results.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps({"tool": name, "result": result}) + "\n")
        assert not result.get("isError"), text(result)
        return result

    report = {"browser": "msedge", "transport": "stdio", "desktopContextVariablesPresent": [], "checks": []}
    try:
        initialization = await call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {"roots": {}},
            "clientInfo": {"name": "codex-edge-integration-test", "version": "1.0"}})
        report["serverInfo"] = initialization["serverInfo"]
        process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        await process.stdin.drain()
        available = {t["name"]: t for t in (await call("tools/list", {}))["tools"]}
        required = {"browser_navigate", "browser_snapshot", "browser_click", "browser_evaluate", "browser_close", "browser_take_screenshot"}
        assert required <= available.keys()
        report["checks"].append("pinned MCP initializes and exposes the required browser tools")
        assert not any(k.startswith(("BROWSER_USE_ACCESS_", "CODEX_APP_TOOLS_", "CODEX_TASK_WORKSPACE_")) for k in env)
        report["checks"].append("browser process starts without desktop authorization context")

        navigated = observation(await tool("browser_navigate", {"url": url}))
        assert "Codex standalone Edge" in navigated and "Verify interaction" in navigated, navigated[:4000]
        report["checks"].append("installed Edge opens and reads the local verification page")
        match = re.search(r'button "Verify interaction".*?\[ref=([^\]]+)\]', navigated)
        assert match, "Expected the button's actual snapshot reference"
        clicked = observation(await tool("browser_click", {"target": match.group(1), "element": "Verify interaction button"}))
        assert "Interaction verified" in clicked
        report["checks"].append("clicking the observed button changes the visible page state")
        identity = text(await tool("browser_evaluate", {"function": "() => navigator.userAgent"}))
        assert "Edg/" in identity, identity
        report["checks"].append("the running browser identifies itself as Microsoft Edge")
        report["edgeVersion"] = re.search(r"Edg/([\d.]+)", identity).group(1)
        screenshot_path = output / "edge-runtime-smoke.png"
        previous_write = screenshot_path.stat().st_mtime_ns if screenshot_path.exists() else None
        screenshot = await tool("browser_take_screenshot", {"type": "png", "filename": "edge-runtime-smoke.png", "fullPage": True})
        assert screenshot_path.is_file(), text(screenshot)
        assert screenshot_path.stat().st_mtime_ns != previous_write, "Screenshot was not refreshed"
        report["checks"].append("browser screenshot captures the verified page")
        await tool("browser_close", {})
        report["checks"].append("the test browser closes through its own MCP lifecycle")
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 15)
        except asyncio.TimeoutError:
            process.kill()  # Only the test-owned child; never existing Edge processes.
            await process.wait()
            raise AssertionError("MCP did not shut down after STDIO closed")
        finally:
            await draining
            http.shutdown()
            http.server_close()
            (output / "mcp-stderr.log").write_text("".join(errors), encoding="utf-8")
    assert process.returncode == 0
    report["checks"].append("closing private STDIO shuts down the MCP process cleanly")
    report["passed"] = len(report["checks"])
    report["screenshot"] = str(output / "edge-runtime-smoke.png")
    (output / "runtime-checks.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", default="node")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = asyncio.run(check(args.node, args.runtime.resolve(), args.output.resolve()))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
