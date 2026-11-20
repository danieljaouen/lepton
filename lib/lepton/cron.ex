defmodule Lepton.Cron do
  @moduledoc """
  cron: run commands at set times, from each account's crontab.

  `crontab` installs a user's table in `/var/lib/lepton/cron/USER` (kept
  on an installed system); `crond`, run by the `cron` service (on by
  default), checks the tables every minute and runs what is due, as the
  table's owner, in their home directory. What the jobs print goes to
  the service's log (`svc logs cron`), each line marked with the user.

  The syntax is Vixie cron's: five fields (minute, hour, day of month,
  month, day of week) with `*`, lists, ranges, steps and names, or one of
  `@reboot @yearly @annually @monthly @weekly @daily @midnight @hourly`;
  `NAME=value` lines set the environment for the lines after them; in a
  command an unescaped `%` is a newline and what follows the first one
  is the command's standard input. When both day fields are restricted,
  a day matching either runs the job. Times are local, in the system's
  time zone (`Lepton.Time`), as `date` shows them.
  """

  alias Lepton.{Persist, Users}

  defmodule Job do
    @moduledoc false
    defstruct [:line, :minute, :hour, :dom, :month, :dow, :command, :input, :reboot, dom_star: true, dow_star: true, env: %{}]
  end

  @fields [{:minute, 0, 59}, {:hour, 0, 23}, {:dom, 1, 31}, {:month, 1, 12}, {:dow, 0, 7}]
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @days ~w(sun mon tue wed thu fri sat)

  @shortcuts %{
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }

  # -- the tables ----------------------------------------------------------------------------

  def dir, do: Persist.state_path("cron")
  def path(user), do: Path.join(dir(), user)

  @doc "A user's installed table, or nil."
  def read(user) do
    case File.read(path(user)) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  @doc "Install `text` as `user`'s table, if it parses. `:ok` or `{:error, [{line, message}]}`."
  def install(user, text) do
    with {:ok, _} <- parse(text) do
      File.mkdir_p!(dir())
      File.chmod(dir(), 0o700)
      File.write!(path(user), text)
      File.chmod(path(user), 0o600)
      :ok
    end
  end

  def remove(user), do: File.rm(path(user))

  @doc "The users who have a table."
  def users do
    case File.ls(dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  # -- parsing --------------------------------------------------------------------------------

  @doc "Parse a table: `{:ok, [job]}` or `{:error, [{line, message}]}`."
  def parse(text) do
    {jobs, errors, _env} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], %{}}, fn {raw, n}, {jobs, errors, env} ->
        line = String.trim(raw)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            {jobs, errors, env}

          m = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/, line) ->
            [_, k, v] = m
            {jobs, errors, Map.put(env, k, unquote_value(v))}

          true ->
            case job(line, n) do
              {:ok, job} -> {[%{job | env: env} | jobs], errors, env}
              {:error, msg} -> {jobs, [{n, msg} | errors], env}
            end
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(jobs)}, else: {:error, Enum.reverse(errors)}
  end

  defp unquote_value(v) do
    case Regex.run(~r/^(["'])(.*)\1$/, v) do
      [_, _, inner] -> inner
      nil -> v
    end
  end

  defp job("@reboot" <> rest, n) do
    with {:ok, {cmd, input}} <- command(rest), do: {:ok, %Job{line: n, reboot: true, command: cmd, input: input}}
  end

  defp job("@" <> _ = line, n) do
    [word | rest] = String.split(line, ~r/\s+/, parts: 2)

    case @shortcuts[String.downcase(word)] do
      nil -> {:error, "unknown schedule #{word} (use @reboot, @yearly, @monthly, @weekly, @daily or @hourly)"}
      spec -> job(spec <> " " <> Enum.join(rest, ""), n)
    end
  end

  defp job(line, n) do
    case String.split(line, ~r/\s+/, parts: 6) do
      [_, _, _, _, _, rest] = parts ->
        specs = Enum.take(parts, 5)

        with {:ok, sets} <- fields(specs),
             {:ok, {cmd, input}} <- command(rest) do
          [minute, hour, dom, month, dow] = sets
          dow = if MapSet.member?(dow, 7), do: dow |> MapSet.delete(7) |> MapSet.put(0), else: dow

          {:ok,
           %Job{line: n, minute: minute, hour: hour, dom: dom, month: month, dow: dow, command: cmd, input: input,
                dom_star: String.starts_with?(Enum.at(specs, 2), "*"), dow_star: String.starts_with?(Enum.at(specs, 4), "*")}}
        end

      _ ->
        {:error, "expected five time fields and a command (minute hour day-of-month month day-of-week command)"}
    end
  end

  defp fields(specs) do
    Enum.zip(specs, @fields)
    |> Enum.reduce_while({:ok, []}, fn {spec, {name, lo, hi}}, {:ok, acc} ->
      case field(spec, name, lo, hi) do
        {:ok, set} -> {:cont, {:ok, acc ++ [set]}}
        {:error, msg} -> {:halt, {:error, "#{label(name)}: #{msg}"}}
      end
    end)
  end

  defp label(:minute), do: "minute"
  defp label(:hour), do: "hour"
  defp label(:dom), do: "day of month"
  defp label(:month), do: "month"
  defp label(:dow), do: "day of week"

  defp field(spec, name, lo, hi) do
    spec
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, set} ->
      case item(String.downcase(item), name, lo, hi) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(set, MapSet.new(values))}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp item(item, name, lo, hi) do
    {range, step} =
      case String.split(item, "/") do
        [r] -> {r, "1"}
        [r, s] -> {r, s}
        _ -> {nil, nil}
      end

    with {:step, {step, ""}} when step > 0 <- {:step, Integer.parse(step || "")},
         {:ok, a, b} <- range(range, name, lo, hi) do
      # `5/10` means 5, 15, 25, ... (to the end of the range).
      b = if not String.contains?(range, "-") and range != "*" and String.contains?(item, "/"), do: hi, else: b
      {:ok, Enum.take_every(a..b//1, step)}
    else
      {:step, _} -> {:error, "bad step in #{inspect(item)}"}
      {:error, _} = e -> e
    end
  end

  defp range(nil, _, _, _), do: {:error, "bad entry"}
  defp range("*", _name, lo, hi), do: {:ok, lo, hi}

  defp range(r, name, lo, hi) do
    case String.split(r, "-") do
      [a] -> with {:ok, v} <- value(a, name, lo, hi), do: {:ok, v, v}
      [a, b] ->
        with {:ok, x} <- value(a, name, lo, hi), {:ok, y} <- value(b, name, lo, hi) do
          if x <= y, do: {:ok, x, y}, else: {:error, "range #{r} goes backwards"}
        end

      _ -> {:error, "bad range #{inspect(r)}"}
    end
  end

  defp value(v, name, lo, hi) do
    names = case name do
      :month -> Enum.with_index(@months, 1)
      :dow -> Enum.with_index(@days)
      _ -> []
    end

    case {Integer.parse(v), List.keyfind(names, String.slice(v, 0, 3), 0)} do
      {{n, ""}, _} when n >= lo and n <= hi -> {:ok, n}
      {{n, ""}, _} -> {:error, "#{n} is out of range (#{lo}-#{hi})"}
      {_, {_, n}} when byte_size(v) == 3 -> {:ok, n}
      _ -> {:error, "#{inspect(v)} is not a number#{if names != [], do: " or a name", else: ""}"}
    end
  end

  # The command; `%` starts its standard input (each further `%` a newline), `\%` is a `%`.
  defp command(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "no command"}
    else
      parts = Regex.split(~r/(?<!\\)%/, text)
      [cmd | input] = Enum.map(parts, &String.replace(&1, "\\%", "%"))
      {:ok, {String.trim(cmd), if(input == [], do: nil, else: Enum.join(input, "\n") <> "\n")}}
    end
  end

  # -- when ------------------------------------------------------------------------------------

  @doc "Is `job` due in the minute of `{{y, m, d}, {h, min, _}}`?"
  def due?(%Job{reboot: true}, _time), do: false

  def due?(job, {{y, mo, d}, {h, mi, _}}) do
    wd = rem(Date.day_of_week(Date.new!(y, mo, d)), 7)
    dom? = MapSet.member?(job.dom, d)
    dow? = MapSet.member?(job.dow, wd)
    day? = if job.dom_star or job.dow_star, do: dom? and dow?, else: dom? or dow?
    MapSet.member?(job.minute, mi) and MapSet.member?(job.hour, h) and MapSet.member?(job.month, mo) and day?
  end

  @doc "The next minute (from `from`, exclusive) when `job` is due, within a year."
  def next(job, from \\ Lepton.Time.erl()) do
    start = from |> NaiveDateTime.from_erl!() |> NaiveDateTime.truncate(:second) |> Map.put(:second, 0) |> NaiveDateTime.add(60)

    Stream.iterate(start, &NaiveDateTime.add(&1, 60))
    |> Stream.take(366 * 24 * 60)
    |> Enum.find(&due?(job, NaiveDateTime.to_erl(&1)))
  end

  # -- running ------------------------------------------------------------------------------------

  @doc """
  Run the jobs due at `time` (or the `@reboot` jobs, with `:reboot`) from
  every table. `log` gets each line to log. Returns the job processes.
  """
  def run_due(time, log, opts \\ []) do
    for user <- users(),
        account = Users.get(user),
        account != nil,
        {:ok, jobs} <- [parse(read(user) || "")],
        job <- jobs,
        if(time == :reboot, do: job.reboot == true, else: due?(job, time)) do
      start(job, account, log, opts)
    end
  end

  defp start(job, account, log, opts) do
    home = if opts[:home], do: opts[:home].(account), else: account.home
    log.("(#{account.name}) CMD (#{job.command})")

    env =
      Map.merge(
        %{"HOME" => home, "USER" => account.name, "LOGNAME" => account.name, "SHELL" => account.shell,
          "PATH" => "/usr/local/bin:/usr/bin:/bin", "LANG" => "C.UTF-8"},
        job.env
      )

    {_pid, beam} =
      Lepton.Proc.spawn(job.command, [], fn _ ->
        {:ok, stdin} = StringIO.open(job.input || "")
        {:ok, out} = StringIO.open("")
        cwd = if File.dir?(home), do: home, else: "/"

        status =
          try do
            Lepton.Shell.run_string(job.command, cwd: cwd, env: env, stdin: stdin, stdout: out, stderr: out, user: account.name)
          catch
            _, _ -> 255
          end

        {_, text} = StringIO.contents(out)
        for line <- String.split(text, "\n", trim: true), do: log.("(#{account.name}) #{line}")
        if status != 0, do: log.("(#{account.name}) exited with status #{status}: #{job.command}")
      end)

    beam
  end

  # -- the daemon (crond) -----------------------------------------------------------------------

  @reboot_marker "/run/crond.reboot"

  @doc """
  `crond`: run the `@reboot` jobs (once per boot), then, at the start of
  every minute, the jobs due. Minutes missed (the machine was busy or
  asleep) are caught up, up to five. Stops on a terminate signal.
  """
  def daemon(log) do
    if File.dir?("/run") and not File.exists?(@reboot_marker) do
      File.write(@reboot_marker, "")
      run_due(:reboot, log)
    end

    log.("crond started; #{length(users())} crontab(s); local time zone #{Lepton.Time.zone()}")
    tick(log, minute())
  end

  # Minutes are counted in UTC; each is matched in local time (the zone may
  # change while crond runs).
  defp minute, do: div(System.os_time(:second), 60)

  defp tick(log, last) do
    wait = 60_000 - rem(System.os_time(:millisecond), 60_000) + 50

    receive do
      {:signal, sig} when sig in [:term, :int] -> 0
    after
      wait ->
        current = minute()
        missed = current - last

        for m <- max(last + 1, current - 4)..current//1 do
          run_due(Lepton.Time.erl(m * 60), log)
        end

        tick(log, if(missed > 0, do: current, else: last))
    end
  end
end
