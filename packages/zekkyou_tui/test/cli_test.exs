defmodule Zekkyou.TUI.CLITest do
  use ExUnit.Case, async: true
  alias Zekkyou.TUI.CLI

  test "local options and help do not require a remote host" do
    assert {:ok, [socket: "/tmp/service.sock"]} = CLI.options(["--socket", "/tmp/service.sock"])
    assert {:ok, []} = CLI.options([])
    assert :help = CLI.options(["--help"])
  end

  test "ambiguous transports and incomplete remote options fail before starting a terminal" do
    assert {:error, :remote_socket_required} = CLI.options(["--ssh", "host"])
    assert {:error, :ssh_host_required} = CLI.options(["--port", "2222"])

    assert {:error, :choose_socket_or_ssh} =
             CLI.options(["--ssh", "host", "--remote-socket", "/remote", "--socket", "/local"])

    assert {:error, _} = CLI.options(["--unknown"])

    assert {:error, :invalid_port} =
             CLI.options(["--ssh", "host", "--remote-socket", "/remote", "--port", "0"])
  end
end
