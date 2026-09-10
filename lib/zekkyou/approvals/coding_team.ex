defmodule Zekkyou.Approvals.CodingTeam do
  @moduledoc """
  Opt-in coding-team policy: permit bounded file writes in an actively owned
  worker checkout; suspend the lead's effects for durable operator approval.
  Other approval-requiring worker tools are denied. Configure the same workspace
  manager in this policy, the team loop and the patch tools.
  """
  @behaviour Alto.Approval

  def decide(_request, %Alto.Tool.Context{agent_identity: %{path: []}}, _opts), do: :suspend

  def decide(
        %Alto.Approval.Request{tool: tool},
        %Alto.Tool.Context{cwd: cwd, agent_identity: %{path: [_ | _]} = identity},
        opts
      )
      when tool in ["write_file", "edit_file"] and is_binary(cwd) do
    id = cwd |> Path.dirname() |> Path.basename()

    with %Alto.Workspaces{} = manager <- Keyword.get(opts, :manager),
         {:ok, %{status: "in_progress", workspace: workspace}} <-
           Alto.Workspaces.get(manager, id),
         true <- cwd == Path.join([manager.root, id, "checkout"]),
         true <- workspace["cwd"] == cwd,
         true <- workspace["owner"] == Alto.Protocol.encode_term(identity) do
      :approve
    else
      _ -> {:deny, :worker_workspace_not_owned}
    end
  end

  def decide(_, _, _), do: {:deny, :worker_tool_not_permitted}
end
