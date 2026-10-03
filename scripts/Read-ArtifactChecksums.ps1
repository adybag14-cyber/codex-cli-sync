function Read-ArtifactChecksums {
    param([string[]]$Lines, [string[]]$RequiredNames)
    $hashes = @{}
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line.Trim(), '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>[^\\/]+)$')
        if (-not $match.Success) { throw "Invalid artifact checksum line: $line" }
        $name = $match.Groups['name'].Value
        if ($hashes.ContainsKey($name)) { throw "Duplicate artifact checksum entry: $name" }
        $hashes[$name] = $match.Groups['hash'].Value.ToLowerInvariant()
    }
    foreach ($name in $RequiredNames) {
        if (-not $hashes.ContainsKey($name)) { throw "Required artifact checksum is missing: $name" }
    }
    return $hashes
}
