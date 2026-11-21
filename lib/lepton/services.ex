defmodule Lepton.Services do
  @moduledoc """
  A small service manager in the spirit of systemd: `svc` (also
  `systemctl`) starts, stops and restarts long-running apps, restarts them
  when they fail, starts enabled ones at boot and keeps their output in a
  log (`svc logs`, `journalctl -u`).

  A service is described by a unit file, `NAME.service`, looked up in

    * `~/.config/lepton/services/` - your own (persists on an installed system)
    * `/etc/lepton/services/` - shipped with Lepton

  (the first match wins, so your file overrides a shipped one;
  `LEPTON_SERVICE_PATH` replaces the list). The format is systemd's:

      [Unit]
      Description=Static web server for ~/public

      [Service]
      ExecStart=httpd -p 8080 ~/public
      Restart=on-failure        # no (default) | on-failure | always
      RestartSec=2              # seconds before a restart (default 1)
      WorkingDirectory=~        # default: home
      Environment=GREETING=hi "NAME=a b"
      TimeoutStopSec=5          # wait before killing on stop (default 5)

  `ExecStart` is an `lsh` command line - pipelines, loops and aliases-free
  scripts all work. Each run is a Lepton process tree under PID 1 (it shows
  in `ps`); stopping a service ends the whole tree. A service that exits
  0 is `inactive`; a non-zero exit or a kill is `failed`. More than 5
  automatic starts within 10 s stops the restarts (`start limit hit`).

  Enabled services (`svc enable`, kept in `/var/lib/lepton/services`)
  start at boot; every service is stopped at power-off. Output lines go to
  `/var/lib/lepton/log/NAME.log` (rotated at 1 MiB) and to followers of
  `svc logs -f`.
  """

  use GenServer

  alias Lepton.Services.{LogDevice, Unit}

  @log_lines 1000
  @log_max 1_048_576
  @start_burst 5
  @start_interval 10_000
  @repo_units Path.expand("../../rootfs/etc/lepton/services", __DIR__)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # -- unit files -----------------------------------------------------------------------

  def unit_dirs do
    case System.get_env("LEPTON_SERVICE_PATH") do
      nil -> [Path.join(home(), ".config/lepton/services"), system_dir()]
      path -> String.split(path, ":", trim: true)
    end
  end

  @doc "Where `svc new`/`svc edit` write units: the first directory searched."
  def user_dir do
    case System.get_env("LEPTON_SERVICE_PATH") do
      nil -> Path.join(home(), ".config/lepton/services")
      _ -> hd(unit_dirs())
    end
  end
  def system_dir, do: if(Lepton.Sys.native?(), do: "/etc/lepton/services", else: @repo_units)
  def home, do: if(Lepton.Sys.native?(), do: "/root", else: System.user_home!())

  @doc "Every service with a unit file, by name."
  def names do
    unit_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.service")))
    |> Enum.map(&Path.basename(&1, ".service"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def unit_path(name) do
    if Unit.valid_name?(name), do: Enum.find_value(unit_dirs(), &(File.exists?(p = Path.join(&1, name <> ".service")) && p))
  end

  # -- enabled set (persists) ------------------------------------------------------------------

  defp enabled_path, do: Lepton.Persist.state_path("services/enabled")

  # The file lists the services enabled, and `-NAME` for a service on by
  # default that was disabled.
  defp enabled_file do
    case File.read(enabled_path()) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  @doc """
  The services that start at boot: those enabled, and the shipped ones on
  by default (an `[Install]` section with `WantedBy=`, as systemd's
  presets enable) unless disabled.
  """
  def enabled do
    lines = enabled_file()
    off = for "-" <> name <- lines, into: MapSet.new(), do: name
    on = for l <- lines, not String.starts_with?(l, "-"), into: MapSet.new(), do: l
    on |> MapSet.union(MapSet.new(defaults())) |> MapSet.difference(off)
  end

  @doc "Shipped services on by default."
  def defaults do
    for path <- Path.wildcard(Path.join(system_dir(), "*.service")),
        name = Path.basename(path, ".service"),
        {:ok, %{wanted_by: w}} <- [Unit.parse(name, path, File.read!(path))],
        w not in [nil, ""],
        do: name
  end

  def enabled?(name), do: MapSet.member?(enabled(), name)

  def set_enabled(name, on?) do
    default? = name in defaults()
    lines = enabled_file() |> Enum.reject(&(&1 in [name, "-" <> name]))

    lines =
      cond do
        on? and default? -> lines
        on? -> lines ++ [name]
        default? -> lines ++ ["-" <> name]
        true -> lines
      end

    File.mkdir_p!(Path.dirname(enabled_path()))
    File.write!(enabled_path(), Enum.map_join(Enum.sort(lines), "", &(&1 <> "\n")))
  end

  # -- API --------------------------------------------------------------------------------------

  def start(name), do: call({:start, name})
  def stop(name), do: call({:stop, name}, :infinity)
  def status(name), do: call({:status, name})
  def list, do: call(:list)
  def follow(name), do: call({:follow, name, self()})

  @doc "Start every enabled service (at boot)."
  def boot do
    for name <- Enum.sort(enabled()) do
      case start(name) do
        {:ok, _} -> :ok
        {:error, e} -> Lepton.Init.say("svc: #{name}: #{e}")
      end
    end

    :ok
  end

  @doc "Stop every running service (at power-off)."
  def stop_all do
    if Process.whereis(__MODULE__) do
      tasks = for %{name: name, state: s} <- list(), s in [:active, :activating], do: Task.async(fn -> stop(name) end)
      Task.await_many(tasks, 15_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The last `n` log lines of a service (this and earlier boots)."
  def logs(name, n) do
    lines =
      for path <- [log_path(name) <> ".1", log_path(name)], {:ok, text} <- [File.read(path)], line <- String.split(text, "\n", trim: true), do: line

    Enum.take(lines, -n)
  end

  def log_path(name), do: Lepton.Persist.state_path("log/#{name}.log")

  defp call(msg, timeout \\ 10_000) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, msg, timeout), else: {:error, "the service manager is not running"}
  end

  # -- server -----------------------------------------------------------------------------------

  @impl true
  def init(_), do: {:ok, %{services: %{}, followers: %{}}}

  @impl true
  def handle_call({:start, name}, _from, st) do
    svc = service(st, name)

    case svc.state do
      :active ->
        {:reply, {:ok, :already_running}, st}

      _ ->
        case Unit.load(name) do
          {:ok, unit} ->
            svc = cancel_timer(svc)
            # A manual start clears the failure state and the start limit.
            svc = run(name, %{svc | unit: unit, starts: [], result: nil}, st)
            {:reply, {:ok, svc.pid}, put(st, name, svc)}

          {:error, e} ->
            {:reply, {:error, e}, st}
        end
    end
  end

  def handle_call({:stop, name}, from, st) do
    svc = service(st, name)

    case svc.state do
      :active ->
        signal_tree(svc.pid, :term)
        timer = Process.send_after(self(), {:stop_timeout, name, svc.ref}, round(svc.unit.timeout_stop_sec * 1000))
        {:noreply, put(st, name, %{svc | stopping: [from | svc.stopping || []], timer: timer})}

      :activating ->
        svc = cancel_timer(svc) |> note("Stopped #{name} (restart cancelled).", st)
        {:reply, :ok, put(st, name, %{svc | state: :inactive})}

      _ ->
        {:reply, {:ok, :not_running}, st}
    end
  end

  def handle_call({:status, name}, _from, st) do
    svc = service(st, name)

    unit =
      case Unit.load(name) do
        {:ok, unit} -> unit
        {:error, e} -> {:error, e}
      end

    {:reply, Map.merge(public(name, svc), %{unit: unit, tail: Enum.take(:queue.to_list(svc.log), -10)}), st}
  end

  def handle_call(:list, _from, st) do
    names = Enum.uniq(names() ++ Map.keys(st.services)) |> Enum.sort()
    {:reply, Enum.map(names, &public(&1, service(st, &1))), st}
  end

  def handle_call({:follow, name, pid}, _from, st) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{st | followers: Map.put(st.followers, ref, {pid, name})}}
  end

  @impl true
  def handle_info({:output, name, pid, data}, st) do
    svc = service(st, name)
    {lines, partial} = split_lines(svc.partial <> data)
    svc = Enum.reduce(lines, %{svc | partial: partial}, &log(&2, "#{name}[#{pid}]", &1, st))
    {:noreply, put(st, name, svc)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, st) do
    case Enum.find(st.services, fn {_, s} -> s.ref == ref end) do
      {name, svc} -> {:noreply, put(st, name, exited(name, svc, reason, st))}
      nil -> {:noreply, %{st | followers: Map.delete(st.followers, ref)}}
    end
  end

  def handle_info({:restart_due, name}, st) do
    svc = service(st, name)

    svc =
      case {svc.state, Unit.load(name)} do
        {:activating, {:ok, unit}} -> run(name, %{svc | unit: unit, timer: nil}, st)
        {:activating, {:error, e}} -> note(%{svc | state: :failed, timer: nil, result: {:error, e}}, "#{name}: #{e}", st)
        _ -> svc
      end

    {:noreply, put(st, name, svc)}
  end

  def handle_info({:stop_timeout, name, ref}, st) do
    svc = service(st, name)

    if svc.state == :active and svc.ref == ref do
      signal_tree(svc.pid, :kill)
      {:noreply, put(st, name, note(svc, "#{name} did not stop within #{svc.unit.timeout_stop_sec}s; killed.", st))}
    else
      {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # -- running ----------------------------------------------------------------------------------

  defp service(st, name) do
    Map.get(st.services, name, %{
      name: name, state: :inactive, unit: nil, pid: nil, ref: nil, since: nil, result: nil, starts: [], restarts: 0,
      log: :queue.new(), partial: "", stopping: nil, timer: nil, dev: nil
    })
  end

  defp put(st, name, svc), do: %{st | services: Map.put(st.services, name, svc)}

  defp run(name, svc, st) do
    unit = svc.unit
    dev = if svc.dev && Process.alive?(svc.dev), do: svc.dev, else: LogDevice.start(self(), name)
    home = home()

    env =
      %{"HOME" => home, "USER" => "root", "PATH" => "/bin", "TERM" => "dumb", "NO_COLOR" => "1", "LEPTON_SERVICE" => name}
      |> Map.merge(unit.environment)

    cwd =
      case unit.working_directory do
        nil -> home
        "~" <> rest -> home <> rest
        dir -> dir
      end

    cmd = unit.exec_start

    # The service's own process (its supervisor, shown as `svc NAME`) runs the command as its child.
    {pid, _beam, ref} =
      Lepton.Proc.spawn("svc " <> name, [ppid: 1, monitor: true], fn pid ->
        send(dev, {:owner, pid})
        status = Lepton.Shell.run_string(cmd, cwd: cwd, env: env, stdin: nil, stdout: dev, stderr: dev, rc: false)
        exit({:shutdown, {:status, status}})
      end)

    now = System.monotonic_time(:millisecond)
    starts = Enum.filter([now | svc.starts], &(now - &1 < @start_interval))
    note(%{svc | state: :active, pid: pid, ref: ref, since: {now, Lepton.Time.erl()}, starts: starts, dev: dev, stopping: nil}, "Started #{name}: #{cmd}", st)
  end

  defp exited(name, svc, reason, st) do
    svc = cancel_timer(svc)
    # Anything the service left behind goes with it.
    signal_tree(svc.pid, :kill)
    svc = flush_partial(name, svc, st)

    result =
      case reason do
        {:shutdown, {:status, n}} -> {:exited, n}
        :normal -> {:exited, 0}
        other -> {:killed, other}
      end

    base = %{svc | pid: nil, ref: nil, result: result, since: {System.monotonic_time(:millisecond), Lepton.Time.erl()}}

    cond do
      svc.stopping ->
        for from <- svc.stopping, do: GenServer.reply(from, :ok)
        note(%{base | state: :inactive, stopping: nil, result: :stopped}, "Stopped #{name}.", st)

      restart?(svc.unit.restart, result) and length(svc.starts) >= @start_burst ->
        note(%{base | state: :failed}, "#{name} #{describe(result)}; start limit hit (#{@start_burst} starts in #{div(@start_interval, 1000)}s) - not restarting", st)

      restart?(svc.unit.restart, result) ->
        delay = round(svc.unit.restart_sec * 1000)
        timer = Process.send_after(self(), {:restart_due, name}, delay)
        note(%{base | state: :activating, timer: timer, restarts: svc.restarts + 1}, "#{name} #{describe(result)}; restarting in #{svc.unit.restart_sec}s", st)

      result == {:exited, 0} ->
        note(%{base | state: :inactive}, "#{name} finished (exit status 0).", st)

      true ->
        note(%{base | state: :failed}, "#{name} #{describe(result)}.", st)
    end
  end

  defp restart?("always", _), do: true
  defp restart?("on-failure", result), do: result != {:exited, 0}
  defp restart?(_, _), do: false

  def describe({:exited, n}), do: "exited with status #{n}"
  def describe({:killed, :killed}), do: "was killed"
  def describe({:killed, :terminated}), do: "was terminated"
  def describe({:killed, reason}), do: "crashed (#{inspect(reason, limit: 5)})"
  def describe({:error, e}), do: e
  def describe(:stopped), do: "stopped"
  def describe(nil), do: ""

  defp cancel_timer(%{timer: nil} = svc), do: svc

  defp cancel_timer(svc) do
    Process.cancel_timer(svc.timer)
    %{svc | timer: nil}
  end

  # The service's process and every descendant (by parent PID).
  defp signal_tree(nil, _sig), do: :ok

  defp signal_tree(pid, sig) do
    procs = Lepton.Proc.list()
    tree = descendants([pid], procs, [pid])
    for p <- Enum.reverse(tree), do: Lepton.Proc.signal(p, sig)
    :ok
  end

  defp descendants([], _procs, acc), do: acc

  defp descendants(parents, procs, acc) do
    kids = for p <- procs, p.ppid in parents, p.pid not in acc, do: p.pid
    descendants(kids, procs, acc ++ kids)
  end

  # -- logging --------------------------------------------------------------------------------------

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp flush_partial(_name, %{partial: ""} = svc, _st), do: svc
  defp flush_partial(name, svc, st), do: log(%{svc | partial: ""}, "#{name}[#{svc.pid}]", svc.partial, st)

  # A line from the manager itself.
  defp note(svc, text, st), do: log(svc, "svc", text, st)

  defp log(svc, source, text, st) do
    line = "#{timestamp()} #{source}: #{String.trim_trailing(text, "\r")}"
    log = :queue.in(line, svc.log)
    log = if :queue.len(log) > @log_lines, do: :queue.drop(log), else: log
    write_log(svc.name, line)
    name = svc.name
    for {_ref, {pid, ^name}} <- st.followers, do: send(pid, {:svc_log, line})
    %{svc | log: log}
  end

  # Best effort: an unwritable log must never take the manager down.
  defp write_log(name, line) do
    path = log_path(name)
    File.mkdir_p(Path.dirname(path))

    case File.stat(path) do
      {:ok, %{size: size}} when size > @log_max -> File.rename(path, path <> ".1")
      _ -> :ok
    end

    File.write(path, line <> "\n", [:append])
  end

  defp timestamp do
    {{_y, mo, d}, {h, mi, s}} = Lepton.Time.erl()
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), mo - 1)
    "#{month} #{String.pad_leading(to_string(d), 2)} #{pad(h)}:#{pad(mi)}:#{pad(s)}"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp public(name, svc) do
    %{
      name: name,
      state: svc.state,
      pid: svc.pid,
      since: svc.since,
      result: svc.result,
      restarts: svc.restarts,
      enabled: enabled?(name),
      description: (svc.unit && svc.unit.description) || description(name),
      path: unit_path(name)
    }
  end

  defp description(name) do
    case Unit.load(name) do
      {:ok, u} -> u.description
      _ -> nil
    end
  end
end

defmodule Lepton.Services.Unit do
  @moduledoc "A parsed `NAME.service` unit file (systemd syntax, the keys in `Lepton.Services`)."

  defstruct [:name, :path, :description, :exec_start, :wanted_by, restart: "no", restart_sec: 1.0, working_directory: nil, environment: %{}, timeout_stop_sec: 5.0, ignored: []]

  @known %{
    {"Unit", "Description"} => :description,
    {"Service", "ExecStart"} => :exec_start,
    {"Service", "Restart"} => :restart,
    {"Service", "RestartSec"} => :restart_sec,
    {"Service", "WorkingDirectory"} => :working_directory,
    {"Service", "Environment"} => :environment,
    {"Service", "TimeoutStopSec"} => :timeout_stop_sec,
    {"Install", "WantedBy"} => :wanted_by
  }

  def valid_name?(name), do: is_binary(name) and String.match?(name, ~r/^[A-Za-z0-9][A-Za-z0-9_.@-]*$/)

  def load(name) do
    name = String.replace_suffix(name, ".service", "")

    cond do
      not valid_name?(name) -> {:error, "invalid service name #{inspect(name)}"}
      path = Lepton.Services.unit_path(name) -> parse(name, path, File.read!(path))
      true -> {:error, "no unit file for #{name} (looked in #{Enum.join(Lepton.Services.unit_dirs(), ", ")})"}
    end
  end

  def parse(name, path, text) do
    text
    |> String.replace(~r/\\\n/, " ")
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({%__MODULE__{name: name, path: path}, nil}, fn {raw, n}, {unit, section} ->
      line = String.trim(raw)

      cond do
        line == "" or String.starts_with?(line, ["#", ";"]) ->
          {:cont, {unit, section}}

        String.match?(line, ~r/^\[[^\]]+\]$/) ->
          {:cont, {unit, String.slice(line, 1..-2//1)}}

        String.contains?(line, "=") ->
          [key, value] = String.split(line, "=", parts: 2)

          case set(unit, section, String.trim(key), String.trim(value)) do
            {:ok, unit} -> {:cont, {unit, section}}
            {:error, e} -> {:halt, {:error, "#{Path.basename(path)}:#{n}: #{e}"}}
          end

        true ->
          {:halt, {:error, "#{Path.basename(path)}:#{n}: expected KEY=VALUE or [Section]"}}
      end
    end)
    |> case do
      {:error, _} = e -> e
      {%{exec_start: nil}, _} -> {:error, "#{Path.basename(path)}: ExecStart= is required"}
      {unit, _} -> {:ok, unit}
    end
  end

  defp set(unit, section, key, value) do
    case @known[{section, key}] do
      nil -> {:ok, %{unit | ignored: unit.ignored ++ ["#{section}.#{key}"]}}
      :restart when value not in ["no", "on-failure", "always"] -> {:error, "Restart= must be no, on-failure or always"}
      field when field in [:restart_sec, :timeout_stop_sec] -> seconds(value) |> then(fn
          {:ok, s} -> {:ok, Map.put(unit, field, s)}
          :error -> {:error, "#{key}= must be a number of seconds"}
        end)
      :environment -> environment(unit, value)
      :exec_start when value == "" -> {:error, "ExecStart= is empty"}
      field -> {:ok, Map.put(unit, field, value)}
    end
  end

  defp seconds(value) do
    case Float.parse(String.trim_trailing(value, "s")) do
      {s, ""} when s >= 0 -> {:ok, s}
      _ -> :error
    end
  end

  defp environment(unit, value) do
    pairs = for word <- OptionParser.split(value), [k, v] <- [String.split(word, "=", parts: 2)], do: {k, v}

    if pairs == [] and value != "",
      do: {:error, "Environment= takes KEY=VALUE pairs"},
      else: {:ok, %{unit | environment: Map.merge(unit.environment, Map.new(pairs))}}
  end
end

defmodule Lepton.Services.LogDevice do
  @moduledoc false
  # An Erlang I/O server that forwards a service's stdout/stderr to the
  # service manager, tagged with the service's PID.

  def start(manager, name) do
    spawn_link(fn -> loop(manager, name, nil) end)
  end

  defp loop(manager, name, pid) do
    receive do
      {:owner, pid} ->
        loop(manager, name, pid)

      {:io_request, from, ref, req} ->
        {reply, out} = request(req)
        if out != "", do: send(manager, {:output, name, pid, out})
        send(from, {:io_reply, ref, reply})
        loop(manager, name, pid)

      _ ->
        loop(manager, name, pid)
    end
  end

  defp request({:put_chars, _enc, chars}), do: {:ok, IO.chardata_to_string(chars)}
  defp request({:put_chars, _enc, m, f, a}), do: {:ok, IO.chardata_to_string(apply(m, f, a))}

  defp request({:requests, reqs}) do
    Enum.reduce(reqs, {:ok, ""}, fn r, {_, acc} ->
      {reply, out} = request(r)
      {reply, acc <> out}
    end)
  end

  defp request({:get_chars, _, _, _}), do: {:eof, ""}
  defp request({:get_line, _, _}), do: {:eof, ""}
  defp request({:get_until, _, _, _, _, _}), do: {:eof, ""}
  defp request({:getopts}), do: {{:ok, [binary: true, encoding: :unicode]}, ""}
  defp request({:setopts, _}), do: {:ok, ""}
  defp request(_), do: {{:error, :request}, ""}
end
