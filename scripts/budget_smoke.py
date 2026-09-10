"""Exercise a durable shared model budget across fresh service VMs."""

import json
import os
import tempfile
from pathlib import Path

import checkpoint_smoke as service


CONFIG = r'''
defmodule BudgetSmoke.Provider do
  @behaviour Alto.Provider
  def describe(_), do: %{}
  def stream(_request, _sink, _opts) do
    path = Path.join(System.fetch_env!("ZEKKYOU_WORKSPACE"), "calls")
    File.write!(path, "1", [:append])
    {:ok, %{message: "completed", tool_calls: []}}
  end
end

{:ok, ledger} = Alto.OperationLog.start_link(
  name: BudgetSmoke.Ledger,
  id: "count-budgets",
  dir: Path.join(System.fetch_env!("ZEKKYOU_STATE_DIR"), "operations"))
{:ok, account} = Alto.Runner.Budget.Account.open(ledger, "shared-profile",
  max_effects: 20, max_model_requests: 2)
profile = Alto.Config.new(
  provider: BudgetSmoke.Provider,
  loop: Alto.chat_loop(),
  budget_account: account,
  max_effects: 20,
  max_model_requests: 2,
  run_timeout: 5_000
)
Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.fetch_env!("ZEKKYOU_STATE_DIR"),
  scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 5_000],
  profiles: %{"budget" => profile}
)
'''


def _recorded_counts(state):
    records = [json.loads(line) for line in
               (state / "operations/count-budgets.jsonl").read_text().splitlines()]
    updates = [record["checkpoint"] for record in records
               if record["op"] == "shared-profile" and
               record["t"] in ("checkpoint", "checkpoint_update")]
    assert updates[-1]["kind"] == "alto_budget_account", updates
    return updates[-1]["model_requests_used"]


def main():
    with tempfile.TemporaryDirectory(prefix="zekkyou-budget-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        state = base / "state"
        config = base / "budget.exs"
        config.write_text(CONFIG)
        environment = os.environ.copy()
        environment.update(
            ZEKKYOU_WORKSPACE=str(workspace),
            ZEKKYOU_STATE_DIR=str(state),
            ERL_FLAGS="+S 2:2",
        )
        socket_path = str(state / "service.sock")

        process = service.launch(environment, socket_path, config)
        try:
            first = service.command(environment, socket_path, "schedule", "budget", "one", "--id", "one")[-1]
            assert first["status"] == "queued", first
            service.wait_for(environment, socket_path, "one", "completed")
            assert (workspace / "calls").read_text() == "1"
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            second = service.command(environment, socket_path, "schedule", "budget", "two", "--id", "two")[-1]
            assert second["status"] == "queued", second
            service.wait_for(environment, socket_path, "two", "completed")
            assert (workspace / "calls").read_text() == "11"
            assert _recorded_counts(state) == 2
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            third = service.command(environment, socket_path, "schedule", "budget", "three", "--id", "three")[-1]
            assert third["status"] == "queued", third
            current = service.wait_for(environment, socket_path, "three", "failed")
            assert current["status"] == "failed", current
            assert "model_request_limit" in json.dumps(current), current
            assert (workspace / "calls").read_text() == "11"
            assert _recorded_counts(state) == 2
        finally:
            service.stop(process)

        process = service.launch(environment, socket_path, config)
        try:
            fourth = service.command(environment, socket_path, "schedule", "budget", "four", "--id", "four")[-1]
            assert fourth["status"] == "queued", fourth
            current = service.wait_for(environment, socket_path, "four", "failed")
            assert current["status"] == "failed", current
            assert "model_request_limit" in json.dumps(current), current
            assert (workspace / "calls").read_text() == "11"
            assert _recorded_counts(state) == 2
        finally:
            service.stop(process)

    print("PASS: durable shared budget survives VM restart and denies excess model calls")


if __name__ == "__main__":
    main()
