defmodule Lepton.Postgres do
  @moduledoc """
  PostgreSQL: the database server Phoenix apps (Ecto) use by default.

  The server is Alpine's PostgreSQL, installed as an app (`Lepton.Apps`,
  `postgresql`: `sudo postgresql setup` installs it, creates the database
  cluster and starts the `postgresql` service). It runs as the `postgres`
  system account (user ID 70, as on Alpine: PostgreSQL refuses to run as
  root), through `Lepton.RunAs`.

    * The cluster is in `/var/lib/lepton/postgresql/18` (on the data
      partition of an installed system), UTF-8 with the `C.UTF-8` locale.
    * It listens on `localhost:5432` (this machine only) and on the socket
      in `/run/postgresql`.
    * Through the socket, anyone on this machine may connect (`trust`):
      Lepton's accounts are not a boundary there (see `Lepton.Users`). Over
      TCP a password is needed: the `postgres` role's is `postgres`, what
      a new Phoenix app's `config/dev.exs` uses.

  This GenServer owns the server's OS process, not the service's Lepton
  process: when the service stops (or its process dies any way at all),
  the server gets a fast shutdown (SIGINT: transactions rolled back,
  everything written) rather than being orphaned, and a power-off waits
  for it (`await_stopped/1`).
  """

  use GenServer

  alias Lepton.{Apps, Persist}

  @app "postgresql"
  @major "18"
  @uid 70
  @gid 70
  @port 5432
  @socket_dir "/run/postgresql"
  @password "postgres"
  # PostgreSQL's own programs, put on PATH (/usr/local/bin) once installed.
  # (psql is Lepton's, in front of PostgreSQL's: see Lepton.Commands.Services.)
  @tools ~w(createdb dropdb createuser dropuser pg_dump pg_dumpall pg_restore pg_isready vacuumdb reindexdb clusterdb pgbench pg_basebackup pg_controldata)
  @tool_dir "/usr/local/bin"

  def app, do: @app
  def major, do: @major
  def port, do: @port
  def socket_dir, do: @socket_dir
  def default_password, do: @password
  def tools, do: @tools

  def installed?, do: Apps.installed?(@app)
  def version, do: Apps.version(@app)

  def prefix, do: Apps.dir(@app)
  def bindir(prefix \\ prefix()), do: Path.join(prefix, "usr/libexec/postgresql#{@major}")
  def bin(name), do: Path.join(bindir(), name)
  def data_dir, do: Persist.state_path("postgresql/#{@major}")
  def initialized?, do: File.exists?(Path.join(data_dir(), "PG_VERSION"))

  @doc "The `postgres` system account, as `Lepton.RunAs` takes it."
  def user, do: %Lepton.Users{name: "postgres", uid: @uid, gid: @gid, gecos: "PostgreSQL", home: Persist.state_path("postgresql"), shell: "/bin/false"}

  @doc "The environment PostgreSQL's programs run with."
  def env(prefix \\ prefix()) do
    # ICU's data (collations) is in the app, not where ICU looks by default.
    icu = Path.wildcard(Path.join(prefix, "usr/share/icu/*")) |> List.first()

    %{
      "LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(prefix, &1)),
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "PGHOST" => @socket_dir,
      "PGPORT" => to_string(@port)
    }
    |> then(&if(icu, do: Map.put(&1, "ICU_DATA", icu), else: &1))
  end

  # -- setup ------------------------------------------------------------------------------------

  @doc """
  What every start needs, and boot for an installed PostgreSQL: the
  socket's directory, the app's libraries on musl's search path (the
  server rewrites its environment for its process titles, so extensions
  loaded later don't see `LD_LIBRARY_PATH`) and the tools on PATH.
  """
  def prepare do
    if installed?() and Lepton.Sys.native?() do
      File.mkdir_p!(@socket_dir)
      File.chown(@socket_dir, @uid)
      File.chgrp(@socket_dir, @gid)
      File.chmod(@socket_dir, 0o2775)
      Apps.musl_path(prefix())
      link_tools()
    end

    :ok
  end

  @doc "Put PostgreSQL's programs on PATH (links in `#{@tool_dir}`); `dir` for tests."
  def link_tools(dir \\ @tool_dir, bindir \\ bindir()) do
    File.mkdir_p!(dir)

    for tool <- @tools, target = Path.join(bindir, tool), File.exists?(target) do
      link = Path.join(dir, tool)
      File.rm(link)
      File.ln_s(target, link)
    end

    :ok
  end

  @doc "Remove the links `link_tools/2` made."
  def unlink_tools(dir \\ @tool_dir) do
    for tool <- @tools, link = Path.join(dir, tool), match?({:ok, _}, File.read_link(link)), do: File.rm(link)
    :ok
  end

  @doc """
  Create the database cluster (once): `initdb` as `postgres`, then
  Lepton's settings. `say` reports progress.
  """
  def init_cluster(say \\ fn _ -> :ok end) do
    if initialized?() do
      :ok
    else
      dir = data_dir()
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      for d <- [Path.dirname(dir), dir], do: own(d)
      File.chmod!(dir, 0o700)

      # The superuser's password, read once by initdb (only postgres can read it).
      pwfile = Path.join(Path.dirname(dir), ".initdb-password")
      File.write!(pwfile, @password <> "\n")
      own(pwfile)
      File.chmod!(pwfile, 0o600)

      say.("Creating the database cluster in #{dir}...\n")

      args =
        ["-D", dir, "-U", "postgres", "--pwfile=" <> pwfile, "--auth-local=trust", "--auth-host=scram-sha-256",
         "-E", "UTF8", "--locale-provider=builtin", "--locale=C.UTF-8", "--no-instructions"]

      result = run_as_postgres(bin("initdb"), args, Path.dirname(dir))
      File.rm(pwfile)

      case result do
        {_, 0} ->
          File.write!(Path.join(dir, "postgresql.conf"), conf(), [:append])
          :ok

        {out, status} ->
          File.rm_rf(dir)
          {:error, "initdb failed (#{status}): #{String.slice(out, -600, 600)}"}
      end
    end
  end

  @doc "Lepton's settings, after initdb's `postgresql.conf`."
  def conf do
    """

    # -- Lepton -------------------------------------------------------------
    # This machine only: put it behind an SSH tunnel to reach it from
    # elsewhere, or change listen_addresses (and pg_hba.conf).
    listen_addresses = 'localhost'
    port = #{@port}
    unix_socket_directories = '#{@socket_dir}'
    # The log goes to the service's (svc logs postgresql).
    logging_collector = off
    """
  end

  defp run_as_postgres(exe, args, cd) do
    {exe, argv} = Lepton.RunAs.command(user(), exe, args)
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: cd, env: charlists(env())])
    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, [acc, d])
      {^port, {:exit_status, s}} -> {IO.iodata_to_binary(acc), s}
    end
  end

  defp own(path) do
    File.chown(path, @uid)
    File.chgrp(path, @gid)
  end

  defp charlists(env), do: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

  @doc "Is the server answering on `localhost:#{@port}`?"
  def listening? do
    case :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      _ ->
        false
    end
  end

  # -- the server ------------------------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Run the server until it exits, `out` getting its output (the
  `postgresql server` command, which the service runs). Returns its exit
  status. If the calling process ends first, the server is shut down.
  """
  def serve(out) do
    with true <- installed?() || {:error, "PostgreSQL isn't installed (sudo postgresql setup)"},
         :ok <- prepare(),
         :ok <- init_cluster(out),
         {:ok, os_pid} <- GenServer.call(__MODULE__, {:start, self()}, :infinity) do
      out.("PostgreSQL #{version()} is starting (process #{os_pid}): localhost:#{@port}, #{@socket_dir}\n")
      relay(out)
    end
  end

  defp relay(out) do
    receive do
      {:postgres, :data, d} ->
        out.(d)
        relay(out)

      {:postgres, :exit, status} ->
        status
    end
  end

  @doc "Is the server running (started by `serve/1`)?"
  def running? do
    Process.whereis(__MODULE__) != nil and GenServer.call(__MODULE__, :running?)
  end

  @doc "Wait (up to `timeout` ms) for a server shutting down to finish (at power-off)."
  def await_stopped(timeout \\ 30_000) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :await_stopped, timeout), else: :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    # Boot: an installed PostgreSQL's tools on PATH (the service starts the server).
    prepare()
    {:ok, %{port: nil, os_pid: nil, client: nil, mref: nil, stopping: false, timer: nil, pending: [], waiters: []}}
  end

  @impl true
  def handle_call({:start, client}, from, %{port: nil} = st), do: {:noreply, start(st, client, from)}
  # Still shutting down (a restart): start when it has stopped.
  def handle_call({:start, client}, from, %{stopping: true} = st), do: {:noreply, %{st | pending: st.pending ++ [{client, from}]}}
  def handle_call({:start, _}, _from, st), do: {:reply, {:error, "PostgreSQL is already running (process #{st.os_pid})"}, st}
  def handle_call(:running?, _from, st), do: {:reply, st.port != nil, st}
  def handle_call(:await_stopped, _from, %{port: nil} = st), do: {:reply, :ok, st}
  def handle_call(:await_stopped, from, st), do: {:noreply, %{st | waiters: [from | st.waiters]}}

  @impl true
  def handle_info({port, {:data, d}}, %{port: port} = st) do
    if st.client, do: send(st.client, {:postgres, :data, d})
    {:noreply, st}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = st) do
    if st.client, do: send(st.client, {:postgres, :exit, status})
    if st.mref, do: Process.demonitor(st.mref, [:flush])
    if st.timer, do: Process.cancel_timer(st.timer)
    for w <- st.waiters, do: GenServer.reply(w, :ok)
    st = %{st | port: nil, os_pid: nil, client: nil, mref: nil, stopping: false, timer: nil, waiters: []}

    case st.pending do
      [{client, from} | rest] -> {:noreply, start(%{st | pending: rest}, client, from)}
      [] -> {:noreply, st}
    end
  end

  # The service (or whoever ran the server) is gone: a fast shutdown.
  def handle_info({:DOWN, ref, :process, _, _}, %{mref: ref} = st) do
    {:noreply, shutdown(%{st | client: nil, mref: nil})}
  end

  # Still running long after SIGINT: an immediate shutdown (recovery at the next start).
  def handle_info(:shutdown_timeout, %{os_pid: pid} = st) when pid != nil do
    signal(pid, "QUIT")
    {:noreply, %{st | timer: nil}}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp start(st, client, from) do
    {exe, argv} = Lepton.RunAs.command(user(), bin("postgres"), ["-D", data_dir()])

    try do
      port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: data_dir(), env: charlists(env())])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      GenServer.reply(from, {:ok, os_pid})
      %{st | port: port, os_pid: os_pid, client: client, mref: Process.monitor(client)}
    rescue
      e ->
        GenServer.reply(from, {:error, "cannot start PostgreSQL: #{Exception.message(e)}"})
        st
    end
  end

  defp shutdown(%{os_pid: nil} = st), do: st
  defp shutdown(%{stopping: true} = st), do: st

  defp shutdown(st) do
    signal(st.os_pid, "INT")
    %{st | stopping: true, timer: Process.send_after(self(), :shutdown_timeout, 20_000)}
  end

  defp signal(os_pid, sig), do: Lepton.Sys.shim("kill", ["-" <> sig, to_string(os_pid)])
end
