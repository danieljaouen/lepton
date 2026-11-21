defmodule Lepton.Shell do
  @moduledoc """
  `lsh`, the Lepton shell.

  A POSIX-flavoured shell whose interactive behaviour follows the user's
  zsh setup: oh-my-zsh's emacs line editing (`bindkey -e`), history
  autosuggestions and syntax highlighting, aliases imported from
  `~/.zshrc`, and a starship-style prompt configured by
  `~/.config/starship.toml`.

  Startup files, in order: `/etc/lshrc`, `~/.zshrc` (imported, see
  `Lepton.Shell.Zshrc`), `~/.lshrc`.
  """

  alias Lepton.{Ctx, Pipe}
  alias Lepton.Shell.{Exec, LineEditor, Parser, Prompt, Zshrc}

  defstruct ctx: nil,
            aliases: %{},
            status: 0,
            jobs: %{},
            next_job: 1,
            last_bg: nil,
            positional: [],
            name: "lsh",
            started: 0,
            exit: nil,
            interrupted: false,
            history: [],
            options: %{},
            interactive: false,
            dirstack: [],
            last_command: nil,
            command_started: nil,
            last_duration: 0,
            # break/continue: {:break | :continue, levels} while unwinding loops
            loop_ctl: nil,
            loop_depth: 0

  @history_file ".lsh_history"
  @history_limit 10_000

  def new(ctx, opts \\ []) do
    %__MODULE__{
      ctx: ctx,
      started: System.monotonic_time(:millisecond),
      interactive: Keyword.get(opts, :interactive, false),
      positional: Keyword.get(opts, :args, []),
      name: Keyword.get(opts, :name, "lsh")
    }
  end

  # -- interactive -------------------------------------------------------------------

  @doc "Run an interactive login shell on `ctx.tty` until it exits."
  def login(ctx) do
    pid = Lepton.Proc.register(self(), "-lsh", tty: ctx.tty)
    ctx = %{ctx | pid: pid}
    shell = new(ctx, interactive: true) |> load_rc() |> load_history()
    repl(shell)
  end

  @doc "An interactive (non-login) shell, e.g. inside a multiplexer pane."
  def interactive(ctx) do
    shell = new(ctx, interactive: true) |> load_rc() |> load_history()
    repl(shell)
  end

  defp repl(shell) do
    {notices, shell} = Exec.reap(shell)
    Enum.each(notices, &Lepton.IO.puts(shell.ctx.stderr, &1))
    flush_signals()

    case read_command(shell, Prompt.render(shell), "") do
      :eof ->
        if map_size(shell.jobs) > 0 and not shell.options["warned_jobs"] do
          Lepton.IO.puts(shell.ctx.stderr, "lsh: you have suspended jobs.")
          repl(put_in(shell.options["warned_jobs"], true))
        else
          shell.status
        end

      {:ok, "", shell} ->
        repl(shell)

      {:ok, src, shell} ->
        shell = remember(shell, src)
        t0 = System.monotonic_time(:millisecond)
        shell = eval(src, %{shell | interrupted: false})
        shell = %{shell | last_duration: System.monotonic_time(:millisecond) - t0}
        if shell.exit, do: shell.exit, else: repl(shell)
    end
  end

  # Reads a complete command, prompting with PS2 while the input is incomplete.
  defp read_command(shell, prompt, acc) do
    case LineEditor.read(shell, prompt) do
      :eof when acc == "" ->
        :eof

      :eof ->
        {:ok, "", shell}

      :cancel ->
        {:ok, "", %{shell | status: 130}}

      {:ok, line} ->
        line = expand_history(line, shell)
        src = if acc == "", do: line, else: acc <> "\n" <> line

        case Parser.parse(src, shell.aliases) do
          {:error, :incomplete} -> read_command(shell, Prompt.continuation(), src)
          _ -> {:ok, String.trim(src), shell}
        end
    end
  end

  defp flush_signals do
    receive do
      {:signal, _} -> flush_signals()
    after
      0 -> :ok
    end
  end

  @doc "Expand `!!`, `!$` and `!N` history references."
  def expand_history(line, shell) do
    if String.contains?(line, "!") and shell.history != [] do
      [last | _] = shell.history

      line
      |> String.replace("!!", last)
      |> String.replace("!$", last |> String.split() |> List.last() || "")
      |> then(fn l ->
        Regex.replace(~r/!(\d+)/, l, fn whole, n ->
          Enum.at(Enum.reverse(shell.history), String.to_integer(n) - 1) || whole
        end)
      end)
    else
      line
    end
  end

  # -- evaluation ----------------------------------------------------------------------

  @doc "Parse and run `src` in `shell`; returns the updated shell."
  def eval(src, shell) do
    case Parser.parse(src, shell.aliases) do
      {:ok, ast} ->
        try do
          Exec.run(ast, shell)
        rescue
          e ->
            Lepton.IO.write(shell.ctx.stderr, "lsh: #{Exception.message(e)}\n")
            %{shell | status: 1}
        end

      {:error, :incomplete} ->
        Lepton.IO.write(shell.ctx.stderr, "lsh: unexpected end of input\n")
        %{shell | status: 2}

      {:error, msg} ->
        Lepton.IO.write(shell.ctx.stderr, "lsh: #{msg}\n")
        %{shell | status: 2}
    end
  end

  @doc "Run `src` with stdout captured; returns {output, status}."
  def capture(src, shell) do
    {:ok, pipe} = Pipe.open()
    parent = self()

    reader =
      spawn(fn ->
        Pipe.set_reader(pipe, self())
        send(parent, {:captured, self(), Lepton.IO.read_all(pipe)})
      end)

    result = eval(src, %{shell | ctx: %{shell.ctx | stdout: pipe}, interactive: false})
    Pipe.close_write(pipe)

    receive do
      {:captured, ^reader, out} -> {out, result.status}
    end
  end

  @doc """
  Non-interactive entry point (`lsh -c`, scripts, tests). Options:
  `:cwd`, `:env`, `:stdin`, `:stdout`, `:stderr`, `:args`, `:rc` (load rc files).
  Returns the exit status.
  """
  def run_string(src, opts \\ []) do
    shell = script_shell(opts)
    shell = eval(src, shell)
    shell.exit || shell.status
  end

  @doc "Like run_string/2 but returns {stdout, status}."
  def run_capture(src, opts \\ []) do
    shell = script_shell(opts)
    {out, status} = capture(src, shell)
    {out, status}
  end

  defp script_shell(opts) do
    gl = Process.group_leader()
    stdout = opts[:stdout] || gl

    ctx = %Ctx{
      cwd: opts[:cwd] || default_cwd(),
      env: Map.merge(default_env(), Map.new(opts[:env] || %{})),
      stdin: opts[:stdin],
      stdout: stdout,
      stderr: opts[:stderr] || stdout,
      tty: opts[:tty],
      pid: Lepton.Proc.current(),
      user: opts[:user] || "root"
    }

    shell = new(ctx, args: opts[:args] || [], name: opts[:name] || "lsh")
    if opts[:rc], do: load_rc(shell), else: shell
  end

  defp default_cwd, do: if(File.dir?("/root") and Lepton.Sys.native?(), do: "/root", else: File.cwd!())

  defp default_env do
    %{"HOME" => System.get_env("HOME", "/root"), "PATH" => "/usr/local/bin:/usr/bin:/bin", "USER" => "root"}
  end

  @doc "Run an executable file: Elixir script (`.exs`) or shell script."
  def run_file(path, args, shell) do
    src = File.read!(path)

    cond do
      String.ends_with?(path, ".exs") or String.starts_with?(src, "#!/usr/bin/env elixir") ->
        System.argv(args)
        Code.eval_string(src, [args: args, ctx: shell.ctx], file: path)
        0

      Lepton.Sys.native?() and match?(<<0x7F, "ELF", _::binary>>, src) ->
        Lepton.Commands.System.run_native(path, args, shell.ctx)

      true ->
        sub = %{shell | positional: args, name: path, interactive: false}
        result = eval(src, sub)
        result.exit || result.status
    end
  end

  # -- startup files -----------------------------------------------------------------

  def load_rc(shell) do
    home = Ctx.home(shell.ctx)

    shell
    |> source_if_exists("/etc/lshrc")
    |> Zshrc.import(Path.join(home, ".zshrc"))
    |> source_if_exists(Path.join(home, ".lshrc"))
  end

  defp source_if_exists(shell, path) do
    case File.read(path) do
      {:ok, src} -> %{eval(src, %{shell | interactive: false}) | interactive: shell.interactive, status: 0}
      _ -> shell
    end
  end

  # -- history ---------------------------------------------------------------------------

  defp history_path(shell), do: Path.join(Ctx.home(shell.ctx), @history_file)

  defp load_history(shell) do
    case File.read(history_path(shell)) do
      {:ok, text} -> %{shell | history: text |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.take(@history_limit)}
      _ -> shell
    end
  end

  # inc_append_history: every command is appended as soon as it is entered.
  defp remember(shell, src) do
    if String.starts_with?(src, " ") or match?([^src | _], shell.history) do
      shell
    else
      path = history_path(shell)
      Lepton.Users.own_new(shell.ctx, path, fn -> File.write(path, src <> "\n", [:append]) end)
      %{shell | history: Enum.take([src | shell.history], @history_limit)}
    end
  end

  @doc "Note the command being run (shown by `ps` and used for cmd_duration)."
  def record_command(shell, text), do: %{shell | last_command: text}
end
