defmodule Lepton.Keys do
  @moduledoc """
  Terminal input decoding.

  Raw bytes become key names in Emacs `kbd` notation - `"a"`, `"C-t"`,
  `"M-x"`, `"RET"`, `"TAB"`, `"ESC"`, `"SPC"`, `"DEL"`, `"<up>"`,
  `"C-<left>"` - so every keymap in the system (and every binding read from
  the user's dotfiles) uses the same vocabulary.
  """

  @csi_finals %{
    "A" => "<up>",
    "B" => "<down>",
    "C" => "<right>",
    "D" => "<left>",
    "H" => "<home>",
    "F" => "<end>",
    "Z" => "<backtab>",
    "P" => "<f1>",
    "Q" => "<f2>",
    "R" => "<f3>",
    "S" => "<f4>"
  }

  @tilde %{
    "1" => "<home>",
    "2" => "<insert>",
    "3" => "<deletechar>",
    "4" => "<end>",
    "5" => "<prior>",
    "6" => "<next>",
    "7" => "<home>",
    "8" => "<end>",
    "15" => "<f5>",
    "17" => "<f6>",
    "18" => "<f7>",
    "19" => "<f8>",
    "20" => "<f9>",
    "21" => "<f10>",
    "23" => "<f11>",
    "24" => "<f12>"
  }

  @doc """
  Decode as many complete keys as possible from `bytes`.

  Returns `{keys, rest}`. `rest` is a trailing incomplete escape or UTF-8
  sequence; callers wait briefly for more input and otherwise call
  `flush/1`.
  """
  def decode(bytes), do: decode(bytes, [])

  @max_paste 4 * 1024 * 1024

  defp decode(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # Escape sequences
  defp decode(<<27>> = rest, acc), do: {Enum.reverse(acc), rest}

  # A mouse report in the old form (no 1006): ESC [ M, then button, column
  # and row, each plus 32; button 3 is a release.
  defp decode(<<27, ?[, ?M, b, x, y, rest::binary>>, acc) when b >= 32 and x > 32 and y > 32 do
    key = if Bitwise.band(b - 32, 0b1100011) == 3, do: mouse(b - 32, x - 33, y - 33, true), else: mouse(b - 32, x - 33, y - 33, false)
    decode(rest, [key | acc])
  end

  defp decode(<<27, ?[, ?M, rest::binary>> = all, acc) when byte_size(rest) < 3, do: {Enum.reverse(acc), all}

  # A bracketed paste (mode 2004): everything up to ESC [ 201 ~ is one
  # {:paste, text} key, newlines included. (Until the end arrives, wait.)
  defp decode(<<27, ?[, "200~", rest::binary>> = all, acc) do
    case :binary.match(rest, "\e[201~") do
      {at, 6} -> decode(binary_part(rest, at + 6, byte_size(rest) - at - 6), [{:paste, binary_part(rest, 0, at)} | acc])
      :nomatch when byte_size(rest) > @max_paste -> decode(<<>>, [{:paste, rest} | acc])
      :nomatch -> {Enum.reverse(acc), all}
    end
  end

  defp decode(<<27, ?[, rest::binary>> = all, acc) do
    case csi(rest) do
      {:ok, key, rest} -> decode(rest, [key | acc])
      :incomplete -> {Enum.reverse(acc), all}
    end
  end

  defp decode(<<27, ?O>>, acc), do: {Enum.reverse(acc), <<27, ?O>>}

  defp decode(<<27, ?O, c, rest::binary>>, acc) do
    key = Map.get(@csi_finals, <<c>>, "M-O")
    decode(rest, [key | acc])
  end

  defp decode(<<27, 27, rest::binary>>, acc), do: decode(<<27>> <> rest, ["ESC" | acc])

  defp decode(<<27, rest::binary>>, acc) do
    case decode_one(rest) do
      {:ok, key, rest} -> decode(rest, [meta(key) | acc])
      :incomplete -> {Enum.reverse(acc), <<27>> <> rest}
    end
  end

  defp decode(bytes, acc) do
    case decode_one(bytes) do
      {:ok, key, rest} -> decode(rest, [key | acc])
      :incomplete -> {Enum.reverse(acc), bytes}
    end
  end

  @doc "Interpret a pending partial sequence as literal keys (after a timeout)."
  def flush(<<>>), do: []
  def flush(<<27>>), do: ["ESC"]
  # (a paste whose end never came: what there is of it)
  def flush(<<27, ?[, "200~", text::binary>>), do: [{:paste, text}]
  def flush(<<27, rest::binary>>), do: ["ESC" | flush(rest)]
  def flush(bytes), do: bytes |> :binary.bin_to_list() |> Enum.map(&ctrl_or_char(&1))

  defp decode_one(<<c, rest::binary>>) when c < 32 or c == 127, do: {:ok, ctrl_or_char(c), rest}

  defp decode_one(bytes) do
    case String.next_grapheme(bytes) do
      nil ->
        :incomplete

      {g, rest} ->
        cond do
          String.valid?(g) -> {:ok, if(g == " ", do: "SPC", else: g), rest}
          byte_size(bytes) < 4 -> :incomplete
          true -> {:ok, <<:binary.first(bytes)>>, binary_part(bytes, 1, byte_size(bytes) - 1)}
        end
    end
  end

  defp ctrl_or_char(0), do: "C-SPC"
  defp ctrl_or_char(9), do: "TAB"
  defp ctrl_or_char(13), do: "RET"
  defp ctrl_or_char(27), do: "ESC"
  defp ctrl_or_char(28), do: "C-\\"
  defp ctrl_or_char(29), do: "C-]"
  defp ctrl_or_char(30), do: "C-^"
  defp ctrl_or_char(31), do: "C-_"
  defp ctrl_or_char(127), do: "DEL"
  defp ctrl_or_char(c) when c < 27, do: "C-" <> <<c + 96>>
  defp ctrl_or_char(32), do: "SPC"
  defp ctrl_or_char(c), do: <<c>>

  defp meta(key), do: "M-" <> key

  defp csi(rest) do
    case Regex.run(~r/^([0-9;?<>]*)([@-~])/, rest) do
      [whole, params, final] ->
        rest = binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))
        {:ok, csi_key(params, final), rest}

      nil ->
        if byte_size(rest) > 16, do: {:ok, "<unknown>", <<>>}, else: :incomplete
    end
  end

  # Mouse reports in SGR form (mode 1006): ESC [ < button ; col ; row M
  # (pressed, dragged) or m (released).
  defp csi_key("<" <> params, final) when final in ["M", "m"] do
    case params |> String.split(";") |> Enum.map(&Integer.parse/1) do
      [{b, ""}, {x, ""}, {y, ""}] -> mouse(b, x - 1, y - 1, final == "m")
      _ -> "<unknown>"
    end
  end

  defp csi_key(params, "R") do
    case String.split(params, ";") do
      [r, c] -> {:cpr, String.to_integer(r), String.to_integer(c)}
      _ -> "<unknown>"
    end
  end

  defp csi_key(params, "~") do
    case String.split(params, ";") do
      [n] -> Map.get(@tilde, n, "<unknown>")
      [n, mods] -> modifiers(mods) <> Map.get(@tilde, n, "<unknown>")
    end
  end

  defp csi_key(params, final) do
    base = Map.get(@csi_finals, final, "<unknown>")

    case String.split(params, ";") do
      [_, mods] -> modifiers(mods) <> base
      _ -> base
    end
  end

  @doc """
  A mouse report as a key: `{:mouse, action, button, col, row, mods}`,
  `action` :press, :release or :drag (:move with no button held), `button`
  :left, :middle, :right, :wheel_up, :wheel_down or :none, `col` and `row`
  counted from 0, `mods` "C-", "M-" and "S-" as for keys.
  """
  def mouse(b, x, y, release?) do
    import Bitwise
    mods = if((b &&& 16) != 0, do: "C-", else: "") <> if((b &&& 8) != 0, do: "M-", else: "") <> if((b &&& 4) != 0, do: "S-", else: "")

    button =
      cond do
        (b &&& 64) != 0 -> if((b &&& 1) == 0, do: :wheel_up, else: :wheel_down)
        true -> Enum.at([:left, :middle, :right, :none], b &&& 3)
      end

    action =
      cond do
        release? -> :release
        (b &&& 32) != 0 -> if(button == :none, do: :move, else: :drag)
        true -> :press
      end

    {:mouse, action, button, max(x, 0), max(y, 0), mods}
  end

  defp modifiers(mods) do
    m = String.to_integer(mods) - 1
    import Bitwise
    if((m &&& 4) != 0, do: "C-", else: "") <> if((m &&& 2) != 0, do: "M-", else: "") <> if((m &&& 1) != 0, do: "S-", else: "")
  end

  # -- encoding (used by the multiplexer to forward keys into panes) ---------------

  @named %{
    "RET" => "\r",
    "TAB" => "\t",
    "ESC" => "\e",
    "SPC" => " ",
    "DEL" => <<127>>,
    "C-SPC" => <<0>>,
    "<up>" => "\e[A",
    "<down>" => "\e[B",
    "<right>" => "\e[C",
    "<left>" => "\e[D",
    "<home>" => "\e[H",
    "<end>" => "\e[F",
    "<backtab>" => "\e[Z",
    "<insert>" => "\e[2~",
    "<deletechar>" => "\e[3~",
    "<prior>" => "\e[5~",
    "<next>" => "\e[6~"
  }

  def encode({:cpr, r, c}), do: "\e[#{r};#{c}R"

  # A paste, as a program in bracketed paste mode gets it (the end marker
  # can't appear inside it).
  def encode({:paste, text}), do: "\e[200~" <> String.replace(text, "\e[201~", "") <> "\e[201~"

  # A mouse report, in SGR form (as Lepton's terminals send them).
  def encode({:mouse, action, button, x, y, mods}) do
    b = %{left: 0, middle: 1, right: 2, none: 3, wheel_up: 64, wheel_down: 65}[button]
    b = b + if(action in [:drag, :move], do: 32, else: 0)
    b = b + if(String.contains?(mods, "S-"), do: 4, else: 0) + if(String.contains?(mods, "M-"), do: 8, else: 0) + if(String.contains?(mods, "C-"), do: 16, else: 0)
    "\e[<#{b};#{x + 1};#{y + 1}" <> if(action == :release, do: "m", else: "M")
  end
  def encode(key) when is_map_key(@named, key), do: @named[key]
  def encode("C-\\"), do: <<28>>
  def encode("C-]"), do: <<29>>
  def encode("C-^"), do: <<30>>
  def encode("C-_"), do: <<31>>
  def encode("C-<" <> _ = key), do: modified(key, 5)
  def encode("C-" <> <<c>>) when c in ?a..?z, do: <<c - 96>>
  def encode("C-" <> <<c>>) when c in ?A..?Z, do: <<c - 64>>
  def encode("M-" <> key), do: "\e" <> encode(key)
  def encode("S-<" <> _ = key), do: modified(key, 2)
  def encode(key), do: key

  @doc """
  A mouse key as a program that asked for reports gets it: SGR form
  (mode 1006), or the old form, ESC [ M and three bytes (32 added; a
  release names no button; nothing past column or row 222).
  """
  def mouse_report(key, true), do: encode(key)

  def mouse_report({:mouse, action, _button, col, row, mods} = key, false) do
    key = if action == :release, do: {:mouse, :press, :none, col, row, mods}, else: key
    # The SGR form's button number is the old form's, less 32.
    "\e[<" <> rest = encode(key)
    b = rest |> String.split(";") |> hd() |> String.to_integer()
    if col < 223 and row < 223, do: <<"\e[M", b + 32, col + 33, row + 33>>, else: ""
  end

  @doc "Whether a program in mouse mode `mode` (Lepton.Screen's) wants a report of `action`."
  def wants_mouse?(nil, _action), do: false
  def wants_mouse?(_mode, action) when action in [:press, :release], do: true
  def wants_mouse?(mode, :drag), do: mode in [:drag, :any]
  def wants_mouse?(mode, :move), do: mode == :any

  defp modified(key, mod) do
    base = key |> String.replace(~r/^([CMS]-)+/, "")

    case @named[base] do
      "\e[" <> <<final>> -> "\e[1;#{mod}" <> <<final>>
      other -> other || ""
    end
  end

  @doc "Parse a key description (`\"C-x C-s\"`, `\"SPC f s\"`, `\"^W\"`) into a list of keys."
  def parse(desc) when is_binary(desc) do
    desc
    |> String.split(" ", trim: true)
    |> Enum.flat_map(&kbd_word/1)
    |> Enum.map(&normalize/1)
  end

  @special ~w(RET SPC TAB ESC DEL LFD NUL)

  # Like Emacs `kbd`: a plain multi-character word is a sequence of keys
  # (",w" is "," then "w"), unless it is a named key or carries modifiers.
  defp kbd_word(word) do
    cond do
      word in @special -> [word]
      String.starts_with?(word, "<") and String.ends_with?(word, ">") -> [word]
      Regex.match?(~r/^([CMSsHA]-)+./, word) -> [word]
      String.starts_with?(word, "^") and String.length(word) == 2 -> [word]
      Regex.match?(~r/^[A-Z][a-zA-Z]+$/, word) and word in ~w(Enter Escape Space Tab BSpace Up Down Left Right Home End PageUp PageDown PPage NPage DC BTab Return Esc) -> [word]
      true -> String.graphemes(word)
    end
  end

  @doc "Normalize alternate spellings (tmux/vim style) to kbd notation."
  def normalize("^" <> <<c>>) when c in ?a..?z or c in ?A..?Z, do: "C-" <> String.downcase(<<c>>)
  def normalize("C-" <> <<c>>) when c in ?A..?Z, do: "C-" <> String.downcase(<<c>>)
  def normalize("<" <> _ = k) when byte_size(k) > 2, do: k
  def normalize(k) when k in ["Enter", "<CR>", "<cr>", "Return"], do: "RET"
  def normalize(k) when k in ["Escape", "Esc", "<Esc>", "<esc>"], do: "ESC"
  def normalize(k) when k in ["Space", " "], do: "SPC"
  def normalize("Tab"), do: "TAB"
  def normalize("BTab"), do: "<backtab>"
  def normalize(k) when k in ["BSpace", "<BS>"], do: "DEL"
  def normalize("Up"), do: "<up>"
  def normalize("Down"), do: "<down>"
  def normalize("Left"), do: "<left>"
  def normalize("Right"), do: "<right>"
  def normalize("Home"), do: "<home>"
  def normalize("End"), do: "<end>"
  def normalize(k) when k in ["PageUp", "PPage"], do: "<prior>"
  def normalize(k) when k in ["PageDown", "NPage"], do: "<next>"
  def normalize("DC"), do: "<deletechar>"
  def normalize(k), do: k

  def printable?(key) when is_binary(key), do: String.length(key) == 1 and key != "\d"
  def printable?(_), do: false

  @doc "Inverse of the SPC naming: the text a key inserts, if any."
  def text("SPC"), do: " "
  def text("TAB"), do: "\t"
  def text(key) when is_binary(key), do: if(printable?(key), do: key, else: nil)
  def text(_), do: nil
end
