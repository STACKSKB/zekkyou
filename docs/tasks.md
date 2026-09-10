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
```

Scheduling is bounded in the trusted service configuration. For example:

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

`zekkyou start PROFILE TASK` and the TUI start an execution directly and are
intended for interactive work: they return a run/session identity for live
watching and follow-up. `zekkyou schedule PROFILE TASK` submits an application
task to the durable queue, where resident workers execute it after its due time
and expose task state through `tasks`, `task`, and `task-reconcile`.

Task execution uses the same Alto serial runner as interactive runs. Each
attempt is recorded in the operation ledger before execution and its outcome
is recorded before the queue claim is acknowledged. Leases and rotating claim
ids fence stale workers. Queue, ledger, payload, attempt, and outcome bounds
come from the scheduling configuration; each scheduled profile is additionally
capped by those limits and by the configured run timeout.

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

The existing approval policies still wait on live front-end connections and
fail closed when unavailable. Durable approval checkpoints are planned for a
later milestone, so an approval wait that crosses the resident execution
boundary must be handled as operator work according to the configured timeout.
