//! Opt-in, turn-scoped reuse of literal terminal decisions at the sampling boundary.
//!
//! Native dispatch owns permissions, hooks, cancellation and receipts. No provider
//! response is fabricated and no model usage is attributed to the local path.
use crate::context_manager::ContextManager;
use crate::function_tool::FunctionCallError;
use crate::session::session::Session;
use crate::session::step_context::StepContext;
use crate::tools::context::{FunctionToolOutput, ToolInvocation, ToolOutput, ToolPayload};
use crate::tools::parallel::ToolCallRuntime;
use crate::tools::registry::{CoreToolRuntime, ToolExecutor};
use crate::tools::router::ToolCall;
use codex_features::Feature;
use codex_protocol::config_types::ModeKind;
use codex_protocol::error::Result as CodexResult;
use codex_protocol::models::ResponseItem;
use codex_tools::{JsonSchema, ResponsesApiTool, ToolName, ToolSpec};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;

const TOOL: &str = "harnessmm_plan";
const MAX_NODES: usize = 8;
const MAX_BYTES: usize = 65536;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Command {
    cmd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    workdir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    shell: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    login: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    environment_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    yield_time_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    max_output_tokens: Option<usize>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    commands: Vec<Command>,
}

fn parse_plan(raw: &str) -> Result<Plan, FunctionCallError> {
    let reject = |message: &str| FunctionCallError::RespondToModel(message.to_owned());
    if raw.len() > MAX_BYTES {
        return Err(reject("HarnessMM plan exceeds 64 KiB; use ordinary tools."));
    }
    let plan: Plan =
        serde_json::from_str(raw).map_err(|e| reject(&format!("Invalid HarnessMM plan: {e}")))?;
    if !(2..=MAX_NODES).contains(&plan.commands.len()) {
        return Err(reject(
            "HarnessMM requires 2 to 8 already-resolved commands.",
        ));
    }
    if plan.commands.iter().any(|command| {
        command.cmd.trim().is_empty()
            || command.cmd.contains('\0')
            || command.yield_time_ms.is_some_and(|n| n > 30000)
            || command.max_output_tokens.is_some_and(|n| n > 10000)
    }) {
        return Err(reject(
            "Invalid command or excessive HarnessMM output/wait budget.",
        ));
    }
    Ok(plan)
}

// This is only a change detector, never a permission or authenticity check.
// Exact authored arguments and host-owned typed receipts determine admission.
fn history_key(history: &ContextManager) -> String {
    let mut digest = Sha1::new();
    for item in history.raw_items() {
        digest.update(serde_json::to_vec(item).expect("ResponseItem serialization"));
        digest.update([0]);
    }
    format!("{:x}", digest.finalize())
}

#[derive(Clone)]
enum Checkpoint {
    Author {
        call_id: String,
        items_before_ack: usize,
        prefix: String,
    },
    Receipt(String),
}

struct Bank {
    id: String,
    commands: Vec<Command>,
    next: usize,
    checkpoint: Checkpoint,
}

struct Pending {
    call_id: String,
    arguments: String,
    receipt: Option<Value>,
}

#[derive(Default)]
struct Inner {
    bank: Option<Bank>,
    pending: Option<Pending>,
}

#[derive(Default)]
struct State(Mutex<Inner>);

fn checkpoint_matches(checkpoint: &Checkpoint, history: &ContextManager) -> bool {
    match checkpoint {
        Checkpoint::Receipt(expected) => history_key(history) == *expected,
        Checkpoint::Author {
            call_id,
            items_before_ack,
            prefix,
        } => {
            if history.raw_items().len() != items_before_ack + 1 {
                return false;
            }
            if !matches!(history.raw_items().last(),
                Some(ResponseItem::FunctionCallOutput { call_id: actual, output, .. })
                    if actual.as_deref() == Some(call_id.as_str()) && output.success == Some(true))
            {
                return false;
            }
            let mut digest = Sha1::new();
            for item in history.raw_items().take(*items_before_ack) {
                digest.update(serde_json::to_vec(item).expect("ResponseItem serialization"));
                digest.update([0]);
            }
            format!("{:x}", digest.finalize()) == *prefix
        }
    }
}

fn admitted_receipt(receipt: &Value) -> bool {
    receipt.get("exit_code").and_then(Value::as_i64) == Some(0)
        && receipt.get("session_id").is_none_or(Value::is_null)
}

/// Called only after the native registry accepts every PostToolUse hook.
pub(crate) fn observe(invocation: &ToolInvocation, output: &dyn ToolOutput) {
    let Some(state) = invocation.turn.extension_data.get::<State>() else {
        return;
    };
    let Ok(mut inner) = state.0.lock() else {
        return;
    };
    let Some(pending) = inner.pending.as_mut() else {
        return;
    };
    if pending.call_id != invocation.call_id {
        return;
    }
    // Rewritten input invalidates the graph, even if the rewritten command exits 0.
    if !invocation.tool_name.is_default_namespace()
        || invocation.tool_name.name != "exec_command"
        || invocation.payload
            != (ToolPayload::Function {
                arguments: pending.arguments.clone(),
            })
    {
        inner.pending = None;
        return;
    }
    pending.receipt = Some(output.code_mode_result(&invocation.payload));
}

/// Substitute exactly one registered sampling boundary, then re-enter the normal
/// turn loop so steering, compaction, budgets and cancellation are checked again.
pub(crate) async fn try_reuse(
    session: &Arc<Session>,
    step: &Arc<StepContext>,
    runtime: &ToolCallRuntime,
    history: &ContextManager,
    cancellation: &CancellationToken,
) -> CodexResult<bool> {
    if !step.turn.config.features.enabled(Feature::HarnessMm) {
        return Ok(false);
    }
    let Some(state) = step.turn.extension_data.get::<State>() else {
        return Ok(false);
    };
    let bank = {
        let Ok(mut inner) = state.0.lock() else {
            return Ok(false);
        };
        inner.bank.take()
    };
    let Some(mut bank) = bank else {
        return Ok(false);
    };
    if cancellation.is_cancelled()
        || step
            .preempt
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
        || step.turn.mode() == ModeKind::Plan
        || !step
            .tool_router
            .exposes_tool(&ToolName::plain("exec_command"))
        || !checkpoint_matches(&bank.checkpoint, history)
    {
        tracing::info!(target: "codex_core::harnessmm", graph_id = %bank.id,
            node = bank.next, outcome = "fallback", "HarnessMM state changed");
        return Ok(false);
    }
    let arguments =
        serde_json::to_string(&bank.commands[bank.next]).expect("literal command serialization");
    let call_id = format!("harnessmm_{}_{}", bank.id, bank.next);
    {
        let Ok(mut inner) = state.0.lock() else {
            return Ok(false);
        };
        inner.pending = Some(Pending {
            call_id: call_id.clone(),
            arguments: arguments.clone(),
            receipt: None,
        });
    }
    let item = ResponseItem::FunctionCall {
        id: None,
        name: "exec_command".into(),
        namespace: None,
        arguments: arguments.clone(),
        call_id: call_id.clone(),
        encrypted_content: None,
        encrypted_function_args: None,
        status: None,
        internal_chat_message_metadata_passthrough: None,
    };
    // Explicit compiled call IDs preserve provenance; these are local decisions,
    // not fabricated provider responses or generated reasoning.
    session
        .record_conversation_items(
            &step.turn,
            &step.settings.model_info,
            std::slice::from_ref(&item),
        )
        .await;
    let response = runtime
        .clone()
        .handle_tool_call(
            ToolCall {
                tool_name: ToolName::plain("exec_command"),
                call_id: call_id.clone(),
                payload: ToolPayload::Function { arguments },
                encrypted_function_args: None,
                native_call: Some(Arc::new(item)),
            },
            cancellation.child_token(),
        )
        .await?;
    session
        .record_annotated_conversation_items(&step.turn, &step.settings.model_info, vec![response])
        .await;
    let next_history = session.clone_history().await;
    let Ok(mut inner) = state.0.lock() else {
        return Ok(true);
    };
    let receipt = inner
        .pending
        .take()
        .filter(|pending| pending.call_id == call_id)
        .and_then(|pending| pending.receipt);
    // Concurrent context additions must not be absorbed into a new checkpoint.
    let mut prefix = Sha1::new();
    for item in next_history.raw_items().take(history.raw_items().len()) {
        prefix.update(serde_json::to_vec(item).expect("ResponseItem serialization"));
        prefix.update([0]);
    }
    let unchanged = next_history.raw_items().len() == history.raw_items().len() + 2
        && format!("{:x}", prefix.finalize()) == history_key(history);
    let continue_graph = unchanged && receipt.as_ref().is_some_and(admitted_receipt);
    tracing::info!(target: "codex_core::harnessmm", graph_id = %bank.id,
        node = bank.next, %call_id, continue_graph, bypassed_sampling_boundary = true,
        "HarnessMM native receipt");
    bank.next += 1;
    if continue_graph && bank.next < bank.commands.len() && !cancellation.is_cancelled() {
        bank.checkpoint = Checkpoint::Receipt(history_key(&next_history));
        inner.bank = Some(bank);
    }
    Ok(true)
}

pub(crate) struct HarnessMmHandler;

impl ToolExecutor<ToolInvocation> for HarnessMmHandler {
    fn tool_name(&self) -> ToolName {
        ToolName::plain(TOOL)
    }

    fn spec(&self) -> ToolSpec {
        let mut command = BTreeMap::new();
        command.insert(
            "cmd".into(),
            JsonSchema::string(Some("Exact shell command, already decided.".into())),
        );
        for name in ["workdir", "shell", "environment_id"] {
            command.insert(name.into(), JsonSchema::string(None));
        }
        command.insert("login".into(), JsonSchema::boolean(None));
        command.insert(
            "yield_time_ms".into(),
            JsonSchema::integer(Some(
                "At most 30000. Background results return to reasoning.".into(),
            )),
        );
        command.insert(
            "max_output_tokens".into(),
            JsonSchema::integer(Some("At most 10000 per command.".into())),
        );
        let commands = JsonSchema::array(
            JsonSchema::object(command, Some(vec!["cmd".into()]), Some(false.into())),
            None,
        );
        ToolSpec::Function(ResponsesApiTool {
            name: TOOL.into(),
            description: "Register 2-8 exact sequential terminal commands you have already resolved. Use for predictable validation or execution sequences. The harness executes each through native exec_command without another model call; later commands require an observed exit code 0 and no running session. Failure, changed context, or user steering returns control to you with all actual results. Do not use when a later command requires interpreting earlier output, selecting paths, editing based on an error, or making a new decision. Arguments remain literal. Existing user constraints and permissions apply. Call this tool directly and alone, then let the harness continue. This tool does not finish the task or prove success.".into(),
            strict: false,
            defer_loading: None,
            parameters: JsonSchema::object(BTreeMap::from([("commands".into(), commands)]), Some(vec!["commands".into()]), Some(false.into())),
            output_schema: None,
        })
    }

    fn handle<'a>(&'a self, invocation: ToolInvocation) -> codex_tools::ToolExecutorFuture<'a>
    where
        ToolInvocation: 'a,
    {
        Box::pin(async move {
            if invocation.turn.mode() == ModeKind::Plan
                || !invocation.turn.config.features.enabled(Feature::HarnessMm)
                || !matches!(
                    invocation.source,
                    crate::tools::context::ToolCallSource::Direct
                )
                || !invocation
                    .step_context
                    .tool_router
                    .exposes_tool(&ToolName::plain("exec_command"))
            {
                return Err(FunctionCallError::RespondToModel(
                    "HarnessMM requires a direct terminal-enabled execution turn.".into(),
                ));
            }
            let ToolPayload::Function { arguments } = &invocation.payload else {
                return Err(FunctionCallError::RespondToModel(
                    "HarnessMM requires JSON arguments.".into(),
                ));
            };
            let plan = parse_plan(arguments)?;
            let history = invocation.session.clone_history().await;
            if !matches!(history.raw_items().last(), Some(ResponseItem::FunctionCall { call_id, .. }) if call_id == &invocation.call_id)
            {
                return Err(FunctionCallError::RespondToModel(
                    "Call HarnessMM alone; intervening output invalidates the plan.".into(),
                ));
            }
            let state = invocation.turn.extension_data.get_or_init(State::default);
            let mut inner = state.0.lock().map_err(|_| {
                FunctionCallError::RespondToModel("HarnessMM state unavailable.".into())
            })?;
            if inner.bank.is_some() || inner.pending.is_some() {
                return Err(FunctionCallError::RespondToModel(
                    "A HarnessMM graph is already active.".into(),
                ));
            }
            let id = uuid::Uuid::new_v4().simple().to_string();
            let count = plan.commands.len();
            inner.bank = Some(Bank {
                id: id.clone(),
                commands: plan.commands,
                next: 0,
                checkpoint: Checkpoint::Author {
                    call_id: invocation.call_id,
                    items_before_ack: history.raw_items().len(),
                    prefix: history_key(&history),
                },
            });
            Ok(Box::new(FunctionToolOutput::from_text(
                json!({"graph_id": id, "registered_commands": count,
                "status": "registered", "guard": "native_exit_zero_and_no_session"})
                .to_string(),
                Some(true),
            )) as Box<dyn ToolOutput>)
        })
    }
}

impl CoreToolRuntime for HarnessMmHandler {
    fn is_builtin_control_tool(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod harnessmm_tests {
    use super::*;

    #[test]
    fn only_native_completed_success_is_admitted() {
        assert!(admitted_receipt(&json!({"exit_code": 0})));
        for value in [
            json!({"exit_code": 7}),
            json!({"session_id": 42}),
            json!({"exit_code": 0, "session_id": 42}),
            json!({"exit_code": "0"}),
            json!({"output": "Process exited with code 0"}),
            json!({"success": true}),
            Value::Null,
        ] {
            assert!(!admitted_receipt(&value), "{value}");
        }
    }

    #[test]
    fn literal_arguments_round_trip_without_interpolation() {
        let raw = r#"{"commands":[{"cmd":"Write-Output '$result; $(literal)'","workdir":"C:/repo","login":false},{"cmd":"python -m pytest","yield_time_ms":30000}]}"#;
        let plan = parse_plan(raw).unwrap();
        let value: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(
            serde_json::to_value(&plan.commands).unwrap(),
            value["commands"]
        );
    }

    #[test]
    fn reject_unknown_authority_and_invalid_graphs() {
        for raw in [
            r#"{"commands":[]}"#,
            r#"{"commands":[{"cmd":"x"}]}"#,
            r#"{"commands":[{"cmd":"x","sandbox_permissions":"require_escalated"},{"cmd":"y"}]}"#,
            r#"{"commands":[{"cmd":"x","tty":true},{"cmd":"y"}]}"#,
            r#"{"commands":[{"cmd":"x","yield_time_ms":30001},{"cmd":"y"}]}"#,
            r#"{"commands":[{"cmd":"x","max_output_tokens":10001},{"cmd":"y"}]}"#,
            r#"{"commands":[{"cmd":""},{"cmd":"y"}]}"#,
        ] {
            assert!(parse_plan(raw).is_err(), "{raw}");
        }
        assert!(parse_plan(&json!({"commands": vec![json!({"cmd":"x"});9]}).to_string()).is_err());
        assert!(parse_plan(&" ".repeat(MAX_BYTES + 1)).is_err());
    }
}
