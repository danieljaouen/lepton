defmodule Lepton.Shell.LineEditor do
  @moduledoc """
  The interactive line editor (zsh ZLE with oh-my-zsh defaults).

  oh-my-zsh runs `bindkey -e`, so this is the emacs keymap, plus:

    * **zsh-autosuggestions** - the newest history entry starting with the
      current input is shown dimmed; `<right>`, `C-f` and `C-e` at end of
      line accept it, `M-f` accepts one word
    * **zsh-syntax-highlighting** - each command word (also after `|`, `&&`, `||`, `;`) is green when it
      resolves (alias, builtin, program) and red otherwise; quoted strings
      are yellow
    * `C-r` incremental history search, `TAB` completion (commands, then
      paths), `M-.` insert last argument, `C-x C-e` edit in `$EDITOR`
  """

  alias Lepton.{Keys, Style, TTY}

  @bindings [
    {"C-a", :beginning_of_line},
    {"<home>", :beginning_of_line},
    {"C-e", :end_of_line},
    {"<end>", :end_of_line},
    {"C-b", :backward_char},
    {"<left>", :backward_char},
    {"C-f", :forward_char},
    {"<right>", :forward_char},
    {"M-b", :backward_word},
    {"C-<left>", :backward_word},
    {"M-f", :forward_word},
    {"C-<right>", :forward_word},
    {"DEL", :backward_delete_char},
    {"C-h", :backward_delete_char},
    {"C-d", :delete_char_or_eof},
    {"<deletechar>", :delete_char},
    {"C-k", :kill_line},
    {"C-u", :kill_whole_line},
    {"C-w", :backward_kill_word},
    {"M-DEL", :backward_kill_word},
    {"M-d", :kill_word},
    {"C-y", :yank},
    {"C-t", :transpose_chars},
    {"C-l", :clear_screen},
    {"C-p", :up_history},
    {"<up>", :up_history},
    {"C-n", :down_history},
    {"<down>", :down_history},
    {"C-r", :history_search},
    {"TAB", :complete},
    {"RET", :accept_line},
    # Shift+Enter (sent as Alt+Enter, ESC RET) or Alt+Enter: a newline in
    # the command line, which runs with the rest at Return (zsh's self-insert-unmeta)
    {"M-RET", :newline},
    {"C-j", :accept_line},
    {"C-c", :cancel},
    {"C-g", :cancel},
    {"M-.", :insert_last_word},
    {"C-x", :prefix_ctrl_x}
  ]

  def bindings, do: @bindings

  defstruct buf: "", pos: 0, hist: [], hist_idx: -1, saved: "", kill: "", prompt: "", shell: nil,
            drawn_rows: 0, drawn_cursor_row: 0, cols: 80, tabbed: false

  @doc "Read a line. Returns {:ok, line} | :eof | :cancel."
  def read(shell, prompt) do
    tty = shell.ctx.tty

    # Like zsh, no line editor on a dumb terminal (also used by automation).
    if tty && is_pid(tty) && Process.alive?(tty) && Map.get(shell.ctx.env, "TERM") != "dumb" do
      TTY.set_mode(tty, :raw)
      # Bracketed paste while a line is typed: a paste comes as text, its
      # newlines in the line, not run one by one as Return would.
      out(tty, "\e[?2004h")

      try do
        {_rows, cols} = TTY.size(tty)
        out(tty, prompt_lines_before_last(prompt))
        state = %__MODULE__{prompt: last_line(prompt), shell: shell, hist: shell.history, cols: max(cols, 20)}
        state = redraw(state)
        loop(state)
      after
        out(tty, "\e[?2004l")
        TTY.set_mode(tty, :cooked)
      end
    else
      # No terminal (scripts, pipes) or TERM=dumb: plain line reading.
      if tty, do: Lepton.IO.write(shell.ctx.stdout, Lepton.Style.strip(prompt))

      case Lepton.IO.read_line(shell.ctx.stdin) do
        :eof -> :eof
        line -> {:ok, String.trim_trailing(line, "\n")}
      end
    end
  end

  defp loop(state) do
    tty = state.shell.ctx.tty

    case TTY.read_key(tty) do
      {:cpr, _, _} -> loop(state)
      {:resize, _rows, cols} -> state |> Map.put(:cols, max(cols, 20)) |> redraw() |> loop()
      {:paste, text} -> state |> insert(paste_text(text)) |> touch(:self_insert) |> redraw() |> loop()
      key -> dispatch(key, state)
    end
  end

  defp dispatch(key, state) do
    action = List.keyfind(@bindings, key, 0)

    case action do
      {_, :accept_line} ->
        state = %{state | buf: state.buf, pos: String.length(state.buf)}
        finish(state)
        {:ok, state.buf}

      {_, :cancel} ->
        finish(%{state | pos: String.length(state.buf)})
        out(state.shell.ctx.tty, "^C")
        :cancel

      {_, :delete_char_or_eof} when state.buf == "" ->
        finish(state)
        :eof

      {_, :prefix_ctrl_x} ->
        case TTY.read_key(state.shell.ctx.tty) do
          "C-e" -> edit_in_editor(state)
          _ -> loop(state)
        end

      {_, act} ->
        state |> act(act) |> touch(act) |> redraw() |> loop()

      nil ->
        case Keys.text(key) do
          nil -> loop(state)
          text -> state |> insert(text) |> touch(:self_insert) |> redraw() |> loop()
        end
    end
  end

  defp touch(state, :complete), do: state
  defp touch(state, _), do: %{state | tabbed: false}

  # -- editing actions ---------------------------------------------------------------

  defp act(s, :beginning_of_line), do: %{s | pos: 0}
  defp act(s, :end_of_line), do: accept_suggestion(s) |> then(&%{&1 | pos: String.length(&1.buf)})
  defp act(s, :backward_char), do: %{s | pos: max(s.pos - 1, 0)}

  defp act(s, :forward_char) do
    if s.pos == String.length(s.buf), do: accept_suggestion(s), else: %{s | pos: s.pos + 1}
  end

  defp act(s, :backward_word), do: %{s | pos: word_start(s.buf, s.pos)}

  defp act(s, :forward_word) do
    if s.pos == String.length(s.buf) do
      case suggestion(s) do
        nil -> s
        rest ->
          [word] = Regex.run(~r/^\s*\S*/, rest)
          insert(s, word)
      end
    else
      %{s | pos: word_end(s.buf, s.pos)}
    end
  end

  defp act(s, :backward_delete_char) do
    if s.pos == 0, do: s, else: %{s | buf: delete_range(s.buf, s.pos - 1, s.pos), pos: s.pos - 1}
  end

  defp act(s, :delete_char), do: %{s | buf: delete_range(s.buf, s.pos, s.pos + 1)}
  defp act(s, :delete_char_or_eof), do: act(s, :delete_char)
  defp act(s, :kill_line), do: %{s | kill: String.slice(s.buf, s.pos..-1//1), buf: String.slice(s.buf, 0, s.pos)}
  defp act(s, :kill_whole_line), do: %{s | kill: s.buf, buf: "", pos: 0}

  defp act(s, :backward_kill_word) do
    start = word_start(s.buf, s.pos)
    %{s | kill: String.slice(s.buf, start, s.pos - start), buf: delete_range(s.buf, start, s.pos), pos: start}
  end

  defp act(s, :kill_word) do
    stop = word_end(s.buf, s.pos)
    %{s | kill: String.slice(s.buf, s.pos, stop - s.pos), buf: delete_range(s.buf, s.pos, stop)}
  end

  defp act(s, :yank), do: insert(s, s.kill)
  defp act(s, :newline), do: insert(s, "\n")

  defp act(s, :transpose_chars) do
    len = String.length(s.buf)

    if len < 2 or s.pos == 0 do
      s
    else
      p = if s.pos == len, do: len - 1, else: s.pos
      g = String.graphemes(s.buf)
      {a, b} = {Enum.at(g, p - 1), Enum.at(g, p)}
      g = g |> List.replace_at(p - 1, b) |> List.replace_at(p, a)
      %{s | buf: Enum.join(g), pos: min(p + 1, len)}
    end
  end

  defp act(s, :clear_screen) do
    out(s.shell.ctx.tty, "\e[H\e[2J")
    %{s | drawn_rows: 0, drawn_cursor_row: 0}
  end

  defp act(s, :up_history) do
    matches = history_matches(s)
    idx = s.hist_idx + 1

    case Enum.at(matches, idx) do
      nil -> s
      line ->
        saved = if s.hist_idx == -1, do: s.buf, else: s.saved
        %{s | buf: line, pos: String.length(line), hist_idx: idx, saved: saved}
    end
  end

  defp act(s, :down_history) do
    cond do
      s.hist_idx <= 0 -> %{s | buf: s.saved, pos: String.length(s.saved), hist_idx: -1}
      true ->
        line = Enum.at(history_matches(s), s.hist_idx - 1)
        %{s | buf: line, pos: String.length(line), hist_idx: s.hist_idx - 1}
    end
  end

  defp act(s, :insert_last_word) do
    case s.hist do
      [last | _] -> insert(s, last |> String.split() |> List.last() || "")
      [] -> s
    end
  end

  defp act(s, :history_search), do: history_search(s, "", 0)
  defp act(s, :complete), do: complete(s)
  defp act(s, _), do: s

  defp history_matches(s) do
    prefix = if s.hist_idx == -1, do: s.buf, else: s.saved
    s.hist |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.uniq()
  end

  defp insert(s, text) do
    {a, b} = String.split_at(s.buf, s.pos)
    %{s | buf: a <> text <> b, pos: s.pos + String.length(text)}
  end

  defp delete_range(buf, from, to) do
    String.slice(buf, 0, max(from, 0)) <> String.slice(buf, to..-1//1)
  end

  defp word_start(buf, pos) do
    before = String.slice(buf, 0, pos)
    trimmed = String.replace(before, ~r/[^A-Za-z0-9]*$/u, "")
    String.length(String.replace(trimmed, ~r/[A-Za-z0-9]*$/u, ""))
  end

  defp word_end(buf, pos) do
    after_ = String.slice(buf, pos..-1//1)
    [skip] = Regex.run(~r/^[^A-Za-z0-9]*[A-Za-z0-9]*/u, after_)
    pos + String.length(skip)
  end

  # -- autosuggestions -----------------------------------------------------------------------

  defp suggestion(%{buf: ""}), do: nil

  defp suggestion(s) do
    if s.pos == String.length(s.buf) do
      case Enum.find(s.hist, &(String.starts_with?(&1, s.buf) and &1 != s.buf)) do
        nil -> nil
        line -> String.slice(line, String.length(s.buf)..-1//1)
      end
    end
  end

  defp accept_suggestion(s) do
    case suggestion(s) do
      nil -> s
      rest -> insert(s, rest)
    end
  end

  # -- incremental search ----------------------------------------------------------------------

  defp history_search(s, query, skip) do
    matches = s.hist |> Enum.filter(&String.contains?(&1, query)) |> Enum.uniq()
    found = if query == "", do: nil, else: Enum.at(matches, skip)
    tty = s.shell.ctx.tty
    shown = found || ""
    status = "(reverse-i-search)`#{query}': #{shown}"
    s2 = %{s | buf: shown, pos: String.length(shown)}
    draw_raw(s2, status)

    case TTY.read_key(tty) do
      "C-r" -> history_search(s, query, skip + 1)
      k when k in ["DEL", "C-h"] -> history_search(s, String.slice(query, 0..-2//1), 0)
      k when k in ["C-g", "C-c", "ESC"] -> s
      k when k in ["RET", "C-j"] -> %{s | buf: shown, pos: String.length(shown)}
      key ->
        case Keys.text(key) do
          nil -> %{s | buf: shown, pos: String.length(shown)}
          t -> history_search(s, query <> t, 0)
        end
    end
  end

  # -- completion -----------------------------------------------------------------------------

  defp complete(s) do
    before = String.slice(s.buf, 0, s.pos)
    {prefix_text, word} =
      case Regex.run(~r/^(.*?)(\S*)$/s, before) do
        [_, p, w] -> {p, w}
      end

    first_word? = String.trim(prefix_text) == "" or String.ends_with?(String.trim_trailing(prefix_text), ["|", ";", "&&", "||"])

    candidates =
      cond do
        s.shell.options[:plain] -> path_candidates(s.shell, word)
        first_word? and not String.contains?(word, "/") -> command_candidates(s.shell, word)
        String.starts_with?(String.trim(prefix_text), "git") and length(String.split(prefix_text)) == 1 -> git_candidates(word)
        true -> path_candidates(s.shell, word)
      end

    case candidates do
      [] ->
        s

      [only] ->
        suffix = if String.ends_with?(only, "/"), do: "", else: " "
        insert(s, String.slice(only, String.length(word)..-1//1) <> suffix)

      many ->
        common = common_prefix(many)

        if String.length(common) > String.length(word) do
          insert(s, String.slice(common, String.length(word)..-1//1))
        else
          if s.tabbed, do: list_candidates(s, many), else: %{s | tabbed: true}
        end
    end
  end

  defp list_candidates(s, many) do
    tty = s.shell.ctx.tty
    width = (many |> Enum.map(&Lepton.Width.string(Path.basename(&1))) |> Enum.max()) + 2
    per_row = max(div(s.cols, width), 1)

    text =
      many
      |> Enum.map(&(&1 |> display_name() |> Lepton.Width.pad(width)))
      |> Enum.chunk_every(per_row)
      |> Enum.map_join("\r\n", &Enum.join/1)

    move_to_end(s)
    out(tty, "\r\n" <> text <> "\r\n")
    %{s | drawn_rows: 0, drawn_cursor_row: 0, tabbed: false}
  end

  defp display_name(path) do
    if String.ends_with?(path, "/"), do: Path.basename(path) <> "/", else: Path.basename(path)
  end

  defp command_candidates(shell, word) do
    (Map.keys(shell.aliases) ++ Lepton.Shell.Builtins.names() ++ Lepton.Commands.names())
    |> Enum.filter(&String.starts_with?(&1, word))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @git_cmds ~w(add branch checkout clone commit config diff fetch init log ls-files merge pull push remote reset restore rm show status switch tag)
  defp git_candidates(word), do: Enum.filter(@git_cmds, &String.starts_with?(&1, word))

  defp path_candidates(shell, word) do
    ctx = shell.ctx
    expanded = Lepton.Ctx.path(ctx, if(word == "", do: ".", else: word))

    {dir, base, shown_dir} =
      if String.ends_with?(word, "/") or word == "" do
        {expanded, "", word}
      else
        {Path.dirname(expanded), Path.basename(word), case Path.dirname(word) do
          "." -> if String.starts_with?(word, "./"), do: "./", else: ""
          # "/" (for "/roo"), and "//": already ends with its slash
          d -> if String.ends_with?(d, "/"), do: d, else: d <> "/"
        end}
      end

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, base))
        |> Enum.reject(&(String.starts_with?(&1, ".") and not String.starts_with?(base, ".")))
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = shown_dir <> name
          if File.dir?(Path.join(dir, name)), do: full <> "/", else: full
        end)

      _ ->
        []
    end
  end

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn s, acc ->
      Enum.zip(String.graphemes(acc), String.graphemes(s))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map_join(fn {a, _} -> a end)
    end)
  end

  # -- $EDITOR ------------------------------------------------------------------------------------

  defp edit_in_editor(s) do
    path = Path.join(System.tmp_dir() || "/tmp", "lsh-edit-#{System.unique_integer([:positive])}.sh")
    File.write!(path, s.buf)
    move_to_end(s)
    out(s.shell.ctx.tty, "\r\n")
    TTY.set_mode(s.shell.ctx.tty, :cooked)
    Lepton.Editor.run([path], s.shell.ctx)
    TTY.set_mode(s.shell.ctx.tty, :raw)
    text = path |> File.read!() |> String.trim_trailing()
    File.rm(path)
    s = %{s | buf: text, pos: String.length(text), drawn_rows: 0, drawn_cursor_row: 0}
    s |> redraw() |> loop()
  end

  # -- drawing --------------------------------------------------------------------------------------

  defp prompt_lines_before_last(prompt) do
    case String.split(prompt, "\n") do
      [_only] -> ""
      lines -> lines |> Enum.drop(-1) |> Enum.join("\r\n") |> Kernel.<>("\r\n")
    end
  end

  defp last_line(prompt), do: prompt |> String.split("\n") |> List.last()

  defp redraw(s) do
    color? = Style.color?(s.shell.ctx)
    sugg = suggestion(s) || ""
    # (plain: not shell commands, psql's SQL for one: no highlighting)
    shown = if s.shell.options[:plain], do: s.buf, else: highlight(s.buf, s.shell, color?)
    line = s.prompt <> shown <> if(color? and sugg != "", do: "\e[38;5;242m" <> sugg <> "\e[0m", else: "")
    draw(s, line, line_widths(s, if(color?, do: Lepton.Width.string(sugg), else: 0)))
  end

  defp draw_raw(s, text), do: draw(s, text, [Style.width(text)])

  # Pasted text: newlines (CR LF or CR, as terminals send them) become the
  # line's own; other control characters are left out.
  defp paste_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/, "")
  end

  # Redraw the input area and place the cursor. The input may wrap, and
  # (pasted) may have lines of its own: `widths` are the visible columns of
  # each of its lines, the prompt's in the first.
  defp draw(s, line, widths) do
    tty = s.shell.ctx.tty
    up = if s.drawn_cursor_row > 0, do: "\e[#{s.drawn_cursor_row}A", else: ""
    last = List.last(widths)
    # Terminals defer wrapping at the last column; force it when needed.
    wrap_fix = if last > 0 and rem(last, s.cols) == 0, do: " \r", else: ""
    rows = Enum.sum(Enum.map(widths, &line_rows(&1, s.cols))) - 1 + if(wrap_fix != "", do: 1, else: 0)
    {crow, ccol} = cursor_at(s, widths)
    down = rows - crow
    move = (if down > 0, do: "\e[#{down}A", else: "") <> "\r" <> if(ccol > 0, do: "\e[#{ccol}C", else: "")
    out(tty, up <> "\r\e[J" <> String.replace(line, "\n", "\r\n") <> wrap_fix <> move)
    %{s | drawn_rows: rows, drawn_cursor_row: crow}
  end

  defp line_rows(width, cols), do: div(max(width - 1, 0), cols) + 1

  # The cursor's row (from the input's first) and column. (Columns, not
  # characters: Chinese, Japanese and Korean take two.)
  defp cursor_at(s, widths) do
    before = String.split(String.slice(s.buf, 0, s.pos), "\n")
    li = length(before) - 1
    col = Lepton.Width.string(List.last(before)) + if(li == 0, do: Style.width(s.prompt), else: 0)
    above = widths |> Enum.take(li) |> Enum.map(&line_rows(&1, s.cols)) |> Enum.sum()
    {above + div(col, s.cols), rem(col, s.cols)}
  end

  # The visible width of each of the input's lines (the prompt's in the first).
  defp line_widths(s, extra) do
    [first | rest] = s.buf |> String.split("\n") |> Enum.map(&Lepton.Width.string/1)
    widths = [first + Style.width(s.prompt) | rest]
    List.update_at(widths, -1, &(&1 + extra))
  end

  defp move_to_end(s) do
    down = s.drawn_rows - s.drawn_cursor_row
    if down > 0, do: out(s.shell.ctx.tty, "\e[#{down}B")
  end

  defp finish(s) do
    # Redraw without the suggestion, then move below the input.
    s = %{s | hist: []}
    s = redraw(%{s | pos: String.length(s.buf)})
    move_to_end(s)
    out(s.shell.ctx.tty, "\r\n")
  end

  # zsh-syntax-highlighting, simplified: every command word (the first, and
  # each after |, ||, && or ;) is green when it exists and red when not.
  @doc false
  def highlight(buf, _shell, false), do: buf

  def highlight(buf, shell, true) do
    case Regex.run(~r/^(\s*)(\S+)(.*)$/s, buf) do
      [_, lead, cmd, rest] -> lead <> command_word(cmd, shell) <> highlight_rest(rest, shell)
      _ -> buf
    end
  end

  defp highlight_rest(rest, shell) do
    Regex.replace(~r/("[^"]*"?|'[^']*'?)|(\s*(?:\|\||&&|\||;)\s*)([^\s|&;]+)?/, rest, fn
      _, q, "", "" when q != "" -> "\e[33m" <> q <> "\e[0m"
      _, "", op, cmd -> "\e[1m" <> op <> "\e[0m" <> if(cmd != "", do: command_word(cmd, shell), else: "")
      whole, _, _, _ -> whole
    end)
  end

  defp command_word(cmd, shell), do: "\e[#{if known?(cmd, shell), do: "32", else: "31"}m" <> cmd <> "\e[0m"

  defp known?(cmd, shell) do
    Map.has_key?(shell.aliases, cmd) or Lepton.Shell.Builtins.builtin?(cmd) or
      match?({:ok, _}, Lepton.Commands.lookup(cmd)) or Lepton.Shell.Exec.find_executable(cmd, shell.ctx) != nil or
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, cmd)
  end

  defp out(tty, data), do: TTY.write(tty, data)
end
