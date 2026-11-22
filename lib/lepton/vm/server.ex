defmodule Lepton.VM.Server do
  @moduledoc """
  One running virtual machine: owns its QEMU, and reads its serial port.

  QEMU runs as the machine's owner. Its serial port is a socket this
  process connects to as soon as QEMU makes it, so nothing the guest
  prints is lost: the latest #{div(128 * 1024, 1024)} KB are kept, for `vm log` and for
  a console attaching later (`vm console` shows them, then follows).
  Consoles send keys back through `input/2`.

  Stopping asks the guest to shut down (QMP `system_powerdown`, the power
  button); `force` ends QEMU at once (QMP `quit`, or SIGKILL). The process
  ends when QEMU does; nothing restarts it.
  """

  use GenServer, restart: :temporary

  alias Lepton.VM

  @keep 128 * 1024

  def child_spec(opts), do: %{id: {__MODULE__, opts[:home], opts[:name]}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:home], opts[:name]))

  defp via(home, name), do: {:via, Registry, {Lepton.VM.Registry, {home, name}}}

  @doc "The server of machine `name` in `home`, or nil."
  def whereis(home, name) do
    case Registry.lookup(Lepton.VM.Registry, {home, name}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      _ -> nil
    end
  end

  @doc "Follow the serial console: returns what it printed lately; then `{:vm_serial, data}` messages, and `{:vm_exit, status}`."
  def attach(pid), do: GenServer.call(pid, {:attach, self()})
  def detach(pid), do: GenServer.cast(pid, {:detach, self()})
  def input(pid, data), do: GenServer.cast(pid, {:input, data})

  @doc "The serial output kept so far."
  def log(pid), do: GenServer.call(pid, :log)

  @doc "QEMU's own messages (errors), as far as kept."
  def qemu_log(pid), do: GenServer.call(pid, :qemu_log)

  def stop(pid, force?), do: GenServer.call(pid, {:stop, force?}, 15_000)

  # -- server ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    home = opts[:home]
    name = opts[:name]
    user = opts[:user]
    cfg = VM.config(home, name)
    prefix = VM.prefix()
    run = VM.run_dir(user.uid, name)
    File.rm_rf(run)
    File.mkdir_p!(run)
    File.chown(run, user.uid)
    File.chgrp(run, user.gid)
    prepare()

    paths = %{disk: VM.disk(home, name), firmware: VM.firmware(prefix), data: Path.join(prefix, "usr/share/qemu"), serial: Path.join(run, "serial.sock"), qmp: Path.join(run, "qmp.sock")}

    cond do
      paths.firmware == nil ->
        {:stop, {:shutdown, "no UEFI firmware in the qemu app (sudo app update qemu)"}}

      cfg["iso"] not in [nil, ""] and not File.exists?(cfg["iso"]) ->
        {:stop, {:shutdown, "the CD image #{cfg["iso"]} doesn't exist (vm set #{name} iso=PATH, or iso= for none)"}}

      true ->
        argv = VM.args(cfg, paths, VM.kvm?())
        {exe, argv} = Lepton.RunAs.command(user, VM.qemu(prefix), argv)
        env = qemu_env(prefix, user)
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: VM.dir(home, name), env: env])
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(self(), {:connect_serial, 50})

        {:ok,
         %{home: home, name: name, port: port, os_pid: os_pid, paths: paths, serial: nil, buffer: "", qemu_log: "", consoles: %{}, kvm: VM.kvm?(), started: System.os_time(:second)}}
    end
  end

  # musl's libraries for QEMU (built for musl, as Alpine is), and KVM for
  # every user, as distributions do through a kvm group.
  defp prepare do
    Lepton.Apps.musl_path(VM.prefix())
    if File.exists?("/dev/kvm"), do: File.chmod("/dev/kvm", 0o666)
  end

  defp qemu_env(prefix, user) do
    %{"HOME" => user.home, "USER" => user.name, "PATH" => "/usr/bin:/bin", "QEMU_MODULE_DIR" => Path.join(prefix, "usr/lib/qemu")}
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  @impl true
  def handle_call({:attach, pid}, _from, st) do
    ref = Process.monitor(pid)
    {:reply, st.buffer, %{st | consoles: Map.put(st.consoles, pid, ref)}}
  end

  def handle_call(:log, _from, st), do: {:reply, st.buffer, st}
  def handle_call(:qemu_log, _from, st), do: {:reply, st.qemu_log, st}

  def handle_call({:stop, force?}, _from, st) do
    result =
      if force? do
        if qmp(st.paths.qmp, "quit") != :ok, do: Lepton.Sys.shim("kill", ["-KILL", to_string(st.os_pid)])
        :ok
      else
        qmp(st.paths.qmp, "system_powerdown")
      end

    {:reply, result, st}
  end

  @impl true
  def handle_cast({:detach, pid}, st) do
    {ref, consoles} = Map.pop(st.consoles, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{st | consoles: consoles}}
  end

  def handle_cast({:input, data}, st) do
    if st.serial, do: :gen_tcp.send(st.serial, data)
    {:noreply, st}
  end

  @impl true
  def handle_info({:connect_serial, tries}, st) do
    case :gen_tcp.connect({:local, String.to_charlist(st.paths.serial)}, 0, [:binary, active: true]) do
      {:ok, sock} ->
        {:noreply, %{st | serial: sock}}

      {:error, _} when tries > 0 ->
        Process.send_after(self(), {:connect_serial, tries - 1}, 100)
        {:noreply, st}

      {:error, _} ->
        {:noreply, st}
    end
  end

  def handle_info({:tcp, sock, data}, %{serial: sock} = st) do
    for {pid, _} <- st.consoles, do: send(pid, {:vm_serial, data})
    {:noreply, %{st | buffer: keep(st.buffer <> data)}}
  end

  def handle_info({:tcp_closed, sock}, %{serial: sock} = st), do: {:noreply, %{st | serial: nil}}

  def handle_info({port, {:data, d}}, %{port: port} = st), do: {:noreply, %{st | qemu_log: keep(st.qemu_log <> d, 16 * 1024)}}

  def handle_info({port, {:exit_status, s}}, %{port: port} = st) do
    for {pid, _} <- st.consoles, do: send(pid, {:vm_exit, s, st.qemu_log})
    File.rm_rf(Path.dirname(st.paths.qmp))
    {:stop, :normal, st}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, st) do
    if st.consoles[pid] == ref, do: {:noreply, %{st | consoles: Map.delete(st.consoles, pid)}}, else: {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp keep(data, n \\ @keep), do: if(byte_size(data) > n, do: binary_part(data, byte_size(data) - n, n), else: data)

  @doc """
  Send QMP command `cmd` (no arguments) to the socket at `path`: `:ok` or
  `{:error, msg}`.
  """
  def qmp(path, cmd) do
    with {:ok, s} <- :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false, packet: :line], 2000) do
      try do
        with {:ok, _greeting} <- :gen_tcp.recv(s, 0, 2000),
             :ok <- :gen_tcp.send(s, ~s({"execute":"qmp_capabilities"}\n)),
             {:ok, _} <- :gen_tcp.recv(s, 0, 2000),
             :ok <- :gen_tcp.send(s, JSON.encode!(%{"execute" => cmd}) <> "\n") do
          case :gen_tcp.recv(s, 0, 2000) do
            {:ok, line} -> if line =~ ~s("error"), do: {:error, line}, else: :ok
            # quit: QEMU may close before it answers.
            {:error, :closed} -> :ok
            {:error, r} -> {:error, inspect(r)}
          end
        end
      after
        :gen_tcp.close(s)
      end
    else
      {:error, r} -> {:error, "QEMU's monitor didn't answer (#{inspect(r)})"}
    end
  end
end
