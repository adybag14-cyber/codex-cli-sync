# Windows upstream compatibility audit

Reviewed against upstream `b741e480e203f037ca726bc2a76d99a8e8668e66` on
2026-10-03. This is a bounded engineering audit, not a claim that arbitrary future
upstream redesigns can be predicted or safely rewritten automatically.

| Contract boundary | Supported changes | Changes requiring review / publication gate |
| --- | --- | --- |
| Version discovery | Numeric stable-tag sorting; patch releases; explicit alpha/RC refs; meaningful workspace versions; major version supplied upstream; historical development tags; UTC rollover | Missing/malformed/conflicting source versions, absent stable tags, failed Git query and overflow stop discovery. A placeholder workspace infers the next minor; it cannot predict an unannounced major release. |
| Build identity and state | Source SHA, version base, Windows target and content fingerprint of scripts, workflow and companion determine whether a successful build is reusable | Missing/old/corrupt state, changed recipe or version baseline require a rebuild. Failed patches cannot advance successful state. A timestamp alone does not force repeated builds. |
| Complete source transformation | All touched files and discovery manifests are staged; all patch and daemon checks complete before source writes; changed source snapshots are rejected | Missing/unknown anchors and ambiguous configuration constructors stop the transaction. Ordinary commit write errors attempt rollback. This is not a filesystem-wide atomic transaction and does not promise recovery from process termination or power loss during commit. |
| Permission construction | Named/shorthand fields and the reviewed current Permissions constructor; the historical flat layout | Multiple constructors now require review. New field types, expressions or constructors moved into other modules require source review and fresh runtime checks; the existing text scanner is not a full Rust parser. |
| Windows sandbox entry points | Reviewed config/features/mode/setup signatures; legacy/current startup NUX; removed onboarding hint | Required signature changes fail staging. Newly introduced sandbox entry paths require review even if old functions remain. Fresh thread/start responses must still report never/dangerFullAccess. |
| Tool permission authority | Legacy async Session layouts and sync StepContext/TurnEnvironment/PathUri evaluator | Unknown signatures, duplicate evaluators and misplaced bypass markers fail. All non-Windows evaluator bodies remain present. New callers or alternative authority paths require semantic review. |
| Exec policy | Legacy production evaluator and shared parsed-command evaluator; test-only wrapper cannot satisfy contract | Unknown evaluator shape fails. A new production route retaining an unused old evaluator requires call-path review. Current command/platform and executable-identity routes were inspected in upstream source. |
| Daemon lifecycle and attachment | Reviewed local interactive/resume/fork gateway, TUI startup and implicit socket discovery; lifecycle guards; known public re-exports | New public functions, duplicate/indented entry points, new public modules or re-exports fail. First-operation guards must precede side effects. Fresh default TUI and historical command rejection gates remain mandatory. New CLI routes or private call paths require review. |
| OAuth callback | Registered ports 1455/1457, flexible constant/bind anchors, PermissionDenied fallback | Missing/duplicate anchors or unregistered ports fail. OAuth provider policy changes need a separate authenticated login investigation; source and offline checks cannot prove provider acceptance. |
| OpenAI metadata | Keep internal classifications while removing only unsupported content_item_kinds from OpenAI requests; preserve turn_id/create_time | Required method/call/assertion drift fails. The exact upstream request test must exist, execute and pass. A future provider schema rollout or removal of this field requires an intentional contract update, not broad metadata deletion. |
| Debug and protocol | Discover existing debug variants; generate/parse emitted schemas; register canonical, legacy, namespaced, deferred and nullable tools; reject invalid definitions | Changed enum or protocol shapes fail fresh runtime gates. Registration and selected upstream dynamic-tool tests do not prove compatibility of every future tool schema or RPC method. |
| Required Cargo regressions | Exact request-metadata test and dynamic-tool test prefix are enumerated before execution | Zero selected tests, mismatched exact selection, ignored tests, missing/changed result summaries or failure stop the build. Test selection evidence is bundled in the package. |
| Rust recursion limits | Raise lower limits to 256 and preserve higher upstream limits | Missing or duplicate limits fail verification. Real Windows compilation remains required; a recursion limit does not guarantee compatibility with future Rust language/compiler changes. |
| V8 build artifacts | Locked version and target-specific archive/bindings; additional checksum entries are accepted | Required hashes must exist exactly once; malformed/duplicate entries and digest mismatches fail. Multiple locked V8 versions, changed graph/profile/asset naming, removed dependencies or unavailable assets still need review. |
| Package and executable identity | Use upstream builder; require reviewed layout/version/target/variant/paths; verify all five packaged input hashes | A changed package layout or changed/missing executable fails before publication. Installer script, .NET companion, host help, protocol and daemon-free packaged runtime checks remain release gates. New architectures or package-layout versions require coordinated support. |
| Release and cache reuse | Exact upstream source checkout; cached build outputs are rebuilt; artifacts and manifests are digested; successful state is committed after validation | Changed download/publishing APIs, dependency availability, runner images and toolchains are operational failures requiring investigation. Source contract success is not a published binary or live authenticated-service result. |

The four-hour live-main check provides early drift detection. The historical,
first-failing and reviewed-current source checks preserve reproducible coverage.
Each now injects a late daemon-export change and a duplicate permission
constructor and verifies that rejection leaves every source input unchanged.
Each also applies the entire patch with upstream recursion limits of 512.

## October 7 operational failures and current-source check

The full patch and transaction/package contracts also pass against
`5b0b2530354052b9194156d70d4c94a439368342`, now retained in the source matrix.
The existing permission, daemon, OAuth, metadata and package requirements remain
the release contract.

- [Run 37579292313](https://github.com/adybag14-cyber/codex-cli-sync/actions/runs/37579292313)
  patched and compiled upstream `5a3140176e668a2f72f3c098490eb7f7052d9d85`,
  then hit an unauthenticated GitHub API rate limit while resolving ripgrep.
  Dependency acquisition now happens before Cargo, uses the workflow token for
  the API request, and verifies the selected ZIP's digest before caching or use.
- [Run 37510874867](https://github.com/adybag14-cyber/codex-cli-sync/actions/runs/37510874867)
  passed 29 packaged runtime checks, then failed removing a temporary Git pack
  file held by an unrelated plugin clone in the isolated TUI fixture. The fixture
  disables plugin discovery, requests graceful exit, waits for its exact owned
  terminal, and retries transient cleanup locks. A real Windows sharing-violation
  regression verifies eventual cleanup; permanent errors remain failures and
  retain a diagnostic report.
- [Run 37548627700](https://github.com/adybag14-cyber/codex-cli-sync/actions/runs/37548627700)
  encountered an upstream test using the old one-argument
  `TurnEnvironmentSelection::new` at `19c4793964f3d70a9c916010376f96f636847a95`.
  The reviewed October 7 source passes the new second argument explicitly.
  The native Cargo gate remains mandatory; source-anchor checks alone cannot
  detect upstream test compilation failures.

Fast coverage is in `test-windows-ripgrep.ps1` and
`test-no-daemon-runtime-contracts.py`. Hosted publication still requires a
fresh native release build and both packaged runtime probes.

The supported response to an unfamiliar structural or semantic change is to
stop publication, inspect the exact upstream change, update the transformation
and its regression coverage, and pass a fresh native Windows build and runtime
gates. No finite set of source patterns or offline tests can guarantee every
possible future behavior. In particular, preserving old anchors does not prove
that upstream still routes every relevant operation through them; semantic
call-path changes remain a review boundary.
