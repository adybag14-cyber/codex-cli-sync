---
name: harnessmm-cue
description: Use the native HarnessMM tool for already-decided terminal validation sequences. Apply when the user says "use the HarnessMM cue skill", names HarnessMM, or requests guarded reuse of known commands. It does not apply to explanations or steps that still need diagnosis or new decisions.
---

# HarnessMM Cue

Use this skill within the user's current task. If no task is established, ask
what they want done; do not create demonstration commands just to exercise reuse.

## Check the current session

The advertised top-level `harnessmm_plan` tool is the authority. Call it directly
and alone. It is not a nested `functions.exec` tool: do not call
`tools.harnessmm_plan`, search `ALL_TOOLS` for it, install a substitute, or emulate it.

If the tool is absent, explain that this session cannot use native HarnessMM and
continue the task with the available tools. A skill cannot add the feature to
an already-running older CLI. Do not alter global configuration or launch another
agent merely because this skill was requested.

## Choose a useful sequence

Use HarnessMM when 2–8 successive terminal commands are already fully decided
and the only condition for a later command is successful completion of its
predecessor. Known validation commands after an edit are a good fit.

Before registration, know the exact commands, working directories, necessary
environment settings and expected exit behavior from the repository's actual
instructions. Keep every argument literal. Each command runs through ordinary
`exec_command`; shell variables and directory changes do not carry into the next
command. Use the currently advertised tool schema instead of guessing fields.

Keep diagnosis, output-dependent edits, selecting unknown paths, interactive
input, and arguments that depend on a future session ID in normal reasoning.
Use normal code-mode batching for independent work when that is already suitable.
Do not add work, skip required checks, or serialize independent work solely to
produce a HarnessMM graph.

On PowerShell, make a native validation command's exit status visible to the
harness, for example by ending that command with `exit $LASTEXITCODE`. Do not
mask an earlier failure with a later successful command in the same invocation.

## Register and resume correctly

Submit the resolved sequence through top-level `harnessmm_plan`, then let the
native harness execute it. Do not issue competing tool calls while registering
the plan. The controller checks actual exit status and context at each boundary.

An error, blocked or rewritten action, running background process, new user
input, changed context, or exhausted graph returns control to the model. Read
the real receipts, diagnose what remains, and continue or author a new suitable
sequence. Never blindly replay the whole graph after partial execution.

Complete the user's task and report the checks that actually ran and their
outcomes. A registered plan is not proof of execution or task success. Claim
token or latency savings only when those quantities were actually measured.
