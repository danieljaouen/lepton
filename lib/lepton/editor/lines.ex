defmodule Lepton.Editor.Lines do
  @moduledoc """
  A buffer's lines: a persistent sequence of binaries in chunks of up to
  #{512} lines, `{:lines, chunks, starts, count}`, `starts` holding the
  number of each chunk's first line.

  An edit rebuilds the chunks it touches and the small tuples above them,
  not the whole buffer: typing in a 50 MB file copies a few kilobytes,
  and the versions undo keeps share every chunk an edit left alone (a
  flat tuple of 660,000 lines was 5 MB a keystroke, and 5 MB an undo step).
  """

  @chunk 512
  # a chunk an edit leaves smaller than this joins the next one
  @small div(@chunk, 4)

  def new([]), do: new([""])

  def new(list) when is_list(list) do
    chunks = list |> Enum.chunk_every(@chunk) |> Enum.map(&List.to_tuple/1)
    build(chunks)
  end

  defp build([]), do: new([""])

  defp build(chunks) do
    {starts, count} = Enum.map_reduce(chunks, 0, fn c, at -> {at, at + tuple_size(c)} end)
    {:lines, List.to_tuple(chunks), List.to_tuple(starts), count}
  end

  def size({:lines, _, _, n}), do: n

  def at({:lines, chunks, starts, n}, i) when is_integer(i) and i >= 0 and i < n do
    k = chunk_of(starts, i)
    elem(elem(chunks, k), i - elem(starts, k))
  end

  def at(_, _), do: nil

  def to_list({:lines, chunks, _, _}), do: chunks |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1)

  @doc "Lines `from`..`to` (inclusive, clipped to the buffer), as a list."
  def slice({:lines, _, _, n} = t, from, to) do
    from = max(from, 0)
    to = min(to, n - 1)
    if from > to, do: [], else: do_slice(t, from, to)
  end

  defp do_slice({:lines, chunks, starts, _}, from, to) do
    k1 = chunk_of(starts, from)
    k2 = chunk_of(starts, to)

    Enum.flat_map(k1..k2, fn k ->
      c = elem(chunks, k)
      s = elem(starts, k)
      a = max(from - s, 0)
      b = min(to - s, tuple_size(c) - 1)
      for i <- a..b//1, do: elem(c, i)
    end)
  end

  @doc """
  Replace lines `l1`..`l2` (inclusive) with `new`: `l2 = l1 - 1` inserts
  before line `l1` (`l1` may be the line count, to add at the end).
  """
  def replace({:lines, chunks, starts, n}, l1, l2, new) when is_list(new) do
    l1 = min(max(l1, 0), n)
    l2 = min(max(l2, l1 - 1), n - 1)
    nchunks = tuple_size(chunks)
    k1 = if l1 >= n, do: nchunks - 1, else: chunk_of(starts, l1)
    k2 = if l2 < l1, do: k1, else: chunk_of(starts, l2)
    local = Enum.flat_map(k1..k2, &Tuple.to_list(elem(chunks, &1)))
    base = elem(starts, k1)
    {head, rest} = Enum.split(local, l1 - base)
    tail = Enum.drop(rest, l2 - l1 + 1)
    middle = head ++ new ++ tail

    # A small remainder joins the next chunk, so edits don't leave the
    # buffer in crumbs.
    {k2, middle} =
      if length(middle) < @small and k2 + 1 < nchunks,
        do: {k2 + 1, middle ++ Tuple.to_list(elem(chunks, k2 + 1))},
        else: {k2, middle}

    mid_chunks = middle |> Enum.chunk_every(@chunk) |> Enum.map(&List.to_tuple/1)
    all = Tuple.to_list(chunks)
    rebuilt = Enum.take(all, k1) ++ mid_chunks ++ Enum.drop(all, k2 + 1)
    build(rebuilt)
  end

  @doc "Every line through `fun`."
  def map(t, fun), do: t |> to_list() |> Enum.map(fun) |> new()

  @doc """
  How many lines two versions share at the start and at the end (the
  suffix not overlapping the prefix): chunks an edit didn't touch are
  the same term, and skipped whole.
  """
  def common({:lines, oc, os, on} = old, {:lines, nc, ns, nn} = new) do
    limit = min(on, nn)
    both = min(tuple_size(oc), tuple_size(nc))
    # whole chunks first (identical terms compare at once)
    pk = Enum.find(0..(both - 1)//1, both, &(elem(os, &1) != elem(ns, &1) or elem(oc, &1) != elem(nc, &1)))
    from = if pk < both, do: min(elem(os, pk), limit), else: limit
    prefix = Enum.find(from..(limit - 1)//1, limit, &(at(old, &1) != at(new, &1)))

    max_suffix = limit - prefix
    # whole chunks from the end
    skip =
      Enum.reduce_while(0..(both - 1)//1, 0, fn j, acc ->
        a = elem(oc, tuple_size(oc) - 1 - j)
        b = elem(nc, tuple_size(nc) - 1 - j)
        if a == b and acc + tuple_size(a) <= max_suffix, do: {:cont, acc + tuple_size(a)}, else: {:halt, acc}
      end)

    suffix = Enum.find(skip..(max_suffix - 1)//1, max_suffix, &(at(old, on - 1 - &1) != at(new, nn - 1 - &1)))
    {prefix, suffix}
  end

  # The chunk holding line `i`: a binary search of the starts.
  defp chunk_of(starts, i), do: search(starts, i, 0, tuple_size(starts) - 1)

  defp search(_starts, _i, lo, hi) when lo >= hi, do: lo

  defp search(starts, i, lo, hi) do
    mid = div(lo + hi + 1, 2)
    if elem(starts, mid) <= i, do: search(starts, i, mid, hi), else: search(starts, i, lo, mid - 1)
  end
end
