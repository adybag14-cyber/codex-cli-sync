[CmdletBinding()]
param(
    [string]$UpstreamRepo = "openai/codex",
    [string]$UpstreamRef = "main",
    [string]$LinuxTarget = "i686-unknown-linux-musl",
    [string]$StateDir = (Join-Path $PSScriptRoot "..\state"),
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "..\out"),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($LinuxTarget -ne "i686-unknown-linux-musl") {
    throw "Unsupported Linux target: $LinuxTarget"
}

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$WorkspaceDir = [System.IO.Path]::GetFullPath($WorkspaceDir)

function Write-ActionOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [string]$WorkingDirectory = $PWD.Path
    )

    Push-Location $WorkingDirectory
    try {
        & git @Args
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Get-UpstreamHead {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    if ($Ref -match '^[0-9a-fA-F]{40}$') {
        return $Ref.ToLowerInvariant()
    }

    $remote = "https://github.com/$Repo.git"
    $candidates = @(
        "refs/heads/$Ref",
        "refs/tags/$Ref",
        $Ref
    )

    foreach ($candidate in $candidates) {
        $output = & git ls-remote $remote $candidate
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-remote failed for $remote $candidate"
        }
        $line = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($line.Count -gt 0) {
            return ([string]$line[0]).Split("`t")[0]
        }
    }

    throw "Could not resolve upstream ref '$Ref' from $remote."
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 20
    Set-Content -Path $Path -Value $json -Encoding utf8
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Enable-I686MuslVendoredOpenSsl {
    param([Parameter(Mandatory = $true)][string]$CargoTomlPath)

    $text = [System.IO.File]::ReadAllText($CargoTomlPath)
    if ($text -match '\[target\.i686-unknown-linux-musl\.dependencies\][\s\S]*?openssl-sys\s*=') {
        return $false
    }

    $addition = @'

# Build OpenSSL from source for 32-bit musl builds.
[target.i686-unknown-linux-musl.dependencies]
openssl-sys = { workspace = true, features = ["vendored"] }
'@

    [System.IO.File]::WriteAllText(
        $CargoTomlPath,
        $text.TrimEnd() + $addition + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $true
}

function Disable-I686MuslV8CodeMode {
    param([Parameter(Mandatory = $true)][string]$CodexRsDir)

    $codeModeDir = Join-Path $CodexRsDir "code-mode"
    $cargoTomlPath = Join-Path $codeModeDir "Cargo.toml"
    $runtimePath = Join-Path $codeModeDir "src/runtime/mod.rs"
    $servicePath = Join-Path $codeModeDir "src/service.rs"

    foreach ($requiredPath in @($cargoTomlPath, $runtimePath, $servicePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required code-mode file not found: $requiredPath"
        }
    }

    $cargoToml = [System.IO.File]::ReadAllText($cargoTomlPath)
    $cargoToml = $cargoToml -replace 'sandbox = \["v8/v8_enable_sandbox"\]', 'sandbox = []'
    $cargoToml = $cargoToml -replace '(?m)^deno_core_icudata = \{ workspace = true \}\r?\n', ''
    $cargoToml = $cargoToml -replace '(?m)^v8 = \{ workspace = true \}\r?\n', ''
    [System.IO.File]::WriteAllText(
        $cargoTomlPath,
        $cargoToml,
        [System.Text.UTF8Encoding]::new($false)
    )

    $runtimeSource = @'
use codex_protocol::ToolName;
use serde::Serialize;
use serde_json::Value as JsonValue;

use crate::description::CodeModeToolKind;
use crate::description::ToolDefinition;
use crate::response::FunctionCallOutputContentItem;
use crate::service::CellId;

pub const DEFAULT_EXEC_YIELD_TIME_MS: u64 = 10_000;
pub const DEFAULT_WAIT_YIELD_TIME_MS: u64 = 10_000;
pub const DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL: usize = 10_000;

#[derive(Clone, Debug)]
pub struct ExecuteRequest {
    pub tool_call_id: String,
    pub enabled_tools: Vec<ToolDefinition>,
    pub source: String,
    pub yield_time_ms: Option<u64>,
    pub max_output_tokens: Option<usize>,
}

#[derive(Clone, Debug)]
pub struct WaitRequest {
    pub cell_id: CellId,
    pub yield_time_ms: u64,
}

#[derive(Clone, Debug)]
pub struct WaitToPendingRequest {
    pub cell_id: CellId,
}

#[derive(Debug, PartialEq)]
pub enum WaitOutcome {
    LiveCell(RuntimeResponse),
    MissingCell(RuntimeResponse),
}

#[derive(Debug, PartialEq)]
pub enum ExecuteToPendingOutcome {
    Pending {
        cell_id: CellId,
        content_items: Vec<FunctionCallOutputContentItem>,
        pending_tool_call_ids: Vec<String>,
    },
    Completed(RuntimeResponse),
}

#[derive(Debug, PartialEq)]
pub enum WaitToPendingOutcome {
    LiveCell(ExecuteToPendingOutcome),
    MissingCell(RuntimeResponse),
}

impl From<WaitOutcome> for RuntimeResponse {
    fn from(outcome: WaitOutcome) -> Self {
        match outcome {
            WaitOutcome::LiveCell(response) | WaitOutcome::MissingCell(response) => response,
        }
    }
}

#[derive(Debug, PartialEq, Serialize)]
pub enum RuntimeResponse {
    Yielded {
        cell_id: CellId,
        content_items: Vec<FunctionCallOutputContentItem>,
    },
    Terminated {
        cell_id: CellId,
        content_items: Vec<FunctionCallOutputContentItem>,
    },
    Result {
        cell_id: CellId,
        content_items: Vec<FunctionCallOutputContentItem>,
        error_text: Option<String>,
    },
}

#[derive(Debug)]
pub struct CodeModeNestedToolCall {
    pub cell_id: CellId,
    pub runtime_tool_call_id: String,
    pub tool_name: ToolName,
    pub tool_kind: CodeModeToolKind,
    pub input: Option<JsonValue>,
}
'@

    $serviceSource = @'
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;

use serde::Deserialize;
use serde::Serialize;
use serde_json::Value as JsonValue;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::FunctionCallOutputContentItem;
use crate::runtime::CodeModeNestedToolCall;
use crate::runtime::ExecuteRequest;
use crate::runtime::RuntimeResponse;
use crate::runtime::WaitOutcome;
use crate::runtime::WaitRequest;

const UNAVAILABLE: &str = "code mode is unavailable in this i686-unknown-linux-musl build because rusty_v8 does not publish a prebuilt V8 archive for this target";

pub type CodeModeSessionResultFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, String>> + Send + 'a>>;
pub type CodeModeSessionProviderFuture<'a> =
    CodeModeSessionResultFuture<'a, Arc<dyn CodeModeSession>>;
pub type ToolInvocationFuture<'a> =
    Pin<Box<dyn Future<Output = Result<JsonValue, String>> + Send + 'a>>;
pub type NotificationFuture<'a> = Pin<Box<dyn Future<Output = Result<(), String>> + Send + 'a>>;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct CellId(String);

impl CellId {
    pub fn new(value: String) -> Self {
        Self(value)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for CellId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for CellId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

pub struct StartedCell {
    pub cell_id: CellId,
    initial_response_rx: oneshot::Receiver<RuntimeResponse>,
}

impl StartedCell {
    fn ready(cell_id: CellId, response: RuntimeResponse) -> Self {
        let (response_tx, initial_response_rx) = oneshot::channel();
        let _ = response_tx.send(response);
        Self {
            cell_id,
            initial_response_rx,
        }
    }

    pub async fn initial_response(self) -> Result<RuntimeResponse, String> {
        self.initial_response_rx
            .await
            .map_err(|_| "exec runtime ended unexpectedly".to_string())
    }
}

pub trait CodeModeSessionDelegate: Send + Sync {
    fn invoke_tool<'a>(
        &'a self,
        invocation: CodeModeNestedToolCall,
        cancellation_token: CancellationToken,
    ) -> ToolInvocationFuture<'a>;

    fn notify<'a>(
        &'a self,
        call_id: String,
        cell_id: CellId,
        text: String,
        cancellation_token: CancellationToken,
    ) -> NotificationFuture<'a>;

    fn cell_closed(&self, cell_id: &CellId);
}

pub struct NoopCodeModeSessionDelegate;

impl CodeModeSessionDelegate for NoopCodeModeSessionDelegate {
    fn invoke_tool<'a>(
        &'a self,
        _invocation: CodeModeNestedToolCall,
        cancellation_token: CancellationToken,
    ) -> ToolInvocationFuture<'a> {
        Box::pin(async move {
            cancellation_token.cancelled().await;
            Err("code mode nested tools are unavailable".to_string())
        })
    }

    fn notify<'a>(
        &'a self,
        _call_id: String,
        _cell_id: CellId,
        _text: String,
        _cancellation_token: CancellationToken,
    ) -> NotificationFuture<'a> {
        Box::pin(async { Ok(()) })
    }

    fn cell_closed(&self, _cell_id: &CellId) {}
}

pub trait CodeModeSession: Send + Sync {
    fn execute<'a>(
        &'a self,
        request: ExecuteRequest,
    ) -> CodeModeSessionResultFuture<'a, StartedCell>;

    fn wait<'a>(&'a self, request: WaitRequest) -> CodeModeSessionResultFuture<'a, WaitOutcome>;

    fn terminate<'a>(&'a self, cell_id: CellId) -> CodeModeSessionResultFuture<'a, WaitOutcome>;

    fn shutdown<'a>(&'a self) -> CodeModeSessionResultFuture<'a, ()>;
}

pub trait CodeModeSessionProvider: Send + Sync {
    fn create_session<'a>(
        &'a self,
        delegate: Arc<dyn CodeModeSessionDelegate>,
    ) -> CodeModeSessionProviderFuture<'a>;
}

#[derive(Default)]
pub struct InProcessCodeModeSessionProvider;

impl CodeModeSessionProvider for InProcessCodeModeSessionProvider {
    fn create_session<'a>(
        &'a self,
        delegate: Arc<dyn CodeModeSessionDelegate>,
    ) -> CodeModeSessionProviderFuture<'a> {
        Box::pin(async move {
            let session: Arc<dyn CodeModeSession> =
                Arc::new(CodeModeService::with_delegate(delegate));
            Ok(session)
        })
    }
}

pub struct CodeModeService {
    next_cell_id: AtomicU64,
    delegate: Arc<dyn CodeModeSessionDelegate>,
}

impl CodeModeService {
    pub fn new() -> Self {
        Self::with_delegate(Arc::new(NoopCodeModeSessionDelegate))
    }

    pub fn with_delegate(delegate: Arc<dyn CodeModeSessionDelegate>) -> Self {
        Self {
            next_cell_id: AtomicU64::new(1),
            delegate,
        }
    }

    pub async fn execute(&self, request: ExecuteRequest) -> Result<StartedCell, String> {
        let cell_id = self.allocate_cell_id();
        let response = unavailable_response(cell_id.clone(), request_summary(&request));
        self.delegate.cell_closed(&cell_id);
        Ok(StartedCell::ready(cell_id, response))
    }

    pub async fn wait(&self, request: WaitRequest) -> Result<WaitOutcome, String> {
        let response = unavailable_response(request.cell_id, None);
        Ok(WaitOutcome::MissingCell(response))
    }

    pub async fn terminate(&self, cell_id: CellId) -> Result<WaitOutcome, String> {
        let response = unavailable_response(cell_id, None);
        Ok(WaitOutcome::MissingCell(response))
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        Ok(())
    }

    fn allocate_cell_id(&self) -> CellId {
        CellId::new(self.next_cell_id.fetch_add(1, Ordering::Relaxed).to_string())
    }
}

impl Default for CodeModeService {
    fn default() -> Self {
        Self::new()
    }
}

impl CodeModeSession for CodeModeService {
    fn execute<'a>(
        &'a self,
        request: ExecuteRequest,
    ) -> CodeModeSessionResultFuture<'a, StartedCell> {
        Box::pin(CodeModeService::execute(self, request))
    }

    fn wait<'a>(&'a self, request: WaitRequest) -> CodeModeSessionResultFuture<'a, WaitOutcome> {
        Box::pin(CodeModeService::wait(self, request))
    }

    fn terminate<'a>(&'a self, cell_id: CellId) -> CodeModeSessionResultFuture<'a, WaitOutcome> {
        Box::pin(CodeModeService::terminate(self, cell_id))
    }

    fn shutdown<'a>(&'a self) -> CodeModeSessionResultFuture<'a, ()> {
        Box::pin(CodeModeService::shutdown(self))
    }
}

fn unavailable_response(cell_id: CellId, request_summary: Option<String>) -> RuntimeResponse {
    let mut content_items = Vec::new();
    if let Some(summary) = request_summary {
        content_items.push(FunctionCallOutputContentItem::InputText { text: summary });
    }
    RuntimeResponse::Result {
        cell_id,
        content_items,
        error_text: Some(UNAVAILABLE.to_string()),
    }
}

fn request_summary(request: &ExecuteRequest) -> Option<String> {
    if request.source.trim().is_empty() {
        return None;
    }
    Some("JavaScript code mode was requested, but this build does not include V8.".to_string())
}
'@

    [System.IO.File]::WriteAllText(
        $runtimePath,
        $runtimeSource,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $servicePath,
        $serviceSource,
        [System.Text.UTF8Encoding]::new($false)
    )

    return $true
}

function Enable-I686MuslLinuxSandboxSyscallBuild {
    param([Parameter(Mandatory = $true)][string]$CodexRsDir)

    $landlockPath = Join-Path $CodexRsDir "linux-sandbox/src/landlock.rs"
    if (-not (Test-Path -LiteralPath $landlockPath -PathType Leaf)) {
        throw "Required linux sandbox file not found: $landlockPath"
    }

    $text = [System.IO.File]::ReadAllText($landlockPath)
    $originalText = $text

    $text = $text.Replace(
        @'
    fn deny_syscall(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: i64) {
        rules.insert(nr, vec![]); // empty rule vec = unconditional match
    }
'@,
        @'
    fn deny_syscall<T>(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: T)
    where
        T: Into<i64>,
    {
        rules.insert(nr.into(), vec![]); // empty rule vec = unconditional match
    }
'@
    )

    $text = $text.Replace(
        "            deny_syscall(&mut rules, libc::SYS_accept);",
        @'
            #[cfg(not(all(target_arch = "x86", target_env = "musl")))]
            deny_syscall(&mut rules, libc::SYS_accept);
'@
    )

    $text = $text.Replace(
        "            rules.insert(libc::SYS_socket, vec![unix_only_rule.clone()]);",
        "            rules.insert(libc::SYS_socket.into(), vec![unix_only_rule.clone()]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![unix_only_rule]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![unix_only_rule]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socket, vec![deny_non_ip_socket]);",
        "            rules.insert(libc::SYS_socket.into(), vec![deny_non_ip_socket]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![deny_unix_socketpair]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![deny_unix_socketpair]);"
    )
    $text = $text.Replace(
        "            rules.insert(libc::SYS_socketpair, vec![deny_non_unix_socketpair]);",
        "            rules.insert(libc::SYS_socketpair.into(), vec![deny_non_unix_socketpair]);"
    )

    if ($text -eq $originalText) {
        throw "Linux sandbox syscall compatibility patch did not change $landlockPath"
    }

    [System.IO.File]::WriteAllText(
        $landlockPath,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )

    return $true
}

function Set-I686MuslBuildEnvironment {
    $env:OPENSSL_STATIC = "1"
    $env:AWS_LC_SYS_NO_JITTER_ENTROPY = "1"
    $env:PKG_CONFIG_ALLOW_CROSS = "1"
    $env:CARGO_BUILD_JOBS = "2"

    # Zig's i686 musl libatomic does not provide __atomic_is_lock_free; make
    # vendored OpenSSL use its lock-based pthread atomic fallback instead.
    $opensslNoAtomicsFlag = "-D__STDC_NO_ATOMICS__"
    if ([string]::IsNullOrWhiteSpace($env:CFLAGS_i686_unknown_linux_musl)) {
        $env:CFLAGS_i686_unknown_linux_musl = $opensslNoAtomicsFlag
    } elseif ($env:CFLAGS_i686_unknown_linux_musl -notmatch [regex]::Escape($opensslNoAtomicsFlag)) {
        $env:CFLAGS_i686_unknown_linux_musl = "$($env:CFLAGS_i686_unknown_linux_musl) $opensslNoAtomicsFlag"
    }

    $rustFlags = "-C target-feature=+crt-static -C strip=symbols"
    if ([string]::IsNullOrWhiteSpace($env:RUSTFLAGS)) {
        $env:RUSTFLAGS = $rustFlags
    } else {
        $env:RUSTFLAGS = "$($env:RUSTFLAGS) $rustFlags"
    }
}

function Get-CaCertificatesBundle {
    $candidates = @(
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "Could not find a system CA certificates bundle to include."
}

function Invoke-TarGzip {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -Force -LiteralPath $ArchivePath
    }

    Push-Location $WorkingDirectory
    try {
        & tar -czf $ArchivePath $EntryName
        if ($LASTEXITCODE -ne 0) {
            throw "tar failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null

$generatedAt = [DateTime]::UtcNow.ToString("o")
$latestShaPath = Join-Path $StateDir "latest-linux-i686-musl-sha.txt"
$latestStatePath = Join-Path $StateDir "latest-linux-i686-musl.json"
$sourceDir = Join-Path $WorkspaceDir "codex-upstream-linux-i686"
$remoteUrl = "https://github.com/$UpstreamRepo.git"
$upstreamSha = Get-UpstreamHead -Repo $UpstreamRepo -Ref $UpstreamRef
$upstreamShortSha = $upstreamSha.Substring(0, 12)
$releaseTag = "linux-i686-musl-$upstreamShortSha"
$rollingTag = "latest-linux-i686-musl"
$payloadName = "codex-linux-i686-musl-$upstreamShortSha"
$releaseWorkspace = Join-Path $WorkspaceDir "linux-i686-musl-$upstreamShortSha"
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.tar.gz"))
$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDir "$payloadName.manifest.json"))

Write-ActionOutput -Name "changed" -Value "false"
Write-ActionOutput -Name "upstream_repo" -Value $UpstreamRepo
Write-ActionOutput -Name "upstream_ref" -Value $UpstreamRef
Write-ActionOutput -Name "upstream_sha" -Value $upstreamSha
Write-ActionOutput -Name "upstream_short_sha" -Value $upstreamShortSha
Write-ActionOutput -Name "linux_target" -Value $LinuxTarget
Write-ActionOutput -Name "release_tag" -Value $releaseTag
Write-ActionOutput -Name "rolling_tag" -Value $rollingTag
Write-ActionOutput -Name "generated_at" -Value $generatedAt
Write-ActionOutput -Name "bundle_path" -Value ""
Write-ActionOutput -Name "manifest_path" -Value ""
Write-ActionOutput -Name "version_output" -Value ""

$currentSha = ""
if (Test-Path -LiteralPath $latestShaPath -PathType Leaf) {
    $currentSha = (Get-Content -Path $latestShaPath -Raw).Trim()
}

Write-Host "Upstream $UpstreamRepo $UpstreamRef resolves to $upstreamSha."
if (-not $Force -and $currentSha -eq $upstreamSha) {
    Write-Host "State already points at $upstreamSha. Skipping Linux i686 musl build."
    return
}

if (Test-Path -LiteralPath (Join-Path $sourceDir ".git") -PathType Container) {
    Invoke-Git -WorkingDirectory $sourceDir -Args @("remote", "set-url", "origin", $remoteUrl)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("fetch", "--no-tags", "--depth", "1", "origin", $upstreamSha)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("reset", "--hard")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("clean", "-ffdx", "-e", "codex-rs/target/")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("checkout", "--detach", "FETCH_HEAD")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("reset", "--hard", "FETCH_HEAD")
    Invoke-Git -WorkingDirectory $sourceDir -Args @("clean", "-ffdx", "-e", "codex-rs/target/")
} else {
    if (Test-Path -LiteralPath $sourceDir) {
        Remove-Item -Recurse -Force -LiteralPath $sourceDir
    }
    Invoke-Git -WorkingDirectory $WorkspaceDir -Args @("clone", "--no-tags", "--depth", "1", $remoteUrl, $sourceDir)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("fetch", "--no-tags", "--depth", "1", "origin", $upstreamSha)
    Invoke-Git -WorkingDirectory $sourceDir -Args @("checkout", "--detach", "FETCH_HEAD")
}

$codexRsDir = Join-Path $sourceDir "codex-rs"
$cliCargoTomlPath = Join-Path $codexRsDir "cli/Cargo.toml"
$addedVendoredOpenSsl = Enable-I686MuslVendoredOpenSsl -CargoTomlPath $cliCargoTomlPath
$disabledV8CodeMode = Disable-I686MuslV8CodeMode -CodexRsDir $codexRsDir
$patchedLinuxSandboxSyscalls = Enable-I686MuslLinuxSandboxSyscallBuild -CodexRsDir $codexRsDir
Set-I686MuslBuildEnvironment

Push-Location $codexRsDir
try {
    & rustup show active-toolchain
    if ($LASTEXITCODE -ne 0) {
        throw "rustup show active-toolchain failed with exit code $LASTEXITCODE"
    }

    & rustup target add $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target add $LinuxTarget failed with exit code $LASTEXITCODE"
    }

    $installedTargets = @(& rustup target list --installed)
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target list --installed failed with exit code $LASTEXITCODE"
    }
    if ($installedTargets -notcontains $LinuxTarget) {
        throw "Rust target $LinuxTarget is not installed after rustup target add."
    }

    & rustc --print target-libdir --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "rustc could not resolve target libdir for $LinuxTarget."
    }

    cargo zigbuild --release --package codex-cli --bin codex --target $LinuxTarget
    if ($LASTEXITCODE -ne 0) {
        throw "cargo zigbuild failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$targetDir = Join-Path $sourceDir "codex-rs/target/$LinuxTarget/release"
$codexPath = Join-Path $targetDir "codex"
if (-not (Test-Path -LiteralPath $codexPath -PathType Leaf)) {
    throw "Build output not found: $codexPath"
}

& chmod 0755 $codexPath
if ($LASTEXITCODE -ne 0) {
    throw "chmod failed for built codex binary."
}

$fileOutput = ""
if (Get-Command file -ErrorAction SilentlyContinue) {
    $fileOutput = [string](& file $codexPath)
    Write-Host $fileOutput
}

$versionOutput = [string](& $codexPath --version)
if ($LASTEXITCODE -ne 0) {
    throw "Built i686 codex --version failed with exit code $LASTEXITCODE"
}
Write-Host "Built $versionOutput"

$payloadRoot = Join-Path $releaseWorkspace $payloadName
$certsDir = Join-Path $payloadRoot "certs"
if (Test-Path -LiteralPath $releaseWorkspace) {
    Remove-Item -Recurse -Force -LiteralPath $releaseWorkspace
}
if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -Force -LiteralPath $manifestPath
}
New-Item -ItemType Directory -Force -Path $certsDir | Out-Null

$caCertPath = Get-CaCertificatesBundle
Copy-RequiredFile -Source $codexPath -Destination (Join-Path $payloadRoot "codex")
Copy-RequiredFile -Source $caCertPath -Destination (Join-Path $certsDir "ca-certificates.crt")
& chmod 0755 (Join-Path $payloadRoot "codex")
if ($LASTEXITCODE -ne 0) {
    throw "chmod failed for packaged codex binary."
}

Set-Content -Path (Join-Path $payloadRoot "VERSION.txt") -Value ($versionOutput + "`n") -Encoding utf8
Set-Content -Path (Join-Path $payloadRoot "README.TINYCORE.txt") -Value @"
Codex Linux i686 musl package

Files:
- codex
- certs/ca-certificates.crt

Compatibility note:
  This i686 musl build does not include JavaScript code mode because rusty_v8
  does not publish a prebuilt V8 archive for i686-unknown-linux-musl.

Tiny Core example:
  install -m 755 codex /home/tc/codex
  mkdir -p /home/tc/certs /usr/local/etc/ssl/certs
  install -m 644 certs/ca-certificates.crt /home/tc/certs/ca-certificates.crt
  cp /home/tc/certs/ca-certificates.crt /usr/local/etc/ssl/cacert.pem
  cp /home/tc/certs/ca-certificates.crt /usr/local/etc/ssl/certs/ca-certificates.crt
"@ -Encoding utf8

Invoke-TarGzip -WorkingDirectory $releaseWorkspace -ArchivePath $bundlePath -EntryName $payloadName

$bundleSha256 = Get-FileSha256 -Path $bundlePath
$codexSha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "codex")
$caCertSha256 = Get-FileSha256 -Path (Join-Path $certsDir "ca-certificates.crt")
$manifest = [ordered]@{
    upstream_repo              = $UpstreamRepo
    upstream_ref               = $UpstreamRef
    upstream_sha               = $upstreamSha
    linux_target               = $LinuxTarget
    generated_at_utc           = $generatedAt
    release_tag                = $releaseTag
    rolling_tag                = $rollingTag
    custom_runtime_patches     = "not_applied"
    compatibility_patches      = @(
        [ordered]@{
            name   = "disable_v8_code_mode_for_i686_musl"
            applied = [bool]$disabledV8CodeMode
            reason = "rusty_v8 v147.4.0 does not publish librusty_v8_release_i686-unknown-linux-musl.a.gz"
            effect = "JavaScript code mode returns an unavailable error on this i686 musl package; standard Codex CLI behavior remains built from upstream source."
        },
        [ordered]@{
            name   = "i686_musl_linux_sandbox_syscall_compile_fix"
            applied = [bool]$patchedLinuxSandboxSyscalls
            reason = "libc syscall constants are i32 on i686 musl and libc does not expose SYS_accept for this target."
            effect = "Linux sandbox syscall table code compiles for the i686 musl release target."
        }
    )
    build_adjustments          = [ordered]@{
        vendored_openssl_for_i686_musl = [bool]$addedVendoredOpenSsl
        v8_code_mode_disabled_for_i686_musl = [bool]$disabledV8CodeMode
        linux_sandbox_syscalls_patched_for_i686_musl = [bool]$patchedLinuxSandboxSyscalls
        openssl_no_c11_atomics_for_i686_musl = $true
        cargo_build_jobs              = $env:CARGO_BUILD_JOBS
        ca_certificates_bundle_source  = $caCertPath
        cargo_command                  = "cargo zigbuild --release --package codex-cli --bin codex --target $LinuxTarget"
    }
    verification              = [ordered]@{
        version_output = $versionOutput
        file_output    = $fileOutput
    }
    artifact                  = [ordered]@{
        name   = [System.IO.Path]::GetFileName($bundlePath)
        sha256 = $bundleSha256
    }
    packaged_files            = @(
        [ordered]@{ path = "codex"; sha256 = $codexSha256 },
        [ordered]@{ path = "certs/ca-certificates.crt"; sha256 = $caCertSha256 },
        [ordered]@{ path = "VERSION.txt"; sha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "VERSION.txt") },
        [ordered]@{ path = "README.TINYCORE.txt"; sha256 = Get-FileSha256 -Path (Join-Path $payloadRoot "README.TINYCORE.txt") }
    )
    release_files             = @(
        [ordered]@{ name = [System.IO.Path]::GetFileName($bundlePath); sha256 = $bundleSha256 },
        [ordered]@{ name = [System.IO.Path]::GetFileName($manifestPath); sha256 = $null }
    )
}

Save-JsonFile -Path $manifestPath -Value $manifest
Save-JsonFile -Path $latestStatePath -Value $manifest
Set-Content -Path $latestShaPath -Value ($upstreamSha + "`n") -Encoding utf8

Write-ActionOutput -Name "changed" -Value "true"
Write-ActionOutput -Name "bundle_path" -Value $bundlePath
Write-ActionOutput -Name "manifest_path" -Value $manifestPath
Write-ActionOutput -Name "version_output" -Value $versionOutput

Write-Host "Linux i686 musl bundle created at $bundlePath"
