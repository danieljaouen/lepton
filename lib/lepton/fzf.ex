defmodule Lepton.Fzf do
  @moduledoc """
  `fzf`: a fuzzy finder, as junegunn's fzf. It takes lines (from a pipe,
  or the files under the current folder), and you type to narrow them:
  `mdsrc` finds `music/david/source.mp3`, the best matches nearest the
  prompt. Enter prints what you chose.

  The query is fzf's extended search: words separated by spaces must all
  match; `'word` matches exactly, `^word` at the start, `word$` at the
  end, `!word` leaves out what has it, and `a | b` matches either. A
  word with a capital letter in it is matched with case (smart case).

  The pieces are used elsewhere too: `select/3` is the picker (the
  shell's C-r, C-t and M-c, and `/` in the Media Player and SNES), and
  `filter/3` is the matching alone.
  """

  alias Lepton.{Keys, TTY, Width}

  # -- matching --------------------------------------------------------------------------------

  @doc """
  The query's terms, as OR-groups that must all match. Options: `:exact`
  (plain words match exactly; `'` makes one fuzzy), `:case` (`:smart`,
  the default, `:sensitive` or `:insensitive`).
  """
  def parse(query, opts \\ []) do
    tokens = Regex.split(~r/(?<!\\) +/, String.trim_leading(query), trim: true) |> Enum.map(&String.replace(&1, "\\ ", " "))

    tokens
    |> Enum.reduce({[], false}, fn
      "|", {[g | gs], _} -> {[g | gs], true}
      t, {[g | gs], true} -> {[g ++ [term(t, opts)] | gs], false}
      t, {gs, _} -> {[[term(t, opts)] | gs], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp term(t, opts) do
    {inverse, t} = if String.starts_with?(t, "!") and t != "!", do: {true, String.slice(t, 1..-1//1)}, else: {false, t}

    {kind, text} =
      cond do
        String.starts_with?(t, "'") and t != "'" -> {if(opts[:exact], do: :fuzzy, else: :exact), String.slice(t, 1..-1//1)}
        String.starts_with?(t, "^") and String.ends_with?(t, "$") and String.length(t) > 2 -> {:equal, String.slice(t, 1..-2//1)}
        String.starts_with?(t, "^") and t != "^" -> {:prefix, String.slice(t, 1..-1//1)}
        String.ends_with?(t, "$") and t != "$" and not String.ends_with?(t, "\\$") -> {:suffix, String.slice(t, 0..-2//1)}
        inverse or opts[:exact] -> {:exact, t}
        true -> {:fuzzy, t}
      end

    sensitive =
      case opts[:case] || :smart do
        :sensitive -> true
        :insensitive -> false
        :smart -> text != String.downcase(text)
      end

    text = if sensitive, do: text, else: String.downcase(text)
    %{kind: kind, text: text, chars: String.codepoints(text), inverse: inverse, sensitive: sensitive}
  end

  @doc """
  Match one line against parsed terms: `{score, positions}` (byte offsets
  of the matched characters, with their lengths), or nil.
  """
  def match(text, groups, lower \\ nil) do
    lower = lower || String.downcase(text)

    Enum.reduce_while(groups, {0, []}, fn group, {score, pos} ->
      case Enum.find_value(group, &term_match(text, lower, &1)) do
        nil -> {:halt, nil}
        {s, p} -> {:cont, {score + s, p ++ pos}}
      end
    end)
  end

  defp term_match(text, lower, t) do
    hay = if t.sensitive, do: text, else: lower
    found = if t.text == "", do: {0, []}, else: find(t, hay)

    cond do
      t.inverse -> if found, do: nil, else: {0, []}
      found == nil -> nil
      true -> {s, p} = found; {s + score(bonus_text(text, hay), p), p}
    end
  end

  # (bonuses read the original's case, when it lines up with what was searched)
  defp bonus_text(text, hay), do: if(byte_size(text) == byte_size(hay), do: text, else: hay)

  defp find(%{kind: :fuzzy, chars: chars}, hay) do
    with {:ok, first} <- forward(hay, chars, 0) do
      # From the end of that match, back to the latest start: the tightest window.
      {last, l} = List.last(first)
      start = backward(hay, Enum.reverse(chars), last + l)
      {:ok, pos} = forward(hay, chars, start)
      {0, pos}
    else
      _ -> nil
    end
  end

  defp find(%{kind: :exact, text: s}, hay) do
    case :binary.match(hay, s) do
      {p, _} -> {0, run(s, p)}
      :nomatch -> nil
    end
  end

  defp find(%{kind: :prefix, text: s}, hay) do
    lead = byte_size(hay) - byte_size(String.trim_leading(hay))
    if String.starts_with?(binary_part(hay, lead, byte_size(hay) - lead), s), do: {0, run(s, lead)}
  end

  defp find(%{kind: :suffix, text: s}, hay) do
    h = String.trim_trailing(hay)
    if String.ends_with?(h, s), do: {0, run(s, byte_size(h) - byte_size(s))}
  end

  defp find(%{kind: :equal, text: s}, hay) do
    if String.trim(hay) == s, do: {0, run(s, byte_size(hay) - byte_size(String.trim_leading(hay)))}
  end

  defp run(s, at) do
    {_, pos} = Enum.reduce(String.codepoints(s), {at, []}, fn c, {o, acc} -> {o + byte_size(c), [{o, byte_size(c)} | acc]} end)
    Enum.reverse(pos)
  end

  defp forward(hay, chars, from) do
    Enum.reduce_while(chars, {:ok, from, []}, fn c, {:ok, i, acc} ->
      case :binary.match(hay, c, scope: {i, byte_size(hay) - i}) do
        {p, l} -> {:cont, {:ok, p + l, [{p, l} | acc]}}
        :nomatch -> {:halt, :nomatch}
      end
    end)
    |> case do
      {:ok, _, acc} -> {:ok, Enum.reverse(acc)}
      :nomatch -> :nomatch
    end
  end

  defp backward(hay, rchars, limit) do
    Enum.reduce(rchars, limit, fn c, lim ->
      case :binary.matches(hay, c, scope: {0, lim}) do
        [] -> lim
        ms -> ms |> List.last() |> elem(0)
      end
    end)
  end

  # fzf's scoring, roughly: each character 16, more at the start of a word
  # (after / most), runs of consecutive characters keep their bonus, gaps cost.
  defp score(text, pos) do
    {s, _, _} =
      Enum.reduce(pos, {0, nil, 0}, fn {p, l}, {s, prev_end, carry} ->
        b = bonus(text, p)

        {s2, carry} =
          cond do
            prev_end == nil -> {16 + b * 2, b}
            p == prev_end -> c = max(carry, b); {16 + max(c, 4), c}
            true -> {16 + b - 3 - min(p - prev_end - 1, 12), b}
          end

        {s + s2, p + l, carry}
      end)

    s
  end

  defp bonus(_text, 0), do: 10

  defp bonus(text, p) do
    prev = :binary.at(text, p - 1)
    cur = :binary.at(text, p)

    cond do
      prev == ?/ -> 9
      prev in ~c" _-.:,;\t" -> 8
      prev in ?a..?z and cur in ?A..?Z -> 7
      not alnum?(prev) and alnum?(cur) -> 6
      true -> 0
    end
  end

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c >= 128

  @doc """
  The lines matching `query`, best first (fzf `-f`). Options as `parse/2`,
  and `:sort` (false: in their order), `:tac` (the last line first),
  `:tiebreak` (`:length`, the default, or `:index`).
  """
  def filter(lines, query, opts \\ []) do
    items = lines |> Enum.with_index() |> Enum.map(fn {t, i} -> {i, t, String.downcase(t)} end)
    items |> matches(parse(query, opts), opts) |> Enum.map(&elem(&1, 3))
  end

  # [{key, positions, index, text, lower}], in the order shown. (No query: in their order.)
  defp matches(items, [], opts), do: items |> Enum.map(fn {i, t, l} -> {{if(opts[:tac], do: -i, else: i)}, [], i, t, l} end) |> sort(opts)

  defp matches(items, groups, opts) do
    items
    |> Enum.flat_map(fn {i, t, l} ->
      case match(t, groups, l) do
        nil -> []
        {s, p} -> [{order(opts, s, t, i), p, i, t, l}]
      end
    end)
    |> sort(opts)
  end

  defp order(opts, score, text, i) do
    i = if opts[:tac], do: -i, else: i

    cond do
      opts[:sort] == false -> {i}
      opts[:tiebreak] == :index -> {-score, i}
      true -> {-score, byte_size(text), i}
    end
  end

  defp sort(list, _opts), do: Enum.sort_by(list, &elem(&1, 0))

  # -- the picker: a state that keys change and that is drawn ---------------------------------------

  defstruct items: [], count: 0, shown: [], query: "", qpos: 0, sel: 0, offset: 0, marked: %{},
            loading: false, opts: %{}, last_click: nil, spin: 0, cached: nil

  @doc """
  A picker over `lines` (more can come with `add/2`). Options: `:query`,
  `:multi`, `:reverse` (the prompt at the top), `:prompt`, `:header`,
  `:exact`, `:case`, `:sort`, `:tac`, `:tiebreak`, `:color`, `:loading`.
  """
  def new(lines \\ [], opts \\ []) do
    opts = Map.new(opts)
    q = opts[:query] || ""
    st = %__MODULE__{opts: opts, query: q, qpos: String.length(q), loading: opts[:loading] == true}
    add(st, lines)
  end

  @doc "More lines (as they're read)."
  def add(st, []), do: st

  def add(st, lines) do
    new = lines |> Enum.with_index(st.count) |> Enum.map(fn {t, i} -> {i, t, String.downcase(t)} end)
    st = %{st | items: Enum.reverse(new, st.items), count: st.count + length(new)}
    groups = parse(st.query, kw(st))

    # (only the new lines need matching; then all in order again)
    shown = if groups == [] and !st.opts[:tac], do: st.shown ++ matches(new, [], kw(st)), else: sort(st.shown ++ matches(new, groups, kw(st)), nil)
    %{st | shown: shown, cached: nil}
  end

  @doc "All lines have been read."
  def done(st), do: %{st | loading: false}

  defp kw(st), do: Map.to_list(Map.take(st.opts, [:exact, :case, :sort, :tac, :tiebreak]))

  defp refilter(st, old_query) do
    groups = parse(st.query, kw(st))

    # Typing on at the end can only narrow the matches (unless ! or | or $ change what a word means).
    pool =
      if old_query != "" and String.starts_with?(st.query, old_query) and not String.contains?(st.query, ["!", "|", "$", "\\"]),
        do: Enum.map(st.shown, fn {_, _, i, t, l} -> {i, t, l} end),
        else: Enum.reverse(st.items)

    %{st | shown: matches(pool, groups, kw(st)), sel: 0, offset: 0}
  end

  @doc "The lines chosen: the marked ones (in the order they came), or the one selected."
  def chosen(st) do
    if map_size(st.marked) > 0 do
      st.marked |> Enum.sort() |> Enum.map(&elem(&1, 1))
    else
      case Enum.at(st.shown, st.sel) do
        nil -> []
        {_, _, _, t, _} -> [t]
      end
    end
  end

  @doc """
  A key pressed (`size` the screen's `{rows, cols}`, for the mouse; `now`
  milliseconds, for double clicks): `{:cont, st}`, `{:accept, st}` or
  `{:cancel, st}`.
  """
  def key(st, key, size \\ {24, 80}, now \\ System.monotonic_time(:millisecond)) do
    n = length(st.shown)
    multi = st.opts[:multi] == true

    case key do
      k when k in ["RET", "C-m"] -> {:accept, st}
      k when k in ["ESC", "C-c", "C-g", "C-q"] -> {:cancel, st}
      "C-d" when st.query == "" -> {:cancel, st}
      k when k in ["<up>", "C-p", "C-k"] -> {:cont, visual(st, :up, 1, n)}
      k when k in ["<down>", "C-n", "C-j"] -> {:cont, visual(st, :down, 1, n)}
      "<prior>" -> {:cont, visual(st, :up, list_height(st, size), n)}
      "<next>" -> {:cont, visual(st, :down, list_height(st, size), n)}
      "TAB" when multi -> {:cont, st |> toggle() |> step(1, n)}
      "<backtab>" when multi -> {:cont, st |> toggle() |> step(-1, n)}
      k when k in ["C-a", "<home>"] -> {:cont, %{st | qpos: 0}}
      k when k in ["C-e", "<end>"] -> {:cont, %{st | qpos: String.length(st.query)}}
      k when k in ["<left>", "C-b"] -> {:cont, %{st | qpos: max(st.qpos - 1, 0)}}
      k when k in ["<right>", "C-f"] -> {:cont, %{st | qpos: min(st.qpos + 1, String.length(st.query))}}
      k when k in ["DEL", "C-h"] -> {:cont, edit(st, fn {a, b} -> {String.slice(a, 0..-2//1), b} end)}
      k when k in ["<deletechar>", "C-d"] -> {:cont, edit(st, fn {a, b} -> {a, String.slice(b, 1..-1//1)} end)}
      "C-u" -> {:cont, edit(st, fn {_a, b} -> {"", b} end)}
      k when k in ["C-w", "M-DEL"] -> {:cont, edit(st, fn {a, b} -> {String.replace(a, ~r/\S*\s*$/u, ""), b} end)}
      {:paste, text} -> {:cont, insert(st, String.replace(text, ~r/[\r\n\t]+/, " "))}
      {:mouse, _, _, _, _, _} = m -> mouse(st, m, size, now)
      k when is_binary(k) ->
        case Keys.text(k) do
          nil -> {:cont, st}
          t -> {:cont, insert(st, t)}
        end

      _ -> {:cont, st}
    end
  end

  defp insert(st, t), do: edit(st, fn {a, b} -> {a <> t, b} end)

  defp edit(st, fun) do
    {a, b} = fun.(String.split_at(st.query, st.qpos))
    old = st.query
    st = %{st | query: a <> b, qpos: String.length(a)}
    if st.query == old, do: st, else: refilter(st, old)
  end

  # Up and down as they look: in the default layout the best match is at
  # the bottom, so up goes to the next one.
  defp visual(st, dir, k, n) do
    d = if (dir == :up) != (st.opts[:reverse] == true), do: k, else: -k
    step(st, d, n)
  end

  defp step(st, d, n), do: %{st | sel: (st.sel + d) |> min(n - 1) |> max(0)}

  defp toggle(st) do
    case Enum.at(st.shown, st.sel) do
      nil -> st
      {_, _, i, t, _} -> %{st | marked: if(Map.has_key?(st.marked, i), do: Map.delete(st.marked, i), else: Map.put(st.marked, i, t))}
    end
  end

  # A click selects, a double click (or a click on what is selected, soon after) chooses;
  # the wheel moves up and down.
  defp mouse(st, {:mouse, :press, button, _x, _row, _}, size, _now) when button in [:wheel_up, :wheel_down] do
    {:cont, visual(st, if(button == :wheel_up, do: :up, else: :down), 3, length(st.shown)) |> fit(size)}
  end

  defp mouse(st, {:mouse, :press, :left, _x, row, _}, size, now) do
    case row_item(st, row, size) do
      nil -> {:cont, st}
      i ->
        case st.last_click do
          {^i, t} when now - t <= 500 -> {:accept, %{st | sel: i, last_click: nil}}
          _ -> {:cont, %{st | sel: i, last_click: {i, now}}}
        end
    end
  end

  defp mouse(st, _m, _size, _now), do: {:cont, st}

  defp header_lines(st), do: if(st.opts[:header] in [nil, ""], do: [], else: String.split(st.opts[:header], "\n"))
  defp list_height(st, {rows, _}), do: max(rows - 2 - length(header_lines(st)), 1)

  # The item on screen row `row`, if any.
  defp row_item(st, row, {rows, _} = size) do
    st = fit(st, size)
    h = list_height(st, size)
    k = if st.opts[:reverse], do: row - 2 - length(header_lines(st)), else: h - 1 - row
    i = st.offset + k
    if k >= 0 and k < h and i < length(st.shown) and row < rows, do: i
  end

  # The selection kept in view.
  defp fit(st, size) do
    h = list_height(st, size)

    offset =
      cond do
        st.sel < st.offset -> st.sel
        st.sel >= st.offset + h -> st.sel - h + 1
        true -> st.offset
      end

    %{st | offset: max(offset, 0)}
  end

  @doc """
  The screen: `{lines, {cursor_row, cursor_col}, st}` for `{rows, cols}`
  (the cursor on the query, counted from 0).
  """
  def render(st, {rows, cols} = size) do
    st = fit(st, size)
    h = list_height(st, size)
    c = palette(st.opts[:color] == true)
    prompt = st.opts[:prompt] || "> "

    items =
      st.shown
      |> Enum.drop(st.offset)
      |> Enum.take(h)
      |> Enum.with_index(st.offset)
      |> Enum.map(fn {{_, pos, i, t, _}, k} -> item_line(t, pos, k == st.sel, Map.has_key?(st.marked, i), cols, c) end)

    blank = List.duplicate("", h - length(items))
    spinner = if st.loading, do: Enum.at(~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏), rem(st.spin, 10)) <> " ", else: "  "
    marked = if map_size(st.marked) > 0, do: " (#{map_size(st.marked)})", else: ""
    info = c.spin <> spinner <> c.reset <> c.info <> "#{length(st.shown)}/#{st.count}#{marked}" <> c.reset
    {query, _} = Width.slice(st.query, 0, max(cols - Width.string(prompt) - 1, 1))
    prompt_line = c.prompt <> prompt <> c.reset <> query
    headers = Enum.map(header_lines(st), &(c.header <> "  " <> elem(Width.slice(&1, 0, cols - 2), 0) <> c.reset))
    cursor_col = Width.string(prompt) + Width.string(String.slice(st.query, 0, st.qpos))

    {lines, cursor_row} =
      if st.opts[:reverse] do
        {[prompt_line, info | headers] ++ items ++ blank, 0}
      else
        {blank ++ Enum.reverse(items) ++ headers ++ [info, prompt_line], rows - 1}
      end

    {Enum.take(lines, rows), {cursor_row, min(cursor_col, cols - 1)}, st}
  end

  defp palette(true) do
    %{hl: "\e[38;5;108m", hl_cur: "\e[38;5;151m", cur: "\e[48;5;236m\e[1m", pointer: "\e[38;5;161m", marker: "\e[38;5;168m",
      info: "\e[38;5;144m", prompt: "\e[38;5;110m", header: "\e[38;5;109m", spin: "\e[38;5;161m", reset: "\e[0m"}
  end

  defp palette(false), do: %{hl: "", hl_cur: "", cur: "\e[1m", pointer: "", marker: "", info: "", prompt: "", header: "", spin: "", reset: "\e[0m"}

  defp item_line(text, pos, current?, marked?, cols, c) do
    at = MapSet.new(pos, &elem(&1, 0))
    room = max(cols - 2, 1)
    base = if current?, do: c.cur, else: ""
    graphemes = Enum.map(String.graphemes(text), &{&1, clean(&1)})
    long = Enum.sum(Enum.map(graphemes, fn {_, s} -> Width.string(s) end)) > room
    limit = if long, do: room - 1, else: room

    {body, _, _} =
      Enum.reduce_while(graphemes, {[], 0, 0}, fn {g, shown}, {acc, off, w} ->
        gw = Width.string(shown)

        cond do
          w + gw > limit -> {:halt, {acc, off, w}}
          MapSet.member?(at, off) -> {:cont, {[base, (if current?, do: c.hl_cur, else: c.hl), shown, c.reset, base | acc], off + byte_size(g), w + gw}}
          true -> {:cont, {[shown | acc], off + byte_size(g), w + gw}}
        end
      end)

    body = if long, do: ["…" | body], else: body

    pointer = if current?, do: c.pointer <> ">" <> c.reset <> base, else: base <> " "
    marker = if marked?, do: c.marker <> ">" <> c.reset <> base, else: " "
    IO.iodata_to_binary([base, pointer, marker, Enum.reverse(body), c.reset])
  end

  defp clean(g) do
    cond do
      String.contains?(g, ["\n", "\r"]) -> "↵"
      g == "\t" -> " "
      match?(<<c>> when c < 32 or c == 127, g) -> "?"
      true -> g
    end
  end

  # -- on the terminal -----------------------------------------------------------------------

  @doc """
  Choose from `source` on the terminal: a list of lines, `{:lines, dev}`
  (read as they come), `{:walk, dir, opts}` (the files under `dir`, as
  paths from it: `:dirs` true for folders instead, `:also` for both, `:hidden` false to leave
  out dot files, `:only` a function of the name), or `{:command, src}` (a
  shell command's output). Options: as `new/2`, and `:screen` (`:own`,
  the default, takes the alternate screen; `:shared` draws on the one a
  full-screen program already has), `:select_1`, `:exit_0`.

  `{:ok, lines, query}`, `{:none, query}` (Enter with nothing matching,
  or nothing at all with `:exit_0`), or `:cancel`.
  """
  def select(ctx, source, opts \\ []) do
    tty = ctx.tty
    opts = Keyword.put_new(opts, :color, Lepton.Style.color?(ctx))

    case source do
      lines when is_list(lines) ->
        st = new(lines, opts)

        cond do
          opts[:select_1] && length(st.shown) == 1 -> {:ok, chosen(st), st.query}
          opts[:exit_0] && st.shown == [] -> {:none, st.query}
          true -> on_screen(tty, st, nil, opts)
        end

      _ ->
        {pid, ref} = loader(ctx, source)
        on_screen(tty, new([], Keyword.put(opts, :loading, true)), {pid, ref}, opts)
    end
  end

  defp on_screen(tty, st, loader, opts) do
    own = opts[:screen] != :shared
    mode = TTY.mode(tty)

    if own do
      TTY.set_mode(tty, :raw)
      TTY.write(tty, "\e[?1049h\e[?1000h\e[?1006h")
    end

    try do
      loop(tty, st, loader, opts)
    after
      if loader, do: stop_loader(loader)
      TTY.write(tty, if(own, do: "\e[?1000l\e[?1006l\e[0m\e[?25h\e[?1049l", else: "\e[0m\e[?25l"))
      if own, do: TTY.set_mode(tty, mode)
    end
  end

  defp loop(tty, st, loader, opts) do
    st = draw(tty, st)
    ref = make_ref()
    GenServer.cast(tty, {:want_key, self(), ref})
    wait(tty, st, loader, opts, ref)
  end

  defp wait(tty, st, loader, opts, ref) do
    lref = if loader, do: elem(loader, 1)

    receive do
      {:key, ^ref, key} ->
        case key(st, key, TTY.size(tty)) do
          {:cont, st} -> loop(tty, st, loader, opts)
          {:accept, st} -> if(chosen(st) == [], do: {:none, st.query}, else: {:ok, chosen(st), st.query})
          {:cancel, _} -> :cancel
        end

      {:fzf_lines, ^lref, lines} ->
        st = add(st, lines ++ more_lines(lref))
        wait(tty, draw(tty, st), loader, opts, ref)

      {:fzf_done, ^lref} ->
        st = done(add(st, more_lines(lref)))

        cond do
          opts[:select_1] && length(st.shown) == 1 -> cancel_key(tty, ref); {:ok, chosen(st), st.query}
          opts[:exit_0] && st.shown == [] -> cancel_key(tty, ref); {:none, st.query}
          true -> wait(tty, draw(tty, st), loader, opts, ref)
        end
    after
      if(st.loading, do: 100, else: :infinity) ->
        wait(tty, draw(tty, %{st | spin: st.spin + 1}), loader, opts, ref)
    end
  end

  defp more_lines(lref) do
    receive do
      {:fzf_lines, ^lref, lines} -> lines ++ more_lines(lref)
    after
      0 -> []
    end
  end

  defp cancel_key(tty, ref) do
    GenServer.cast(tty, {:cancel_key, ref})

    receive do
      {:key, ^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp draw(tty, st) do
    {rows, cols} = TTY.size(tty)
    {lines, {r, c}, st} = render(st, {rows, cols})
    out = lines |> Enum.with_index() |> Enum.map(fn {l, i} -> ["\e[#{i + 1};1H", l, "\e[0m\e[K"] end)
    TTY.write(tty, ["\e[?25l", out, "\e[#{r + 1};#{c + 1}H\e[?25h"])
    st
  end

  # -- reading what to choose from ------------------------------------------------------------------

  defp loader(ctx, source) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        emit = fn lines -> if lines != [], do: send(parent, {:fzf_lines, ref, lines}) end

        try do
          case source do
            {:lines, dev} -> read_lines(dev, emit, [])
            {:walk, dir, wopts} -> walk(dir, "", Map.new(wopts), emit, []) |> emit.()
            {:command, src} -> {out, _} = Lepton.Shell.run_capture(src, cwd: ctx.cwd, env: ctx.env); emit.(String.split(out, "\n", trim: true))
          end
        rescue
          _ -> :ok
        end

        send(parent, {:fzf_done, ref})
      end)

    {pid, ref}
  end

  defp stop_loader({pid, ref}) do
    Process.exit(pid, :kill)
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:fzf_lines, ^ref, _} -> flush(ref)
      {:fzf_done, ^ref} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp read_lines(dev, emit, acc) do
    case Lepton.IO.read_line(dev) do
      :eof -> emit.(Enum.reverse(acc))
      {:error, _} -> emit.(Enum.reverse(acc))
      line ->
        acc = [String.trim_trailing(line, "\n") | acc]
        if length(acc) >= 500, do: (emit.(Enum.reverse(acc)); read_lines(dev, emit, [])), else: read_lines(dev, emit, acc)
    end
  end

  @skip ~w(.git node_modules)
  @kernel ~w(/proc /sys /dev)

  @doc false
  # The files (or folders) under `root`, as paths from it, sent along in batches; returns the rest.
  def walk(root, rel, wopts, emit, acc) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(Enum.sort(names), acc, fn name, acc ->
          path = Path.join(dir, name)
          relp = if rel == "", do: name, else: rel <> "/" <> name
          hidden? = String.starts_with?(name, ".")

          info = if hidden? and wopts[:hidden] == false, do: :skip, else: :file.read_link_info(String.to_charlist(path))

          case info do
            {:ok, info} when elem(info, 2) == :directory ->
              if name in @skip or path in @kernel do
                acc
              else
                acc = if wopts[:dirs] in [true, :also], do: [relp | acc], else: acc
                acc = if length(acc) >= 500, do: (emit.(Enum.reverse(acc)); []), else: acc
                walk(root, relp, wopts, emit, acc)
              end

            {:ok, info} when elem(info, 2) in [:regular, :symlink] ->
              if wopts[:dirs] != true and (wopts[:only] == nil or wopts[:only].(name)) do
                acc = [relp | acc]
                if length(acc) >= 500, do: (emit.(Enum.reverse(acc)); []), else: acc
              else
                acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        acc
    end
    |> then(fn acc -> if rel == "", do: Enum.reverse(acc), else: acc end)
  end

  # -- the command ----------------------------------------------------------------------------

  @doc "`fzf ARGS`: choose on the terminal (or `-f`: filter), printing the lines chosen."
  def cli(args, ctx) do
    defaults = OptionParser.split(ctx.env["FZF_DEFAULT_OPTS"] || "")

    case options(defaults ++ args, %{}) do
      {:error, msg} ->
        Lepton.IO.err(ctx, "fzf: " <> msg)
        2

      {:ok, o} ->
        source =
          cond do
            ctx.stdin != nil and not TTY.tty?(ctx.stdin) -> {:lines, ctx.stdin}
            (cmd = ctx.env["FZF_DEFAULT_COMMAND"]) not in [nil, ""] -> {:command, cmd}
            true -> {:walk, ctx.cwd, []}
          end

        if o[:filter] do
          filter_mode(ctx, source, o)
        else
          interactive(ctx, source, o)
        end
    end
  end

  defp filter_mode(ctx, source, o) do
    lines =
      case source do
        {:lines, dev} -> dev |> Lepton.IO.lines() |> Enum.map(&String.trim_trailing(&1, "\n"))
        {:walk, dir, w} -> collect_walk(dir, w)
        {:command, src} -> {out, _} = Lepton.Shell.run_capture(src, cwd: ctx.cwd, env: ctx.env); String.split(out, "\n", trim: true)
      end

    found = filter(lines, o[:filter], Map.to_list(o))
    if o[:print_query], do: Lepton.IO.write(ctx, [o[:filter], o[:sep] || "\n"])
    for l <- found, do: Lepton.IO.write(ctx, [l, o[:sep] || "\n"])
    if found == [], do: 1, else: 0
  end

  # (walk/5 sends batches to emit; here they're gathered instead)
  defp collect_walk(dir, w) do
    me = self()
    ref = make_ref()
    rest = walk(dir, "", Map.new(w), fn lines -> send(me, {ref, lines}) end, [])
    gather(ref, []) ++ rest
  end

  defp gather(ref, acc) do
    receive do
      {^ref, lines} -> gather(ref, acc ++ lines)
    after
      0 -> acc
    end
  end

  defp interactive(ctx, source, o) do
    if ctx.tty && is_pid(ctx.tty) && Process.alive?(ctx.tty) do
      case select(ctx, source, Map.to_list(o)) do
        {:ok, lines, q} ->
          if o[:print_query], do: Lepton.IO.write(ctx, [q, o[:sep] || "\n"])
          for l <- lines, do: Lepton.IO.write(ctx, [l, o[:sep] || "\n"])
          0

        {:none, q} ->
          if o[:print_query], do: Lepton.IO.write(ctx, [q, o[:sep] || "\n"])
          1

        :cancel ->
          130
      end
    else
      Lepton.IO.err(ctx, "fzf: no terminal to choose on (-f QUERY filters without one)")
      2
    end
  end

  @doc false
  def options([], o), do: {:ok, o}

  def options([a | rest], o) do
    {a, inline} =
      case String.split(a, "=", parts: 2) do
        ["--" <> _ = name, v] -> {name, v}
        _ -> {a, nil}
      end

    value = fn ->
      case {inline, rest} do
        {nil, [v | r]} -> {v, r}
        {nil, []} -> :missing
        {v, r} -> {v, r}
      end
    end

    with_value = fn key, conv ->
      case value.() do
        :missing -> {:error, "#{a} needs a value"}
        {v, r} -> options(r, Map.put(o, key, conv.(v)))
      end
    end

    case a do
      x when x in ["-m", "--multi"] -> options(rest, Map.put(o, :multi, true))
      x when x in ["+m", "--no-multi"] -> options(rest, Map.put(o, :multi, false))
      x when x in ["-e", "--exact"] -> options(rest, Map.put(o, :exact, true))
      "+e" -> options(rest, Map.put(o, :exact, false))
      "-i" -> options(rest, Map.put(o, :case, :insensitive))
      "+i" -> options(rest, Map.put(o, :case, :sensitive))
      "--smart-case" -> options(rest, Map.put(o, :case, :smart))
      x when x in ["+s", "--no-sort"] -> options(rest, Map.put(o, :sort, false))
      "--tac" -> options(rest, Map.put(o, :tac, true))
      "--reverse" -> options(rest, Map.put(o, :reverse, true))
      "--layout" -> with_value.(:reverse, &(&1 in ["reverse", "reverse-list"]))
      x when x in ["-1", "--select-1"] -> options(rest, Map.put(o, :select_1, true))
      x when x in ["-0", "--exit-0"] -> options(rest, Map.put(o, :exit_0, true))
      "--print-query" -> options(rest, Map.put(o, :print_query, true))
      "--print0" -> options(rest, Map.put(o, :sep, <<0>>))
      x when x in ["-q", "--query"] -> with_value.(:query, & &1)
      x when x in ["-f", "--filter"] -> with_value.(:filter, & &1)
      "--prompt" -> with_value.(:prompt, & &1)
      "--header" -> with_value.(:header, & &1)
      "--tiebreak" -> with_value.(:tiebreak, &if(String.starts_with?(&1, "index"), do: :index, else: :length))
      "--scheme" -> with_value.(:tiebreak, &if(&1 == "history", do: :index, else: :length))
      "-q" <> q when q != "" -> options(rest, Map.put(o, :query, q))
      "-f" <> q when q != "" -> options(rest, Map.put(o, :filter, q))
      # (accepted, so that settings written for fzf work; they change nothing here)
      x when x in ["--ansi", "--no-mouse", "--cycle", "--no-hscroll", "--border", "--inline-info", "--no-bold", "--black", "--sync"] -> options(rest, o)
      x when x in ["--height", "--color", "--info", "--bind", "--preview", "--preview-window", "--margin", "--padding", "--pointer", "--marker", "--min-height"] ->
        case {inline, rest} do
          {nil, [_ | r]} -> options(r, o)
          {nil, []} -> options([], o)
          _ -> options(rest, o)
        end

      "-h" -> {:error, "usage: fzf [-m] [-q QUERY] [-e] [-i | +i] [--reverse] [--prompt STR] [--header STR] [--tac] [--no-sort] [-1] [-0] [--print-query] [-f QUERY]"}
      "--help" -> options(["-h"], o)
      other -> {:error, "unknown option: #{other}"}
    end
  end
end
