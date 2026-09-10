"""Qualify named team execution and exact integration across fresh service VMs.

Run after mix escript.build. Uses deterministic local provider fixtures, real
Alto prepared tool execution, and temporary state; no provider account is used.
"""

import os
import tempfile
from pathlib import Path

import checkpoint_smoke as service


CONFIG = r'''
defmodule TeamSmoke.Provider do
  @behaviour Alto.Provider
  def describe(_), do: %{}

  def stream(request, _sink, options) do
    completion =
      if options[:worker] do
        # Fixture instrumentation: count actual worker provider invocations.
        File.write!(Path.join(System.fetch_env!("ZEKKYOU_WORKSPACE"), "workers"), "1", [:append])
        %{message: "inspected", tool_calls: []}
      else
        stages = Enum.flat_map(request.messages, fn message ->
          case JSON.decode(message["content"] || "") do
            {:ok, %{"type" => "zekkyou_team_stage", "stage" => stage}} -> [stage]
            _ -> []
          end
        end)

        cond do
          List.last(stages) == "planning" ->
            %{message: JSON.encode!(%{agents: [
              %{id: "a", profile: "inspect", task: "first part"},
              %{id: "b", profile: "inspect", task: "second part"}
            ]}), tool_calls: []}

          Enum.any?(request.messages, &(&1["role"] == "tool")) ->
            %{message: "integrated", tool_calls: []}

          true ->
            %{message: nil, tool_calls: [%{id: "write", name: "guarded", arguments_json: "{}"}]}
        end
      end

    {:ok, Map.put(completion, :usage, %{input_tokens: 1, output_tokens: 1})}
  end
end

defmodule TeamSmoke.Guarded do
  @behaviour Alto.Tool
  def name, do: :guarded
  def schema, do: %{description: "append prepared input", parameters: %{type: "object", properties: %{}}}
  def execution_mode, do: :exclusive
  def approval, do: :required
  def prepare(_, context), do: {:ok, %{value: File.read!(Path.join(context.cwd, "input"))}, %{action: "append input"}}
  def run_prepared(%{value: value}, context) do
    File.write!(Path.join(context.cwd, "integrated"), value, [:append])
    {:ok, value}
  end
end

workers = %{"inspect" => [provider: {TeamSmoke.Provider, worker: true}, max_steps: 1]}
profile = Alto.Config.new(
  provider: TeamSmoke.Provider,
  system_prompt: Zekkyou.Team.instructions(workers, 2),
  loop: Zekkyou.Team.loop(workers: workers, max_children: 2, max_concurrency: 2),
  tools: [TeamSmoke.Guarded],
  approval: Alto.Approvals.Checkpoint,
  checkpoint_version: "team-smoke-v1",
  max_steps: 3,
  max_model_requests: 5,
  max_effects: 20
)
Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, max_attempts: 1],
  profiles: %{"team" => profile}
)
'''


def main():
    with tempfile.TemporaryDirectory(prefix="zekkyou-team-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        (workspace / "input").write_text("original")
        config = base / "service.exs"
        config.write_text(CONFIG)
        socket_path = str(base / "state/service.sock")
        environment = os.environ.copy()
        environment.update(ZEKKYOU_WORKSPACE=str(workspace), ZEKKYOU_STATE_DIR=str(base / "state"),
                           ERL_FLAGS="+S 2:2")

        process = service.launch(environment, socket_path, config)
        try:
            service.command(environment, socket_path, "schedule", "team", "inspect then integrate",
                            "--id", "team")
            waiting = service.wait_for(environment, socket_path, "team", "waiting_approval")
            assert (workspace / "workers").read_text() == "11"
            assert waiting["usage"]["total_tokens"] == 8, waiting
            assert not (workspace / "integrated").exists()
        finally:
            service.stop(process)

        (workspace / "input").write_text("changed")
        process = service.launch(environment, socket_path, config)
        try:
            recovered = service.task(environment, socket_path, "team")
            assert recovered["revision"] == waiting["revision"], recovered
            assert recovered["approval"] == waiting["approval"], recovered
            service.command(environment, socket_path, "task-decide", "team", "approve",
                            "--revision", str(recovered["revision"]))
            completed = service.wait_for(environment, socket_path, "team", "completed")
            assert completed["session_id"] == waiting["session_id"], completed
            assert completed["usage"]["total_tokens"] == 10, completed
            assert (workspace / "workers").read_text() == "11"
            assert (workspace / "integrated").read_text() == "original"
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            replay = service.task(environment, socket_path, "team")
            assert replay["status"] == "completed"
            assert replay["usage"]["total_tokens"] == 10, replay
            assert (workspace / "workers").read_text() == "11"
            assert (workspace / "integrated").read_text() == "original"
        finally:
            service.stop(process)

    print("PASS: named workers, shared budget/usage, exact integration approval, fresh-VM recovery")


if __name__ == "__main__":
    main()
