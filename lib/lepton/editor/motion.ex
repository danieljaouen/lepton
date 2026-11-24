defmodule Lepton.Editor.Motion do
  @moduledoc """
  Evil (vim) motions and text objects as pure functions over a buffer.

  `parse/1` recognises a key sequence; `apply/5` computes the target.
  A motion yields `{target_pos, kind}` where kind is `:exclusive`,
  `:inclusive` or `:linewise` (what an operator acts on); a text object
  yields `{:range, from, to, kind}`.
  """

  alias Lepton.Editor.Buffer

  @simple ~w(h j k l w b e W B E 0 ^ $ G H M L % { } n N ; , + - _ |) ++
            ["<left>", "<right>", "<up>", "<down>", "<home>", "<end>", "SPC", "DEL", "RET"]

  @doc "Classify a key sequence: {:motion, m} | {:object, o} | :more | :invalid."
  def parse([k]) when k in @simple, do: {:motion, k}
  def parse(["g"]), do: :more
  def parse(["g", k]) when k in ["g", "e", "_", "0", "$", "E"], do: {:motion, "g" <> k}
  def parse([k]) when k in ["f", "F", "t", "T"], do: :more
  # A mark: ' to its line (first non-blank), ` to the very place.
  def parse([k]) when k in ["'", "`"], do: :more
  def parse([k, m]) when k in ["'", "`"], do: {:motion, {k, m}}
  def parse([k, c]) when k in ["f", "F", "t", "T"], do: {:motion, {k, char(c)}}
  def parse([k]) when k in ["i", "a"], do: :more
  def parse([k, o]) when k in ["i", "a"], do: {:object, {k, o}}
  def parse(_), do: :invalid

  defp char("SPC"), do: " "
  defp char("TAB"), do: "\t"
  defp char(c), do: c

  @doc """
  Apply a motion. `ctx` is a map with `:view` (`{top, height}`) and
  `:last_find` / `:search` for `;`, `,`, `n`, `N`.
  """
  def apply(buf, {l, c}, motion, count, ctx \\ %{}) do
    n = count || 1
    last = Buffer.line_count(buf) - 1

    case motion do
      m when m in ["h", "<left>", "DEL"] -> {{l, max(c - n, 0)}, :exclusive}
      m when m in ["l", "<right>", "SPC"] -> {{l, min(c + n, max_col(buf, l, true))}, :exclusive}
      m when m in ["j", "<down>"] -> {{min(l + n, last), c}, :linewise}
      m when m in ["k", "<up>"] -> {{max(l - n, 0), c}, :linewise}
      m when m in ["+", "RET"] -> {{min(l + n, last), first_non_blank(buf, min(l + n, last))}, :linewise}
      "-" -> {{max(l - n, 0), first_non_blank(buf, max(l - n, 0))}, :linewise}
      "_" -> {{min(l + n - 1, last), first_non_blank(buf, min(l + n - 1, last))}, :linewise}
      m when m in ["0", "<home>"] -> {{l, 0}, :exclusive}
      "^" -> {{l, first_non_blank(buf, l)}, :exclusive}
      m when m in ["$", "<end>"] ->
        target = min(l + n - 1, last)
        {{target, max(Buffer.line_length(buf, target) - 1, 0)}, :inclusive}

      "|" -> {{l, min(n - 1, max_col(buf, l))}, :exclusive}
      "G" -> line_target(buf, if(count, do: count - 1, else: last))
      "gg" -> line_target(buf, if(count, do: count - 1, else: 0))
      "g_" -> {{l, max(String.length(String.trim_trailing(Buffer.line(buf, l))) - 1, 0)}, :inclusive}
      "w" -> repeat(n, {l, c}, &word_forward(buf, &1, :word)) |> excl()
      "W" -> repeat(n, {l, c}, &word_forward(buf, &1, :WORD)) |> excl()
      "b" -> repeat(n, {l, c}, &word_backward(buf, &1, :word)) |> excl()
      "B" -> repeat(n, {l, c}, &word_backward(buf, &1, :WORD)) |> excl()
      "e" -> repeat(n, {l, c}, &word_end(buf, &1, :word)) |> incl()
      "E" -> repeat(n, {l, c}, &word_end(buf, &1, :WORD)) |> incl()
      "ge" -> repeat(n, {l, c}, &word_end_backward(buf, &1)) |> incl()
      "H" -> view_target(buf, ctx, :top)
      "M" -> view_target(buf, ctx, :middle)
      "L" -> view_target(buf, ctx, :bottom)
      "}" -> repeat(n, {l, c}, &paragraph(buf, &1, 1)) |> excl()
      "{" -> repeat(n, {l, c}, &paragraph(buf, &1, -1)) |> excl()
      "%" -> match_pair(buf, {l, c})
      {k, ch} when k in ["f", "F", "t", "T"] -> find_char(buf, {l, c}, k, ch, n)
      {k, m} when k in ["'", "`"] -> mark_target(buf, {l, c}, k, (ctx[:marks] || %{})[m])
      ";" -> repeat_find(buf, {l, c}, ctx[:last_find], n, false)
      "," -> repeat_find(buf, {l, c}, ctx[:last_find], n, true)
      "n" -> search(buf, {l, c}, ctx[:search], n, false)
      "N" -> search(buf, {l, c}, ctx[:search], n, true)
      _ -> {{l, c}, :exclusive}
    end
  end

  defp excl(pos), do: {pos, :exclusive}
  defp incl(pos), do: {pos, :inclusive}

  defp repeat(0, pos, _f), do: pos
  defp repeat(n, pos, f), do: repeat(n - 1, f.(pos), f)

  def max_col(buf, l, allow_eol \\ false) do
    len = Buffer.line_length(buf, l)
    if allow_eol, do: max(len - 1, 0), else: max(len - 1, 0)
  end

  def first_non_blank(buf, l) do
    line = Buffer.line(buf, l)
    String.length(line) - String.length(String.trim_leading(line))
  end

  defp line_target(buf, target) do
    t = target |> max(0) |> min(Buffer.line_count(buf) - 1)
    {{t, first_non_blank(buf, t)}, :linewise}
  end

  defp view_target(buf, ctx, where) do
    {top, height} = Map.get(ctx, :view, {0, 20})
    last = min(top + height - 1, Buffer.line_count(buf) - 1)

    l =
      case where do
        :top -> top
        :middle -> div(top + last, 2)
        :bottom -> last
      end

    {{l, first_non_blank(buf, l)}, :linewise}
  end

  # -- words ----------------------------------------------------------------------------

  defp class(nil, _), do: :eol
  defp class(c, kind) do
    cond do
      c =~ ~r/^\s$/u -> :space
      kind == :WORD -> :word
      c =~ ~r/^[\p{L}\p{N}_]$/u -> :word
      true -> :punct
    end
  end

  defp char_at(buf, {l, c}), do: Buffer.line(buf, l) |> String.at(c)

  defp next_pos(buf, {l, c}) do
    len = Buffer.line_length(buf, l)

    cond do
      c + 1 < len -> {l, c + 1}
      l + 1 < Buffer.line_count(buf) -> {l + 1, -1}
      true -> nil
    end
  end

  defp prev_pos(buf, {l, c}) do
    cond do
      c > 0 -> {l, c - 1}
      l > 0 -> {l - 1, max(Buffer.line_length(buf, l - 1), 0)}
      true -> nil
    end
  end

  # Positions with col -1 denote "start of line l" (the line break before it).
  defp norm({l, -1}), do: {l, 0}
  defp norm(p), do: p

  def word_forward(buf, pos, kind) do
    start_class = class(char_at(buf, pos), kind)
    do_word_forward(buf, pos, start_class, kind, false)
  end

  defp do_word_forward(buf, pos, start_class, kind, crossed) do
    case next_pos(buf, pos) do
      nil ->
        {l, _} = pos
        {l, max(Buffer.line_length(buf, l) - 1, 0)} |> then(fn p -> if Buffer.line_length(buf, l) == 0, do: {l, 0}, else: p end)

      {l, -1} ->
        # Empty lines are words of their own.
        if Buffer.line_length(buf, l) == 0, do: {l, 0}, else: do_word_forward(buf, {l, -1}, :space, kind, true)

      next ->
        cls = class(char_at(buf, next), kind)

        cond do
          cls == :space -> do_word_forward(buf, next, :space, kind, crossed)
          cls != start_class or crossed -> next
          true -> do_word_forward(buf, next, start_class, kind, crossed)
        end
    end
    |> norm()
  end

  def word_backward(buf, pos, kind) do
    # Skip whitespace backwards, then to the start of that word.
    case skip_back(buf, prev_pos(buf, pos), kind) do
      nil -> {0, 0}
      p ->
        cls = class(char_at(buf, p), kind)
        start_of_run(buf, p, cls, kind)
    end
  end

  defp skip_back(_buf, nil, _kind), do: nil

  defp skip_back(buf, {l, c} = p, kind) do
    ch = char_at(buf, p)

    cond do
      Buffer.line_length(buf, l) == 0 and c == 0 -> p
      ch == nil or class(ch, kind) == :space -> skip_back(buf, prev_pos(buf, p), kind)
      true -> p
    end
  end

  defp start_of_run(buf, {l, c} = p, cls, kind) do
    if c > 0 and class(char_at(buf, {l, c - 1}), kind) == cls, do: start_of_run(buf, {l, c - 1}, cls, kind), else: p
  end

  def word_end(buf, pos, kind) do
    case next_pos(buf, pos) do
      nil -> pos
      next ->
        next = norm(next)
        p = skip_fwd_space(buf, next, kind)

        case p do
          nil -> pos
          p -> end_of_run(buf, p, class(char_at(buf, p), kind), kind)
        end
    end
  end

  defp skip_fwd_space(buf, p, kind) do
    ch = char_at(buf, p)

    if ch == nil or class(ch, kind) == :space do
      case next_pos(buf, p) do
        nil -> nil
        n -> skip_fwd_space(buf, norm(n), kind)
      end
    else
      p
    end
  end

  defp end_of_run(buf, {l, c} = p, cls, kind) do
    nxt = char_at(buf, {l, c + 1})
    if nxt != nil and class(nxt, kind) == cls, do: end_of_run(buf, {l, c + 1}, cls, kind), else: p
  end

  defp word_end_backward(buf, pos) do
    case skip_back(buf, prev_pos(buf, pos), :word) do
      nil -> {0, 0}
      p -> p
    end
  end

  defp paragraph(buf, {l, _}, dir) do
    last = Buffer.line_count(buf) - 1
    blank? = fn i -> String.trim(Buffer.line(buf, i)) == "" end
    # Skip blank lines, then advance to the next blank line.
    i = Stream.iterate(l + dir, &(&1 + dir)) |> Enum.find(fn i -> i < 0 or i > last or not blank?.(i) end)
    j = Stream.iterate(i, &(&1 + dir)) |> Enum.find(fn i -> i < 0 or i > last or blank?.(i) end)
    {j |> max(0) |> min(last), 0}
  end

  @pairs %{"(" => ")", "[" => "]", "{" => "}"}
  @rpairs %{")" => "(", "]" => "[", "}" => "{"}

  defp match_pair(buf, {l, c}) do
    line = Buffer.line(buf, l)
    # Find the first bracket at or after the cursor on this line.
    offset = line |> String.slice(c..-1//1) |> String.graphemes() |> Enum.find_index(&(&1 in ~w|( ) [ ] { }|))

    case offset do
      nil -> {{l, c}, :inclusive}
      off ->
        start = {l, c + off}
        ch = char_at(buf, start)

        target =
          if Map.has_key?(@pairs, ch),
            do: scan(buf, start, ch, @pairs[ch], 1, &next_pos/2),
            else: scan(buf, start, ch, @rpairs[ch], -1, &prev_pos/2)

        {target || {l, c}, :inclusive}
    end
  end

  defp scan(buf, pos, open, close, _dir, step) do
    Stream.unfold({pos, 0}, fn
      nil -> nil
      {p, depth} ->
        ch = char_at(buf, p)
        depth = cond do
          ch == open -> depth + 1
          ch == close -> depth - 1
          true -> depth
        end

        next = step.(buf, p)
        {{p, depth}, if(next, do: {norm(next), depth}, else: nil)}
    end)
    |> Enum.find_value(fn {p, depth} -> if depth == 0, do: p end)
  end

  defp find_char(buf, {l, c}, k, ch, n) do
    line = Buffer.line(buf, l)
    g = String.graphemes(line)

    result =
      case k do
        k when k in ["f", "t"] ->
          g |> Enum.with_index() |> Enum.filter(fn {x, i} -> x == ch and i > c end) |> Enum.at(n - 1)
          |> then(fn
            nil -> nil
            {_, i} -> if k == "t", do: i - 1, else: i
          end)

        k when k in ["F", "T"] ->
          g |> Enum.with_index() |> Enum.filter(fn {x, i} -> x == ch and i < c end) |> Enum.reverse() |> Enum.at(n - 1)
          |> then(fn
            nil -> nil
            {_, i} -> if k == "T", do: i + 1, else: i
          end)
      end

    case result do
      nil -> {{l, c}, :none}
      col -> {{l, col}, if(k in ["f", "t"], do: :inclusive, else: :exclusive)}
    end
  end

  defp repeat_find(_buf, pos, nil, _n, _rev), do: {pos, :none}

  defp repeat_find(buf, {l, c}, {k, ch}, n, reverse) do
    k = if reverse, do: %{"f" => "F", "F" => "f", "t" => "T", "T" => "t"}[k], else: k
    # Repeating t/T must not stick on the adjacent match.
    start = case k do
      "t" -> c + 1
      "T" -> c - 1
      _ -> c
    end

    {{l2, c2}, kind} = find_char(buf, {l, start}, k, ch, n)
    if kind == :none, do: {{l, c}, :none}, else: {{l2, c2}, kind}
  end

  @doc "Search for regex `re` from pos; returns {pos, :exclusive} (wrapping)."
  def search(_buf, pos, nil, _n, _rev), do: {pos, :none}

  def search(buf, pos, {re, dir}, n, reverse) do
    dir = if reverse, do: -dir, else: dir
    Enum.reduce(1..n, {pos, :exclusive}, fn _, {p, _} -> {search_once(buf, p, re, dir) || p, :exclusive} end)
  end

  defp search_once(buf, {l, c}, re, dir) do
    count = Buffer.line_count(buf)

    order =
      if dir > 0,
        do: Enum.map(0..count, fn i -> rem(l + i, count) end),
        else: Enum.map(0..count, fn i -> rem(l - i + count * 2, count) end)

    order
    |> Enum.with_index()
    |> Enum.find_value(fn {li, step} ->
      line = Buffer.line(buf, li)
      matches = Regex.scan(re, line, return: :index) |> Enum.map(fn [{s, _} | _] -> String.length(binary_part(line, 0, s)) end)

      candidates =
        cond do
          step == 0 and dir > 0 -> Enum.filter(matches, &(&1 > c))
          step == 0 and dir < 0 -> Enum.filter(matches, &(&1 < c))
          step == count and dir > 0 -> Enum.filter(matches, &(&1 <= c))
          step == count -> Enum.filter(matches, &(&1 >= c))
          true -> matches
        end

      case if(dir > 0, do: List.first(candidates), else: List.last(candidates)) do
        nil -> nil
        col -> {li, col}
      end
    end)
  end

  # -- text objects --------------------------------------------------------------------

  @doc "Resolve a text object to {:range, from, to_exclusive, kind} or :none."
  def object(buf, {l, c}, {ia, o}) do
    line = Buffer.line(buf, l)

    case o do
      w when w in ["w", "W"] -> word_object(line, l, c, ia, if(w == "w", do: :word, else: :WORD))
      q when q in ["\"", "'", "`"] -> quote_object(line, l, c, ia, q)
      b when b in ["(", ")", "b"] -> bracket_object(buf, {l, c}, ia, "(", ")")
      b when b in ["{", "}", "B"] -> bracket_object(buf, {l, c}, ia, "{", "}")
      b when b in ["[", "]"] -> bracket_object(buf, {l, c}, ia, "[", "]")
      b when b in ["<", ">"] -> bracket_object(buf, {l, c}, ia, "<", ">")
      "p" -> paragraph_object(buf, l, ia)
      _ -> :none
    end
  end

  defp word_object(line, l, c, ia, kind) do
    g = String.graphemes(line)
    if g == [], do: :none, else: do_word_object(g, l, c, ia, kind)
  end

  defp do_word_object(g, l, c, ia, kind) do
    cls = fn i -> class(Enum.at(g, i), kind) end
    here = cls.(c)
    s = Enum.reduce_while((c - 1)..0//-1, c, fn i, acc -> if cls.(i) == here, do: {:cont, i}, else: {:halt, acc} end)
    e = Enum.reduce_while((c + 1)..(length(g) - 1)//1, c, fn i, acc -> if cls.(i) == here, do: {:cont, i}, else: {:halt, acc} end)

    {s, e} =
      if ia == "a" do
        e2 = Enum.reduce_while((e + 1)..(length(g) - 1)//1, e, fn i, acc -> if cls.(i) == :space, do: {:cont, i}, else: {:halt, acc} end)

        if e2 == e,
          do: {Enum.reduce_while((s - 1)..0//-1, s, fn i, acc -> if cls.(i) == :space, do: {:cont, i}, else: {:halt, acc} end), e},
          else: {s, e2}
      else
        {s, e}
      end

    {:range, {l, s}, {l, e + 1}, :exclusive}
  end

  defp quote_object(line, l, c, ia, q) do
    idx = line |> String.graphemes() |> Enum.with_index() |> Enum.filter(fn {x, _} -> x == q end) |> Enum.map(&elem(&1, 1))
    pairs = Enum.chunk_every(idx, 2, 2, :discard)

    case Enum.find(pairs, fn [a, b] -> c >= a and c <= b end) || Enum.find(pairs, fn [a, _] -> a > c end) do
      [a, b] -> if ia == "i", do: {:range, {l, a + 1}, {l, b}, :exclusive}, else: {:range, {l, a}, {l, b + 1}, :exclusive}
      nil -> :none
    end
  end

  defp bracket_object(buf, pos, ia, open, close) do
    with start when start != nil <- find_unmatched(buf, pos, open, close, -1),
         stop when stop != nil <- find_unmatched(buf, pos, close, open, 1) do
      {sl, sc} = start
      {el, ec} = stop
      if ia == "i", do: {:range, {sl, sc + 1}, {el, ec}, :exclusive}, else: {:range, {sl, sc}, {el, ec + 1}, :exclusive}
    else
      _ -> :none
    end
  end

  defp find_unmatched(buf, pos, target, other, dir) do
    step = if dir > 0, do: &next_pos/2, else: &prev_pos/2

    Stream.unfold({pos, 0, true}, fn
      nil -> nil
      {p, depth, first} ->
        ch = char_at(buf, p)
        {found, depth} =
          cond do
            ch == target and depth == 0 -> {true, depth}
            ch == target -> {false, depth - 1}
            ch == other and not first -> {false, depth + 1}
            true -> {false, depth}
          end

        nxt = step.(buf, p)
        {{p, found}, if(nxt && !found, do: {norm(nxt), depth, false}, else: nil)}
    end)
    |> Enum.find_value(fn {p, found} -> if found, do: p end)
  end

  defp paragraph_object(buf, l, ia) do
    last = Buffer.line_count(buf) - 1
    blank? = fn i -> String.trim(Buffer.line(buf, i)) == "" end
    here = blank?.(l)
    s = Enum.reduce_while((l - 1)..0//-1, l, fn i, acc -> if blank?.(i) == here, do: {:cont, i}, else: {:halt, acc} end)
    e = Enum.reduce_while((l + 1)..last//1, l, fn i, acc -> if blank?.(i) == here, do: {:cont, i}, else: {:halt, acc} end)
    e = if ia == "a", do: Enum.reduce_while((e + 1)..last//1, e, fn i, acc -> if blank?.(i), do: {:cont, i}, else: {:halt, acc} end), else: e
    {:range, {s, 0}, {e, 0}, :linewise}
  end

  # Where a mark is: line-wise to its line's first non-blank ('), or exactly (`).
  # An unset mark goes nowhere.
  defp mark_target(_buf, pos, _k, nil), do: {pos, :exclusive}

  defp mark_target(buf, _pos, "'", {ml, _}) do
    ml = min(ml, Buffer.line_count(buf) - 1)
    {{ml, first_non_blank(buf, ml)}, :linewise}
  end

  defp mark_target(buf, _pos, "`", {ml, mc}) do
    ml = min(ml, Buffer.line_count(buf) - 1)
    {{ml, min(mc, max(Buffer.line_length(buf, ml) - 1, 0))}, :exclusive}
  end

end
