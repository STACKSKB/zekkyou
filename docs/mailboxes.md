# Durable team mailboxes

Grant `Zekkyou.Tools.Mailbox` to the lead and any worker profiles that need team
messages. As with other worker tools, the complete module/options pair must be
present in the lead's tools. The resident service supplies one bounded Alto queue
for all team messages. A custom service name uses the matching configured tool:

```elixir
{Zekkyou.Tools.Mailbox, queue: Zekkyou.Mailbox.queue(service_name)}
```

The default service and `examples/team.exs` can use the bare module. This is
internal agent communication; it does not send email or contact external users.

## Addresses and authority

Alto supplies an execution-tree identity to each tool call. The root has path
`[]`; a worker named `parser` has path `["parser"]`; a nested worker's path
extends its parent's path. Every member shares the root run ID. Each fresh root
execution, including a completed-session follow-up, gets a new namespace.
An exact approval continuation keeps the original namespace even though its
current run ID changes. The task view exposes this as `agent_identity`.

The model chooses the recipient path, message ID and body. It cannot supply the
root namespace, impersonate another sender, claim another recipient's messages,
or settle another recipient's claim. Address paths accept at most 16 segments,
each a nonempty UTF-8 string of at most 100 bytes. Addresses need not already be
running: sending to an unknown address stores a bounded pending message and
does not create or wake an agent. Include peer IDs in assignments when workers
need to communicate. Messages carry evidence, never permission to expand tools,
budgets or other authority. These are tool capability boundaries, not isolation
from arbitrary trusted native code or unrestricted shell access.

## Tool operations

Send a finding to the lead:

```json
{"action":"send","id":"parser-finding-1","to":[],"body":"The parser rejects empty input."}
```

Message IDs are unique per sender within the execution tree. Admission is
first-wins: reuse of an ID returns `duplicate: true` and keeps the original
recipient and body. Deduplication survives receipt, acknowledgement and restart
within the configured completed-message window; it is not an infinite history.

Receive up to five messages at the caller's address:

```json
{"action":"receive","count":5}
```

The result includes the caller's identity and queued records with `payload`,
`key`, `claim_id` and `lease_until_ms`. Receive returns immediately, including
when empty. Messages are selected in arrival order within this address, while
unrelated recipients stay untouched. The result contains a fitting prefix;
records that cannot fit are not leased invisibly. Repeated polling consumes
ordinary Alto execution/model budgets.

After handling a message, acknowledge its current lease:

```json
{"action":"ack","key":"received-message-key","claim_id":"received-claim-id"}
```

Use `"action":"release"` with the same fields to return it to pending. An
expired or superseded lease cannot acknowledge a new delivery. Unacknowledged
messages become eligible for redelivery after lease expiry, including across
service restarts. This is at-least-once delivery, not exactly-once processing of
effects performed while handling a message. Acknowledgements are explicit; the
host does not infer them from a model response or successful tool result.

## Inspection and limits

Use the task's `agent_identity.root_run_id` for operator inspection:

```sh
./zekkyou mailbox ROOT_RUN_ID
./zekkyou mailbox ROOT_RUN_ID --cursor NEXT_CURSOR
./zekkyou mailbox-get ROOT_RUN_ID MESSAGE_KEY
./zekkyou mailbox-cancel ROOT_RUN_ID MESSAGE_KEY
./zekkyou mailbox-compact
```

These are local operator commands with cross-address visibility within the
selected execution tree. Model tools have no equivalent cross-address read.
Listing scans one page of ten shared queue records and filters the requested
root; follow `next_cursor` even when the page's `messages` is empty. Inspection
does not reclaim leases. Cancellation accepts pending messages only and retains
their deduplication marker. Active claims must finish, be released, or be
reclaimed after expiry before pending cancellation can succeed.

Configure service-wide bounds using `Zekkyou.Config.new(mailbox: [...])`:

| Setting | Default | Range |
| --- | --- | --- |
| `auto_compact` | `true` | `true` or `false` |
| `max_messages` | 1,000 pending and claimed | 1–10,000 |
| `max_completed` | 10,000 retained identities | 1–100,000 |
| `lease_ms` | 30,000 milliseconds | 1,000–3,600,000 |
| `max_log_bytes` | 64,000,000 bytes | 64,000–256,000,000 |

IDs are at most 100 bytes, message bodies at most 32,000 bytes, and the complete
JSON-encoded envelope at most 32,000 bytes. Large escaped text can therefore
reach the envelope limit first. Receive accepts 1–10 messages and limits the
record array to 48,000 wire bytes, leaving room for identity and tool framing
under Alto's default 64,000-byte result limit. Configurations with a smaller
tool-result limit should account for this mailbox response size.

Alto owns atomic matching claims, leases, fencing, file synchronization, replay
and queue bounds. Zekkyou owns message envelopes, addresses, authority checks,
configuration and operator presentation. Queue state is private and durable;
capacity/log limits fail explicitly. Mailboxes enable Alto's automatic log
compaction: before a write would exceed the log bound, old history is replaced
with current live records and the configured completed-identity window.
`mailbox-compact` performs the same cleanup immediately and reports retained
counts and file sizes. It operates on the shared mailbox store, not one root.

Compaction preserves unread messages and active claims exactly; completed tasks
do not silently discard unread messages. Acknowledgement and explicit pending
cancellation remain the only message removal policies. There is no age-based
expiry. If retained state cannot fit, capacity still fails explicitly. Set
`auto_compact: false` to retain append-only queue history; explicit compaction
still replaces that history. Compacted queues use Alto log version 3 and cannot
be opened by earlier Alto releases. Independent child recovery remains pending.

`python3 -B scripts/team_smoke.py` exercises both ordinary teams and mailbox
teams across fresh VMs: two children send findings, the lead suspends for
approval, a new service resumes its exact identity and receives/acknowledges
both findings, and a third service verifies completion without worker replay.
The bundled release qualification runs both scenarios with its own runtime.
