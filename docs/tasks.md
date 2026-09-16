# Scheduled tasks

The task commands submit work to the resident service. The service writes the
task to Alto's durable queue before reporting success, and workers claim due
records under a lease. A task can be delayed with `--delay-ms` and can use an
explicit id for idempotent admission:

```text
zekkyou schedule PROFILE TASK [--delay-ms N] [--id KEY]
zekkyou tasks
zekkyou task ID
zekkyou task-cancel ID
zekkyou task-reconcile ID committed|failed|retry --revision N --note TEXT
zekkyou task-decide ID approve|deny --revision N
zekkyou task-recover ID KEY --revision TASK_REV --generation G --continuation-revision CELL_REV
zekkyou task-child-decide TASK CHILD approve|deny --revision TASK_REV --generation BATCH_GEN --batch-revision BATCH_REV --attempt ATTEMPT --suspension NONCE --key BATCH_KEY
zekkyou task-cleanup TASK --revision TASK_REV
```

Scheduling is bounded in the trusted service configuration. For example:

task-decide submits a fenced operator decision for a task using its current
positive revision. The decision is limited to approve or deny; the service
validates the revision again before applying it.

```elixir
Zekkyou.Config.new(
  workspace: "/srv/zekkyou/workspace",
  state_dir: "/srv/zekkyou/state",
  profiles: profiles,
  scheduling: [
    workers: 2,
    max_attempts: 3,
    poll_ms: 250,
    run_timeout: 300_000,
    max_model_requests: 64,
    max_effects: 1_000,
    max_pending: 100,
    max_tasks: 1_000
  ]
)
```

`zekkyou start PROFILE TASK` starts an execution directly and returns a
run/session identity for live watching and follow-up. `zekkyou schedule PROFILE
TASK` and the TUI composer submit application tasks to the durable queue, where
resident workers execute them after their due time. The terminal shows queued
work before a run exists, retains task identity across restart, and supports
cancellation of queued and running work. Follow-ups create new durable tasks
using the selected task's completed session as context.

In the TUI, Ctrl+G W opens an existing folder on the service host, with
highlighted suggestions and Tab completion. Ctrl+G N starts a task in the current
folder without opening the folder picker.
The service registers that folder and persists its identity and working path in
each new task, including delayed work. The private transport's `projects.list`,
`projects.complete` and `projects.open` commands list, complete and register folders; `tasks.submit` accepts
`workspace_id` from that catalog. It does not accept arbitrary execution options.
A resumed session keeps its recorded folder, and a conflicting explicit workspace
is rejected. Without a chosen workspace, new work uses the profile's configured
folder or the service default.

For a selected `requires_operator` task, inspect the recorded evidence in its
details and enter `/retry NOTE`, `/committed NOTE`, or `/failed NOTE`. A nonempty
note is required and the decision is fenced by the displayed task revision.
These commands are interpreted only for operator-review tasks; ordinary text
cannot silently restart uncertain work. If another client has already decided,
refresh the task before acting again.

Task execution uses the same trusted Alto runner profile as interactive runs.
Serial is the default; `runner: Alto.Runner.Stepped` selects its automatic host.
See [runner selection and upgrade notes](runners.md). Each
attempt is recorded in the operation ledger before execution and its outcome
is recorded before the queue claim is acknowledged. Leases and rotating claim
ids fence stale workers. Queue, ledger, payload, attempt, and outcome bounds
come from the scheduling configuration; each scheduled profile is additionally
capped by those limits and by the configured run timeout.

`task ID` retains a bounded failure explanation in `evidence.reason`, including
budget denials, so a reconnect can show why execution stopped. These explanations
are limited to 2,048 characters; the authoritative outcome class and task state
remain separate fields.

Unknown work is parked as `requires_operator` after a restart, timeout, or
other uncertain boundary. For tasks without a parent continuation, retry is an
explicit operator decision: inspect the task revision with `task ID`, then
reconcile it with a nonempty explanatory note. `retry` restores the retained
recovery payload to the durable queue; there is no automatic retry after an
unknown outcome. `committed` and `failed` close the operation without another
dispatch. If the queue is full, a recorded retry grant remains
`awaiting_admission` and enters once capacity is available, including after
restart. It can be cancelled while waiting. Cancellation is recorded in the
ledger before removing a queued entry, so a racing worker cannot dispatch a
successfully cancelled task.

A scheduled profile can opt into a retained parent continuation with a trusted
`continuation_store: Zekkyou.ParentRuns.ledger()`, a durable child journal, and
checkpoint callbacks that support the child boundary. Zekkyou opens a per-task
durable shared budget account unless the profile supplies one. After a parent
process is lost, `task ID` exposes `parent_continuation` with its `identity`
(`key` and `generation`), `revision`, `phase`, and `session_id`. Inspect that
snapshot and the child batch before recovering. For example:

```text
zekkyou task-recover TASK_ID CELL_KEY --revision TASK_REV --generation CELL_GENERATION --continuation-revision CELL_REV
```

This command accepts only a parked task and the exact current task and cell
revisions. Every child must have a retained result, the parent frame must
already be ready, or a child must have an explicit saved approval decision.
It readmits the saved parent frame to resume decided children, integrate results and
continue; it does not rerun the model's plan or dispatch a child again. A
missing, pending-child, claimed, or mismatched continuation is refused. A task
with a parent continuation cannot use generic `task-reconcile ... retry` as a
substitute. The parent frame is claimed once before downstream effects, so an
uncertain later effect still needs ordinary operator review.

Recovery does not approve a tool. Suspended tool approvals continue to use
`task-decide` and their own saved decision. Parent continuations carry an
absolute expiry; time spent stopped counts against the run deadline. The
acknowledged child journal, claimed parent cell, and budget account remain
retained after recovery until explicit terminal-task cleanup.

When a child reaches a durable approval boundary, use `task-child-decide` with
the exact task revision, batch generation and revision, child attempt, suspension
nonce, and batch key obtained through `task`, `team-batch` and
`team-child-approval`. For example:

```text
zekkyou team-child-approval BATCH_KEY CHILD --generation BATCH_GEN --revision BATCH_REV
zekkyou task-child-decide TASK CHILD approve --revision TASK_REV --key BATCH_KEY --generation BATCH_GEN --batch-revision BATCH_REV --attempt ATTEMPT --suspension NONCE
```

The service fences every
identity, records the child decision durably, and only then readmits the parent
continuation. Sibling states remain retained; approval does not replan or
redispatch any child. The continuation's absolute expiry includes downtime, so
stopping the service does not extend its deadline.

Use `task-cleanup TASK --revision TASK_REV` only for a terminal task after
reviewing its retained state. Cleanup retires consumed child journals, claimed
parent continuations, and the task's owned durable account through a restartable
manifest. Pending, uncertain, or unconsumed records remain protected. Accounts
shared externally are never retired by task cleanup. Ordinary root approvals
continue using `task-decide`.
If cleanup is interrupted, repeat the same command and task revision. Its
durable plan survives even if the task record is later evicted. Store replacement
or a different task generation cannot redirect that plan. Retired records become
eligible for bounded ledger eviction; cleanup does not delete transcripts, worker
patches, or mailbox messages. A task ID remains unavailable for reuse while its
old continuation, owned account, or cleanup record is retained.
Retirement does not compact the append-only operation audit logs; their configured
byte limits still apply.

The `scheduled/` profile prefix is reserved internally. Retention is bounded:
completed task identities can eventually be evicted; an idempotency key is not
an indefinite duplicate-delivery guarantee.

Durable approval is enabled explicitly in each trusted Alto profile:

```elixir
Alto.Config.new(
  provider: nil,
  loop: Alto.rule_loop(steps: ["write_file"]),
  tools: [Alto.Tools.WriteFile],
  approval: Alto.Approvals.Checkpoint,
  checkpoint_version: "write-v1"
)
```

`examples/approved-write.exs` is a runnable configuration for this real file
operation. Required approvals become `waiting_approval`, persist their exact
prepared operation and continuation in Alto, and release the worker slot. The
terminal's Ctrl+A/Ctrl+D controls approve or deny the saved decision; the CLI
uses `task-decide ID approve|deny --revision N`. The decision survives restart
and is written before the continuation is readmitted. Ordinary text cannot
start a follow-up while a task is awaiting approval. Cancellation is durable.

Approved continuations do not repeat earlier effects or tool preparation, and
healthy approval segments do not consume the ordinary retry allowance. Saved
budgets preserve consumed effects and model requests; waiting for a decision
pauses active execution time. Current stricter limits still apply. A changed
file can invalidate a saved prepared write even after approval.

Alto's shipped Default, Chat and Rule loops support explicit checkpoint
reconstruction. Custom loops need the same callbacks. Checkpoints reject live
process capabilities, unsupported data and changed loop/tool fingerprints;
Child approvals in opted-in durable batches have their own retained checkpoints
and single-use grants. Provider credentials
are re-resolved on the host, while exact messages and prepared tool data remain
in private state. This is an explicit continuation contract, not arbitrary
process serialization. Existing Socket approvals retain their live-wait policy.
Unknown effects after a resumed dispatch still require operator review.

Pre-refactor suspended approval packets are retained but cannot be approved or
denied by the new shipped runners. The task reports `upgrade_required` and the
terminal explains the required reconciliation; see [upgrade steps](runners.md).
Completed transcripts remain usable. Interrupted application commands can report
`command_outcome_unknown`; inspect durable state before retrying.
