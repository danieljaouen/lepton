defmodule Lepton.RunAsTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Apps, RunAs, Users}

  @user %Users{name: "carol", uid: 1234, gid: 1235, home: "/home/carol"}

  test "runas: a static aarch64 executable; root and other systems run programs directly" do
    exe = RunAs.executable()
    assert <<0x7F, "ELF", 2, 1, 1, _::binary-size(9), 2::little-16, 183::little-16, _::little-32, entry::little-64, _::binary>> = exe
    assert entry == 0x400000 + 64 + 2 * 56
    assert byte_size(exe) == 64 + 2 * 56 + 41 * 4
    assert RunAs.command(Users.get("root"), "/bin/prog", ["a"]) == {"/bin/prog", ["a"]}

    if Lepton.FD.supported?(),
      do: assert({"/run/lepton/runas", ["1234", "1235", "/bin/prog", "a"]} = RunAs.command(@user, "/bin/prog", ["a"])),
      else: assert(RunAs.command(@user, "/bin/prog", ["a"]) == {"/bin/prog", ["a"]})
  end

  defp run(exe, args) do
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, args: args])
    collect(port, "")
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, acc <> d)
      {^port, {:exit_status, s}} -> {acc, s}
    end
  end

  # Inside Lepton: the program really runs as the user.
  @tag :native
  test "runas sets the user, group and groups, and exits 126 when it can't run the program" do
    {exe, args} = RunAs.command(@user, "/bin/busybox", ["id"])
    # (no "groups=": the supplementary groups are gone)
    assert {"uid=1234 gid=1235\n", 0} = run(exe, args)
    {exe, args} = RunAs.command(@user, "/nonexistent", [])
    assert {"", 126} = run(exe, args)
  end

  @tag :native
  test "an app's folders in the home that root made become the user's" do
    home = tmp_dir("rahome")
    File.mkdir_p!(Path.join(home, ".config/mozilla/firefox/p"))
    File.write!(Path.join(home, ".config/mozilla/firefox/p/prefs.js"), "")
    :ok = Apps.prepare_home(home, @user, Apps.get("firefox"))

    for p <- [".cache", ".cache/lepton", ".config", ".config/mozilla", ".config/mozilla/firefox/p/prefs.js"] do
      assert %File.Stat{uid: 1234, gid: 1235} = File.stat!(Path.join(home, p)), p
    end
  end
end
