# Zekkyou

Persistent agents built on [Alto](https://github.com/STACKSKB/alto).
The service owns execution; terminal clients can disconnect without stopping
its agents. Linux and Elixir 1.18 / OTP 27 are the initial development target.

The [roadmap](ROADMAP.md) records the approved scope and ownership boundary.
Development is in progress; this is not yet the unattended-operation release.

## Development

The dependency pins Alto commit `262bd132a44e506ca103c09cef840fd3b5716b33`,
which adds durable replay, owner-bound runs and delayed queue scheduling on top
of the clean public v0.0.1 release. That revision is currently **local and
unpublished** on `zekkyou/durable-host`. Until it is published, set `ALTO_PATH`
to the integrated checkout; fetching this revision from GitHub will not work.
Local development uses `.work/alto`, an independent Git repository whose history
starts at the public release. This ignored directory is not part of Zekkyou's
source distribution. Keep or transfer that Alto branch alongside Zekkyou.

```sh
export ALTO_PATH="$PWD/.work/alto"
mix deps.get
mix test
mix escript.build
python3 scripts/smoke.py
```

Alto commits: `0ea2ec0` (durable replay and owner lifetime), `d9604e2` (due times
and fenced rescheduling), `262bd13` (fresh-VM replay without unsafe term decoding).
Scheduling primitives are available in Alto; the
Zekkyou unattended-task policy is a later milestone.

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
service running. Restart recovery of interrupted work is a separate roadmap
milestone: current Alto sessions resume only from completed transcript snapshots.

State defaults to `$XDG_STATE_HOME/zekkyou` or `~/.local/state/zekkyou`.
Its socket and state are private to the service account. Use `--socket PATH`
on clients when choosing another state directory.

The `runtime:` configuration field accepts a server-side `Zekkyou.Runtime`
adapter. The default composes Alto's registry and socket listener; its execution
profiles remain ordinary `Alto.Config` values. Native terminal UI libraries are
not dependencies of this service.

## Remote access

Run the service on the remote machine under a persistent service manager. Use
OpenSSH Unix socket forwarding to expose its socket locally:

```sh
ssh -N -L /tmp/zekkyou-remote.sock:/home/agent/.local/state/zekkyou/service.sock agent@host
./zekkyou status --socket /tmp/zekkyou-remote.sock
```

Choose a socket in a private local directory on a shared machine. SSH handles
authentication and encryption. A dropped SSH connection affects the client,
not the remote resident service.

## Validation boundaries

Automated tests exercise local service/client contracts without live providers.
The executable smoke check uses real files and independent service/client VMs,
including a service restart. See [validation results](VALIDATION.md).
Real provider, SSH and Discord qualification is tracked separately in the
roadmap. No hosted CI or publishing is performed by this development work.
