defmodule Lepton.Mux.Config do
  @moduledoc """
  Reads tmux configuration (`~/.tmux.conf`) into key tables and options.

  Supported directives: `set`/`set-option`/`setw`/`set-window-option`
  (`-g`, `-s`, `-w`), `bind`/`bind-key` (`-r`, `-n`, `-T table`),
  `unbind`/`unbind-key` (`-n`, `-T`, `-a`), `source-file`, `if-shell`
  (the test command runs in lsh - so `uname | grep -q Linux` is true here)
  and `run`/`run-shell` (TPM plugin loading is noted and skipped). Command
  chains joined with `\\;` are kept as one binding.

  Bindings are `%{table => %{key => %{cmd: string, repeat: bool}}}` with
  keys normalized to kbd notation (`^W` -> `C-w`).
  """

  alias Lepton.Keys

  defstruct tables: %{}, options: %{}, plugins: [], log: [], sources: []

  @prefix_defaults [
    {"C-b", "send-prefix"},
    {"!", "break-pane"},
    {"\"", "split-window"},
    {"#", "list-buffers"},
    {"$", "command-prompt -I \"#S\" \"rename-session '%%'\""},
    {"%", "split-window -h"},
    {"&", "confirm-before -p \"kill-window #W? (y/n)\" kill-window"},
    {"'", "command-prompt -p index \"select-window -t ':%%'\""},
    {"(", "switch-client -p"},
    {")", "switch-client -n"},
    {",", "command-prompt -I \"#W\" \"rename-window '%%'\""},
    {"0", "select-window -t :=0"},
    {"1", "select-window -t :=1"},
    {"2", "select-window -t :=2"},
    {"3", "select-window -t :=3"},
    {"4", "select-window -t :=4"},
    {"5", "select-window -t :=5"},
    {"6", "select-window -t :=6"},
    {"7", "select-window -t :=7"},
    {"8", "select-window -t :=8"},
    {"9", "select-window -t :=9"},
    {":", "command-prompt"},
    {";", "last-pane"},
    {"=", "choose-buffer"},
    {"?", "list-keys"},
    {"[", "copy-mode"},
    {"]", "paste-buffer"},
    {"c", "new-window"},
    {"d", "detach-client"},
    {"i", "display-message"},
    {"l", "last-window"},
    {"n", "next-window"},
    {"o", "select-pane -t :.+"},
    {"p", "previous-window"},
    {"q", "display-panes"},
    {"r", "refresh-client"},
    {"s", "choose-tree -s"},
    {"t", "clock-mode"},
    {"w", "choose-tree -w"},
    {"x", "confirm-before -p \"kill-pane #P? (y/n)\" kill-pane"},
    {"z", "resize-pane -Z"},
    {"{", "swap-pane -U"},
    {"}", "swap-pane -D"},
    {"<prior>", "copy-mode -u"},
    {"<up>", "select-pane -U"},
    {"<down>", "select-pane -D"},
    {"<left>", "select-pane -L"},
    {"<right>", "select-pane -R"},
    {"M-1", "select-layout even-horizontal"},
    {"M-2", "select-layout even-vertical"},
    {"M-5", "select-layout tiled"},
    {"SPC", "next-layout"},
    {"C-o", "rotate-window"}
  ]

  @copy_vi_defaults [
    {"h", "send-keys -X cursor-left"},
    {"j", "send-keys -X cursor-down"},
    {"k", "send-keys -X cursor-up"},
    {"l", "send-keys -X cursor-right"},
    {"w", "send-keys -X next-word"},
    {"b", "send-keys -X previous-word"},
    {"e", "send-keys -X next-word-end"},
    {"{", "send-keys -X previous-paragraph"},
    {"}", "send-keys -X next-paragraph"},
    {"0", "send-keys -X start-of-line"},
    {"^", "send-keys -X back-to-indentation"},
    {"$", "send-keys -X end-of-line"},
    {"g", "send-keys -X history-top"},
    {"G", "send-keys -X history-bottom"},
    {"H", "send-keys -X top-line"},
    {"M", "send-keys -X middle-line"},
    {"L", "send-keys -X bottom-line"},
    {"C-u", "send-keys -X halfpage-up"},
    {"C-d", "send-keys -X halfpage-down"},
    {"C-b", "send-keys -X page-up"},
    {"C-f", "send-keys -X page-down"},
    {"<up>", "send-keys -X cursor-up"},
    {"<down>", "send-keys -X cursor-down"},
    {"<left>", "send-keys -X cursor-left"},
    {"<right>", "send-keys -X cursor-right"},
    {"/", "command-prompt -p \"(search down)\" \"send -X search-forward '%%'\""},
    {"?", "command-prompt -p \"(search up)\" \"send -X search-backward '%%'\""},
    {"n", "send-keys -X search-again"},
    {"N", "send-keys -X search-reverse"},
    {"SPC", "send-keys -X begin-selection"},
    {"V", "send-keys -X select-line"},
    {"RET", "send-keys -X copy-selection-and-cancel"},
    {"ESC", "send-keys -X clear-selection"},
    {"q", "send-keys -X cancel"},
    {"C-c", "send-keys -X cancel"}
  ]

  @option_defaults %{
    "prefix" => "C-b",
    "history-limit" => "2000",
    "mode-keys" => "emacs",
    "status" => "on",
    "base-index" => "0",
    "mouse" => "off",
    "repeat-time" => "500",
    "set-titles" => "off",
    "set-titles-string" => "#S: #W",
    "monitor-activity" => "off",
    "visual-activity" => "off",
    "status-left" => "[#S] ",
    "status-right" => "#H %H:%M %d-%b-%y",
    "default-terminal" => "screen"
  }

  def defaults do
    %__MODULE__{
      tables: %{
        "prefix" => Map.new(@prefix_defaults, fn {k, c} -> {k, %{cmd: c, repeat: false}} end),
        "root" => %{},
        "copy-mode-vi" => Map.new(@copy_vi_defaults, fn {k, c} -> {k, %{cmd: c, repeat: false}} end)
      },
      options: @option_defaults
    }
  end

  @doc "Load ~/.tmux.conf (and anything it sources) on top of tmux's defaults."
  def load(home) do
    path = Path.join(home, ".tmux.conf")
    cfg = defaults()
    if File.regular?(path), do: source(cfg, path, home), else: cfg
  end

  def source(cfg, path, home) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> join_continuations()
        |> String.split("\n")
        |> Enum.reduce(%{cfg | sources: cfg.sources ++ [path]}, &apply_line(&2, &1, home))

      {:error, _} ->
        log(cfg, "source-file: cannot read #{path}")
    end
  end

  defp join_continuations(text), do: String.replace(text, "\\\n", " ")

  def apply_line(cfg, line, home) do
    case tokenize(String.trim(line)) do
      [] -> cfg
      [cmd | args] -> apply_command(cfg, cmd, args, home)
    end
  end

  defp apply_command(cfg, cmd, args, _home) when cmd in ["set", "set-option", "setw", "set-window-option"] do
    {_flags, rest} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    case rest do
      ["@" <> _ = opt, value | _] ->
        cfg = put_in(cfg.options[opt], value)
        if opt == "@plugin", do: %{cfg | plugins: cfg.plugins ++ [value]}, else: cfg

      [opt, value | _] ->
        value = if opt == "prefix", do: Keys.normalize(value), else: value
        put_in(cfg.options[opt], value)

      [opt] ->
        put_in(cfg.options[opt], "on")

      _ ->
        cfg
    end
  end

  defp apply_command(cfg, cmd, args, _home) when cmd in ["bind", "bind-key"] do
    {flags, table, rest} = parse_bind_flags(args, MapSet.new(), "prefix")

    case rest do
      [key | command] when command != [] ->
        key = Keys.normalize(key)
        binding = %{cmd: Enum.map_join(command, " ", &requote/1), repeat: MapSet.member?(flags, "r")}
        update_in(cfg.tables, &Map.update(&1, table, %{key => binding}, fn t -> Map.put(t, key, binding) end))

      _ ->
        cfg
    end
  end

  defp apply_command(cfg, cmd, args, _home) when cmd in ["unbind", "unbind-key"] do
    {flags, table, rest} = parse_bind_flags(args, MapSet.new(), "prefix")

    case {MapSet.member?(flags, "a"), rest} do
      {true, _} -> put_in(cfg.tables[table], %{})
      {false, [key | _]} -> update_in(cfg.tables, &Map.update(&1, table, %{}, fn t -> Map.delete(t, Keys.normalize(key)) end))
      _ -> cfg
    end
  end

  defp apply_command(cfg, cmd, [path | _], home) when cmd in ["source", "source-file"] do
    source(cfg, expand(path, home), home)
  end

  defp apply_command(cfg, "if-shell", args, home) do
    {_flags, rest} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    case rest do
      [test, then_cmd | else_cmd] ->
        branch = if shell_true?(test, home), do: then_cmd, else: List.first(else_cmd)
        if branch, do: apply_line(cfg, branch, home), else: cfg

      _ ->
        cfg
    end
  end

  defp apply_command(cfg, cmd, args, _home) when cmd in ["run", "run-shell"] do
    log(cfg, "#{cmd} #{Enum.join(args, " ")}: plugin managers are not run; plugin options are honoured where Lepton supports them")
  end

  defp apply_command(cfg, cmd, _args, _home), do: log(cfg, "ignored: #{cmd}")

  defp parse_bind_flags(["-r" | rest], f, t), do: parse_bind_flags(rest, MapSet.put(f, "r"), t)
  defp parse_bind_flags(["-n" | rest], f, _t), do: parse_bind_flags(rest, MapSet.put(f, "n"), "root")
  defp parse_bind_flags(["-a" | rest], f, t), do: parse_bind_flags(rest, MapSet.put(f, "a"), t)
  defp parse_bind_flags(["-T", table | rest], f, _t), do: parse_bind_flags(rest, f, table)
  defp parse_bind_flags(["-N", _note | rest], f, t), do: parse_bind_flags(rest, f, t)
  defp parse_bind_flags(rest, f, t), do: {f, t, rest}

  defp log(cfg, msg), do: %{cfg | log: cfg.log ++ [msg]}

  defp expand("~/" <> rest, home), do: Path.join(home, rest)
  defp expand(path, _home), do: path

  # if-shell tests run in lsh, so Linux checks are true on Lepton.
  defp shell_true?(test, home) do
    Lepton.Shell.run_string(test, cwd: home, stdout: null_sink(), env: %{"HOME" => home}) == 0
  rescue
    _ -> false
  end

  defp null_sink do
    {:ok, pid} = StringIO.open("")
    pid
  end

  # Re-quote a token that contained spaces so the stored command string
  # can be tokenized again when the binding runs.
  defp requote(";"), do: "\\;"
  defp requote(t), do: if(t == "" or String.contains?(t, [" ", "\"", "'"]), do: "'" <> String.replace(t, "'", "'\\''") <> "'", else: t)

  @doc """
  Tokenize a tmux command line: quotes, backslash escapes, comments, and
  `\\;` / `;` as separate `";"` tokens.
  """
  def tokenize(line), do: tok(String.graphemes(line), "", [], false)

  defp tok([], cur, acc, quoted), do: Enum.reverse(push(cur, acc, quoted))
  defp tok(["#" | _], "", acc, false), do: Enum.reverse(acc)
  defp tok([c | rest], cur, acc, quoted) when c in [" ", "\t"], do: tok(rest, "", push(cur, acc, quoted), false)
  defp tok(["\\", ";" | rest], cur, acc, quoted), do: tok(rest, "", [";" | push(cur, acc, quoted)], false)
  defp tok([";" | rest], "", acc, _), do: tok(rest, "", [";" | acc], false)
  defp tok(["\\", c | rest], cur, acc, _), do: tok(rest, cur <> c, acc, true)

  defp tok([q | rest], cur, acc, _) when q in ["'", "\""] do
    {inner, rest} = Enum.split_while(rest, &(&1 != q))
    tok(Enum.drop(rest, 1), cur <> Enum.join(inner), acc, true)
  end

  defp tok([c | rest], cur, acc, quoted), do: tok(rest, cur <> c, acc, quoted)

  defp push("", acc, false), do: acc
  defp push(cur, acc, _), do: [cur | acc]

  @doc "Split a command string into a list of commands (each a token list)."
  def commands(string) do
    string
    |> tokenize()
    |> Enum.chunk_by(&(&1 == ";"))
    |> Enum.reject(&(&1 == [";"]))
  end
end
