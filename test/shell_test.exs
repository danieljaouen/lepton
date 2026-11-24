defmodule Lepton.ShellTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Shell.Parser

  describe "parser" do
    test "words, quotes and escapes" do
      assert {:ok, {:list, [{{:pipeline, false, [{:simple, [], words, []}]}, :fg}]}} = Parser.parse(~s(echo 'a b' "c $X" d\\ e))
      assert length(words) == 4
    end

    test "pipelines, lists and redirections" do
      {:ok, {:list, items}} = Parser.parse("a | b && c || d; e > out 2>&1 &")
      assert length(items) == 2
      assert [{{:and_or, {:pipeline, false, [_, _]}, [{:and, _}, {:or, _}]}, :fg}, {{:pipeline, false, [{:simple, [], _, redirs}]}, :bg}] = items
      assert [{:out, 1, _}, {:dup, 2, 1}] = redirs
    end

    test "incomplete input is reported" do
      assert {:error, :incomplete} = Parser.parse("echo 'unterminated")
      assert {:error, :incomplete} = Parser.parse("if true; then")
      assert {:error, :incomplete} = Parser.parse("ls |")
    end

    test "alias expansion of the command word" do
      {:ok, {:list, [{{:pipeline, false, [{:simple, [], words, []}]}, :fg}]}} = Parser.parse("l /tmp", %{"l" => "ls -lah"})
      assert Enum.map(words, &Parser.literal/1) == ["ls", "-lah", "/tmp"]
    end
  end

  describe "execution" do
    test "echo, pipes and exit status" do
      assert {"hello world\n", 0} = sh("echo hello world")
      assert {"3\n", 0} = sh("printf 'a\\nb\\nc\\n' | wc -l | tr -d ' '")
      assert {_, 1} = sh("false")
      assert {"yes\n", 0} = sh("false || echo yes")
      assert {"", 1} = sh("false && echo no")
      assert {"1\n", 0} = sh("false; echo $?")
    end

    test "variables and expansions" do
      assert {"bar baz\n", 0} = sh("FOO=bar; echo $FOO baz")
      assert {"default\n", 0} = sh("echo ${UNSET:-default}")
      assert {"3\n", 0} = sh("X=abc; echo ${#X}")
      assert {"inner\n", 0} = sh("echo $(echo inner)")
      assert {"a b c\n", 0} = sh("for i in a b c; do printf \"$i \"; done; echo | tr -d '\\n'; echo") |> then(fn {o, s} -> {String.trim_leading(o) |> String.replace(" \n", "\n"), s} end)
    end

    test "control flow" do
      assert {"yes\n", 0} = sh("if test 1 -eq 1; then echo yes; else echo no; fi")
      assert {"no\n", 0} = sh("if [ a = b ]; then echo yes; else echo no; fi")
      assert {"0\n1\n2\n", 0} = sh("i=0; while [ $i -lt 3 ]; do echo $i; i=$(expr $i + 1); done")
    end

    test "redirections to files and here-strings" do
      dir = tmp_dir()
      assert {"", 0} = sh("echo one > f.txt; echo two >> f.txt", cwd: dir)
      assert File.read!(Path.join(dir, "f.txt")) == "one\ntwo\n"
      assert {"two\n", 0} = sh("grep tw < f.txt", cwd: dir)
      assert {"HELLO\n", 0} = sh("tr a-z A-Z <<< hello", cwd: dir)
      assert {"", 0} = sh("ls nonexistent 2> err.txt; true", cwd: dir)
      assert File.read!(Path.join(dir, "err.txt")) =~ "cannot access"
    end

    test "globbing and tilde" do
      dir = tmp_dir()
      for f <- ~w(a.ex b.ex c.txt), do: File.write!(Path.join(dir, f), "")
      assert {"a.ex b.ex\n", 0} = sh("echo *.ex", cwd: dir)
      {out, 0} = sh("echo ~", cwd: dir, home: "/home/x")
      assert out == "/home/x\n"
    end

    test "builtins change shell state" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "sub"))
      assert {out, 0} = sh("cd sub && pwd", cwd: dir)
      assert String.ends_with?(String.trim(out), "/sub")
      assert {"hi\n", 0} = sh("alias hi='echo hi'; eval hi")
      assert {"bar\n", 0} = sh("export FOO=bar; printenv FOO")
    end

    test "background jobs and wait" do
      assert {out, 0} = sh("sleep 0.1 & wait; echo done")
      assert out =~ "done"
    end

    test "a closed pipe stops the writer (SIGPIPE)" do
      assert {"y\ny\n", 0} = sh("yes | head -n 2")
    end

    test "command not found" do
      assert {_, 127} = sh("definitely-not-a-command")
    end
  end

  describe "zshrc import" do
    @tag :dotfiles
    test "aliases from the user's zshrc, Linux branch only" do
      entries = Lepton.Shell.Zshrc.parse(File.read!(Path.join(dotfiles_home(), ".zshrc")))
      aliases = for {:alias, k, v} <- entries, into: %{}, do: {k, v}
      assert aliases["l"] == "ls -lah"
      assert aliases["gc"] == "git commit -m"
      # Linux branch of the OS conditional, not the macOS one
      assert aliases["open"] == "xdg-open"
      # EDITOR=vim becomes an alias to Lepton's editor
      assert aliases["vim"] == "le"
      assert {:setopt, "interactive_comments", true} in entries
    end

    test "conditional blocks" do
      text = """
      if [[ "x$OS" == "xOSX" ]]
      then
          alias mac=yes
      else
          alias linux=yes
      fi
      alias always=yes
      """

      aliases = for {:alias, k, _} <- Lepton.Shell.Zshrc.parse(text), do: k
      assert "linux" in aliases and "always" in aliases
      refute "mac" in aliases
    end
  end

  describe "prompt" do
    test "starship format language" do
      out = Lepton.Shell.Prompt.render_format("[$user]($style) on [x](bold blue) ($missing)", fn
        "user" -> "root"
        "style" -> "green"
        _ -> ""
      end, false)

      assert out == "root on x "
    end
  end

  describe "arithmetic and loop control" do
    test "$((...)) integer arithmetic" do
      assert {"14 20 3 1 -3 1 1\n", 0} = sh("echo $((2 + 3 * 4)) $(( (2+3)*4 )) $((7 / 2)) $((7 % 3)) $((-5 + 2)) $((3 > 2 && 1)) $((!0))")
      assert {"x*2=12 7\n", 0} = sh(~s|x=6; echo "x*2=$((x * 2))" $(($x+1))|)
      assert {"0 1 2\n", 0} = sh("i=0; s=; while [ $i -lt 3 ]; do s=\"$s $i\"; i=$((i+1)); done; echo $s")
    end

    test "break and continue, including nested levels" do
      assert {"once\nafter\n", 0} = sh("while true; do echo once; break; done; echo after")
      assert {"1\n3\n", 0} = sh("for i in 1 2 3; do if [ $i = 2 ]; then continue; fi; echo $i; done")
      assert {"a1\nb1\n", 0} = sh("for i in a b; do for j in 1 2 3; do if [ $j = 2 ]; then continue 2; fi; echo $i$j; done; done")
      assert {"a1\ndone\n", 0} = sh("for i in a b; do for j in 1 2; do echo $i$j; break 2; done; done; echo done")
      assert {"still\n", 0} = sh("break; echo still")
    end
  end

  describe "highlighting" do
    test "every command word is checked, also after pipes and lists" do
      shell = Lepton.Shell.new(%Lepton.Ctx{cwd: "/", env: %{"PATH" => "/nonexistent"}})
      hl = &Lepton.Shell.LineEditor.highlight(&1, shell, true)
      green = &("\e[32m" <> &1 <> "\e[0m")
      red = &("\e[31m" <> &1 <> "\e[0m")

      assert hl.("echo hi | nosuchcmd") =~ red.("nosuchcmd")
      assert hl.("echo hi | grep h") =~ green.("grep")
      assert hl.("echo hi|nosuchcmd") =~ red.("nosuchcmd")
      assert hl.("true && nosuch1 || echo; nosuch2") |> then(&(&1 =~ red.("nosuch1") and &1 =~ green.("echo") and &1 =~ red.("nosuch2")))
      assert hl.("nosuchcmd | echo") =~ red.("nosuchcmd")
      assert hl.("echo 'a | b'") =~ "\e[33m'a | b'\e[0m"
    end
  end

  describe "commands of several lines" do
    # The line editor on a terminal whose output a Screen interprets: what it returns, and what shows.
    defp edit(history, inputs) do
      {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
      shell = Lepton.Shell.new(%Lepton.Ctx{cwd: "/", env: %{"PATH" => "/nonexistent", "TERM" => "xterm-256color"}, tty: tty, stdin: tty, stdout: tty, stderr: tty})
      line = Task.async(fn -> Lepton.Shell.LineEditor.read(%{shell | history: history}, "$ ") end)
      Process.sleep(100)
      for input <- inputs, do: (Lepton.TTY.input(tty, input); Process.sleep(80))
      {line, screen_of(tty), tty}
    end

    defp screen_of(tty) do
      {_, agent} = :sys.get_state(tty).backend
      Lepton.Screen.new(24, 80) |> Lepton.Screen.feed(Lepton.TTY.Capture.output(agent))
    end

    test "Shift+Enter (ESC RET) and pastes put lines in the command; Return runs them together" do
      {line, _, _} = edit([], ["ls", "\e\r", "j", "\r"])
      assert Task.await(line, 5000) == {:ok, "ls\nj"}
      {line, screen, _} = edit([], [Lepton.Keys.encode({:paste, "echo a\r\necho b"}), "\r"])
      assert Task.await(line, 5000) == {:ok, "echo a\necho b"}
      assert Lepton.Screen.row_text(screen, 0) =~ "$ echo a" and Lepton.Screen.row_text(screen, 1) == "echo b"
    end

    # Such a command in history used to be suggested across lines, and the
    # cursor and every redraw after it landed a line too low.
    test "one in history is suggested on the line being typed, by its first line; → takes all of it" do
      {line, screen, tty} = edit(["ls\nj"], ["l"])
      assert Lepton.Screen.row_text(screen, 0) == "$ ls…" and Lepton.Screen.row_text(screen, 1) == ""
      assert {screen.x, screen.y} == {3, 0}
      # Typing on redraws in place: still one line, the cursor after what's typed.
      Lepton.TTY.input(tty, "s")
      Process.sleep(80)
      screen = screen_of(tty)
      assert Lepton.Screen.row_text(screen, 0) == "$ ls…" and Lepton.Screen.row_text(screen, 1) == ""
      assert {screen.x, screen.y} == {4, 0}
      # → takes the whole command.
      Lepton.TTY.input(tty, "\e[C\r")
      assert Task.await(line, 5000) == {:ok, "ls\nj"}
    end
  end

  describe "completion" do
    # TAB in the line editor; the line it returns.
    defp complete(typed, cwd) do
      {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
      shell = Lepton.Shell.new(%Lepton.Ctx{cwd: cwd, env: %{"PATH" => "/nonexistent", "TERM" => "xterm", "NO_COLOR" => "1"}, tty: tty, stdin: tty, stdout: tty, stderr: tty})
      line = Task.async(fn -> Lepton.Shell.LineEditor.read(shell, "$ ") end)
      Process.sleep(100)
      Lepton.TTY.input(tty, typed <> "\t")
      Process.sleep(100)
      Lepton.TTY.input(tty, "\r")
      Task.await(line, 5000)
    end

    test "paths: in /, in a directory, and relative (a directory gets its slash, a file a space)" do
      dir = tmp_dir("complete")
      File.mkdir_p!(Path.join(dir, "sub/inner"))
      File.write!(Path.join(dir, "sub/notes.txt"), "")

      # The directory part is "/": "/us" was "/ussr/" (one letter too many).
      assert complete("l /us", "/") == {:ok, "l /usr/"}
      assert complete("l #{dir}/su", "/") == {:ok, "l #{dir}/sub/"}
      assert complete("l sub/i", dir) == {:ok, "l sub/inner/"}
      assert complete("l sub/no", dir) == {:ok, "l sub/notes.txt "}
      assert complete("l ./su", dir) == {:ok, "l ./sub/"}
    end
  end
end
