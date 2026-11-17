defmodule Lepton.Proc do
  @moduledoc """
  The process table.

  Every Lepton process is a BEAM process; this table gives it a Unix-style
  integer PID, a parent, a command line and a controlling terminal so that
  `ps`, `kill`, `jobs` and `fg` have something to talk about.
  """

  use GenServer

  @table :lepton_proc

  defstruct [:pid, :beam, :ppid, :cmd, :tty, :started, state: :running]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Spawn a new Lepton process running `fun.(lepton_pid)`; returns
  `{lepton_pid, beam_pid}`, or `{lepton_pid, beam_pid, monitor_ref}` with
  `monitor: true`. The monitor is set up before the process is released,
  so even a process that exits immediately reports its real exit reason.
  """
  def spawn(cmd, opts \\ [], fun) do
    parent = opts[:ppid] || current()
    tty = opts[:tty]

    beam =
      Kernel.spawn(fn ->
        receive do
          {:go, pid} -> fun.(pid)
        end
      end)

    pid = GenServer.call(__MODULE__, {:register, beam, parent, cmd, tty})
    ref = if opts[:monitor], do: Process.monitor(beam)
    send(beam, {:go, pid})
    if ref, do: {pid, beam, ref}, else: {pid, beam}
  end

  @doc "Register an already-running BEAM process (e.g. a login shell)."
  def register(beam, cmd, opts \\ []) do
    GenServer.call(__MODULE__, {:register, beam, opts[:ppid] || 1, cmd, opts[:tty]})
  end

  def current do
    case lookup_beam(self()) do
      %__MODULE__{pid: pid} -> pid
      nil -> 1
    end
  end

  def list do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.pid)
    end
  end

  def lookup(pid) when is_integer(pid) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, pid) do
      [{_, entry}] -> entry
      _ -> nil
    end
  end

  def lookup_beam(beam) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      Enum.find(list(), &(&1.beam == beam))
    end
  end

  def set_state(pid, state), do: GenServer.cast(__MODULE__, {:state, pid, state})

  @doc "Deliver a signal. Returns :ok or {:error, reason}."
  def signal(pid, sig) when is_integer(pid) do
    case lookup(pid) do
      nil ->
        {:error, :esrch}

      %{pid: 1} ->
        {:error, :eperm}

      %{beam: beam} ->
        case sig do
          s when s in [:kill, 9] ->
            Process.exit(beam, :kill)

          s when s in [:stop, :tstp, 19, 20] ->
            :erlang.suspend_process(beam)
            set_state(pid, :stopped)

          s when s in [:cont, 18] ->
            :erlang.resume_process(beam)
            set_state(pid, :running)

          _ ->
            send(beam, {:signal, :term})
            Process.exit(beam, :terminated)
        end

        :ok
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    init_entry = %__MODULE__{pid: 1, beam: Process.whereis(:init) || self(), ppid: 0, cmd: "init", tty: nil, started: now()}
    :ets.insert(@table, {1, init_entry})
    {:ok, %{next: 100}}
  end

  @impl true
  def handle_call({:register, beam, ppid, cmd, tty}, _from, state) do
    pid = state.next
    Process.monitor(beam)
    entry = %__MODULE__{pid: pid, beam: beam, ppid: ppid, cmd: cmd, tty: tty, started: now()}
    :ets.insert(@table, {pid, entry})
    {:reply, pid, %{state | next: pid + 1}}
  end

  @impl true
  def handle_cast({:state, pid, s}, state) do
    case :ets.lookup(@table, pid) do
      [{_, e}] -> :ets.insert(@table, {pid, %{e | state: s}})
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _, :process, beam, _}, state) do
    for {pid, %{beam: ^beam}} <- :ets.tab2list(@table), do: :ets.delete(@table, pid)
    {:noreply, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
