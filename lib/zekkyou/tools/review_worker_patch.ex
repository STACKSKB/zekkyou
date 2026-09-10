defmodule Zekkyou.Tools.ReviewWorkerPatch do
  @moduledoc "Bounded, execution-scoped inspection of descendant worker patches."
  @behaviour Alto.Tool

  def name, do: :review_worker_patch
  def execution_mode, do: :parallel
  def approval, do: :never

  def schema do
    %{
      description:
        "Read a captured descendant worker patch before integrating it. Responses contain " <>
          "base64 chunks, the full SHA-256 and a next byte cursor. Read all chunks for full review.",
      parameters: %{
        type: "object",
        properties: %{
          workspace_id: %{type: "string"},
          cursor: %{type: "integer", minimum: 0}
        },
        required: ["workspace_id"],
        additionalProperties: false
      }
    }
  end

  def run(args, context), do: run(args, context, [])

  def run(%{"workspace_id" => id} = args, context, opts) do
    with true <- Map.keys(args) -- ~w(workspace_id cursor) == [],
         {:ok, manager, _} <- Zekkyou.Workspaces.for_descendant(context, id, opts) do
      Zekkyou.Workspaces.patch_chunk(manager, id, Map.get(args, "cursor", 0))
    else
      false -> {:error, :invalid_patch_arguments}
      error -> error
    end
  end

  def run(_, _, _), do: {:error, :invalid_patch_arguments}
end
