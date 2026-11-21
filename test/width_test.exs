defmodule Lepton.WidthTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Screen, Width}
  alias Lepton.Wayland.Font

  test "columns: two for Chinese, Japanese and Korean, one for the rest, none for controls" do
    assert Width.string("abc") == 3
    assert Width.string("日本語") == 6
    assert Width.string("한국어 ok") == 9
    assert Width.string("สวัสดี") == 4
    assert Width.string("ｱ１") == 3
    assert Width.grapheme("\e") == 0
    assert Lepton.Style.width("\e[31m中文\e[0m") == 4
    assert Width.slice("日本語abc", 0, 5) == {"日本 ", 5}
    assert Width.slice("日本語abc", 1, 4) == {" 本 ", 4}
    assert Width.pad("中", 4) == "中  "
  end

  test "the screen: a wide character takes two cells, wraps whole, and half of one overwritten blanks the other" do
    s = Screen.new(3, 6) |> Screen.feed("ab한국어x")
    assert Screen.text(s) == "ab한국\n어x"
    assert Screen.cell(s, 2, 0) == {"한", ""} and Screen.cell(s, 3, 0) == {"", ""}
    assert {s.x, s.y} == {3, 1}

    s = Screen.new(2, 6) |> Screen.feed("日本\r\e[1Cx")
    assert Screen.row_text(s, 0) == " x本"
    assert Screen.render_row(Screen.new(1, 4) |> Screen.feed("中a"), 0) == "中a "
  end

  test "the font: Unifont for what Terminus lacks, 16 pixels wide for wide characters" do
    assert Font.char_width(?a) == 8
    assert Font.char_width(0x65E5) == 16 and Font.has?(0x65E5)
    assert Font.char_width(0xD55C) == 16
    assert Font.char_width(0x0E01) == 8 and Font.has?(0x0E01)
    assert Font.text_width("Hi 日本") == 56
    assert [row | _] = Font.rows(0x65E5, <<255, 255, 255, 255>>, <<0, 0, 0, 255>>)
    assert byte_size(row) == 16 * 4
    assert Font.text_rows("日本", <<1, 1, 1, 1>>, <<0, 0, 0, 0>>, 40) |> hd() |> byte_size() == 40 * 4
  end

  test "ls lines up names in columns by their width" do
    dir = tmp_dir("lswide")
    for f <- ~w(日本語.txt a.txt), do: File.write!(Path.join(dir, f), "")
    {out, 0} = sh("ls", cwd: dir)
    assert out =~ ~r/a\.txt\s+日本語\.txt/
  end
end
