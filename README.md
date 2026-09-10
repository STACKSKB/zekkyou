# Zekkyou

Persistent agents built on [Alto](https://github.com/STACKSKB/alto).
The service owns execution; terminal clients can disconnect without stopping
its agents. Linux and Elixir 1.18 / OTP 27 are the initial development target.

The [roadmap](ROADMAP.md) records the approved scope and ownership boundary.
Development is in progress; this is not yet the unattended-operation release.

## Development

The dependency pins Alto commit `711aee97db68b5ed50ddae3a55b61c3d16bf92b1`,
which adds durable replay, owner-bound runs and delayed queue scheduling on top
of the clean public v0.0.1 release. That revision is currently **local and
unpublished** on `zekkyou/durable-host`. Until it is published, set `ALTO_PATH`
to the integrated checkout; fetching this revision from GitHub will not work.
Local development uses the `zekkyou/durable-host` branch in the normal Alto
checkout, `/home/three/code/alto` on this machine. The first three commits were
made in an independent `.work/alto` checkout and have been imported into that
branch. Further Alto changes are committed in the normal Alto folder. The
branch starts at the clean public release; older development branches are kept.

```sh
export ALTO_PATH="/path/to/alto" # here: /home/three/code/alto
mix deps.get
mix test
mix escript.build
python3 scripts/smoke.py
```

Alto commits: `0ea2ec0` (durable replay and owner lifetime), `d9604e2` (due times
and fenced rescheduling), `262bd13` (fresh-VM replay without unsafe term decoding),
`8ecceaf` (resident summaries and bounded saved conversations),
`711aee9` (fenced cancellation/recovery and trusted application commands).
Zekkyou now composes those primitives into bounded durable tasks with delayed
admission, cancellation, and explicit operator recovery. See [task commands](docs/tasks.md).
Durable tool-approval checkpoints remain under development.

Alto uses `flock` for cross-process state ownership. The server requires no
native terminal renderer. Provider and external tool requirements depend on
your trusted configuration.

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
service running. The durable `schedule` commands park interrupted attempts for operator review;
current Alto sessions resume only from completed transcript snapshots.

State defaults to `$XDG_STATE_HOME/zekkyou` or `~/.local/state/zekkyou`.
Its socket and state are private to the service account. Use `--socket PATH`
on clients when choosing another state directory.

The `runtime:` configuration field accepts a server-side `Zekkyou.Runtime`
adapter. The default composes Alto's queue, operation ledger, consumers, registry and socket listener; its execution
profiles remain ordinary `Alto.Config` values. Native terminal UI libraries are
not dependencies of this service.

## Terminal interface

The optional terminal package reuses Alto's terminal layout while connecting to
an independently running service. It has a task list, saved conversation,
activity history, composer, approval decisions, and run usage details.

```sh
cd packages/zekkyou_tui
export ALTO_PATH="/path/to/alto"
export ALTO_TUI_LOCAL=1
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
shown decision, and Ctrl+D denies it. Ctrl+Q detaches. Ctrl+R reconnects after
a connection failure. Failed sends are never retried automatically; inspect
recovered task state before resending when delivery is uncertain.

The conversation shows the latest saved transcript (up to 100 messages), with
bounded activity history alongside it. Progress appears as Alto records events;
this initial client does not render token-by-token streaming. After a service
restart, choose the profile explicitly when following up on a stored session.
Approval replay currently survives client disconnects while the service is
alive; durable approval recovery belongs to milestone 4.

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
