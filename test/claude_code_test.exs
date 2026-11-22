defmodule Lepton.ClaudeCodeTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.ClaudeCode

  test "the app: what Claude Code needs from Alpine" do
    app = Lepton.Apps.get("claude-code")
    for p <- ~w(bash git ripgrep util-linux-misc ca-certificates-bundle), do: assert(p in app.packages)
    assert app.exe == nil and app.main == "bash"
  end

  test "the release manifest gives this platform's checksum and size" do
    sum = String.duplicate("ab", 32)
    json = JSON.encode!(%{"version" => "2.1.330", "platforms" => %{"linux-arm64-musl" => %{"checksum" => sum, "size" => 365_065_160}, "linux-arm64" => %{"checksum" => String.duplicate("cd", 32), "size" => 1}}})
    assert ClaudeCode.manifest_entry(json) == {:ok, sum, 365_065_160}
    assert {:error, msg} = ClaudeCode.manifest_entry(JSON.encode!(%{"platforms" => %{"linux-arm64" => %{"checksum" => sum, "size" => 1}}}))
    assert msg =~ "linux-arm64-musl"
    assert {:error, _} = ClaudeCode.manifest_entry("<html>not json")
  end

  test "a download is kept only with the right size and checksum" do
    file = Path.join(tmp_dir("cc"), "claude.part")
    File.write!(file, "the binary")
    sum = :crypto.hash(:sha256, "the binary") |> Base.encode16(case: :lower)
    assert ClaudeCode.verify(file, sum, 10) == :ok
    assert ClaudeCode.verify(file, sum, 11) == {:error, "the download is incomplete"}
    assert ClaudeCode.verify(file, String.duplicate("0", 64), 10) == {:error, "the download doesn't match its checksum"}
  end

  test "its environment: Alpine's bash and tools, its own ripgrep, no updater, glibc's VM left alone" do
    env = ClaudeCode.env(%{"HOME" => "/home/alice", "LD_LIBRARY_PATH" => "/x", "LANG" => "en_US.UTF-8"}, "/apps/cc")
    assert env["SHELL"] == "/apps/cc/bin/bash"
    assert env["HOME"] == "/home/alice" and env["LANG"] == "en_US.UTF-8"
    refute Map.has_key?(env, "LD_LIBRARY_PATH")
    assert env["USE_BUILTIN_RIPGREP"] == "0" and env["DISABLE_AUTOUPDATER"] == "1"
    assert env["GIT_EXEC_PATH"] == "/apps/cc/usr/libexec/git-core"
    [wrappers, alpine | rest] = String.split(env["PATH"], ":")
    assert wrappers =~ "claude-code/bin" and alpine == "/apps/cc/usr/bin"
    # busybox's applets come last: Alpine's programs win.
    assert List.last(rest) =~ "claude-code/busybox"
  end

  test "on a terminal it runs under script, sized, with its arguments quoted" do
    argv = ClaudeCode.script_argv(["-p", "it's"], {40, 120})
    assert ["--quiet", "--return", "--flush", "--command", cmd, "/dev/null"] = argv
    assert cmd =~ "stty rows 40 cols 120"
    assert cmd =~ ~s(exec '#{ClaudeCode.binary()}' '-p' 'it'\\''s')
  end

  test "children: the processes started by a process (for SIGWINCH)" do
    proc = tmp_dir("ccproc")
    for {pid, ppid} <- [{10, 1}, {11, 10}, {12, 10}, {13, 11}] do
      File.mkdir_p!(Path.join(proc, "#{pid}"))
      File.write!(Path.join([proc, "#{pid}", "stat"]), "#{pid} (some (odd) name) S #{ppid} 1 1 0\n")
    end
    File.mkdir_p!(Path.join(proc, "self"))
    assert Enum.sort(ClaudeCode.children(10, proc)) == [11, 12]
    assert ClaudeCode.children(13, proc) == []
  end

  test "claude and claude-code say how to install it" do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("ccstate"))

    try do
      {out, 1} = sh("claude 2>&1")
      assert out =~ "sudo claude-code install"
      {out, 1} = sh("claude-code")
      assert out =~ "isn't installed"
    after
      System.delete_env("LEPTON_STATE_DIR")
    end
  end

  @tag :native
  test "mix and elixir scripts run the image's Elixir in a VM of its own" do
    dir = tmp_dir("ccbin")
    :ok = ClaudeCode.write_wrappers(dir)
    mix = File.read!(Path.join(dir, "mix"))
    assert mix =~ "erlexec" and mix =~ "Mix.CLI.main()" and mix =~ ~s("$@")
    assert File.read!(Path.join(dir, "elixir")) =~ "-extra \"$@\""
  end
end
