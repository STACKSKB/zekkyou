provider = fn model ->
  {Alto.Providers.OpenAICompatible,
   base_url: System.fetch_env!("ZEKKYOU_PROVIDER_URL"),
   model: model,
   api_key: System.get_env("ZEKKYOU_API_KEY")}
end

inspection = [
  Alto.Tools.ListFiles,
  Alto.Tools.ReadFile,
  Alto.Tools.SearchFiles,
  Zekkyou.Tools.Mailbox
]

workers = %{
  "inspect" => [
    provider: provider.(System.fetch_env!("ZEKKYOU_WORKER_MODEL")),
    tools: inspection,
    max_steps: 8,
    system_prompt:
      "Inspect the assigned part of the workspace. Report evidence with file paths. " <>
        "Do not delegate or edit files. Clearly distinguish findings from guesses. " <>
        "You may send useful findings to the lead at mailbox address []."
  ]
}

Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.get_env("ZEKKYOU_STATE_DIR") || Zekkyou.Config.default_state_dir(),
  profiles: %{
    "team" =>
      Alto.Config.new(
        provider: provider.(System.fetch_env!("ZEKKYOU_MODEL")),
        system_prompt: Zekkyou.Team.instructions(workers, 4),
        loop: Zekkyou.Team.loop(workers: workers, max_children: 4, max_concurrency: 2),
        tools: inspection ++ [Alto.Tools.WriteFile],
        approval: Alto.Approvals.Checkpoint,
        checkpoint_version: "team-v1",
        max_steps: 16,
        max_model_requests: 48,
        max_effects: 200,
        run_timeout: 600_000
      )
  }
)
