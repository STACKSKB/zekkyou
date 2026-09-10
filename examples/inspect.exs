Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.get_env("ZEKKYOU_STATE_DIR") || Zekkyou.Config.default_state_dir(),
  profiles: %{
    "inspect" =>
      Alto.Config.new(
        provider: nil,
        loop: Alto.rule_loop(steps: ["list_files"]),
        tools: [Alto.Tools.ListFiles],
        approval: Alto.Approvals.DenyAll,
        max_effects: 10,
        run_timeout: 10_000
      )
  }
)
