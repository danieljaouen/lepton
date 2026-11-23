defmodule Lepton.Screen do
  @moduledoc """
  A VT100/xterm screen emulator.

  Multiplexer panes run their programs against a virtual terminal: bytes
  written by the program are interpreted here (cursor movement, erase,
  SGR attributes, scroll regions, the alternate screen) into a grid of
  cells that the multiplexer composes onto the real terminal. Lines that
  scroll off the top are kept as scrollback for copy mode.

  Cells are `{grapheme, sgr}` where `sgr` is the SGR parameter string in
  effect (e.g. `"1;32"`), which keeps rendering trivial.
  """

  defstruct rows: 24,
            cols: 80,
            grid: %{},
            x: 0,
            y: 0,
            sgr: "",
            saved: {0, 0, ""},
            top: 0,
            bottom: 23,
            scrollback: [],
            sb_len: 0,
            history_limit: 100_000,
            alt: nil,
            cursor_visible: true,
            pending: "",
            wrap_next: false,
            title: nil,
            dirty: true

  def new(rows, cols, opts \\ []) do
    %__MODULE__{rows: rows, cols: cols, bottom: rows - 1, history_limit: opts[:history_limit] || 100_000}
  end

  @blank {" ", ""}

  # The grid is %{row => %{col => cell}}, so scrolling only moves row keys.
  def cell(s, x, y), do: s.grid |> Map.get(y, %{}) |> Map.get(x, @blank)

  defp put_cell(grid, x, y, c), do: Map.update(grid, y, %{x => c}, &Map.put(&1, x, c))
  defp del_cell(grid, x, y), do: Map.update(grid, y, %{}, &Map.delete(&1, x))

  @doc "Text of row `y` (no attributes)."
  def row_text(s, y), do: for(x <- 0..(s.cols - 1), into: "", do: elem(cell(s, x, y), 0)) |> String.trim_trailing()

  def text(s), do: Enum.map_join(0..(s.rows - 1), "\n", &row_text(s, &1)) |> String.trim_trailing()

  @doc "Render row `y` as a string with SGR escapes."
  def render_row(s, y, from \\ 0, width \\ nil) do
    width = width || s.cols

    {out, last} =
      Enum.reduce(from..(from + width - 1)//1, {[], ""}, fn x, {acc, cur} ->
        {ch, sgr} = if x < s.cols, do: cell(s, x, y), else: @blank

        if sgr == cur,
          do: {[acc, ch], cur},
          else: {[acc, "\e[0", if(sgr == "", do: "", else: ";" <> sgr), "m", ch], sgr}
      end)

    IO.iodata_to_binary([out, if(last == "", do: "", else: "\e[0m")])
  end

  def resize(s, rows, cols) do
    grid = for {y, row} <- s.grid, y < rows, into: %{}, do: {y, Map.reject(row, fn {x, _} -> x >= cols end)}
    %{s | rows: rows, cols: cols, grid: grid, x: min(s.x, cols - 1), y: min(s.y, rows - 1), top: 0, bottom: rows - 1, dirty: true}
  end

  # -- input ----------------------------------------------------------------------------

  def feed(s, bytes), do: parse(%{s | dirty: true}, s.pending <> bytes)

  defp parse(s, <<>>), do: %{s | pending: ""}

  defp parse(s, <<27, rest::binary>> = all) do
    case escape(rest) do
      {:incomplete} -> %{s | pending: all}
      {:csi, params, inter, final, rest} -> s |> csi(params, inter, final) |> parse(rest)
      {:osc, body, rest} -> s |> osc(body) |> parse(rest)
      {:string, body, rest} -> s |> string(body) |> parse(rest)
      {:esc, c, rest} -> s |> esc(c) |> parse(rest)
    end
  end

  defp parse(s, <<"\r", rest::binary>>), do: parse(%{s | x: 0, wrap_next: false}, rest)
  defp parse(s, <<"\n", rest::binary>>), do: parse(linefeed(%{s | wrap_next: false}), rest)
  defp parse(s, <<11, rest::binary>>), do: parse(linefeed(s), rest)
  defp parse(s, <<12, rest::binary>>), do: parse(linefeed(s), rest)
  defp parse(s, <<8, rest::binary>>), do: parse(%{s | x: max(s.x - 1, 0), wrap_next: false}, rest)
  defp parse(s, <<"\t", rest::binary>>), do: parse(%{s | x: min((div(s.x, 8) + 1) * 8, s.cols - 1)}, rest)
  defp parse(s, <<7, rest::binary>>), do: parse(s, rest)
  defp parse(s, <<c, rest::binary>>) when c < 32, do: parse(s, rest)

  defp parse(s, bytes) do
    case String.next_grapheme(bytes) do
      {g, rest} ->
        if String.valid?(g) or byte_size(bytes) >= 4 do
          parse(put_char(s, g), rest)
        else
          %{s | pending: bytes}
        end

      nil ->
        %{s | pending: bytes}
    end
  end

  # CSI: parameter bytes 0x30-0x3F (digits, ; : and the private markers
  # < = > ?), intermediates 0x20-0x2F, a final 0x40-0x7E. Anything else
  # ends it as malformed: it is dropped, and what follows is read as usual.
  defp escape(<<"[", rest::binary>>) do
    case Regex.run(~r/^([0-?]*)([ -\/]*)([@-~])/, rest) do
      [whole, params, inter, final] ->
        {:csi, params, inter, final, binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))}

      nil ->
        [prefix] = Regex.run(~r/^[0-?]*[ -\/]*/, rest)

        if prefix == rest and byte_size(rest) <= 64,
          do: {:incomplete},
          else: {:esc, "?", binary_part(rest, byte_size(prefix), byte_size(rest) - byte_size(prefix))}
    end
  end

  # DCS, SOS, PM and APC: strings up to ST (ESC \). A DCS may be tmux's
  # passthrough, ESC P tmux; ... with its escapes doubled.
  defp escape(<<c, rest::binary>>) when c in [?P, ?X, ?^, ?_] do
    case string_end(rest, 0) do
      nil -> if byte_size(rest) > 65_536, do: {:esc, "?", ""}, else: {:incomplete}
      n -> {:string, <<c, binary_part(rest, 0, n)::binary>>, binary_part(rest, n + 2, byte_size(rest) - n - 2)}
    end
  end

  defp escape(<<"]", rest::binary>>) do
    case Regex.run(~r/^(.*?)(\a|\e\\)/s, rest) do
      [whole, body, _] -> {:osc, body, binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))}
      nil -> if byte_size(rest) > 4096, do: {:esc, "?", ""}, else: {:incomplete}
    end
  end

  defp escape(<<c, _cs, rest::binary>>) when c in [?(, ?), ?#], do: {:esc, "charset", rest}
  defp escape(<<c, rest::binary>>), do: {:esc, <<c>>, rest}
  defp escape(<<>>), do: {:incomplete}

  # A wide character (Lepton.Width: Chinese, Japanese, Korean) takes two
  # cells: itself, and a continuation cell {"", sgr} after it.
  defp put_char(s, g) do
    case Lepton.Width.grapheme(g) do
      0 -> combine(s, g)
      w -> put_char(s, g, w)
    end
  end

  defp put_char(s, g, w) do
    s = if s.wrap_next, do: linefeed(%{s | x: 0, wrap_next: false}), else: s
    # One that doesn't fit in the last column goes to the next line.
    s = if w == 2 and s.x >= s.cols - 1 and s.cols > 1, do: linefeed(%{s | grid: put_cell(s.grid, s.x, s.y, {" ", s.sgr}), x: 0}), else: s
    grid = s.grid |> unpair(s.x, s.y) |> put_cell(s.x, s.y, {g, s.sgr})
    grid = if w == 2, do: grid |> unpair(s.x + 1, s.y) |> put_cell(s.x + 1, s.y, {"", s.sgr}), else: grid
    s = %{s | grid: grid}

    if s.x + w > s.cols - 1,
      do: %{s | x: s.cols - 1, wrap_next: true},
      else: %{s | x: s.x + w}
  end

  # Writing over half of a wide character blanks the other half.
  defp unpair(grid, x, y) do
    row = Map.get(grid, y, %{})

    case Map.get(row, x) do
      {"", sgr} when x > 0 -> put_cell(grid, x - 1, y, {" ", sgr})
      {g, sgr} when g != "" -> if match?({"", _}, Map.get(row, x + 1)), do: put_cell(grid, x + 1, y, {" ", sgr}), else: grid
      _ -> grid
    end
  end

  # A combining mark on its own joins the character before it.
  defp combine(s, g) do
    x = if s.wrap_next, do: s.x, else: s.x - 1
    x = if x > 0 and match?({"", _}, cell(s, x, s.y)), do: x - 1, else: x

    if x >= 0 do
      {prev, sgr} = cell(s, x, s.y)
      %{s | grid: put_cell(s.grid, x, s.y, {prev <> g, sgr})}
    else
      s
    end
  end

  defp linefeed(s) do
    if s.y == s.bottom, do: scroll_up(s, 1), else: %{s | y: min(s.y + 1, s.rows - 1)}
  end

  # Lines leaving the top of the main screen go to scrollback, unless the
  # scroll is a line deletion (`save?: false`).
  defp scroll_up(s, n, save? \\ true) do
    Enum.reduce(1..n//1, s, fn _, s ->
      s =
        if save? and s.top == 0 and s.alt == nil do
          line = for x <- 0..(s.cols - 1), do: cell(s, x, 0)
          sb = [line | s.scrollback]
          {sb, len} = if s.sb_len >= s.history_limit, do: {Enum.take(sb, s.history_limit), s.history_limit}, else: {sb, s.sb_len + 1}
          %{s | scrollback: sb, sb_len: len}
        else
          s
        end

      grid =
        for {y, row} <- s.grid, y != s.top, into: %{} do
          if y > s.top and y <= s.bottom, do: {y - 1, row}, else: {y, row}
        end

      %{s | grid: grid}
    end)
  end

  defp scroll_down(s, n) do
    Enum.reduce(1..n//1, s, fn _, s ->
      grid =
        for {y, row} <- s.grid, y != s.bottom, into: %{} do
          if y >= s.top and y < s.bottom, do: {y + 1, row}, else: {y, row}
        end

      %{s | grid: grid}
    end)
  end

  defp esc(s, "7"), do: %{s | saved: {s.x, s.y, s.sgr}}
  defp esc(s, "8"), do: (fn {x, y, sgr} -> %{s | x: x, y: y, sgr: sgr} end).(s.saved)
  defp esc(s, "D"), do: linefeed(s)
  defp esc(s, "E"), do: linefeed(%{s | x: 0})
  defp esc(s, "M"), do: if(s.y == s.top, do: scroll_down(s, 1), else: %{s | y: max(s.y - 1, 0)})
  defp esc(s, "c"), do: new(s.rows, s.cols, history_limit: s.history_limit)
  defp esc(s, _), do: s

  # Where a string's ST (ESC \) is; ESC ESC is an escaped ESC (tmux).
  defp string_end(bin, i) do
    case bin do
      <<_::binary-size(^i), 27, 27, _::binary>> -> string_end(bin, i + 2)
      <<_::binary-size(^i), 27, ?\\, _::binary>> -> i
      <<_::binary-size(^i), _, _::binary>> -> string_end(bin, i + 1)
      _ -> nil
    end
  end

  # tmux's passthrough: what it wraps is output as any other (OSC 52, titles);
  # other strings (DCS queries, kitty graphics) are ignored.
  defp string(s, <<"Ptmux;", body::binary>>), do: %{parse(s, String.replace(body, "\e\e", "\e")) | pending: ""}
  defp string(s, _), do: s

  defp osc(s, body) do
    case String.split(body, ";", parts: 2) do
      [n, title] when n in ["0", "2"] -> %{s | title: title}
      ["52", data] -> clipboard(s, data)
      _ -> s
    end
  end

  defp clipboard(s, data) do
    with [_, b64] <- String.split(data, ";", parts: 2), {:ok, text} <- Base.decode64(b64) do
      Lepton.Clipboard.put(text)
    end

    s
  end

  defp nums(params, default) do
    params
    |> String.trim_leading("?")
    |> String.split(";")
    |> Enum.map(fn
      "" -> default
      n -> case Integer.parse(n) do
          {i, _} -> i
          :error -> default
        end
    end)
  end

  defp n1(params), do: params |> nums(1) |> hd() |> max(1)

  # Private (< = >) and intermediate forms are other commands than the
  # plain ones: CSI > 1 u and CSI < u push and pop the kitty keyboard
  # flags, not restore the cursor; CSI > 4 ; 2 m sets xterm's
  # modifyOtherKeys, not underline. None draws anything: they are ignored,
  # and ? is for modes only.
  defp csi(s, <<m, _::binary>>, _inter, _final) when m in [?<, ?=, ?>], do: s
  defp csi(s, _params, inter, _final) when inter != "", do: s
  defp csi(s, "?" <> _, _inter, final) when final not in ["h", "l"], do: s

  defp csi(s, params, _inter, final) do
    s = %{s | wrap_next: false}

    case final do
      "A" -> %{s | y: max(s.y - n1(params), if(s.y >= s.top, do: s.top, else: 0))}
      "B" -> %{s | y: min(s.y + n1(params), if(s.y <= s.bottom, do: s.bottom, else: s.rows - 1))}
      "C" -> %{s | x: min(s.x + n1(params), s.cols - 1)}
      "D" -> %{s | x: max(s.x - n1(params), 0)}
      "E" -> %{s | x: 0, y: min(s.y + n1(params), s.rows - 1)}
      "F" -> %{s | x: 0, y: max(s.y - n1(params), 0)}
      "G" -> %{s | x: clamp(n1(params) - 1, s.cols)}
      "`" -> %{s | x: clamp(n1(params) - 1, s.cols)}
      "d" -> %{s | y: clamp(n1(params) - 1, s.rows)}
      f when f in ["H", "f"] ->
        case nums(params, 1) do
          [r, c | _] -> %{s | y: clamp(r - 1, s.rows), x: clamp(c - 1, s.cols)}
          [r] -> %{s | y: clamp(r - 1, s.rows), x: 0}
        end

      "J" -> erase_display(s, hd(nums(params, 0)))
      "K" -> erase_line(s, hd(nums(params, 0)))
      "X" -> erase_cells(s, s.x, min(s.x + n1(params), s.cols) - 1, s.y)
      "P" -> delete_chars(s, n1(params))
      "@" -> insert_chars(s, n1(params))
      "L" -> insert_lines(s, n1(params))
      "M" -> delete_lines(s, n1(params))
      "S" -> scroll_up(s, n1(params))
      "T" -> scroll_down(s, n1(params))
      "m" -> %{s | sgr: sgr(s.sgr, params)}
      "r" ->
        case nums(params, 0) do
          [t, b | _] when t > 0 and b > t -> %{s | top: t - 1, bottom: min(b - 1, s.rows - 1), x: 0, y: 0}
          _ -> %{s | top: 0, bottom: s.rows - 1, x: 0, y: 0}
        end

      "s" -> %{s | saved: {s.x, s.y, s.sgr}}
      "u" -> (fn {x, y, sgr} -> %{s | x: x, y: y, sgr: sgr} end).(s.saved)
      "h" -> mode(s, params, true)
      "l" -> mode(s, params, false)
      _ -> s
    end
  end

  defp clamp(v, n), do: v |> max(0) |> min(n - 1)

  defp mode(s, "?25", on), do: %{s | cursor_visible: on}

  defp mode(s, p, true) when p in ["?1049", "?47", "?1047"] do
    if s.alt, do: s, else: %{s | alt: {s.grid, s.x, s.y}, grid: %{}}
  end


  defp mode(s, p, false) when p in ["?1049", "?47", "?1047"] do
    case s.alt do
      {grid, x, y} -> %{s | grid: grid, x: x, y: y, alt: nil}
      nil -> s
    end
  end

  defp mode(s, _, _), do: s

  defp erase_display(s, 0), do: s |> erase_line(0) |> erase_rows(s.y + 1, s.rows - 1)
  defp erase_display(s, 1), do: s |> erase_line(1) |> erase_rows(0, s.y - 1)
  defp erase_display(s, 3), do: %{s | scrollback: [], sb_len: 0}
  defp erase_display(s, _), do: %{s | grid: %{}}

  defp erase_rows(s, from, to) when from > to, do: s
  defp erase_rows(s, from, to), do: %{s | grid: Map.reject(s.grid, fn {y, _} -> y >= from and y <= to end)}

  defp erase_line(s, 0), do: erase_cells(s, s.x, s.cols - 1, s.y)
  defp erase_line(s, 1), do: erase_cells(s, 0, s.x, s.y)
  defp erase_line(s, _), do: erase_cells(s, 0, s.cols - 1, s.y)

  defp erase_cells(s, from, to, y) do
    # Erased cells keep the current background (like xterm's BCE).
    bg = background(s.sgr)

    grid =
      Enum.reduce(from..to//1, s.grid, fn x, g ->
        if bg == "", do: del_cell(g, x, y), else: put_cell(g, x, y, {" ", bg})
      end)

    %{s | grid: grid}
  end

  defp background(sgr) do
    sgr |> String.split(";") |> bg_codes([]) |> Enum.join(";")
  end

  defp bg_codes(["48", "5", n | rest], acc), do: bg_codes(rest, acc ++ ["48", "5", n])
  defp bg_codes(["48", "2", r, g, b | rest], acc), do: bg_codes(rest, acc ++ ["48", "2", r, g, b])
  defp bg_codes([c | rest], acc) do
    case Integer.parse(c) do
      {n, ""} when n in 40..47 or n in 100..107 -> bg_codes(rest, acc ++ [c])
      _ -> bg_codes(rest, acc)
    end
  end

  defp bg_codes([], acc), do: acc

  defp delete_chars(s, n) do
    row = for x <- 0..(s.cols - 1), do: cell(s, x, s.y)
    {left, right} = Enum.split(row, s.x)
    new_row = left ++ Enum.drop(right, n) ++ List.duplicate(@blank, n)
    put_row(s, s.y, new_row)
  end

  defp insert_chars(s, n) do
    row = for x <- 0..(s.cols - 1), do: cell(s, x, s.y)
    {left, right} = Enum.split(row, s.x)
    new_row = Enum.take(left ++ List.duplicate(@blank, n) ++ right, s.cols)
    put_row(s, s.y, new_row)
  end

  defp put_row(s, y, cells) do
    row = for {c, x} <- Enum.with_index(cells), c != @blank, into: %{}, do: {x, c}
    %{s | grid: Map.put(s.grid, y, row)}
  end

  defp insert_lines(s, n) do
    if s.y < s.top or s.y > s.bottom, do: s, else: %{scroll_down(%{s | top: s.y}, n) | top: s.top}
  end

  defp delete_lines(s, n) do
    if s.y < s.top or s.y > s.bottom, do: s, else: %{scroll_up(%{s | top: s.y}, n, false) | top: s.top}
  end

  # Keep the SGR state as a normalized parameter string.
  defp sgr(_current, ""), do: ""

  defp sgr(current, params) do
    params
    |> String.split(";")
    |> Enum.map(fn
      "" -> "0"
      p -> p
    end)
    |> apply_sgr(if(current == "", do: [], else: String.split(current, ";")))
    |> Enum.join(";")
  end

  defp apply_sgr([], acc), do: acc
  defp apply_sgr(["0" | rest], _acc), do: apply_sgr(rest, [])
  defp apply_sgr(["00" | rest], _acc), do: apply_sgr(rest, [])
  defp apply_sgr([c, "5", n | rest], acc) when c in ["38", "48"], do: apply_sgr(rest, drop_color(acc, c) ++ [c, "5", n])
  defp apply_sgr([c, "2", r, g, b | rest], acc) when c in ["38", "48"], do: apply_sgr(rest, drop_color(acc, c) ++ [c, "2", r, g, b])

  defp apply_sgr([c | rest], acc) do
    n = String.to_integer(c)

    acc =
      cond do
        n in 30..37 or n in 90..97 or n == 39 -> drop_color(acc, "38") ++ if(n == 39, do: [], else: [c])
        n in 40..47 or n in 100..107 or n == 49 -> drop_color(acc, "48") ++ if(n == 49, do: [], else: [c])
        n == 22 -> acc -- ["1", "2"]
        n == 23 -> acc -- ["3"]
        n == 24 -> acc -- ["4"]
        n == 27 -> acc -- ["7"]
        c in acc -> acc
        true -> acc ++ [c]
      end

    apply_sgr(rest, acc)
  rescue
    ArgumentError -> apply_sgr(rest, acc)
  end

  # Remove an existing foreground (38) or background (48) colour.
  defp drop_color(acc, kind) do
    {base, bright} = if kind == "38", do: {30..37, 90..97}, else: {40..47, 100..107}
    drop(acc, kind, base, bright, [])
  end

  defp drop([k, "5", _ | rest], k, b, br, out), do: drop(rest, k, b, br, out)
  defp drop([k, "2", _, _, _ | rest], k, b, br, out), do: drop(rest, k, b, br, out)

  defp drop([c | rest], k, b, br, out) do
    case Integer.parse(c) do
      {n, ""} -> if n in b or n in br, do: drop(rest, k, b, br, out), else: drop(rest, k, b, br, out ++ [c])
      _ -> drop(rest, k, b, br, out ++ [c])
    end
  end

  defp drop([], _, _, _, out), do: out
end
