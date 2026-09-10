# Development checkpoint — 2026-09-10

Alto source: public v0.0.1 plus local commits on `zekkyou/durable-host` in
`/home/three/code/alto`. The normal Alto checkout now contains the original
three integration commits and the new API commit
`8ecceaf3a84831c15616b71016b9f7ac52ed3f95`. Set `ALTO_PATH`
until the integrated revision is published.

## Automated checks

- Zekkyou: **17 tests passed**. Includes resident execution, private state,
  named profiles, correlated bounded socket requests, owner cleanup, malformed
  envelopes, disconnect/reconnect, two-client conversation consistency,
  follow-up context, persisted transcript after service restart, approval
  replay/selection, cancellation, and managed SSH process cleanup.
- Optional terminal package: **10 tests passed**. Covers CLI option validation,
  responsive layout, keyboard release handling, UTF-8 paste byte bounds,
  preservation of edits typed during submission, and running-task selection.
  A real ExRatatui headless terminal submits to a real resident service,
  detaches during execution, reconnects, and verifies the rendered answer.
- Alto: **618 tracked regression tests passed** with `--max-cases 4`.
  The focused API/CLI suite also passed **73 tests**, including run status and
  usage, latest-100-message transcript bounds, protocol validation, explicit
  oversized-reply errors, and fresh-VM event replay.
- Compilation with warnings as errors and formatting checks passed for the
  service and terminal package; Alto's core compilation passed as well.
- The terminal launcher was exercised in a real PTY through startup,
  connection-failure display, and Ctrl+Q teardown. The native renderer cannot
  load from a single-file escript, so the terminal uses `bin/zekkyou-tui`
  with compiled libraries on disk. The service remains a separate escript.

## Independent-process qualification

`python3 scripts/smoke.py` passes after building the service executable. It
creates an actual workspace file, starts a standalone service, invokes Alto's
real directory-listing tool from a separate CLI process, reconnects, stops the
service, then starts a fresh VM and compares saved event history and session
listing. The executable archive contains no ExRatatui dependency.

SSH tests use a controlled executable that binds a real local Unix socket.
They check OpenSSH arguments, private directory permissions, owner death,
startup timeout, cleanup and actual child OS-process termination. These tests
exercise transport management; they do not constitute remote-host qualification.

## Remaining qualification and limits

- No live model provider, remote SSH daemon, or Discord integration was tested.
  No persistent service or systemd unit was installed on this machine.
- Completed history survives restart. Interrupted work is not automatically
  retried. Pending approvals replay while the resident remains alive; durable
  approvals/checkpoints and conservative recovery are milestone 4.
- Saved transcript snapshots show the latest 100 messages; activity retains
  the latest 500 loaded events. Pagination, truncation and gaps are explicit.
  This client does not render token-by-token streaming. Usage comes from
  completed resident runs; it is not a durable billing ledger.
- Session logging retains Alto's best-effort contract. A gap-free cursor does
  not prove all execution events were written; corruption and oversized logs
  fail explicitly. Failed sends are never retried automatically.
- The concurrent Alto TUI task has separate uncommitted changes and new tests;
  those changes are outside these integration commits.
- Agent coordination, memory/skills, messaging adapters and unattended policy
  remain later milestones. No changes were pushed or published.
