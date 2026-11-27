defmodule Lepton.Transpose do
  @moduledoc """
  Emacs's `transpose-words` (M-t), for lsh's line editor and le's insert
  state: the word before the cursor and the word after it change places,
  what's between them staying, and the cursor ends after both. In a word,
  the cursor counts as at its end; with no word after it (at the end of
  the line), the last two words change places. Words are letters and
  digits, as Emacs has them.
  """

  @doc """
  Swap the words around grapheme position `pos` in `text`: `{text, pos}`,
  or `:none` with fewer than two words to swap.
  """
  def words(text, pos) do
    g = String.graphemes(text)
    spans = spans(g)
    # In a word: as at its end.
    pos = case Enum.find(spans, fn {s, e} -> s < pos and pos < e end) do
      {_, e} -> e
      nil -> pos
    end

    {before, later} = Enum.split_with(spans, fn {_s, e} -> e <= pos end)

    pair =
      case {Enum.reverse(before), later} do
        {[a | _], [b | _]} -> {a, b}
        {[b, a | _], []} -> {a, b}
        {[], [a, b | _]} -> {a, b}
        _ -> nil
      end

    case pair do
      nil -> :none
      {{as, ae}, {bs, be}} ->
        slice = fn s, e -> g |> Enum.slice(s, e - s) |> Enum.join() end
        new = slice.(0, as) <> slice.(bs, be) <> slice.(ae, bs) <> slice.(as, ae) <> slice.(be, length(g))
        {new, be}
    end
  end

  # The words: {start, end} grapheme positions.
  defp spans(g) do
    {spans, open, _} =
      Enum.reduce(g, {[], nil, 0}, fn c, {acc, open, i} ->
        word? = String.match?(c, ~r/^[\p{L}\p{N}]/u)

        cond do
          word? and open == nil -> {acc, i, i + 1}
          word? -> {acc, open, i + 1}
          open != nil -> {[{open, i} | acc], nil, i + 1}
          true -> {acc, nil, i + 1}
        end
      end)

    spans = if open != nil, do: [{open, length(g)} | spans], else: spans
    Enum.reverse(spans)
  end
end
