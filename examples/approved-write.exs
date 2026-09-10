# Write a real workspace file after a durable, revision-fenced decision.
# ./zekkyou serve examples/approved-write.exs
# ./zekkyou schedule write '{"path":"notes.txt","content":"Reviewed content"}'
# Inspect with `task ID`, then `task-decide ID approve --revision N`.
Zekkyou.Config.new(
  workspace: System.fetch_env!("ZEKKYOU_WORKSPACE"),
  state_dir: System.get_env("ZEKKYOU_STATE_DIR") || Zekkyou.Config.default_state_dir(),
  profiles: %{
    "write" =>
      Alto.Config.new(
        provider: nil,
        loop: Alto.rule_loop(steps: ["write_file"]),
        tools: [Alto.Tools.WriteFile],
        approval: Alto.Approvals.Checkpoint,
        checkpoint_version: "approved-write-v1"
      )
  }
)
