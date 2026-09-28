"""Exercise a packaged Windows CLI without using the user's config or credentials."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading


class AppServer:
    def __init__(self, executable, cwd, env):
        self.messages = queue.Queue()
        self.serial = 0
        self.process = subprocess.Popen(
            [str(executable), "app-server", "--listen", "stdio://"],
            cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(EOFError("Probe app-server closed stdout"))

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def request(self, method, params, *, expect_error=False):
        self.serial += 1
        request_id = self.serial
        self.send({"id": request_id, "method": method, "params": params})
        # Notifications do not reset the deadline for a request.
        import time
        deadline = time.monotonic() + 45
        while True:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if message.get("id") != request_id:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"App-server did not answer {method}")
                continue
            if expect_error:
                if message.get("error", {}).get("code") != -32600:
                    raise AssertionError(f"Expected invalid-request response: {message}")
                return message["error"]
            if "error" in message:
                raise AssertionError(f"{method} failed: {message['error']}")
            return message["result"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # This exact subprocess was created above; no daemon or process-name kills.
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        self.process.stdout.close()


def debug_commands(source_root):
    source = (source_root / "codex-rs/cli/src/main.rs").read_text(encoding="utf-8")
    matches = re.findall(r"^enum DebugSubcommand \{\n(.*?)^\}", source, re.M | re.S)
    if len(matches) != 1:
        raise AssertionError("Cannot identify the upstream DebugSubcommand enum")
    variants = re.findall(r"^    ([A-Z][A-Za-z0-9_]*)\s*(?:\([^\n]*\))?,\s*$", matches[0], re.M)
    if not variants:
        raise AssertionError("Upstream debug command list is empty or changed shape")
    return [re.sub(r"(?<!^)(?=[A-Z])", "-", value).lower() for value in variants]


def windows_token_is_elevated():
    """Query the real process token, not CI environment flags or group names.

    An API failure must fail the probe rather than silently selecting the less
    privileged branch. TOKEN_ELEVATION is also what the upstream daemon checks.
    """
    import ctypes
    from ctypes import wintypes

    if os.name != "nt":
        raise OSError("The packaged Windows runtime probe requires Windows")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.OpenProcessToken.restype = wintypes.BOOL
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
                                          wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    advapi.GetTokenInformation.restype = wintypes.BOOL
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 0x0008, ctypes.byref(token)):  # TOKEN_QUERY
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        elevation, returned = wintypes.DWORD(), wintypes.DWORD()
        if not advapi.GetTokenInformation(token, 20, ctypes.byref(elevation),  # TokenElevation
                                          ctypes.sizeof(elevation), ctypes.byref(returned)):
            raise ctypes.WinError(ctypes.get_last_error())
        if returned.value != ctypes.sizeof(elevation):
            raise OSError("Windows returned an invalid TOKEN_ELEVATION size")
        return bool(elevation.value)
    finally:
        kernel.CloseHandle(token)


def check_isolated_daemon(*, config_home, executable, expected_version, elevated, run, run_result):
    """Check the daemon's contract for this token, always cleaning up our namespace.

    Administrators must be rejected; ordinary users must start the exact packaged
    binary. Neither branch skips the daemon probe or changes the upstream guard.
    """
    checks = []
    daemon_state = config_home / "app-server-daemon"
    # Let Codex create its state directory with the required private Windows ACL.
    initialized = json.loads(run("app-server", "daemon", "stop"))
    if initialized["status"] != "notRunning":
        raise AssertionError("A newly created disposable CODEX_HOME unexpectedly had a daemon")
    (daemon_state / "settings.json").write_text(json.dumps({
        "remoteControlEnabled": False, "shutdownGraceSeconds": 1,
        "updater": {"autoUpdateEnabled": False},
    }), encoding="utf-8")
    try:
        if elevated:
            result = run_result("app-server", "daemon", "start")
            expected_error = ("start the Windows daemon from a non-elevated terminal; "
                              "shared clients must not inherit administrator privileges")
            if result.returncode == 0 or expected_error not in result.stderr:
                raise AssertionError(
                    "Elevated daemon launch did not produce the expected security rejection: "
                    f"exit={result.returncode}, stderr={result.stderr[-2000:]}"
                )
            checks.append("isolated_daemon_rejects_elevated_start")
        else:
            started = json.loads(run("app-server", "daemon", "start"))
            if started["status"] != "started" or not started.get("pid"):
                raise AssertionError(f"Disposable daemon did not start: {started}")
            managed = Path(started["managedCodexPath"]).resolve()
            if not managed.is_relative_to(config_home.resolve()):
                raise AssertionError("Probe daemon package escaped its disposable CODEX_HOME")
            if hashlib.sha256(managed.read_bytes()).digest() != hashlib.sha256(executable.read_bytes()).digest():
                raise AssertionError("Daemon did not use the exact packaged CLI binary")
            running = json.loads(run("app-server", "daemon", "version"))
            if running["status"] != "running" or running["appServerVersion"] != expected_version:
                raise AssertionError(f"Probe daemon reports the wrong version: {running}")
            checks.append("isolated_daemon_starts_exact_packaged_binary")
    finally:
        stopped = json.loads(run("app-server", "daemon", "stop"))
        if stopped["status"] not in {"stopped", "notRunning"}:
            raise AssertionError(f"Disposable daemon was not stopped: {stopped}")
        if elevated and stopped["status"] != "notRunning":
            raise AssertionError("Rejected elevated launch unexpectedly left a running daemon")
    checks.append("isolated_daemon_remains_stopped" if elevated else "isolated_daemon_stopped")
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--require-visible-debug", action="store_true")
    parser.add_argument("--require-no-daemon", action="store_true")
    parser.add_argument("--require-daemon-lifecycle", action="store_true",
                        help="Fail unless running non-elevated so full daemon startup/shutdown is exercised")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.require_no_daemon and args.require_daemon_lifecycle:
        parser.error("Daemon removal and legacy daemon lifecycle checks are mutually exclusive")
    elevated = windows_token_is_elevated()
    if args.require_daemon_lifecycle and elevated:
        raise AssertionError("Full daemon lifecycle checks require a non-elevated Windows terminal")
    package = args.package.resolve()
    executable = package / "bin/codex.exe"
    metadata = json.loads((package / "codex-package.json").read_text(encoding="utf-8-sig"))
    expected = {"layoutVersion": 1, "entrypoint": "bin/codex.exe", "variant": "codex",
                "target": "x86_64-pc-windows-msvc", "resourcesDir": "codex-resources", "pathDir": "codex-path"}
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise AssertionError(f"Package {key}: expected {value!r}, got {metadata.get(key)!r}")
    for relative in ["bin/codex.exe", "bin/codex-code-mode-host.exe", "codex-path/rg.exe",
                     "codex-resources/codex-command-runner.exe", "codex-resources/codex-windows-sandbox-setup.exe"]:
        if not (package / relative).is_file():
            raise AssertionError(f"Missing required package file: {relative}")
    checks = ["canonical_package_layout"]
    commands = debug_commands(args.source_root.resolve())
    # Codex deliberately refuses helper aliases under the OS shared temp directory.
    # Use a short disposable user-profile path: Windows AF_UNIX sockets are also
    # limited by SUN_LEN, so deep checkout/package paths cannot host this probe.
    with tempfile.TemporaryDirectory(prefix=".cx-", dir=Path.home()) as temporary:
        root = Path(temporary).resolve()
        config_home = root / "home"
        workspace = root / "workspace"
        config_home.mkdir()
        workspace.mkdir()
        env = dict(os.environ, CODEX_HOME=str(config_home))
        for variable in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY"]:
            env.pop(variable, None)
        (config_home / "config.toml").write_text('''model = "gpt-5.1"
model_provider = "probe"
[model_providers.probe]
name = "Local schema registration probe"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
requires_openai_auth = false
[browser_use.default_origin_policy]
access = "allow"
uploads = "deny"
downloads = "deny"
full_cdp_access = "deny"
[browser_use.origins."http://example.com"]
access = "allow"
[browser_use.origins."https://example.com"]
access = "allow"
[browser_use.origins."file://*"]
access = "allow"
[browser_use.origins."data:*"]
access = "allow"
''', encoding="utf-8")

        def run_result(*arguments):
            return subprocess.run([str(executable), *arguments], cwd=workspace, env=env,
                                    capture_output=True, text=True, encoding="utf-8", timeout=45,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

        def run(*arguments):
            result = run_result(*arguments)
            if result.returncode:
                raise AssertionError(f"CLI {arguments!r} failed: {result.stderr[-2000:]}")
            return result.stdout

        version = run("--version").strip()
        if metadata["version"] not in version:
            raise AssertionError("Package manifest and executable versions differ")
        debug_help = run("debug", "--help")
        for command in commands:
            # clear-memories is only inspected with --help, never executed.
            run("debug", command, "--help")
            if args.require_visible_debug and not re.search(r"^  " + re.escape(command) + r"\s", debug_help, re.M):
                raise AssertionError(f"Debug command remains hidden: {command}")
            checks.append(f"debug_help:{command}")
        run("debug", "app-server", "send-message-v2", "--help")
        checks.append("debug_help:app-server/send-message-v2")
        catalog = json.loads(run("debug", "models", "--bundled"))
        if not isinstance(catalog, (dict, list)) or not catalog:
            raise AssertionError("Bundled model catalog is empty")
        checks.append("debug_models_bundled_json")
        schema_dir = root / "schemas"
        run("app-server", "generate-json-schema", "--experimental", "--out", str(schema_dir))
        schema_files = list(schema_dir.rglob("*.json"))
        if not schema_files:
            raise AssertionError("App-server schema generator emitted no JSON")
        for schema in schema_files:
            json.loads(schema.read_text(encoding="utf-8"))
        checks.append("experimental_protocol_schemas_parse")
        rpc = AppServer(executable, workspace, env)
        try:
            rpc.request("initialize", {"clientInfo": {"name": "windows-release-probe", "version": "1.0.0"},
                                       "capabilities": {"experimentalApi": True}})
            rpc.send({"method": "initialized"})
            config = rpc.request("config/read", {"includeLayers": False, "cwd": str(workspace)})["config"]["browser_use"]
            if set(config["origins"]) != {"http://example.com", "https://example.com", "file://*", "data:*"}:
                raise AssertionError("Browser config string keys were lost in config/read")
            if config["default_origin_policy"]["uploads"] != "deny":
                raise AssertionError("Browser upload deny was lost")
            checks.append("browser_config_round_trip_is_not_scheme_support")

            def function(schema, *, legacy=False):
                value = {"name": "echo_probe", "description": "Schema registration probe", "inputSchema": schema}
                if not legacy:
                    value["type"] = "function"
                return value

            object_schema = {"type": "object", "properties": {"text": {"type": "string"}},
                             "required": ["text"], "additionalProperties": False}
            cases = {
                "canonical_function": [function(object_schema)],
                "legacy_function": [function(object_schema, legacy=True)],
                "missing_type_sanitized": [function({"properties": {}})],
                "nullable_field": [function({"type": "object", "properties": {"text": {"type": ["string", "null"]}}})],
                "namespaced_deferred_function": [{"type": "namespace", "name": "probe_tools", "description": "Probe namespace",
                                                  "tools": [dict(function(object_schema), deferLoading=True)]}],
            }
            for label, tools in cases.items():
                response = rpc.request("thread/start", {"cwd": str(workspace), "ephemeral": True, "dynamicTools": tools})
                if not response.get("thread", {}).get("id"):
                    raise AssertionError(f"No thread ID after registering {label}")
                if args.require_no_daemon and (response.get("approvalPolicy") != "never"
                                              or response.get("sandbox") != {"type": "dangerFullAccess"}):
                    raise AssertionError("Daemon removal regressed the Windows approval/sandbox overrides: "
                                         + str({key: response.get(key) for key in ("approvalPolicy", "sandbox")}))
                checks.append(f"dynamic_tool_registration:{label}")
            if args.require_no_daemon:
                checks.append("windows_approval_never_and_sandbox_disabled_preserved")
            for label, tools in {
                "invalid_root_schema": [function({"type": "null"})],
                "mixed_legacy_and_canonical": [function(object_schema), function(object_schema, legacy=True)],
            }.items():
                rpc.request("thread/start", {"cwd": str(workspace), "ephemeral": True, "dynamicTools": tools}, expect_error=True)
                checks.append(f"invalid_tool_rejected:{label}")
        finally:
            rpc.close()
        if args.require_no_daemon:
            from importlib.util import module_from_spec, spec_from_file_location
            spec = spec_from_file_location("no_daemon", Path(__file__).with_name("test-no-daemon-runtime.py"))
            no_daemon = module_from_spec(spec)
            spec.loader.exec_module(no_daemon)
            checks.extend(no_daemon.check_disabled_commands(run_result, config_home))
        else:
            checks.extend(check_isolated_daemon(
                config_home=config_home, executable=executable, expected_version=metadata["version"],
                elevated=elevated, run=run, run_result=run_result,
            ))
    report = {"version": version, "packageLayout": metadata, "debugCommands": commands,
              "debugCommandsRequiredVisible": args.require_visible_debug, "schemaFileCount": len(schema_files),
              "executableSha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "passed": len(checks), "checks": checks,
              "daemonProbe": {"tokenElevated": elevated,
                              "mode": "disabled" if args.require_no_daemon else ("elevated_rejection" if elevated else "non_elevated_lifecycle"),
                              "lifecycleExercised": not args.require_no_daemon and not elevated},
              "scope": ("Offline CLI, schema generation, tool registration, and "
                        + ("local daemon entry points disabled. " if args.require_no_daemon else "elevated daemon rejection (startup/shutdown is not exercised). " if elevated
                           else "isolated daemon startup/shutdown. ")
                        + "Tool execution round trips are covered by the upstream app-server dynamic_tools test suite.")}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Passed {len(checks)} packaged Windows runtime checks; generated {len(schema_files)} valid JSON schema files.")
    print(f"Daemon probe: {report['daemonProbe']['mode']}; lifecycleExercised={report['daemonProbe']['lifecycleExercised']}.")


if __name__ == "__main__":
    main()
