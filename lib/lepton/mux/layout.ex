defmodule Lepton.Mux.Layout do
  @moduledoc """
  Pane layouts as trees: `{:pane, id}` or `{:split, :h | :v, [{tree, weight}]}`.
  `:h` places children side by side (tmux `split-window -h`), `:v` stacks
  them. Weights are relative sizes; one cell separates siblings (the
  border).
  """

  def panes({:pane, id}), do: [id]
  def panes({:split, _, children}), do: Enum.flat_map(children, fn {t, _} -> panes(t) end)

  @doc "Rectangles {x, y, w, h} for each pane in an area."
  def rects(tree, area), do: rects(tree, area, %{})

  defp rects({:pane, id}, area, acc), do: Map.put(acc, id, area)

  defp rects({:split, dir, children}, {x, y, w, h}, acc) do
    n = length(children)
    total = if dir == :h, do: w - (n - 1), else: h - (n - 1)
    weights = Enum.map(children, &elem(&1, 1))
    sizes = distribute(max(total, n), weights)

    {acc, _} =
      Enum.zip(children, sizes)
      |> Enum.reduce({acc, if(dir == :h, do: x, else: y)}, fn {{child, _}, size}, {acc, pos} ->
        area = if dir == :h, do: {pos, y, max(size, 1), h}, else: {x, pos, w, max(size, 1)}
        {rects(child, area, acc), pos + size + 1}
      end)

    acc
  end

  # Split `total` cells proportionally to weights (largest remainder).
  def distribute(total, weights) do
    sum = Enum.sum(weights)
    sum = if sum == 0, do: length(weights), else: sum
    raw = Enum.map(weights, &(&1 * total / sum))
    floors = Enum.map(raw, &max(trunc(&1), 1))
    left = total - Enum.sum(floors)

    raw
    |> Enum.with_index()
    |> Enum.sort_by(fn {r, _} -> -(r - trunc(r)) end)
    |> Enum.take(max(left, 0))
    |> Enum.reduce(floors, fn {_, i}, acc -> List.update_at(acc, i, &(&1 + 1)) end)
  end

  @doc "Split pane `target`; the new pane takes `pct` percent (default 50)."
  def split(tree, target, dir, new_id, pct \\ 50, before \\ false) do
    replace(tree, target, fn leaf ->
      new = {{:pane, new_id}, pct}
      old = {leaf, 100 - pct}
      {:split, dir, if(before, do: [new, old], else: [old, new])}
    end)
    |> flatten()
  end

  defp replace({:pane, id} = leaf, id, fun), do: fun.(leaf)
  defp replace({:pane, _} = leaf, _, _), do: leaf
  defp replace({:split, d, ch}, id, fun), do: {:split, d, Enum.map(ch, fn {t, w} -> {replace(t, id, fun), w} end)}

  # Merge a split nested in a split of the same direction, scaling weights.
  def flatten({:split, d, children}) do
    children =
      Enum.flat_map(children, fn
        {{:split, ^d, inner}, w} ->
          total = inner |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          Enum.map(inner, fn {t, iw} -> {flatten(t), w * iw / max(total, 1)} end)

        {t, w} ->
          [{flatten(t), w}]
      end)

    case children do
      [{one, _}] -> one
      many -> {:split, d, many}
    end
  end

  def flatten(leaf), do: leaf

  def remove({:pane, id}, id), do: nil
  def remove({:pane, _} = leaf, _), do: leaf

  def remove({:split, d, ch}, id) do
    ch = for {t, w} <- ch, t2 = remove(t, id), t2 != nil, do: {t2, w}

    case ch do
      [] -> nil
      [{one, _}] -> one
      many -> {:split, d, many}
    end
  end

  def rename({:pane, id}, id, new), do: {:pane, new}
  def rename({:pane, _} = l, _, _), do: l
  def rename({:split, d, ch}, id, new), do: {:split, d, Enum.map(ch, fn {t, w} -> {rename(t, id, new), w} end)}

  @doc "Exchange two panes' positions within one tree."
  def swap(tree, a, b), do: tree |> rename(a, :swap_tmp) |> rename(b, a) |> rename(:swap_tmp, b)

  def tiled(ids) do
    n = length(ids)
    cols = n |> :math.sqrt() |> Float.ceil() |> trunc() |> max(1)
    rows = ids |> Enum.chunk_every(cols)

    rows
    |> Enum.map(fn row -> {if(length(row) == 1, do: {:pane, hd(row)}, else: {:split, :h, Enum.map(row, &{{:pane, &1}, 1})}), 1} end)
    |> then(fn
      [{one, _}] -> one
      many -> {:split, :v, many}
    end)
  end

  def even(ids, dir) do
    case ids do
      [one] -> {:pane, one}
      many -> {:split, dir, Enum.map(many, &{{:pane, &1}, 1})}
    end
  end

  def main_vertical([main | rest]) when rest != [], do: {:split, :h, [{{:pane, main}, 60}, {even(rest, :v), 40}]}
  def main_vertical(ids), do: even(ids, :h)

  @doc "The pane adjacent to `id` in direction :left/:right/:up/:down (wrapping like tmux)."
  def neighbor(tree, area, id, dir) do
    rects = rects(tree, area)
    {x, y, w, h} = rects[id]
    {cx, cy} = {x + div(w, 2), y + div(h, 2)}

    candidates =
      for {other, {ox, oy, ow, oh}} <- rects, other != id do
        overlap_v = oy < y + h and y < oy + oh
        overlap_h = ox < x + w and x < ox + ow

        ok =
          case dir do
            :left -> ox + ow <= x and overlap_v
            :right -> ox >= x + w and overlap_v
            :up -> oy + oh <= y and overlap_h
            :down -> oy >= y + h and overlap_h
          end

        {other, ok, abs(ox + div(ow, 2) - cx) + abs(oy + div(oh, 2) - cy)}
      end

    case Enum.filter(candidates, fn {_, ok, _} -> ok end) do
      [] -> wrap(rects, id, dir)
      list -> list |> Enum.min_by(fn {_, _, d} -> d end) |> elem(0)
    end
  end

  defp wrap(rects, id, dir) do
    {x, y, w, h} = rects[id]

    others =
      for {o, {ox, oy, ow, oh}} <- rects, o != id do
        case dir do
          d when d in [:left, :right] -> {o, oy < y + h and y < oy + oh, if(d == :left, do: -ox, else: ox)}
          d when d in [:up, :down] -> {o, ox < x + w and x < ox + ow, if(d == :up, do: -oy, else: oy)}
        end
      end

    case Enum.filter(others, fn {_, ok, _} -> ok end) do
      [] -> id
      list -> list |> Enum.min_by(fn {_, _, k} -> k end) |> elem(0)
    end
  end

  @doc "Grow/shrink pane `id` by `n` cells toward `dir`."
  def resize(tree, area, id, dir, n) do
    axis = if dir in [:left, :right], do: :h, else: :v
    sign = if dir in [:right, :down], do: 1, else: -1
    rects = rects(tree, area)
    {tree, _} = do_resize(tree, rects, id, axis, sign * n)
    tree
  end

  defp do_resize({:pane, _} = l, _rects, _id, _axis, _n), do: {l, false}

  defp do_resize({:split, d, ch}, rects, id, axis, n) do
    idx = Enum.find_index(ch, fn {t, _} -> id in panes(t) end)

    cond do
      idx == nil ->
        {{:split, d, ch}, false}

      true ->
        {child, w} = Enum.at(ch, idx)
        {child2, done} = do_resize(child, rects, id, axis, n)
        ch = List.replace_at(ch, idx, {child2, w})

        if done or d != axis do
          {{:split, d, ch}, done}
        else
          # Like tmux: move the pane's border in `dir`. With a neighbour on
          # that side the pane grows into it; otherwise the opposite border
          # moves and the pane shrinks.
          step = if n > 0, do: 1, else: -1
          {grow, shrink} =
            cond do
              idx + step >= 0 and idx + step < length(ch) -> {idx, idx + step}
              idx - step >= 0 and idx - step < length(ch) -> {idx - step, idx}
              true -> {nil, nil}
            end

          if grow == nil do
            {{:split, d, ch}, false}
          else
            sizes = Enum.map(ch, fn {t, _} -> size(t, rects, d) end)
            delta = min(abs(n), Enum.at(sizes, shrink) - 1)
            sizes = sizes |> List.update_at(grow, &(&1 + delta)) |> List.update_at(shrink, &(&1 - delta))
            {{:split, d, Enum.zip(Enum.map(ch, &elem(&1, 0)), sizes)}, true}
          end
        end
    end
  end

  defp size(tree, rects, dir) do
    ids = panes(tree)
    boxes = Enum.map(ids, &rects[&1])

    if dir == :h do
      min_x = boxes |> Enum.map(&elem(&1, 0)) |> Enum.min()
      max_x = boxes |> Enum.map(fn {x, _, w, _} -> x + w end) |> Enum.max()
      max_x - min_x
    else
      min_y = boxes |> Enum.map(&elem(&1, 1)) |> Enum.min()
      max_y = boxes |> Enum.map(fn {_, y, _, h} -> y + h end) |> Enum.max()
      max_y - min_y
    end
  end
end
