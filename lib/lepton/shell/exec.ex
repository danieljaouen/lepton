defmodule Lepton.Shell.Exec do
  @moduledoc """
  Executes parsed `lsh` programs.

  Each command of a pipeline runs as its own Lepton process connected by
  `Lepton.Pipe`s. The shell waits on the job, relaying terminal signals:
  `C-c` kills the job (status 130), `C-z` suspends it with
  `:erlang.suspend_process/1` so `fg`/`bg` can resume it.
  """

  alias Lepton.{Ctx, Pipe, Proc}
  alias Lepton.Shell
  alias Lepton.Shell.{Builtins, Expand}

  # -- lists ---------------------------------------------------------------------

  def run({:list, items}, shell) do
    Enum.reduce_while(items, shell, fn {item, mode}, shell ->
      shell =
        case mode do
          :fg -> run_and_or(item, shell)
          :bg -> background(item, shell)
        end

      if shell.exit || shell.loop_ctl, do: {:halt, shell}, else: {:cont, shell}
    end)
  end

  defp run_and_or({:and_or, first, rest}, shell) do
    shell = run_pipeline(first, shell)

    Enum.reduce(rest, shell, fn
      {:and, p}, shell -> if shell.status == 0 and !shell.exit and !shell.loop_ctl, do: run_pipeline(p, shell), else: shell
      {:or, p}, shell -> if shell.status != 0 and !shell.exit and !shell.loop_ctl, do: run_pipeline(p, shell), else: shell
    end)
  end

  defp run_and_or(pipeline, shell), do: run_pipeline(pipeline, shell)

  # -- pipelines ---------------------------------------------------------------------

  defp run_pipeline({:pipeline, negate, cmds}, shell) do
    shell = do_pipeline(cmds, shell)
    if negate, do: %{shell | status: if(shell.status == 0, do: 1, else: 0)}, else: shell
  end

  # A single builtin or compound command runs in the shell process itself so
  # it can change the shell's state (cd, export, alias, ...).
  defp do_pipeline([cmd], shell) do
    case in_process(cmd, shell) do
      {:ok, shell} -> shell
      :spawn -> spawn_and_wait([cmd], shell)
    end
  end

  defp do_pipeline(cmds, shell), do: spawn_and_wait(cmds, shell)

  defp in_process({:simple, assigns, [], redirs}, shell) do
    # Bare assignments set shell (exported) variables.
    env = Enum.reduce(assigns, shell.ctx.env, fn {k, v}, env -> Map.put(env, k, Expand.string(v, shell)) end)
    shell = put_in(shell.ctx.env, env)
    {:ok, with_redirects(redirs, shell, fn shell -> %{shell | status: 0} end)}
  end

  defp in_process({:simple, assigns, words, redirs}, shell) do
    argv = Expand.words(words, shell)

    case argv do
      [] ->
        {:ok, %{shell | status: 0}}

      [name | args] ->
        if Builtins.builtin?(name) do
          shell = Shell.record_command(shell, Enum.join(argv, " "))

          {:ok,
           with_redirects(redirs, shell, fn shell ->
             # `VAR=x builtin` sets VAR only for the builtin's duration.
             temp = assign_map(assigns, shell)
             saved = shell.ctx.env
             {status, shell} = Builtins.run(name, args, put_in(shell.ctx.env, Map.merge(saved, temp)))
             shell = put_in(shell.ctx.env, restore_env(shell.ctx.env, saved, Map.keys(temp)))
             %{shell | status: status}
           end)}
        else
          :spawn
        end
    end
  end

  defp in_process({:group, body, redirs}, shell), do: {:ok, with_redirects(redirs, shell, &run(body, &1))}

  defp in_process({:if, cond, body, else_body}, shell) do
    shell = run(cond, shell)

    cond do
      shell.exit || shell.loop_ctl -> {:ok, shell}
      shell.status == 0 -> {:ok, run(body, shell)}
      else_body -> {:ok, run(else_body, shell)}
      true -> {:ok, %{shell | status: 0}}
    end
  end

  defp in_process({:for, var, words, body}, shell) do
    items = Expand.words(Enum.map(words, fn {:word, parts} -> parts end), shell)

    shell =
      Enum.reduce_while(items, %{shell | status: 0, loop_depth: shell.loop_depth + 1}, fn item, shell ->
        {next, shell} = after_body(run(body, put_in(shell.ctx.env[var], item)))
        if next == :stop or shell.exit || shell.interrupted, do: {:halt, shell}, else: {:cont, shell}
      end)

    {:ok, %{shell | loop_depth: shell.loop_depth - 1}}
  end

  defp in_process({kind, cond, body}, shell) when kind in [:while, :until] do
    shell = loop(kind, cond, body, %{shell | status: 0, loop_depth: shell.loop_depth + 1}, 0)
    {:ok, %{shell | loop_depth: shell.loop_depth - 1}}
  end

  defp in_process({:subshell, _, _}, _shell), do: :spawn

  defp loop(kind, cond, body, shell, n) do
    {next, result} = after_body(run(cond, shell))
    continue? = if kind == :while, do: result.status == 0, else: result.status != 0

    cond do
      next == :stop -> result
      continue? and !result.exit and !result.interrupted ->
        {next, shell} = after_body(run(body, result))
        if next == :stop, do: shell, else: loop(kind, cond, body, shell, n + 1)

      true ->
        %{result | status: 0}
    end
  end

  # After a loop body: consume a break/continue aimed at this loop, or pass
  # a multi-level one outward. Returns {:next | :stop, shell}.
  defp after_body(%{loop_ctl: nil} = shell), do: {:next, shell}
  defp after_body(%{loop_ctl: {:break, 1}} = shell), do: {:stop, %{shell | loop_ctl: nil}}
  defp after_body(%{loop_ctl: {:continue, 1}} = shell), do: {:next, %{shell | loop_ctl: nil}}
  defp after_body(%{loop_ctl: {kind, n}} = shell), do: {:stop, %{shell | loop_ctl: {kind, n - 1}}}

  defp restore_env(env, saved, keys) do
    Enum.reduce(keys, env, fn k, env ->
      case Map.fetch(saved, k) do
        {:ok, v} -> Map.put(env, k, v)
        :error -> Map.delete(env, k)
      end
    end)
  end

  defp assign_map(assigns, shell), do: Map.new(assigns, fn {k, v} -> {k, Expand.string(v, shell)} end)

  # -- spawning ------------------------------------------------------------------------

  defp spawn_and_wait(cmds, shell) do
    shell = Shell.record_command(shell, describe(cmds))
    job = start_job(cmds, shell)
    wait(job, shell)
  end

  defp background(item, shell) do
    cmds =
      case item do
        {:pipeline, _neg, cmds} -> cmds
        other -> [{:subshell, {:list, [{other, :fg}]}, []}]
      end

    job = start_job(cmds, shell, background: true)
    id = shell.next_job
    job = Map.merge(job, %{id: id, state: :running, cmd: describe(cmds)})
    Lepton.IO.write(shell.ctx.stderr, "[#{id}] #{List.last(job.pids)}\n")

    %{shell | jobs: Map.put(shell.jobs, id, job), next_job: id + 1, last_bg: List.last(job.pids), status: 0}
  end

  @doc "Start every command of a pipeline; returns a job map."
  def start_job(cmds, shell, opts \\ []) do
    n = length(cmds)
    pipes = for _ <- 1..(n - 1)//1, do: elem(Pipe.open(), 1)
    stdin = if opts[:background], do: nil, else: shell.ctx.stdin

    procs =
      cmds
      |> Enum.with_index()
      |> Enum.map(fn {cmd, i} ->
        input = if i == 0, do: stdin, else: Enum.at(pipes, i - 1)
        output = if i == n - 1, do: shell.ctx.stdout, else: Enum.at(pipes, i)
        ctx = %{shell.ctx | stdin: input, stdout: output}
        {pid, beam, ref} = launch(cmd, %{shell | ctx: ctx})
        if i > 0, do: Pipe.set_reader(Enum.at(pipes, i - 1), beam)
        %{pid: pid, beam: beam, ref: ref, writes: if(i < n - 1, do: Enum.at(pipes, i)), index: i}
      end)

    %{procs: procs, pids: Enum.map(procs, & &1.pid), statuses: %{}, cmd: describe(cmds)}
  end

  defp launch(cmd, shell) do
    title = describe([cmd])

    Proc.spawn(title, [tty: shell.ctx.tty, ppid: shell.ctx.pid, monitor: true], fn pid ->
      shell = put_in(shell.ctx.pid, pid)
      if is_pid(shell.ctx.stdout), do: Process.group_leader(self(), shell.ctx.stdout)
      exit({:lsh_status, run_child(cmd, shell)})
    end)
  end

  # Runs inside the child process; returns the exit status.
  defp run_child({:simple, assigns, words, redirs}, shell) do
    argv = Expand.words(words, shell)
    env = Map.merge(shell.ctx.env, assign_map(assigns, shell))
    shell = put_in(shell.ctx.env, env)

    with_redirects(redirs, shell, fn shell ->
      case argv do
        [] -> %{shell | status: 0}
        [name | args] -> %{shell | status: exec(name, args, shell)}
      end
    end).status
  end

  defp run_child({:subshell, body, redirs}, shell) do
    with_redirects(redirs, shell, &run(body, &1)).status
  end

  defp run_child(compound, shell) do
    {:ok, shell} = in_process(compound, shell)
    shell.status
  end

  @doc "Execute a program by name in the current process; returns its status."
  def exec(name, args, shell) do
    ctx = shell.ctx

    cond do
      Builtins.builtin?(name) ->
        {status, _} = Builtins.run(name, args, shell)
        status

      match?({:ok, _}, Lepton.Commands.lookup(name)) ->
        {:ok, cmd} = Lepton.Commands.lookup(name)
        guard(name, ctx, fn -> Lepton.Commands.invoke(cmd, args, ctx) end)

      path = find_executable(name, ctx) ->
        guard(name, ctx, fn -> Shell.run_file(path, args, shell) end)

      true ->
        Lepton.IO.write(ctx.stderr, "lsh: command not found: #{name}\n")
        127
    end
  end

  @doc "Run a shell builtin or the OS image's own command, bypassing packages."
  def exec_builtin(name, args, shell) do
    cond do
      Builtins.builtin?(name) ->
        {status, _} = Builtins.run(name, args, shell)
        status

      match?({:ok, _}, Lepton.Commands.builtin_lookup(name)) ->
        {:ok, cmd} = Lepton.Commands.builtin_lookup(name)
        guard(name, shell.ctx, fn -> Lepton.Commands.invoke(cmd, args, shell.ctx) end)

      true ->
        Lepton.IO.write(shell.ctx.stderr, "builtin: #{name}: not a built-in command\n")
        1
    end
  end

  defp guard(name, ctx, fun) do
    case fun.() do
      status when is_integer(status) -> status
      :ok -> 0
      _ -> 0
    end
  rescue
    e ->
      Lepton.IO.write(ctx.stderr, "#{name}: #{Exception.message(e)}\n")
      1
  end

  def find_executable(name, ctx) do
    candidates =
      if String.contains?(name, "/") do
        [Ctx.path(ctx, name)]
      else
        ctx.env |> Map.get("PATH", "") |> String.split(":", trim: true) |> Enum.map(&Path.join(&1, name))
      end

    Enum.find(candidates, &File.regular?/1)
  end

  # -- waiting ---------------------------------------------------------------------------

  @doc "Wait for a foreground job; returns the updated shell."
  def wait(job, shell) do
    tty = shell.ctx.tty
    if tty, do: safe_fg(tty, self())
    result = wait_loop(job)
    if tty, do: safe_fg(tty, nil)

    case result do
      {:done, status} ->
        %{shell | status: status, interrupted: status == 130}

      {:stopped, job} ->
        id = shell.next_job
        Lepton.IO.write(shell.ctx.stderr, "\n[#{id}]+  Stopped    #{job.cmd}\n")
        job = Map.merge(job, %{id: id, state: :stopped})
        %{shell | status: 148, jobs: Map.put(shell.jobs, id, job), next_job: id + 1}
    end
  end

  defp safe_fg(tty, pid) do
    Lepton.TTY.set_foreground(tty, pid)
  catch
    :exit, _ -> :ok
  end

  defp wait_loop(job) do
    if map_size(job.statuses) == length(job.procs) do
      last = List.last(job.procs)
      {:done, Map.fetch!(job.statuses, last.ref)}
    else
      receive do
        {:DOWN, ref, :process, _beam, reason} ->
          case Enum.find(job.procs, &(&1.ref == ref)) do
            nil ->
              wait_loop(job)

            proc ->
              if proc.writes, do: Pipe.close_write(proc.writes)
              wait_loop(%{job | statuses: Map.put(job.statuses, ref, status_of(reason))})
          end

        {:signal, :int} ->
          for p <- job.procs, not Map.has_key?(job.statuses, p.ref), do: Process.exit(p.beam, :kill)
          drain(job, 130)

        {:signal, :quit} ->
          for p <- job.procs, not Map.has_key?(job.statuses, p.ref), do: Process.exit(p.beam, :kill)
          drain(job, 131)

        {:signal, :tstp} ->
          for p <- job.procs, not Map.has_key?(job.statuses, p.ref) do
            :erlang.suspend_process(p.beam)
            Proc.set_state(p.pid, :stopped)
          end

          {:stopped, job}
      end
    end
  end

  # After killing a job, collect the DOWNs and close pipes.
  defp drain(job, status) do
    for p <- job.procs, not Map.has_key?(job.statuses, p.ref) do
      receive do
        {:DOWN, ref, :process, _, _} when ref == p.ref -> :ok
      after
        1000 -> :ok
      end

      if p.writes, do: Pipe.close_write(p.writes)
    end

    {:done, status}
  end

  @doc "Resume a stopped job in the foreground."
  def resume(job, shell) do
    for p <- job.procs, not Map.has_key?(job.statuses, p.ref) do
      Proc.set_state(p.pid, :running)
      :erlang.resume_process(p.beam)
    end

    wait(Map.drop(job, [:id, :state]), shell)
  end

  @doc "Resume a stopped job in the background."
  def resume_bg(job) do
    for p <- job.procs, not Map.has_key?(job.statuses, p.ref) do
      Proc.set_state(p.pid, :running)
      :erlang.resume_process(p.beam)
    end

    %{job | state: :running}
  end

  def status_of({:lsh_status, s}) when is_integer(s), do: s
  def status_of(:normal), do: 0
  def status_of(:epipe), do: 141
  def status_of(:killed), do: 137
  def status_of(:interrupt), do: 130
  def status_of(:terminated), do: 143
  def status_of(_), do: 1

  @doc "Reap finished background jobs: returns {notices, shell}."
  def reap(shell) do
    {notices, jobs} =
      Enum.reduce(shell.jobs, {[], shell.jobs}, fn {id, job}, {notices, jobs} ->
        job = collect_downs(job)

        if map_size(job.statuses) == length(job.procs) and job.state != :stopped do
          status = Map.fetch!(job.statuses, List.last(job.procs).ref)
          word = if status == 0, do: "Done", else: "Exit #{status}"
          {["[#{id}]+  #{String.pad_trailing(word, 10)} #{job.cmd}" | notices], Map.delete(jobs, id)}
        else
          {notices, Map.put(jobs, id, job)}
        end
      end)

    {Enum.reverse(notices), %{shell | jobs: jobs}}
  end

  defp collect_downs(job) do
    Enum.reduce(job.procs, job, fn p, job ->
      if Map.has_key?(job.statuses, p.ref) do
        job
      else
        receive do
          {:DOWN, ref, :process, _, reason} when ref == p.ref ->
            if p.writes, do: Pipe.close_write(p.writes)
            %{job | statuses: Map.put(job.statuses, p.ref, status_of(reason))}
        after
          0 -> job
        end
      end
    end)
  end

  # -- redirections ------------------------------------------------------------------------

  @doc "Apply redirections around `fun.(shell)`; returns the resulting shell."
  def with_redirects([], shell, fun), do: fun.(shell)

  def with_redirects(redirs, shell, fun) do
    {ctx, opened} =
      Enum.reduce(redirs, {shell.ctx, []}, fn redir, {ctx, opened} ->
        apply_redirect(redir, ctx, opened, shell)
      end)

    case ctx do
      {:error, msg} ->
        Enum.each(opened, &File.close/1)
        Lepton.IO.write(shell.ctx.stderr, "lsh: #{msg}\n")
        %{shell | status: 1}

      ctx ->
        saved = shell.ctx
        result = fun.(%{shell | ctx: ctx})
        Enum.each(opened, &File.close/1)
        # Keep state changes (cwd/env) but restore the original descriptors.
        %{result | ctx: %{result.ctx | stdin: saved.stdin, stdout: saved.stdout, stderr: saved.stderr}}
    end
  end

  defp apply_redirect(_, {:error, _} = err, opened, _shell), do: {err, opened}

  defp apply_redirect({:dup, fd, target}, ctx, opened, _shell) do
    dev = fd_dev(ctx, target)
    {put_fd(ctx, fd, dev), opened}
  end

  defp apply_redirect({:herestring, fd, word}, ctx, opened, shell) do
    {:ok, pipe} = Pipe.open()
    IO.binwrite(pipe, Expand.string(word, shell) <> "\n")
    Pipe.close_write(pipe)
    {put_fd(ctx, fd, pipe), opened}
  end

  defp apply_redirect({kind, fd, word}, ctx, opened, shell) do
    path = Expand.string(word, shell)

    if path == "/dev/null" and kind != :in do
      {put_fd(ctx, fd, null_device()) |> then(&if(kind in [:out_both, :append_both], do: put_fd(&1, 2, null_device()), else: &1)), opened}
    else
      modes =
        case kind do
          :in -> [:read, :binary]
          k when k in [:out, :out_both] -> [:write, :binary]
          k when k in [:append, :append_both] -> [:append, :binary]
        end

      full = Ctx.path(ctx, path)
      allowed = if kind == :in, do: Lepton.Users.check_read(ctx, full), else: Lepton.Users.check_write(ctx, full)

      # A file made by `>` is the user's (Lepton writes it as root).
      open = fn -> File.open(full, modes) end
      case with(:ok <- allowed, do: if(kind == :in, do: open.(), else: Lepton.Users.own_new(ctx, full, open))) do
        {:ok, dev} ->
          ctx = put_fd(ctx, fd, dev)
          ctx = if kind in [:out_both, :append_both], do: put_fd(ctx, 2, dev), else: ctx
          {ctx, [dev | opened]}

        {:error, reason} ->
          {{:error, "#{path}: #{:file.format_error(reason)}"}, opened}
      end
    end
  end

  defp put_fd(ctx, 0, dev), do: %{ctx | stdin: dev}
  defp put_fd(ctx, 1, dev), do: %{ctx | stdout: dev}
  defp put_fd(ctx, 2, dev), do: %{ctx | stderr: dev}
  defp put_fd(ctx, _, _), do: ctx

  defp fd_dev(ctx, 0), do: ctx.stdin
  defp fd_dev(ctx, 1), do: ctx.stdout
  defp fd_dev(ctx, 2), do: ctx.stderr
  defp fd_dev(ctx, _), do: ctx.stdout

  defp null_device do
    case Process.whereis(:lepton_null) do
      nil ->
        pid = spawn(fn -> null_loop() end)

        try do
          Process.register(pid, :lepton_null)
          pid
        rescue
          _ ->
            Process.exit(pid, :kill)
            Process.whereis(:lepton_null)
        end

      pid ->
        pid
    end
  end

  defp null_loop do
    receive do
      {:io_request, from, ref, req} ->
        reply =
          case req do
            {:put_chars, _, _} -> :ok
            {:put_chars, _, _, _, _} -> :ok
            :getopts -> [binary: true]
            {:setopts, _} -> :ok
            _ -> :eof
          end

        send(from, {:io_reply, ref, reply})
    end

    null_loop()
  end

  # -- describing commands (for ps/jobs) ---------------------------------------------------

  def describe(cmds) when is_list(cmds), do: Enum.map_join(cmds, " | ", &describe_one/1)

  defp describe_one({:simple, assigns, words, _}) do
    a = Enum.map(assigns, fn {k, v} -> "#{k}=#{word_text(v)}" end)
    Enum.join(a ++ Enum.map(words, &word_text/1), " ")
  end

  defp describe_one({:subshell, _, _}), do: "( ... )"
  defp describe_one({:group, _, _}), do: "{ ... }"
  defp describe_one(other), do: other |> elem(0) |> to_string()

  defp word_text(parts) do
    Enum.map_join(parts, fn
      {:lit, t} -> t
      {:sq, t} -> "'#{t}'"
      {:dq, ps} -> "\"" <> word_text(ps) <> "\""
      {:var, n} -> "$" <> n
      {:cmd, s} -> "$(" <> s <> ")"
      {:arith, s} -> "$((" <> s <> "))"
      :tilde -> "~"
    end)
  end
end
