defmodule Lepton.Editor.LinesTest do
  use ExUnit.Case, async: true
  alias Lepton.Editor.Lines

  # Lines against a plain list, through thousands of random edits of every
  # size, at chunk edges too.
  test "it behaves as a list through random replacements, inserts and deletes" do
    :rand.seed(:exsss, {1, 2, 3})
    start = for i <- 1..3000, do: "line #{i}"

    Enum.reduce(1..3000, {Lines.new(start), start}, fn step, {t, list} ->
      n = length(list)
      l1 = :rand.uniform(n + 1) - 1
      l2 = l1 - 1 + min(Enum.random([0, 0, 1, 1, 2, 5, 600, 1100]), n - l1)
      new = for j <- 1..Enum.random([0, 1, 1, 2, 3, 700])//1, do: "s#{step}.#{j}"
      new = if Enum.random([true, false]), do: new, else: Enum.take(new, 1)

      t = Lines.replace(t, l1, l2, new)
      {head, rest} = Enum.split(list, l1)
      list = head ++ new ++ Enum.drop(rest, max(l2 - l1 + 1, 0))
      list = if list == [], do: [""], else: list

      assert Lines.size(t) == length(list)
      if rem(step, 50) == 0, do: assert(Lines.to_list(t) == list)
      i = :rand.uniform(length(list)) - 1
      assert Lines.at(t, i) == Enum.at(list, i)
      a = :rand.uniform(length(list)) - 1
      assert Lines.slice(t, a, a + 700) == Enum.slice(list, a, 701)
      {t, list}
    end)
  end

  test "common: the lines two versions share at the start and the end" do
    list = for i <- 1..5000, do: "l#{i}"
    old = Lines.new(list)
    assert Lines.common(old, old) == {5000, 0}
    new = Lines.replace(old, 2500, 2501, ["x"])
    assert Lines.common(old, new) == {2500, 2498}
    new = Lines.replace(old, 0, -1, ["top"])
    assert Lines.common(old, new) == {0, 5000}
    new = Lines.replace(old, 4999, 4999, [])
    assert Lines.common(old, new) == {4999, 0}
    # Equal content in different chunks counts too.
    assert Lines.common(old, Lines.new(list)) == {5000, 0}
  end

  test "an edit shares the chunks it didn't touch (undo keeps versions cheaply)" do
    old = Lines.new(for i <- 1..100_000, do: "line #{i}")
    new = Lines.replace(old, 50_000, 50_000, ["changed"])
    {:lines, oc, _, _} = old
    {:lines, nc, _, _} = new
    shared = Enum.count(0..(tuple_size(oc) - 1), &:erts_debug.same(elem(oc, &1), elem(nc, &1)))
    assert shared >= tuple_size(oc) - 2
    # Deleting every line leaves one empty line, as a buffer always has.
    assert Lines.to_list(Lines.replace(Lines.new(["a"]), 0, 0, [])) == [""]
  end
end
