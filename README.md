# Zekkyou

Persistent agents built on [Alto](https://github.com/STACKSKB/alto).
The service owns execution; terminal clients can disconnect without stopping
its agents. Linux and Elixir 1.18 / OTP 27 are the initial development target.

The [roadmap](ROADMAP.md) records the approved scope and ownership boundary.
Development is in progress; this is not yet the unattended-operation release.

## Development

The dependency and lockfiles pin Alto commit
`fade95e64689ea511c924db5a6b206cf5416b94e`, which includes exact parent-batch
continuations, independent child approvals and explicit resource retirement
for the Serial/Stepped runners, plus shared TUI screen selection, clipboard support,
and the folder workspace dialog.
This commit is published on Alto’s `main` branch for the `0.0.1` release.
Build directly from the pinned Git dependency:

```sh
mix deps.get
mix test
mix escript.build
python3 -B scripts/smoke.py
```

For local Alto development, the optional `ALTO_PATH=/absolute/path/to/alto`
override applies to both packages. Validate against the pinned commit before
upgrading persisted state. See
[runner selection and upgrade compatibility](docs/runners.md), particularly
for suspended approvals and retained worker workspaces.

Alto commits: `0ea2ec0` (durable replay and owner lifetime), `d9604e2` (due times
and fenced rescheduling), `262bd13` (fresh-VM replay without unsafe term decoding),
`8ecceaf` (resident summaries and bounded saved conversations),
`711aee9` (fenced cancellation/recovery and trusted application commands),
`ab97a1b` (durable approval checkpoints and exact continuations),
`ec5e3fa` (socket listener cleanup during supervised shutdown),
`da4d112` (bounded concurrent children, inherited authority and shared accounting).
Zekkyou now composes those primitives into bounded durable tasks with delayed
admission, cancellation, and explicit operator recovery. See [task commands](docs/tasks.md).
Durable tool approvals use Alto's explicit checkpoint contract.

Alto uses `flock` for cross-process state ownership. The server requires no
native terminal renderer. Provider and external tool requirements depend on
your trusted configuration.

For an installation that includes its own Erlang/Elixir runtime, build the
bundled service release with `MIX_ENV=prod mix release`. The archive includes
the CLI, examples and systemd unit. See the [installation guide](deploy/README.md)
for build qualification, configuration, restart and upgrade instructions.

Named [worker teams](docs/teams.md) can now plan bounded parallel assignments,
select configured worker models, and integrate results in the lead. The
`examples/team.exs` profile gives workers inspection tools and checkpoints the
lead's proposed file writes. Optional [durable mailboxes](docs/mailboxes.md)
support scoped team messages, receipt leases and operator inspection across
restarts. Optional [isolated worker workspaces](docs/workspaces.md) capture
independent patches and retain interrupted resources for review. The
`examples/coding-team.exs` profile permits bounded worker edits in isolated
checkouts, then has the lead review and request durable approval for patch
application. The team profile can also recover a completed child batch from
the lead's exact saved continuation through `task-recover`, without repeating
the plan or workers. Children can suspend independently for approval; inspect
their exact requests with `team-child-approval` and decide with
`task-child-decide`. Terminal tasks can retire consumed execution records with
`task-cleanup`.

## Run a resident service

Configure `ZEKKYOU_WORKSPACE`, `ZEKKYOU_PROVIDER_URL`, `ZEKKYOU_MODEL`, and
optionally `ZEKKYOU_API_KEY`, then:

```sh
./zekkyou serve examples/service.exs
```

The example allows workspace inspection. Add tools, approval policies and
budgets explicitly in your own configuration. Configurations are trusted Elixir
code evaluated on the server; clients can select a profile by name but cannot
submit executable configuration. Keep secrets in the server environment.

In another terminal:

```sh
./zekkyou start coding "Explain the repository and suggest the next change"
./zekkyou status
./zekkyou watch RUN_ID
./zekkyou history SESSION_ID
./zekkyou follow SESSION_ID coding "Now examine the tests"
./zekkyou cancel RUN_ID
```

To exercise the service without a model account, use `examples/inspect.exs`
instead. It performs a real bounded directory listing through Alto's tool
runtime. Submit it with `./zekkyou start inspect '{"path":"."}'`.

`start` returns the run and session IDs. `watch` displays live notifications;
`history` pages through persisted session events. Closing a client leaves the
service running. The durable `schedule` commands park interrupted attempts for
operator review. Explicit approval checkpoints and opted-in parent continuations
can restore suspended execution; ordinary follow-ups use completed transcripts.

State defaults to `$XDG_STATE_HOME/zekkyou` or `~/.local/state/zekkyou`.
Its socket and state are private to the service account. Use `--socket PATH`
on clients when choosing another state directory.

The `runtime:` configuration field accepts a server-side `Zekkyou.Runtime`
adapter. The default composes Alto's queue, operation ledger, consumers, registry and socket listener; its execution
profiles remain ordinary `Alto.Config` values and may select `runner:` and
`runner_options:`. See [runner configuration](docs/runners.md). Native terminal UI libraries are
not dependencies of this service.

## Terminal interface

The optional terminal package reuses Alto's terminal layout while connecting to
an independently running service. It has a task list, saved conversation,
activity history, composer, approval decisions, and run usage details. The
composer submits durable tasks; queued work appears before execution starts.

```sh
cd packages/zekkyou_tui
mix deps.get
mix test
bin/zekkyou-tui --profile coding
```

The launcher runs the compiled application with native libraries on disk; the
terminal package cannot use a single-file escript. It requires this source
checkout, its Mix dependencies, and Elixir. The service still has its own
standalone, native-free executable.

Use `--socket PATH` to select a service. Tab switches between tasks and the
composer; arrows select tasks, Enter sends, and Page Up/Down scroll activity.
Ctrl+N starts a new task, Ctrl+K requests cancellation, Ctrl+A approves the
shown decision, and Ctrl+D denies it. New approvals open at the top of the
context pane and display readable commands, folders, reasons and execution limits.
In narrow terminals, the approval appears above conversation history. Context
and conversation scrolling stop at their last useful wrapped row. For a task
requiring operator review, inspect its evidence and enter `/retry NOTE`, `/committed NOTE`, or `/failed NOTE`
in the composer. Decisions are revision-fenced across clients. Ctrl+Q detaches.
Press **Ctrl+G, N** to start in the current folder, or click a workspace name in
the sidebar to compose a new task in that folder. Up/Down traverses workspace
headers and their task rows; click a task to resume it.
Click **+ New workspace** or use **Ctrl+G, W** to open another existing folder. Enter a path on the **service host**; relative paths start at
its configured default workspace, and `~` uses the service account's home.
Tab extends the typed path to the longest common prefix of matching folders and
lists the next matches: `/hom` becomes `/home/`, regardless of saved workspaces.
Suggestions start unselected, and Enter opens the typed path. Down selects the
first suggestion; Up selects the last. The Enter hint changes when a suggestion
is selected. Typing or completing a path clears that selection. Up/Down followed
by Tab accepts a specific folder. Saved folders appear only with empty input. Suggestions come from the service host, including over SSH; a Tab
pressed while they load is applied when the response arrives.
Opening a workspace preserves your draft and prepares a new task. The details
pane shows the full working folder. Workspaces and queued folder choices survive
service restart; existing tasks and resumed conversations retain their original
folder. An SSH client uses folders on the remote host. Restart the service after
upgrading to make its workspace and path-completion commands available.

Close a workspace with **×** on its sidebar row or **Ctrl+G, X** for the current
workspace. Closing hides it without deleting files or task history, and running
work continues. Closed workspaces stay closed across reconnects; opening the same
folder restores its saved tasks. Closing the last workspace leaves the folder
picker available. Restart the service after upgrading to enable workspace closing.

Application errors and returned tool data appear as readable messages and labeled
fields, including provider explanations, HTTP status codes, exit codes, and paths.
The same formatting applies to reconnect notices and saved tool history. Ordinary
user and assistant messages retain their code and prose.

The conversation border shows animated activity and elapsed time while connecting,
sending, waiting for a model or service, thinking, and running tools. Provider
reasoning is shown separately as **THINKING** when readable text is supplied,
and reappears from saved history after reconnecting.

Use **Ctrl+G E** to fetch the configured service model's supported reasoning effort
levels, then arrows and Enter to choose. The choice applies to the next submission;
the service validates and records it with the queued task. Provider default keeps
the service profile's configuration. The selector does not expose credentials or
allow arbitrary model/provider changes. Restart the service after updating to
make the new `tasks.efforts` command available.

Drag to select conversation text, context data, your draft, or entered form
values. Each drag stays inside its starting box. Hold at the top or bottom edge
of a conversation/context pane to scroll, or use the wheel while holding the drag.
Both directions scroll at the same speed; moving inside or releasing stops.
Copy preserves the full selected range, including text now off-screen. Controls, titles, status bars,
and placeholder hints are excluded by default; **Alt+drag** explicitly opts into
UI text. **Ctrl+C** or **Alt+C** copies, and **right-click without Shift** opens
a compact Copy menu with a muted shortcut. Selecting text opens no toolbar or
popup. Esc dismisses the menu, then clears selection. Ctrl+Shift+A selects visible
content; adding Alt includes UI text. Dragging reuses a cached screen and updates
only highlight colors while the service continues running. Consecutive mouse
moves are coalesced to the latest position, so fast drags do not queue stale frames.
Copy uses `wl-copy`, `xclip`, `xsel`, or `pbcopy` when available, with OSC 52 as a
fallback. The status distinguishes desktop copies from unconfirmed terminal
requests. Shift+drag and Shift+right-click belong to the terminal application;
its own copy menu is separate from the TUI's selection. Paste with the terminal's
usual shortcut (often Ctrl+Shift+V or Cmd+V), or Ctrl+V with a local clipboard
helper (`wl-paste`, `xclip`, `xsel`, `pbpaste`). Without a helper, Ctrl+V pastes the
last TUI copy.
Paste focuses the composer and never submits automatically.

Ctrl+R reconnects after
a connection failure. Failed sends are never retried automatically; inspect
recovered task state before resending when delivery is uncertain.

The conversation shows the latest saved transcript (up to 100 messages), with
bounded activity history alongside it. Progress appears as Alto records events;
this initial client does not render token-by-token streaming. Durable tasks
retain their profile after restart; when following up on an older direct-run
session, choose the profile explicitly.
Profiles using `Alto.Approvals.Checkpoint` and an explicit `checkpoint_version`
persist pending tool approvals, release their worker slot, and survive service
restart. Ctrl+A/Ctrl+D also decide these saved approvals. Existing Socket
approval policies continue to use live waits. See [task and approval configuration](docs/tasks.md)
and the runnable `examples/approved-write.exs` file-write profile.

## Remote access

Run the resident service on the remote machine under a persistent service
manager, then connect using the optional terminal package:

```sh
bin/zekkyou-tui --ssh agent@host \
  --remote-socket /home/agent/.local/state/zekkyou/service.sock --profile coding
```

The client manages an OpenSSH forward in a private local directory. OpenSSH
uses your existing keys, agent, configuration and known-host checks. Configure
noninteractive authentication before launching the TUI. Ctrl+R opens a new
tunnel after a disconnect. Closing the TUI closes its tunnel; the remote
resident service continues running. See [SSH details](docs/ssh.md).

The CLI can also use a separately managed forward through `--socket PATH`.

## Validation boundaries

Automated tests exercise local service/client contracts without live providers.
The executable smoke check uses real files and independent service/client VMs,
including a service restart. See [validation results](VALIDATION.md).
Real provider, SSH and Discord qualification is tracked separately in the
roadmap. No hosted CI or publishing is performed by this development work.

Tool rows identify the file or command, show Git output, and display applied
edit/write diffs with normal line breaks. Long transcripts use cached wrapping
for selection and scrolling. Cache diagnostics separate the latest request from
cumulative usage; OpenRouter requests carry a stable session ID for cache affinity.
