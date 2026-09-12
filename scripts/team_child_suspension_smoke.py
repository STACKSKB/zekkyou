"""Qualify named worker provider recovery through Zekkyou's trusted team loop."""
import child_suspension_smoke as child

CONFIG = child.CONFIG.split("runner = case", 1)[0] + r'''
defmodule NamedChildSmoke.Lead do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(request, _, _) do
    cond do
      Enum.any?(request.messages, &(&1["role"] == "tool")) ->
        {:ok, %{message: "done", tool_calls: []}}
      Enum.any?(request.messages, &(is_binary(&1["content"]) and
          String.contains?(&1["content"], "alto_subagent_results"))) ->
        {:ok, %{message: nil, tool_calls: [%{id: "integrate", name: "first",
          arguments_json: JSON.encode!(%{id: "integrated"})}]}}
      true ->
        File.write!(Path.join(System.fetch_env!("ZEKKYOU_WORKSPACE"), "plans"), "1", [:append])
        agents = for id <- ["one", "two"], do: %{id: id, profile: "cheap", task: JSON.encode!(%{id: id})}
        {:ok, %{message: JSON.encode!(%{agents: agents}), tool_calls: []}}
    end
  end
end
defmodule NamedChildSmoke.Worker do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(request, _, opts) do
    true = Keyword.fetch!(opts, :credential) == "local-worker-credential-sentinel"
    task = Enum.find(request.messages, &(&1["role"] == "user"))
    %{"id" => id} = JSON.decode!(task["content"])
    case Enum.count(request.messages, &(&1["role"] == "tool")) do
      0 -> call("first", id)
      1 -> call("guarded", id)
      _ -> {:ok, %{message: "worker finished", tool_calls: []}}
    end
  end
  defp call(tool, id), do: {:ok, %{message: nil, tool_calls: [
    %{id: tool <> id, name: tool, arguments_json: JSON.encode!(%{id: id})}]}}
end
runner = case System.fetch_env!("ZEKKYOU_SMOKE_RUNNER") do
  "serial" -> Alto.Runner.Serial
  "stepped" -> Alto.Runner.Stepped
end
workers = %{"cheap" => [provider: {NamedChildSmoke.Worker,
  credential: "local-worker-credential-sentinel"},
  tools: [ChildSuspensionSmoke.First, ChildSuspensionSmoke.Guarded]]}
profile = Alto.Config.new(runner: runner, continuation_store: Zekkyou.ParentRuns.ledger(),
  checkpoint_version: "named-child-smoke-v1", provider: NamedChildSmoke.Lead,
  loop: Zekkyou.Team.loop(workers: workers, max_children: 2, max_concurrency: 2,
    sessions: :separate, journal: Zekkyou.ChildRuns.ledger()),
  tools: [ChildSuspensionSmoke.First, ChildSuspensionSmoke.Guarded],
  approval: Alto.Approvals.Checkpoint)
Zekkyou.Config.new(workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, run_timeout: 180_000], profiles: %{"team" => profile})
'''


def main(runner="serial"):
    child.main(runner, CONFIG)
    print(f"PASS ({runner}): named team worker providers resolve from trusted configuration across restart")


if __name__ == "__main__":
    main()
    main("stepped")
