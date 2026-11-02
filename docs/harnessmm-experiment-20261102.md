# Native HarnessMM: real Actions-repair comparison

The native mechanism worked on the real repair task when the actor was explicitly
cued to use it. In that guided pair, total reported actor tokens fell **54.79%**,
model requests fell from **17 to 10**, and both solutions passed the independent
checks. Enabling the feature alone did **not** produce automatic uptake: the
unprompted candidate never registered a graph. The feature therefore remains
opt-in, and this report preserves both outcomes.

This is a test of this repository's native, bounded terminal implementation,
inspired by [HarnessMM](https://arxiv.org/abs/2610.32813) and the
[authors' implementation](https://github.com/YuhuaJiang2002/HarnessMM/tree/c8f19947e59feaa8103c05155bd79ef3eb084730).
It does not reproduce the paper's additional context-management or offline RSI
configurations.

## Frozen setup

- Task: repair the failure addressed by [PR #21](https://github.com/adybag14-cyber/codex-cli-sync/pull/21).
- Repository input: an export of `2dc5bb138748bb9aac80e30dd0c773b2399f2a03`, before the fix.
- Upstream fixture and CLI source: `67f0994b532b8740f14b5b738af7b7b2a915b1d6`.
- Actual reproduced failure: `Unsupported upstream source: interactive local launch`.
- Both Windows executables advertise `0.167.0-202611021654`, use the same release
  profile and existing custom patches, and differ by inclusion of the native
  HarnessMM overlay. The candidate runs with `features.harnessmm=true`.
- Both actors use `gpt-6-astra`, reasoning effort `max`, the same context limits,
  native tools and permission settings. Runs are sequential on the same workstation.
- Each actor receives a fresh source export, a single-commit local repository
  without a remote or future history, an isolated Codex home, and no personal
  memories or earlier trial transcript. Only the existing access grant is
  supplied temporarily; the account's refresh token remains in its original store.
- One attempt per arm per condition, with a 45-minute bound. No corrective
  feedback or reference solution is supplied to either actor.

The repository trees and upstream trees are byte-identical within and across the
two conditions. Each pair also receives identical prompt and failure-log content.
The guided condition has a separately reproduced failure log and a shared
[usage cue](../analysis/harnessmm/guided-cue.txt). It is a diagnostic second
condition, not an independent replication to pool with the first.

## Results

| Condition | Metric | Control | HarnessMM candidate |
| --- | --- | ---: | ---: |
| Unprompted | Total input + output tokens | 838,683 | 818,888 |
| Unprompted | Model requests | 15 | 15 |
| Unprompted | Elapsed seconds | 451.010 | 379.915 |
| Unprompted | Authored graphs / native dispatches | 0 / 0 | 0 / 0 |
| Guided, same cue in both arms | Total input + output tokens | 1,013,674 | 458,302 |
| Guided, same cue in both arms | Model requests | 17 | 10 |
| Guided, same cue in both arms | Elapsed seconds | 454.076 | 356.596 |
| Guided, same cue in both arms | Authored graphs / native dispatches | 0 / 0 | 1 / 4 |

The unprompted token difference is **2.36%** and elapsed-time difference is
**15.76%**. Because neither actor invoked the mechanism and both made 15 model
requests, these differences do not demonstrate a decision-reuse benefit.

In the guided pair the observed reductions are **54.79%** for total tokens,
**41.18%** for model requests, and **21.47%** for elapsed time. These are complete
task measurements, including graph authorship, failed tool attempts and recovery.

| Guided token accounting | Control | HarnessMM candidate |
| --- | ---: | ---: |
| Input tokens, including cached input | 997,717 | 445,727 |
| Cached input subset | 927,488 | 387,200 |
| Uncached input | 70,229 | 58,527 |
| Output tokens, including reasoning | 15,957 | 12,575 |
| Reasoning-output subset | 8,309 | 5,665 |

Most of the total-token reduction is avoided replay of cached input. Uncached
input falls **16.66%** and output falls **21.19%**. A 54.79% reduction in reported
tokens is not a measured 54.79% reduction in billing or subscription allowance.
Cached input and reasoning output are subsets, not additional tokens to add again.

Every model attempt in these four task runs completed with a usage record.
Summed request-hook usage exactly matches the CLI's final usage in each run.
Elapsed time includes the identical request-logging instrumentation and CLI
startup; builds, qualification, preflights and independent judging are separate.

## Quality and trace findings

All four solutions fix the original source-patching failure, apply the full
Windows patch, and replay without changing bytes. Their generated upstream
source is byte-identical to the known repair's generated source. The comparison
does not rebuild a separate complete CLI for each agent's resulting patcher;
the failure being repaired occurs in source transformation before compilation.

The unprompted solutions each miss four withheld subcases: misplaced and duplicate
reserved patch markers in the legacy and current launch layouts. Their own
regressions and the mainline patch/replay pass, but the stricter robustness screen
fails. The guided solutions both pass all 11 withheld test methods, their own
regressions, the 185 compatibility checks, full patch application, replay and
whitespace checks. The same independent evaluator was used throughout. Before
the trials it rejected the broken input and accepted the known repair.

Both unprompted actors use 14 code-mode `exec` calls. Those calls already batch
multiple native operations: the control makes 23 terminal invocations and four
patch batches; the candidate makes 31 terminal invocations and three patch
batches. Advertising a second execution path did not make this model choose it.

With the shared cue, the candidate authors one four-command plan for:

1. Daemon-patch regression tests.
2. Guardian compatibility regression tests.
3. The 185 upstream compatibility checks.
4. Six complete-source transaction scenarios.

The four native calls run from **21:14:53.007 UTC to the final receipt at
21:15:03.052 UTC**. Every dispatched argument object matches the actor's original
plan. There is **no model request between the first dispatch and final receipt**;
the next request starts at 21:15:03.438 UTC. This verifies actual callback
substitution, including three continuations after the initial dispatch.
The tool-only correlation is retained in [trace-proof-guided.json](../analysis/harnessmm/trace-proof-guided.json).

The full guided improvement must not be attributed entirely to those four local
substitutions. The candidate also uses one patch batch instead of three and
19 terminal invocations instead of 28. The actors took different read/edit/repair
paths before the graph ran. Four omitted local boundaries are not a measurement
of seven counterfactual model responses or a fixed token saving per action.

## Build and runtime qualification

| Arm | Workflow source | Build evidence | Executable SHA-256 |
| --- | --- | --- | --- |
| Control | `8a659b73acf73f0aeb93bbb25d487309e9f53b3a` | [successful control job](https://github.com/adybag14-cyber/codex-cli-sync/actions/runs/41485953749/job/125416297140) | `b0a0eb2a0beb3a1bb916e4264d7f1430868e8498a4864563f9e44975f5faac2c` |
| HarnessMM | `db37069d8c7d9d8028d7183b0a6b7ba262ca860e` | [successful candidate job](https://github.com/adybag14-cyber/codex-cli-sync/actions/runs/41492965511/job/125441011196) | `04a10fd0268bfc1da1ce37b78f2c6b34d2f58e30c1984ea9b378993e2952683a` |

The control was retained from the first matrix after its job passed. That matrix's
initial treatment failed compilation because a native output call ID is optional;
the corrected treatment was built separately. The 38 common source/build inputs
are byte-identical, the upstream SHA and version timestamp are fixed, and no
qualified executable was rebuilt or relabelled to repair orchestration.

GitHub Actions archive digests, inner ZIP digests, package layout, advertised
version and executable-bound reports were verified locally. Each package passes
30 packaged runtime checks and 14 daemon-free checks. The candidate also passes
three native Rust policy tests and nine actual-CLI/mock-provider cases: success,
feature disabled, nonzero exit, spoofed stdout, input rewrite, pre-tool block,
post-tool block, changed context and complete request metering. A live
`gpt-6-astra` preflight executes an authored two-command graph successfully.

An initial blocking fixture lost Python's exit code 2 through PowerShell, which
converted it to 1. Explicit exit forwarding fixed the fixture. The successful
suite uses the same candidate executable; this was not a product-code change.

## Use and interpretation

The implementation is deliberately opt-in. On an included build, enable
`features.harnessmm=true` and supply the tested usage cue when appropriate. The
cue requires only already-resolved commands, forbids inventing extra work to
create a chain, and lets the control use normal programmatic batching.

This experiment supports a promising guided use case, not an automatic or
universal efficiency guarantee. One pair per condition cannot separate all
sampling, caching and trajectory effects. Reliable unprompted uptake and a
broader repeated task suite remain prerequisites for considering default enablement.

Machine-readable results: [unprompted](../analysis/harnessmm/results-unprompted.json),
[guided](../analysis/harnessmm/results-guided.json). Reproduction, artifact
verification, isolated execution, judging and trace-analysis scripts are in
[`analysis/harnessmm`](../analysis/harnessmm). Raw local traces are retained in the
experiment workspace; credentials and private prompt/reasoning records are not
published in this repository.
