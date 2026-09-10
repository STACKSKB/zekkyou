# Running under systemd

`zekkyou.service` is a user service template; it is not installed automatically.
Adjust its working directory and executable path for your installation. Copy
your trusted config to `~/.config/zekkyou/service.exs` and put environment values
such as `ZEKKYOU_WORKSPACE`, provider URL/model and secret key in
`~/.config/zekkyou/service.env` (mode 0600, parent directory 0700).

Install the template at `~/.config/systemd/user/zekkyou.service`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now zekkyou
journalctl --user -u zekkyou
```

On a remote host, your user service manager must remain alive after logout;
configure lingering according to that host's administration policy. SSH client
disconnection does not stop the unit. `KillMode=control-group` ensures a stopped
unit also stops processes started by tools.

Service restart currently preserves completed session history and reports
interrupted executions; it does not automatically resume interrupted work.
Durable queue admission, parked approvals and application recovery are later
roadmap work. The template alone does not provide those guarantees.
