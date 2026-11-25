defmodule Lepton.ClocTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  # Files cloc 2.08 counted; its numbers are the expected ones.
  @elixir ~S'''
  defmodule A do
    @moduledoc """
    Docs.

    # not a comment, but in a doc
    """

    # a comment
    @doc "one line: code"
    def f, do: Path.wildcard("**/*.ex") # trailing
    def g, do: 1

    @typedoc """
    typedoc text: code, for cloc
    """
    def h, do: "/* not closed"
  end
  '''

  defp project do
    dir = tmp_dir("cloc")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), @elixir)
    File.write!(Path.join(dir, "lib/dup.ex"), @elixir)
    File.write!(Path.join(dir, "run"), "#!/bin/sh\n# hi\necho x\n")
    File.write!(Path.join(dir, "t.exs"), "IO.puts 1\n# c\n")
    File.write!(Path.join(dir, "r.md"), "# T\n\n<!-- hidden -->\ntext\n")
    File.write!(Path.join(dir, "image.png"), <<137, 80, 78, 71, 0, 0, 0>>)
    dir
  end

  test "counted as cloc 2.08 counts: Elixir's docs and # lines, /* ... */ as C comments, #! scripts, Elixir Script, Markdown; duplicates once" do
    r = Lepton.Cloc.run([project()])
    langs = Map.new(Lepton.Cloc.by_language(r.files))
    assert langs["Elixir"] == %{files: 1, blank: 3, comment: 5, code: 9}
    assert langs["Bourne Shell"] == %{files: 1, blank: 0, comment: 1, code: 2}
    assert langs["Markdown"] == %{files: 1, blank: 1, comment: 1, code: 2}
    assert langs["Elixir Script"] == %{files: 1, blank: 0, comment: 1, code: 1}
    assert map_size(langs) == 4
  end

  test "a C comment that closes takes the code it spans (cloc's way: \"**/*\" ... \"*/\")" do
    lang = Lepton.Cloc.language("x.ex")
    text = "a = \"**/*\"\nb = 1\nc = \"*/\"\nd = 2\n"
    # (cloc 2.08: from /* on line 1 to */ on line 3 goes, newlines too: lines
    # 1 and 3's remains make one line; so 2 of code, 2 "comments")
    assert Lepton.Cloc.count(text, lang) == %{blank: 0, comment: 2, code: 2}
  end

  test "the command: cloc's table, --by-file, --json, --csv, --md, --include-lang, --vcs=git" do
    dir = project()
    {out, 0} = sh("cloc --hide-rate .", cwd: dir)
    # (6 files: one a picture, one a duplicate)
    assert out =~ "       6 text files.\n       4 unique files.\n       2 files ignored."
    assert out =~ ~r/^Language\s+files\s+blank\s+comment\s+code$/m
    assert out =~ ~r/^Elixir\s+1\s+3\s+5\s+9$/m
    assert out =~ ~r/^SUM:\s+4\s+4\s+8\s+14$/m
    {out, 0} = sh("cloc --quiet --include-lang=Elixir .", cwd: dir)
    refute out =~ "text files" or out =~ "Markdown"
    {out, 0} = sh("cloc --by-file --quiet .", cwd: dir)
    assert out =~ ~r/^lib\/a\.ex\s+3\s+5\s+9$/m
    {out, 0} = sh("cloc --json .", cwd: dir)
    assert %{"Elixir" => %{"code" => 9, "nFiles" => 1}, "SUM" => %{"code" => 14}} = JSON.decode!(out)
    {out, 0} = sh("cloc --csv .", cwd: dir)
    assert out =~ "1,Elixir,3,5,9\n" and out =~ "4,SUM,4,8,14\n"
    {out, 0} = sh("cloc --md .", cwd: dir)
    assert out =~ "Elixir|1|3|5|9\n"
    {_, 2} = sh("cloc --frob .", cwd: dir)

    # In a repository: what git tracks, not what it ignores.
    Lepton.Git.Repo.init(dir)
    File.write!(Path.join(dir, ".gitignore"), "*.md\n")
    {out, 0} = sh("cloc --vcs=git --quiet .", cwd: dir)
    assert out =~ ~r/^Elixir\s+1/m and not (out =~ "Markdown")
  end
end
