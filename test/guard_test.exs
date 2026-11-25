defmodule Lepton.GuardTest do
  use ExUnit.Case

  # Is a process with this command line running (not a zombie)?
  defp running?(marker) do
    Enum.any?(Path.wildcard("/proc/[0-9]*"), fn dir ->
      with {:ok, cmd} <- File.read(Path.join(dir, "cmdline")),
           true <- String.contains?(cmd, marker),
           {:ok, stat} <- File.read(Path.join(dir, "stat")) do
        not String.contains?(stat, ") Z ")
      else
        _ -> false
      end
    end)
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  # A program that never reads its input (a server, say) outlives its
  # port's closing; the guard stops it when its Lepton process ends.
  test "a native program goes when the process that started it is killed" do
    if File.dir?("/proc/self") do
      n = "#{System.unique_integer([:positive])}.5"
      me = self()

      owner =
        spawn(fn ->
          # (busybox's sleep: the VM's tests have no sleep on their PATH)
          {exe, args} = if File.exists?("/bin/busybox"), do: {"/bin/busybox", ["sleep", n]}, else: {System.find_executable("sleep"), [n]}
          port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args])
          Lepton.Sys.guard(port)
          send(me, :started)
          Process.sleep(:infinity)
        end)

      assert_receive :started, 2000
      assert eventually(fn -> running?("sleep\0" <> n) end)
      Process.exit(owner, :kill)
      assert eventually(fn -> not running?("sleep\0" <> n) end)
    end
  end

  test "the shell's native programs too (run_native: services you make, Ctrl-C)" do
    if File.exists?("/bin/busybox") and File.dir?("/proc/self") do
      n = "#{System.unique_integer([:positive])}.25"
      ctx = %Lepton.Ctx{cwd: "/", env: %{"PATH" => "/bin"}, stdout: Process.group_leader()}
      task = spawn(fn -> Lepton.Commands.System.run_native("/bin/busybox", ["sleep", n], ctx) end)
      assert eventually(fn -> running?("sleep\0" <> n) end)
      Process.exit(task, :kill)
      assert eventually(fn -> not running?("sleep\0" <> n) end)
    end
  end
end
