defmodule Lepton.OwnershipTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Users

  test "own_new: returns what it ran, and leaves paths that existed alone" do
    dir = tmp_dir("own")
    assert {:ok, :done} = Users.own_new(%Lepton.Ctx{user: "root"}, Path.join(dir, "x"), fn -> {:ok, :done} end)
    File.write!(Path.join(dir, "y"), "")
    before = File.stat!(Path.join(dir, "y")).uid
    assert :ok = Users.own_new(%Lepton.Ctx{user: "nobody-here"}, Path.join(dir, "y"), fn -> File.write(Path.join(dir, "y"), "z") end)
    assert File.stat!(Path.join(dir, "y")).uid == before
  end

  # Lepton runs as root: what a user's commands create must be theirs.
  @tag :native
  test "what a user creates is theirs: redirects, tee, touch, mkdir -p, cp, ln -s, git; root's own files stay root's" do
    name = "dora#{System.unique_integer([:positive])}"
    root = tmp_dir("ownhome")
    {:ok, user} = Users.create(name, "explorer1", home_root: root)
    on_exit(fn -> Users.delete(name) end)
    home = Path.join(root, name)
    # Made with sudo, long ago: stays root's.
    File.write!(Path.join(home, "roots.txt"), "root's\n")
    File.chown!(Path.join(home, "roots.txt"), 0)
    File.touch!(Path.join(home, "roots.txt"), System.os_time(:second) - 3600)

    script = """
    echo hi > a.txt; echo more >> a.txt; echo err &> both.txt
    echo t | tee tee.txt > /dev/null
    touch t.txt; mkdir -p d/e/f; cp a.txt b.txt; cp -r d d2; ln -s a.txt link
    echo appended >> roots.txt
    git init -q repo; cp a.txt repo/; cd repo; git add a.txt
    """

    assert {_, 0} = sh(script, user: name, home: home, cwd: home)
    uid = fn p -> File.lstat!(Path.join(home, p)).uid end

    for p <- ~w(a.txt both.txt tee.txt t.txt d d/e d/e/f b.txt d2 d2/e/f link repo repo/.git repo/.git/index repo/a.txt),
        do: assert(uid.(p) == user.uid, "#{p} is root's")

    objects = Path.wildcard(Path.join(home, "repo/.git/objects/*/*"))
    assert objects != [] and Enum.all?(objects, &(File.stat!(&1).uid == user.uid))
    # Writing to a file that exists doesn't change its owner.
    assert uid.("roots.txt") == 0
    assert File.read!(Path.join(home, "roots.txt")) == "root's\nappended\n"
  end

  @tag :native
  test "ssh's known hosts in a home are its user's; the repair at boot gives back what was left root's" do
    name = "ollie#{System.unique_integer([:positive])}"
    root = tmp_dir("ownrepair")
    {:ok, user} = Users.create(name, "explorer1", home_root: root)
    on_exit(fn -> Users.delete(name) end)
    home = Path.join(root, name)

    # The first host ssh records makes ~/.ssh: the user's, not root's.
    key = Lepton.SSH.generate()
    Lepton.SSH.add_known_host(Path.join(home, ".ssh/known_hosts"), "example.com", 22, Lepton.SSH.public(key))
    assert File.lstat!(Path.join(home, ".ssh")).uid == user.uid
    assert File.lstat!(Path.join(home, ".ssh/known_hosts")).uid == user.uid

    # What an older Lepton left root's (a directory, a file in it, a history file).
    File.mkdir_p!(Path.join(home, "src/words"))
    File.write!(Path.join(home, "src/words/notes.org"), "* notes\n")
    File.write!(Path.join(home, ".lsh_history"), "ls\n")
    for p <- ~w(src src/words src/words/notes.org .lsh_history), do: File.chown!(Path.join(home, p), 0)
    outside = Path.join(root, "not-a-home.txt")
    File.write!(outside, "root's\n")

    # (the test's home isn't /home/NAME, where repair_homes/0 looks)
    Users.repair_home(user, home)
    for p <- ~w(src src/words src/words/notes.org .lsh_history), do: assert(File.lstat!(Path.join(home, p)).uid == user.uid, "#{p} is root's")
    # Outside anyone's home: left alone.
    assert File.lstat!(outside).uid == 0
  end

  @tag :native
  test "chown -R: the links themselves (also one pointing nowhere), never what they point at; it goes on past an error" do
    name = "pat#{System.unique_integer([:positive])}"
    root = tmp_dir("chownr")
    {:ok, user} = Users.create(name, "explorer1", home_root: root)
    on_exit(fn -> Users.delete(name) end)
    dir = Path.join(root, "tree")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/file"), "x")
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "root's")
    File.ln_s!(outside, Path.join(dir, "to-outside"))
    File.ln_s!("/no/such/file", Path.join(dir, "dangling"))

    assert {_, 0} = sh("chown -R #{name} #{dir}")
    for p <- ["", "sub", "sub/file", "to-outside", "dangling"], do: assert(File.lstat!(Path.join(dir, p)).uid == user.uid, "#{p} wasn't changed")
    assert File.lstat!(outside).uid == 0

    # Something it can't change: says which, and does the rest.
    assert {_, 1} = sh("chown -R #{name} #{dir} /no/such/place")
  end
end
