# Isolated worker workspaces

Alto owns workspace creation, worker lifetime, patch capture and recovery.
Zekkyou supplies the resident resource ledger and team configuration:

```elixir
state_dir = System.fetch_env!("ZEKKYOU_STATE_DIR")
manager = Zekkyou.Workspaces.manager(state_dir)
loop = Zekkyou.Team.loop(
  workers: workers,
  max_children: 4,
  max_concurrency: 2,
  workspaces: manager)
```

Use the same `state_dir` in `Zekkyou.Config.new/1`. A service started with a
custom name must pass that name as the second argument to `manager/2`.
Profiles without a workspace manager continue to use their configured cwd.
Only trusted configuration selects a manager; plans cannot choose directories.

The source must be a clean ordinary Git repository. Each worker receives an
independent clone of the same captured commit. Its index and Git metadata are
separate from both the source and other workers. Standard file tools operate
inside that worker's checkout. Unrestricted commands and custom tools retain
their configured authority; clones do not provide process-level sandboxing.

Workers inherit the parent's approval policy. The opt-in
`Zekkyou.Approvals.CodingTeam` policy permits `WriteFile` and `EditFile` only in
an active checkout owned by that worker. It denies other approval-requiring
worker tools and suspends lead effects for durable approval. Independent child
approval recovery is still pending. The [coding-team profile](../examples/coding-team.exs)
configures this policy, the same manager and scoped patch tools together.

After a child finishes, its result includes a workspace ID, revision, status,
source snapshot and frozen patch hash. Capturing the patch leaves the source
checkout unchanged. The lead can inspect full patches with `review_worker_patch`
and request `apply_worker_patch` with the saved workspace ID and revision.
Both tools enforce the host's execution-tree identity and source directory;
workers cannot apply their own patches or inspect another team's resources.

Alto prepares a portable approval manifest containing the patch hash, repository
identity and affected-file snapshots. Approval after a restart uses that exact
manifest. Changed content, modes, repository HEAD or configuration invalidate
it. Applying disjoint patches preserves unrelated files and the Git index.
Success retains an `applied` resource; a failure after dispatch is uncertain and
remains available for operator review without automatic retry. Locks coordinate
this manager's applications; unrelated editors are not locked out. Application
is not a multi-file rollback transaction.

The approval view includes affected filenames, the full patch hash and a bounded
preview. Read every chunk through the review tool or operator export for the full
patch. Standard terminal and CLI task approval controls answer the saved request.

## Operator inspection and cleanup

```sh
./zekkyou workspaces
./zekkyou workspace WORKSPACE_ID
./zekkyou workspace-patch WORKSPACE_ID
./zekkyou workspace-patch WORKSPACE_ID --cursor NEXT_CURSOR
./zekkyou workspace-discard WORKSPACE_ID --revision VIEWED_REVISION --note "Reviewed and no longer needed"
```

Patch responses contain base64 chunks of up to 24,000 original bytes, the full
patch's SHA-256 and byte count, and the next byte cursor. Concatenate decoded
chunks and verify the full hash when exporting a patch. This preserves exact
bytes and keeps each socket response bounded.

Ready, worked, frozen, applied and interrupted workspaces remain retained until an
explicit discard. Discard rejects a stale revision or a workspace still locked
by a live worker. Restarting the service preserves resources; it does not
silently restart interrupted creation, worker execution or capture. A retained
resource is evidence for inspection, not proof that the child succeeded.

Configure storage limits with `Zekkyou.Config.new(workspaces: [...])`:

```elixir
workspaces: [max_retained: 128, max_log_bytes: 64_000_000]
```

Held resources cannot be evicted to admit more work. Explicitly discard reviewed
resources when capacity is exhausted. Independent child job recovery remains outstanding.

The deterministic local qualification script is
`python3 -B scripts/workspace_smoke.py [PATH_TO_ZEKKYOU_CLI]`. It checks named
workers, an unchanged source, recovered patches and fenced operator cleanup
across fresh service VMs without a model-provider account.
