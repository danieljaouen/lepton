defmodule Lepton.EditorTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Editor
  alias Lepton.Editor.{Buffer, Keymap, Motion}

  # Drive the editor headlessly: feed keys, inspect state.
  defp editor(text, opts \\ []) do
    dir = tmp_dir("ed")
    path = Path.join(dir, opts[:name] || "file.ex")
    File.write!(path, text)
    ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => opts[:home] || dotfiles_home()}, tty: nil}
    {Editor.init([path], ctx), path}
  end

  defp keys(st, seq) when is_binary(seq), do: keys(st, Lepton.Keys.parse(seq))
  defp keys(st, list), do: Enum.reduce(list, st, &Editor.handle_key(&2, &1))
  defp text(st), do: Buffer.text(Editor.buf(st))
  defp cursor(st), do: Editor.win(st).cursor

  test "insert and escape" do
    {st, _} = editor("world\n")
    st = keys(st, "i h e l l o SPC ESC")
    assert text(st) == "hello world\n"
    assert st.mode == :normal
    # Alt+Enter (what a terminal window sends for Shift+Enter) breaks the line as Return does.
    st = keys(st, "A M-RET ! ESC")
    assert text(st) == "hello world\n!\n"
  end

  # The terminal reports clicks at cells from 0; the line numbers take 4
  # columns here (relative, in the user's editing.el) and the size is 24x80.
  test "the mouse: a click moves the cursor, a drag selects, the wheel scrolls, a click picks the window" do
    {st, _} = editor(Enum.map_join(1..60, "\n", &"line #{&1}\tx 한글 end") <> "\n")
    gutter = Lepton.Editor.Render.gutter(st, Editor.buf(st))
    click = fn st, x, y, action -> Editor.handle_key(st, {:mouse, action, :left, x, y, ""}) end

    # On line 3, at "n" of "line": column 2 of the text.
    st = click.(st, gutter + 2, 2, :press)
    assert cursor(st) == {2, 2}
    # Past the tab (to column 8), the wide characters take two columns each: "글" is at 12 and 13.
    st = click.(st, gutter + 13, 4, :press)
    assert cursor(st) == {4, 10}
    # Left of the text (the line numbers): column 0; past the end: the last character.
    assert cursor(click.(st, 0, 5, :press)) == {5, 0}
    assert cursor(click.(st, 70, 6, :press)) == {6, 14}

    # A drag selects from the press, as v: d deletes "ne 2\tx", up to the pointer.
    st = click.(st, gutter + 2, 1, :press)
    st = click.(st, gutter + 8, 1, :drag)
    assert st.mode == :visual and cursor(st) == {1, 7}
    st = click.(st, gutter + 8, 1, :release)
    st = keys(st, "d")
    assert Buffer.line(Editor.buf(st), 1) == "li 한글 end"
    # A click leaves visual mode; in insert mode it moves the cursor and stays inserting.
    st = keys(click.(st, gutter, 3, :press) |> click.(gutter + 3, 3, :drag), "ESC")
    st = keys(st, "i") |> click.(gutter + 4, 7, :press)
    assert st.mode == :insert and cursor(st) == {7, 4}
    st = keys(st, "ESC")

    # The wheel scrolls the window under the pointer three lines; the cursor stays on screen.
    st = Editor.handle_key(st, {:mouse, :press, :wheel_down, 10, 10, ""})
    assert Editor.win(st).top == 3
    st = Enum.reduce(1..5, st, fn _, st -> Editor.handle_key(st, {:mouse, :press, :wheel_down, 10, 10, ""}) end)
    assert Editor.win(st).top == 18 and elem(cursor(st), 0) == 18
    st = Editor.handle_key(st, {:mouse, :press, :wheel_up, 10, 10, ""})
    assert Editor.win(st).top == 15
    # A click under the scrolled window's top line is that line.
    assert cursor(click.(st, gutter, 0, :press)) == {15, 0}

    # Two windows side by side: a click in the left one selects it, there.
    st = keys(st, "SPC w /")
    right = st.active
    st = click.(st, gutter + 1, 2, :press)
    assert st.active != right and cursor(st) == {17, 1}
    # Its mode line just selects the window; the bottom line (the echo area) does nothing.
    st = click.(st, 60, 22, :press)
    assert st.active == right
    assert click.(st, 5, 23, :press) == st
  end

  test "visual block (C-v): yank and paste as a block, delete, change, I, A (and $A), r, case, o and O" do
    text = "abcdef\nghijkl\nmn\nopqrst\n"
    {st, _} = editor(text)

    # y: columns 0-2 of every line (the short one gives what it has); p puts them back as a block.
    st = keys(st, "C-v l l j j j y")
    assert st.mode == :normal and cursor(st) == {0, 0} and st.register == {:block, ["abc", "ghi", "mn", "opq"]}
    st = keys(st, "$ p")
    assert text(st) == "abcdefabc\nghijklghi\nmn    mn\nopqrstopq\n"
    st = keys(st, "u")
    assert text(st) == text

    # On an empty line (o, Escape) a block's rows become lines of their own,
    # and the empty line stays after them, apart from the lines below.
    st = keys(st, "g g o ESC p")
    assert text(st) == "abcdef\nabc\nghi\nmn\nopq\n\nghijkl\nmn\nopqrst\n"
    st = keys(st, "u u")
    assert text(st) == text

    # As typed: "ayy in the block (the second y starts a yank that o cancels;
    # o still opens the line), then "ap there: the block, then what was below.
    {st2, _} = editor("abcd\nefgh\nijkl\n")
    st2 = keys(st2, "C-v j l \" a y y o ESC \" a p")
    assert text(st2) == "abcd\nab\nef\n\nefgh\nijkl\n"
    # $ first: whole lines' ends; the same.
    {st2, _} = editor("abcd\nefgh\nijkl\n")
    st2 = keys(st2, "C-v j $ y o ESC p")
    assert text(st2) == "abcd\nabcd\nefgh\n\nefgh\nijkl\n"

    # Across a short line the block keeps its width (the column the cursor was going to).
    st = keys(st, "g g 0 l C-v l l j j y")
    assert st.register == {:block, ["bcd", "hij", "n"]}

    # d: the block goes, the rest of each line closes up; u brings it back.
    st = keys(st, "0 l C-v l j d")
    assert text(st) == "adef\ngjkl\nmn\nopqrst\n" and cursor(st) == {0, 1}
    st = keys(st, "u")
    assert text(st) == text

    # I: typed on the first line, put on every line of the block at Escape.
    st = keys(st, "g g 0 C-v j j I # SPC ESC")
    assert text(st) == "# abcdef\n# ghijkl\n# mn\nopqrst\n"
    st = keys(st, "u")
    # A: after the block; a line too short for it is padded.
    st = keys(st, "g g 0 3 l C-v j j A X ESC")
    assert text(st) == "abcdXef\nghijXkl\nmn  X\nopqrst\n"
    st = keys(st, "u")
    # $A: at the end of each line.
    st = keys(st, "g g C-v j j $ A ; ESC")
    assert text(st) == "abcdef;\nghijkl;\nmn;\nopqrst\n"
    st = keys(st, "u")

    # c: the block replaced on every line by what is typed.
    st = keys(st, "g g 0 l C-v j l c Z Z ESC")
    assert text(st) == "aZZdef\ngZZjkl\nmn\nopqrst\n"
    st = keys(st, "u")
    # r: every character of the block.
    st = keys(st, "g g 0 C-v j l r x")
    assert text(st) == "xxcdef\nxxijkl\nmn\nopqrst\n"
    st = keys(st, "u")
    # U: the case of the block.
    st = keys(st, "g g 0 C-v j U")
    assert text(st) == "Abcdef\nGhijkl\nmn\nopqrst\n"
    st = keys(st, "u")

    # o: the opposite corner; O: the other corner on the same line.
    st = keys(st, "g g 0 C-v l l j o")
    assert cursor(st) == {0, 0} and st.visual_start == {1, 2}
    st = keys(st, "O")
    assert cursor(st) == {0, 2} and st.visual_start == {1, 0}
    # The block is drawn; C-v again (or Escape) leaves it.
    {rows, _} = Lepton.Editor.Render.frame(st)
    assert length(rows) == 24
    st = keys(st, "C-v")
    assert st.mode == :normal and text(st) == text
  end

  test "marks: ma sets one, 'a goes to its line, `a to the very place, as motions too; they move with the text" do
    {st, _} = editor("one\n  two three\nfour\nfive\nsix\n")
    # ma on "three", away, then back: ' to the line's first non-blank, ` exactly.
    st = keys(st, "j w w m a G")
    assert cursor(st) == {4, 0}
    st = keys(st, "' a")
    assert cursor(st) == {1, 2}
    st = keys(st, "G ` a")
    assert cursor(st) == {1, 6}
    # '' goes back to the line the jump left from, and again returns (line-wise: its first non-blank).
    st = keys(st, "' '")
    assert elem(cursor(st), 0) == 4
    st = keys(st, "' '")
    assert cursor(st) == {1, 2}

    # A line added above moves the mark with its text.
    st = keys(st, "g g O z e r o ESC G ' a")
    assert cursor(st) == {2, 2} and Lepton.Editor.Buffer.line(Editor.buf(st), 2) == "  two three"

    # As a motion: d'a deletes from here to the mark's line, line-wise.
    st = keys(st, "G d ' a")
    assert text(st) == "zero\none\n"

    # Not set: says so and stays.
    st = keys(st, "g g ' q")
    assert cursor(st) == {0, 0} and st.message =~ "Mark not set: q"

    # :marks lists them.
    st = keys(st, "m b : m a r k s RET")
    assert st.message =~ "b 1:0"
  end

  test "uppercase marks name the file too: 'A from another buffer goes there" do
    {st, path} = editor("alpha\nbeta\ngamma\n")
    other = Path.join(Path.dirname(path), "other.txt")
    File.write!(other, "x\ny\n")
    st = keys(st, "j j m A")
    st = keys(st, ": e SPC") |> keys(String.graphemes(other) |> Enum.map(&if(&1 == " ", do: "SPC", else: &1))) |> keys("RET")
    assert Editor.buf(st).path == other
    st = keys(st, "' A")
    assert Editor.buf(st).path == path and cursor(st) == {2, 0}
  end

  test "registers: \"ay yanks into a, \"ap pastes it; \"A appends, \"_ forgets, \"0 is the last yank; in visual mode too" do
    {st, _} = editor("one\ntwo\nthree\n")
    # "ayy, then a delete into the unnamed register: "ap still pastes a.
    st = keys(st, "\" a y y j \" b y y j d d")
    assert text(st) == "one\ntwo\n" and st.register == {:line, ["three"]}
    st = keys(st, "g g \" a p")
    assert text(st) == "one\none\ntwo\n"
    st = keys(st, "\" b P")
    assert text(st) == "one\ntwo\none\ntwo\n"

    # "A appends to a; a count goes with it.
    st = keys(st, "G \" A y y \" a p")
    assert text(st) == "one\ntwo\none\ntwo\none\ntwo\n"
    st = keys(st, "u \" a 2 p")
    assert text(st) == "one\ntwo\none\ntwo\none\ntwo\none\ntwo\n"
    st = keys(st, "u")

    # "_ deletes without touching the unnamed register; "0 holds the last yank after a delete.
    st = keys(st, "g g y w")
    assert st.register == {:char, "one"}
    st = keys(st, "\" _ d d")
    assert st.register == {:char, "one"}
    st = keys(st, "d d \" 0 P")
    assert Lepton.Editor.Buffer.line(Editor.buf(st), 0) == "oneone"

    # An empty register says so.
    st = keys(st, "\" q p")
    assert st.message =~ "Register q is empty"

    # Visual: "ay yanks the selection into a; "ap over a selection replaces it with a.
    {st, _} = editor("alpha beta\n")
    st = keys(st, "v e \" a y w v e \" a p")
    assert text(st) == "alpha alpha\n"
    st = keys(st, ": r e g RET")
    assert st.message =~ "\"a alpha"

    # "+ is the clipboard.
    Lepton.Clipboard.put("clip")
    st = keys(st, "0 \" + P")
    assert text(st) == "clipalpha alpha\n"
  end

  test "dw on a line's last word stops at its end (not the newline); d} from a line's start is line-wise; v p at a line's end" do
    for {keys_, expected} <- [{"d w", "\ntwo\n\nfour\n"}, {"l d w", "o\ntwo\n\nfour\n"}, {"y w P", "oneone\ntwo\n\nfour\n"}, {"c w x ESC", "x\ntwo\n\nfour\n"}, {"d }", "\nfour\n"}] do
      {st, _} = editor("one\ntwo\n\nfour\n")
      assert text(keys(st, keys_)) == expected, keys_
    end

    {st, _} = editor("ab cd\n")
    st = keys(st, "y w w v $ p")
    assert text(st) == "ab ab \n"
  end

  test "a paste from the terminal (bracketed) goes in as it is: insert, normal and visual modes, prompts; one undo" do
    paste = fn st, text -> Editor.handle_key(st, {:paste, text}) end
    # Insert mode: newlines and indentation as pasted (no auto-indent added).
    {st, _} = editor("def f do\nend\n")
    st = keys(st, "A RET") |> paste.("  a = 1\r\n    b = 2") |> keys("ESC")
    assert text(st) == "def f do\n  a = 1\n    b = 2\nend\n"

    # Normal mode: before the cursor, staying normal; u takes it all back.
    {st, _} = editor("xy\n")
    st = keys(st, "l") |> paste.("1\n2")
    assert text(st) == "x1\n2y\n" and st.mode == :normal
    st = keys(st, "u")
    assert text(st) == "xy\n"

    # Visual: in place of the selection, even at the line's end.
    {st, _} = editor("one two\n")
    st = keys(st, "w v e") |> paste.("2")
    assert text(st) == "one 2\n" and st.mode == :normal

    # A prompt: on its line.
    {st, _} = editor("alpha\nbeta gamma\n")
    st = keys(st, "/") |> paste.("gam\nma")
    assert st.minibuffer.text == "gam ma"
    st = keys(st, "C-u") |> paste.("gamma") |> keys("RET")
    assert cursor(st) == {1, 5}
  end

  describe "project replace" do
    # A project of three files with matches (and one without), le on the first.
    defp project do
      dir = tmp_dir("projreplace")
      File.write!(Path.join(dir, "a.ex"), "foo = 1\nfoo + foo\n")
      File.write!(Path.join(dir, "b.ex"), "no match here\nx = foo\n")
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "sub/c.txt"), "the foo_id and bar_id\n")
      File.write!(Path.join(dir, "d.txt"), "nothing\n")
      ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dotfiles_home()}, tty: nil}
      {Editor.init([Path.join(dir, "a.ex")], ctx), dir}
    end

    defp typed(text), do: text |> String.graphemes() |> Enum.map(&if(&1 == " ", do: "SPC", else: &1))

    test "SPC p R: each match asks (y, n, then ! for the rest), across files; unsaved until :wa" do
      {st, dir} = project()
      st = keys(st, ["SPC", "p", "R"] ++ typed("foo") ++ ["RET"] ++ typed("baz") ++ ["RET"])
      assert st.query.at == {0, 0, 3} and st.message =~ "Replace with \"baz\"?"
      st = keys(st, "y n")
      assert text(st) == "baz = 1\nfoo + foo\n" and st.query.at == {1, 6, 9}
      st = keys(st, "y")
      # On to b.ex (no match in its first line), then the rest at once.
      assert Editor.buf(st).name == "b.ex" and st.query.at == {1, 4, 7}
      st = keys(st, "!")
      assert st.query == nil and st.message =~ "Replaced 4 occurrences in 3 files" and st.message =~ ":wa"
      assert File.read!(Path.join(dir, "sub/c.txt")) == "the foo_id and bar_id\n"
      st = keys(st, "SPC f S")
      assert st.message =~ "Saved 3 files"
      assert keys(st, "C-x s").message =~ "No changed files"
      assert File.read!(Path.join(dir, "a.ex")) == "baz = 1\nfoo + baz\n"
      assert File.read!(Path.join(dir, "b.ex")) == "no match here\nx = baz\n"
      assert File.read!(Path.join(dir, "sub/c.txt")) == "the baz_id and bar_id\n"
      assert File.read!(Path.join(dir, "d.txt")) == "nothing\n"
      _ = st
    end

    test ". replaces this one and stops; q stops; SPC p % takes a regexp and \\1" do
      {st, _dir} = project()
      st = keys(st, ["SPC", "p", "R"] ++ typed("foo") ++ ["RET", "x", "RET", "."])
      assert st.query == nil and text(st) == "x = 1\nfoo + foo\n" and st.message =~ "Replaced 1 occurrence in 1 file"
      st = keys(st, ["SPC", "p", "R"] ++ typed("foo") ++ ["RET", "y", "RET", "q"])
      assert st.query == nil and text(st) == "x = 1\nfoo + foo\n"

      st = keys(st, ["SPC", "p", "%"] ++ typed("(\\w+)_id") ++ ["RET"] ++ typed("\\1Id") ++ ["RET", "!"])
      assert Editor.buf(st).name == "c.txt" and text(st) == "the fooId and barId\n"

      # Nothing to replace: says so.
      st = keys(st, ["SPC", "p", "R"] ++ typed("zzz") ++ ["RET", "a", "RET"])
      assert st.query == nil and st.message =~ "No match"
    end
  end

  test "evil-escape with jk (editing.el)" do
    {st, _} = editor("\n")
    st = keys(st, "i a b c j k")
    assert st.mode == :normal
    assert text(st) == "abc\n"
  end

  test "operators, counts, text objects and undo" do
    {st, _} = editor("one two three\nfour\nfive\n")
    assert text(keys(st, "d w")) == "two three\nfour\nfive\n"
    assert text(keys(st, "2 d d")) == "five\n"
    assert text(keys(st, "w c i w T W O ESC")) == "one TWO three\nfour\nfive\n"
    assert text(keys(st, "d d u")) == "one two three\nfour\nfive\n"
    assert text(keys(st, "y y j p")) == "one two three\nfour\none two three\nfive\n"
    assert text(keys(st, "3 x")) == " two three\nfour\nfive\n"
    assert text(keys(st, "x .")) == "e two three\nfour\nfive\n"
  end

  test "change inside quotes and brackets" do
    {st, _} = editor(~s|call("arg", [1, 2])\n|)
    assert text(keys(st, ~s|f " c i " n e w ESC|)) == ~s|call("new", [1, 2])\n|
    assert text(keys(st, "f [ d i [")) == ~s|call("arg", [])\n|
  end

  test "visual line delete and sort-lines on , q (keybindings.el)" do
    {st, _} = editor("c\nb\na\nz\n")
    assert text(keys(st, "V j d")) == "a\nz\n"
    st2 = keys(st, "V j j , q")
    assert text(st2) == "a\nb\nc\nz\n"
  end

  @tag :dotfiles
  test "; opens the ex prompt and :s substitutes (keybindings.el binds ; to evil-ex)" do
    {st, _} = editor("foo foo\n")
    st = keys(st, "; s / f o o / b a r / g RET")
    assert text(st) == "bar bar\n"
  end

  @tag :dotfiles
  test ", w deletes trailing whitespace (keybindings.el)" do
    {st, _} = editor("a  \nb\t\n")
    assert text(keys(st, ", w")) == "a\nb\n"
  end

  test "saving deletes trailing whitespace (before-save-hook in editing.el)" do
    {st, path} = editor("x   \n")
    _ = keys(st, "SPC f s")
    assert File.read!(path) == "x\n"
  end

  test "align-repeat (editing.el defun)" do
    lines = ["a = 1", "long_name = 2", "b = 33"]
    assert Editor.align_lines(lines, ~r/=/) == ["a         = 1", "long_name = 2", "b         = 33"]
  end

  test "search is case-sensitive (case-fold-search nil)" do
    {st, _} = editor("Foo\nfoo\n")
    st = keys(st, "/ f o o RET n")
    assert cursor(st) == {1, 0}
  end

  test "SPC w / splits and C-l moves to the new window (evil-window-right)" do
    {st, _} = editor("text\n")
    st = keys(st, "SPC w /")
    assert map_size(st.windows) == 2
    right = st.active
    st = keys(st, "C-h")
    refute st.active == right
    st = keys(st, "C-l")
    assert st.active == right
  end

  test "motions" do
    {st, _} = editor("alpha beta.gamma\n")
    b = Editor.buf(st)
    assert Motion.word_forward(b, {0, 0}, :word) == {0, 6}
    assert Motion.word_forward(b, {0, 6}, :word) == {0, 10}
    assert Motion.word_forward(b, {0, 6}, :WORD) == {0, 16} |> then(fn _ -> Motion.word_forward(b, {0, 6}, :WORD) end)
    assert Motion.word_end(b, {0, 0}, :word) == {0, 4}
    assert {{0, 11}, :inclusive} = Motion.apply(b, {0, 0}, {"f", "g"}, 1)
  end

  @tag :dotfiles
  test "user keybindings are loaded from ~/.spacemacs.d/keybindings.el" do
    km = Keymap.build(Lepton.Dotfiles.emacs(dotfiles_home()))
    assert km.normal[[";"]] == :ex
    assert km.normal[["C-h"]] == :window_left
    assert km.normal[["C-j"]] == :window_down
    assert km.normal[[",", "w"]] == :delete_trailing_whitespace
    assert km.visual[[",", "q"]] == :sort_lines
    assert km.visual[[",", "a", "h"]] == :align_repeat
    assert km.insert[["C-h"]] == :backspace
    assert km.insert[["C-w"]] == :delete_backward_word
    assert km.insert[["C-y", ","]] == :tab_command
    refute Map.has_key?(km.insert, ["C-y"])
    assert km.completion[["C-n"]] == :completion_next
    assert km.magit[["Z"]] == :magit_stash
  end

  @tag :dotfiles
  test "editing variables come from editing.el" do
    e = Lepton.Dotfiles.emacs(dotfiles_home())
    assert e.vars["display-fill-column-indicator-column"] == 101
    assert e.vars["fill-column"] == 79
    assert e.vars["evil-escape-key-sequence"] == "jk"
    assert e.vars["display-line-numbers-type"] == "relative"
    assert hd(e.themes) == "monokai"
    assert "git" in e.layers and "tmux" in e.layers
    assert e.aliases["sl"] == "sort-lines"
  end

  test "rendering produces a full frame" do
    {st, _} = editor("defmodule X do\nend\n")
    {rows, cursor} = Lepton.Editor.Render.frame(st)
    assert length(rows) == 24
    assert cursor != nil
    assert Enum.any?(rows, &String.contains?(Lepton.Style.strip(&1), "file.ex"))
  end

  test "keyboard macros: qq records, q stops, @q plays, @@ repeats, counts, qQ appends" do
    {st, _} = editor("one\ntwo\nthree\nfour\nfive\nsix\n")
    # Record: wrap the line in brackets and go down.
    st = keys(st, "q q I [ ESC A ] ESC j q")
    assert st.message == "Recorded @q (7 keys)" and st.macro_rec == nil
    assert text(st) == "[one]\ntwo\nthree\nfour\nfive\nsix\n"
    st = keys(st, "@ q")
    assert text(st) =~ "[two]\nthree"
    st = keys(st, "@ @")
    assert text(st) =~ "[three]\nfour"
    st = keys(st, "2 @ q")
    assert text(st) == "[one]\n[two]\n[three]\n[four]\n[five]\nsix\n"
    assert elem(cursor(st), 0) == 5

    # qW appends to w; q in insert mode is text.
    {st, _} = editor("a\n")
    st = keys(st, "q w A q ESC q")
    assert text(st) == "aq\n"
    st = keys(st, "q W A ! ESC q @ w")
    assert text(st) == "aq!q!\n"

    # A register without a macro, and @@ before any @.
    {st, _} = editor("a\n")
    st = keys(st, "@ @")
    assert st.message =~ "No macro played yet"
    st = keys(st, "@ z")
    assert st.message =~ "Register z has no macro"
    # A macro that calls itself stops.
    st = keys(st, "q r A x ESC @ r q")
    st = keys(st, "@ r")
    assert st.message =~ "too deeply"
  end

  test "a macro stops where a motion fails: j past the last line ends it, its count and the macros that called it" do
    # As in Vim: 100@q on a 4-line file wraps each line once, not the last one 97 times.
    {st, _} = editor("one\ntwo\nthree\nfour\n")
    st = keys(st, "q q I [ ESC A ] ESC j q")
    st = keys(st, "1 0 0 @ q")
    assert text(st) == "[one]\n[two]\n[three]\n[four]\n"
    assert st.message =~ "Macro @q stopped" and st.motion_failed == false
    assert elem(cursor(st), 0) == 3

    # The recursive idiom (a macro that ends by calling itself) runs to the last line and stops there.
    {st, _} = editor("a\nb\nc\n")
    st = keys(st, "q r A ! ESC j q")
    st = keys(st, "q R @ r q")
    st = keys(st, "g g @ r")
    # (recording qR played it once already, on b)
    assert text(st) == "a!!\nb!!\nc!\n"

    # r takes its character as the next key: recorded and played by macros, repeated by `.`.
    {st, _} = editor("abcd\nefgh\n")
    st = keys(st, "q m r X l q @ m")
    assert text(st) == "XXcd\nefgh\n"
    st = keys(st, "j 0 r Y l .")
    assert text(st) == "XXcd\nYYgh\n"

    # f without the character fails too; typing j on the last line by hand is just a no-op.
    {st, _} = editor("x,y\nz\n")
    st = keys(st, "q f f , r ; q j 0 @ f")
    assert text(st) == "x;y\nz\n"
    st = keys(st, "j j")
    assert elem(cursor(st), 0) == 1 and st.motion_failed
    st = keys(st, "k @ f")
    assert text(st) == "x;y\nz\n" and st.message =~ "stopped"
  end

  describe "Org folding" do
    @org """
    * One
    body one
    ** One A
    text a
    ** One B
    text b
    * Two
    body two
    """

    defp screen(st) do
      {rows, _} = Lepton.Editor.Render.frame(st)
      Enum.map(rows, &Lepton.Style.strip/1)
    end

    defp shows?(st, text), do: Enum.any?(screen(st), &String.contains?(&1, text))
    defp line(st), do: elem(cursor(st), 0)

    test "TAB cycles a heading: folded, children, subtree" do
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "TAB")
      assert st.message == "FOLDED"
      assert shows?(st, "* One ...")
      refute shows?(st, "body one")
      refute shows?(st, "One A")
      assert shows?(st, "body two")

      st = keys(st, "TAB")
      assert st.message == "CHILDREN"
      assert shows?(st, "body one") and shows?(st, "** One A ...") and shows?(st, "** One B ...")
      refute shows?(st, "text a")

      st = keys(st, "TAB")
      assert st.message == "SUBTREE"
      assert shows?(st, "text a") and shows?(st, "text b")

      assert keys(st, "TAB").message == "FOLDED"
      # Not on a heading: nothing happens.
      assert keys(st, "j TAB").buffers == keys(st, "j").buffers
    end

    test "zm folds every heading, zr reveals everything" do
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "z m")
      assert shows?(st, "* One ...") and shows?(st, "* Two ...")
      refute shows?(st, "One A")
      refute shows?(st, "body two")

      st = keys(st, "z r")
      for t <- ["body one", "text a", "text b", "body two"], do: assert(shows?(st, t))
      refute shows?(st, "...")
    end

    test "j and k skip folded subtrees; za, zc and zo work under the cursor" do
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "z m")
      assert line(keys(st, "j")) == 6
      assert line(keys(st, "j k")) == 0
      # zo opens One; its children stay folded.
      st = keys(st, "z o")
      assert shows?(st, "body one") and shows?(st, "** One A ...")
      assert line(keys(st, "2 j")) == 2
      # za on a line inside One A's body toggles One A.
      st = keys(st, "2 j z a")
      assert shows?(st, "text a")
      st = keys(st, "j z c")
      assert line(st) == 2
      refute shows?(st, "text a")
    end

    test "S-TAB cycles the buffer: overview, contents, show all" do
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "<backtab>")
      assert st.message == "OVERVIEW"
      refute shows?(st, "One A")
      st = keys(st, "<backtab>")
      assert st.message == "CONTENTS"
      assert shows?(st, "One A") and shows?(st, "Two")
      refute shows?(st, "text a")
      st = keys(st, "<backtab>")
      assert st.message == "SHOW ALL"
      assert shows?(st, "text a")
    end

    test "a search opens the fold it lands in; edits keep folds" do
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "z m / t e x t SPC b RET")
      assert line(st) == 5 and shows?(st, "text b")
      # A line added above moves the folds down with their headings.
      {st, _} = editor(@org, name: "notes.org")
      st = keys(st, "G z c g g O n e w ESC")
      assert shows?(st, "* Two ...")
      refute shows?(st, "body two")
      assert MapSet.to_list(Editor.buf(st).folds) == [7]
    end

    test "O and o with folds: the new line shows, the folds stay; folding again hides it" do
      org = "* a\nbody a\n* b\nbody b\n"
      {st, _} = editor(org, name: "notes.org")
      # O above * b opens a line at the end of folded * a: it shows, and
      # what is typed goes there (not onto * a).
      st = keys(st, "z m j O x RET y ESC")
      assert text(st) == "* a\nbody a\nx\ny\n* b\nbody b\n"
      assert line(st) == 3 and shows?(st, "x") and shows?(st, "y") and shows?(st, "* a ...")
      refute shows?(st, "body a")
      assert MapSet.member?(Editor.buf(st).folds, 0)
      # o on folded * b opens below its subtree.
      st = keys(st, "j o z ESC")
      assert text(st) == "* a\nbody a\nx\ny\n* b\nbody b\nz\n"
      assert line(st) == 6 and shows?(st, "z") and not shows?(st, "body b")
      # zm folds them away again.
      st = keys(st, "z m")
      refute shows?(st, "x") or shows?(st, "z")
      assert Lepton.Editor.Fold.visible_lines(Editor.buf(st), 0, 10) == [0, 4]
    end

    test "outside Org, zm says there is nothing to fold" do
      {st, _} = editor("a\nb\n")
      st = keys(st, "z m")
      assert st.message =~ "No outline"
    end
  end

  test "SPC s p: RET opens the result's file at its line; motions such as b move in the results" do
    dir = tmp_dir("grepres")
    repo = Lepton.Git.Repo.init(dir)
    File.write!(Path.join(dir, "words.org"), "* one\n* badinage: light banter\n")
    Lepton.Git.add(repo, [dir])
    ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dotfiles_home()}, tty: nil}
    st = Editor.init([Path.join(dir, "words.org")], ctx)

    st = keys(st, "SPC s p b a d i n a g e RET")
    assert Editor.buf(st).name == "*grep*"
    assert cursor(st) == {2, 0}
    st = keys(st, "w w w")
    {_, col} = cursor(st)
    assert col > 0
    st = keys(st, "b")
    refute (st.message || "") =~ "not available"
    assert {2, back} = cursor(st)
    assert back < col
    st = keys(st, "G 0 RET")
    assert Editor.buf(st).path == Path.join(dir, "words.org")
    assert cursor(st) == {1, 0}
  end

  test "magit: s saves the file's buffer first and stages it, s on a section heading stages the section; commit with , c / C-c C-c / :wq, cancel with C-c C-k" do
    dir = tmp_dir("magit")
    repo = Lepton.Git.Repo.init(dir)
    File.write!(Path.join(dir, "words.org"), "* one\n")
    File.write!(Path.join(dir, "b.txt"), "b\n")
    Lepton.Git.add(repo, [dir])
    {:ok, _} = Lepton.Git.commit(repo, "one")
    File.write!(Path.join(dir, "new.txt"), "new\n")
    File.write!(Path.join(dir, "b.txt"), "b2\n")
    ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dotfiles_home()}, tty: nil}
    st = Editor.init([Path.join(dir, "words.org")], ctx)

    # An edit not saved yet: magit saves it, so it is there to stage.
    st = keys(st, "o * SPC t w o ESC SPC g s")
    assert st.message == "Saved words.org"
    assert File.read!(Path.join(dir, "words.org")) == "* one\n* two\n"
    lines = Buffer.lines(Editor.buf(st))
    at = Enum.find_index(lines, &(&1 =~ ~r/^modified\s+words.org/))
    st = keys(st, String.duplicate("j ", at) <> "s")
    assert {"words.org", :modified} in Lepton.Git.status(repo).staged
    assert {"b.txt", :modified} in Lepton.Git.status(repo).unstaged

    # On "Untracked files": every untracked file. On "Staged changes", u unstages them all.
    lines = Buffer.lines(Editor.buf(st))
    st = keys(st, "g g" <> String.duplicate(" j", Enum.find_index(lines, &String.starts_with?(&1, "Untracked files"))) <> " s")
    assert Enum.any?(Lepton.Git.status(repo).staged, &match?({"new.txt", _}, &1))
    lines = Buffer.lines(Editor.buf(st))
    st = keys(st, "g g" <> String.duplicate(" j", Enum.find_index(lines, &String.starts_with?(&1, "Staged changes"))) <> " u")
    assert Lepton.Git.status(repo).staged == []

    # Nowhere to stage from: it says so.
    st = keys(st, "g g s")
    assert st.message =~ "Nothing to stage here"

    # c c, then C-c C-k: canceled, back to the status, nothing committed.
    st = keys(st, "S c c")
    assert Editor.buf(st).kind == :commit and st.mode == :insert
    st = keys(st, "o o p s C-c C-k")
    assert st.message == "Commit canceled" and Editor.buf(st).kind == :magit and st.mode == :normal
    assert length(Lepton.Git.log(repo, 10)) == 1

    # , c commits (from normal state) and comes back to the status.
    st = keys(st, "c c T w o ESC , c")
    assert st.message =~ ~r/^\[\S+ [0-9a-f]{7}\] Two$/ and Editor.buf(st).kind == :magit
    assert hd(Lepton.Git.log(repo, 10)).subject == "Two" and Lepton.Git.status(repo).staged == []
    refute st.quit

    # C-c C-c from insert state, and :wq, commit too.
    File.write!(Path.join(dir, "b.txt"), "b3\n")
    st = keys(st, "S c c T h r e e C-c C-c")
    assert hd(Lepton.Git.log(repo, 10)).subject == "Three" and Editor.buf(st).kind == :magit
    File.write!(Path.join(dir, "b.txt"), "b4\n")
    st = keys(st, "g r S c c F o u r ESC : w q RET")
    assert hd(Lepton.Git.log(repo, 10)).subject == "Four" and Editor.buf(st).kind == :magit
    refute st.quit
  end
end
