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
end
