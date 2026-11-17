defmodule Lepton.Elisp do
  @moduledoc """
  An Emacs Lisp *reader* (not an evaluator): turns `.el` source into data
  so configuration such as Spacemacs keybindings can be extracted.

  Representation: lists are Elixir lists, symbols `{:sym, "name"}`,
  strings are binaries, numbers are numbers, `'x` is `{:quote, x}`,
  `` `x `` is `{:backquote, x}`, `,x` is `{:unquote, x}`, vectors are
  `{:vector, [...]}` and `?a` character literals are integers.
  """

  def read_all(src) do
    {forms, _rest} = forms(String.to_charlist(src), [])
    {:ok, forms}
  catch
    {:elisp_error, reason} -> {:error, reason}
  end

  def read_file(path) do
    case File.read(path) do
      {:ok, src} -> read_all(src)
      error -> error
    end
  end

  defp forms(chars, acc) do
    case skip(chars) do
      [] -> {Enum.reverse(acc), []}
      [?) | rest] -> {Enum.reverse(acc), [?) | rest]}
      [?] | rest] -> {Enum.reverse(acc), [?] | rest]}
      chars ->
        {form, rest} = form(chars)
        forms(rest, [form | acc])
    end
  end

  defp skip([c | rest]) when c in [?\s, ?\t, ?\n, ?\r, ?\f], do: skip(rest)
  defp skip([?; | rest]), do: rest |> Enum.drop_while(&(&1 != ?\n)) |> skip()
  defp skip(chars), do: chars

  defp form([?( | rest]) do
    {items, rest} = forms(rest, [])

    case rest do
      [?) | rest] -> {dotted(items), rest}
      _ -> throw({:elisp_error, :unbalanced})
    end
  end

  defp form([?[ | rest]) do
    {items, rest} = forms(rest, [])

    case rest do
      [?] | rest] -> {{:vector, items}, rest}
      _ -> throw({:elisp_error, :unbalanced})
    end
  end

  defp form([?' | rest]), do: wrap(:quote, rest)
  defp form([?` | rest]), do: wrap(:backquote, rest)
  defp form([?,, ?@ | rest]), do: wrap(:splice, rest)
  defp form([?, | rest]), do: wrap(:unquote, rest)
  defp form([?#, ?' | rest]), do: wrap(:quote, rest)
  defp form([?" | rest]), do: string(rest, [])
  defp form([??, ?\\, c | rest]), do: {escape_char(c), rest}
  defp form([??, c | rest]), do: {c, rest}
  defp form(chars), do: atom(chars)

  defp wrap(tag, rest) do
    {f, rest} = form(skip(rest))
    {{tag, f}, rest}
  end

  # (a . b) pairs
  defp dotted(items) do
    case Enum.split(items, -2) do
      {init, [{:sym, "."}, last]} when init != [] -> {:cons, init, last}
      _ -> items
    end
  end

  defp string([?" | rest], acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp string([?\\, ?\n | rest], acc), do: string(rest, acc)
  defp string([?\\, c | rest], acc), do: string(rest, [escape_char(c) | acc])
  defp string([c | rest], acc), do: string(rest, [c | acc])
  defp string([], _), do: throw({:elisp_error, :unterminated_string})

  defp escape_char(?n), do: ?\n
  defp escape_char(?t), do: ?\t
  defp escape_char(?e), do: 27
  defp escape_char(c), do: c

  defp atom(chars) do
    {text, rest} = take_atom(chars, [])
    text = List.to_string(text)

    value =
      cond do
        Regex.match?(~r/^[+-]?\d+$/, text) -> String.to_integer(text)
        Regex.match?(~r/^[+-]?\d+\.\d+$/, text) -> String.to_float(text)
        true -> {:sym, text}
      end

    {value, rest}
  end

  defp take_atom([?\\, c | rest], acc), do: take_atom(rest, [c | acc])

  defp take_atom([c | rest], acc) when c not in [?\s, ?\t, ?\n, ?\r, ?(, ?), ?[, ?], ?", ?;, ?'],
    do: take_atom(rest, [c | acc])

  defp take_atom(rest, []), do: throw({:elisp_error, {:unexpected, List.to_string(Enum.take(rest, 10))}})
  defp take_atom(rest, acc), do: {Enum.reverse(acc), rest}

  # -- helpers for consumers -------------------------------------------------------------

  def sym?({:sym, _}), do: true
  def sym?(_), do: false

  def name({:sym, n}), do: n
  def name({:quote, x}), do: name(x)
  def name(_), do: nil

  @doc "Unwrap `(kbd \"...\")` or a plain string into a key description."
  def key([{:sym, "kbd"}, desc]) when is_binary(desc), do: desc
  def key(desc) when is_binary(desc), do: desc
  def key(_), do: nil

  @doc "Evaluate a literal value: quoted symbols, lists, strings, numbers, t/nil."
  def value({:quote, x}), do: literal(x)
  def value({:sym, "t"}), do: true
  def value({:sym, "nil"}), do: nil
  def value(x) when is_binary(x) or is_number(x), do: x
  def value(_), do: :unknown

  defp literal({:sym, n}), do: n
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(x), do: x
end
