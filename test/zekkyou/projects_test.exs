defmodule Zekkyou.ProjectsTest do
  use ExUnit.Case, async: false
  alias Zekkyou.{Config, Console, Projects, Service, Tasks}

  defmodule WriteFolder do
    @behaviour Alto.Tool
    def name, do: :write_folder

    def schema,
      do: %{
        description: "Record the execution folder",
        parameters: %{type: "object", properties: %{}}
      }

    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(_, context) do
      File.write!(Path.join(context.cwd, "ran.txt"), "run\n", [:append])
      {:ok, context.cwd}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "zek-projects-#{System.unique_integer([:positive])}")
    folder = Path.join(root, "second project")
    File.mkdir_p!(folder)

    config =
      Config.new(
        workspace: root,
        state_dir: Path.join(root, "state"),
        scheduling: [poll_ms: 10, workers: 1],
        profiles: %{
          "test" =>
            Alto.Config.new(
              provider: nil,
              loop: Alto.rule_loop(steps: ["write_folder"]),
              tools: [WriteFolder]
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(root) end)
    %{config: config, name: name, folder: folder, root: root}
  end

  test "console workspaces launch in their folder and follow-ups retain it", ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    assert model.workspace_base == ctx.root
    invalid = Console.perform(model, {:workspace, "missing-folder"}, self())
    assert invalid.notice =~ "does not exist"
    assert invalid.workspace_id == model.workspace_id
    assert invalid.connection == "connected"
    model = Console.perform(model, {:workspace, "second project"}, self())
    assert model.workspace_root == ctx.folder
    assert model.selected_id == nil
    id = model.workspace_id
    model = Console.perform(model, {:submit, "{}"}, self())
    assert model.notice == "Sent"
    task = completed(ctx.name, model.selected_id)
    assert task["cwd"] == ctx.folder
    assert task["workspace_id"] == id
    assert File.read!(Path.join(ctx.folder, "ran.txt")) == "run\n"
    refute File.exists?(Path.join(ctx.root, "ran.txt"))

    {:ok, %{project: other}} = Projects.open(ctx.config, ctx.root)

    assert {:error, :workspace_session_mismatch} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "wrong folder",
               "resume" => task["session_id"],
               "workspace_id" => other["id"]
             })

    assert {:ok, reply} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "{}",
               "resume" => task["session_id"]
             })

    followup = completed(ctx.name, reply["task_id"])
    assert followup["cwd"] == ctx.folder
    assert File.read!(Path.join(ctx.folder, "ran.txt")) == "run\nrun\n"
    refute File.exists?(Path.join(ctx.root, "ran.txt"))
    Console.close(model)
  end

  test "selecting a saved workspace prepares a fresh task there without reordering folders",
       ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    default = Enum.find(model.projects, &(&1["root"] == ctx.root))
    model = Console.perform(model, {:workspace, "second project"}, self())
    model = Console.perform(model, {:submit, "{}"}, self())
    old_id = model.selected_id
    assert completed(ctx.name, old_id)["cwd"] == ctx.folder
    projects = model.projects
    model = Console.perform(model, {:select_workspace, default["id"]}, self())
    assert model.projects == projects
    assert model.selected_id == nil
    assert model.workspace_root == ctx.root
    assert model.workspace_id == default["id"]
    assert model.entries == []
    model = Console.perform(model, {:submit, "{}"}, self())
    assert model.selected_id != old_id
    assert completed(ctx.name, model.selected_id)["cwd"] == ctx.root
    Console.close(model)
  end

  test "console completes directories on the service host without registering them", ctx do
    model = Console.perform(Console.new(socket: Config.socket_path(ctx.config)), :connect, self())

    assert {:ok, %{folders: folders, completion: completion}} =
             Console.complete_folders(model, "sec")

    assert folders == [ctx.folder <> "/"]
    assert completion == ctx.folder <> "/"
    assert {:error, _} = Console.complete_folders(model, "bad\npath")
    assert model.selected_id == nil
    assert model.workspace_root == ctx.root
    Console.close(model)
  end

  test "workspace registrations and queued folder choices survive restart", ctx do
    {:ok, %{project: project}} = Projects.open(ctx.config, ctx.folder)
    {:ok, %{project: same}} = Projects.open(ctx.config, ctx.folder)
    assert same["id"] == project["id"]

    assert {:ok, _} =
             Tasks.command(ctx.name, "submit", %{
               "id" => "delayed-folder",
               "profile" => "test",
               "task" => "later",
               "workspace_id" => project["id"],
               "delay_ms" => 60_000
             })

    stop_supervised!(Service)
    start_supervised!({Service, config: ctx.config, name: ctx.name})
    assert {:ok, folder} = Projects.root(ctx.config, project["id"], nil)
    assert folder == ctx.folder
    assert {:ok, %{"task" => task}} = Tasks.command(ctx.name, "get", %{"id" => "delayed-folder"})
    assert task["cwd"] == ctx.folder
    assert task["workspace_id"] == project["id"]
  end

  test "invalid folders and workspace identities are rejected before admission", ctx do
    assert {:error, :invalid_workspace_path} = Projects.open(ctx.config, "")
    assert {:error, :invalid_workspace_path} = Projects.open(ctx.config, "a\nb")
    assert {:error, {:project_not_directory, _}} = Projects.open(ctx.config, "missing")

    assert {:error, :unknown_workspace} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "bad",
               "workspace_id" => "not-registered"
             })

    # A raw client-supplied cwd cannot bypass the registered workspace choice.
    assert {:ok, reply} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "{}",
               "cwd" => ctx.folder
             })

    assert completed(ctx.name, reply["task_id"])["cwd"] == ctx.root
    assert File.exists?(Path.join(ctx.root, "ran.txt"))
    refute File.exists?(Path.join(ctx.folder, "ran.txt"))
  end

  defp completed(name, id, attempts \\ 150) do
    {:ok, %{"task" => task}} = Tasks.command(name, "get", %{"id" => id})

    cond do
      task["status"] == "completed" ->
        task

      attempts == 0 ->
        flunk("Task did not complete: #{inspect(task)}")

      true ->
        Process.sleep(20)
        completed(name, id, attempts - 1)
    end
  end
end
