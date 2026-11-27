defmodule Lepton.TransposeTest do
  use ExUnit.Case

  alias Lepton.Transpose

  test "M-t, as Emacs: the words around the cursor change places; in a word, as at its end; at the end, the last two" do
    assert Transpose.words("abc def", 3) == {"def abc", 7}
    assert Transpose.words("abc def", 1) == {"def abc", 7}
    assert Transpose.words("abc def", 4) == {"def abc", 7}
    assert Transpose.words("abc def", 7) == {"def abc", 7}
    assert Transpose.words("one, two three", 3) == {"two, one three", 8}
    assert Transpose.words("a  b  c", 4) == {"a  c  b", 7}
    assert Transpose.words("héllo wörld", 2) == {"wörld héllo", 11}
    assert Transpose.words("solo", 2) == :none
    assert Transpose.words("", 0) == :none
  end

  test "lsh: M-t in the line editor" do
    {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
    ctx = %Lepton.Ctx{cwd: "/", env: %{"TERM" => "xterm", "NO_COLOR" => "1"}, tty: tty, stdin: tty, stdout: tty, stderr: tty}
    shell = Lepton.Shell.new(ctx)
    line = Task.async(fn -> Lepton.Shell.LineEditor.read(shell, "$ ") end)
    Process.sleep(100)
    # (Alt+t comes as ESC t; Esc, then t, too)
    for k <- ["git commit", "\et", "\r"], do: (Lepton.TTY.input(tty, k); Process.sleep(80))
    assert Task.await(line) == {:ok, "commit git"}
  end
end
