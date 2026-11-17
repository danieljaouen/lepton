defmodule Lepton.Mux.CopyMode do
  @moduledoc """
  tmux copy mode over a pane's scrollback + screen, driven by the
  `copy-mode-vi` key table (the user sets `mode-keys vi` and binds `v`
  begin-selection, `y` copy-selection, `Y` copy-pipe-and-cancel).
  """

  alias Lepton.{Clipboard, Screen}
  alias Lepton.Mux.Client

  def enter(st, page_up?) do
    snap = st.snapshot
    %{rect: {_x, _y, w, h}, screen: scr} = snap.panes[snap.active_pane]
    sb = scr.scrollback |> Enum.reverse() |> Enum.map(fn cells -> cells |> Enum.map_join(&elem(&1, 0)) |> String.trim_trailing() end)
    rows = for y <- 0..(scr.rows - 1), do: Screen.row_text(scr, y)
    lines = sb ++ rows
    top = length(sb)
    c = %{lines: lines, top: top, cy: top + scr.y, cx: scr.x, height: h, width: w, sel: nil, search: nil}
    c = if page_up?, do: move(c, :page_up), else: c
    %{st | mode: {:copy, c}}
  end

  def key(st, c, key) do
    table = st.cfg.tables["copy-mode-vi"] || %{}

    case table[key] do
      nil -> st
      %{cmd: cmd} -> Client.exec_string(%{st | mode: {:copy, c}}, cmd)
    end
  end

  @doc "Handle `send-keys -X ACTION [ARG]` while in copy mode."
  def x(st, c, [action | args]) do
    case action do
      "cancel" -> %{st | mode: :normal}
      "begin-selection" -> %{st | mode: {:copy, %{c | sel: {:char, {c.cy, c.cx}}}}}
      "select-line" -> %{st | mode: {:copy, %{c | sel: {:line, c.cy}}}}
      "clear-selection" -> %{st | mode: {:copy, %{c | sel: nil}}}
      "rectangle-toggle" -> st
      "copy-selection" -> copy(c); %{st | mode: {:copy, %{c | sel: nil}}}
      "copy-selection-and-cancel" -> copy(c); %{st | mode: :normal}
      "copy-pipe" -> pipe(st, c, args); %{st | mode: {:copy, %{c | sel: nil}}}
      "copy-pipe-and-cancel" -> pipe(st, c, args); %{st | mode: :normal}
      "search-forward" -> search(st, %{c | search: {List.first(args) || "", 1}}, 1)
      "search-backward" -> search(st, %{c | search: {List.first(args) || "", -1}}, -1)
      "search-again" -> search(st, c, 1)
      "search-reverse" -> search(st, c, -1)
      other -> %{st | mode: {:copy, move(c, String.to_atom(String.replace(other, "-", "_")))}}
    end
  end

  def x(st, _c, []), do: st

  defp move(c, action) do
    last = length(c.lines) - 1
    line = Enum.at(c.lines, c.cy) || ""
    len = String.length(line)

    c =
      case action do
        :cursor_left -> %{c | cx: max(c.cx - 1, 0)}
        :cursor_right -> %{c | cx: min(c.cx + 1, max(len - 1, 0))}
        :cursor_up -> %{c | cy: max(c.cy - 1, 0)}
        :cursor_down -> %{c | cy: min(c.cy + 1, last)}
        :start_of_line -> %{c | cx: 0}
        :end_of_line -> %{c | cx: max(len - 1, 0)}
        :back_to_indentation -> %{c | cx: len - String.length(String.trim_leading(line))}
        :history_top -> %{c | cy: 0, cx: 0}
        :history_bottom -> %{c | cy: last}
        :top_line -> %{c | cy: c.top}
        :middle_line -> %{c | cy: min(c.top + div(c.height, 2), last)}
        :bottom_line -> %{c | cy: min(c.top + c.height - 1, last)}
        :halfpage_up -> %{c | cy: max(c.cy - div(c.height, 2), 0), top: max(c.top - div(c.height, 2), 0)}
        :halfpage_down -> %{c | cy: min(c.cy + div(c.height, 2), last), top: c.top + div(c.height, 2)}
        :page_up -> %{c | cy: max(c.cy - c.height, 0), top: max(c.top - c.height, 0)}
        :page_down -> %{c | cy: min(c.cy + c.height, last), top: c.top + c.height}
        :next_word -> word(c, line, 1)
        :previous_word -> word(c, line, -1)
        :next_word_end -> word(c, line, 2)
        _ -> c
      end

    clamp(c)
  end

  defp word(c, line, dir) do
    positions = Regex.scan(~r/\S+/u, line, return: :index) |> Enum.map(fn [{s, l}] -> {String.length(binary_part(line, 0, s)), String.length(binary_part(line, s, l))} end)

    case dir do
      1 -> case Enum.find(positions, fn {s, _} -> s > c.cx end) do
          {s, _} -> %{c | cx: s}
          nil -> if c.cy + 1 < length(c.lines), do: %{c | cy: c.cy + 1, cx: 0}, else: c
        end

      -1 -> case positions |> Enum.reverse() |> Enum.find(fn {s, _} -> s < c.cx end) do
          {s, _} -> %{c | cx: s}
          nil -> if c.cy > 0, do: %{c | cy: c.cy - 1, cx: 0}, else: c
        end

      2 -> case Enum.find(positions, fn {s, l} -> s + l - 1 > c.cx end) do
          {s, l} -> %{c | cx: s + l - 1}
          nil -> c
        end
    end
  end

  defp clamp(c) do
    last = length(c.lines) - 1
    max_top = max(length(c.lines) - c.height, 0)
    top = c.top |> min(max_top) |> max(0)

    top =
      cond do
        c.cy < top -> c.cy
        c.cy >= top + c.height -> c.cy - c.height + 1
        true -> top
      end

    %{c | top: top, cy: c.cy |> max(0) |> min(last)}
  end

  defp selection_text(%{sel: nil}), do: nil

  defp selection_text(%{sel: {:line, l}} = c) do
    {a, b} = Enum.min_max([l, c.cy])
    c.lines |> Enum.slice(a..b) |> Enum.join("\n")
  end

  defp selection_text(%{sel: {:char, start}} = c) do
    {{l1, c1}, {l2, c2}} = Enum.min_max([start, {c.cy, c.cx}])

    if l1 == l2 do
      String.slice(Enum.at(c.lines, l1), c1..c2)
    else
      first = String.slice(Enum.at(c.lines, l1), c1..-1//1)
      mid = Enum.slice(c.lines, (l1 + 1)..(l2 - 1)//1)
      last = String.slice(Enum.at(c.lines, l2), 0..c2)
      Enum.join([first | mid] ++ [last], "\n")
    end
  end

  defp copy(c) do
    if text = selection_text(c), do: Clipboard.put(text)
  end

  # copy-pipe-and-cancel "xclip -sel clip -i" (tmux.linux.conf) / "pbcopy"
  defp pipe(st, c, args) do
    text = selection_text(c) || ""
    Clipboard.put(text)

    case args do
      [cmd | _] ->
        {:ok, input} = Lepton.Pipe.open()
        IO.binwrite(input, text)
        Lepton.Pipe.close_write(input)
        {:ok, sink} = StringIO.open("")
        Lepton.Shell.run_string(cmd, stdin: input, stdout: sink, stderr: sink, cwd: st.ctx.cwd, env: st.ctx.env, tty: st.tty)

      [] ->
        :ok
    end
  end

  defp search(st, %{search: nil} = c, _dir), do: %{st | mode: {:copy, c}}

  defp search(st, %{search: {pattern, base}} = c, dir) do
    dir = base * dir

    case Regex.compile(Regex.escape(pattern)) do
      {:ok, re} ->
        order =
          if dir > 0,
            do: Enum.to_list((c.cy + 1)..(length(c.lines) - 1)//1) ++ Enum.to_list(0..c.cy),
            else: Enum.to_list((c.cy - 1)..0//-1) ++ Enum.to_list((length(c.lines) - 1)..c.cy//-1)

        case Enum.find(order, &Regex.match?(re, Enum.at(c.lines, &1))) do
          nil -> %{st | mode: {:copy, c}, message: {"Search failed: #{pattern}", System.monotonic_time(:millisecond) + 1500}}
          l ->
            [{s, _} | _] = Regex.run(re, Enum.at(c.lines, l), return: :index)
            %{st | mode: {:copy, clamp(%{c | cy: l, cx: String.length(binary_part(Enum.at(c.lines, l), 0, s))})}}
        end

      _ ->
        %{st | mode: {:copy, c}}
    end
  end

  # -- drawing ---------------------------------------------------------------------------------

  def render_row(c, _scr, y, w) do
    li = c.top + y
    text = (Enum.at(c.lines, li) || "") |> String.slice(0, w) |> String.pad_trailing(w)
    text = highlight(c, li, text)

    if y == 0 do
      indicator = "[#{max(length(c.lines) - c.height - c.top, 0)}/#{max(length(c.lines) - c.height, 0)}]"
      visible = String.slice(Lepton.Style.strip(text), 0, max(w - String.length(indicator), 0))
      String.pad_trailing(visible, w - String.length(indicator)) <> "\e[48;5;220;38;5;232m" <> indicator <> "\e[0m"
    else
      text
    end
  end

  defp highlight(%{sel: nil}, _li, text), do: text

  defp highlight(c, li, text) do
    range =
      case c.sel do
        {:line, l} ->
          {a, b} = Enum.min_max([l, c.cy])
          if li >= a and li <= b, do: {0, String.length(text)}

        {:char, start} ->
          {{l1, c1}, {l2, c2}} = Enum.min_max([start, {c.cy, c.cx}])

          cond do
            li < l1 or li > l2 -> nil
            l1 == l2 -> {c1, c2 + 1}
            li == l1 -> {c1, String.length(text)}
            li == l2 -> {0, c2 + 1}
            true -> {0, String.length(text)}
          end
      end

    case range do
      nil -> text
      {a, b} ->
        {pre, rest} = String.split_at(text, a)
        {mid, post} = String.split_at(rest, max(b - a, 0))
        pre <> "\e[7m" <> mid <> "\e[27m" <> post
    end
  end

  def cursor(c, x, y), do: {y + c.cy - c.top, x + c.cx}
end
