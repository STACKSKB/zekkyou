"""Qualify isolated named workers and operator recovery across service VMs."""
import base64
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import checkpoint_smoke as service

CONFIG = r'''
defmodule WorkspaceSmoke.Provider do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(request, _sink, _opts) do
    stages = Enum.flat_map(request.messages, fn m ->
      case JSON.decode(m["content"] || "") do
        {:ok, %{"type" => "zekkyou_team_stage", "stage" => stage}} -> [stage]
        _ -> []
      end
    end)
    message = if List.last(stages) == "planning" do
      JSON.encode!(%{agents: [
        %{id: "left", profile: "code", task: "left"},
        %{id: "right", profile: "code", task: "right"}
      ]})
    else
      "patches ready for review"
    end
    {:ok, %{message: message, tool_calls: [], usage: %{input_tokens: 1, output_tokens: 1}}}
  end
end

defmodule WorkspaceSmoke.Writer do
  @behaviour Alto.Loop
  def init(content, _spec) do
    Alto.Transition.continue(%{}, [Alto.Effect.invoke_tool(%{
      id: "write", name: "write_file", arguments: %{"path" => "tracked.txt", "content" => content <> "\n"}
    })])
  end
  def handle_event(%Alto.Event{type: :tool_completed}, state, _), do: Alto.Transition.stop(state, :written)
  def handle_event(%Alto.Event{type: :tool_failed, data: data}, state, _), do: Alto.Transition.error(state, data)
  def handle_event(_, state, _), do: Alto.Transition.continue(state)
end

state = System.fetch_env!("ZEKKYOU_STATE_DIR")
workers = %{"code" => [loop: Alto.loop(WorkspaceSmoke.Writer), tools: [Alto.Tools.WriteFile]]}
profile = Alto.Config.new(
  provider: WorkspaceSmoke.Provider,
  loop: Zekkyou.Team.loop(workers: workers, max_children: 2, max_concurrency: 2,
                         workspaces: Zekkyou.Workspaces.manager(state)),
  tools: [Alto.Tools.WriteFile], approval: Alto.Approvals.AllowAll,
  max_model_requests: 2, max_effects: 20)
Zekkyou.Config.new(workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"), state_dir: state,
  profiles: %{"coding" => profile}, scheduling: [workers: 1, poll_ms: 10])
'''


def main():
    with tempfile.TemporaryDirectory(prefix="zekkyou-workspaces-") as temporary:
        base = Path(temporary)
        source = base / "source"
        source.mkdir()
        (source / "tracked.txt").write_text("base\n")
        environment = os.environ.copy()
        environment.update(ZEKKYOU_WORKSPACE=str(source), ZEKKYOU_STATE_DIR=str(base / "state"),
                           ERL_FLAGS="+S 2:2", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        for args in [["init", "-q"], ["add", "tracked.txt"],
                     ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"]]:
            subprocess.run(["git", *args], cwd=source, env=environment, check=True,
                           capture_output=True, timeout=15)
        config = base / "service.exs"
        config.write_text(CONFIG)
        socket = str(base / "state/service.sock")
        process = service.launch(environment, socket, config)
        try:
            service.command(environment, socket, "schedule", "coding", "make isolated edits", "--id", "coding")
            try:
                completed = service.wait_for(environment, socket, "coding", "completed")
            except AssertionError:
                current = service.task(environment, socket, "coding")
                print(service.command(environment, socket, "workspaces"), flush=True)
                if current.get("session_id"):
                    print(service.command(environment, socket, "history", current["session_id"]), flush=True)
                raise
            assert completed["usage"]["total_tokens"] == 4, completed
            records = service.command(environment, socket, "workspaces")[-1]["workspaces"]
            assert len(records) == 2 and all(r["status"] == "frozen" for r in records), records
            assert len({r["workspace"]["cwd"] for r in records}) == 2
            assert (source / "tracked.txt").read_text() == "base\n"
        finally:
            service.stop(process)

        process = service.launch(environment, socket, config)
        try:
            patches = []
            for saved in records:
                record = service.command(environment, socket, "workspace", saved["id"])[-1]
                assert record["workspace_id"] == saved["id"], record
                assert record["revision"] == saved["revision"] and record["status"] == "frozen", record
                chunk = service.command(environment, socket, "workspace-patch", saved["id"])[-1]
                patch = base64.b64decode(chunk["chunk"])
                assert chunk["next_cursor"] is None
                assert hashlib.sha256(patch).hexdigest() == saved["workspace"]["patch_sha256"]
                patches.append(patch)
                try:
                    service.command(environment, socket, "workspace-discard", saved["id"],
                                    "--revision", str(saved["revision"] - 1), "--note", "stale")
                except RuntimeError as error:
                    assert "stale_workspace" in str(error), error
                else:
                    raise AssertionError("stale discard succeeded")
                discarded = service.command(environment, socket, "workspace-discard", saved["id"],
                                            "--revision", str(saved["revision"]), "--note", "reviewed")[-1]
                assert discarded["status"] == "discarded", discarded
                assert not Path(saved["workspace"]["cwd"]).exists()
            assert any(b"+left" in patch for patch in patches)
            assert any(b"+right" in patch for patch in patches)
            assert (source / "tracked.txt").read_text() == "base\n"
        finally:
            service.stop(process)
    print("PASS: isolated named coding workers, immutable patches, fresh-VM operator recovery and fenced cleanup")


if __name__ == "__main__":
    if len(sys.argv) == 2:
        service.EXECUTABLE = str(Path(sys.argv[1]).resolve())
    elif len(sys.argv) != 1:
        raise SystemExit("Usage: workspace_smoke.py [ZEKKYOU_CLI]")
    main()
