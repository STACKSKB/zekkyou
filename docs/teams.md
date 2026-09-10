# Named worker teams

`Zekkyou.Team.loop/1` lets a lead model plan independent assignments, select
trusted worker profiles, collect their results and continue with Alto's ordinary
tool loop to integrate the work. Set each worker's provider/model in trusted
configuration, including a less expensive model where appropriate. The model's
plan can select a profile name and task text; it cannot supply executable code,
tools, providers, prompts or credentials.

The runnable [`examples/team.exs`](../examples/team.exs) configures inspection
workers and a lead that can propose prepared file writes for approval:

```sh
export ZEKKYOU_WORKSPACE=/absolute/path/to/repository
export ZEKKYOU_PROVIDER_URL=https://your-provider.example/v1
export ZEKKYOU_MODEL=your-lead-model
export ZEKKYOU_WORKER_MODEL=your-worker-model
# Set ZEKKYOU_API_KEY if your provider requires it.
./zekkyou serve examples/team.exs
```

From another terminal:

```sh
./zekkyou schedule team "Inspect the parser and its tests independently, then fix the identified issue"
./zekkyou tasks
./zekkyou task TASK_ID
```

The bundled release uses `bin/zekkyou-cli` in place of `./zekkyou`. The terminal
client can select this profile with `--profile team` and use its existing task
and approval controls. A lead's prepared write can park for a durable approval;
resume it through the terminal or `task-decide TASK_ID approve --revision N`.

## Policy and execution

Worker profiles are keyword lists with these supported fields:

| Field | Behavior |
| --- | --- |
| `provider` | Trusted provider module/options; omitted means inherit the lead provider. |
| `tools` | Exact subset of the lead's tool modules/options; omitted means no tools. |
| `model_tools` | Optional further restriction on provider-visible tool names. |
| `max_steps` | Child model-step cap, also bounded by the parent cap. |
| `loop` | Optional trusted Alto loop; default is Alto's ordinary tool loop. |
| `system_prompt` | Worker instructions; omitted uses an independent worker prompt. |

Pass `Zekkyou.Team.instructions(workers, max_children)` as the lead's system
prompt, adding your own integration requirements if needed. The loop adds
explicit planning/integration markers to the conversation so later tasks can
plan again while retaining prior history. Planning exposes no tools and accepts
only this JSON shape:

```json
{"agents":[{"id":"parser","profile":"inspect","task":"Inspect the parser"}]}
```

The entire plan is checked before delegation. IDs must be unique and at most
100 bytes, task text at most 32,000 bytes, and each profile must be registered.
Unknown fields and malformed plans fail the task without dispatching children.
Team configuration accepts 1–64 named profiles and children, with concurrency
no greater than the configured child limit. Defaults are four children and two
concurrent children. The example runs at most two inspection workers at once.

Alto owns the shared mechanism: effect/model-request counters, active execution
deadline, child lifetime, result bounds and inherited authority. A rejected
budget reservation does not consume capacity. Children cannot add tools,
replace tool implementations/options, widen model exposure or increase the
parent's depth allowance. Cancelling the lead cancels active children and leaves
queued children unstarted. Killing the parent also cancels its active children.

Results return in assignment order and enter the lead's bounded conversation as
`alto_subagent_results`. Token usage includes descendant usage; the result's
`model_requests` field remains the lead's own request count. Unknown child
outcomes remain unknown in the parent outcome, even if the lead produces a final
answer. Durable tasks then require operator reconciliation.

## Recovery and remaining work

The lead can checkpoint during integration after its workers finish. Restart and
approval continuation preserve the completed worker results, consumed budgets
and exact pending operation; the plan and child work are not repeated.
Completed-session follow-ups start a new planning stage.

Workers currently share the configured workspace. The supplied example gives
workers inspection tools and reserves file editing for the lead. Isolated coding
workspaces, durable addressed mailboxes and separate child recovery are still
pending; milestone 5 is not complete. Child runs share the parent session's
best-effort event history, not a separate durable dispatch ledger. A crash during
active delegation parks the containing durable task for operator review.
Checkpoint approvals inside an independently active child are not supported;
use supported approval policies for workers and keep durable checkpointed
integration in the lead. Live provider/model quality and cost have not been
qualified by the local deterministic tests.

`python3 -B scripts/team_smoke.py` (after `mix escript.build`) verifies the
complete team/approval flow across three fresh service VMs, including final
descendant usage and a shared five-request budget. The release qualification
script runs this same scenario against its extracted bundled runtime.
