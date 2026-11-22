defmodule Lepton.BridgeTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  @client Path.expand("rootfs/usr/bin/lepton")

  # The client is an escript: the image's Erlang on Lepton, the build machine's here.
  defp lepton(path, args, opts \\ []) do
    escript = System.find_executable("escript") || "/usr/bin/escript"
    client = if File.exists?(@client), do: @client, else: "/usr/bin/lepton"
    System.cmd(escript, [client | args], [env: [{"LEPTON_BRIDGE", path}], stderr_to_stdout: true] ++ opts)
  end

  setup do
    dir = tmp_dir("bridge")
    path = Path.join([dir, "1000", "socket"])
    user = Lepton.Users.get("root")
    {:ok, acceptor} = Lepton.Bridge.listen_at(path, user)
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    %{path: path, dir: dir}
  end

  test "a native program runs Lepton's commands, with their output and status", %{path: path, dir: dir} do
    assert {"hello world\n", 0} = lepton(path, ["echo", "hello world"], cd: dir)
    assert {"it's\n", 0} = lepton(path, ["echo", "it's"])
    {out, 0} = lepton(path, ["pwd"], cd: dir)
    # (macOS resolves /var to /private/var)
    assert String.ends_with?(String.trim(out), Path.basename(dir))
    assert {_, 3} = lepton(path, ["-c", "exit 3"])
    {out, 127} = lepton(path, ["no-such-command"])
    assert out =~ "command not found"
  end

  test "a command line, and input sent with -i", %{path: path} do
    assert {"a\nb\n", 0} = lepton(path, ["-c", "echo a; echo b | grep b"])
    escript = System.find_executable("escript") || "/usr/bin/escript"
    client = if File.exists?(@client), do: @client, else: "/usr/bin/lepton"
    {out, 0} = System.cmd("/bin/sh", ["-c", "printf 'one\\ntwo\\nthree\\n' | #{escript} #{client} -i grep t"], env: [{"LEPTON_BRIDGE", path}])
    assert out == "two\nthree\n"
  end

  test "without Lepton, it says so" do
    {out, 1} = lepton("/nonexistent/socket", ["echo", "x"])
    assert out =~ "can't reach Lepton"
  end

  test "at Lepton's prompt, lepton runs the command itself" do
    assert {"hi\n", 0} = sh("lepton echo hi")
    assert {"x\n", 0} = sh("lepton -c 'echo x'")
  end
end
