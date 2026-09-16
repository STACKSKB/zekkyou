# Install the resident service

The service release bundles Erlang, Elixir, Alto and Zekkyou. The target does
not need Mix, a source checkout, or a system Elixir installation. Build for the
target's architecture, Linux distribution and shared libraries; the archive is
not a portable binary for every Linux host. The target still needs a POSIX shell,
standard core utilities (including `sync` and `kill`), `flock` (util-linux),
Git for coding workspaces, and the runtime's shared libraries
(including OpenSSL). Configured tools may have further requirements.

The optional terminal client is packaged separately. It is not included here.

## Build and qualify

From the Zekkyou checkout, build against the published Alto commit
`f1dcffedae3f1033c553621f8fd411a83f45a5ce` pinned in the dependency lockfile.
No local Alto checkout or path override is required:

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix release --overwrite
python3 -B scripts/release_smoke.py _build/prod/zekkyou-0.0.1-dev.tar.gz
```

The build creates `_build/prod/zekkyou-0.0.1-dev.tar.gz`. It includes example
configurations, this guide, the systemd template and task documentation.
The qualification script extracts that archive into a temporary directory,
runs with system Erlang/Elixir/Mix absent from `PATH`, and checks execution,
restart, durable approvals, interrupted work and private state. It does not
install or enable a service. Build and test before copying the archive to a host.

Use `bin/zekkyou-cli` for both the resident service and one-shot client commands:

```sh
bin/zekkyou-cli serve /absolute/path/to/service.exs
bin/zekkyou-cli tasks
```

This launcher starts a foreground process and disables Erlang distribution.
The generated `bin/zekkyou` script is runtime tooling; its generic `start`
command does not load a Zekkyou service configuration. Use the CLI launcher or
the unit below. Stop the foreground process with SIGTERM or its service manager.

## Install under your user account

Use a new directory for each build. These commands illustrate the first local
installation; replace the build directory name for subsequent installations.
They assume the archive was copied to the current directory on the target.

```sh
install -d -m 700 "$HOME/.local/opt/zekkyou/0.0.1-dev-build1"
tar -xzf zekkyou-0.0.1-dev.tar.gz -C "$HOME/.local/opt/zekkyou/0.0.1-dev-build1"
ln -s 0.0.1-dev-build1 "$HOME/.local/opt/zekkyou/current"
install -d -m 700 "$HOME/.config/zekkyou" "$HOME/.config/systemd/user"
install -m 600 "$HOME/.local/opt/zekkyou/current/examples/service.exs" \
  "$HOME/.config/zekkyou/service.exs"
install -m 600 "$HOME/.local/opt/zekkyou/current/deploy/service.env.example" \
  "$HOME/.config/zekkyou/service.env"
install -m 644 "$HOME/.local/opt/zekkyou/current/deploy/zekkyou.service" \
  "$HOME/.config/systemd/user/zekkyou.service"
```

Edit `service.env` with an **absolute** workspace path, provider URL, model and
credentials. systemd environment files are assignments, not shell scripts:
do not use `export`, `~`, `$HOME`, or command substitution. Keep the file mode
0600 and its directory 0700. Edit the trusted `service.exs` to declare the
profiles, tools, approval policy and execution limits you intend to allow.
Configurations are executable Elixir code; use files you control.

For a provider-free first check, use `examples/inspect.exs` as `service.exs` and
set only the workspace in the environment file. It runs Alto's real directory
inspection tool. The supplied unit uses the default state directory at
`~/.local/state/zekkyou`; an explicit `ZEKKYOU_STATE_DIR` can override it.

```sh
systemctl --user daemon-reload
systemctl --user enable --now zekkyou
journalctl --user -u zekkyou
"$HOME/.local/opt/zekkyou/current/bin/zekkyou-cli" tasks
```

The CLI must use `--socket /absolute/state/path/service.sock` when the service
uses a nondefault state directory. A second service cannot own the same state.
No service is installed or enabled by building or extracting the archive.

On a remote host, the user service manager must remain alive after logout;
configure lingering according to that host's administration policy. SSH client
disconnection does not stop the unit. Check this on the actual remote host.

## Stop, restart and upgrade

`systemctl --user stop zekkyou` stops the whole service group, including tool
processes. The unit restarts failures after five seconds. SIGTERM allows orderly
shutdown; systemd forcibly terminates processes still alive after 30 seconds.
Work interrupted during shutdown may require operator review after restart.

Durable queued work and checkpoint-enabled approvals survive restarts. An
uncertain dispatched effect is parked for explicit reconciliation, never silently
repeated. Socket approval policies still wait in memory. See
[`docs/tasks.md`](../docs/tasks.md) for approval and reconciliation commands.

Read the [runner migration notes](../docs/runners.md) before upgrading from the
old durable-host build: pre-refactor approval packets and retained workspace
source layouts need explicit reconciliation.

For an upgrade, stop the unit first, keep a private backup of the complete state
directory and trusted configuration, and extract the new build into a separate
version directory. Switch `current` to that directory, then start the unit and
inspect task status and logs. Keep the old release until qualification succeeds.
Do not overlay files into a running release or start two versions on one state
directory. Pending exact continuations require compatible code/configuration;
resolve them before an incompatible upgrade. Rolling back executable files does
not undo external effects or make newer state compatible with an older release.

Local unit qualification, when a user systemd manager is available:

```sh
python3 -B scripts/systemd_smoke.py _build/prod/rel/zekkyou
```

This uses a temporary transient unit and private temporary state. It checks
automatic restart, durable work and shutdown without enabling a persistent unit.
Remote logout, live providers and remote SSH still require host qualification.
