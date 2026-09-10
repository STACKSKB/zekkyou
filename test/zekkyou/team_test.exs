defmodule Zekkyou.TeamTest do
  use ExUnit.Case, async: true

  defmodule LeadProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:lead_request, request})

      stages =
        Enum.flat_map(request.messages, fn message ->
          case JSON.decode(message["content"] || "") do
            {:ok, %{"type" => "zekkyou_team_stage", "stage" => stage}} -> [stage]
            _ -> []
          end
        end)

      if List.last(stages) == "integrating" do
        {:ok, %{message: "integrated", tool_calls: []}}
      else
        {:ok,
         %{
           message: ~s({"agents":[{"id":"worker-1","profile":"cheap","task":"inspect"}]}),
           tool_calls: []
         }}
      end
    end
  end

  defmodule CheapProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:worker_request, request})
      {:ok, %{message: "finding", tool_calls: []}}
    end
  end

  defmodule InvalidProfileLead do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, _opts),
      do:
        {:ok,
         %{message: ~s({"agents":[{"id":"x","profile":"missing","task":"x"}]}), tool_calls: []}}
  end

  defmodule PlanProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def stream(_request, _sink, opts), do: {:ok, %{message: opts[:plan], tool_calls: []}}
  end

  test "invalid assignments reject the whole plan without dispatching valid siblings" do
    child = %{"id" => "valid", "profile" => "cheap", "task" => "inspect"}

    invalid = [
      [child, %{child | "profile" => "missing", "id" => "other"}],
      [child, child],
      [Map.put(child, "tools", ["write_file"])],
      [Map.put(child, "provider", "untrusted")],
      [child, %{child | "id" => "two"}, %{child | "id" => "three"}]
    ]

    for agents <- invalid do
      assert {:error, :invalid_team_plan, _} =
               Alto.run("task",
                 loop:
                   Zekkyou.Team.loop(
                     workers: %{"cheap" => [provider: {CheapProvider, test_pid: self()}]},
                     max_children: 2
                   ),
                 provider: {PlanProvider, plan: JSON.encode!(%{agents: agents})}
               )
    end

    refute_receive {:worker_request, _}, 100
  end

  test "worker names cannot alias a different profile and omitted tools grant none" do
    assert_raise ArgumentError, fn ->
      Zekkyou.Team.loop(workers: %{:cheap => [], "cheap" => [tools: [Alto.Tools.WriteFile]]})
    end

    loop = Zekkyou.Team.loop(workers: %{"cheap" => []})
    assert loop.driver_options[:workers]["cheap"][:tools] == []
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zekkyou-team-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "plans through named worker and integrates child results", %{dir: dir} do
    pid = self()

    assert {:ok, result} =
             Alto.run("original task",
               loop:
                 Zekkyou.Team.loop(
                   workers: %{cheap: [provider: {CheapProvider, test_pid: pid}]},
                   max_children: 2,
                   max_concurrency: 1,
                   sessions: :separate
                 ),
               provider: {LeadProvider, test_pid: pid},
               system_prompt: Zekkyou.Team.instructions([:cheap], 2),
               session: :new,
               session_dir: dir
             )

    assert result.output == "integrated"
    assert result.persistence == :ok
    children = Enum.find(result.events, &(&1.type == :subagents_completed)).data.results
    [child] = children
    assert child.session_id != result.session_id
    assert {:ok, transcript} = Alto.Session.transcript(child.session_id, session_dir: dir)
    assert Enum.any?(transcript.messages, &(&1["content"] == "finding"))
    refute Enum.any?(transcript.messages, &(&1["content"] == "original task"))
    assert_receive {:worker_request, worker_request}, 2_000
    assert hd(worker_request.messages)["content"] =~ "Carry out the assigned task"
    refute hd(worker_request.messages)["content"] =~ "Registered profiles"
    assert_receive {:lead_request, %{loop: %{model_tools: []}}}, 2_000
    assert_receive {:lead_request, request}, 2_000

    assert Enum.any?(request.messages, fn message ->
             case JSON.decode(message["content"] || "") do
               {:ok,
                %{
                  "type" => "alto_subagent_results",
                  "results" => [%{"id" => "worker-1", "output" => "finding", "status" => "ok"}]
                }} ->
                 true

               _ ->
                 false
             end
           end)

    assert {:ok, next} =
             Alto.resume(result.session_id, "follow-up task",
               loop:
                 Zekkyou.Team.loop(
                   workers: %{"cheap" => [provider: {CheapProvider, test_pid: pid}]},
                   max_children: 2,
                   max_concurrency: 1
                 ),
               provider: {LeadProvider, test_pid: pid},
               session_dir: dir
             )

    assert next.output == "integrated"
    assert next.session_id == result.session_id
    assert_receive {:worker_request, _}, 2_000
    assert_receive {:lead_request, planning}, 2_000
    assert JSON.decode!(List.last(planning.messages)["content"])["stage"] == "planning"
  end

  test "unknown profile fails before any child dispatch", %{dir: dir} do
    assert {:error, _reason, _result} =
             Alto.run("original task",
               loop:
                 Zekkyou.Team.loop(
                   workers: %{cheap: [provider: {CheapProvider, test_pid: self()}]}
                 ),
               provider: InvalidProfileLead,
               session: :new,
               session_dir: dir
             )

    refute_receive {:worker_request, _}, 100
  end
end
