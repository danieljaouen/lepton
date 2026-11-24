defmodule Lepton.NcduTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Ncdu

  # big/ (3000 bytes in a file, 1000 in sub/), small.txt (100), a hard link to
  # big's file, a symlink, an empty directory.
  defp tree do
    dir = tmp_dir("ncdu")
    File.mkdir_p!(Path.join(dir, "big/sub"))
    File.mkdir_p!(Path.join(dir, "empty"))
    File.write!(Path.join(dir, "big/data.bin"), :binary.copy("x", 3000))
    File.write!(Path.join(dir, "big/sub/more.bin"), :binary.copy("y", 1000))
    File.write!(Path.join(dir, "small.txt"), :binary.copy("z", 100))
    :ok = File.ln(Path.join(dir, "big/data.bin"), Path.join(dir, "zlink.bin"))
    :ok = File.ln_s("small.txt", Path.join(dir, "sym"))
    dir
  end

  defp text(screen), do: Enum.map(screen, &String.replace(&1, ~r/\e\[[0-9;]*m/, ""))

  test "the scan: sizes add up, a hard link counts once, symlinks aren't followed, empty directories are marked" do
    dir = tree()
    t = Ncdu.scan(dir)
    names = Enum.map(t.children, & &1.name)
    # Largest first.
    assert hd(names) == "big"
    big = Enum.find(t.children, &(&1.name == "big"))
    assert big.type == :directory and big.size >= 4000 and big.items == 4
    # The hard link's data is big's: counted once, flagged H.
    assert %{size: 0, flag: "H"} = Enum.find(t.children, &(&1.name == "zlink.bin"))
    assert %{type: :symlink, flag: "@"} = Enum.find(t.children, &(&1.name == "sym"))
    assert %{flag: "e", items: 1} = Enum.find(t.children, &(&1.name == "empty"))
    assert t.size == Enum.sum(Enum.map(t.children, & &1.size)) + File.lstat!(dir).size
  end

  test "browsing: move, open and leave directories, sort (again: reverse), bars or percentages" do
    dir = tree()
    st = Ncdu.new(Ncdu.scan(dir), dir)
    {screen, st} = Ncdu.render(st, 12, 70)
    lines = text(screen)
    assert hd(lines) =~ "ncdu"
    assert Enum.at(lines, 1) =~ "--- #{dir}"
    assert Enum.at(lines, 2) =~ ~r/\[##########\] big\/\s*$/
    assert List.last(lines) =~ "Items: 9"

    st = Ncdu.key(st, "l")
    assert Ncdu.dir_path(st) == Path.join(dir, "big")
    {screen, _} = Ncdu.render(st, 12, 70)
    assert Enum.at(text(screen), 2) =~ "data.bin"
    st = Ncdu.key(st, "h")
    assert st.path == [] and st.sel == 0

    # By name: a to z (directories first); n again: z to a.
    st = Ncdu.key(st, "n")
    {screen, _} = Ncdu.render(st, 12, 70)
    assert Enum.at(text(screen), 2) =~ "big/" and Enum.at(text(screen), 3) =~ "empty/"
    st = Ncdu.key(st, "n")
    {screen, _} = Ncdu.render(st, 12, 70)
    assert Enum.at(text(screen), 2) =~ "zlink.bin"

    # g: percentages instead of bars.
    st = Ncdu.key(Ncdu.key(st, "s"), "g")
    {screen, _} = Ncdu.render(st, 12, 70)
    assert Enum.at(text(screen), 2) =~ ~r/\[\s*\d+\.\d%\] big\//

    # A file can't be opened; i tells about it; ? shows the keys; q quits.
    st = Ncdu.key(Ncdu.key(st, "G"), "l")
    assert st.path == []
    {screen, _} = Ncdu.render(Ncdu.key(st, "i"), 20, 70)
    assert Enum.any?(text(screen), &(&1 =~ "Type:"))
    {screen, _} = Ncdu.render(Ncdu.key(st, "?"), 22, 70)
    assert Enum.any?(text(screen), &(&1 =~ "delete (asks first)"))
    assert Ncdu.key(st, "q").quit
  end

  test "d deletes after asking (sizes above it follow); r scans again" do
    dir = tree()
    st = Ncdu.new(Ncdu.scan(dir), dir) |> Ncdu.key("l")
    before = st.tree.size
    # (in big/: data.bin first)
    st = Ncdu.key(st, "d")
    {screen, _} = Ncdu.render(st, 12, 70)
    assert List.last(text(screen)) =~ "Delete data.bin? (y/N)"
    st = Ncdu.key(st, "n")
    assert File.exists?(Path.join(dir, "big/data.bin")) and st.msg == "Not deleted"

    st = st |> Ncdu.key("d") |> Ncdu.key("y")
    refute File.exists?(Path.join(dir, "big/data.bin"))
    assert st.msg == "Deleted data.bin" and st.tree.size == before - 3000

    # A new file appears after r.
    File.write!(Path.join(dir, "big/new.txt"), "hello")
    st = Ncdu.key(st, "r")
    assert st.rescan == Path.join(dir, "big")
    st = Ncdu.replace_dir(st, Ncdu.scan(st.rescan))
    assert Enum.any?(Ncdu.dir(st).children, &(&1.name == "new.txt")) and Ncdu.dir(st).name == "big"
  end

  # Scans / itself: quick on Lepton, minutes on a Mac's disk.
  @tag :native
  test "-x stays on one file system; the kernel's are left out" do
    t = Ncdu.scan("/", one_fs: true)
    proc = Enum.find(t.children, &(&1.name == "proc"))
    if proc, do: assert(proc.flag == "<" and proc.size == 0)
  end

  test "the command: without a terminal it prints the directory's contents, largest first" do
    dir = tree()
    {out, 0} = sh("ncdu #{dir}")
    [first | _] = String.split(out, "\n", trim: true)
    assert first =~ ~r/KiB  big\/$/
    assert out =~ "total, 9 items"
    assert {_, 1} = sh("ncdu /no/such/dir")
  end
end
