defmodule Lepton.Postgres.Psql do
  @moduledoc """
  `psql`: PostgreSQL's own SQL shell, with Lepton's line editor in front.

  Native programs on Lepton get no terminal (Lepton's terminals are its
  own, not the kernel's), so PostgreSQL's `psql` reads its input from a
  pipe, as from a script. Lepton reads each statement with its line
  editor (history, `C-r`, editing keys), sends it to `psql`, and after it
  a `\\echo` of a marker; what `psql` prints up to the marker is the
  statement's output. Everything else (backslash commands, formatting,
  `\\c`, errors) is `psql`'s own.

  A statement is sent when its line ends with `;` (outside quotes), or
  at once for a backslash command. `-c`, `-f`, `-l` and input from a pipe
  or file run `psql` directly.
  """

  alias Lepton.{IO, Postgres}
  alias Lepton.Shell.LineEditor

  @direct ~w(-c --command -f --file -l --list -V --version -? --help)

  def run(args, ctx) do
    cond do
      not Postgres.installed?() ->
        IO.err(ctx, "psql: PostgreSQL isn't installed (sudo postgresql setup)")
        1

      direct?(args) ->
        direct(args, ctx)

      not Lepton.TTY.tty?(ctx.stdin) ->
        # A pipe or a file: psql reads it as a script (from a file: the port has no input of its own).
        piped(args, ctx)

      true ->
        interactive(args, ctx)
    end
  end

  defp direct?(args), do: Enum.any?(args, fn a -> a in @direct or String.starts_with?(a, ["--command=", "--file="]) end)

  @doc "The environment `psql` runs with: PostgreSQL's, as the `postgres` role unless `PGUSER` says otherwise."
  def env(ctx_env) do
    ctx_env
    |> Map.merge(Map.drop(Postgres.env(), ["PGHOST", "PGPORT"]))
    |> Map.put_new("PGHOST", Postgres.socket_dir())
    |> Map.put_new("PGPORT", to_string(Postgres.port()))
    |> Map.put_new("PGUSER", "postgres")
    |> Map.put("PAGER", "")
  end

  defp open(args, ctx) do
    exe = Postgres.bin("psql")
    env = Enum.map(env(ctx.env), fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, cd: ctx.cwd, env: env])
    Lepton.Sys.guard(port)
    port
  end

  defp direct(args, ctx), do: ctx |> then(&open(args, &1)) |> drain(ctx)

  defp piped(args, ctx) do
    tmp = Path.join(System.tmp_dir!(), "psql-#{System.unique_integer([:positive])}.sql")
    File.write!(tmp, read_all(ctx.stdin, []))

    try do
      direct(args ++ ["-f", tmp], ctx)
    after
      File.rm(tmp)
    end
  end

  defp read_all(dev, acc) do
    case IO.read_line(dev) do
      :eof -> Enum.reverse(acc)
      line -> read_all(dev, [line | acc])
    end
  end

  defp drain(port, ctx) do
    receive do
      {^port, {:data, d}} ->
        IO.write(ctx, d)
        drain(port, ctx)

      {^port, {:exit_status, s}} ->
        s
    end
  end

  # -- interactive ----------------------------------------------------------------------------

  defp interactive(args, ctx) do
    port = open(args, ctx)
    st = %{port: port, ctx: ctx, n: 0, db: nil, user: nil}

    # Connected (and to what)? A connection that fails ends psql at once.
    case exchange(st, "") do
      {:ok, st} ->
        IO.puts(ctx, "psql #{Postgres.version() |> to_string() |> String.replace(~r/-r\d+$/, "")}: PostgreSQL's SQL shell. \\? for help, \\q or C-d to quit.")
        shell = %{Lepton.Shell.new(ctx, interactive: true) | history: load_history(ctx), options: %{plain: true}}
        loop(st, shell, "")

      {:exit, status} ->
        status
    end
  end

  defp loop(st, shell, buf) do
    prompt = "#{st.db}#{if buf == "", do: "=", else: continuation(buf)}#{if st.user == "postgres", do: "#", else: ">"} "

    case LineEditor.read(shell, prompt) do
      :eof ->
        quit(st)

      :cancel ->
        loop(st, shell, "")

      {:ok, line} ->
        text = if buf == "", do: line, else: buf <> "\n" <> line
        trimmed = String.trim(text)

        cond do
          trimmed == "" ->
            loop(st, shell, "")

          buf == "" and trimmed in ["\\q", "quit", "exit", "\\quit"] ->
            remember(shell, trimmed)
            quit(st)

          complete?(text) ->
            shell = remember(shell, text)

            case exchange(st, text) do
              {:ok, st} -> loop(st, shell, "")
              {:exit, status} -> status
            end

          true ->
            loop(st, shell, text)
        end
    end
  end

  # psql's continuation prompts: inside a string, or a statement going on.
  defp continuation(buf), do: if(odd_quotes?(buf), do: "'", else: "-")

  @doc false
  # A statement is complete at a `;` that ends a line outside quotes and
  # dollar quotes, or as a backslash command.
  def complete?(text) do
    trimmed = String.trim(text)

    String.starts_with?(trimmed, "\\") or
      (String.ends_with?(trimmed, [";", "\\g", "\\gx"]) and not odd_quotes?(trimmed) and rem(length(String.split(trimmed, "$$")) - 1, 2) == 0)
  end

  defp odd_quotes?(text), do: rem(length(String.split(text, "'")) - 1, 2) == 1

  defp quit(st) do
    Port.command(st.port, "\\q\n")
    receive do
      {port, {:exit_status, s}} when port == st.port -> s
    after
      5000 -> 0
    end
  end

  # Send `text` and a marker; print what psql prints until the marker,
  # which also says the database and role now (\c changes them).
  defp exchange(st, text) do
    n = st.n + 1
    mark = "__LEPTON_PSQL_#{n}__"
    Port.command(st.port, text <> "\n\\echo " <> mark <> " :DBNAME :USER\n")
    read_until(%{st | n: n}, mark, "")
  catch
    :error, :badarg -> {:exit, 2}
  end

  defp read_until(st, mark, partial) do
    receive do
      {port, {:data, d}} when port == st.port ->
        {lines, rest} = split(partial <> d)

        Enum.reduce_while(lines, {:cont, st}, fn line, {:cont, st} ->
          case String.split(line, " ") do
            [^mark, db, user] -> {:halt, {:done, %{st | db: db, user: user}}}
            [^mark | _] -> {:halt, {:done, st}}
            _ -> IO.puts(st.ctx, line); {:cont, {:cont, st}}
          end
        end)
        |> case do
          {:done, st} -> {:ok, st}
          {:cont, st} -> read_until(st, mark, rest)
        end

      {port, {:exit_status, s}} when port == st.port ->
        if partial != "", do: IO.puts(st.ctx, partial)
        {:exit, s}

      # C-c during a statement: psql cancels it (on the server).
      {:signal, :int} ->
        with {:os_pid, pid} <- Port.info(st.port, :os_pid), do: Lepton.Sys.shim("kill", ["-INT", to_string(pid)])
        read_until(st, mark, partial)
    end
  end

  defp split(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  # -- history: ~/.psql_history, one statement a line --------------------------------------------

  defp history_path(ctx), do: Path.join(Lepton.Ctx.home(ctx), ".psql_history")

  defp load_history(ctx) do
    case File.read(history_path(ctx)) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.take(1000)
      _ -> []
    end
  end

  defp remember(shell, text) do
    entry = text |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)
    path = history_path(shell.ctx)
    Lepton.Users.own_new(shell.ctx, path, fn -> File.write(path, entry <> "\n", [:append]) end)
    %{shell | history: [entry | shell.history]}
  end
end
