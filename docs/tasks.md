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

For a selected `requires_operator` task, inspect the recorded evidence in its
details and enter `/retry NOTE`, `/committed NOTE`, or `/failed NOTE`. A nonempty
note is required and the decision is fenced by the displayed task revision.
These commands are interpreted only for operator-review tasks; ordinary text
cannot silently restart uncertain work. If another client has already decided,
refresh the task before acting again.

Task execution uses the same Alto serial runner as interactive runs. Each
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
other uncertain boundary. Retry is an explicit operator decision: inspect the
task revision with `task ID`, then reconcile it with a nonempty explanatory
note. `retry` restores the retained recovery payload to the durable queue;
there is no automatic retry after an unknown outcome. `committed` and `failed`
close the operation without another dispatch. If the queue is full, a recorded
retry grant remains `awaiting_admission` and enters once capacity is available,
including after restart. It can be cancelled while waiting. Cancellation is
recorded in the ledger before removing a queued entry, so a racing worker
cannot dispatch a successfully cancelled task.

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
child runs do not independently suspend a shared parent. Provider credentials
are re-resolved on the host, while exact messages and prepared tool data remain
in private state. This is an explicit continuation contract, not arbitrary
process serialization. Existing Socket approvals retain their live-wait policy.
Unknown effects after a resumed dispatch still require operator review.
