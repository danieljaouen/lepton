defmodule Lepton.MixVMTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  test "mix runs in a VM of its own" do
    {out, status} = sh("mix --version")
    assert status == 0
    assert out =~ "Mix #{System.version()}"
  end

  test "outside a project, Mix itself says so" do
    {out, status} = sh("cd #{tmp_dir("nomix")} && mix compile 2>&1")
    assert status != 0
    assert out =~ "mix.exs"
  end

  test "input is read only when Mix stops at a question" do
    assert Lepton.MixVM.prompt?("Shall I install Hex? (if running non-interactively, use \"mix local.hex --force\") [Yn] ")
    assert Lepton.MixVM.prompt?("Fetch and install dependencies? [Yn]")
    assert Lepton.MixVM.prompt?("Are you sure? ")
    refute Lepton.MixVM.prompt?("Compiling 12 files (.ex)")
    refute Lepton.MixVM.prompt?("")
  end

  @tag :native
  test "the VM is stopped when its Lepton process ends, however it ends" do
    port = Port.open({:spawn_executable, "/bin/busybox"}, [:binary, :exit_status, args: ["sleep", "60"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    owner = spawn(fn -> receive do: (:go -> :ok) end)
    Lepton.MixVM.guard(os_pid, owner, 2000)
    Process.exit(owner, :kill)
    assert_receive {^port, {:exit_status, _}}, 5000
  end
end
