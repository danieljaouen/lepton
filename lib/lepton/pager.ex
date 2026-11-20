defmodule Lepton.Pager do
  @moduledoc "`less`: a full-screen pager with vi/less keys (j k d u f b g G / n N q)."

  alias Lepton.TTY

  def run(ctx, text, name) do
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    TTY.write(tty, "\e[?1049h\e[?25l")

    try do
      loop(%{lines: lines, top: 0, tty: tty, name: name, search: nil, msg: nil})
    after
      TTY.write(tty, "\e[?25h\e[?1049l")
      TTY.set_mode(tty, :cooked)
    end

    0
  end

  defp loop(st) do
    {rows, cols} = TTY.size(st.tty)
    h = rows - 1
    max_top = max(length(st.lines) - h, 0)
    st = %{st | top: st.top |> max(0) |> min(max_top)}
    visible = Enum.slice(st.lines, st.top, h)

    body =
      for i <- 0..(h - 1) do
        line = Enum.at(visible, i)
        text = if line, do: fit(line, cols), else: "~"
        text = if st.search && line, do: highlight(text, st.search), else: text
        ["\e[#{i + 1};1H\e[2K", text, "\e[0m"]
      end

    pct = if length(st.lines) <= h, do: "(END)", else: "#{div((st.top + h) * 100, length(st.lines)) |> min(100)}%"
    status = st.msg || "#{st.name} lines #{st.top + 1}-#{min(st.top + h, length(st.lines))}/#{length(st.lines)} #{pct}"
    TTY.write(st.tty, [body, "\e[#{rows};1H\e[2K\e[7m", String.slice(status, 0, cols - 1), "\e[0m"])
    st = %{st | msg: nil}

    case TTY.read_key(st.tty) do
      k when k in ["q", "Q", "C-c", "ESC"] -> :ok
      k when k in ["j", "RET", "<down>", "C-n", "C-e"] -> loop(%{st | top: st.top + 1})
      k when k in ["k", "<up>", "C-p", "C-y"] -> loop(%{st | top: st.top - 1})
      k when k in ["SPC", "f", "C-f", "<next>", "C-v"] -> loop(%{st | top: st.top + h})
      k when k in ["b", "C-b", "<prior>", "M-v"] -> loop(%{st | top: st.top - h})
      k when k in ["d", "C-d"] -> loop(%{st | top: st.top + div(h, 2)})
      k when k in ["u", "C-u"] -> loop(%{st | top: st.top - div(h, 2)})
      k when k in ["g", "<", "<home>"] -> loop(%{st | top: 0})
      k when k in ["G", ">", "<end>"] -> loop(%{st | top: max_top})
      "/" -> search(st, rows)
      "n" -> loop(find(st, 1))
      "N" -> loop(find(st, -1))
      _ -> loop(st)
    end
  end

  defp search(st, rows) do
    TTY.write(st.tty, "\e[#{rows};1H\e[2K/")
    query = read_query(st.tty, "")

    case query && Regex.compile(query) do
      {:ok, re} -> loop(find(%{st | search: re}, 1, st.top))
      _ -> loop(st)
    end
  end

  defp read_query(tty, acc) do
    case TTY.read_key(tty) do
      "RET" -> acc
      k when k in ["ESC", "C-c", "C-g"] -> nil
      k when k in ["DEL", "C-h"] ->
        acc = String.slice(acc, 0..-2//1)
        TTY.write(tty, "\b \b")
        read_query(tty, acc)

      k ->
        case Lepton.Keys.text(k) do
          nil -> read_query(tty, acc)
          t -> TTY.write(tty, t); read_query(tty, acc <> t)
        end
    end
  end

  # Text with escape sequences (man's bold): cut to `cols` visible
  # characters, and highlight matches only outside the escapes.
  @sgr ~r/\e\[[0-9;]*m/

  @doc false
  def fit(line, cols) do
    if String.length(Lepton.Style.strip(line)) <= cols, do: line, else: cut(Regex.split(@sgr, line, include_captures: true), cols, [])
  end

  defp cut([], _room, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp cut(["\e[" <> _ = esc | rest], room, acc), do: cut(rest, room, [esc | acc])
  defp cut([text | rest], room, acc), do: if(room <= 0, do: cut(rest, 0, acc), else: cut(rest, room - String.length(text), [String.slice(text, 0, room) | acc]))

  @doc false
  def highlight(line, re) do
    @sgr
    |> Regex.split(line, include_captures: true)
    |> Enum.map_join(fn
      "\e[" <> _ = esc -> esc
      text -> Regex.replace(re, text, "\e[7m\\0\e[27m")
    end)
  end

  defp find(%{search: nil} = st, _dir), do: %{st | msg: "No previous search"}
  defp find(st, dir), do: find(st, dir, st.top + dir)

  defp find(st, dir, from) do
    indices = if dir > 0, do: from..(length(st.lines) - 1)//1, else: from..0//-1

    case Enum.find(indices, &Regex.match?(st.search, Lepton.Style.strip(Enum.at(st.lines, &1) || ""))) do
      nil -> %{st | msg: "Pattern not found"}
      i -> %{st | top: i}
    end
  end
end

defmodule Lepton.Top do
  @moduledoc "`top`: live view of Lepton processes and BEAM resource usage."

  alias Lepton.{Proc, Sys, TTY}

  def run(ctx) do
    TTY.set_mode(ctx.tty, :raw)
    TTY.write(ctx.tty, "\e[?1049h\e[?25l")
    :erlang.system_flag(:scheduler_wall_time, true)

    try do
      loop(ctx, :erlang.statistics(:scheduler_wall_time))
    after
      TTY.write(ctx.tty, "\e[?25h\e[?1049l")
      TTY.set_mode(ctx.tty, :cooked)
    end

    0
  end

  defp loop(ctx, prev) do
    now = :erlang.statistics(:scheduler_wall_time)
    util = utilization(prev, now)
    mem = Sys.meminfo()
    {rows, cols} = TTY.size(ctx.tty)

    header = [
      "top - #{trunc(Sys.uptime_seconds())}s up, load average: #{Sys.loadavg()}",
      "Lepton procs: #{length(Proc.list())}   BEAM procs: #{:erlang.system_info(:process_count)}   schedulers: #{System.schedulers_online()}   cpu: #{util}%",
      "Mem: #{div(mem["MemTotal"] || 0, 1024)}k total, #{div(mem["MemAvailable"] || 0, 1024)}k avail   BEAM: #{div(:erlang.memory(:total), 1024)}k",
      "",
      "\e[7m  PID  PPID STAT     MEM(k)  REDUCTIONS  COMMAND" <> String.duplicate(" ", max(cols - 47, 0)) <> "\e[0m"
    ]

    procs =
      for p <- Proc.list() do
        info = Process.info(p.beam, [:memory, :reductions]) || [memory: 0, reductions: 0]
        {p, info[:memory], info[:reductions]}
      end
      |> Enum.sort_by(fn {_, _, r} -> -r end)
      |> Enum.take(rows - length(header) - 1)
      |> Enum.map(fn {p, m, r} ->
        "#{String.pad_leading(to_string(p.pid), 5)} #{String.pad_leading(to_string(p.ppid), 5)} #{String.pad_trailing(if(p.state == :stopped, do: "T", else: "S"), 4)} #{String.pad_leading(to_string(div(m, 1024)), 10)} #{String.pad_leading(to_string(r), 11)}  #{String.slice(p.cmd, 0, cols - 42)}"
      end)

    TTY.write(ctx.tty, ["\e[H\e[2J", Enum.join(header ++ procs, "\r\n")])

    case TTY.read_key(ctx.tty, 2000) do
      k when k in ["q", "C-c", "ESC"] -> :ok
      _ -> loop(ctx, now)
    end
  end

  defp utilization(prev, now) when is_list(prev) and is_list(now) do
    {active, total} =
      Enum.zip(Enum.sort(prev), Enum.sort(now))
      |> Enum.reduce({0, 0}, fn {{_, a0, t0}, {_, a1, t1}}, {a, t} -> {a + a1 - a0, t + t1 - t0} end)

    if total > 0, do: round(active * 100 / total), else: 0
  end

  defp utilization(_, _), do: 0
end

defmodule Lepton.IEx do
  @moduledoc """
  `iex` and `mix` inside Lepton.

  `iex` is a REPL over Elixir's own evaluator that loads `~/.iex.exs`
  first - so the user's `MyIExHelpers` (`sh "ls"`, `~x(ls -la)`) work, and
  here `System.shell/2` runs commands in `lsh`.
  """

  alias Lepton.{Ctx, IO}

  def run(ctx) do
    IO.puts(ctx, "Interactive Elixir (#{System.version()}) - press Ctrl+D or type exit to exit; ~/.iex.exs is loaded")
    binding = []
    env = Code.env_for_eval([])
    {binding, env} = load_dotiex(ctx, binding, env)
    loop(ctx, binding, env, 1, "")
  end

  defp load_dotiex(ctx, binding, env) do
    path = Path.join(Ctx.home(ctx), ".iex.exs")

    case File.read(path) do
      {:ok, code} ->
        # System.shell/2 has no /bin/sh on Lepton: route it through lsh.
        code = String.replace(code, "System.shell(cmd,", "Lepton.IEx.shell(cmd,")

        try do
          {_, binding, env} = Code.eval_quoted_with_env(Code.string_to_quoted!(code), binding, env)
          {binding, env}
        rescue
          e ->
            IO.err(ctx, "error loading ~/.iex.exs: #{Exception.message(e)}")
            {binding, env}
        end

      _ ->
        {binding, env}
    end
  end

  @doc "Stand-in for System.shell/2 that runs commands in lsh."
  def shell(cmd, _opts \\ []) do
    status = Lepton.Shell.run_string(cmd, stdout: Process.group_leader())
    {:ok, status}
  end

  defp loop(ctx, binding, env, n, acc) do
    prompt = if acc == "", do: "iex(#{n})> ", else: "...(#{n})> "
    IO.write(ctx, prompt)

    case IO.read_line(ctx) do
      :eof ->
        IO.puts(ctx, "")
        0

      line ->
        code = acc <> line

        cond do
          String.trim(code) in ["exit", "exit()", "quit"] -> 0
          true ->
            case Code.string_to_quoted(code) do
              {:ok, _} ->
                {binding, env} = eval(ctx, code, binding, env)
                loop(ctx, binding, env, n + 1, "")

              {:error, {_meta, msg, token}} ->
                if incomplete?(msg, token) do
                  loop(ctx, binding, env, n, code)
                else
                  IO.err(ctx, "** (SyntaxError) #{error_text(msg)}#{token}")
                  loop(ctx, binding, env, n + 1, "")
                end
            end
        end
    end
  end

  defp error_text({a, b}), do: "#{a}#{b}"
  defp error_text(msg), do: to_string(msg)

  defp incomplete?(msg, token) do
    text = error_text(msg)
    token == "" or String.contains?(text, ["missing terminator", "incomplete"])
  end

  defp eval(ctx, code, binding, env) do
    Process.group_leader(self(), ctx.stdout)
    {value, binding, env} = Code.eval_quoted_with_env(Code.string_to_quoted!(code), binding, env)
    IO.puts(ctx, inspect(value, pretty: true, syntax_colors: if(Lepton.Style.color?(ctx), do: Elixir.IO.ANSI.syntax_colors(), else: [])))
    {binding, env}
  rescue
    e ->
      IO.err(ctx, Exception.format(:error, e, __STACKTRACE__) |> String.trim_trailing())
      {binding, env}
  catch
    kind, reason ->
      IO.err(ctx, Exception.format(kind, reason, __STACKTRACE__) |> String.trim_trailing())
      {binding, env}
  end

  @doc "Run a mix task in the project at ctx.cwd."
  def mix(args, ctx) do
    if not File.exists?(Path.join(ctx.cwd, "mix.exs")) and List.first(args) not in ["new", "help", nil] do
      IO.err(ctx, "** (Mix) Could not find a Mix.Project, please ensure you are running Mix in a directory containing a mix.exs file")
      1
    else
      parent_cwd = File.cwd!()
      Process.group_leader(self(), ctx.stdout)

      try do
        # Mix relies on the node-wide cwd; Lepton serialises mix runs.
        :global.trans({__MODULE__, :mix}, fn ->
          File.cd!(ctx.cwd)
          Application.ensure_all_started(:mix)
          Mix.start()
          Mix.Task.run(List.first(args) || "help", Enum.drop(args, 1))
        end)

        0
      rescue
        e ->
          IO.err(ctx, "** (Mix) " <> Exception.message(e))
          1
      after
        File.cd(parent_cwd)
      end
    end
  end
end
