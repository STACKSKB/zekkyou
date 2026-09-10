"""Qualify named team execution and exact integration across fresh service VMs.

Run after mix escript.build. Uses deterministic local provider fixtures, real
Alto prepared tool execution, and temporary state; no provider account is used.
"""

import json
import os
import tempfile
from pathlib import Path

import checkpoint_smoke as service


CONFIG = r'''
defmodule TeamSmoke.Provider do
  @behaviour Alto.Provider
  def describe(_), do: %{}

  def stream(request, _sink, options) do
    mailbox? = System.get_env("ZEKKYOU_TEAM_MAILBOX") == "1"
    replies = Enum.filter(request.messages, &(&1["role"] == "tool"))

    completion =
      if options[:worker] do
        # Fixture instrumentation: count actual worker provider invocations.
        File.write!(Path.join(System.fetch_env!("ZEKKYOU_WORKSPACE"), "workers"), "1", [:append])
        if mailbox? and replies == [] do
          call("send", %{action: "send", id: "finding", to: [], body: "inspected"})
        else
          if mailbox?, do: false = JSON.decode!(hd(replies)["content"])["duplicate"]
          %{message: "inspected", tool_calls: []}
        end
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

          mailbox? and Enum.any?(replies, &(&1["tool_call_id"] == "ack-1")) ->
            %{message: "integrated", tool_calls: []}

          mailbox? and Enum.any?(replies, &(&1["tool_call_id"] == "receive")) ->
            received = Enum.find(replies, &(&1["tool_call_id"] == "receive"))
            messages = JSON.decode!(received["content"])["messages"]
            2 = length(messages)
            [["a"], ["b"]] = Enum.sort(Enum.map(messages, & &1["payload"]["from"]))
            true = Enum.all?(messages, &(&1["payload"]["body"] == "inspected"))
            %{message: nil, tool_calls: Enum.with_index(messages, 1) |> Enum.map(fn {m, i} ->
              hd(call("ack-#{i}", %{action: "ack", key: m["key"], claim_id: m["claim_id"]}).tool_calls)
            end)}

          mailbox? and replies != [] ->
            call("receive", %{action: "receive"})

          replies != [] ->
            %{message: "integrated", tool_calls: []}

          true ->
            %{message: nil, tool_calls: [%{id: "write", name: "guarded", arguments_json: "{}"}]}
        end
      end

    {:ok, Map.put(completion, :usage, %{input_tokens: 1, output_tokens: 1})}
  end

  defp call(id, arguments), do: %{message: nil, tool_calls: [
    %{id: id, name: "team_mailbox", arguments_json: JSON.encode!(arguments)}
  ]}
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

mailbox? = System.get_env("ZEKKYOU_TEAM_MAILBOX") == "1"
mailbox_tools = if mailbox?, do: [Zekkyou.Tools.Mailbox], else: []
workers = %{"inspect" => [provider: {TeamSmoke.Provider, worker: true},
                          tools: mailbox_tools, max_steps: if(mailbox?, do: 2, else: 1)]}
{:ok, _journal} = Alto.OperationLog.start_link(
  id: "children", name: TeamSmoke.Journal,
  dir: Path.join(System.fetch_env!("ZEKKYOU_STATE_DIR"), "operations"))
profile = Alto.Config.new(
  provider: TeamSmoke.Provider,
  system_prompt: Zekkyou.Team.instructions(workers, 2),
  loop: Zekkyou.Team.loop(workers: workers, max_children: 2, max_concurrency: 2, sessions: :separate, journal: TeamSmoke.Journal),
  tools: [TeamSmoke.Guarded] ++ mailbox_tools,
  approval: Alto.Approvals.Checkpoint,
  checkpoint_version: "team-smoke-v1",
  max_steps: if(mailbox?, do: 5, else: 3),
  max_model_requests: if(mailbox?, do: 9, else: 5),
  max_effects: 40
)
Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, poll_ms: 10, max_attempts: 1],
  profiles: %{"team" => profile}
)
'''


def main(mailboxes=False):
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
                           ZEKKYOU_TEAM_MAILBOX="1" if mailboxes else "0", ERL_FLAGS="+S 2:2")
        worker_calls = "1111" if mailboxes else "11"
        waiting_tokens = 12 if mailboxes else 8
        completed_tokens = 18 if mailboxes else 10

        def mailbox_records():
            return [json.loads(line) for line in
                    (base / "state/queues/team-messages.jsonl").read_text().splitlines()]

        def child_journal(parent):
            records = [json.loads(line) for line in
                       (base / "state/operations/children.jsonl").read_text().splitlines()]
            packets = [r["checkpoint"] for r in records
                       if r["t"] in ("checkpoint", "checkpoint_update")
                       and r["checkpoint"].get("kind") == "alto_subagent_batch"]
            assert packets, records
            packet = packets[-1]
            assert packet["metadata"]["parent_session_id"] == parent, packet
            assert packet["ids"] == ["a", "b"], packet
            assert [child["id"] for child in packet["children"]] == ["a", "b"], packet
            assert all(child["state"] == "completed" and child["result"]
                       for child in packet["children"]), packet
            assert packet["join"] is None, packet
            return packet

        def child_sessions(parent):
            summaries = service.command(environment, socket_path, "status")[-1]["sessions"]
            children = [s for s in summaries if s["parent_session_id"] == parent]
            assert len(children) == 2, summaries
            assert sorted(s["agent_identity"]["path"] for s in children) == [["a"], ["b"]]
            saved = {}
            for child in children:
                assert child["runs"] == child["completed_runs"] == 1, child
                assert child["last_outcome"] == "ok", child
                session = child["id"]
                transcript = json.loads((base / "state/sessions" / (session + ".transcript.json")).read_text())
                assert any(m.get("content") == "inspected" for m in transcript["messages"]), transcript
                history = service.command(environment, socket_path, "history", session)[-1]
                saved[session] = (child, transcript, history)
            return saved

        process = service.launch(environment, socket_path, config)
        try:
            service.command(environment, socket_path, "schedule", "team", "inspect then integrate",
                            "--id", "team")
            waiting = service.wait_for(environment, socket_path, "team", "waiting_approval")
            assert (workspace / "workers").read_text() == worker_calls
            assert waiting["usage"]["total_tokens"] == waiting_tokens, waiting
            saved_children = child_sessions(waiting["session_id"])
            saved_journal = child_journal(waiting["session_id"])
            if mailboxes:
                assert [r["type"] for r in mailbox_records()] == ["put", "put"]
                root = waiting["agent_identity"]["root_run_id"]
                pending = service.command(environment, socket_path, "mailbox", root)[-1]["messages"]
                assert sorted(m["payload"]["from"] for m in pending) == [["a"], ["b"]]
                for message in pending:
                    inspected = service.command(environment, socket_path, "mailbox-get", root,
                                                message["key"])[-1]["message"]
                    assert inspected["payload"]["body"] == "inspected"
                compacted = service.command(environment, socket_path, "mailbox-compact")[-1]
                assert compacted["live_records"] == 2, compacted
                assert mailbox_records()[0]["type"] == "retained_state"
            assert not (workspace / "integrated").exists()
        finally:
            service.stop(process)

        (workspace / "input").write_text("changed")
        process = service.launch(environment, socket_path, config)
        try:
            recovered = service.task(environment, socket_path, "team")
            assert recovered["revision"] == waiting["revision"], recovered
            assert recovered["approval"] == waiting["approval"], recovered
            assert child_sessions(recovered["session_id"]) == saved_children
            assert child_journal(recovered["session_id"]) == saved_journal
            if mailboxes:
                assert service.command(environment, socket_path, "mailbox", root)[-1]["messages"] == pending
            service.command(environment, socket_path, "task-decide", "team", "approve",
                            "--revision", str(recovered["revision"]))
            completed = service.wait_for(environment, socket_path, "team", "completed")
            assert completed["session_id"] == waiting["session_id"], completed
            assert completed["usage"]["total_tokens"] == completed_tokens, completed
            assert (workspace / "workers").read_text() == worker_calls
            assert (workspace / "integrated").read_text() == "original"
            if mailboxes:
                assert completed["agent_identity"] == waiting["agent_identity"]
                assert completed["run_id"] != waiting["agent_identity"]["root_run_id"]
                assert sum(r["type"] == "blank" for r in mailbox_records()) == 2
                assert service.command(environment, socket_path, "mailbox", root)[-1]["messages"] == []
                compacted = service.command(environment, socket_path, "mailbox-compact")[-1]
                assert compacted["live_records"] == 0 and compacted["completed_keys"] == 2, compacted
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            replay = service.task(environment, socket_path, "team")
            assert replay["status"] == "completed"
            assert child_sessions(replay["session_id"]) == saved_children
            assert child_journal(replay["session_id"]) == saved_journal
            assert replay["usage"]["total_tokens"] == completed_tokens, replay
            assert (workspace / "workers").read_text() == worker_calls
            assert (workspace / "integrated").read_text() == "original"
            if mailboxes:
                assert replay["agent_identity"] == waiting["agent_identity"]
                assert len(mailbox_records()[0]["completed"]) == 2
                assert service.command(environment, socket_path, "mailbox", root)[-1]["messages"] == []
        finally:
            service.stop(process)

    print("PASS: " + ("scoped durable team mailboxes, retained-state compaction, restart, acknowledgement, stable identity" if mailboxes
                      else "named workers, separate child sessions, durable child journals, shared budget/usage, exact integration approval, fresh-VM recovery"))


if __name__ == "__main__":
    main()
    main(mailboxes=True)
