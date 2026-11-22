defmodule Lepton.Editor.Fold do
  @moduledoc """
  Outline folding for `le`, as in Org mode (Spacemacs with evil-org):

  - `TAB` on a heading cycles it: folded → its child headings → the whole
    subtree → folded (`org-cycle`).
  - `S-TAB` cycles the buffer: the top-level headings → every heading →
    everything (`org-global-cycle`).
  - `zm` / `zM` fold every heading, `zr` / `zR` reveal everything;
    `za` toggles the heading the cursor is under, `zc` folds it and `zo`
    opens it.

  A buffer's folds are the set of heading lines whose subtree is hidden
  (`Buffer.folds`): all of a buffer's windows show them. The lines of a
  folded subtree are skipped when drawing and by `j` and `k`; a search
  that lands inside one opens it. Edits keep folds above and below the
  changed lines (`remap/3`).
  """

  alias Lepton.Editor.Buffer

  @doc "Does this buffer have an outline (headings) to fold?"
  def outline?(b), do: b.mode == "Org"

  @doc "A line's heading level (Org: the number of leading stars), or 0."
  def level(line) do
    case Regex.run(~r/^(\*+)(?:\s|$)/, line) do
      [_, stars] -> String.length(stars)
      _ -> 0
    end
  end

  def heading?(b, n), do: outline?(b) and level(Buffer.line(b, n)) > 0

  @doc "The last line of heading `h`'s subtree (`h` itself when it is empty)."
  def subtree_end(b, h) do
    lv = level(Buffer.line(b, h))
    count = Buffer.line_count(b)
    next = Enum.find((h + 1)..(count - 1)//1, fn n -> (l = level(Buffer.line(b, n))) > 0 and l <= lv end)
    if next, do: next - 1, else: count - 1
  end

  @doc "The heading whose subtree holds line `n` (`n` itself on a heading), or nil."
  def heading_at(b, n) do
    if outline?(b), do: Enum.find(n..0//-1, &(level(Buffer.line(b, &1)) > 0)), else: nil
  end

  @doc "The headings inside `h`'s subtree."
  def descendants(b, h), do: for(n <- (h + 1)..subtree_end(b, h)//1, level(Buffer.line(b, n)) > 0, do: n)

  def headings(b) do
    if outline?(b), do: for({line, n} <- Enum.with_index(Buffer.lines(b)), level(line) > 0, do: n), else: []
  end

  # -- what is hidden -------------------------------------------------------------------

  @doc "The hidden line ranges: one per folded heading with a body."
  def hidden(%{folds: folds} = b) do
    if MapSet.size(folds) == 0 do
      []
    else
      for h <- Enum.sort(folds), (e = subtree_end(b, h)) > h, do: (h + 1)..e
    end
  end

  def hidden?(ranges, n), do: Enum.any?(ranges, &(n in &1))

  @doc "The first visible line at or after `n` (nil past the end)."
  def visible_at_or_after(ranges, n, count) do
    cond do
      n >= count -> nil
      r = Enum.find(ranges, &(n in &1)) -> visible_at_or_after(ranges, r.last + 1, count)
      true -> n
    end
  end

  @doc "The line shown for `n`: itself, or the folded heading that hides it."
  def shown(ranges, n) do
    case Enum.filter(ranges, &(n in &1)) do
      [] -> n
      rs -> (rs |> Enum.map(& &1.first) |> Enum.min()) - 1
    end
  end

  @doc "`count` visible lines from the one shown for `top`."
  def visible_lines(b, top, count) do
    ranges = hidden(b)
    total = Buffer.line_count(b)
    start = shown(ranges, min(top, total - 1))

    Stream.unfold(start, fn
      nil -> nil
      n -> {n, visible_at_or_after(ranges, n + 1, total)}
    end)
    |> Enum.take(count)
  end

  @doc "Move `steps` visible lines from `l` (negative: up)."
  def step(b, l, steps) do
    ranges = hidden(b)
    total = Buffer.line_count(b)
    l = shown(ranges, l)

    Enum.reduce_while(1..abs(steps)//1, l, fn _, at ->
      next = if steps > 0, do: visible_at_or_after(ranges, at + 1, total), else: (if at > 0, do: shown(ranges, at - 1), else: nil)
      if next, do: {:cont, next}, else: {:halt, at}
    end)
  end

  @doc "The number of visible lines from `a` up to `b` (exclusive), a <= b."
  def visible_between(b, a, z) do
    ranges = hidden(b)
    Enum.count(a..(z - 1)//1, &(not hidden?(ranges, &1)))
  end

  # -- changing folds -------------------------------------------------------------------

  def fold(b, hs), do: %{b | folds: Enum.reduce(List.wrap(hs), b.folds, &MapSet.put(&2, &1))}
  def unfold(b, hs), do: %{b | folds: Enum.reduce(List.wrap(hs), b.folds, &MapSet.delete(&2, &1))}

  @doc "Open whatever hides line `n` (a search landed there)."
  def reveal(b, n) do
    case Enum.filter(b.folds, fn h -> h < n and n <= subtree_end(b, h) end) do
      [] -> b
      hs -> unfold(b, hs)
    end
  end

  @doc "Fold every heading (zm): only the top-level ones stay visible."
  def fold_all(b), do: %{b | folds: MapSet.new(headings(b))}

  @doc "Reveal everything (zr)."
  def unfold_all(b), do: %{b | folds: MapSet.new()}

  @doc """
  `org-cycle` on heading `h`: folded → children → subtree → folded.
  Returns the buffer and the state's name.
  """
  def cycle(b, h) do
    kids = descendants(b, h)

    cond do
      subtree_end(b, h) == h -> {b, "EMPTY ENTRY"}
      MapSet.member?(b.folds, h) and kids != [] -> {b |> unfold(h) |> fold(kids), "CHILDREN"}
      MapSet.member?(b.folds, h) -> {unfold(b, h), "SUBTREE"}
      Enum.any?(kids, &MapSet.member?(b.folds, &1)) -> {unfold(b, kids), "SUBTREE"}
      true -> {fold(b, h), "FOLDED"}
    end
  end

  @doc "`org-global-cycle`: overview → contents → show all."
  def global_cycle(b) do
    hs = headings(b)
    with_body = Enum.filter(hs, &(subtree_end(b, &1) > &1))

    cond do
      hs == [] ->
        {b, "No headings"}

      overview?(b, hs) ->
        # Contents: every heading shows, bodies don't. A heading's body is
        # the text before its first child, so fold the leaves only.
        leaves = Enum.filter(with_body, fn h -> descendants(b, h) == [] end)
        {%{b | folds: MapSet.new(leaves)}, "CONTENTS"}

      MapSet.size(b.folds) > 0 and contents?(b, hs) ->
        {unfold_all(b), "SHOW ALL"}

      # Everything visible, or folded some other way: the overview.
      true ->
        {fold_all(b), "OVERVIEW"}
    end
  end

  defp overview?(b, hs), do: MapSet.equal?(b.folds, MapSet.new(hs))

  defp contents?(b, hs) do
    leaves = Enum.filter(hs, fn h -> subtree_end(b, h) > h and descendants(b, h) == [] end)
    MapSet.equal?(b.folds, MapSet.new(leaves))
  end

  @doc """
  Keep folds across an edit from `old` to `new` lines: folds above the
  changed lines stay, those below move with them, those in the changed
  lines go, as do any that are no longer headings.
  """
  def remap(folds, old, new) do
    if MapSet.size(folds) == 0 or old == new do
      folds
    else
      {os, ns} = {tuple_size(old), tuple_size(new)}
      prefix = Enum.find(0..(min(os, ns) - 1)//1, min(os, ns), &(elem(old, &1) != elem(new, &1)))
      max_suffix = min(os, ns) - prefix
      suffix = Enum.find(0..(max_suffix - 1)//1, max_suffix, &(elem(old, os - 1 - &1) != elem(new, ns - 1 - &1)))
      delta = ns - os

      for h <- folds,
          n = (cond do
            h < prefix -> h
            h >= os - suffix -> h + delta
            true -> nil
          end),
          n != nil and n < ns and level(elem(new, n)) > 0,
          into: MapSet.new(),
          do: n
    end
  end
end
