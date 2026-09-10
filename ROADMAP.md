# Zekkyou roadmap

Approved 2026-09-10. Zekkyou is a separate application built on Alto: resident
agents keep working while clients disconnect, locally or on a remote host.

## Ownership and development

Alto owns reusable execution and scheduling mechanisms: durable admission,
claiming, bounded concurrency, delayed execution, cancellation, event history,
explicit retry eligibility, recovery and checkpoint contracts. Extend its
existing Queue, Inbox, OperationLog and frontend contracts before introducing
another engine. Keep these mechanisms optional and policy-neutral.

Zekkyou owns the agent task model and policy: selecting work and agent/model
profiles, coordinating agents, presenting decisions, memory, skills, and
communication adapters. One user task may span multiple Alto executions.

Develop both projects together. Make generic changes in a separate Alto branch
based on the clean public v0.0.1 commit
`67003823b50929e3a1ae4a78bb71a1738a9030b2`, then pin the integrated revision.
Do not import the private development history. Commit each validated major
step separately in its owning repository. Publication is separate from local
implementation. Use Luna subagents for bounded work; keep shared architecture,
recovery, integration and review with the lead agent. Hosted CI is out of scope.

## Milestones

1. **Foundation and contracts.** Separate Elixir project, private state,
   resident service, CLI, replaceable runtime adapter, trusted configuration.
   Verify published Alto APIs and inventory scheduling/recovery gaps.
   Gate: service starts independently and executes a real Alto task without a
   terminal renderer on the server.
2. **Detached execution and reconnect.** Service-owned runs, local socket,
   listing/cancellation, persisted events and explicit replay cursors/gaps.
   Generic durable machinery belongs in Alto.
   Gate: kill a client, let the task complete, reconnect and recover progress.
3. **TUI and SSH.** Reuse Alto's example UI components where practical; clients
   attach to the service instead of owning runs. Task list, conversation,
   details, composer, decisions and usage; SSH transport uses existing SSH.
   Gate: consistent views across two clients; remote reconnect and follow-up.
4. **Unattended work and recovery.** Alto durable scheduling, execution budgets,
   pending-decision/checkpoint contracts and conservative interrupted-run
   reconciliation. Zekkyou selects policy. Service packaging and systemd unit.
   Gate: approval-dependent work parks; restart never silently repeats an
   uncertain external effect; independent permitted work can continue.
5. **Subagents and messages.** Bounded child runs, shared budgets, cheaper model
   profiles, cancellation propagation, durable mailboxes and isolated coding
   workspaces. Use Alto delegation mechanisms and extend generic gaps there.
   Gate: lead agent delegates independent tasks, receives results and integrates
   them without conflicting writes or exceeding shared authority/budgets.
6. **Memory and skills.** Scoped persistent memory with provenance and bounded
   retrieval; inspect/edit/delete. Versioned skills: propose, validate, activate,
   rollback. Gate: a later session retrieves prior knowledge and reuses an
   inspected skill; proposed skills cannot silently grant authority.
7. **Communication and qualification.** Interchangeable communication contract,
   optional Discord integration with identity checks and deduplication, docs,
   installation and sustained remote execution qualification.
   Gate: TUI and Discord operate on the same task and duplicate delivery does
   not duplicate execution; sustained work survives disconnects and restarts.

## Working constraints

- Client disconnect is not server crash. Prove each recovery boundary separately.
- Alto execution outcomes remain authoritative; Zekkyou does not infer success
  from transport failure or replay an uncertain operation automatically.
- Persistent state belongs outside project checkouts, with bounded reads/writes
  and owner-only permissions. Credentials are resolved by trusted configuration.
- Live provider, SSH and Discord checks require real configured services; report
  unexercised integrations explicitly rather than substituting mocked evidence.
- Every milestone needs relevant behavioral checks, format/compile checks and a
  separate commit. Tests should exercise failure boundaries, not mirror code.

## Progress

- Planning: approved and revised with shared Alto ownership.
- Foundation implemented: separate Elixir application, trusted named profiles,
  replaceable runtime adapter, resident service, private socket/state, CLI,
  executable packaging, and an optional systemd user-service template.
- Detached-execution baseline implemented: client closure leaves work running;
  reconnect, cancellation, completed-session follow-up and paginated durable
  event history are available through the CLI. History survives a fresh VM.
  Run/session IDs are the initial task identity; richer agent task state comes
  with the application scheduling policy.
- Alto mechanisms committed on `zekkyou/durable-host`: `0ea2ec0` adds replay
  and owner-bound run lifetime; `d9604e2` adds due times/fenced rescheduling;
  `262bd13` makes replay independent of atoms loaded in the old VM;
  `8ecceaf` supplies run summaries and saved conversations for reconnecting clients;
  `711aee9` adds fenced rejection, per-grant recovery admission, application
  commands, and authoritative owner-bound results;
  `ab97a1b` adds durable approval checkpoints, declared continuation snapshots
  and budget restoration; `ec5e3fa` fixes listener cleanup during supervised
  shutdown and recovery after acceptor failure; `da4d112` adds concurrent child
  batches, inherited tool/depth authority, owned lifetime, shared accounting,
  and bounded per-request context; `759192b` adds exact matching queue claims,
  claimed-record wire bounds and checkpointed execution-tree identities.
- Zekkyou pins `759192bdb591e76fe8533f2d9a429c31d319a3f2`. These Alto changes
  remain local on `zekkyou/durable-host` in `/home/three/code/alto`; use
  `ALTO_PATH` until that revision is published. The initial independent checkout
  in `.work/alto` has been superseded by this normal Alto checkout.
- TUI implementation: optional `packages/zekkyou_tui` client reuses Alto's
  layout, selects resident/stored sessions, sends follow-ups, displays saved
  conversation and bounded activity, handles approval/cancel commands, and
  shows completion usage. Its network work runs outside the renderer.
- Managed SSH transport uses OpenSSH, a private forwarding socket, existing
  authentication/host checks, bounded startup diagnostics, and owner cleanup.
  Reconnection reopens the tunnel without restarting work.
- Alto now supplies resident summaries and bounded saved transcript snapshots;
  Zekkyou retains application presentation and transport policy.
- Validation: 53 service/client/transport tests and 13 terminal tests, including
  a real native headless terminal driving a resident task across detach/reconnect.
  Two clients recover identical conversations and follow-up messages; saved
  conversation survives service restart. The standalone service smoke check
  still verifies fresh-VM history and absence of native UI dependencies.
- Milestone 3 implementation is committed; live remote SSH/reconnect
  qualification remains outstanding because no SSH host is configured.
  Native terminal libraries require the on-disk launcher, not an escript.
- Milestone 4 scheduling is implemented: Zekkyou now has a durable scheduled-task
  policy backed by Alto's bounded queue and operation ledger, including due-time
  admission, worker limits, run budgets, lease fencing, explicit cancellation,
  conservative interrupted-run parking, revisioned operator reconciliation, and
  CLI inspection/submission commands. Scheduling configuration bounds pending
  tasks, workers, attempts, run time, model requests and effects; Alto also
  applies bounded payload, evidence and durable-record limits.
- Terminal task integration is implemented: the composer uses the durable queue,
  queued tasks are selectable before execution, cancellation covers waiting work,
  and operator review commands carry the viewed revision and an explanatory note.
  Reconnect recovers task state and recorded outcomes.
- Durable approvals are implemented in Alto: explicit suspended ledger state,
  exact prepared operation and continuation capture, optional loop snapshot
  callbacks, version/code checks, budget restoration, and revision-fenced host
  decisions. Zekkyou uses these APIs to free workers and resume saved approvals
  through CLI and terminal controls. No earlier effect or preparation is replayed.
- Independent-VM qualification verifies suspension, independent work, restart,
  exact prepared-value continuation, and completion replay in a third VM.
  Tests also cover model/tool batches, repeated approval segments under a single
  retry allowance, denial, cancellation gaps, and stale prepared file writes.
- Milestone 4 service packaging and local operational qualification are implemented:
  a relocatable release bundles Erlang/Elixir, the CLI, examples and systemd unit.
  Archive checks pass without system Erlang/Elixir/Mix on PATH and verify real
  execution, exact argument forwarding, private state, single-owner startup,
  scheduled work, checkpoint recovery, interrupted-effect review and SIGTERM cleanup.
  A transient local systemd unit passes automatic crash restart, delayed execution,
  history/task recovery after another restart, and complete shutdown. No persistent
  unit was installed or enabled. Remote-host qualification remains outstanding.
  Custom loops must declare serializable continuations; arbitrary live state and
  independently suspended child runs are not supported by this checkpoint path.
- Milestone 5 is partially implemented: named worker profiles let the lead plan
  independent assignments, select configured worker models, run bounded parallel
  children and integrate their ordered results through Alto's default tool loop.
  Plans cannot introduce providers/tools/prompts. Workers have separate prompts,
  explicit tool subsets, inherited depth limits and shared execution budgets.
  Cancelling or killing the parent cancels children; unknown outcomes and
  descendant token usage propagate to the parent.
- Team tests cover named-profile selection, invalid whole-plan rejection,
  follow-ups with prior history and approval during integration. Three fresh VMs
  verify completed worker results and consumed budgets survive the lead's
  checkpoint, with no worker replay and accurate final usage. The runnable team
  example assigns inspection to workers and reserves file edits for the lead.
- Durable addressed mailboxes are implemented using Alto's atomic matching
  claims and host-derived execution-tree identities. Zekkyou supplies message
  validation, sender/recipient policy, scoped tools and operator inspection/cancellation.
  Fresh-VM tests verify two worker messages survive the lead's approval pause,
  restore under the same root identity despite a new run ID, and are acknowledged
  without worker replay. Claim fencing, first-wins deduplication, bounds and
  recipient isolation are covered. Messages do not create or wake agents.
- Milestone 5 still needs isolated coding workspaces, mailbox retention cleanup
  and child lifecycle/recovery policy. Workers currently share the configured
  workspace; they are not independent durable queue tasks. This does not yet
  satisfy the full concurrent coding-workspace gate.
- Next implementation: child lifecycle and isolated workspaces,
  extending shared Alto contracts where needed. Remote qualification follows
  when a host is available.
- Recovery now restores queued work and explicitly approved checkpoints; uncertain
  dispatched effects remain parked for operator reconciliation. Durable agent
  coordination, memory/skills and messaging adapters remain pending.
