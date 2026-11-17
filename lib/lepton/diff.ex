defmodule Lepton.Diff do
  @moduledoc "Line diffs in unified format (Myers' algorithm via `List.myers_difference/2`)."

  @context 3

  def lines(""), do: []

  def lines(text) do
    parts = String.split(text, "\n")
    if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
  end

  @doc "Unified diff of two texts; empty string when equal."
  def unified(a, b, name_a, name_b, opts \\ []) do
    la = lines(a)
    lb = lines(b)

    if la == lb do
      ""
    else
      header = opts[:header] || "--- #{name_a}\n+++ #{name_b}\n"
      header <> Enum.map_join(hunks(la, lb), &render_hunk/1)
    end
  end

  @doc "Edit script as a flat list of {:eq | :del | :ins, line}."
  def script(la, lb) do
    la
    |> List.myers_difference(lb)
    |> Enum.flat_map(fn {op, ls} -> Enum.map(ls, &{op, &1}) end)
  end

  def hunks(la, lb) do
    ops = script(la, lb) |> annotate()
    changed = for {{op, _, _, _}, i} <- Enum.with_index(ops), op != :eq, do: i

    changed
    |> Enum.chunk_while(
      [],
      fn i, acc ->
        case acc do
          [] -> {:cont, [i]}
          [last | _] when i - last <= 2 * @context -> {:cont, [i | acc]}
          _ -> {:cont, Enum.reverse(acc), [i]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn idxs ->
      from = max(hd(idxs) - @context, 0)
      to = min(List.last(idxs) + @context, length(ops) - 1)
      Enum.slice(ops, from..to)
    end)
  end

  # Attach 1-based line numbers in a and b to each op.
  defp annotate(ops) do
    {acc, _, _} =
      Enum.reduce(ops, {[], 1, 1}, fn
        {:eq, l}, {acc, a, b} -> {[{:eq, l, a, b} | acc], a + 1, b + 1}
        {:del, l}, {acc, a, b} -> {[{:del, l, a, b} | acc], a + 1, b}
        {:ins, l}, {acc, a, b} -> {[{:ins, l, a, b} | acc], a, b + 1}
      end)

    Enum.reverse(acc)
  end

  defp render_hunk(ops) do
    {_, _, a0, b0} = hd(ops)
    a_len = Enum.count(ops, fn {op, _, _, _} -> op != :ins end)
    b_len = Enum.count(ops, fn {op, _, _, _} -> op != :del end)
    a_start = if a_len == 0, do: a0 - 1, else: a0
    b_start = if b_len == 0, do: b0 - 1, else: b0

    body =
      Enum.map_join(ops, fn
        {:eq, l, _, _} -> " " <> l <> "\n"
        {:del, l, _, _} -> "-" <> l <> "\n"
        {:ins, l, _, _} -> "+" <> l <> "\n"
      end)

    "@@ -#{a_start},#{a_len} +#{b_start},#{b_len} @@\n" <> body
  end

  def colorize(text, false), do: text

  def colorize(text, true) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "+++" <> _ = l -> "\e[1m" <> l <> "\e[0m"
      "---" <> _ = l -> "\e[1m" <> l <> "\e[0m"
      "diff " <> _ = l -> "\e[1m" <> l <> "\e[0m"
      "+" <> _ = l -> "\e[32m" <> l <> "\e[0m"
      "-" <> _ = l -> "\e[31m" <> l <> "\e[0m"
      "@@" <> _ = l -> "\e[36m" <> l <> "\e[0m"
      l -> l
    end)
  end
end
