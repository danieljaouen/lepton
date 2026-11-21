defmodule Lepton.KeyboardTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Hangul, Keyboard}
  alias Lepton.Wayland.{Keymap, Layouts}

  setup do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("kbstate"))

    on_exit(fn ->
      Keyboard.set_sources(["us"])
      System.delete_env("LEPTON_STATE_DIR")
    end)
  end

  test "Hangul: 2-set keys compose syllables, a vowel takes the final consonant along, Backspace takes back a jamo" do
    for {keys, text} <- [
          {"dkssudgktpdy", "안녕하세요"},
          {"gksrnrdj", "한국어"},
          {"ekfrrk", "닭가"},
          {"ekfrk", "달가"},
          {"dhks", "완"},
          {"Rkcl", "까치"},
          {"dmlwk", "의자"},
          {"qnpfr", "뷁"},
          {"dlTek", "있다"},
          {"rr", "ㄱㄱ"},
          {"dkssud gktpdy", "안녕 하세요"}
        ],
        do: assert(Hangul.compose(keys) == text, keys)

    {s, "", "ㅎ"} = Hangul.type(Hangul.new(), "ㅎ")
    {s, "", "하"} = Hangul.type(s, "ㅏ")
    {s, "", "한"} = Hangul.type(s, "ㄴ")
    # 한 + ㅏ: the ㄴ starts the next syllable.
    assert {["ㄴ", "ㅏ"], "하", "나"} = Hangul.type(s, "ㅏ")
    assert Hangul.backspace(s) == {["ㅎ", "ㅏ"], "하"}
    assert Hangul.backspace([]) == nil
    assert Hangul.jamo("r") == "ㄱ" and Hangul.jamo("R") == "ㄲ" and Hangul.jamo("K") == "ㅏ" and Hangul.jamo("1") == nil
  end

  test "input sources: set, use, next, kept in the state directory; layouts become XKB groups" do
    assert {:ok, %{sources: ["us", "ko", "th"], current: "us"}} = Keyboard.set_sources(["us", "ko", "th"])
    assert {:ok, %{current: "ko", hangul: true}} = Keyboard.next()
    assert {:ok, %{hangul: false}} = Keyboard.toggle_hangul()
    assert {:ok, %{current: "th", hangul: true}} = Keyboard.next()
    assert {:ok, %{current: "us"}} = Keyboard.next()
    assert {:ok, %{current: "th"}} = Keyboard.use("th")
    assert {:error, _} = Keyboard.use("hi")
    assert {:error, "unknown input source: xx" <> _} = Keyboard.set_sources(["us", "xx"])
    assert {:error, "at most 3 layouts" <> _} = Keyboard.set_sources(~w(us th hi ar he))
    assert File.read!(Path.join(System.get_env("LEPTON_STATE_DIR"), "keyboard")) == "sources us ko th\ncurrent th\n"

    # Korean types with the US keys: groups are US, then Thai.
    assert Keyboard.groups(["us", "ko", "th"]) == ["us", "th"]
    assert Keyboard.group(%{sources: ["us", "ko", "th"], current: "th"}) == 1
    assert Keyboard.group(%{sources: ["us", "ko", "th"], current: "ko"}) == 0
    assert Keyboard.group_layout(1) == "th"
    assert length(Keyboard.known()) == 2 + length(Layouts.ids())

    # Lepton's own windows: the group's character, but Ctrl+key is still the US one.
    assert Keymap.key_name(16, 0, 1) == "ๆ"
    assert Keymap.key_name(16, Keymap.shift(), 1) == "๐"
    assert Keymap.key_name(16, Keymap.ctrl(), 1) == "C-q"
    assert Keymap.key_name(28, 0, 1) == "RET"

    xkb = Keymap.xkb(Keyboard.groups(["us", "ko", "th", "ar"]))
    assert xkb =~ ~s(name[Group2] = "Thai";)
    assert xkb =~ ~s(name[Group3] = "Arabic";)
    assert xkb =~ ~s(key <K16> { type[Group1] = "ALPHABETIC", type[Group2] = "TWO_LEVEL", type[Group3] = "TWO_LEVEL", symbols[Group1] = [ q, Q ], symbols[Group2] = [ U0E46, U0E50 ], symbols[Group3] = [ U0636, U064E ] };)
    # Keys only US has (Escape, the modifiers) are the same in every group.
    assert xkb =~ ~s(key <K1> { type = "ONE_LEVEL", [ Escape ] };)
  end

  test "the classic taskbar: an indicator with more than one source, and a click moves to the next" do
    alias Lepton.Photon.WM.Classic
    Keyboard.set_sources(["us"])
    s = Classic.init(1024, 768, {1024, 768})
    assert Classic.tray(s).keyboard == nil
    Keyboard.set_sources(["us", "ko"])
    x = Classic.tray(s).keyboard
    assert is_integer(x)
    assert {:handled, _, []} = Classic.click(s, [], {x + 4, 768 - 10}, 0x110, false)
    assert Keyboard.state().current == "ko"
  end

  test "keyboard: lists, adds, switches and removes input sources" do
    Keyboard.set_sources(["us"])
    assert {out, 0} = sh("keyboard")
    assert out =~ "* us  English (US)"
    assert {out, 0} = sh("keyboard list")
    assert out =~ "  ko  Korean (Hangul, 2-set)" and out =~ "  th  Thai" and out =~ "+ us  English (US)"
    assert {out, 0} = sh("keyboard add ko hi")
    assert out =~ "  ko  Korean" and out =~ "  hi  Hindi (InScript)" and out =~ "Super+Space"
    assert {out, 0} = sh("keyboard use ko")
    assert out =~ "* ko  Korean (Hangul, 2-set) (typing Hangul)" and out =~ "Right Alt"
    assert {_, 1} = sh("keyboard use th")
    assert {out, 0} = sh("keyboard remove ko")
    assert out =~ "* us" and not (out =~ "ko ")
    assert {_, 1} = sh("keyboard remove us hi")
    assert {_, 2} = sh("keyboard frobnicate")
  end
end
