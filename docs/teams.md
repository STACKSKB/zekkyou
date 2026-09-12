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

The lead profile selects the Alto runner and trusted `runner_options`; workers
inherit them. Serial remains default and Stepped automatic mode is supported.
See [runner configuration and upgrade notes](runners.md).

Alto owns the shared mechanism: effect/model-request counters, active execution
deadline, child lifetime, result bounds and inherited authority. A rejected
budget reservation does not consume capacity. Children cannot add tools,
replace tool implementations/options, widen model exposure or increase the
parent's depth allowance. Cancelling the lead cancels active children and leaves
queued children unstarted. Killing the parent also cancels its active children.

Trusted Alto profiles can supply an already opened
`Alto.Runner.Budget.Account` through `budget_account:`. The host owns and
supervises its `Alto.OperationLog`. The account persists shared effect and model
request counts, including charges made after an approval snapshot was captured.
Restoration must supply the same account generation; reopening cannot widen
its caps. Sharing one account across profiles or tasks intentionally shares one
allowance. When a scheduled profile enables parent continuations, Zekkyou opens
a per-task durable account unless the profile supplies one. Other profiles keep
the live shared counter, with consumed counts saved in supported root checkpoints.

This option persists count limits only. Root approval pauses keep their existing
active-time semantics. A parent continuation has an absolute expiry, so downtime
counts against its deadline. Counts are not token or currency limits. A parent
continuation's account remains retained after the parent frame is claimed;
automatic retirement is future work.

Results return in assignment order and enter the lead's bounded conversation as
`alto_subagent_results`. Token usage includes descendant usage; the result's
`model_requests` field remains the lead's own request count. Unknown child
outcomes remain unknown in the parent outcome, even if the lead produces a final
answer. Durable tasks then require operator reconciliation.

## Recovery and remaining work

Optional [durable mailboxes](mailboxes.md) support addressed messages between
team members. The example grants this tool to the lead and inspection workers.
Alto binds each sender and reader to its execution identity; Zekkyou supplies
envelope validation, routing policy and operator inspection.

The lead can checkpoint during integration after its workers finish. Restart and
approval continuation preserve the completed worker results, consumed budgets
and exact pending operation; the plan and child work are not repeated.
Completed-session follow-ups start a new planning stage.

`Zekkyou.Team.loop(workers: workers, sessions: :separate)` opts into Alto's
separate child session logs and transcript snapshots. The default is `:shared`.
Each completed worker result includes its `session_id`; separate session
summaries retain the parent session and execution-tree identity. These child
conversations appear in saved-session listings. Inspect the saved conversation
in the terminal or use `history SESSION` for its events. They retain their own transcript revision
without changing the lead's conversation. This option requires a persisted lead;
an unrecorded run does not create child sessions. Session storage remains best
effort, and a separate conversation does not authorize child recovery or reset
the shared execution budget.

`Zekkyou.Team.loop(workers: workers, journal: MyChildJournal)` enables Alto's
optional durable child journal. Supply a supervised `Alto.OperationLog` server;
a stable registered name lets checkpoint configuration match after restart.
Alto records dispatch before each worker starts and saves each exact bounded
child summary before returning it to the lead. Results and parent identity
links survive even if the lead cannot collect the reply. The default has no
child journal.

To let a scheduled lead resume a completed batch after its parent process is
lost, enable both the journal and a parent continuation store in its trusted
profile:

```elixir
Alto.Config.new(
  provider: MyProvider,
  loop: Zekkyou.Team.loop(workers: workers, journal: Zekkyou.ChildRuns.ledger()),
  continuation_store: Zekkyou.ParentRuns.ledger(),
  checkpoint_version: "team-parent-v1"
)
```

The loop must support checkpoint dump/load for the child boundary. Alto saves a
pending parent frame before child dispatch, then saves the exact post-join frame
before granting the next parent effect. Serial and Stepped automatic mode use the
same retained format. Until the Alto change is published, set `ALTO_PATH` to the
local Alto checkout used by this feature; see [runner setup](runners.md).

The default resident runtime now supervises a journal at
`operations/team-children.jsonl` within the private state directory. Opt in with
`journal: Zekkyou.ChildRuns.ledger()`; a named service uses `ledger(service_name)`.
The runnable team example enables this journal and separate child sessions.
The `child_runs` service settings default to 128 retained batches, a 64 MB log
and a 1 MB checkpoint limit per batch. A batch contains all its child results;
the per-batch bound can be reached before Alto's individual result limit.
Retention exhaustion refuses further writes rather than evicting unconsumed
results. Inspection does not free capacity. Existing separately supervised
journals remain supported and untouched; these commands inspect only the
resident journal, not arbitrary configured stores.
Finish pending approvals with their existing trusted profile before changing
its journal or session settings; Alto binds checkpoints to that configuration.

The lead's `subagents_started` and completion events expose the journal binding.
Trusted host code can reconnect with `Alto.Subagents.Journal.restore/2` and read
ordered results with `join/1`. Results stay retained until that host durably
saves its consuming continuation, acknowledges the viewed revision with
`acknowledge/3`, then explicitly calls `retire/2`. The parent continuation path
acknowledges the completed join before claiming its post-join frame. It leaves
the acknowledged journal and claimed parent cell retained; automatic retirement
is future work.
A dispatched worker without a saved result remains uncertain and cannot be
silently rerun. Journal limits can reject retention; Alto preserves uncertainty
and reports persistence failure rather than inventing a successful join. Exact
result decoding uses Alto's portable codec; result atoms require their trusted
defining modules to be loaded in the consuming VM.

The resident service exposes read-only inspection for its child journal through
`team-batches`, `team-batch KEY`, and `team-result KEY CHILD --generation G
--revision N [--cursor N]`. These commands list retained batches, inspect a
batch's child states, or export a bounded base64 portable-term result in chunks.
The generation and revision are required on every result page so an operator
cannot accidentally read from a replaced batch or stale view. Local operators
may read and export these records; the commands never acknowledge, retire, or
resume a batch. A completed child means only that an exact outcome was retained;
that outcome may be an error or `unknown`. A dispatched child without a retained
outcome remains uncertain and must not be silently rerun. A batch's `active`
state describes retained, unretired storage; it does not prove a worker is alive.

Concatenate result `chunk` strings in cursor order and verify `bytes` and
`sha256` against that complete ASCII base64 string. The encoding is Alto's
portable-term representation, not JSON; trusted Elixir tooling can decode it
with `Alto.Persistence.Codec.decode/1`. Export itself does not decode terms or
load custom modules. This preserves results even when their custom atom
vocabulary is unavailable in the observing VM. If another child completes
between pages, the old revision is refused: inspect the batch again and restart
the export. List pagination is a bounded view of the current sorted keys, not
a frozen snapshot; rescan while batches are being added or retired.

`python3 -B scripts/child_recovery_smoke.py` checks an abrupt process-group kill
during delegation for both Serial and Stepped. One child has a retained result,
one has performed an effect without returning, and one has not started. Two
fresh observing service VMs recover identical paged results and journal bytes,
leave the interrupted parent for operator review, and do not dispatch any child.
This verifies recovery of evidence for an incomplete batch. It does not grant
another dispatch or exercise the completed-batch parent continuation path.

Workers share the configured workspace unless the team receives an optional
[workspace manager](workspaces.md). The manager gives each child an independent
Git checkout and captures a frozen patch without changing the source. The
supplied example gives workers inspection tools and reserves file editing for
the lead. [Reviewed patch integration](workspaces.md) is available for coding
teams; independent child recovery remains pending, so milestone 5 is not complete.
Neither mailbox durability nor separate session history makes child execution
independently recoverable. A crash during active delegation parks the containing
durable task for operator review. Once every child has a retained result, an
operator can resume the parent at its saved continuation with
`task-recover ID KEY --revision TASK_REV --generation G
--continuation-revision CELL_REV`. An incomplete dispatched child stays pending
and cannot be restarted by this command. See [scheduled task recovery](tasks.md).
Checkpoint approvals inside an independently active child are not supported;
use supported approval policies for workers and keep durable checkpointed
integration in the lead. Live provider/model quality and cost have not been
qualified by the local deterministic tests.

`python3 -B scripts/team_smoke.py` (after `mix escript.build`) verifies the
complete team/approval flow across three fresh service VMs, including final
descendant usage, a shared five-request budget, and unchanged separate child
histories, transcripts and retained child journals across restarts. The release qualification
script runs this same scenario against its extracted bundled runtime.
