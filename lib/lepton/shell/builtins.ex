defmodule Lepton.Shell.Builtins do
  @moduledoc "Shell builtins: commands that run inside the shell and may change its state."

  alias Lepton.{Ctx, IO}
  alias Lepton.Shell
  alias Lepton.Shell.Exec

  @builtins ~w(cd pwd export unset alias unalias history exit logout source . jobs fg bg wait
               type which read eval shift set setopt unsetopt bindkey hash rehash umask local
               dirs pushd popd exec builtin command return break continue)

  def builtin?(name), do: name in @builtins
  def names, do: @builtins

  def run(name, args, shell) do
    do_run(name, args, shell)
  rescue
    e ->
      IO.write(shell.ctx.stderr, "#{name}: #{Exception.message(e)}\n")
      {1, shell}
  end

  defp do_run("cd", args, shell) do
    ctx = shell.ctx

    target =
      case args do
        [] -> Ctx.home(ctx)
        ["-"] -> Map.get(ctx.env, "OLDPWD", ctx.cwd)
        [dir | _] -> Ctx.path(ctx, dir)
      end

    cond do
      File.dir?(target) ->
        if args == ["-"], do: IO.puts(ctx, Ctx.tildify(ctx, target))
        env = ctx.env |> Map.put("OLDPWD", ctx.cwd) |> Map.put("PWD", target)
        {0, %{shell | ctx: %{ctx | cwd: target, env: env}}}

      File.exists?(target) ->
        IO.err(ctx, "cd: not a directory: #{hd(args)}")
        {1, shell}

      true ->
        IO.err(ctx, "cd: no such file or directory: #{hd(args)}")
        {1, shell}
    end
  end

  defp do_run("pwd", _args, shell) do
    IO.puts(shell.ctx, shell.ctx.cwd)
    {0, shell}
  end

  defp do_run(cmd, [], shell) when cmd in ["export", "set"] do
    for {k, v} <- Enum.sort(shell.ctx.env), do: IO.puts(shell.ctx, "#{k}=#{v}")
    {0, shell}
  end

  defp do_run(cmd, args, shell) when cmd in ["export", "local"] do
    env =
      Enum.reduce(args, shell.ctx.env, fn arg, env ->
        case String.split(arg, "=", parts: 2) do
          [k, v] -> Map.put(env, k, v)
          [k] -> Map.put_new(env, k, "")
        end
      end)

    {0, put_in(shell.ctx.env, env)}
  end

  defp do_run("set", ["-o" | _], shell) do
    for {k, v} <- Enum.sort(shell.options), do: IO.puts(shell.ctx, "#{String.pad_trailing(k, 24)}#{if v, do: "on", else: "off"}")
    {0, shell}
  end

  defp do_run("set", ["--" | args], shell), do: {0, %{shell | positional: args}}
  defp do_run("set", args, shell), do: {0, %{shell | positional: args}}

  defp do_run("unset", args, shell), do: {0, put_in(shell.ctx.env, Map.drop(shell.ctx.env, args))}

  defp do_run("alias", [], shell) do
    for {k, v} <- Enum.sort(shell.aliases), do: IO.puts(shell.ctx, "#{k}='#{v}'")
    {0, shell}
  end

  defp do_run("alias", args, shell) do
    Enum.reduce(args, {0, shell}, fn arg, {status, shell} ->
      case String.split(arg, "=", parts: 2) do
        [k, v] ->
          {status, %{shell | aliases: Map.put(shell.aliases, k, v)}}

        [k] ->
          case Map.fetch(shell.aliases, k) do
            {:ok, v} ->
              IO.puts(shell.ctx, "#{k}='#{v}'")
              {status, shell}

            :error ->
              IO.err(shell.ctx, "alias: #{k}: not found")
              {1, shell}
          end
      end
    end)
  end

  defp do_run("unalias", ["-a"], shell), do: {0, %{shell | aliases: %{}}}
  defp do_run("unalias", args, shell), do: {0, %{shell | aliases: Map.drop(shell.aliases, args)}}

  defp do_run("history", args, shell) do
    entries = shell.history |> Enum.reverse() |> Enum.with_index(1)

    entries =
      case args do
        [n | _] ->
          case Integer.parse(n) do
            {n, ""} -> Enum.take(entries, -n)
            _ -> entries
          end

        [] ->
          entries
      end

    for {line, i} <- entries, do: IO.puts(shell.ctx, "#{String.pad_leading(to_string(i), 5)}  #{line}")
    {0, shell}
  end

  defp do_run(cmd, args, shell) when cmd in ["exit", "logout"] do
    status =
      case args do
        [n | _] -> String.to_integer(n)
        [] -> shell.status
      end

    {status, %{shell | exit: status}}
  end

  defp do_run(cmd, [file | args], shell) when cmd in ["source", "."] do
    path = Ctx.path(shell.ctx, file)

    case File.read(path) do
      {:ok, src} ->
        saved = shell.positional
        shell = Shell.eval(src, %{shell | positional: args})
        {shell.status, %{shell | positional: saved}}

      {:error, reason} ->
        IO.err(shell.ctx, "#{cmd}: #{file}: #{:file.format_error(reason)}")
        {1, shell}
    end
  end

  defp do_run("jobs", _args, shell) do
    for {id, job} <- Enum.sort(shell.jobs) do
      state = if job.state == :stopped, do: "Stopped", else: "Running"
      IO.puts(shell.ctx, "[#{id}]  #{String.pad_trailing(state, 10)} #{job.cmd}")
    end

    {0, shell}
  end

  defp do_run("fg", args, shell) do
    case pick_job(args, shell) do
      nil ->
        IO.err(shell.ctx, "fg: no current job")
        {1, shell}

      {id, job} ->
        IO.puts(shell.ctx, job.cmd)
        shell = %{shell | jobs: Map.delete(shell.jobs, id)}
        shell = Exec.resume(job, shell)
        {shell.status, shell}
    end
  end

  defp do_run("bg", args, shell) do
    case pick_job(args, shell) do
      nil ->
        IO.err(shell.ctx, "bg: no current job")
        {1, shell}

      {id, job} ->
        IO.puts(shell.ctx, "[#{id}]+ #{job.cmd} &")
        {0, %{shell | jobs: Map.put(shell.jobs, id, Exec.resume_bg(job))}}
    end
  end

  defp do_run("wait", _args, shell) do
    shell =
      Enum.reduce(shell.jobs, shell, fn {id, job}, shell ->
        shell = Exec.wait(Map.drop(job, [:id, :state]), %{shell | jobs: Map.delete(shell.jobs, id)})
        shell
      end)

    {0, shell}
  end

  defp do_run(cmd, names, shell) when cmd in ["type", "which"] do
    statuses =
      for name <- names do
        cond do
          Map.has_key?(shell.aliases, name) ->
            IO.puts(shell.ctx, if(cmd == "which", do: "#{name}: aliased to #{shell.aliases[name]}", else: "#{name} is an alias for #{shell.aliases[name]}"))
            0

          builtin?(name) ->
            IO.puts(shell.ctx, if(cmd == "which", do: "#{name}: shell built-in command", else: "#{name} is a shell builtin"))
            0

          match?({:ok, _}, Lepton.Commands.lookup(name)) ->
            {:ok, %{fun: fun}} = Lepton.Commands.lookup(name)
            where = case fun do
              {mod, _} -> inspect(mod)
              _ -> "runtime"
            end
            IO.puts(shell.ctx, if(cmd == "which", do: "/bin/#{name}", else: "#{name} is /bin/#{name} (#{where})"))
            0

          path = Exec.find_executable(name, shell.ctx) ->
            IO.puts(shell.ctx, path)
            0

          true ->
            IO.err(shell.ctx, "#{name} not found")
            1
        end
      end

    {Enum.max([0 | statuses]), shell}
  end

  defp do_run("read", args, shell) do
    {opts, names} = Lepton.Args.getopt(args, "p:r")
    if prompt = opts["p"], do: IO.write(shell.ctx.stderr, prompt)

    case IO.read_line(shell.ctx.stdin) do
      :eof ->
        {1, shell}

      line ->
        line = String.trim_trailing(line, "\n")
        names = if names == [], do: ["REPLY"], else: names
        {first, [last]} = Enum.split(names, -1)
        fields = String.split(line, ~r/\s+/, trim: true, parts: length(names))
        values = fields ++ List.duplicate("", max(length(names) - length(fields), 0))
        env = Enum.zip(first ++ [last], values) |> Enum.into(shell.ctx.env)
        {0, put_in(shell.ctx.env, env)}
    end
  end

  defp do_run("eval", args, shell) do
    shell = Shell.eval(Enum.join(args, " "), shell)
    {shell.status, shell}
  end

  defp do_run("shift", args, shell) do
    n = case args do
      [n | _] -> String.to_integer(n)
      [] -> 1
    end

    {0, %{shell | positional: Enum.drop(shell.positional, n)}}
  end

  defp do_run(cmd, args, shell) when cmd in ["setopt", "unsetopt"] do
    value = cmd == "setopt"
    options = Enum.reduce(args, shell.options, &Map.put(&2, String.downcase(&1), value))
    {0, %{shell | options: options}}
  end

  defp do_run("bindkey", _args, shell) do
    for {key, action} <- Lepton.Shell.LineEditor.bindings() do
      IO.puts(shell.ctx, "#{inspect(key)} #{action}")
    end

    {0, shell}
  end

  defp do_run(cmd, _args, shell) when cmd in ["hash", "rehash", "umask", "return"], do: {0, shell}

  defp do_run(cmd, args, shell) when cmd in ["break", "continue"] do
    levels =
      case args do
        [] -> 1
        [n | _] -> String.to_integer(n)
      end

    cond do
      levels < 1 ->
        IO.err(shell.ctx, "#{cmd}: loop count must be at least 1")
        {1, shell}

      shell.loop_depth == 0 ->
        IO.err(shell.ctx, "#{cmd}: only meaningful in a for, while or until loop")
        {0, shell}

      true ->
        {0, %{shell | loop_ctl: {String.to_atom(cmd), min(levels, shell.loop_depth)}}}
    end
  end

  defp do_run("dirs", _args, shell) do
    IO.puts(shell.ctx, Enum.map_join([shell.ctx.cwd | shell.dirstack], " ", &Ctx.tildify(shell.ctx, &1)))
    {0, shell}
  end

  defp do_run("pushd", [dir | _], shell) do
    old = shell.ctx.cwd

    case do_run("cd", [dir], shell) do
      {0, shell} ->
        shell = %{shell | dirstack: [old | shell.dirstack]}
        do_run("dirs", [], shell)

      other ->
        other
    end
  end

  defp do_run("popd", _args, shell) do
    case shell.dirstack do
      [dir | rest] ->
        {status, shell} = do_run("cd", [dir], %{shell | dirstack: rest})
        {status, shell}

      [] ->
        IO.err(shell.ctx, "popd: directory stack empty")
        {1, shell}
    end
  end

  # `builtin NAME` runs the OS image's own command even when an official
  # update (lpm upgrade) stands in for it.
  defp do_run("builtin", [name | args], shell), do: {Exec.exec_builtin(name, args, shell), shell}

  defp do_run(cmd, [name | args], shell) when cmd in ["exec", "command"] do
    {Exec.exec(name, args, shell), shell}
  end

  defp do_run(cmd, [], shell) when cmd in ["exec", "builtin", "command"], do: {0, shell}

  defp pick_job([], shell) do
    case Enum.max_by(shell.jobs, fn {id, _} -> id end, fn -> nil end) do
      nil -> nil
      found -> found
    end
  end

  defp pick_job(["%" <> n | _], shell), do: pick_job([n], shell)

  defp pick_job([n | _], shell) do
    case Integer.parse(n) do
      {id, ""} -> if job = shell.jobs[id], do: {id, job}
      _ -> nil
    end
  end
end
