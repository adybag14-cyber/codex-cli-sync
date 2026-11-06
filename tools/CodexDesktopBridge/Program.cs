using System.Diagnostics;
using System.Net.WebSockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

// A transport adapter, not a browser authorization issuer. The desktop starts
// this executable using its existing CLI override. Its unmodified browser host
// remains the sole source of signed browser permission responses. Browser host
// environment values are inherited by the child and never persisted or printed.
internal static class Program
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };
    private static readonly string[] BrowserContextNames =
    ["BROWSER_USE_ACCESS_PIPE_PATH", "BROWSER_USE_ACCESS_VERIFYING_IDENTITY", "BROWSER_USE_ACCESS_EXECUTOR_ID"];
    private const string TokenEnvironment = "CODEX_DESKTOP_BRIDGE_TRANSPORT_TOKEN";
    private const int MaxMessageBytes = 128 * 1024 * 1024;

    private sealed record Config(string CliPath, string StateRoot);
    private sealed record Connection(
        int BridgePid, long BridgeStartTicks, int ServerPid, long ServerStartTicks,
        string Endpoint, string Token, string CliPath,
        bool BrowserHostContextInherited, string? ClientName);

    public static async Task<int> Main(string[] args)
    {
        try
        {
            var configurationPath = Path.Combine(AppContext.BaseDirectory, "bridge.config.json");
            var config = JsonSerializer.Deserialize<Config>(await File.ReadAllTextAsync(configurationPath), Json)
                ?? throw new InvalidOperationException("Invalid bridge configuration.");
            RequireAbsolute(config.CliPath);
            RequireAbsolute(config.StateRoot);
            if (!File.Exists(config.CliPath) || SamePath(config.CliPath, Environment.ProcessPath!))
                throw new InvalidOperationException("Configure an existing, separate Codex CLI executable.");
            if (args.FirstOrDefault() == "--bridge-status")
            {
                var connections = ReadConnections(config);
                Console.WriteLine(JsonSerializer.Serialize(connections.Select(c => new
                {
                    c.BridgePid, c.ServerPid, c.Endpoint, c.CliPath,
                    c.BrowserHostContextInherited, c.ClientName,
                    browserAuthorization = "Requires a live decision from the desktop browser host",
                }), Json));
                return 0;
            }
            if (args.FirstOrDefault() == "--bridge-connect")
                return await ConnectCli(config, args.Skip(1).ToArray());

            // Leave all ordinary CLI, schema, daemon, and already-networked server
            // invocations intact. Only the desktop's plain STDIO app-server is adapted.
            if (IsStdioServer(args)) return await Serve(config, args);
            return await RunCli(config.CliPath, args);
        }
        catch (Exception error)
        {
            // Never dump config, process environments, or connection records here.
            Console.Error.WriteLine($"Codex desktop bridge: {error.Message}");
            return 1;
        }
    }

    private static bool IsStdioServer(string[] args)
    {
        if (args.Any(a => a is "--help" or "-h" or "--version" or "-V" or "--print-startup-config" or "--startup-sign-out")) return false;
        var index = Array.IndexOf(args, "app-server");
        if (index < 0) return false;
        var commands = new HashSet<string>(StringComparer.Ordinal)
        { "generate-ts", "generate-json-schema", "generate-internal-json-schema", "daemon", "proxy", "version" };
        if (args.Skip(index + 1).Any(commands.Contains)) return false;
        for (var i = index + 1; i < args.Length; i++)
        {
            if (args[i] == "--listen")
                return i + 1 < args.Length && args[i + 1] == "stdio://";
            if (args[i].StartsWith("--listen=", StringComparison.Ordinal))
                return args[i] == "--listen=stdio://";
            if (args[i].StartsWith("--ws-", StringComparison.Ordinal)) return false;
        }
        return true;
    }

    private static async Task<int> Serve(Config config, string[] originalArgs)
    {
        var privateRoot = PrivateDirectory(config.StateRoot);
        var instance = PrivateDirectory(Path.Combine(privateRoot.FullName,
            $"{Environment.ProcessId}-{Guid.NewGuid():N}"));
        var recordPath = Path.Combine(instance.FullName, "connection.json");
        // This capability authenticates the new loopback transport only. It is
        // unrelated to the desktop's browser signing key or ChatGPT account.
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var tokenHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();
        var args = new List<string>();
        for (var i = 0; i < originalArgs.Length; i++)
        {
            if (originalArgs[i] == "--listen") { i++; continue; }
            if (originalArgs[i] == "--stdio" || originalArgs[i].StartsWith("--listen=", StringComparison.Ordinal)) continue;
            args.Add(originalArgs[i]);
        }
        args.AddRange(["--listen", "ws://127.0.0.1:0", "--ws-auth", "capability-token", "--ws-token-sha256", tokenHash]);
        var start = StartInfo(config.CliPath, args);
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.CreateNoWindow = true;
        using var server = Process.Start(start) ?? throw new InvalidOperationException("Cannot start custom app server.");
        using var stop = new CancellationTokenSource();
        var endpointReady = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stderr = DrainServerOutput(server.StandardError, endpointReady, stop.Token);
        var stdout = DrainServerOutput(server.StandardOutput, endpointReady, stop.Token);
        using var websocket = new ClientWebSocket();
        using var standardInput = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true), false);
        using var standardOutput = Console.OpenStandardOutput();
        websocket.Options.Proxy = null;
        websocket.Options.SetRequestHeader("Authorization", $"Bearer {token}");
        try
        {
            var exited = server.WaitForExitAsync();
            var timeout = Task.Delay(TimeSpan.FromSeconds(30));
            var first = await Task.WhenAny(endpointReady.Task, exited, timeout);
            if (first != endpointReady.Task)
                throw new InvalidOperationException(first == exited
                    ? $"App server exited before listening (exit {server.ExitCode})."
                    : "Timed out waiting for the app-server listener.");
            var endpoint = await endpointReady.Task;
            using (var connectTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)))
                await websocket.ConnectAsync(endpoint, connectTimeout.Token);
            using var self = Process.GetCurrentProcess();
            var connection = new Connection(self.Id, self.StartTime.ToUniversalTime().Ticks,
                server.Id, server.StartTime.ToUniversalTime().Ticks, endpoint.AbsoluteUri, token, config.CliPath,
                BrowserContextNames.All(n => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(n))), null);
            await WriteRecord(recordPath, connection);
            // Forward the desktop's own initialize/request/notification messages
            // exactly. Do not synthesize a desktop client or browser executor.
            var input = Task.Run(async () =>
            {
                while (await standardInput.ReadLineAsync(stop.Token) is { } line)
                {
                    if (Encoding.UTF8.GetByteCount(line) > MaxMessageBytes)
                        throw new InvalidOperationException("STDIO message exceeds the transport size limit.");
                    if (connection.ClientName is null)
                    {
                        using var document = JsonDocument.Parse(line);
                        var root = document.RootElement;
                        if (root.TryGetProperty("method", out var method) && method.GetString() == "initialize" &&
                            root.TryGetProperty("params", out var parameters) &&
                            parameters.TryGetProperty("clientInfo", out var client) &&
                            client.TryGetProperty("name", out var name))
                        {
                            connection = connection with { ClientName = name.GetString() };
                            await WriteRecord(recordPath, connection);
                        }
                    }
                    await websocket.SendAsync(Encoding.UTF8.GetBytes(line).AsMemory(),
                        WebSocketMessageType.Text, true, stop.Token);
                }
            }, stop.Token);
            var output = Task.Run(async () =>
            {
                var buffer = new byte[64 * 1024];
                while (!stop.IsCancellationRequested)
                {
                    using var message = new MemoryStream();
                    ValueWebSocketReceiveResult result;
                    do
                    {
                        result = await websocket.ReceiveAsync(buffer.AsMemory(), stop.Token);
                        if (result.MessageType == WebSocketMessageType.Close) return;
                        if (result.MessageType != WebSocketMessageType.Text)
                            throw new InvalidOperationException("Unexpected binary app-server message.");
                        if (message.Length + result.Count > MaxMessageBytes)
                            throw new InvalidOperationException("App-server message exceeds the transport size limit.");
                        message.Write(buffer, 0, result.Count);
                    } while (!result.EndOfMessage);
                    // JSONL is a byte protocol. Console.Out may use a Windows
                    // console code page and corrupt Unicode in large replies.
                    await standardOutput.WriteAsync(message.GetBuffer().AsMemory(0, (int)message.Length), stop.Token);
                    await standardOutput.WriteAsync(new byte[] { (byte)'\n' }, stop.Token);
                    await standardOutput.FlushAsync(stop.Token);
                }
            }, stop.Token);
            var completed = await Task.WhenAny(input, output, exited);
            await completed;
            return server.HasExited ? server.ExitCode : 0;
        }
        finally
        {
            stop.Cancel();
            websocket.Abort();
            // Only the exact child started above is stopped. Never stop other
            // desktop, browser, Codex, or Node processes.
            if (!server.HasExited) server.Kill(entireProcessTree: true);
            await server.WaitForExitAsync();
            try { await Task.WhenAll(stderr, stdout); } catch (OperationCanceledException) { }
            foreach (var path in new[] { recordPath, recordPath + ".tmp" })
                if (File.Exists(path)) File.Delete(path);
            // Nonrecursive deletion fails safely if unexpected files appeared.
            if (Directory.Exists(instance.FullName)) Directory.Delete(instance.FullName, false);
        }
    }

    private static async Task DrainServerOutput(StreamReader reader, TaskCompletionSource<Uri> endpoint, CancellationToken stop)
    {
        while (await reader.ReadLineAsync(stop) is { } line)
        {
            var match = Regex.Match(line, @"ws://127\.0\.0\.1:(\d+)");
            if (match.Success && Uri.TryCreate(match.Value, UriKind.Absolute, out var uri) && uri.Port > 0)
                endpoint.TrySetResult(uri);
            await Console.Error.WriteLineAsync(line);
        }
    }

    private static async Task<int> ConnectCli(Config config, string[] args)
    {
        int? selectedPid = null;
        if (args.FirstOrDefault() == "--instance")
        {
            if (args.Length < 2 || !int.TryParse(args[1], out var pid))
                throw new InvalidOperationException("--instance requires a bridge process ID.");
            selectedPid = pid;
            args = args.Skip(2).ToArray();
        }
        if (args.Any(a => a == "--remote" || a.StartsWith("--remote=", StringComparison.Ordinal) ||
                          a.StartsWith("--remote-auth-token-env", StringComparison.Ordinal)))
            throw new InvalidOperationException("The bridge supplies its own remote transport options.");
        var connections = ReadConnections(config).Where(c => c.BrowserHostContextInherited &&
            !string.IsNullOrWhiteSpace(c.ClientName) && (selectedPid is null || c.BridgePid == selectedPid)).ToArray();
        if (connections.Length != 1)
            throw new InvalidOperationException(connections.Length == 0
                ? "No live desktop-started server with browser host context. Start the desktop through the bridge launcher first."
                : "Multiple desktop servers are available. Use --bridge-status, then --bridge-connect --instance <bridgePid>.");
        var connection = connections[0];
        var options = new[] { "--remote", connection.Endpoint, "--remote-auth-token-env", TokenEnvironment }.Concat(args).ToArray();
        return await RunCli(connection.CliPath, options, connection.Token);
    }

    private static List<Connection> ReadConnections(Config config)
    {
        var result = new List<Connection>();
        if (!Directory.Exists(config.StateRoot)) return result;
        foreach (var directory in new DirectoryInfo(config.StateRoot).EnumerateDirectories())
        {
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) continue;
            var path = Path.Combine(directory.FullName, "connection.json");
            try
            {
                if (!File.Exists(path) || new FileInfo(path).Length > 16 * 1024) continue;
                var c = JsonSerializer.Deserialize<Connection>(File.ReadAllText(path), Json);
                if (c is null || !SamePath(c.CliPath, config.CliPath) ||
                    !Uri.TryCreate(c.Endpoint, UriKind.Absolute, out var uri) ||
                    uri.Scheme != "ws" || uri.Host != "127.0.0.1" || uri.Port <= 0 ||
                    !string.IsNullOrEmpty(uri.UserInfo) || c.Token.Length != 64) continue;
                using var bridge = Process.GetProcessById(c.BridgePid);
                using var server = Process.GetProcessById(c.ServerPid);
                if (bridge.StartTime.ToUniversalTime().Ticks != c.BridgeStartTicks ||
                    server.StartTime.ToUniversalTime().Ticks != c.ServerStartTicks ||
                    !SamePath(bridge.MainModule!.FileName, Environment.ProcessPath!) ||
                    !SamePath(server.MainModule!.FileName, config.CliPath)) continue;
                result.Add(c);
            }
            catch (Exception error) when (error is IOException or JsonException or ArgumentException or
                InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return result;
    }

    private static DirectoryInfo PrivateDirectory(string path)
    {
        RequireAbsolute(path);
        var directory = new DirectoryInfo(path);
        if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Bridge state directory must not be a reparse point.");
        directory.Create();
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var currentUser = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("No Windows user identity.");
        foreach (var identity in new[] { currentUser, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        return directory;
    }

    private static async Task WriteRecord(string path, Connection connection)
    {
        await File.WriteAllTextAsync(path + ".tmp", JsonSerializer.Serialize(connection, Json));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    private static ProcessStartInfo StartInfo(string executable, IEnumerable<string> args)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        return start;
    }

    private static async Task<int> RunCli(string executable, string[] args, string? token = null)
    {
        var start = StartInfo(executable, args);
        if (token is not null) start.Environment[TokenEnvironment] = token;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start Codex CLI.");
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private static bool SamePath(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private static void RequireAbsolute(string path)
    {
        if (!Path.IsPathFullyQualified(path)) throw new InvalidOperationException("Bridge paths must be absolute.");
    }
}
