"""Independent sibling approvals and terminal cleanup across fresh service VMs."""
import os
import tempfile
from pathlib import Path

import checkpoint_smoke as service

CONFIG = r'''
defmodule ChildSuspensionSmoke.Parent do
  @behaviour Alto.Loop
  def init(_, spec) do
    File.write!(Path.join(spec.driver_options[:dir], "plans"), "1", [:append])
    agents = for id <- ["one", "two"], do: %{id: id, task: %{"id" => id},
      loop: Alto.rule_loop(steps: ["first", "guarded"])}
    Alto.Transition.continue(%{}, [Alto.Effect.spawn_agents(%{agents: agents})])
  end
  def handle_event(%Alto.Event{type: :subagents_completed}, state, _),
    do: Alto.Transition.continue(state, [Alto.Effect.invoke_tool(%{name: "first",
      arguments: %{"id" => "integrated"}})])
  def handle_event(%Alto.Event{type: :tool_completed}, state, _), do: Alto.Transition.stop(state, "done")
  def handle_event(_, state, _), do: Alto.Transition.continue(state)
  def dump_checkpoint(state, _), do: {:ok, state}
  def load_checkpoint(state, _), do: {:ok, state}
end
defmodule ChildSuspensionSmoke.First do
  @behaviour Alto.Tool
  def name, do: :first
  def schema, do: %{description: "first", parameters: %{type: "object", properties: %{}}}
  def execution_mode, do: :exclusive
  def approval, do: :never
  def run(%{"id" => id}, context) do
    File.write!(Path.join(context.cwd, "first-" <> id), "1", [:append])
    {:ok, id}
  end
end
defmodule ChildSuspensionSmoke.Guarded do
  @behaviour Alto.Tool
  def name, do: :guarded
  def schema, do: %{description: "guarded", parameters: %{type: "object", properties: %{}}}
  def execution_mode, do: :exclusive
  def approval, do: :required
  def prepare(%{"id" => id}, context) do
    File.write!(Path.join(context.cwd, "prepared-" <> id), "1", [:append])
    {:ok, %{id: id, value: File.read!(Path.join(context.cwd, "input"))}, %{id: id}}
  end
  def run_prepared(%{id: id, value: value}, context) do
    File.write!(Path.join(context.cwd, "effect-" <> id), value, [:append])
    {:ok, value}
  end
end
runner = case System.fetch_env!("ZEKKYOU_SMOKE_RUNNER") do
  "serial" -> Alto.Runner.Serial
  "stepped" -> Alto.Runner.Stepped
end
profile = Alto.Config.new(runner: runner, continuation_store: Zekkyou.ParentRuns.ledger(),
  checkpoint_version: "independent-children-smoke-v1", provider: nil,
  loop: Alto.loop(ChildSuspensionSmoke.Parent, dir: System.fetch_env!("ZEKKYOU_WORKSPACE"),
    subagents: Alto.Subagents.bounded(max_depth: 1, max_children: 2, max_concurrency: 2,
      sessions: :separate, journal: Zekkyou.ChildRuns.ledger())),
  tools: [ChildSuspensionSmoke.First, ChildSuspensionSmoke.Guarded],
  approval: Alto.Approvals.Checkpoint)
Zekkyou.Config.new(workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, run_timeout: 180_000], profiles: %{"team" => profile})
'''


def main(runner="serial", config_text=None):
    with tempfile.TemporaryDirectory(prefix="zek-child-suspend-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        (workspace / "input").write_text("original")
        state = base / "state"
        socket = str(state / "service.sock")
        config = base / "service.exs"
        config.write_text(config_text or CONFIG)
        environment = os.environ.copy()
        environment.update(ZEKKYOU_WORKSPACE=str(workspace), ZEKKYOU_STATE_DIR=str(state),
                           ZEKKYOU_SMOKE_RUNNER=runner, ERL_FLAGS="+S 2:2")

        def command(*args):
            return service.command(environment, socket, *args)[-1]

        def decide(child, decision):
            task = service.wait_for(environment, socket, "parent", "requires_operator")
            batch = command("team-batches")["batches"][0]
            view = command("team-child-approval", batch["key"], child,
                           "--generation", batch["generation"], "--revision", str(batch["revision"]))
            assert view["request"]["tool"] == "guarded", view
            identity = view["identity"]
            arguments = ["task-child-decide", "parent", child, decision,
                           "--revision", str(task["revision"]), "--key", batch["key"],
                           "--generation", batch["generation"], "--batch-revision", str(batch["revision"]),
                           "--attempt", identity["attempt"], "--suspension", identity["suspension"]]
            stale = arguments.copy()
            stale[5] = str(task["revision"] + 1)
            try:
                command(*stale)
                raise AssertionError("Stale task decision was accepted")
            except RuntimeError as error:
                assert "stale_revision" in str(error), error
            assert command("team-batches")["batches"][0]["revision"] == batch["revision"]
            return command(*arguments)

        process = service.launch(environment, socket, config)
        try:
            command("schedule", "team", "delegate", "--id", "parent")
            service.wait_for(environment, socket, "parent", "requires_operator")
            assert command("team-batches")["batches"][0]["counts"] == {"suspended": 2}
            for child in ["one", "two"]:
                assert (workspace / f"first-{child}").read_text() == "1"
                assert (workspace / f"prepared-{child}").read_text() == "1"
        finally:
            service.stop(process)

        (workspace / "input").write_text("changed")
        process = service.launch(environment, socket, config)
        try:
            decide("one", "approve")
            service.wait_for(environment, socket, "parent", "requires_operator")
            assert (workspace / "effect-one").read_text() == "original"
            assert not (workspace / "effect-two").exists()
            assert not (workspace / "first-integrated").exists()
        finally:
            service.stop(process)

        process = service.launch(environment, socket, config)
        try:
            decide("two", "deny")
            completed = service.wait_for(environment, socket, "parent", "completed")
            assert (workspace / "first-integrated").read_text() == "1"
            assert not (workspace / "effect-two").exists()
            assert command("task-cleanup", "parent", "--revision", str(completed["revision"]))["status"] == "cleaned"
            assert command("team-batches")["batches"][0]["state"] == "retired"
        finally:
            service.stop(process)

        process = service.launch(environment, socket, config)
        try:
            assert command("task-cleanup", "parent", "--revision", str(completed["revision"]))["status"] == "cleaned"
            assert (workspace / "plans").read_text() == "1"
            for child in ["one", "two"]:
                assert (workspace / f"first-{child}").read_text() == "1"
                assert (workspace / f"prepared-{child}").read_text() == "1"
        finally:
            service.stop(process)
    print(f"PASS ({runner}): independent sibling approve/deny, exact prepared values, four VMs and durable cleanup")


if __name__ == "__main__":
    main()
    main("stepped")
