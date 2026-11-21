defmodule Lepton.Style do
  @moduledoc """
  Terminal styling: starship-style style strings (`"bold green"`, `"197"`,
  `"#ff8800"`, `"fg:red bg:blue"`) to SGR escape sequences, plus the
  palette Lepton's UI uses (Monokai, the user's Spacemacs theme).
  """

  @colors %{
    "black" => 0,
    "red" => 1,
    "green" => 2,
    "yellow" => 3,
    "blue" => 4,
    "purple" => 5,
    "magenta" => 5,
    "cyan" => 6,
    "white" => 7
  }

  def color?(%{env: env}), do: not Map.has_key?(env, "NO_COLOR")
  def color?(_), do: true

  def apply(text, _style, false), do: text
  def apply("", _style, _), do: ""
  def apply(text, nil, _), do: text
  def apply(text, "", _), do: text

  def apply(text, style, true) do
    case sgr(style) do
      "" -> text
      codes -> "\e[#{codes}m" <> text <> "\e[0m"
    end
  end

  @doc "Convert a style string into SGR parameters (without ESC[ and m)."
  def sgr(style) do
    style
    |> String.split()
    |> Enum.flat_map(&word/1)
    |> Enum.join(";")
  end

  defp word("bold"), do: ["1"]
  defp word("dimmed"), do: ["2"]
  defp word("italic"), do: ["3"]
  defp word("underline"), do: ["4"]
  defp word("blink"), do: ["5"]
  defp word("inverted"), do: ["7"]
  defp word("hidden"), do: ["8"]
  defp word("strikethrough"), do: ["9"]
  defp word("none"), do: []
  defp word("fg:" <> c), do: color(c, 30)
  defp word("bg:" <> c), do: color(c, 40)
  defp word(c), do: color(c, 30)

  defp color("bright-" <> name, base) do
    case @colors[name] do
      nil -> []
      n -> [to_string(base + 60 + n)]
    end
  end

  defp color("#" <> hex, base) when byte_size(hex) == 6 do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    [to_string(base + 8), "2", h(r), h(g), h(b)]
  end

  defp color(name, base) do
    cond do
      Map.has_key?(@colors, name) -> [to_string(base + @colors[name])]
      Regex.match?(~r/^\d{1,3}$/, name) -> [to_string(base + 8), "5", name]
      true -> []
    end
  end

  defp h(x), do: x |> String.to_integer(16) |> to_string()

  @doc "Visible width of a string containing escape sequences."
  def width(s) do
    s
    |> strip()
    |> Lepton.Width.string()
  end

  def strip(s), do: Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]|\e\][^\a]*\a/, s, "")

  # Monokai, as used by the editor and multiplexer chrome. 256-colour codes
  # degrade gracefully on the Linux console (which approximates them).
  def monokai do
    %{
      bg: "235",
      fg: "231",
      comment: "242",
      yellow: "186",
      orange: "208",
      purple: "141",
      pink: "197",
      green: "148",
      cyan: "81",
      line: "237",
      selection: "59"
    }
  end
end
