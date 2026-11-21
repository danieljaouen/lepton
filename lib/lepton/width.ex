defmodule Lepton.Width do
  @moduledoc """
  How many terminal columns text takes (`wcwidth`): two for East Asian
  wide and fullwidth characters (Chinese, Japanese, Korean, fullwidth
  forms, most emoji), none for control characters, one for the rest. A
  grapheme's width is its first code point's (combining marks ride along).

  The ranges are Unicode's East Asian Width W and F classes, as terminals
  (xterm, iTerm2, VTE) use them.
  """

  @wide [
    {0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC}, {0x23F0, 0x23F0}, {0x23F3, 0x23F3},
    {0x25FD, 0x25FE}, {0x2614, 0x2615}, {0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
    {0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE}, {0x26D4, 0x26D4}, {0x26EA, 0x26EA},
    {0x26F2, 0x26F3}, {0x26F5, 0x26F5}, {0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B},
    {0x2728, 0x2728}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797},
    {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55},
    {0x2E80, 0x303E}, {0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA4CF}, {0xA960, 0xA97F},
    {0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFE10, 0xFE19}, {0xFE30, 0xFE6F}, {0xFF00, 0xFF60}, {0xFFE0, 0xFFE6},
    {0x16FE0, 0x16FE4}, {0x17000, 0x18CFF}, {0x1B000, 0x1B2FF}, {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF},
    {0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F200, 0x1F251}, {0x1F300, 0x1F320}, {0x1F32D, 0x1F335},
    {0x1F337, 0x1F37C}, {0x1F37E, 0x1F393}, {0x1F3A0, 0x1F3CA}, {0x1F3CF, 0x1F3D3}, {0x1F3E0, 0x1F3F0},
    {0x1F3F4, 0x1F3F4}, {0x1F3F8, 0x1F43E}, {0x1F440, 0x1F440}, {0x1F442, 0x1F4FC}, {0x1F4FF, 0x1F53D},
    {0x1F54B, 0x1F54E}, {0x1F550, 0x1F567}, {0x1F57A, 0x1F57A}, {0x1F595, 0x1F596}, {0x1F5A4, 0x1F5A4},
    {0x1F5FB, 0x1F64F}, {0x1F680, 0x1F6C5}, {0x1F6CC, 0x1F6CC}, {0x1F6D0, 0x1F6D2}, {0x1F6D5, 0x1F6D7},
    {0x1F6DC, 0x1F6DF}, {0x1F6EB, 0x1F6EC}, {0x1F6F4, 0x1F6FC}, {0x1F7E0, 0x1F7EB}, {0x1F7F0, 0x1F7F0},
    {0x1F90C, 0x1F93A}, {0x1F93C, 0x1F945}, {0x1F947, 0x1F9FF}, {0x1FA70, 0x1FAFF},
    {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD}
  ]

  # A tuple for binary search.
  @table List.to_tuple(@wide)
  @n tuple_size(@table)

  @doc "Is code point `cp` two columns wide?"
  def wide?(cp) when cp < 0x1100, do: false
  def wide?(cp), do: search(cp, 0, @n - 1)

  defp search(_cp, lo, hi) when lo > hi, do: false

  defp search(cp, lo, hi) do
    mid = div(lo + hi, 2)
    {a, b} = elem(@table, mid)

    cond do
      cp < a -> search(cp, lo, mid - 1)
      cp > b -> search(cp, mid + 1, hi)
      true -> true
    end
  end

  @doc "Columns one grapheme takes: 0, 1 or 2."
  def grapheme(<<c, _::binary>>) when c < 32 or c == 127, do: 0
  def grapheme(<<c, _::binary>>) when c < 128, do: 1

  def grapheme(g) do
    case g do
      <<cp::utf8, _::binary>> -> if wide?(cp), do: 2, else: if(zero?(cp), do: 0, else: 1)
      _ -> 1
    end
  end

  # Combining marks and joiners on their own, and the zero-width characters.
  defp zero?(cp), do: cp in 0x0300..0x036F or cp in 0x200B..0x200F or cp == 0xFEFF

  @doc "Columns a string takes (no escape sequences: see `Lepton.Style.width/1`)."
  def string(s) do
    if ascii?(s), do: byte_size(s), else: s |> String.graphemes() |> Enum.reduce(0, &(grapheme(&1) + &2))
  end

  defp ascii?(<<>>), do: true
  defp ascii?(<<c, rest::binary>>) when c >= 32 and c < 127, do: ascii?(rest)
  defp ascii?(_), do: false

  @doc """
  The part of `s` from column `from` that fits in `width` columns:
  `{text, columns}`. A wide character cut by either edge is left out
  (its place filled with a space).
  """
  def slice(s, from, width) do
    {acc, _col, used} =
      s
      |> String.graphemes()
      |> Enum.reduce_while({[], 0, 0}, fn g, {acc, col, used} ->
        w = grapheme(g)

        cond do
          col + w <= from -> {:cont, {acc, col + w, used}}
          # cut by the left edge
          col < from -> {:cont, {[" " | acc], col + w, used + col + w - from}}
          used + w > width -> {:halt, {if(used < width, do: [" " | acc], else: acc), col, if(used < width, do: used + 1, else: used)}}
          true -> {:cont, {[g | acc], col + w, used + w}}
        end
      end)

    {acc |> Enum.reverse() |> IO.iodata_to_binary(), used}
  end

  @doc "Pad `s` with spaces to `width` columns (or cut it to them)."
  def pad(s, width) do
    {text, used} = slice(s, 0, width)
    text <> String.duplicate(" ", max(width - used, 0))
  end
end
