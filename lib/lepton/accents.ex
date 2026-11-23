defmodule Lepton.Accents do
  @moduledoc """
  Accented letters, typed as on a Mac with Option, here Alt (a Mac's
  Option key in UTM, or over SSH from a Terminal that uses Option as
  Meta): a dead key, then the letter.

      Alt+e e → é   (acute)        Alt+` e → è   (grave)
      Alt+i e → ê   (circumflex)   Alt+u u → ü   (umlaut)
      Alt+n n → ñ   (tilde)        Alt+h c → č   (háček)
      Alt+, c → ç   (cedilla; ą ę: ogonek)
      Alt+k a → å   (ring)         Alt+m a → ā   (macron)
      Alt+g a → ă   (breve)        Alt+z z → ż   (dot above)
      Alt+= o → ő   (double acute)

  Shift gives the capital (`Alt+e E` → É). Space, or the dead key again,
  types the accent itself; a letter that doesn't take it follows the
  accent (`Alt+e q` → ´q). `keyboard accents off` turns them off, for
  programs that use these Alt keys themselves. Some characters are one key (`@one_key`): Alt+c
  ç, Alt+s ß, Alt+l ł, Alt+$ €, Alt+[ “, ...

  `feed/2` works on `Lepton.Keys` names, so every terminal gets it in one
  place (`Lepton.TTY`: the console, terminal windows, SSH, tmux panes),
  and Photon composes the same way for Firefox.
  """

  # dead key => {name, combining marks (the first Unicode composes with), the accent alone}
  @dead %{
    "e" => {:acute, [0x301], "´"},
    "`" => {:grave, [0x300], "`"},
    "i" => {:circumflex, [0x302], "^"},
    "u" => {:umlaut, [0x308], "¨"},
    "n" => {:tilde, [0x303], "~"},
    "h" => {:háček, [0x30C], "ˇ"},
    "," => {:cedilla, [0x327, 0x328], "¸"},
    "k" => {:ring, [0x30A], "˚"},
    "m" => {:macron, [0x304], "¯"},
    "g" => {:breve, [0x306], "˘"},
    "z" => {:dot, [0x307], "˙"},
    "=" => {:double_acute, [0x30B], "˝"}
  }

  # Letters with no combining mark, punctuation and symbols: one key each.
  # (Not Alt+b d f v x . or digits: the line editor, the pager and tmux's
  # layouts use those.)
  @one_key %{
    "c" => "ç", "C" => "Ç", "s" => "ß", "a" => "å", "A" => "Å", "o" => "ø",
    "'" => "æ", "\"" => "Æ", "q" => "œ", "Q" => "Œ", "l" => "ł", "L" => "Ł",
    "!" => "¡", "?" => "¿", "$" => "€", "#" => "£", "*" => "°", ";" => "…",
    "-" => "–", "_" => "—", "[" => "“", "{" => "”", "]" => "‘", "}" => "’",
    "\\" => "«", "|" => "»"
  }

  @doc "No accent pending."
  def new, do: nil

  @doc "The dead keys and one-key characters, for documentation: `{[{key, name, examples}], [{key, char}]}`."
  def table do
    dead = for {k, {name, _, _}} <- Enum.sort_by(@dead, fn {_, {n, _, _}} -> order(n) end), do: {"M-" <> k, name, examples(k)}
    {dead, for({k, c} <- Enum.sort_by(@one_key, fn {k, _} -> {String.downcase(k), k} end), do: {"M-" <> k, c})}
  end

  defp order(name), do: Enum.find_index(~w(acute grave circumflex umlaut tilde háček cedilla ring macron breve dot double_acute)a, &(&1 == name))

  defp examples(k) do
    for(l <- String.graphemes("aeiouycgnszrlAEIOUCSZ"), c <- [compose(k, l)], c != nil, do: c) |> Enum.join(" ")
  end

  @doc "The dead key a key is (`\"M-e\"` → `\"e\"`, `\"M-E\"` too), or nil."
  def dead("M-" <> k) do
    k = String.downcase(k)
    if Map.has_key?(@dead, k), do: k
  end

  def dead(_), do: nil

  @doc """
  One key with `pending` (nil, or the dead key typed before): `{pending,
  keys}`, the keys that result. Keys that aren't text (arrows, `C-c`,
  resizes) end an accent without typing it.
  """
  def feed(nil, key) do
    cond do
      d = dead(key) -> {d, []}
      c = one_key(key) -> {nil, [c]}
      true -> {nil, [key]}
    end
  end

  def feed(d, key) when is_binary(key) do
    cond do
      key == "SPC" or dead(key) == d -> {nil, [accent(d)]}
      letter?(key) -> {nil, if(c = compose(d, key), do: [c], else: [accent(d), key])}
      true -> {nil, [key]}
    end
  end

  def feed(d, key), do: {d, [key]}

  @doc "Does `key` start an accent or type one (so it isn't passed on as itself)?"
  def accent_key?(key), do: dead(key) != nil or one_key(key) != nil

  @doc "The accent alone (dead key `\"e\"` → ´), shown while it waits for a letter."
  def accent(d), do: elem(@dead[d], 2)

  defp one_key("M-" <> k), do: @one_key[k]
  defp one_key(_), do: nil

  # The letter with the dead key's mark, if Unicode has it as one character.
  defp compose(d, letter) do
    {_, marks, _} = @dead[d]

    Enum.find_value(marks, fn cp ->
      c = :unicode.characters_to_nfc_binary(letter <> <<cp::utf8>>)
      if length(String.codepoints(c)) == 1, do: c
    end)
  end

  defp letter?(key), do: String.length(key) == 1 and String.match?(key, ~r/^\p{L}$/u)
end
