defmodule Lepton.Wayland.Keymap do
  @moduledoc """
  The US keyboard layout, by Linux input (evdev) key code, and the other
  layouts of `Lepton.Wayland.Layouts` as further XKB groups.

  One table serves both ends: Photon sends clients an XKB keymap generated
  from it (`xkb/1`, what `wl_keyboard.keymap` carries), and Lepton's own
  clients turn key codes into keys with `key_name/3` (the group is the
  one `wl_keyboard.modifiers` names; see `Lepton.Keyboard`).
  """

  import Bitwise

  # Modifier masks, as XKB's real modifiers (the keymap below maps them so).
  @shift 1
  @caps 2
  @ctrl 4
  @alt 8
  @super 64

  def shift, do: @shift
  def caps, do: @caps
  def ctrl, do: @ctrl
  def alt, do: @alt
  def super, do: @super

  # code => {unshifted, shifted} for keys that type characters
  @chars %{
    2 => {"1", "!"}, 3 => {"2", "@"}, 4 => {"3", "#"}, 5 => {"4", "$"}, 6 => {"5", "%"},
    7 => {"6", "^"}, 8 => {"7", "&"}, 9 => {"8", "*"}, 10 => {"9", "("}, 11 => {"0", ")"},
    12 => {"-", "_"}, 13 => {"=", "+"}, 26 => {"[", "{"}, 27 => {"]", "}"}, 39 => {";", ":"},
    40 => {"'", "\""}, 41 => {"`", "~"}, 43 => {"\\", "|"}, 51 => {",", "<"}, 52 => {".", ">"},
    53 => {"/", "?"}, 57 => {" ", " "}
  }

  @letters Enum.zip([16..25, 30..38, 44..50] |> Enum.flat_map(&Enum.to_list/1), String.graphemes("qwertyuiopasdfghjklzxcvbnm")) |> Map.new()

  # code => key name (Lepton.Keys vocabulary) and XKB keysym
  @named %{
    1 => {"ESC", "Escape"},
    14 => {"DEL", "BackSpace"},
    15 => {"TAB", "Tab"},
    28 => {"RET", "Return"},
    96 => {"RET", "KP_Enter"},
    102 => {"<home>", "Home"},
    103 => {"<up>", "Up"},
    104 => {"<prior>", "Prior"},
    105 => {"<left>", "Left"},
    106 => {"<right>", "Right"},
    107 => {"<end>", "End"},
    108 => {"<down>", "Down"},
    109 => {"<next>", "Next"},
    110 => {"<insert>", "Insert"},
    111 => {"<deletechar>", "Delete"},
    59 => {"<f1>", "F1"}, 60 => {"<f2>", "F2"}, 61 => {"<f3>", "F3"}, 62 => {"<f4>", "F4"},
    63 => {"<f5>", "F5"}, 64 => {"<f6>", "F6"}, 65 => {"<f7>", "F7"}, 66 => {"<f8>", "F8"},
    67 => {"<f9>", "F9"}, 68 => {"<f10>", "F10"}, 87 => {"<f11>", "F11"}, 88 => {"<f12>", "F12"}
  }

  # code => {modifier mask, keysym}
  @modifiers %{
    42 => {@shift, "Shift_L"},
    54 => {@shift, "Shift_R"},
    29 => {@ctrl, "Control_L"},
    97 => {@ctrl, "Control_R"},
    56 => {@alt, "Alt_L"},
    100 => {@alt, "Alt_R"},
    125 => {@super, "Super_L"},
    126 => {@super, "Super_R"}
  }

  @capslock 58

  @doc "The modifier bit a key code holds down, or nil (Caps Lock is a lock, see `capslock/0`)."
  def modifier(code), do: with({mask, _} <- @modifiers[code], do: mask)
  def capslock, do: @capslock

  @doc "The text a key types with modifiers `mods` in XKB group `group` (0: US), or nil."
  def text(code, mods, group \\ 0)

  def text(code, mods, group) when group > 0 do
    with layout when layout != "us" <- Lepton.Keyboard.group_layout(group),
         {_, table} <- Lepton.Wayland.Layouts.get(layout),
         {plain, shifted} <- table[code] do
      case if(band(mods, @shift) != 0, do: shifted, else: plain) do
        cp when is_integer(cp) -> <<cp::utf8>>
        _ -> nil
      end
    else
      _ -> text(code, mods, 0)
    end
  end

  def text(code, mods, 0) do
    shift? = band(mods, @shift) != 0

    cond do
      l = @letters[code] -> if shift? != (band(mods, @caps) != 0), do: String.upcase(l), else: l
      pair = @chars[code] -> if shift?, do: elem(pair, 1), else: elem(pair, 0)
      true -> nil
    end
  end

  @doc """
  The key a key code is with modifiers `mods`, as `Lepton.Keys` names it
  (`"a"`, `"A"`, `"C-a"`, `"M-x"`, `"RET"`, `"<up>"`, `"C-<left>"`), or nil
  for keys that are only modifiers. In another group a key types that
  layout's character, but with Ctrl or Alt it is the US key (C-c stays C-c).
  """
  def key_name(code, mods, group \\ 0) do
    ctrl? = band(mods, @ctrl) != 0
    alt? = band(mods, @alt) != 0
    group = if ctrl? or alt?, do: 0, else: group

    base =
      case {@named[code], text(code, mods, group)} do
        {{name, _}, _} -> name
        {nil, " "} -> "SPC"
        {nil, nil} -> nil
        {nil, t} -> t
      end

    cond do
      base == nil -> nil
      ctrl? and base == "SPC" -> prefix("C-@", alt?)
      ctrl? and Regex.match?(~r/^[A-Z]$/, base) -> prefix("C-" <> String.downcase(base), alt?)
      ctrl? -> prefix("C-" <> base, alt?)
      true -> prefix(base, alt?)
    end
  end

  defp prefix(key, true), do: "M-" <> key
  defp prefix(key, false), do: key

  # -- XKB ---------------------------------------------------------------------------

  @symbols %{
    "!" => "exclam", "@" => "at", "#" => "numbersign", "$" => "dollar", "%" => "percent",
    "^" => "asciicircum", "&" => "ampersand", "*" => "asterisk", "(" => "parenleft",
    ")" => "parenright", "-" => "minus", "_" => "underscore", "=" => "equal", "+" => "plus",
    "[" => "bracketleft", "{" => "braceleft", "]" => "bracketright", "}" => "braceright",
    ";" => "semicolon", ":" => "colon", "'" => "apostrophe", "\"" => "quotedbl",
    "`" => "grave", "~" => "asciitilde", "\\" => "backslash", "|" => "bar", "," => "comma",
    "<" => "less", "." => "period", ">" => "greater", "/" => "slash", "?" => "question",
    " " => "space"
  }

  defp sym(c), do: @symbols[c] || c

  # A layout character as an XKB keysym: ASCII by name, the rest as Unicode (U0E01).
  defp keysym({:dead, name}), do: name
  defp keysym(cp) when cp in ?a..?z or cp in ?A..?Z or cp in ?0..?9, do: <<cp>>
  defp keysym(cp) when cp in 0x20..0x7E, do: sym(<<cp>>)
  defp keysym(cp), do: "U" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")

  @doc """
  An XKB keymap (text format v1), as `wl_keyboard.keymap` sends it: US
  English as group 1, and each layout of `groups` after it (ids of
  `Lepton.Wayland.Layouts`; "us" is skipped).
  """
  def xkb(groups \\ ["us"]) do
    extra = for id <- groups, id != "us", l = Lepton.Wayland.Layouts.get(id), do: l

    codes = Map.keys(@chars) ++ Map.keys(@letters) ++ Map.keys(@named) ++ Map.keys(@modifiers) ++ [@capslock]
    codes = Enum.sort(Enum.uniq(codes))

    keycodes = Enum.map(codes, &"    <K#{&1}> = #{&1 + 8};\n")

    symbols =
      Enum.map(codes, fn code ->
        others =
          for {{_, table}, i} <- Enum.with_index(extra, 2), {a, b} = table[code] || {nil, nil}, a != nil, do: {i, a, b}

        body =
          cond do
            (@letters[code] || @chars[code]) && others != [] ->
              {t1, s1} =
                case @letters[code] do
                  nil -> {"TWO_LEVEL", "#{sym(elem(@chars[code], 0))}, #{sym(elem(@chars[code], 1))}"}
                  l -> {"ALPHABETIC", "#{l}, #{String.upcase(l)}"}
                end

              types = Enum.map_join(others, "", fn {i, _, _} -> ~s(, type[Group#{i}] = "TWO_LEVEL") end)
              syms = Enum.map_join(others, "", fn {i, a, b} -> ", symbols[Group#{i}] = [ #{keysym(a)}, #{keysym(b)} ]" end)
              ~s(type[Group1] = "#{t1}"#{types}, symbols[Group1] = [ #{s1} ]#{syms})

            l = @letters[code] -> ~s(type = "ALPHABETIC", [ #{l}, #{String.upcase(l)} ])
            pair = @chars[code] -> ~s(type = "TWO_LEVEL", [ #{sym(elem(pair, 0))}, #{sym(elem(pair, 1))} ])
            n = @named[code] -> ~s(type = "ONE_LEVEL", [ #{elem(n, 1)} ])
            m = @modifiers[code] -> ~s(type = "ONE_LEVEL", [ #{elem(m, 1)} ])
            code == @capslock -> ~s(type = "ONE_LEVEL", [ Caps_Lock ])
          end

        "    key <K#{code}> { #{body} };\n"
      end)

    modmap = fn mask -> @modifiers |> Enum.filter(fn {_, {m, _}} -> m == mask end) |> Enum.map_join(", ", fn {c, _} -> "<K#{c}>" end) end

    """
    xkb_keymap {
    xkb_keycodes "lepton" {
        minimum = 8;
        maximum = 255;
    #{keycodes}};
    xkb_types "lepton" {
        type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; };
        type "TWO_LEVEL" { modifiers = Shift; map[Shift] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Shift"; };
        type "ALPHABETIC" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Caps"; };
    };
    xkb_compatibility "lepton" {
        interpret Shift_L { action = SetMods(modifiers = Shift); };
        interpret Shift_R { action = SetMods(modifiers = Shift); };
        interpret Control_L { action = SetMods(modifiers = Control); };
        interpret Control_R { action = SetMods(modifiers = Control); };
        interpret Alt_L { action = SetMods(modifiers = Mod1); };
        interpret Alt_R { action = SetMods(modifiers = Mod1); };
        interpret Super_L { action = SetMods(modifiers = Mod4); };
        interpret Super_R { action = SetMods(modifiers = Mod4); };
        interpret Caps_Lock { action = LockMods(modifiers = Lock); };
    };
    xkb_symbols "lepton" {
        name[Group1] = "English (US)";
    #{Enum.with_index(extra, 2) |> Enum.map_join("", fn {{name, _}, i} -> ~s(    name[Group#{i}] = "#{name}";\n) end)}#{symbols}    modifier_map Shift { #{modmap.(@shift)} };
        modifier_map Lock { <K#{@capslock}> };
        modifier_map Control { #{modmap.(@ctrl)} };
        modifier_map Mod1 { #{modmap.(@alt)} };
        modifier_map Mod4 { #{modmap.(@super)} };
    };
    };
    """
  end
end
