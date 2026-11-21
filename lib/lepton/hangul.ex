defmodule Lepton.Hangul do
  @moduledoc """
  Korean typing: the standard 2-set (Dubeolsik) keyboard, composing
  jamo into syllables as they are typed (ㅎ ㅏ ㄴ → 한).

  The state is the jamo typed for the syllable being composed, so
  Backspace takes back one jamo at a time. `type/2` adds one and returns
  `{state, committed_text, preedit}`: the text that is finished, and the
  syllable still being composed (shown underlined, and replaced as typing
  goes on). A vowel after a final consonant takes that consonant into
  the next syllable (달 + ㄱ + ㅏ → 달가).
  """

  @cho ~w(ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ)
  @jung ~w(ㅏ ㅐ ㅑ ㅒ ㅓ ㅔ ㅕ ㅖ ㅗ ㅘ ㅙ ㅚ ㅛ ㅜ ㅝ ㅞ ㅟ ㅠ ㅡ ㅢ ㅣ)
  @jong ["" | ~w(ㄱ ㄲ ㄳ ㄴ ㄵ ㄶ ㄷ ㄹ ㄺ ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅁ ㅂ ㅄ ㅅ ㅆ ㅇ ㅈ ㅊ ㅋ ㅌ ㅍ ㅎ)]

  @vowels %{"ㅗㅏ" => "ㅘ", "ㅗㅐ" => "ㅙ", "ㅗㅣ" => "ㅚ", "ㅜㅓ" => "ㅝ", "ㅜㅔ" => "ㅞ", "ㅜㅣ" => "ㅟ", "ㅡㅣ" => "ㅢ"}
  @finals %{
    "ㄱㅅ" => "ㄳ", "ㄴㅈ" => "ㄵ", "ㄴㅎ" => "ㄶ", "ㄹㄱ" => "ㄺ", "ㄹㅁ" => "ㄻ", "ㄹㅂ" => "ㄼ",
    "ㄹㅅ" => "ㄽ", "ㄹㅌ" => "ㄾ", "ㄹㅍ" => "ㄿ", "ㄹㅎ" => "ㅀ", "ㅂㅅ" => "ㅄ"
  }

  # The 2-set layout: letter key => jamo (Shift gives the doubled consonants and ㅒ ㅖ).
  @keys Enum.zip(String.graphemes("qwertyuiopasdfghjklzxcvbnm"), ~w(ㅂ ㅈ ㄷ ㄱ ㅅ ㅛ ㅕ ㅑ ㅐ ㅔ ㅁ ㄴ ㅇ ㄹ ㅎ ㅗ ㅓ ㅏ ㅣ ㅋ ㅌ ㅊ ㅍ ㅠ ㅜ ㅡ)) |> Map.new()
  @shifted %{"q" => "ㅃ", "w" => "ㅉ", "e" => "ㄸ", "r" => "ㄲ", "t" => "ㅆ", "o" => "ㅒ", "p" => "ㅖ"}

  def new, do: []

  @doc "The jamo a letter key types (`\"r\"` → ㄱ; Shift: `\"R\"` → ㄲ), or nil."
  def jamo(letter) do
    lower = String.downcase(letter)

    cond do
      letter != lower -> @shifted[lower] || @keys[lower]
      true -> @keys[letter]
    end
  end

  @doc "Type jamo `j`: `{state, committed, preedit}`."
  def type(keys, j) do
    cond do
      syllable(keys ++ [j]) ->
        {keys ++ [j], "", text(keys ++ [j])}

      vowel?(j) and final?(keys) ->
        {rest, [last]} = Enum.split(keys, -1)
        {[last, j], text(rest), text([last, j])}

      true ->
        {[j], text(keys), j}
    end
  end

  @doc "Take back the last jamo: `{state, preedit}`, or nil when nothing is being composed."
  def backspace([]), do: nil
  def backspace(keys), do: (rest = Enum.drop(keys, -1); {rest, text(rest)})

  @doc "The text of a state (the syllable being composed)."
  def text([]), do: ""
  def text(keys), do: syllable(keys) || Enum.join(keys)

  @doc "Type a string of letter keys from the start (for tests): the text."
  def compose(letters) do
    {keys, out} =
      letters
      |> String.graphemes()
      |> Enum.reduce({new(), ""}, fn l, {keys, out} ->
        case jamo(l) do
          nil -> {[], out <> text(keys) <> l}
          j -> (fn {k, c, _} -> {k, out <> c} end).(type(keys, j))
        end
      end)

    out <> text(keys)
  end

  def vowel?(j), do: j in @jung

  # A whole syllable's text, or nil when `keys` aren't one syllable.
  defp syllable([c]), do: if(c in @cho or vowel?(c), do: c)
  defp syllable([a, b]) when is_binary(a), do: (if vowel?(a), do: @vowels[a <> b], else: block(a, [b], []))
  defp syllable([c | rest]) when length(rest) in 2..4, do: split(c, rest)
  defp syllable(_), do: nil

  defp split(c, rest) do
    # The vowel part is the first one or two (combinable) vowels; the rest is the final.
    {vs, fs} = Enum.split_while(rest, &vowel?/1)
    block(c, vs, fs)
  end

  defp block(c, vs, fs) do
    with true <- c in @cho,
         v when v != nil <- vowel(vs),
         f when f != nil <- final(fs) do
      ci = Enum.find_index(@cho, &(&1 == c))
      vi = Enum.find_index(@jung, &(&1 == v))
      fi = Enum.find_index(@jong, &(&1 == f))
      <<0xAC00 + (ci * 21 + vi) * 28 + fi::utf8>>
    else
      _ -> nil
    end
  end

  defp vowel([v]), do: if(vowel?(v), do: v)
  defp vowel([a, b]), do: @vowels[a <> b]
  defp vowel(_), do: nil

  defp final([]), do: ""
  defp final([f]), do: if(f in @jong and f != "", do: f)
  defp final([a, b]), do: @finals[a <> b]
  defp final(_), do: nil

  # Does the syllable being composed end in a final consonant?
  defp final?(keys) do
    case keys do
      [c | rest] when rest != [] ->
        {vs, fs} = Enum.split_while(rest, &vowel?/1)
        c in @cho and vs != [] and fs != [] and syllable(keys) != nil

      _ ->
        false
    end
  end
end
