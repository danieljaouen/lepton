defmodule Lepton.ManTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Man

  test "every command, alias and shell builtin has a manual page" do
    without = for {_, c} <- Lepton.Commands.builtins(), Man.source(c.name) == nil, uniq: true, do: c.name
    assert without == [], "no man/NAME.md for #{inspect(without)}"
    names = for {name, _} <- Lepton.Commands.builtins(), do: name
    missing = for n <- names ++ Lepton.Shell.Builtins.names(), Man.page(n) == nil, do: n
    assert missing == []

    for n <- Man.names(), p = Man.page(n) do
      assert p.body =~ "## DESCRIPTION", "#{n}'s page has no DESCRIPTION"
      assert p.summary not in [nil, ""]
    end
  end

  test "every cross reference names a page" do
    pages = MapSet.new(Man.names())

    for n <- Man.names(), [ref, name] <- Regex.scan(~r/\b([a-z][\w.-]*)\(1\)/, Man.page(n).body) do
      assert MapSet.member?(pages, name), "#{n} refers to #{ref}, which has no page"
    end
  end

  test "man shows a page: NAME, SYNOPSIS from the code, then its sections" do
    {out, 0} = sh("man ls")
    assert out =~ ~r/^LS\(1\) +Lepton Manual +LS\(1\)\n/
    assert out =~ "NAME\n       ls - list directory contents\n"
    assert out =~ "SYNOPSIS\n       ls [-1aAlhRrtSdF] [FILE...]\n"
    # tagged options: a short tag shares its line, a long one doesn't
    assert out =~ "\n       -l     long format:"
    assert out =~ "\n       LSCOLORS\n              colours in BSD format"
    assert out =~ "\n           ls -la\n"
    refute out =~ "\e["
    refute out =~ "`"
  end

  test "aliases, sections and shell builtins" do
    {vim, 0} = sh("man vim")
    assert vim =~ "le, vi, vim, nvim, emacs"
    assert {^vim, 0} = sh("man 1 le")

    {cd, 0} = sh("man cd")
    assert cd =~ "cd - change the current directory to DIR (shell builtin)"
    assert cd =~ "SYNOPSIS\n       cd [DIR | -]"
    assert cd =~ "DESCRIPTION\n       Change the current directory"

    {all, 0} = sh("man builtins")
    for b <- Lepton.Shell.Builtins.names(), do: assert(all =~ ~r/(^ +|, )#{Regex.escape(b)}( |,|$)/m, "builtins(1) lacks #{b}")
  end

  test "lines fit MANWIDTH" do
    {out, 0} = sh("man git", env: %{"MANWIDTH" => "50"})
    long = for line <- String.split(out, "\n"), not String.starts_with?(line, "           "), String.length(line) > 50, do: line
    assert long == []
  end

  test "man -k searches names and summaries; -f gives one summary; unknown pages fail" do
    {out, 0} = sh("man -k usb")
    assert out =~ ~r/^eject\(1\) +- unmount a USB drive or SD card so it's safe to remove$/m
    assert out =~ "usb(1)"
    {out, 0} = sh("man -f grep")
    assert out =~ ~r/^grep\(1\) +- print lines that match patterns\n$/
    assert {"", 16} = sh("man frobnicate")
    assert {"", 16} = sh("man -k zzzzqqq")
  end

  test "apropos: names and summaries, -a every keyword, -t the pages' text with the words around; whatis" do
    {out, 0} = sh("apropos usb")
    assert out =~ ~r/^eject\(1\) +- unmount a USB drive or SD card so it's safe to remove$/m
    {out, 0} = sh("apropos -a disk usb")
    assert out =~ "lsblk(1)" and not (out =~ "eject(1)")
    {out, 0} = sh(~s(apropos "caps lock"))
    assert out =~ ~r/^keyboard\(1\) +- .*Caps Lock as Ctrl$/m
    assert {"", 16} = sh("apropos loadkeys")
    {out, 0} = sh("apropos -t loadkeys")
    assert out =~ ~r/^keyboard\(1\) +- .*\n    …console \(the kernel's keymap, as loadkeys would set it\)/m
    assert out =~ ~r/^apropos\(1\) .*\n    apropos -t loadkeys\n/m
    {out, 0} = sh("apropos --text --and magit push")
    assert out =~ "le(1)" and out =~ "P p push"
    assert {_, 2} = sh("apropos")
    {out, 0} = sh("whatis grep cd")
    assert out =~ ~r/^grep\(1\) +- print lines that match patterns\ncd\(1\) +- change the current directory/
    assert {_, 16} = sh("whatis frobnicate")
    {out, 0} = sh("man -k caps usb")
    assert out =~ "keyboard(1)" and out =~ "eject(1)"
  end

  test "a package's command without a page gets one from its summary" do
    Lepton.Commands.register("greet-man-test", fn _, _ -> 0 end, "say hello")
    {out, 0} = sh("man greet-man-test")
    assert out =~ "NAME\n       greet-man-test - say hello\n\nDESCRIPTION\n       Say hello.\n"
  end

  test "help COMMAND is the short form" do
    {out, 0} = sh("help ls")
    assert out == "ls - list directory contents\nusage: ls [-1aAlhRrtSdF] [FILE...]\n`man ls` for the manual\n"
  end

  test "colour: bold headings and code" do
    page = Man.render(Man.page("ls"), 80, true)
    assert page =~ "\e[1mOPTIONS\e[22m"
    assert page =~ "\e[1m-a\e[22m"
  end

  test "a code span holding a backtick (`` `a ``) shows as the code alone" do
    page = Man.render(Man.page("le"), 80, false)
    assert page =~ "'a goes to its line and `a to the very place"
    refute page =~ "``"
    assert Man.render(Man.page("le"), 80, true) =~ "\e[1m`a\e[22m"
  end

  test "the pager cuts and highlights around escape sequences" do
    line = "\e[1mbold\e[22m and plain"
    assert Lepton.Pager.fit(line, 80) == line
    assert Lepton.Pager.fit(line, 6) == "\e[1mbold\e[22m a"
    assert Lepton.Pager.highlight(line, ~r/m/) == "\e[1mbold\e[22m and plain"
    assert Lepton.Pager.highlight(line, ~r/an/) == "\e[1mbold\e[22m \e[7man\e[27md plain"
  end
end
