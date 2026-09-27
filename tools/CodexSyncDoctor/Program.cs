using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

internal static class Program
{
    private const string VerifiedBrowserHash = "b40b10c44f2397b3137c40060ace432cc2487e6075b07551a6944f81bea3bb91";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static readonly string[] PackageFiles = [
        "bin/codex.exe", "bin/codex-code-mode-host.exe", "codex-path/rg.exe",
        "codex-resources/codex-command-runner.exe", "codex-resources/codex-windows-sandbox-setup.exe"
    ];

    private static int Main(string[] args)
    {
        try
        {
            switch (args)
            {
                case ["inspect-browser", var service]:
                    Print(InspectBrowser(service));
                    break;
                case ["inspect-package", var package]:
                    Print(InspectPackage(package));
                    break;
                case ["suggest-origin", var url]:
                    Console.WriteLine(OriginRule(url));
                    break;
                case ["repair-package", var legacy, var destination, var upstream]:
                    Print(RepairPackage(legacy, destination, upstream));
                    break;
                case ["self-test"]:
                    SelfTest();
                    break;
                case ["--help"] or ["-h"] or []:
                    Console.WriteLine("""
                        codex-sync-doctor inspect-browser <browser-service.mjs>
                        codex-sync-doctor inspect-package <package-root>
                        codex-sync-doctor suggest-origin <http-or-https-url>
                        codex-sync-doctor repair-package <legacy-root> <new-destination> <openai-codex-source-root>
                        codex-sync-doctor self-test

                        Browser inspection is read-only and distinguishes verified from unknown bundle versions.
                        suggest-origin prints an exact-origin TOML rule; allow still leaves other checks in force.
                        repair-package uses the supplied upstream Python package builder with existing binaries.
                        It creates a new package, preserves the old one, and never switches an active installation.
                        """);
                    break;
                default:
                    throw new ArgumentException("Unknown command or wrong argument count. Use --help.");
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }

    private static void Print(object value) => Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
    private static string Hash(string file) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file)));

    private static object InspectBrowser(string file)
    {
        file = Path.GetFullPath(file);
        var source = File.ReadAllText(file);
        var hash = Hash(file);
        var verified = hash == VerifiedBrowserHash;
        var candidates = Regex.Matches(source,
            "Object\\.freeze\\(\\[(?:\"[a-z][a-z0-9+.-]*:\"(?:,|(?=\\]))){1,16}\\]\\)",
            RegexOptions.CultureInvariant, TimeSpan.FromSeconds(2))
            .Select(match => new { characterOffset = match.Index, declaration = match.Value }).ToArray();
        string[] reasons = ["navigation_url_policy_blocked", "enterprise_policy_blocked",
            "browser_capability_blocked", "guardian_denied", "persisted_user_denied", "site_status_blocked"];
        return new
        {
            path = file,
            sha256 = hash,
            verification = verified ? "verified-26.924.22138" : "unknown-bundle-version",
            confirmedNavigationProtocols = verified ? new[] { "http:", "https:" } : null,
            confirmedNavigationExceptions = verified ? new[] { "about:blank" } : null,
            confirmedOriginRuleSchemes = verified ? new[] { "http", "https" } : null,
            candidateProtocolDeclarations = candidates,
            policyReasonMarkers = reasons.Where(reason => source.Contains(reason, StringComparison.Ordinal)).ToArray(),
            interpretation = verified
                ? "CLI config/read accepts string keys; this service only matches HTTP/HTTPS origins. Access allow neither changes the navigation protocol gate nor overrides other policy checks."
                : "Static markers only. Re-run source and tool verification before claiming runtime support for this version.",
            filesChanged = false
        };
    }

    private static object InspectPackage(string root)
    {
        root = Path.GetFullPath(root);
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "codex-package.json")));
        var metadata = document.RootElement;
        if (metadata.GetProperty("layoutVersion").GetInt32() != 1)
            throw new InvalidDataException("Unsupported package layout version.");
        foreach (var (key, expected) in new Dictionary<string, string> {
            ["target"] = "x86_64-pc-windows-msvc", ["variant"] = "codex", ["entrypoint"] = "bin/codex.exe",
            ["resourcesDir"] = "codex-resources", ["pathDir"] = "codex-path"
        })
            if (metadata.GetProperty(key).GetString() != expected)
                throw new InvalidDataException($"Invalid package {key}: expected {expected}.");
        foreach (var relative in PackageFiles)
            if (!File.Exists(Path.Combine(root, relative)))
                throw new FileNotFoundException($"Required package file is missing: {relative}");
        return new
        {
            root, layoutVersion = 1, version = metadata.GetProperty("version").GetString(),
            files = PackageFiles.Select(relative => new { path = relative, sha256 = Hash(Path.Combine(root, relative)) }).ToArray(),
            filesChanged = false
        };
    }

    private static string OriginRule(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https") || string.IsNullOrEmpty(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo))
            throw new ArgumentException("Only absolute HTTP/HTTPS URLs without embedded credentials have supported origin rules. No configuration was changed.");
        var host = uri.HostNameType == UriHostNameType.IPv6 ? $"[{uri.IdnHost.Trim('[', ']')}]" : uri.IdnHost;
        var origin = $"{uri.Scheme}://{host}{(uri.IsDefaultPort ? "" : $":{uri.Port}")}";
        // A quoted TOML key has the same escaping for this restricted URL alphabet.
        return $"[browser_use.origins.{JsonSerializer.Serialize(origin)}]\naccess = \"allow\"";
    }

    private static object RepairPackage(string legacy, string destination, string upstream)
    {
        legacy = Path.GetFullPath(legacy);
        destination = Path.GetFullPath(destination);
        upstream = Path.GetFullPath(upstream);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("Repair destination must not already exist; use a new directory.");
        if (destination.StartsWith(legacy.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Repair destination must be outside the legacy package.");
        var builder = Path.Combine(upstream, "scripts", "build_codex_package.py");
        if (!File.Exists(builder))
            throw new FileNotFoundException("The supplied OpenAI Codex source has no canonical package builder.");
        var version = File.ReadAllText(Path.Combine(legacy, "VERSION.txt")).Trim();
        var inputs = new Dictionary<string, string> {
            ["--entrypoint-bin"] = "codex.exe", ["--code-mode-host-bin"] = "codex-resources/codex-code-mode-host.exe",
            ["--rg-bin"] = "codex-resources/rg.exe", ["--codex-command-runner-bin"] = "codex-resources/codex-command-runner.exe",
            ["--codex-windows-sandbox-setup-bin"] = "codex-resources/codex-windows-sandbox-setup.exe"
        };
        var hashes = new Dictionary<string, string>();
        foreach (var relative in inputs.Values)
        {
            var path = Path.Combine(legacy, relative);
            if (!File.Exists(path)) throw new FileNotFoundException($"Missing legacy binary: {relative}");
            hashes[relative] = Hash(path);
        }
        var start = new ProcessStartInfo("python") {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.Environment["CODEX_REPO_ROOT"] = upstream;
        start.ArgumentList.Add(builder);
        foreach (var argument in new[] { "--target", "x86_64-pc-windows-msvc", "--variant", "codex",
            "--package-version", version, "--package-dir", destination })
            start.ArgumentList.Add(argument);
        foreach (var (option, relative) in inputs)
        {
            start.ArgumentList.Add(option);
            start.ArgumentList.Add(Path.Combine(legacy, relative));
        }
        using var process = Process.Start(start) ?? throw new IOException("Could not start the upstream package builder.");
        var builderOutput = process.StandardOutput.ReadToEndAsync();
        var builderError = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(60000))
        {
            process.Kill();
            process.WaitForExit();
            throw new TimeoutException("The owned package-builder process timed out. The source package was not changed.");
        }
        if (process.ExitCode != 0)
            throw new IOException($"Upstream package builder failed with exit code {process.ExitCode}: {builderError.GetAwaiter().GetResult()}");
        var mapping = new Dictionary<string, string> {
            ["codex.exe"] = "bin/codex.exe", ["codex-resources/codex-code-mode-host.exe"] = "bin/codex-code-mode-host.exe",
            ["codex-resources/rg.exe"] = "codex-path/rg.exe", ["codex-resources/codex-command-runner.exe"] = "codex-resources/codex-command-runner.exe",
            ["codex-resources/codex-windows-sandbox-setup.exe"] = "codex-resources/codex-windows-sandbox-setup.exe"
        };
        foreach (var (oldPath, newPath) in mapping)
            if (Hash(Path.Combine(legacy, oldPath)) != hashes[oldPath] || Hash(Path.Combine(destination, newPath)) != hashes[oldPath])
                throw new IOException($"Binary identity changed while repackaging: {oldPath}");
        File.WriteAllText(Path.Combine(destination, "VERSION.txt"), version + "\n");
        InspectPackage(destination);
        return new { source = legacy, destination, version, repaired = true, binariesPreserved = true,
            activeInstallationChanged = false, builderOutput = builderOutput.GetAwaiter().GetResult().Trim() };
    }

    private static void SelfTest()
    {
        var passed = 0;
        foreach (var (input, expected) in new[] {
            ("https://example.com/path?q=1", "https://example.com"),
            ("http://localhost:8765/probe", "http://localhost:8765"),
            ("https://example.com:443/", "https://example.com"),
            ("http://[::1]:8765/path", "http://[::1]:8765")
        })
        {
            if (OriginRule(input) != $"[browser_use.origins.{JsonSerializer.Serialize(expected)}]\naccess = \"allow\"")
                throw new InvalidOperationException($"Origin normalization failed for {input}");
            passed++;
        }
        foreach (var input in new[] { "file:///C:/probe.html", "data:text/plain,test", "chrome://version", "https://user:secret@example.com/", "not a URL" })
        {
            try { OriginRule(input); }
            catch (ArgumentException) { passed++; continue; }
            throw new InvalidOperationException($"Unsupported origin was accepted: {input}");
        }
        Print(new { passed, suite = "origin-rule compatibility" });
    }
}
