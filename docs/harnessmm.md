# Native HarnessMM experiment

Predictable terminal transitions repeatedly resend context and invoke the model
even when their exact commands are already known. The opt-in `harnessmm` feature
lets the actor register 2–8 literal commands through `harnessmm_plan`. Codex
executes one command at each ordinary sampling boundary, retaining the original
provider, authentication, native tool dispatcher, hooks and cancellation path.
The feature defaults off. Enable an included build with `-c features.harnessmm=true`.

This implementation takes inspiration from [HarnessMM](https://github.com/YuhuaJiang2002/HarnessMM)
at `c8f19947e59feaa8103c05155bd79ef3eb084730` and
[arXiv:2610.32813](https://arxiv.org/abs/2610.32813). It is a new Rust integration,
not a reproduction of every research configuration or its reported savings.
It uses a bounded linear decision graph with a deterministic selector; no extra
model, Python/Node service, provider proxy, context pruning or offline RSI is added.

## Execution contract

- The author supplies exact ordinary `exec_command` arguments. No result-dependent
  substitution, inferred paths, interactive input, permission escalation, or
  arbitrary graph/guard code is accepted by the plan schema.
- The first action requires the accepted plan receipt and unchanged context.
  Each successor requires the host's typed `exit_code = 0` with no active session.
  Strings in stdout cannot satisfy the guard. A failed, blocked, rewritten,
  cancelled or background command returns control to the normal actor.
- Every substitution re-enters the ordinary turn loop. Context changes, including
  steering and compaction, invalidate the graph. State is turn-local and is not
  restored on cold resume. It never implicitly crosses tasks.
- Every action passes through the native dispatcher. Post-tool hook acceptance
  precedes receipt admission; argument rewrites invalidate future reuse.
- The rollout contains the original plan, each literal native call with an
  explicit `harnessmm_<graph>_<node>` ID, and its actual output. Runtime logs mark
  the substituted sampling boundaries. These are local calls, not fake provider
  responses. Certificates of execution do not certify task correctness.
- History fingerprints use the already-linked SHA-1 only as internal change
  detectors. They grant no authority and are not authenticity certificates.

The conservative first scope is terminal commands. MCP, browser, arbitrary tool
graphs and dynamic output bindings are deliberately unsupported. Code-mode
clients can see the plan as a direct model-only tool; nested registration rejects.
Existing independent-command batching remains available in both arms.

## A/B experiment

`.github/workflows/harnessmm-ab.yml` builds the same pinned upstream source with
all existing custom patches twice: the baseline omits the overlay and the
candidate includes it. One timestamp freezes the advertised version. The jobs
have read-only repository permission, upload artifacts and never publish or
change release state. The manifest records the included variant and recipe hash.

The intended real task is the failure repaired in PR #21. Both agents receive an
export of parent `2dc5bb138748bb9aac80e30dd0c773b2399f2a03`, the failing upstream
`67f0994b532b8740f14b5b738af7b7b2a915b1d6`, and the same failure evidence and prompt.
The repaired commit and repository history are not available in their workspaces.
Fresh isolated Codex homes exclude personal memories and prior task transcripts.
The same model, reasoning effort, tools and budget apply, with candidate feature
activation the intentional difference. Runs are serialized on the same machine.

Report correctness separately from complete input/output/cached tokens, model
requests, elapsed time, tool calls, substitutions, fallbacks, and retries. Include
authorship overhead and unsuccessful work. Count physical requests: a local
substitution is not automatically a net saved request, because the authoring call
also costs tokens. A single pair is a case study, not statistical proof.

## Validation status

Patch transaction/replay/refusal contracts pass locally against the pinned source.
Native compilation, mock-provider integration, the two built artifacts and real
agent trials are pending. The PR must be updated with their actual terminal results.
