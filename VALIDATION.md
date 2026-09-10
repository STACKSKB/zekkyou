# Development checkpoint — 2026-09-10

Alto source: public v0.0.1 plus local commits on `zekkyou/durable-host` in
`/home/three/code/alto`. The normal Alto checkout contains all integration changes, including durable
admission, revision-fenced cancellation and retries, trusted application commands,
and registry-owned or caller-owned execution. Set `ALTO_PATH` until the integrated
revision is published.

## Automated checks

- Zekkyou: **56 tests passed**. Includes resident execution, private state,
  named profiles, correlated bounded socket requests, owner cleanup, malformed
  envelopes, disconnect/reconnect, two-client conversation consistency,
  follow-up context, persisted transcript after service restart, approval
  replay/selection, cancellation, and managed SSH process cleanup. Console
  checks also cover delayed tasks without sessions, two-client revision-fenced
  operator decisions, and follow-ups submitted through the durable queue.
  Durable approval tests cover restart, worker-slot release, multiple approval
  segments under one retry allowance, denial, cancellation during claim cleanup,
  and a real prepared write rejecting a subsequently changed file.
  Team tests cover named profiles, strict whole-plan validation, separate worker
  prompts, explicit stage markers across follow-ups, and checkpointed integration
  after restart without rerunning workers. Completed tasks show final persisted
  usage rather than stale checkpoint totals.
  Mailbox tests cover recipient/root isolation, first-wins delivery identity,
  restart, stale claim fencing, release, encoded size bounds and scoped operator
  inspection/cancellation. Models cannot supply sender or root identities.
- Optional terminal package: **13 tests passed**. Covers CLI option validation,
  responsive layout, keyboard release handling, UTF-8 paste byte bounds,
  preservation of edits typed during submission or reconciliation, operator
  command scoping, and running-task selection.
  A real ExRatatui headless terminal submits to a real resident service,
  detaches during execution, reconnects, and verifies the rendered answer.
- Alto: **723 regression tests passed** with `--max-cases 4`, covering the
  shared queue/ledger recovery changes and application command envelope bounds.
  Checkpoint tests cover exact continuation and prepared-value restoration,
  model/tool batches, budget preservation, unsupported capabilities,
  configuration mismatch, and bounded custom snapshot callbacks. Listener tests
  also verify supervised socket cleanup and termination after acceptor failure.
  Delegation tests exercise concurrent batches, ordered outcomes, shared model
  caps, atomic reservations without overshoot, cancellation, parent death,
  tool replacement/widening rejection, inherited depth, unknown child outcomes,
  aggregate usage, and bounded per-request context without role overrides.
  Matching queue claims cover multiple exact selector fields, due times,
  routing past unrelated heads, append failure and receipt byte bounds.
  Execution-tree identities follow nested delegation and exact checkpoint
  restoration, malformed identity rejection and actual claimed-record byte limits.
- Compilation with warnings as errors and formatting checks passed for the
  service and terminal package; Alto's core compilation passed as well.
- The terminal launcher was exercised in a real PTY through startup,
  connection-failure display, and Ctrl+Q teardown. The native renderer cannot
  load from a single-file escript, so the terminal uses `bin/zekkyou-tui`
  with compiled libraries on disk. The service has an escript and a bundled
  release with its own Erlang/Elixir runtime.

## Independent-process qualification

`python3 scripts/smoke.py` passes after building the service executable. It
creates an actual workspace file, starts a standalone service, invokes Alto's
real directory-listing tool from a separate CLI process, reconnects, stops the
service, then starts a fresh VM and compares saved event history and session
listing. It also admits a delayed task before stopping the first VM, waits for
execution in the second VM, and verifies its recorded outcome in a third VM.
The executable archive contains no ExRatatui dependency.

`python3 scripts/checkpoint_smoke.py` also passes across three independent VMs.
The first suspends after a real prior file effect and completes independent
work. The second recovers the same request/revision, approves, and executes the
original prepared value after its input changed. The third confirms completion
without another effect.

`python3 -B scripts/team_smoke.py` passes across three fresh VMs. A lead plans
two named workers, collects their results, and checkpoints a prepared integration
write. After restart it uses the original prepared value without another worker
request, within a shared five-model-request budget. Final usage includes all
five requests and remains correct in the third VM. Providers are deterministic
local fixtures; the prepared write is real Alto tool execution.

The script also passes a second three-VM scenario with durable team mailboxes.
Two workers each send a finding. While the lead waits for approval, operator
commands inspect both messages. A new service restores the lead's original
root identity under a new current run ID and receives/acknowledges both findings.
A third VM confirms completion, acknowledgement and no worker replay, within
a shared nine-model-request budget with all 18 tokens accounted for.

`python3 -B scripts/release_smoke.py _build/prod/zekkyou-0.0.1-dev.tar.gz`
passed at the mailbox baseline (`e9eb3cd`) against the extracted release in a
separate directory containing spaces, with system Erlang/Elixir/Mix absent from PATH. It runs the execution, checkpoint
and team smoke scenarios through the bundled CLI, checks exact forwarding of
task text containing shell syntax and newlines, rejects invalid configuration and
duplicate service ownership, verifies private state, and confirms that a crash
after an external file effect parks the task across subsequent restarts. SIGTERM
to the main PID exits the VM and removes its listener socket.

`python3 -B scripts/systemd_smoke.py _build/prod/rel/zekkyou` passes against a
temporary local user unit. systemd restarts the killed main VM, admitted delayed
work completes, and another restart preserves task status, session identity and
event history. Stopping the unit leaves it inactive and removes the socket.
The unit template also passes `systemd-analyze verify` with its installation
paths substituted for this build. No persistent unit was installed or enabled.

SSH tests use a controlled executable that binds a real local Unix socket.
They check OpenSSH arguments, private directory permissions, owner death,
startup timeout, cleanup and actual child OS-process termination. These tests
exercise transport management; they do not constitute remote-host qualification.

Workspace qualification includes concurrent real file-tool edits to the same
tracked path in separate child clones, with distinct captured patches and an
unchanged source. Git checks cover clean source admission, source-local filter
rejection, inherited configuration isolation, ignored build caches, resource
bounds and tampered metadata/patch detection. Resource checks cover killed
creation and worker use, continuation-grant interruption, non-evictable retained
workspaces, stale cleanup and callback-result preservation after ledger failure.
Two standalone Alto VMs verified exact frozen-patch recovery and fenced cleanup.

`python3 -B scripts/workspace_smoke.py _build/prod/rel/zekkyou/bin/zekkyou-cli`
passes for this increment against the bundled runtime: named workers make
independent edits, source content stays unchanged, a fresh service VM returns
identical patches through CLI inspection, stale discard is rejected, and exact
revision cleanup succeeds. The full bundled regression rerun was not completed
for this increment; the broader release result above is the previous baseline.
The current `release_smoke.py` includes this workspace scenario for future full
qualification. Live providers and remote hosts remain unqualified.

## Reviewed patch integration increment

Alto `e40a99b` passes 733 tests, format checks and production compilation.
Its prepared-patch tests cover read-only preparation, unchanged staging,
disjoint integration, stale content/mode/HEAD/config rejection, renamed paths,
additions/deletions/binary patches, special filenames, artifact tampering,
revision fencing and retained interruption metadata. Three separate Alto VMs
verify portable preparation, application after restart, recovered application,
replay rejection and explicit cleanup.

Zekkyou passes 63 tests, including scoped patch review/application, opt-in worker
file-write policy, and two named coding workers integrated through repeated
approvals with service restarts. `scripts/patch_integration_smoke.py` passes
against the current CLI across four fresh service VMs: pending approvals recover
exactly, each worker runs once, the Git index remains unchanged, and applied
resources can be inspected and discarded after another restart. The strengthened
service test also exercises model-driven worker file calls and inherited exposure.

All 13 terminal tests pass. The full relocated bundled-release regression passes
with no system Erlang/Elixir/Mix on PATH, including scheduling, approvals,
teams, mailboxes, workspace capture, the new four-VM patch scenario, crash review
and shutdown cleanup. Its restricted utility list now includes `sync` for durable
patch storage and `kill` for process-group cleanup. Format checks, warning-free
production compilation and the bundled build pass. Live providers and remote
hosts remain unqualified.

## Mailbox retained-state cleanup increment

Alto `e487d8e` passes 740 tests, format checks and production compilation.
Queue compaction preserves exact live records, active claims and native owner
metadata, delayed work, recovery identities, ordering, record-ID progression
and the configured completed-key window. Tests cover automatic bounded-log
churn, full retained-state refusal without replacement, opt-out behavior,
corrupt/incomplete snapshot rejection and torn later-append repair. Two separate
VMs recover equal retained values and successfully use the original live lease.

Zekkyou passes 65 tests including mailbox churn beyond the log-size limit,
retained unread messages and claims across restart, completed-key deduplication,
manual compaction and configuration validation. The mailbox team qualification
now compacts unread worker messages before restart and completed markers before
a further restart, checking identical messages and no worker replay.

The full relocated bundled-release regression passes with this scenario,
including scheduling, exact approval recovery, teams, workspace capture,
reviewed patch integration, crash review and shutdown cleanup. Format checks,
warning-free production compilation and the bundled build pass.

## Separate child session increment

Alto `04e78f3` passes 744 tests, formatting and production compilation. Its
optional separate-session policy creates independent child transcripts, exact
parent/run/identity links and delegation result pointers. Tests verify separate
transcript contents and revisions, parent isolation, shared default behavior,
summary ownership and absence of child storage for unrecorded parents. Two
fresh VMs verify exact parent and child transcripts, history and ancestry.
The existing authority, shared budget and cancellation regressions also pass.

Zekkyou exposes the option through its team policy. Independent child
checkpoints, durable shared budgets and recovered parent joins remain pending.

The 65 service tests pass, including separate worker transcript storage and
completed-session follow-up. All 13 terminal tests pass with the original
recorded seed. An earlier terminal transcript timeout did not reproduce in the
seeded suite or 20 repeated integration runs. A proposed production change was
discarded because its regression also passed the original code; the terminal
test now reports state on a future timeout without relaxing its assertions.

The full relocated bundled-release regression passes against this Alto pin.
The strengthened team qualification also passes separately against the bundled
CLI with `sessions: :separate`, both with and without mailboxes: child summaries,
transcripts and CLI histories are identical across the lead's approval restart
and another service restart after completion. Workers execute only once. The
full regression's team scenarios now include these additional checks.

## Remaining qualification and limits

- No live model provider, remote SSH daemon, or Discord integration was tested.
  Only a temporary local systemd unit was exercised; no persistent service or
  systemd unit was installed on this machine.
- Completed history survives restart. Interrupted work is not automatically
  retried. Checkpoint-enabled approvals survive service restart; Socket approvals
  retain their live-wait contract. Scheduled attempts with uncertain outcomes
  park for explicit operator decisions. Recovery tests cover a real file effect
  committed before a crash, repeated revision-fenced retry grants, full-queue
  retry admission, and cancellation on both sides of the queue/ledger boundary.
- Saved transcript snapshots show the latest 100 messages; activity retains
  the latest 500 loaded events. Pagination, truncation and gaps are explicit.
  This client does not render token-by-token streaming. Usage comes from
  completed resident runs; it is not a durable billing ledger.
- Session logging retains Alto's best-effort contract. A gap-free cursor does
  not prove all execution events were written; corruption and oversized logs
  fail explicitly. Failed sends are never retried automatically.
- Custom loops must declare checkpoint reconstruction, and exact snapshots
  reject live capabilities or incompatible code/configuration. Independently
  suspended child runs remain unsupported. Waiting for approval pauses active
  execution time; consumed budget counters are preserved.
- Named teams, durable addressed mailboxes and optional isolated workspace capture are implemented.
  Independent child lifecycle/recovery,
  memory/skills, messaging adapters and
  live remote qualification remain pending. No changes were pushed or published.
