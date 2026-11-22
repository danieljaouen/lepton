defmodule Lepton.GitTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Git
  alias Lepton.Git.{Index, Object, Pack, Repo}

  test "object hashes match upstream git" do
    assert Object.hash(:blob, "hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a"
    assert Object.hash(:blob, "") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    assert Object.hash(:tree, "") == "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  end

  test "init, add, commit, status, log, diff via the git command" do
    dir = tmp_dir("git")
    env = %{"HOME" => dotfiles_home()}
    assert {_, 0} = sh("git init -b main", cwd: dir, env: env)
    File.write!(Path.join(dir, "README.md"), "hello\n")
    assert {out, 0} = sh("git status", cwd: dir, env: env)
    assert out =~ "Untracked files"
    assert {_, 0} = sh("git add README.md && git commit -m 'first commit'", cwd: dir, env: env)
    assert {out, 0} = sh("git status", cwd: dir, env: env)
    assert out =~ "nothing to commit"
    File.write!(Path.join(dir, "README.md"), "hello\nworld\n")
    assert {out, 0} = sh("git diff", cwd: dir, env: env)
    assert out =~ "+world"
    assert {_, 0} = sh("git commit -a -m second", cwd: dir, env: env)
    assert {out, 0} = sh("git log --oneline", cwd: dir, env: env)
    assert out =~ "second" and out =~ "first commit"

    repo = Repo.open(dir)
    head = Git.head_sha(repo)
    c = Git.read_commit(repo, head)
    assert c.subject == "second"
    assert [_parent] = c.parents
    assert %{"README.md" => {"100644", blob}} = Git.flatten_tree(repo, c.tree)
    assert blob == Object.hash(:blob, "hello\nworld\n")
  end

  @tag :dotfiles
  test "aliases and identity from the user's gitconfig" do
    dir = tmp_dir("gitalias")
    env = %{"HOME" => dotfiles_home()}
    sh("git init && touch a && git add a && git ci -m aliased", cwd: dir, env: env)
    assert {out, 0} = sh("git st", cwd: dir, env: env)
    assert out =~ "On branch"
    assert {out, 0} = sh("git gl", cwd: dir, env: env)
    assert out =~ "aliased"
    c = Git.read_commit(Repo.open(dir), Git.head_sha(Repo.open(dir)))
    assert c.author_email == "dcj24@cornell.edu"
  end

  test "branches, checkout and stash" do
    dir = tmp_dir("gitbr")
    repo = Repo.init(dir)
    File.write!(Path.join(dir, "f"), "1\n")
    Git.add(repo, [dir])
    {:ok, _} = Git.commit(repo, "one")
    :ok = Git.create_branch(repo, "feature")
    :ok = Git.checkout(repo, "feature")
    File.write!(Path.join(dir, "g"), "new\n")
    Git.add(repo, [dir])
    {:ok, _} = Git.commit(repo, "two")
    :ok = Git.checkout(repo, "main")
    refute File.exists?(Path.join(dir, "g"))
    File.write!(Path.join(dir, "f"), "changed\n")
    assert {:ok, _} = Git.stash(repo)
    assert File.read!(Path.join(dir, "f")) == "1\n"
    assert {:ok, _} = Git.stash_pop(repo)
    assert File.read!(Path.join(dir, "f")) == "changed\n"
  end

  # The lepton repository's site/ is a submodule: its tree entry is the
  # site repository's commit, which a clone of lepton doesn't have.
  test "a submodule checks out as an empty directory, and stays in the index, status, diffs and new trees" do
    dir = tmp_dir("gitsub")
    repo = Repo.init(dir)
    sub = "1bb7a7ddf038f478673a3bd325c1f56548b2491e"
    file = Object.write(repo, :blob, "hello\n")
    tree = Object.write(repo, :tree, Object.encode_tree([{"100644", "README.md", file}, {"160000", "site", sub}]))
    who = "A <a@example.com> 0 +0000"
    commit = Object.write(repo, :commit, "tree #{tree}\nauthor #{who}\ncommitter #{who}\n\nwith a submodule\n")
    Git.update_ref(repo, "refs/heads/main", commit)

    # What clone does after fetching: no "object 1bb7a7d... not found".
    files = Git.flatten_tree(repo, tree)
    assert files["site"] == {"160000", sub}
    Git.write_worktree(repo, %{}, files)
    assert File.read!(Path.join(dir, "README.md")) == "hello\n"
    assert File.dir?(Path.join(dir, "site")) and File.ls!(Path.join(dir, "site")) == []
    assert Index.read(repo)["site"].mode == 0o160000

    # Clean, even with files in the submodule's directory.
    File.write!(Path.join([dir, "site", "index.html"]), "x")
    assert %{staged: [], unstaged: [], untracked: []} = Git.status(repo)
    {:ok, _} = Git.add(repo, ["."])
    assert Index.read(repo)["site"].sha == sub
    refute Map.has_key?(Index.read(repo), "site/index.html")
    # A new tree keeps the submodule.
    assert {"160000", "site", ^sub} = Enum.find(Object.parse_tree(elem(Object.read!(repo, Git.write_tree(repo, Index.read(repo))), 1)), &(elem(&1, 1) == "site"))
    # A diff shows its commit, as git does.
    assert Git.commit_diff(repo, commit) =~ "+Subproject commit #{sub}"
  end

  test "index round trip" do
    dir = tmp_dir("gitidx")
    repo = Repo.init(dir)
    File.write!(Path.join(dir, "x"), "x")
    Git.add(repo, [dir])
    idx = Index.read(repo)
    Index.write(repo, idx)
    assert Index.read(repo) == idx
  end

  test "pack encode/decode and deltas" do
    objects = [{:blob, "hello\n"}, {:tree, ""}, {:blob, String.duplicate("abc", 1000)}]
    decoded = objects |> Pack.encode() |> Pack.decode()
    assert Enum.map(decoded, fn {_sha, t, c} -> {t, c} end) == objects
    assert Enum.map(decoded, &elem(&1, 0)) == Enum.map(objects, fn {t, c} -> Object.hash(t, c) end)
    # delta: base 5, target 10, copy 5 bytes from 0, insert "world"
    delta = <<5, 10, 0x90, 5, 5>> <> "world"
    assert Pack.apply_delta("hello", delta) == "helloworld"
  end

  test "gitignore rules" do
    dir = tmp_dir("gitign")
    repo = Repo.init(dir)
    File.write!(Path.join(dir, ".gitignore"), "_build/\n*.log\n!keep.log\n")
    File.mkdir_p!(Path.join(dir, "_build"))
    for f <- ~w(a.ex b.log keep.log _build/out), do: File.write!(Path.join(dir, f), "")
    assert Enum.sort(Git.worktree_files(repo)) == [".gitignore", "a.ex", "keep.log"]
  end

  @tag :network
  test "clone a small public repository from GitHub" do
    dir = Path.join(tmp_dir("clone"), "hello")
    assert {:ok, _} = Lepton.Git.Remote.clone("https://github.com/octocat/Hello-World.git", dir)
    assert File.exists?(Path.join(dir, "README"))
    assert Git.log(Repo.open(dir), 1) != []
  end
end
