defmodule Lepton.TypstTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  test "without the app: typst says how to install it; app update-all is root's" do
    unless Lepton.Typst.installed?() do
      {:ok, err} = StringIO.open("")
      assert {"", 1} = sh("typst compile x.typ", stderr: err)
      assert elem(StringIO.contents(err), 1) =~ "sudo app install typst"
    end

    {:ok, err} = StringIO.open("")
    assert {_, 1} = sh("app update-all", user: "nobody", stderr: err)
    assert elem(StringIO.contents(err), 1) =~ "app update-all"
  end

  test "the environment: its libraries, certificates and the font folders there are" do
    home = tmp_dir("typsthome")
    File.mkdir_p!(Path.join(home, ".fonts"))
    env = Lepton.Typst.env(%Lepton.Ctx{env: %{"HOME" => home, "LANG" => "C.UTF-8"}})
    assert env["TYPST_FONT_PATHS"] =~ Path.join(home, ".fonts")
    refute env["TYPST_FONT_PATHS"] =~ ".local/share/fonts"
    assert env["SSL_CERT_FILE"] =~ "ca-certificates.crt" and env["LANG"] == "C.UTF-8"
  end

  test "le: .typ files are Typst, commented with //" do
    b = Lepton.Editor.Buffer.new("paper.typ")
    assert b.mode == "Typst" and Lepton.Editor.Buffer.comment_prefix(b) == "// "
  end

  alias Lepton.Editor

  defp keys(st, seq), do: Enum.reduce(Lepton.Keys.parse(seq), st, &Editor.handle_key(&2, &1))

  defp editor(files, home, opts \\ []) do
    ctx = %Lepton.Ctx{cwd: home, env: %{"HOME" => home, "XDG_STATE_HOME" => tmp_dir("lestate")}, tty: nil}
    Editor.init(files, ctx, opts)
  end

  test "le --typst: a new ~/Documents/untitled.typ (then untitled-2), begun with a starter, unsaved" do
    home = tmp_dir("typsthome")
    ctx = %Lepton.Ctx{env: %{"HOME" => home}}
    path = Editor.untitled_typst(ctx)
    assert path == Path.join(home, "Documents/untitled.typ") and File.dir?(Path.join(home, "Documents"))
    File.write!(path, "")
    assert Editor.untitled_typst(ctx) == Path.join(home, "Documents/untitled-2.typ")

    st = editor([Path.join(home, "Documents/new.typ")], home, typst_starter: true)
    b = Editor.buf(st)
    assert b.mode == "Typst" and b.modified and Lepton.Editor.Buffer.text(b) =~ "= A Title"
    # An existing file is left as it is.
    st = editor([path], home, typst_starter: true)
    assert Lepton.Editor.Buffer.text(Editor.buf(st)) == ""
    # Not Typst: SPC m c says so.
    st = editor([Path.join(home, "notes.txt")], home)
    assert keys(st, "SPC m c").message == "Not a Typst file (.typ)"
  end

  test "Typst highlighting: headings, #code and its keywords, math, comments, strong" do
    hl = &Lepton.Editor.Syntax.highlight(&1, "Typst", nil, 0, false)
    assert hl.("= Heading") =~ "38;5;208;1"
    assert hl.("#let x = 1") =~ "38;5;197m#let"
    assert hl.("#table(columns: 2)") =~ "38;5;148m#table"
    assert hl.("so $a^2$ here") =~ "38;5;81m$a^2$"
    assert hl.("text // a note") =~ "38;5;242m// a note"
    assert hl.("a *bold* word") =~ "38;5;197m*bold*"
  end

  test "where typst's first error is, from its report" do
    out = "error: unknown variable: nope\n  ┌─ doc.typ:3:5\n  │\n3 │ #nope\n"
    assert Lepton.Typst.where(out) == {"doc.typ", 3, 5}
    assert Lepton.Typst.summary(out) == "error: unknown variable: nope"
    assert Lepton.Typst.where("warning: something\n") == nil
  end

  test "with Typst, in le: SPC m c goes to the error; fixed and saved, it compiles (on save)" do
    if Lepton.Typst.installed?() do
      home = tmp_dir("typsthome")
      path = Path.join(home, "doc.typ")
      File.write!(path, "= Title\n\nSome #nope here\n")
      st = editor([path], home)
      st = keys(st, "SPC m c")
      assert st.message =~ "unknown variable: nope" and st.message =~ "doc.typ:3:6" and st.message_error
      assert Editor.win(st).cursor == {2, 5}
      assert Enum.any?(Map.values(st.buffers), &(&1.name == "*typst*"))
      # Fix it (delete "#nope "), save: compiled.
      st = keys(st, "d W : w RET")
      assert st.message =~ "compiled doc.pdf"
      assert "%PDF" <> _ = File.read!(Path.join(home, "doc.pdf"))
      # SPC m w: no more compiling on save.
      st = keys(st, "SPC m w")
      assert st.message =~ "not compiling on save"
      File.rm!(Path.join(home, "doc.pdf"))
      st = keys(st, "x : w RET")
      refute File.exists?(Path.join(home, "doc.pdf"))
      _ = st
    end
  end

  test "with Typst: a document compiled to a PDF; an error reported, with its status" do
    if Lepton.Typst.installed?() do
      dir = tmp_dir("typst")
      File.write!(Path.join(dir, "doc.typ"), "= Title\nSome math: $a^2 + b^2 = c^2$\n#table(columns: 2, [a], [b])\n")
      assert {_, 0} = sh("typst compile doc.typ", cwd: dir, home: dir)
      assert "%PDF" <> _ = File.read!(Path.join(dir, "doc.pdf"))
      File.write!(Path.join(dir, "bad.typ"), "#let x = \n")
      assert {out, 1} = sh("typst compile bad.typ 2>&1", cwd: dir, home: dir)
      assert out =~ "expected expression" and out =~ "bad.typ:1"
    end
  end
end
