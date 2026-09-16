# Choosing an Alto runner

Zekkyou's resident runtime composes Alto's registry, queue, consumers and stores.
Execution scheduling is selected inside each trusted `Alto.Config` profile:

```elixir
profile = Alto.Config.new(
  runner: Alto.Runner.Stepped,
  runner_options: [mode: :automatic],
  provider: MyProvider,
  loop: Alto.chat_loop(),
  tools: tools,
  approval: approval_policy
)
Zekkyou.Config.new(workspace: workspace, profiles: %{"stepped" => profile})
```

Serial remains the default when `runner:` is omitted. Scheduled and interactive
runs resolve the same profile. Zekkyou still applies its task admission, worker
limits and execution caps; it does not replace those policies with an Alto
scheduler. Models and clients select a registered profile name, never a runner
module or arbitrary runner options. Team children inherit the chosen runner and
its options, as well as existing authority and shared budgets.

Stepped automatic mode schedules one effect per mailbox turn. Alto also offers
manual mode, but a trusted controller must consume and advance its tickets;
Zekkyou does not supply a manual-step UI or controller. Waiting for a manual
ticket consumes execution time and does not grant tool approval.

Custom runners implement `Alto.Runner`. Code using asynchronous runs should use
`Alto.start/await/cancel/terminate/subscribe`, opaque `Alto.Runner.Handle` values,
and neutral `Alto.Runner.Result` outcomes. A successful subscription returns
`{:ok, reference}` and delivers one `{:alto_runner_result, reference, outcome}`
notification, including failure. An await timeout does not cancel execution.
Zekkyou uses the resident registry's public lifecycle, result and notification
APIs and never inspects private runner handles or worker processes.

Alto's optional TaskHost retains a completed outcome for 60 seconds. Zekkyou's
registry owns its configured live result retention, while task status, usage,
operation evidence and session history live in their bounded durable stores.
Neither TaskHost retention nor a saved conversation grants permission to repeat
an uncertain task. See [task recovery](tasks.md).

The two shipped Alto runners share a versioned continuation format. A compatible
checkpoint can move between Serial and Stepped while retaining the same prepared
operation, state, budgets and store identities. Custom runners must implement a
compatible continuation contract or reject the packet without starting over.
Code, tool and configuration checks still apply. Older packets are incompatible;
follow the upgrade steps below before switching versions.

Parent continuation is an opt-in boundary for root runs that delegate through
an Alto child journal. A trusted profile supplies
`continuation_store: Zekkyou.ParentRuns.ledger()`, a journal on its bounded
subagents policy, and a `checkpoint_version`; the loop must implement checkpoint
dump/load for the child boundary. Serial and Stepped automatic mode save the
same pending and post-join parent frames. A completed batch can resume from its
saved frame without repeating the plan or children. The claimed frame is a
single-use grant for downstream effects. See [team recovery](teams.md) and the
[`task-recover` command](tasks.md).

Durable child approvals retain their own checkpoint and suspension identity.
The parent restores a decided child only after validating its configuration,
authority, shared account, workspace revision and absolute expiry. A distinct
single-use grant prevents a losing concurrent attempt from completing the
winner's journal or overwriting its transcript. The team loop resolves named
worker providers from trusted configuration; custom loops with provider
overrides need Alto's `resolve_child_provider/2` callback and stable profile keys.
Team also fingerprints its complete worker configuration as parent driver
options. Embedded credential changes invalidate that parent checkpoint before
child provider resolution, so keep those options stable across recovery.
Explicit terminal-task cleanup uses Alto's retirement APIs and preserves a
durable plan until all consumed resources have been retired.

The service and terminal dependency declarations and lockfiles pin Alto
`d05c400a4e3b04a013cc4f8a1291b31599a9a660`, published on Alto’s `main` branch
for `0.0.1`. Fresh builds use the pinned Git dependency. The optional
`ALTO_PATH=/absolute/path/to/alto` override remains available for local
development in both packages. Qualify persisted state against this exact
revision before replacing an executable.

## Upgrading from the durable-host development revision

The published runner-refactor baseline was Alto
`3bcec285537c5ab44d301a43737fc9d0b8351a7a`. The following migration guidance
still applies when upgrading older durable-host state to the current pin.

Before replacing the executable:

1. Inspect queued, running, suspended and operator-review tasks. Finish or
   approve/deny suspended work with the old executable. Review completed effects
   before choosing cancellation; cancellation does not undo those effects.
2. Inspect and export retained worker patches. Finish reviewed integration and
   explicitly discard resources with the old version when appropriate. Keep
   interrupted or uncertain resources for reconciliation.
3. Stop the service and keep a private backup of the complete state directory,
   trusted configuration and old executable. Never run two versions on one
   state directory. Deploy the new build separately and inspect recovered state.

Pre-refactor approval packets do not have the new continuation marker. For the
shipped runners, Zekkyou marks these tasks with
`upgrade_required: "pre_refactor_checkpoint"`, retains their exact snapshots,
and refuses approval/denial with `checkpoint_upgrade_required` before releasing
a checkpoint grant. The terminal explains the upgrade requirement. Cancellation
remains available after reviewing effects. Do not remove ledger entries or
submit the original task again as a substitute for reconciliation. Custom
runners own compatibility checks for their own packet formats.

Old workspace records keep the source inside backend metadata. New records bind
it separately at `workspace["source"]`, using `Alto.Workspaces.Snapshot` during
creation. Legacy resources remain listed and inspectable with
`upgrade_required: "legacy_workspace_source"`; frozen patches remain exportable.
Scoped patch use and discard return `workspace_upgrade_required`. Zekkyou does
not infer authority from old metadata, rewrite records, or delete resources.
Use the matching old executable for outstanding resource operations after
stopping the new service and assessing state compatibility; otherwise retain
and export the data for manual reconciliation. A backend/code fingerprint change
can also make an otherwise current resource stale and require review.

Ordinary completed transcripts remain usable. Keep the queue and operation logs;
downgrading a binary does not undo external changes or convert newer records to
older formats. An uncertain dispatched write or command must be reconciled
before any retry.

Registry application commands now execute in supervised tasks with a default
30-second `command_timeout`. Interrupted commands report
`{:command_outcome_unknown, reason}`. The command may already have committed;
inspect task/workspace/message state and its revision before retrying. Transport
or inner application timeouts likewise do not prove non-execution.
