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
  `262bd13` makes replay independent of atoms loaded in the old VM.
- Zekkyou pins `262bd132a44e506ca103c09cef840fd3b5716b33`. These Alto changes
  remain local in `.work/alto`; use `ALTO_PATH` until that revision is published.
- Validation: 10 Zekkyou tests, 611 Alto tests, warning-free compile/format
  checks, and standalone real-file execution/reconnect/fresh-VM replay.
- Next: milestone 3, the reconnecting TUI and live SSH qualification.
- Unattended task policy, durable approvals/checkpoints, automatic safe recovery,
  concurrent agent coordination, memory/skills and messaging adapters remain
  pending. The existing queue extension is a mechanism, not that application.
