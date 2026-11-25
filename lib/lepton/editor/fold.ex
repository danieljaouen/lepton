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

  Lines added while a subtree is folded stay visible until it is folded
  again (`Buffer.revealed`), as text typed in Emacs is: `O` above a
  heading opens a line at the end of the folded entry before it, and
  that line shows, with the entry still folded.
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

  @doc "The hidden line ranges: a folded heading's body, but for lines added since (`revealed`)."
  def hidden(%{folds: folds} = b) do
    if MapSet.size(folds) == 0 do
      []
    else
      for h <- Enum.sort(folds), (e = subtree_end(b, h)) > h, r <- without(h + 1, e, b.revealed), do: r
    end
  end

  @doc "The folded headings that hide lines (they end in an ellipsis)."
  def folded_headings(b), do: for(h <- b.folds, subtree_end(b, h) > h, into: MapSet.new(), do: h)

  defp without(a, z, revealed) do
    if Enum.any?(revealed, &(&1 in a..z)) do
      a..z
      |> Enum.chunk_by(&MapSet.member?(revealed, &1))
      |> Enum.reject(&MapSet.member?(revealed, hd(&1)))
      |> Enum.map(&(hd(&1)..List.last(&1)))
    else
      [a..z]
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

  # Folding hides again the lines added since (`revealed`).
  def fold(b, hs), do: %{b | folds: Enum.reduce(List.wrap(hs), b.folds, &MapSet.put(&2, &1)), revealed: MapSet.new()}
  def unfold(b, hs), do: %{b | folds: Enum.reduce(List.wrap(hs), b.folds, &MapSet.delete(&2, &1))}

  @doc "Open whatever hides line `n` (a search landed there)."
  def reveal(b, n) do
    case Enum.filter(b.folds, fn h -> h < n and n <= subtree_end(b, h) end) do
      [] -> b
      hs -> unfold(b, hs)
    end
  end

  @doc "Fold every heading (zm): only the top-level ones stay visible."
  def fold_all(b), do: %{b | folds: MapSet.new(headings(b)), revealed: MapSet.new()}

  @doc "Reveal everything (zr)."
  def unfold_all(b), do: %{b | folds: MapSet.new(), revealed: MapSet.new()}

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
        {%{b | folds: MapSet.new(leaves), revealed: MapSet.new()}, "CONTENTS"}

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
      {prefix, suffix, os, ns} = diff(old, new)

      for h <- folds, n = moved(h, prefix, suffix, os, ns), n != nil and level(Lepton.Editor.Lines.at(new, n)) > 0, into: MapSet.new(), do: n
    end
  end

  @doc """
  The revealed lines across the same edit: they move as folds do, stay
  revealed when edited, and lines it adds while something is folded join
  them.
  """
  def remap_revealed(revealed, folds, old, new) do
    if MapSet.size(folds) == 0 or old == new do
      if MapSet.size(folds) == 0, do: MapSet.new(), else: revealed
    else
      {prefix, suffix, os, ns} = diff(old, new)
      kept = for n <- revealed, m = moved(n, prefix, suffix, os, ns), m != nil, into: MapSet.new(), do: m
      # Added lines, and the changed lines that were revealed: revealed.
      edited? = Enum.any?(revealed, &(&1 >= prefix and &1 < os - suffix))
      if ns > os or edited?, do: Enum.into(prefix..(ns - suffix - 1)//1, kept), else: kept
    end
  end

  @doc """
  Marks (`%{name => {line, column}}`) across the same edit: lines added or
  removed above one move it; on a line that changed it stays where it was
  (on the last line, if the buffer got shorter than that).
  """
  def remap_marks(marks, old, new) do
    if map_size(marks) == 0 or old == new do
      marks
    else
      {prefix, suffix, os, ns} = diff(old, new)
      for {k, {l, c}} <- marks, into: %{}, do: {k, {moved(l, prefix, suffix, os, ns) || min(l, ns - 1), c}}
    end
  end

  # The lines two versions share at the start and at the end.
  defp diff(old, new) do
    {prefix, suffix} = Lepton.Editor.Lines.common(old, new)
    {prefix, suffix, Lepton.Editor.Lines.size(old), Lepton.Editor.Lines.size(new)}
  end

  # Where line `n` is after the edit, or nil if it was changed.
  defp moved(n, prefix, suffix, os, ns) do
    m =
      cond do
        n < prefix -> n
        n >= os - suffix -> n + ns - os
        true -> nil
      end

    if m != nil and m < ns, do: m
  end
end
