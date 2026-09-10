provider = fn model ->
  {Alto.Providers.OpenAICompatible,
   base_url: System.fetch_env!("ZEKKYOU_PROVIDER_URL"),
   model: model,
   api_key: System.get_env("ZEKKYOU_API_KEY")}
end

state = System.get_env("ZEKKYOU_STATE_DIR") || Zekkyou.Config.default_state_dir()
manager = Zekkyou.Workspaces.manager(state)
inspection = [Alto.Tools.ListFiles, Alto.Tools.ReadFile, Alto.Tools.SearchFiles]
writes = [Alto.Tools.WriteFile, Alto.Tools.EditFile]

workers = %{
  "code" => [
    provider: provider.(System.fetch_env!("ZEKKYOU_WORKER_MODEL")),
    tools: inspection ++ writes,
    model_tools: [:list_files, :read_file, :search_files, :write_file, :edit_file],
    max_steps: 12,
    system_prompt:
      "Implement the assigned change in your isolated checkout using the file tools. " <>
        "Report what changed and any checks or limitations. Do not delegate."
  ]
}

Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: state,
  profiles: %{
    "coding" =>
      Alto.Config.new(
        provider: provider.(System.fetch_env!("ZEKKYOU_MODEL")),
        system_prompt:
          Zekkyou.Team.instructions(workers, 4) <>
            " Workers edit independent checkouts. Review every patch with review_worker_patch, " <>
            "then request apply_worker_patch with the exact workspace ID and revision. " <>
            "Check each tool result; report conflicts and uncertainty without retrying them.",
        loop:
          Zekkyou.Team.loop(
            workers: workers,
            max_children: 4,
            max_concurrency: 2,
            workspaces: manager
          ),
        tools:
          inspection ++
            writes ++
            [
              {Zekkyou.Tools.ReviewWorkerPatch, manager: manager},
              {Zekkyou.Tools.ApplyWorkerPatch, manager: manager}
            ],
        model_tools: [
          :list_files,
          :read_file,
          :search_files,
          :write_file,
          :edit_file,
          :review_worker_patch,
          :apply_worker_patch
        ],
        approval: {Zekkyou.Approvals.CodingTeam, manager: manager},
        checkpoint_version: "coding-team-v1",
        max_steps: 24,
        max_model_requests: 72,
        max_effects: 240,
        run_timeout: 600_000
      )
  }
)
