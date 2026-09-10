# Foundation validation — 2026-09-10

Alto source: public v0.0.1 plus local commits through
`262bd132a44e506ca103c09cef840fd3b5716b33`, branch `zekkyou/durable-host`.
Zekkyou uses `ALTO_PATH=.work/alto` until the integrated revision is published.

## Automated checks

- Zekkyou: 10 tests passed. Covers resident execution, private state, named
  configuration resolution, disconnect/reconnect, history after service
  restart, correlated replies, timeouts, owner cleanup, malformed envelopes,
  and event count/byte bounds.
- Alto: 611 tests passed with `mix test --max-cases 4`. The first high-parallelism
  run encountered two HTTP fixture timeouts; the complete suite passed with
  reduced concurrency. No product timeouts were relaxed.
- Alto development and production compilation passed with warnings as errors.
- Zekkyou compilation with warnings as errors and both formatting checks passed.
- Standalone escript build passed; its archive contains no ExRatatui dependency.

## Independent-process qualification

`python3 scripts/smoke.py` passed after building the executable. It creates a
temporary workspace with an actual file, starts a standalone service, invokes
Alto's real directory-listing tool through a separate CLI process, reconnects
to inspect the result, stops the service, starts a fresh VM and verifies the
same saved event history and session listing. Temporary services and files are
cleaned up by the check.

This caught a replay bug that same-VM tests missed: exact saved terms can contain
atoms not loaded in the new VM. Alto now persists a readable JSON projection
alongside each encodable exact event payload, with a fresh-VM regression test.
The safe term decoder remains strict for older records.

## Limits of this checkpoint

- No live model-provider, SSH host, or Discord integration was exercised.
- SSH forwarding instructions and the systemd unit are installation templates;
  no persistent service was installed on this machine.
- Completed history survives restart. Interrupted executions are cancelled or
  discoverable as interrupted; they are not automatically retried/resumed.
- Session logging retains Alto's best-effort persistence contract. A replay
  cursor does not prove all execution events were written; corruption and
  oversized logs fail explicitly. Durable approval and recovery work remains
  in milestone 4.
- The full TUI, agent coordination, memory/skills and messaging adapters are
  later roadmap milestones.
- No changes have been published or pushed.
