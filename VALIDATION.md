# Development checkpoint — 2026-09-10

Current Alto source: published commit
`a339e5a57aefcea4b634c6fc6a8a4d3eb0029f69`, pinned in both the service and
terminal dependency declarations and lockfiles. Fresh builds use the Git
dependency directly. The sections below retain earlier development checkpoints;
the latest validation is recorded at the end.

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

## Durable shared count-budget increment

Alto `f56da63` passes 764 tests, formatting and production compilation.
Tests cover retained-checkpoint CAS updates, stale revisions, full-log refusal,
terminal-state fencing, torn-tail repair and duplicate update rejection. Budget
tests cover concurrent caps, generation binding, consistent reads, reopening
without widening, tightening existing handles, ledger failure, closure and key
reuse, and restored runners sharing charges made after the saved snapshot.
Approval continuation retains the exact prepared value across a ledger restart.
Three separate VMs verify an old snapshot cannot replenish model calls: a later
charge remains consumed, two restored handles share one remaining call, and a
third VM recovers the exhausted allowance.

These are durable count budgets. Coordinated child active-time accounting,
durable child dispatch and parent joins remain pending.

Zekkyou passes 66 service tests and 13 terminal tests with the recorded seed.
Task failure explanations are now retained as bounded text in durable evidence,
including budget denials. Tests verify their size, UTF-8 validity and survival
across service restart.

The relocated bundled regression passes with the new budget scenario included.
Four fresh service VMs share a two-request account through trusted profiles:
the first two jobs invoke the provider once each, and later jobs persist an
explicit model-budget failure without invoking it again. The durable counter
remains two across configuration reloads. Scheduling, approvals, separate child
sessions, mailboxes, workspace capture/integration, crash review and shutdown
cleanup also pass against this bundle.

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

## Child journals and retained joins — 2026-09-10

Alto commit `1aa4ed3` adds optional durable child journals on the normal
`zekkyou/durable-host` checkout. Dispatch is recorded before execution, and
workers retain their exact bounded summaries before returning to the parent.
Completed results remain protected from ledger eviction until explicit join
acknowledgement and retirement. Zekkyou's team policy passes through the optional
trusted journal server; default profiles keep their existing behavior.

The full Alto suite passes **780 tests**. After a cold-observer decoding fix,
all **16 focused journal and runner tests** pass again. They cover concurrent
admission, concurrent completion of 64 children without exhausting attempt
history, ordered results, ledger restart, generation/result conflicts, record
bounds, nonportable values, retention pressure, stale acknowledgement and
interrupted retirement. Runner tests suspend the parent before child completion
and prove the worker's result is already durable without parent collection.
Forced child shutdown preserves cancellation while retaining an unknown verdict
and unresolved dispatch evidence. Runs without session logging still report
journal persistence failures.

Three independent Alto VMs execute two real fixture children, recover exact
native outputs and input order, refuse redispatch, retain a separate uncertain
dispatch, acknowledge/retire the completed batch, and verify retirement without
additional child calls. An initial final-observer check exposed missing loaded
result atoms; the journal now loads Alto's fixed runtime/usage vocabulary before
safe decoding. The corrected observer also passes with compilation disabled.
Stored data cannot select modules to load or create atoms. Additional custom
result atoms require their trusted defining code to be loaded.

Zekkyou passes **66 service tests** and **13 terminal tests** (seed 745605).
Its team test compares the retained native child summary to the actual result.
The terminal check uses the existing shared dependency directory; the initial
invocation without that setting stopped before tests because dependencies were
not found. Production compilation and formatting checks pass.

The full relocated bundled-release check passes, including real execution,
reconnect, scheduled work, exact approval continuation, team mailboxes,
independent workspaces, reviewed patch integration and durable shared budgets.
The team fixture now enables the child journal and compares its complete saved
packet across three service VMs alongside unchanged child histories, outputs,
provider-call counts and usage. Its retained join remains unacknowledged until
an explicit host consumption protocol is supplied; task completion does not
silently discard the journal.

Automatic restoration of an interrupted parent batch, independently suspended
children, coordinated active time and automatic journal/budget retirement are
still pending. The user requested stopping after this current step; remaining
roadmap items are deferred.

## Published runner migration — 2026-09-10

The service and terminal resolve the published Alto revision from Git with
`ALTO_PATH` unset. No Alto source was changed for this migration, and its upstream
test suite was not rerun here.

- **73 service tests** pass, including **22 focused migration tests**. Coverage
  includes trusted per-profile runner selection, scheduled Stepped execution and
  cancellation, inherited child runner options, and custom opaque handles with
  neutral results through the resident registry.
- **13 terminal tests** pass. Production compilation with warnings as errors
  and formatting checks pass for both packages. The service release builds.
- Workspace checks prove that manager-owned source and patch digest remain
  authoritative when backend metadata omits or tampers with equivalent fields.
  Legacy resources remain inspectable/exportable while mutation is refused;
  tests compare retained records and patch bytes before and after rejection.
- Legacy approval packets are retained exactly and cannot release an approval
  or denial grant through the shipped runners. Tests verify the terminal notice,
  absence of tool execution, and continued availability of explicit cancellation.
- The complete relocated bundled-release qualification passes. Fresh service
  VMs recover exact prepared approvals for Serial to Serial, Serial to Stepped,
  and Stepped to Serial, without repeating earlier effects. Serial and Stepped
  teams preserve separate child sessions, durable journals, shared usage/budgets
  and exact integration approval across restart.
- Existing bundle scenarios also pass: execution/reconnect, durable scheduling,
  mailboxes, isolated coding workspaces, two reviewed patch integrations across
  four VMs, durable budget enforcement, startup failures, exclusive state
  ownership, shutdown cleanup, crash review and private state.

A delegated final review found no must-fix issue. Upgrade compatibility limits
and reconciliation steps are documented in [the runner guide](docs/runners.md).
This migration does not implement the deferred roadmap items above.

## Resident child evidence recovery — 2026-09-12

Work resumed on milestone 5 using the same published Alto pin. Zekkyou now
supervises an opt-in child journal and offers bounded operator inspection and
exact result export. All lifecycle storage and validation use Alto's existing
OperationLog and Journal APIs; no Alto source was changed for this step.

- **79 service tests** pass (seed 846613), including six new child recovery
  tests. They cover partial batches across journal restart, exact exported
  bytes and decoded result equality, stale generations/revisions, concurrent
  completion between export pages, list pagination and retention exhaustion.
  Completed but unconsumed batches remain protected from eviction, and reads
  leave the complete retained snapshot unchanged.
- **13 terminal tests** pass (seed 643558). Service compilation with warnings
  as errors, production compilation, release assembly, formatting and diff
  whitespace checks pass. A restricted build initially could not open Mix's
  local socket; the authorized build and checks completed successfully.
- The new crash qualification passes for **Serial and Stepped**. A real child
  finishes with a result large enough to require multiple export pages; a
  second child writes an external effect and is killed before returning; a
  third remains undispatched. Two fresh service VMs retain exactly the same
  journal bytes and exported result, park the containing task for operator
  review, and do not repeat the plan or either child effect.
- The complete relocated bundled-release suite passes, including those crash
  scenarios. Existing team checks now use the supervised resident journal and
  inspect/export both child results through the actual CLI across approval
  suspension and two restarts. Cross-runner checkpoints, mailboxes, workspaces,
  reviewed patch integration, shared budgets and service shutdown/recovery
  regressions also pass.

The commands do not acknowledge joins, retire batches, or resume execution.
Automatic parent continuations, independent child checkpoints and coordinated
active-time accounting remain unfinished. Existing custom journal stores are
not rewritten or adopted automatically. See [team recovery](docs/teams.md) for
the configuration, retention and export contracts.

## Exact parent-batch continuation — 2026-09-12

Alto commit `f71d574a46e33011be288b2f38ee6e03231f4680` adds retained pending
and ready parent frames, exact checkpoint restoration, journal acknowledgement
and a single-use claim before downstream effects. It is committed in the normal
Alto checkout on `codex/parent-continuations` and is not published. Zekkyou pins
that revision and adds resident continuation/count-account stores, historical
store bindings, and the explicitly fenced `task-recover` operator command.

- **833 Alto tests** pass. New coverage includes continuation state transitions,
  stale generations/revisions, store/account/configuration binding, deadline and
  authority narrowing, pending/ready restoration, concurrent recovery and
  protection of the winning session's transcript from a losing recovery attempt.
  Alto formatting and production compilation with warnings as errors pass.
- **84 Zekkyou service tests** pass (seed 231870), including five parent recovery
  tests. They exercise resident store/account ownership, parent loss after child
  completion, service restart, exact single-use integration, stale operator
  fences, incomplete/claimed refusal, CLI validation, and removing a profile's
  continuation store without allowing generic retry to bypass historical state.
- The standalone fresh-process qualification passes for **Serial and Stepped**.
  The parent is suspended while a real child retains its result, then the process
  group is killed. A second service restores the exact parent through the CLI;
  a third verifies completion and join acknowledgement. Durable external
  counters prove exactly one plan, child effect and integration effect, with the
  same session throughout. This found and fixed cold-start callback loading and
  premature result decoding during admission.
- **13 terminal tests** pass (seed 283525). Service and terminal production
  compilation pass with warnings as errors after rebuilding the changed
  dependency artifacts. Service release assembly, formatting, Python syntax and
  diff whitespace checks pass. Build qualification uses the pinned Git checkouts
  with `ALTO_PATH` unset; the unpublished commit objects were imported locally
  from the normal Alto repository, so this does not establish remote availability.
- The **complete relocated bundled-release suite passes**, including exact
  parent recovery under both runners, uncertain child dispatch, cross-runner
  approval checkpoints, team mailboxes and compaction, isolated workspaces,
  durable reviewed patch integration, shared budgets, exclusive state ownership,
  cancellation/shutdown and interrupted-task review. The installed archive runs
  with system Erlang, Elixir and Mix absent from `PATH`.

Parent recovery currently requires a completed child batch or an already ready
parent frame. An uncertain dispatched child remains parked. A claimed frame
cannot be replayed after interruption; this provides an at-most-once grant, not
transactional exactly-once effects. Parent downtime consumes its absolute
deadline. Independently suspended children, coordinated active-time accounting
and explicit lifecycle retirement remain pending. Claimed continuations,
acknowledged journals and count accounts remain retained and may exhaust their
configured bounds. No source or release was pushed or published.

## Independent child approvals and lifecycle cleanup — 2026-09-12

Alto `3195d21` retains each child's exact approval checkpoint, explicit decision and
single-use resume grant in its journal. Parent recovery processes decided
children through the existing bounded batch coordinator. Undecided siblings
stay suspended; uncertain dispatched or claimed work is never silently repeated.
Separate and shared transcript ownership, workspace revisions, authority limits,
shared durable counts and absolute expiry remain fenced during restore. Named
worker providers resolve from the current trusted loop callback instead of
embedding resolved provider options in the child checkpoint.

Alto retirement commit `8289512` makes claimed-continuation retirement and budget
closure restartable. Zekkyou adds `team-child-approval`, `task-child-decide` and
`task-cleanup`. Cleanup saves its complete plan before making any resource
evictable, can finish after the original task record is evicted, and never closes
an explicitly shared profile account. Task admission refuses retained IDs so a
new generation cannot inherit an old continuation or budget.

The new four-VM CLI qualification passes for Serial and Stepped: two siblings
suspend, one is approved using its original prepared input after that input
changes, the other is denied after another restart, and integration runs once.
Cleanup retires the consumed batch and remains idempotent in a fourth VM.

- **853 Alto tests** pass, including concurrent child grants, losing-attempt
  transcript protection, repeated child suspension, exact sibling decisions,
  shared/separate sessions, workspace revision checks, absolute expiry and prompt
  cancellation of resumed children. Named provider tests rotate credentials
  without retaining them in the saved child profile. Production compilation with
  warnings as errors, formatting and diff whitespace checks pass.
- **98 service tests** pass (seed 975008). Ten lifecycle tests cover interrupted
  cleanup after task eviction, store and generation fences, replacement records,
  task ID reuse protection, account-only roots with no child journal, external
  account ownership, and refusal to retire unconsumed work. Four CLI tests cover
  invalid child decision, inspection and cleanup arguments.
- The named-team variant also passes across four fresh VMs under both runners,
  exercising Zekkyou's actual worker profile resolver and model-driven child
  approvals. The CLI checks reject stale task decisions without changing the
  child journal. These tests use deterministic local providers, not paid calls.
- **13 terminal tests** pass. Service and terminal production builds pass with
  warnings as errors against the pinned Git checkouts. The unpublished Alto
  objects were imported locally; fresh external builds still need `ALTO_PATH`.
- The **full relocated bundled-release suite passes**, including the new
  independent and named-provider child approval/cleanup scenarios under both
  runners, existing parent recovery, uncertain child dispatch, cross-runner root
  approvals, mailboxes, isolated workspaces, reviewed patch integration, shared
  budgets and shutdown/restart behavior. System Erlang, Elixir and Mix are absent
  from the installed archive's execution environment.

This is explicit approval-boundary recovery, not arbitrary process suspension.
Clock time while stopped still consumes the original absolute deadline;
coordinated pausable active-time accounting remains future work. Cleanup covers
consumed journals, claimed parent cells and task-owned accounts. Pending,
unconsumed and uncertain resources remain protected for reconciliation.
Transcripts, workspace patches and mailbox contents retain their own lifecycle.
Retirement releases retained-operation capacity when terminal records are evicted;
it does not compact append-only audit logs or remove their byte limits.
No changes have been pushed or published.


## Recovery boundary audit — 2026-09-12

Alto `6f4182083d13d49dfdce8014896041bb8809a690` is the audited local pin.
Its coordinating audit reports **864 tests passing**, formatting and production
compilation with warnings as errors. It validates child checkpoint restoration
before activating a workspace and admits resumed work under the workspace lock.
Rejected restoration or admission leaves workspace state unchanged. Successful
checkpoint fingerprint bytes remain compatible; unavailable durable identities
fail explicitly. Concurrent journal retirement can finish idempotently.

Zekkyou commit `26ded43` contains unavailable parent-store failures without
restarting Tasks, passes already bounded profile options into ParentRuns, treats
an explicit nil budget account as task-owned, and permits cleanup of ordinary
terminal profiles without a continuation store. The subsequent migration uses
Alto's validated continuation discovery, account and journal lookups, and
single-snapshot child approval inspection. Application cleanup manifests remain
Zekkyou-owned; saved store, generation, revision and join receipt fences remain
in force. Replacement generations are never retired by an older cleanup plan.

- **105 service tests pass** (seed 361503), including unavailable-store survival,
  ordinary terminal cleanup, nil-account ownership, and stale sibling approval
  views without mutating the retained checkpoint.
- **13 terminal tests pass** (seed 817766).
- Service and terminal production builds pass with warnings as errors against
  the pinned Git checkouts, with no `ALTO_PATH` override. Formatting and diff
  whitespace checks pass. Local Alto objects were imported for these builds;
  the commit is still unpublished and fresh external builds need `ALTO_PATH`.

Team's worker options are part of the parent fingerprint. Although child
packets omit resolved provider credentials, changing an embedded worker API key
invalidates the parent checkpoint before child provider resolution. Recovery
requires stable trusted configuration; this audit does not introduce arbitrary
credential rotation. The absolute-expiry, explicit-approval-boundary recovery,
uncertain-dispatch and audit-log retention limitations above still apply.

The **complete relocated bundled-release suite passes** against the audited pin:
independent sibling approvals and durable cleanup under Serial and Stepped,
named Team worker recovery, uncertain child evidence without redispatch, exact
parent continuation, cross-runner root approvals, mailbox retention, workspace
recovery, reviewed patch integration, shared budgets and interrupted shutdown.
The installed runtime runs without system Erlang, Elixir or Mix. No changes
were pushed or published during this audit.


## Alto publication status — 2026-09-12

The Alto audit task subsequently published the exact tested pin
`6f4182083d13d49dfdce8014896041bb8809a690` to `STACKSKB/alto` main for version
`0.0.1`; the release checkout's `origin/main` matches it. No Zekkyou code or
dependency pin changed. Earlier notes about unpublished objects describe the
validation environment at that time. Fresh builds now fetch the pinned Git
revision without requiring `ALTO_PATH`; that override remains optional for
local development. Zekkyou itself has not been pushed by this task.

## TUI selection and clipboard — 2026-09-16

Published Alto `f554634445c66bc56e5d656da973f7910c2f90a9` adds a shared
selection layer over the final rendered screen and OSC 52 clipboard output.
Zekkyou uses that layer for every visible pane, enables mouse reporting, and
routes bracketed/system clipboard paste to the sanitized composer without
submitting. Ctrl+C copies an active selection before the normal detach action;
Escape clears selection and resize discards stale coordinates.

Both dependency declarations and lockfiles now pin that published revision.
Validation with no `ALTO_PATH` override:

- Service: `mix test` — 105 tests passed.
- Terminal client: `mix test` — 16 tests passed, including every-pane copying,
  local-copy paste fallback, sanitized system paste, resize and Escape behavior.
- Upstream Alto: full suite — 872 tests passed; final TUI suite — 45 tests passed.
  TUI checks cover Unicode cell widths, reverse drags, frozen streaming views,
  masked popup fields, and selecting approval labels without activating them.

System clipboard writes require terminal OSC 52 support; native Shift+drag and
terminal copy remain available. Ctrl+V reads the local clipboard when a helper
is available, otherwise it pastes the last selection copied inside the client.

## Folder workspaces in the TUI — 2026-09-16

Alto `c2c0d44624dd009e8733234c61e7a38b95ada40e` provides a shared F7
folder dialog, a pinned New workspace action, saved-folder recall, and trusted
per-run working-directory selection. Zekkyou exposes `projects.list` and
`projects.open` on its private service transport, stores registered folders in
`projects.json`, and persists each admitted task's workspace identity and cwd.
Relative paths resolve on the service host. Follow-ups retain the saved session
folder, and an explicit mismatch is rejected before queue admission.

Task summaries now derive status, evidence and revision from one ledger snapshot.
This fixes a race exposed by lifecycle tests where a completed status could be
paired with an earlier revision and cause immediate cleanup to report stale state.

Validation:

- Alto: full suite, 877 tests passed (`--max-cases 1 --seed 920397`).
- Zekkyou service against the published Git pin: 108 tests passed.
- Zekkyou TUI against the published Git pin: 18 tests passed.
- Warning-free compilation and formatting checks passed.
- New checks cover narrow layouts, Unicode paths, invalid folders, draft
  preservation, saved-folder recall, real tool execution in a second folder,
  queued-folder persistence across restart, and cross-folder resume rejection.

Restart the service after upgrade to expose the new workspace commands.

## 2026-09-16 — bounded text selection and visible Copy actions

Published Alto `25a9445c53ea1bd1df243f5084c4f3dd6094417f` is pinned in
both dependency declarations and lockfiles. Mouse selection stays within the
starting widget's content, with borders and controls selectable separately.
Overlays exclude covered content. A visible Copy button and an unmodified
right-click Copy menu supplement Ctrl+C and Alt+C. Desktop clipboard writers
(`wl-copy`, `xclip`, `xsel`, `pbcopy`) precede OSC 52; unacknowledged terminal
requests are no longer reported as confirmed copies. The workspace action uses
an ASCII plus to avoid differing full-width glyph behavior between terminals.

Validation:

- Alto TUI: 56 tests passed, including pane clipping, reverse and Unicode drags,
  overlay exclusion, click safety, Copy controls, and fixed workspace-label cell
  positions across selection/copy at three viewport widths.
- Clipboard helpers: exact stdin roundtrip with a test executable, private-file
  cleanup, helper failures, and OSC 52/tmux fallback are covered by those tests.
  This does not validate a particular terminal emulator's clipboard permissions.
- Full Alto suite: 885 tests, two HTTP socket timeout failures, also seen with
  reduced concurrency. All TUI tests passed. The affected web-listener modules
  and TUI suite passed together in isolation: 86 tests, zero failures.
- Zekkyou service: 108 tests passed using the published Git dependency.
- Zekkyou TUI: 19 tests passed using the published Git dependencies, without
  `ALTO_PATH`, including pane-confined selection and mouse-driven Copy.
- Formatting and whitespace checks passed.

Relaunch the terminal client to load the updated code. Shift+right-click remains
controlled by the terminal emulator; use right-click without Shift for the TUI's
Copy menu.

## 2026-09-16 — responsive selection and content defaults

Published Alto `4914e0ff444dcdfb5776a9ed38aefa7dddd0acb2` replaces the
per-cell drag renderer with a cached, coalesced frame and highlighted text runs.
Both clients defer building their live view while a selection is active, so
mouse movement does not repeatedly format conversation history. Unicode width
probes are batched; clicks on non-selectable controls skip capture entirely.

Ordinary selection includes conversation content, context data, drafts and entered
form values. Controls, titles, status and empty-field hints require explicit
Alt+drag. Ctrl+Shift+A also follows the content policy; adding Alt includes UI.
Selection alone opens no toolbar or popup. Right-click opens one unframed Copy
menu row with a dim shortcut. Esc dismisses the menu before clearing selection.

Validation:

- Alto TUI: 59 tests passed, including content exclusions, approval click safety,
  Unicode/reverse drags, unchanged workspace positioning, and menu behavior.
- Regression coverage verifies that motion/repaint never rebuild the live view
  and that cached background spans scale with style runs, not terminal cells.
- Zekkyou TUI: 20 tests passed against the published Git dependencies, without
  `ALTO_PATH`. Service and terminal declarations/lockfiles use the same revision.
- `mix run scripts/tui_selection_bench.exs` measures selection events plus native
  drawing. At 240×70, the prior median drag frame was 32.8 ms (p95 40.6 ms).
  Updated measurements were 2.6–3.5 ms median (p95 4.4–7.8 ms). At 160×50,
  the median fell from 14.5 ms to 1.2–1.5 ms. Host load affects these values.
  One-time mouse-down capture remains; these measurements do not include a
  terminal emulator's own display latency.
- Formatting and whitespace checks passed. This revision changes the TUIs;
  the broader service/runtime suites were not rerun.

Relaunch the TUI to use the new renderer and menu. Terminal fonts have one cell
size; the shortcut uses a lighter, dimmed style rather than a separate font size.


## 2026-09-16 — readable approvals and faster selection bursts

Published Alto `3e33c0ee10428d61894d97514a22c8c4d8fc9a87` supplies the shared
approval formatter and faster selection renderer. Both declarations and lockfiles
pin that revision. Commands show prepared argv, folder, reason and execution
limits; file operations and generic tools use readable labels. Original approval
requests and decisions are unchanged.

Alto resets context scroll and clears a frozen selection when the active approval
changes, including advancing the queue. Zekkyou similarly reveals newly active
approvals, places them before transcript history in narrow layouts, and preserves
the user's scroll position during refreshes of the same approval. Its service
refresh timer now uses a distinct message instead of colliding with the terminal
runtime's internal poll message.

Selection caches full-row geometry and text indexes, slices only boundary rows,
and applies highlight colors without redrawing text. Consecutive drag events
coalesce to the latest position, preserving releases, copy keys, resize events
and other mailbox messages. An out-and-back drag cannot activate an approval
button even when intermediate positions were coalesced.

Validation:

- Alto TUI: 69 tests passed, covering readable native/remote requests, approval
  visibility in wide/narrow layouts and queue transitions, event ordering,
  Unicode, reverse drags and click safety.
- Zekkyou TUI: 22 tests passed with published Git dependencies and no `ALTO_PATH`,
  including a real runtime timer test and approval visibility in both layouts.
- At 400×120, median selection event plus native draw fell from 8.7 ms to 3.5 ms
  (p95 13.5 ms to 4.4 ms); highlight calculation fell from 3.8 ms to 0.011 ms.
  A burst of 200 pending drag motions rendered once in 5.9 ms. At 240×70,
  median drag time was 1.4 ms; at 160×50 it was 0.75 ms.
- These benchmark results exclude terminal-emulator latency. One-time mouse-down
  capture still costs about 89 ms at 400×120 (23 ms at 240×70); the improvements
  primarily target sustained dragging and rapid reversals. Host load varies.
- Formatting and whitespace checks passed. Service/runtime suites were not rerun
  for these terminal-only changes.

Relaunch both terminal clients to load the fixes.


## 2026-09-16 — selection capture, bounded scrolling and folder commands

Alto `f1dcffedae3f1033c553621f8fd411a83f45a5ce` is published on main and pinned
in both Zekkyou dependency declarations and lockfiles. Each major change was
committed separately in Alto and in the downstream client.

- First-run model discovery loads provider modules before checking optional
  callbacks. A cold-provider regression reproduces the previous false error.
- Selection exports compact screen text, freezes mutable inputs, indexes only
  boundary rows during dragging and reuses native capture buffers. Large plain
  paragraphs are cropped to their visible viewport so motion does not reflow
  off-screen history. Pane boundaries, Unicode and content-only defaults remain.
- Context scrolling uses the renderer's exact wrapping to cap offsets. Zekkyou
  also supports bounded context wheel scrolling and caps conversation scrolling.
- Ctrl+G N and the New task rail action start in the current folder. Folder
  changes use Ctrl+G W; Alto's task picker also offers a New task action. The
  separate F7 workspace shortcut and prominent New workspace action are removed.
- The folder picker highlights directory suggestions and completes with Tab.
  Zekkyou's new projects.complete command resolves paths on the service host;
  requests run asynchronously, and stale responses cannot replace newer input.

Validation:

- Alto TUI, provider discovery and CLI onboarding: 83 tests passed together.
- Zekkyou TUI: 25 tests passed against the published Git pin without ALTO_PATH,
  including bounded context scrolling, direct task
  creation, remote suggestions and stale-response rejection.
- Affected Zekkyou service/console tests: 9 tests passed against the published
  Git pin without ALTO_PATH, including real socket
  path completion and unchanged task-folder execution/persistence behavior.
- Published selection benchmark: at 240×70, first capture was 3.5 ms; reused
  mouse-down plus draw was 2.8 ms, with 1.3 ms median drag frames. At 400×120,
  first capture was 8.8 ms and reused mouse-down plus draw was 7.2 ms; median
  dragging was 3.7 ms. Measurements vary with host load and exclude terminal
  emulator display latency; the script reports first capture separately.
- A 10,000-line scrolled transcript previously took 39 ms per drag render.
  Caching its visible paragraph reduced that to 1.2 ms, similar to short history.
  Its first capture still took about 51 ms; that work no longer repeats while
  dragging. This remains a limitation for exceptionally long transcripts.
- Formatting and whitespace checks passed. Dependency lockfile changes are
  limited to the Alto / Alto TUI Git revisions.

Restart the TUIs and the Zekkyou service to enable service-host path completion.

## 2026-09-16 — selection autoscroll

Published Alto `d5c7de2c99f85f6ab0498de8863eae78ef10e6e8` adds edge-held
selection scrolling shared by both terminal clients. Zekkyou handles its scroll
timers and preserves the resulting conversation/context offsets after copying.
Both dependency declarations and lockfiles use the published revision.

- Hold the drag at a pane's top/bottom to scroll, or use the wheel while holding.
  Going farther beyond the edge increases speed. Moving inside, releasing,
  losing focus or reaching content bounds stops scrolling.
- Copy includes off-screen rows and stays confined to the originating pane;
  reversing direction, wrapped text and wide Unicode glyphs are covered.
- Alto's approval panes and compact drawers scroll without activating controls.
- Alto TUI: 82 tests passed. Zekkyou TUI: 26 tests passed against the published
  dependencies without ALTO_PATH. Service/runtime code did not change.
- Selection event handling plus native draw remained approximately 1.4 ms median
  at 240×70 and 3.8 ms at 400×120. Those measurements cover pointer motion within
  the viewport, exclude terminal-emulator latency and vary with host load.
  Advancing the viewport still requires rendering newly exposed source text.
- Formatting and whitespace checks passed; dependency lock changes are limited
  to the Alto and Alto TUI Git revisions.

Restart both TUIs to load this change.

## 2026-09-16 — symmetric selection, activity and reasoning controls

Alto `3e5a9422ca2a635f5d8412eea2676d26752e9b73` is published on main and
pinned in the service and terminal package declarations and lockfiles. Scroll
speed and activity feedback were committed separately from reasoning controls.

- Selection scrolls one row per tick in both directions. The previous distance
  acceleration was asymmetric in practice because there is more screen space
  below the conversation pane than above it.
- A conversation-border indicator animates and shows elapsed time while waiting
  for connections, model output, service responses or tool work. It is outside
  the default selectable content. Reasoning events update the stage to thinking.
- Alto uses Ctrl+G R for effort; Zekkyou uses Ctrl+G E, retaining R for reconnect.
  Choices come from model capabilities, including a cold catalog fetch in Alto.
  Provider default remains available, and unknown capabilities are not guessed.
- Zekkyou discovers capabilities on the service host. The service checks selected
  effort values at admission, records them with queued tasks, and supplies them
  to the configured provider. A follow-up can change effort without discarding
  earlier provider reasoning. Providerless profiles have no effort choices.
- OpenAI-compatible reasoning/summary deltas and Codex reasoning summaries appear
  separately from answers. Native Anthropic thinking is shown when the complete
  response arrives; that adapter remains non-streaming. Encrypted/redacted fields
  are not displayed. Signed provider content and reasoning fields survive tool
  turns, saved history and reconnects.

Validation against the published dependencies, without ALTO_PATH:

- Alto full suite: 926 tests passed.
- Zekkyou service full suite: 110 tests passed.
- Zekkyou TUI full suite: 28 tests passed.
- HTTP adapter fixtures check request fields and reasoning deltas; a fake Codex
  app server verifies effort and summary parameters. Real local socket service
  tests exercise effort rejection, execution, changed effort on follow-up,
  streaming reasoning and reconnect replay. No paid provider calls were made.
- Formatting/whitespace checks passed. Lockfile changes contain only the Alto /
  Alto TUI Git revisions.

API references used for the adapter contracts:
[OpenRouter reasoning](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens),
[Codex App Server](https://developers.openai.com/codex/app-server/),
[Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort).

Restart the service and both terminal clients to load these changes.

## Folder prefix completion — 2026-09-16

Published Alto `d05c400a4e3b04a013cc4f8a1291b31599a9a660` and pinned both
service and TUI dependencies to it. Tab now extends the typed path to the longest
common prefix of matching directories. `/hom` completes to `/home/` and lists
its folders; saved workspaces cannot override typed prefixes. Explicit arrow-key
or mouse choices still accept a specific folder. Empty input retains saved-folder
shortcuts without automatically completing to the working directory.

The service sends a prefix computed from every match while returning at most
50 display suggestions. Remote Tab presses wait for the current response and
trigger a child-directory refresh after completion; edits invalidate pending
completion. Existing stale-response checks remain in place.

Validation:

- Alto TUI suite: 92 tests passed, covering saved-workspace precedence, ambiguous
  and Unicode prefixes, nonexistent paths, more than 50 matches, and remote Tab.
- Zekkyou service suite: 110 tests passed against the published dependency.
- Zekkyou TUI suite: 29 tests passed against the published dependencies, including
  queued Tab and the follow-up directory refresh.
- Formatting and whitespace checks passed; dependency lockfile changes only
  update the Alto and Alto TUI revisions.

Restart the service and terminal clients to load the fix.

## Workspace sidebar navigation and mouse actions — 2026-09-16

Published Alto `a339e5a57aefcea4b634c6fc6a8a4d3eb0029f69` and updated both
service and TUI dependency pins. The sidebar action is now New workspace and
opens the shared folder picker by mouse. Clicking a workspace name prepares a
new task in that folder and focuses the composer while preserving its draft.
Ctrl+G N remains the keyboard shortcut for a new task in the current folder.

Alto workspace-header selection no longer automatically reselects the first
child task, which previously trapped upward navigation. Zekkyou displays workspace
headers and their task rows, with matching Up/Down and mouse handling. Selecting
a saved workspace preserves sidebar order; legacy tasks without registered
workspaces remain accessible. Scrolled mouse targets follow the rendered rows.

Validation:

- Alto TUI suite: 93 tests passed.
- Zekkyou service suite: 111 tests passed against the published dependency,
  including execution of a fresh task in a selected saved workspace.
- Zekkyou TUI suite: 31 tests passed against the published dependencies,
  including upward/downward navigation, workspace and task clicks, creating a
  workspace through the sidebar, draft preservation, and scrolled hit targets.
- Formatting and whitespace checks passed. Only Alto / Alto TUI revisions
  changed in the lockfiles.

Restart the terminal clients to load the updated sidebar.
