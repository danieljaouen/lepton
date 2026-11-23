defmodule LeptonBuild.DotfilesSourceTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias LeptonBuild.Paths

  # The build tooling lives in the repository only (:docs), and needs git.
  @moduletag :docs

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@example.com"}, {"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@example.com"}])
    out
  end

  defp commit(dir, file, text) do
    File.write!(Path.join(dir, file), text)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-q", "-m", file])
  end

  test "builds take the dotfiles from their repository, brought up to date, whatever is checked out locally" do
    remote = tmp_dir("dotremote")
    git!(remote, ["init", "-q", "-b", "main"])
    commit(remote, "zshrc", "one\n")

    # Cloned the first time.
    copy = Path.join(tmp_dir("dotbuild"), "dotfiles")
    assert Paths.github_dotfiles(copy, remote) == copy
    assert File.read!(Path.join(copy, "zshrc")) == "one\n"
    assert Paths.dotfiles_source(copy) =~ ~r/#{remote} at [0-9a-f]{7}/

    # A later build (another run: no memo) brings it to the remote's head,
    # and local edits in the build's copy don't survive.
    commit(remote, "zshrc", "two\n")
    File.write!(Path.join(copy, "zshrc"), "edited\n")
    :persistent_term.erase({Paths, :dotfiles, copy})
    assert Paths.github_dotfiles(copy, remote) == copy
    assert File.read!(Path.join(copy, "zshrc")) == "two\n"

    # Offline: the copy from before.
    :persistent_term.erase({Paths, :dotfiles, copy})
    assert Paths.github_dotfiles(copy, "/nonexistent/dotfiles.git") == copy

    # Never fetched, and unreachable: no dotfiles.
    assert Paths.github_dotfiles(Path.join(tmp_dir("dotnone"), "dotfiles"), "/nonexistent/dotfiles.git") == nil
  end

  test "LEPTON_DOTFILES still names a local checkout, for a build of your own" do
    dir = tmp_dir("dotlocal")
    System.put_env("LEPTON_DOTFILES", dir)

    try do
      assert Paths.dotfiles() == dir
      assert Paths.dotfiles_source(dir) == Path.expand(dir)
    after
      System.delete_env("LEPTON_DOTFILES")
    end
  end
end

defmodule LeptonBuild.StripBeamTest do
  use ExUnit.Case

  # The build tooling lives in the repository only (:docs).
  @moduletag :docs

  test "the image's modules lose what records the build machine, and keep working" do
    [{mod, beam}] =
      Code.compile_string("""
      defmodule LeptonStripProbe do
        @moduledoc "A probe."
        @external_resource "/Users/someone/src/lepton/man/ls.md"
        @doc "Twice."
        def twice(x), do: 2 * x
      end
      """)

    stripped = LeptonBuild.Image.strip_beam(beam)
    {:ok, _, before} = :beam_lib.all_chunks(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(stripped)
    # Every chunk stays (code, docs, line numbers, ...) but those two.
    assert Enum.map(chunks, &elem(&1, 0)) == Enum.map(before, &elem(&1, 0)) -- [~c"Dbgi", ~c"CInf"]
    refute :binary.match(stripped, "/Users/someone") != :nomatch
    refute :binary.match(beam, "/Users/someone") == :nomatch, "(the probe did record the path before)"

    :code.purge(mod)
    :code.delete(mod)
    {:module, ^mod} = :code.load_binary(mod, ~c"in_memory", stripped)
    assert mod.twice(21) == 42
  after
    :code.purge(LeptonStripProbe)
    :code.delete(LeptonStripProbe)
  end
end
