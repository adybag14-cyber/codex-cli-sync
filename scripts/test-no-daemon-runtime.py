"""Exercise a fresh CLI's default TUI with a local Responses server and no credentials."""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


DISABLED = "The local daemon is disabled in this custom build; run codex directly."
ANSWER = "DAEMON_FREE_HI_OK"


def check_disabled_commands(run_result, config_home):
    checks = []
    for command in ("start", "restart", "stop", "version", "bootstrap", "enable-remote-control",
                    "disable-remote-control", "update", "pid-update-loop"):
        arguments = ["app-server", "daemon", command]
        if command == "bootstrap":
            arguments += ["--json"]
        result = run_result(*arguments)
        if result.returncode == 0 or DISABLED not in result.stderr + result.stdout:
            raise AssertionError(f"Daemon {command} did not reject before startup: {result}")
        checks.append(f"daemon_disabled:{command}")
    result = run_result("app-server", "--managed-daemon")
    if result.returncode == 0 or DISABLED not in result.stderr + result.stdout:
        raise AssertionError(f"Managed daemon worker was not rejected: {result}")
    if (config_home / "app-server-daemon").exists():
        raise AssertionError("Disabled commands created daemon state")
    return checks + ["managed_daemon_worker_disabled", "no_daemon_state_created"]


class Terminal:
    def __init__(self, args, cwd, env):
        self.messages = queue.Queue()
        if os.name == "nt":
            from winpty import PtyProcess
            self.process = PtyProcess.spawn(args, cwd=str(cwd), env=env, dimensions=(35, 140))
            self.read = lambda: self.process.read(8192)
            self.write = self.process.write
            self.alive = self.process.isalive
        else:
            import fcntl
            import pty
            import struct
            import termios
            self.master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))

            def attach():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            self.process = subprocess.Popen(args, cwd=cwd, env=env, stdin=slave, stdout=slave,
                                            stderr=slave, preexec_fn=attach)
            os.close(slave)
            self.read = lambda: os.read(self.master, 8192).decode("utf-8", errors="replace")
            self.write = lambda data: os.write(self.master, data.encode())
            self.alive = lambda: self.process.poll() is None
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while value := self.read():
                self.messages.put(value)
        except (EOFError, OSError):
            pass
        finally:
            self.messages.put(None)

    def close(self):
        if self.alive():
            self.write("\x03")
            time.sleep(0.2)
            if self.alive():
                self.write("\x03")
        deadline = time.monotonic() + 10
        while self.alive() and time.monotonic() < deadline:
            time.sleep(0.1)
        if self.alive():
            # Only the exact subprocess handle created by this fixture is closed.
            if os.name == "nt":
                self.process.terminate(force=True)
            else:
                self.process.kill()
        if os.name != "nt":
            self.process.wait(timeout=5)
            os.close(self.master)
        self.reader.join(timeout=5)


def smoke(executable, root):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(body)
            message = {"id": "msg_hi", "type": "message", "role": "assistant", "status": "completed",
                       "content": [{"type": "output_text", "text": ANSWER, "annotations": []}]}
            events = [
                {"type": "response.created", "response": {"id": "resp_hi"}},
                {"type": "response.output_item.added", "output_index": 0,
                 "item": dict(message, status="in_progress", content=[])},
                {"type": "response.output_text.delta", "item_id": "msg_hi", "output_index": 0,
                 "content_index": 0, "delta": ANSWER},
                {"type": "response.output_item.done", "output_index": 0, "item": message},
                {"type": "response.completed", "response": {"id": "resp_hi", "status": "completed",
                 "output": [message], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}},
            ]
            data = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    config_home, workspace = root / "home", root / "workspace"
    config_home.mkdir()
    workspace.mkdir()
    (config_home / "config.toml").write_text(f'''model = "gpt-5.1"
model_provider = "smoke"
approval_policy = "never"
cli_auth_credentials_store = "file"
[features]
daemon_auto_start = true
[model_providers.smoke]
name = "Isolated Responses fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
[projects.{json.dumps(str(workspace))}]
trust_level = "trusted"
''', encoding="utf-8")
    env = dict(os.environ, CODEX_HOME=str(config_home), TERM="xterm-256color")
    for key in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_HOME_OVERRIDE",
                "CODEX_EXEC_SERVER_URL", "NO_COLOR"):
        env.pop(key, None)

    def run_result(*args):
        return subprocess.run([str(executable), *args], cwd=workspace, env=env, capture_output=True,
                              text=True, encoding="utf-8", timeout=45,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    terminal = None
    transcript = ""
    try:
        checks = check_disabled_commands(run_result, config_home)
        # No --no-daemon, --disable or -c override: they could mask a broken default.
        terminal = Terminal([str(executable), "--no-alt-screen", "hi"], workspace, env)
        deadline = time.monotonic() + 120
        while ANSWER not in transcript:
            value = terminal.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if value is None:
                raise AssertionError(f"Default TUI exited before answering hi: {transcript[-6000:]}")
            transcript += value
            if "\x1b[6n" in value:
                terminal.write("\x1b[1;1R")
            if time.monotonic() >= deadline:
                raise AssertionError(f"Default TUI did not answer hi: {transcript[-6000:]}")
        if not any(item.get("role") == "user" and any(part.get("text") == "hi" for part in item.get("content", []))
                   for request in requests for item in request.get("input", [])):
            raise AssertionError("Responses server did not receive the user's hi message")
        if (config_home / "app-server-daemon").exists():
            raise AssertionError("Default TUI created daemon state")
        checks += ["default_interactive_hi_round_trip", "daemon_auto_start_cannot_override_patch",
                   "no_daemon_state_after_interactive_turn"]
        return {"checks": checks, "passed": len(checks), "requestCount": len(requests), "prompt": "hi",
                "answer": ANSWER, "backend": "local Responses fixture", "uid": os.getuid() if os.name != "nt" else None}
    finally:
        if terminal is not None:
            terminal.close()
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    executable = args.codex.resolve()
    with tempfile.TemporaryDirectory(prefix=".cx-free-", dir=Path.home()) as temporary:
        report = smoke(executable, Path(temporary).resolve())
    report["executableSha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
