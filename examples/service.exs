Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.get_env("ZEKKYOU_STATE_DIR") || Zekkyou.Config.default_state_dir(),
  profiles: %{
    "coding" =>
      Alto.Config.new(
        provider:
          {Alto.Providers.OpenAICompatible,
           base_url: System.fetch_env!("ZEKKYOU_PROVIDER_URL"),
           model: System.fetch_env!("ZEKKYOU_MODEL"),
           api_key: System.get_env("ZEKKYOU_API_KEY")},
        loop: Alto.default_loop(context: Alto.Context.window(usage_estimation: true)),
        tools: [Alto.Tools.ListFiles, Alto.Tools.ReadFile, Alto.Tools.SearchFiles],
        approval: Alto.Approvals.DenyAll,
        max_steps: 30,
        max_effects: 200,
        run_timeout: 600_000
      )
  }
)
