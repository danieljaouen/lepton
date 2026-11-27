defmodule Lepton.FzfTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Fzf

  @lines ~w(music/david/source.mp3 src/lepton/fzf.ex lib/lepton/fuzzy_zone.ex README.md docs/fzf.md Makefile)

  test "matching: fuzzy, best first; exact, prefix, suffix, not, or; smart case" do
    assert hd(Fzf.filter(@lines, "mdsrc")) == "music/david/source.mp3"
    assert Fzf.filter(@lines, "fzf") == ["docs/fzf.md", "src/lepton/fzf.ex"]
    assert Fzf.filter(@lines, "'fzf .ex$") == ["src/lepton/fzf.ex"]
    assert Fzf.filter(@lines, "^lib | ^docs") == ["docs/fzf.md", "lib/lepton/fuzzy_zone.ex"]
    assert Fzf.filter(@lines, "lepton !fzf") == ["lib/lepton/fuzzy_zone.ex"]
    assert Fzf.filter(@lines, "make") == ["Makefile"]
    assert Fzf.filter(@lines, "MAKE") == []
    assert Fzf.filter(@lines, "qqq") == []
    # No query: in their order (--tac: the last first); -e: words match exactly.
    assert Fzf.filter(@lines, "") == @lines
    assert hd(Fzf.filter(@lines, "", tac: true)) == "Makefile"
    assert Fzf.filter(@lines, "mdsrc", exact: true) == []
    # A word boundary beats the middle of a word.
    assert Fzf.filter(["xxfzfxx", "a/fzf"], "fzf") == ["a/fzf", "xxfzfxx"]
  end

  test "the picker: best match at the bottom, by the prompt; keys move, Tab marks, the mouse clicks and scrolls" do
    st = Fzf.new(@lines, query: "fz")
    {lines, cursor, st} = Fzf.render(st, {8, 40})
    lines = Enum.map(lines, &String.replace(&1, "\e[0m", ""))
    assert List.last(lines) =~ "> fz" and Enum.at(lines, 6) =~ "3/6"
    assert Enum.at(lines, 5) =~ ~r/^\e\[1m>.*docs\/.*f.*z.*f\.md/
    assert cursor == {7, 4}
    assert Fzf.chosen(st) == ["docs/fzf.md"]

    # Up goes to the next match (it's above); typing narrows, Backspace widens.
    {:cont, st} = Fzf.key(st, "<up>")
    assert Fzf.chosen(st) == ["src/lepton/fzf.ex"]
    {:cont, st} = Fzf.key(st, "m")
    assert length(st.shown) == 1 and st.sel == 0
    {:cont, st} = Fzf.key(st, "DEL")
    assert length(st.shown) == 3

    # --reverse: the prompt at the top, down to the next.
    r = Fzf.new(@lines, reverse: true, multi: true)
    {[prompt, info | _], {0, 2}, _} = Fzf.render(r, {8, 40})
    assert prompt == "> \e[0m" or prompt =~ "> "
    assert info =~ "6/6"
    {:cont, r} = Fzf.key(r, "TAB")
    {:cont, r} = Fzf.key(r, "TAB")
    assert Fzf.chosen(r) == ["music/david/source.mp3", "src/lepton/fzf.ex"]
    {:cont, r} = Fzf.key(r, "<backtab>")
    # (Shift+Tab marks this one too, and goes back up)
    assert length(Fzf.chosen(r)) == 3 and r.sel == 1

    # The mouse (default layout, 8 rows: the list on rows 0-5, best at row 5).
    st = Fzf.new(@lines)
    {:cont, st} = Fzf.key(st, {:mouse, :press, :left, 3, 4, ""}, {8, 40}, 1000)
    assert Fzf.chosen(st) == ["src/lepton/fzf.ex"]
    assert {:accept, st} = Fzf.key(st, {:mouse, :press, :left, 3, 4, ""}, {8, 40}, 1200)
    assert Fzf.chosen(st) == ["src/lepton/fzf.ex"]
    {:cont, st} = Fzf.key(Fzf.new(@lines), {:mouse, :press, :wheel_up, 3, 4, ""}, {8, 40}, 0)
    assert st.sel == 3
    # Enter chooses, Esc gives up.
    assert {:accept, _} = Fzf.key(st, "RET")
    assert {:cancel, _} = Fzf.key(st, "ESC")
  end

  test "fzf -f filters what comes in (or the files here) without a terminal" do
    dir = tmp_dir("fzf")
    File.mkdir_p!(Path.join(dir, "music/david"))
    File.write!(Path.join(dir, "music/david/source.mp3"), "x")
    File.write!(Path.join(dir, "notes.txt"), "x")
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, ".git/HEAD"), "x")
    assert {"banana\n", 0} = sh("printf 'apple\\nbanana\\ncherry\\n' | fzf -f an")
    assert {"music/david/source.mp3\n", 0} = sh("fzf -f mdsrc", cwd: dir)
    # (.git is left out)
    assert {"music/david/source.mp3\nnotes.txt\n", 0} = sh("fzf -f ''", cwd: dir)
    assert {"", 1} = sh("fzf -f zzz", cwd: dir)
    assert {"fzf: unknown option: --bogus\n", 2} = sh("fzf --bogus 2>&1")
    assert {"fzf: no terminal" <> _, 2} = sh("printf 'a\\n' | fzf 2>&1")
    assert {"b\nbanana\n", 0} = sh("printf 'apple\\nbanana\\n' | FZF_DEFAULT_OPTS='--print-query' fzf -f b")
  end

  defp terminal(cwd \\ "/") do
    {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
    ctx = %Lepton.Ctx{cwd: cwd, env: %{"TERM" => "xterm-256color", "NO_COLOR" => "1", "HOME" => cwd}, tty: tty, stdin: tty, stdout: tty, stderr: tty}
    {ctx, tty}
  end

  defp type(tty, keys), do: for(k <- keys, do: (Lepton.TTY.input(tty, k); Process.sleep(80)))

  defp screen(tty, rows \\ 24) do
    {_, agent} = :sys.get_state(tty).backend
    Lepton.Screen.new(rows, 80) |> Lepton.Screen.feed(Lepton.TTY.Capture.output(agent)) |> Lepton.Screen.text()
  end

  test "on the terminal: type to narrow, Enter chooses; Esc gives up; files are found while you type" do
    {ctx, tty} = terminal()
    task = Task.async(fn -> Fzf.select(ctx, @lines) end)
    Process.sleep(150)
    assert screen(tty) =~ "6/6"
    type(tty, ["r", "e", "a", "d"])
    assert screen(tty) =~ "1/6"
    type(tty, ["\r"])
    assert Task.await(task) == {:ok, ["README.md"], "read"}

    task = Task.async(fn -> Fzf.select(ctx, @lines) end)
    Process.sleep(150)
    type(tty, ["\e"])
    Process.sleep(100)
    assert Task.await(task) == :cancel

    dir = tmp_dir("fzfwalk")
    for i <- 1..1200, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
    File.mkdir_p!(Path.join(dir, "deep/er"))
    File.write!(Path.join(dir, "deep/er/target.mp3"), "")
    task = Task.async(fn -> Fzf.select(ctx, {:walk, dir, []}) end)
    assert Enum.any?(1..100, fn _ -> Process.sleep(50); screen(tty) =~ ~r{\d+/\d+} end)
    type(tty, ["t", "a", "r", "g"])
    # (the files go on being found while you type: on a slow machine, a while)
    assert Enum.any?(1..100, fn _ -> Process.sleep(100); screen(tty) =~ "1/1201" end)
    type(tty, ["\r"])
    assert Task.await(task) == {:ok, ["deep/er/target.mp3"], "targ"}
  end

  # A mouse press at (col, row), from 0, as a terminal reports it.
  defp click(col, row), do: "\e[<0;#{col + 1};#{row + 1}M\e[<0;#{col + 1};#{row + 1}m"
  defp wheel(:down, row), do: "\e[<65;3;#{row + 1}M"

  test "the Media Player's and SNES's folder view: a click selects, a double click opens, the wheel moves; / finds below" do
    dir = tmp_dir("fbrowse")
    File.mkdir_p!(Path.join(dir, "Album/Disc 2"))
    File.write!(Path.join(dir, "Album/track.mp3"), "")
    File.write!(Path.join(dir, "Album/Disc 2/deep.mp3"), "")
    File.write!(Path.join(dir, "Album/Disc 2/other.mp3"), "")
    File.write!(Path.join(dir, "film.mp4"), "")
    {ctx, tty} = terminal(dir)
    me = self()

    opts = [
      title: "Media Player",
      entries: &Lepton.Player.CLI.entries/1,
      only: &Lepton.Player.CLI.media?/1,
      multi: true,
      open: fn d, files -> send(me, {:opened, d, files}); "opened" end
    ]

    task = Task.async(fn -> Lepton.FileBrowser.run(ctx, dir, opts) end)
    Process.sleep(150)
    # Rows: 0 the title, 2 "../", 3 "Album/", 4 "film.mp4".
    type(tty, [click(3, 3)])
    type(tty, [click(3, 3)])
    assert screen(tty) =~ "track.mp3"
    # Up again (Backspace), Album/ still selected; the wheel goes down to film.mp4; a double click plays it.
    type(tty, ["\d", wheel(:down, 3)])
    type(tty, [click(3, 4), click(3, 4)])
    assert_receive {:opened, ^dir, [film]}
    assert film == Path.join(dir, "film.mp4")

    # /: parts of a path; Enter opens it in its folder, with what comes after it.
    type(tty, ["/", "d", "e", "e", "p"])
    assert screen(tty) =~ "Album/Disc 2/deep.mp3"
    type(tty, ["\r"])
    assert_receive {:opened, d, [deep, other]}
    assert d == Path.join(dir, "Album/Disc 2") and Path.basename(deep) == "deep.mp3" and Path.basename(other) == "other.mp3"
    # Tab marks several: just those.
    type(tty, ["/", "m", "p", "3", "\t", "\t", "\r"])
    assert_receive {:opened, _, [_, _] = two}
    assert Enum.all?(two, &String.ends_with?(&1, ".mp3"))
    type(tty, ["q"])
    assert Task.await(task) == 0
  end

  test "lsh: C-r chooses from history, the line replaced (not run); M-c and C-t put in folders and files" do
    dir = tmp_dir("fzfsh")
    File.mkdir_p!(Path.join(dir, "my folder"))
    File.write!(Path.join(dir, "my folder/a file.txt"), "")
    {ctx, tty} = terminal(dir)
    shell = Lepton.Shell.new(ctx)
    shell = %{shell | history: ["git status", "ls -la", "git commit -m wip", "make test"]}

    line = Task.async(fn -> Lepton.Shell.LineEditor.read(shell, "$ ") end)
    Process.sleep(100)
    type(tty, ["\x12", "c", "o", "m"])
    assert screen(tty) =~ "1/4"
    type(tty, ["\r"])
    assert screen(tty) =~ "$ git commit -m wip"
    type(tty, ["\r"])
    assert Task.await(line) == {:ok, "git commit -m wip"}

    line = Task.async(fn -> Lepton.Shell.LineEditor.read(shell, "$ ") end)
    Process.sleep(100)
    type(tty, ["l", "s", " ", "\x14", "a", "f", "i", "l", "e", "\r", "\r"])
    assert Task.await(line) == {:ok, "ls my\\ folder/a\\ file.txt "}

    line = Task.async(fn -> Lepton.Shell.LineEditor.read(shell, "$ ") end)
    Process.sleep(100)
    # (Alt+c types ç while the accent keys are on; Esc, then c, is M-c.)
    type(tty, ["\e", "c", "m", "y", "\r"])
    assert Task.await(line) == {:ok, "cd my\\ folder"}
  end
end
