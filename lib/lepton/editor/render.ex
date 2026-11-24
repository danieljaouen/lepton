defmodule Lepton.Editor.Render do
  @moduledoc """
  Draws the editor: windows with relative line numbers and the
  fill-column indicator, a Spacemacs-style mode line per window, the echo
  area / minibuffer, and popups (which-key, helm candidates, company).
  Frames are lists of row strings; `diff/2` emits only changed rows.
  """

  alias Lepton.Editor
  alias Lepton.Editor.{Buffer, Fold, Keymap, Syntax}

  @state_colors %{normal: "48;5;214", insert: "48;5;112", visual: "48;5;248", visual_line: "48;5;248", visual_block: "48;5;248", replace: "48;5;167", special: "48;5;141"}

  def frame(st) do
    {rows, cols} = st.size
    rects = Editor.rects(st)
    canvas = for _ <- 1..rows, do: nil

    {canvas, cursor} =
      Enum.reduce(rects, {canvas, nil}, fn {id, rect}, {canvas, cursor} ->
        {rows_drawn, cur} = draw_window(st, id, rect)
        canvas = place(canvas, rect, rows_drawn)
        {canvas, if(id == st.active, do: cur, else: cursor)}
      end)

    canvas = draw_vertical_borders(canvas, rects, st)
    {bottom, mb_cursor} = minibuffer_line(st, cols)
    canvas = List.replace_at(canvas, rows - 1, {:line, bottom})
    {canvas, popup_cursor} = popups(st, canvas, rows, cols)

    rows_out =
      canvas
      |> Enum.map(fn
        nil -> String.duplicate(" ", cols)
        {:line, s} -> s
        {:segments, segs} -> segs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join(&elem(&1, 1))
      end)

    {rows_out, mb_cursor || popup_cursor || cursor}
  end

  # Each window contributes segments to rows; segments are {col, string}.
  defp place(canvas, {r, c, _h, _w}, rows_drawn) do
    Enum.reduce(Enum.with_index(rows_drawn), canvas, fn {text, i}, canvas ->
      List.update_at(canvas, r + i, fn
        {:segments, segs} -> {:segments, [{c, text} | segs]}
        _ -> {:segments, [{c, text}]}
      end)
    end)
  end

  defp draw_vertical_borders(canvas, rects, st) do
    Enum.reduce(rects, canvas, fn {_id, {r, c, h, w}}, canvas ->
      {_, cols} = st.size

      if c + w < cols do
        Enum.reduce(r..(r + h - 1), canvas, fn row, canvas ->
          List.update_at(canvas, row, fn
            {:segments, segs} -> {:segments, [{c + w, "\e[38;5;240m│\e[0m"} | segs]}
            other -> other
          end)
        end)
      else
        canvas
      end
    end)
  end

  defp draw_window(st, id, {r, c, h, w}) do
    win = st.windows[id]
    b = st.buffers[win.buf]
    active = id == st.active
    gutter = gutter(st, b)
    text_h = h - 1
    text_w = max(w - gutter, 1)
    {cl, cc} = win.cursor
    relative = st.vars["display-line-numbers-type"] == "relative"
    fci = if st.vars["fill-column-indicator"], do: st.vars["display-fill-column-indicator-column"], else: nil
    hl = highlight_spans(st, b, id)

    # The buffer lines shown, top to bottom: folded subtrees (Org) are
    # skipped, and their heading ends in an ellipsis.
    {shown, folded} =
      if MapSet.size(b.folds) == 0 do
        {Enum.to_list(win.top..(win.top + text_h - 1)), MapSet.new()}
      else
        {Fold.visible_lines(b, win.top, text_h), Fold.folded_headings(b)}
      end

    row_of = shown |> Enum.with_index() |> Map.new()
    cl_row = Map.get(row_of, cl)

    lines =
      for i <- 0..(text_h - 1) do
        n = Enum.at(shown, i) || Buffer.line_count(b)

        if n < Buffer.line_count(b) do
          num =
            cond do
              gutter == 0 -> ""
              relative and n != cl -> "\e[38;5;240m" <> String.pad_leading(to_string(if(cl_row, do: abs(i - cl_row), else: abs(n - cl))), gutter - 1) <> " \e[0m"
              true -> "\e[38;5;#{if n == cl, do: "214", else: "240"}m" <> String.pad_leading(to_string(n + 1), gutter - 1) <> " \e[0m"
            end

          line = Buffer.line(b, n) |> expand_tabs()
          # (by columns: Chinese, Japanese and Korean characters take two)
          line = if MapSet.member?(folded, n), do: line <> " ...", else: line
          {vis, len} = visible(line, win.left, text_w)
          body = Syntax.highlight(vis, b.mode, Map.get(hl, n), win.left, st.vars["show-whitespace"])
          pad_len = text_w - len
          pad = fill(pad_len, len + win.left, fci, win.left)
          bg = if n == cl and active and b.kind not in [:help], do: "\e[48;5;236m", else: "\e[48;5;235m"
          bg <> num <> bg <> body <> bg <> pad <> "\e[0m"
        else
          tilde = if gutter > 0, do: "\e[38;5;240m" <> String.pad_leading("~", gutter - 1) <> " ", else: ""
          "\e[48;5;235m" <> tilde <> String.duplicate(" ", text_w) <> "\e[0m"
        end
      end

    mode_line = mode_line(st, id, b, active, w)
    cursor_row = cl_row || cl - win.top
    cursor_col = gutter + Editor.display_col(Buffer.line(b, cl), cc) - win.left
    {lines ++ [mode_line], {r + cursor_row, c + cursor_col}}
  end

  @doc "How many columns the line numbers take in a window showing `b`."
  def gutter(st, b) do
    if st.vars["line-numbers"] and b.kind in [:file, :scratch, :commit] do
      digits = b |> Buffer.line_count() |> Integer.to_string() |> String.length()
      max(digits, 3) + 1
    else
      0
    end
  end

  defp visible(line, left, width) do
    if Lepton.Width.string(line) == String.length(line) do
      vis = String.slice(line, left, width)
      {vis, String.length(vis)}
    else
      Lepton.Width.slice(line, left, width)
    end
  end

  defp expand_tabs(line) do
    if String.contains?(line, "\t") do
      line |> String.graphemes() |> Enum.reduce({"", 0}, fn
        "\t", {acc, col} -> n = 8 - rem(col, 8); {acc <> String.duplicate(" ", n), col + n}
        g, {acc, col} -> {acc <> g, col + 1}
      end) |> elem(0)
    else
      line
    end
  end

  # Padding after the text, with the fill-column indicator (editing.el:
  # display-fill-column-indicator-column 101) drawn as a dim bar.
  defp fill(n, _start, _fci, _left) when n <= 0, do: ""

  defp fill(n, start, fci, left) do
    col = if fci, do: fci - start + left, else: nil

    if col != nil and col >= 0 and col < n do
      String.duplicate(" ", col) <> "\e[38;5;238m│\e[39m" <> String.duplicate(" ", n - col - 1)
    else
      String.duplicate(" ", n)
    end
  end

  # Visual selection and search-in-progress highlights per line: %{line => [{from, to}]}
  defp highlight_spans(st, b, id) do
    cond do
      # A block: the same display columns on each of its lines (to each one's end after $).
      id == st.active and st.mode == :visual_block and st.visual_start ->
        blk = Editor.block_columns(st)

        for l <- blk.fl..blk.tl, into: %{} do
          width = Editor.display_col(Buffer.line(b, l), Buffer.line_length(b, l))
          {l, [if(blk.eol, do: {blk.left, max(width, blk.left + 1)}, else: {blk.left, blk.right})]}
        end

      id == st.active and st.mode in [:visual, :visual_line] and st.visual_start ->
        {a, z} = Enum.min_max([st.visual_start, st.windows[id].cursor])
        {al, ac} = a
        {zl, zc} = z

        for l <- al..zl, into: %{} do
          len = Buffer.line_length(b, l)

          span =
            if st.mode == :visual_line,
              do: {0, max(len, 1)},
              else: {if(l == al, do: ac, else: 0), if(l == zl, do: zc + 1, else: max(len, 1))}

          {l, [span]}
        end

      id == st.active and match?(%{kind: {:search, _}, text: t} when t != "", st.minibuffer) ->
        case Regex.compile(st.minibuffer.text) do
          {:ok, re} ->
            for {line, l} <- Enum.with_index(Buffer.lines(b)), Regex.match?(re, line), into: %{} do
              spans = for [{s, len}] <- Regex.scan(re, line, return: :index) do
                start = String.length(binary_part(line, 0, s))
                {start, start + String.length(binary_part(line, s, len))}
              end

              {l, spans}
            end

          _ ->
            %{}
        end

      true ->
        %{}
    end
  end

  defp mode_line(st, id, b, active, width) do
    win = st.windows[id]
    {l, c} = win.cursor
    number = Enum.find_index(leaves(st.layout), &(&1 == id)) |> then(&((&1 || 0) + 1))

    state =
      cond do
        not active -> nil
        b.kind in [:magit, :dired, :help, :list, :log] -> :special
        true -> st.mode
      end

    state_seg =
      case state do
        nil -> "\e[48;5;238;38;5;250m #{number} \e[0m"
        s -> "\e[#{@state_colors[s] || "48;5;214"};38;5;232;1m #{number} \e[0m"
      end

    total = Buffer.line_count(b)
    pct = cond do
      win.top == 0 -> "Top"
      win.top + 20 >= total -> "Bot"
      true -> "#{div(win.top * 100, max(total, 1))}%"
    end

    modified = if b.modified, do: "*", else: if(b.read_only, do: "%", else: "-")
    # evil's "Recording @q"
    rec = if active && st.macro_rec, do: "[@#{elem(st.macro_rec, 0)}] ", else: ""
    name = "#{rec}#{modified} #{b.name}"
    branch = if b.path, do: Lepton.Git.branch(Path.dirname(b.path)), else: nil
    right = "#{b.mode}  #{if branch, do: " " <> branch <> "  ", else: ""}#{l + 1}:#{c}  #{pct} "
    bg = if active, do: "48;5;237;38;5;252", else: "48;5;235;38;5;244"
    visible = 3 + String.length(to_string(number)) + 1 + String.length(name) + String.length(right) + 2
    pad = String.duplicate(" ", max(width - visible, 1))
    state_seg <> "\e[#{bg}m " <> "\e[1m" <> name <> "\e[22m" <> pad <> right <> "\e[0m"
  end

  defp leaves({:leaf, id}), do: [id]
  defp leaves({:split, _, ch}), do: Enum.flat_map(ch, &leaves/1)

  defp minibuffer_line(st, cols) do
    case {st.minibuffer, st.message} do
      {%{prompt: p, text: t, pos: pos}, _} ->
        line = p <> t
        {"\e[0m" <> String.pad_trailing(String.slice(line, 0, cols), cols), {elem(st.size, 0) - 1, min(String.length(p) + pos, cols - 1)}}

      {nil, {:which_key, _}} ->
        {String.duplicate(" ", cols), nil}

      {nil, nil} ->
        prefix = pending_text(st)
        {String.pad_trailing(prefix, cols), nil}

      {nil, text} when is_binary(text) ->
        color = if st.message_error, do: "\e[38;5;197m", else: ""
        {color <> String.pad_trailing(String.slice(text, 0, cols), cols) <> "\e[0m", nil}
    end
  end

  defp pending_text(st) do
    parts = (if st.count, do: [to_string(st.count)], else: []) ++ st.pending
    if parts == [], do: "", else: Enum.join(parts, " ") <> "-"
  end

  # -- popups ---------------------------------------------------------------------------

  defp popups(st, canvas, rows, cols) do
    cond do
      st.minibuffer && st.minibuffer.candidates != [] -> helm_popup(st, canvas, rows, cols)
      match?({:which_key, _}, st.message) or (st.pending != [] and hd(st.pending) == "SPC") -> which_key(st, canvas, rows, cols)
      st.completion -> {company(st, canvas), nil}
      true -> {canvas, nil}
    end
  end

  # helm-style candidate list above the minibuffer
  defp helm_popup(st, canvas, rows, cols) do
    mb = st.minibuffer
    max_rows = min(12, rows - 3)
    sel = mb.selected
    start = max(sel - max_rows + 1, 0)
    shown = Enum.slice(mb.candidates, start, max_rows)
    header = "\e[48;5;24;38;5;231;1m" <> String.pad_trailing(" #{helm_title(mb.kind)} (#{length(mb.candidates)})", cols) <> "\e[0m"

    lines =
      shown
      |> Enum.with_index(start)
      |> Enum.map(fn {cand, i} ->
        text = String.pad_trailing(" " <> String.slice(cand, 0, cols - 2), cols)
        if i == sel, do: "\e[48;5;59;38;5;231;1m" <> text <> "\e[0m", else: "\e[48;5;235;38;5;252m" <> text <> "\e[0m"
      end)

    block = [header | lines]
    first = rows - 1 - length(block)

    canvas =
      block
      |> Enum.with_index(first)
      |> Enum.reduce(canvas, fn {line, r}, cv -> List.replace_at(cv, r, {:line, line}) end)

    {canvas, nil}
  end

  defp helm_title(:find_file), do: "Find Files"
  defp helm_title(:switch_buffer), do: "Buffers"
  defp helm_title(:project_file), do: "Projectile files"
  defp helm_title(:mx), do: "Emacs Commands"
  defp helm_title(:swoop), do: "Swoop"
  defp helm_title(other), do: inspect(other)

  # which-key: what can follow the keys typed so far
  defp which_key(st, canvas, rows, cols) do
    prefix = case st.message do
      {:which_key, p} when p != [] -> p
      _ -> st.pending
    end

    table = cond do
      st.mode in [:visual, :visual_line, :visual_block] -> st.km.visual
      true -> st.km.normal
    end

    items = Keymap.continuations(st.km, table, prefix)

    if items == [] do
      {canvas, nil}
    else
      cell_w = 28
      per_row = max(div(cols, cell_w), 1)
      cells = Enum.map(items, fn {k, label} ->
        key = "\e[38;5;214m" <> String.pad_leading(k, 4) <> "\e[38;5;244m → "
        lab = if String.starts_with?(label, "+"), do: "\e[38;5;81m" <> label, else: "\e[38;5;252m" <> label
        {key <> String.slice(lab, 0, cell_w + 10) <> "\e[0m", String.length(k |> String.pad_leading(4)) + 3 + String.length(String.slice(label, 0, cell_w))}
      end)

      lines =
        cells
        |> Enum.chunk_every(per_row)
        |> Enum.map(fn row ->
          body = Enum.map_join(row, fn {s, len} -> s <> "\e[48;5;234m" <> String.duplicate(" ", max(cell_w - len, 1)) end)
          used = row |> Enum.map(fn {_, len} -> max(cell_w, len + 1) end) |> Enum.sum()
          "\e[48;5;234m" <> body <> "\e[48;5;234m" <> String.duplicate(" ", max(cols - used, 0)) <> "\e[0m"
        end)
        |> Enum.take(rows - 3)

      title = "\e[48;5;234;38;5;244m " <> Enum.join(prefix, " ") <> "-" <> String.duplicate(" ", max(cols - String.length(Enum.join(prefix, " ")) - 2, 0)) <> "\e[0m"
      block = [title | lines]
      first = rows - 1 - length(block)
      canvas = block |> Enum.with_index(first) |> Enum.reduce(canvas, fn {line, r}, cv -> List.replace_at(cv, r, {:line, line}) end)
      {canvas, nil}
    end
  end

  # company-mode popup under the cursor line (drawn at the bottom for simplicity)
  defp company(st, canvas) do
    %{items: items, selected: sel} = st.completion
    {rows, cols} = st.size

    lines =
      items
      |> Enum.with_index()
      |> Enum.map(fn {w, i} ->
        text = String.pad_trailing(" " <> w, 24) |> String.slice(0, cols)
        if i == sel, do: "\e[48;5;24;38;5;231m" <> text <> "\e[0m", else: "\e[48;5;238;38;5;252m" <> text <> "\e[0m"
      end)

    first = rows - 2 - length(lines)

    pad = String.duplicate(" ", max(cols - 24, 0))

    lines
    |> Enum.with_index(first)
    |> Enum.reduce(canvas, fn {line, r}, cv -> List.replace_at(cv, r, {:line, line <> pad}) end)
  end

  # -- output --------------------------------------------------------------------------------

  def diff(old, new) do
    new
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      if Enum.at(old, i) == row, do: [], else: ["\e[#{i + 1};1H", row, "\e[0m"]
    end)
  end

  def describe_bindings(st) do
    user = st.km.user

    header = [
      "Key bindings (Spacemacs defaults + your dotfiles)",
      "",
      "From your Spacemacs config (#{Enum.join(st.emacs.sources, ", ")}):"
    ]

    user_lines =
      for {map, key, cmd} <- user do
        mark = if Keymap.supported?(cmd), do: "", else: "   [not supported in le]"
        "  #{String.pad_trailing(map, 34)} #{String.pad_trailing(key, 8)} #{cmd || "<unbound>"}#{mark}"
      end

    vars = ["", "Variables:"] ++ Enum.map(Enum.sort(st.emacs.vars), fn {k, v} -> "  #{k} = #{inspect(v)}" end)

    leader =
      ["", "Leader (SPC) bindings:"] ++
        (st.km.normal
         |> Enum.filter(fn {k, _} -> hd(k) == "SPC" end)
         |> Enum.sort()
         |> Enum.map(fn {k, a} -> "  #{String.pad_trailing(Enum.join(k, " "), 12)} #{Map.get(st.km.labels, k) || Keymap.action_label(a)}" end))

    Enum.join(header ++ user_lines ++ vars ++ leader, "\n")
  end
end
