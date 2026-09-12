"""Recover child evidence after killing a service during active delegation."""

import hashlib
import os
import signal
import tempfile
import time
from pathlib import Path

import checkpoint_smoke as service


CONFIG = r'''
defmodule ChildRecoverySmoke.Lead do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(_, _, _) do
    File.write!(Path.join(System.fetch_env!("ZEKKYOU_WORKSPACE"), "plans"), "1", [:append])
    agents = Enum.map(["done", "uncertain", "planned"],
      &%{id: &1, profile: "worker", task: &1})
    {:ok, %{message: JSON.encode!(%{agents: agents}), tool_calls: []}}
  end
end
defmodule ChildRecoverySmoke.Worker do
  @behaviour Alto.Loop
  def init(task, _) do
    Alto.Transition.continue(%{}, [Alto.Effect.invoke_tool(%{
      name: "child_effect", arguments: %{"id" => task}})])
  end
  def handle_event(%Alto.Event{type: :tool_completed}, state, _),
    do: Alto.Transition.stop(state, String.duplicate("retained finding ", 2000))
  def handle_event(event, state, _), do: Alto.Transition.error(state, event.type)
end
defmodule ChildRecoverySmoke.Effect do
  @behaviour Alto.Tool
  def name, do: :child_effect
  def schema, do: %{description: "fixture effect", parameters: %{type: "object", properties: %{}}}
  def execution_mode, do: :exclusive
  def approval, do: :never
  def run(%{"id" => id}, context) do
    File.write!(Path.join(context.cwd, id), "1", [:append])
    if id == "uncertain", do: Process.sleep(120_000)
    {:ok, id}
  end
end
runner = case System.fetch_env!("ZEKKYOU_SMOKE_RUNNER") do
  "serial" -> Alto.Runner.Serial
  "stepped" -> Alto.Runner.Stepped
end
profile = Alto.Config.new(
  runner: runner, runner_options: [mode: :automatic],
  provider: ChildRecoverySmoke.Lead,
  loop: Zekkyou.Team.loop(
    workers: %{"worker" => [loop: Alto.loop(ChildRecoverySmoke.Worker),
                            tools: [ChildRecoverySmoke.Effect]]},
    max_children: 3, max_concurrency: 1, sessions: :separate,
    journal: Zekkyou.ChildRuns.ledger()),
  tools: [ChildRecoverySmoke.Effect], approval: Alto.Approvals.DenyAll)
Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, run_timeout: 180_000],
  profiles: %{"team" => profile})
'''


def main(runner="serial"):
    with tempfile.TemporaryDirectory(prefix="zek-child-recovery-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        state = base / "state"
        socket_path = str(state / "service.sock")
        config = base / "service.exs"
        config.write_text(CONFIG)
        environment = os.environ.copy()
        environment.update(ZEKKYOU_WORKSPACE=str(workspace), ZEKKYOU_STATE_DIR=str(state),
                           ZEKKYOU_SMOKE_RUNNER=runner, ERL_FLAGS="+S 2:2")

        def inspect_batch():
            batches = service.command(environment, socket_path, "team-batches")[-1]["batches"]
            batch, = batches
            detail = service.command(environment, socket_path, "team-batch", batch["key"])[-1]
            assert detail["counts"] == {"completed": 1, "dispatched": 1, "planned": 1}, detail
            assert not detail["joined"], detail
            assert [c["id"] for c in detail["children"]] == ["done", "uncertain", "planned"]
            encoded = ""
            cursor = 0
            pages = 0
            while cursor is not None:
                chunk = service.command(environment, socket_path, "team-result", batch["key"],
                                        "done", "--generation", detail["generation"],
                                        "--revision", str(detail["revision"]),
                                        "--cursor", str(cursor))[-1]
                assert len(chunk["chunk"]) <= 24_000, chunk
                assert chunk["generation"] == detail["generation"]
                encoded += chunk["chunk"]
                cursor = chunk["next_cursor"]
                pages += 1
            assert pages > 1
            assert len(encoded) == chunk["bytes"]
            assert hashlib.sha256(encoded.encode("ascii")).hexdigest() == chunk["sha256"]
            # Transport correlation IDs belong to this request, not retained state.
            detail.pop("id")
            return detail, encoded

        process = service.launch(environment, socket_path, config)
        try:
            service.command(environment, socket_path, "schedule", "team", "inspect",
                            "--id", "interrupted-team")
            deadline = time.monotonic() + 20
            while not (workspace / "uncertain").exists():
                assert process.poll() is None, "Service exited before child dispatch"
                assert time.monotonic() < deadline, "Second child never dispatched"
                time.sleep(0.025)
            saved = inspect_batch()
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
        finally:
            service.stop(process)

        retained = (state / "operations/team-children.jsonl").read_bytes()
        for _ in range(2):
            process = service.launch(environment, socket_path, config)
            try:
                current = service.wait_for(environment, socket_path, "interrupted-team",
                                           "requires_operator")
                assert current["revision"] > 0
                assert inspect_batch() == saved
                assert (state / "operations/team-children.jsonl").read_bytes() == retained
                assert (workspace / "plans").read_text() == "1"
                assert (workspace / "done").read_text() == "1"
                assert (workspace / "uncertain").read_text() == "1"
                assert not (workspace / "planned").exists()
            finally:
                service.stop(process)

    print(f"PASS ({runner}): interrupted delegation retains exact paged child results and "
          "uncertain dispatch across three VMs without redispatch or journal mutation")


if __name__ == "__main__":
    main()
    main(runner="stepped")
