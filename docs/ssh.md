# SSH Unix socket forwarding

`Zekkyou.SSH.open/3` starts a managed OpenSSH process that forwards a local
Unix socket to an absolute remote Unix socket:

```elixir
{:ok, tunnel} = Zekkyou.SSH.open("user@example", "/run/alto/service.sock")
local_socket = Zekkyou.SSH.path(tunnel)
# ... pass local_socket to the client ...
Zekkyou.SSH.close(tunnel)
```

OpenSSH is launched with argument vectors (there is no shell interpolation),
`BatchMode`, `ExitOnForwardFailure`, and keepalive options. The system OpenSSH
known-hosts and host-key verification policy remains in force. Hosts beginning
with `-` or whitespace, and remote paths that are relative, contain whitespace,
control characters, or `:`, are rejected because they cannot safely represent a
Unix-socket forwarding specification. A numeric `:port` option is supported.
The `:ssh` option may select a trusted executable; otherwise the SSH path is
resolved with `System.find_executable/1`. Startup timeout, diagnostic size,
and keepalive values are type-checked and bounded.

Each tunnel gets a fresh mode-0700 directory below the system temporary
directory. The directory and SSH process are removed when `close/1` is called,
when startup times out, or when the process that called `open/3` exits. Startup
waits only for the configured timeout (5 seconds by default), and captured SSH
diagnostics are bounded to 4096 bytes. The `:ssh` option exists for trusted test
executables and should not be exposed to untrusted input.

The repository tests use a local fake executable to exercise argument handling,
startup, timeout, cleanup, and owner-death behavior. There is currently no
`sshd` available on the test host, so qualification against a real SSH daemon
is still pending.
