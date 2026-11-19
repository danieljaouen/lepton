defmodule Lepton.Bluetooth do
  @moduledoc """
  Bluetooth: keyboards, mice and headphones.

  The kernel has the radio's driver (`btusb` for USB adapters) and the
  input drivers (`hidp` for classic Bluetooth keyboards and mice, `uhid`
  for Bluetooth Low Energy ones). Pairing, connecting and the profiles
  are BlueZ's `bluetoothd`, which is driven over D-Bus; headphones play
  through bluez-alsa's `bluealsa`. They come as an app (`Lepton.Apps`,
  "bluetooth", installed the first time it's needed), and this
  GenServer runs them once it is installed:

    * `dbus-daemon`, a system bus at `/run/dbus/system_bus_socket` that
      everyone may use (Lepton has one user at the desk);
    * `bluetoothd`, keeping pairings in `/var/lib/bluetooth` (kept with
      the rest of Lepton's state, so paired devices stay paired);
    * `bluealsa`, playing A2DP audio to headphones and speakers.

  Lepton talks to them with `Lepton.DBus`: every two seconds it reads
  BlueZ's objects (the adapter, the devices) and bluealsa's PCMs into
  `summary/0`, which the `bluetooth` command and the classic desktop's
  applet read without waiting. It is also BlueZ's pairing **agent**:
  when a device wants a PIN, or a passkey typed on a keyboard, the agent
  asks whoever is pairing (`pair/2`: the `bluetooth pair` command, in a
  terminal).

  A paired keyboard or mouse becomes an ordinary input device
  (`/dev/input/event*`); paired headphones become a sound output
  (`Lepton.Sound`).
  """

  use GenServer
  require Logger
  import Bitwise

  alias Lepton.{Apps, DBus}

  @app "bluetooth"
  @tick 2_000
  @bluez "org.bluez"
  @bluealsa "org.bluealsa"
  @agent "/org/lepton/agent"

  # -- what there is ------------------------------------------------------------------------------------

  @empty %{installed: false, running: false, controllers: [], adapter: nil, devices: [], outputs: []}

  @doc """
  Bluetooth now, without waiting on BlueZ: `%{installed, running,
  controllers, adapter, devices, outputs}`. `adapter` is `%{path, address,
  name, powered, discovering}` or nil; `devices` are `%{path, address,
  name, kind, paired, connected, trusted, rssi, battery}`, connected and
  paired ones first; `outputs` are headphones' A2DP PCMs (`%{pcm,
  address, name, channels, rate}`).
  """
  def summary, do: :persistent_term.get({__MODULE__, :summary}, @empty)

  @doc "The Bluetooth radios the kernel has (`hci0`, ...)."
  def controllers do
    case File.ls("/sys/class/bluetooth") do
      {:ok, names} -> names |> Enum.filter(&(&1 =~ ~r/^hci\d+$/)) |> Enum.sort()
      _ -> []
    end
  end

  @doc "What a device is, from BlueZ's icon name."
  def kind(icon) do
    case icon do
      "input-keyboard" -> :keyboard
      i when i in ["input-mouse", "input-tablet"] -> :mouse
      "input-gaming" -> :gamepad
      i when i in ["audio-headphones", "audio-headset", "audio-card"] -> :headphones
      "phone" -> :phone
      "computer" -> :computer
      _ -> :device
    end
  end

  @doc "Find a device by address or name (case-insensitive): `{:ok, device}` or `{:error, reason}`."
  def find(devices, what) do
    w = String.downcase(what)

    case Enum.filter(devices, &(String.downcase(&1.address) == w)) do
      [d] ->
        {:ok, d}

      [] ->
        case Enum.filter(devices, &(String.downcase(&1.name) == w)) do
          [d] -> {:ok, d}
          [] -> {:error, "no device \"#{what}\" (bluetooth scan finds devices nearby)"}
          _ -> {:error, "several devices are called \"#{what}\": use the address"}
        end

      _ ->
        {:error, "several devices have that address"}
    end
  end

  # -- doing things (from the caller's process) ------------------------------------------------------

  defp conn do
    case GenServer.whereis(__MODULE__) && GenServer.call(__MODULE__, :conn) do
      {:ok, conn, adapter} when adapter != nil -> {:ok, conn, adapter}
      {:ok, _conn, nil} -> {:error, "no Bluetooth adapter (plug in a USB Bluetooth adapter, and pass it to the VM)"}
      _ -> {:error, "Bluetooth isn't running" <> if(Apps.installed?(@app), do: "", else: " (install it with: sudo app install bluetooth)")}
    end
  end

  @doc "Turn the radio on or off."
  def power(on?) do
    with {:ok, c, adapter} <- conn(),
         :ok <- result(DBus.set(c, @bluez, adapter, "org.bluez.Adapter1", "Powered", "b", on?)) do
      refresh()
    end
  end

  @doc "Look for devices for `seconds` (in the background)."
  def discover(seconds \\ 30) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:discover, seconds * 1000}, 10_000), else: {:error, "Bluetooth isn't running"}
  end

  @doc """
  Pair with a device, then trust and connect it. `prompter` gets the
  agent's questions as `{:bt_agent, from, ref, request}` and answers with
  `send(from, {:bt_answer, ref, answer})` (see `agent/3`). Blocks until
  done (up to a minute and a half).
  """
  def pair(device, prompter) do
    with {:ok, c, _adapter} <- conn() do
      GenServer.call(__MODULE__, {:prompter, prompter})

      try do
        with :ok <- result(DBus.call(c, @bluez, device.path, "org.bluez.Device1", "Pair", "", [], 90_000)),
             :ok <- result(DBus.set(c, @bluez, device.path, "org.bluez.Device1", "Trusted", "b", true)) do
          # Keyboards and headphones want connecting; some connect by themselves.
          _ = DBus.call(c, @bluez, device.path, "org.bluez.Device1", "Connect", "", [], 30_000)
          refresh()
        end
      after
        GenServer.call(__MODULE__, {:prompter, nil})
      end
    end
  end

  @doc "Connect a paired device."
  def connect(device), do: device_call(device, "Connect")

  @doc "Disconnect a device."
  def disconnect(device), do: device_call(device, "Disconnect")

  @doc "Forget a device: unpair it."
  def forget(device) do
    with {:ok, c, adapter} <- conn(),
         :ok <- result(DBus.call(c, @bluez, adapter, "org.bluez.Adapter1", "RemoveDevice", "o", [device.path])) do
      refresh()
    end
  end

  defp device_call(device, member) do
    with {:ok, c, _} <- conn(),
         :ok <- result(DBus.call(c, @bluez, device.path, "org.bluez.Device1", member, "", [], 30_000)) do
      refresh()
    end
  end

  @doc "Set headphones' volume (0-100) and mute (bluealsa: 0-127 per channel, the top bit mutes)."
  def set_volume(pcm, volume, muted) do
    level = round(volume * 127 / 100) |> max(0) |> min(127)
    byte = if muted, do: 0x80 ||| level, else: level

    with {:ok, c, _} <- conn_any() do
      result(DBus.set(c, @bluealsa, pcm, "org.bluealsa.PCM1", "Volume", "q", byte <<< 8 ||| byte))
    end
  end

  defp conn_any do
    case GenServer.whereis(__MODULE__) && GenServer.call(__MODULE__, :conn) do
      {:ok, c, adapter} -> {:ok, c, adapter}
      _ -> {:error, "Bluetooth isn't running"}
    end
  end

  @doc "The environment the Bluetooth programs run with (their libraries)."
  def env do
    prefix = Apps.dir(@app)
    %{"LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(prefix, &1))}
  end

  @doc "A program of the Bluetooth app (`usr/bin/bluealsa-cli`, ...)."
  def program(rel), do: Path.join(Apps.dir(@app), rel)

  defp refresh do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :refresh, 10_000)
    :ok
  end

  defp result({:ok, _}), do: :ok
  defp result(:ok), do: :ok
  defp result({:error, name, text}), do: {:error, describe(name, text)}

  # BlueZ's errors, as people would say them.
  defp describe(name, text) do
    case {name |> String.split(".") |> List.last(), text} do
      {"AuthenticationFailed", _} -> "pairing failed (wrong PIN or passkey?)"
      {"AuthenticationCanceled", _} -> "pairing was cancelled"
      {"AuthenticationRejected", _} -> "the device refused to pair"
      {"AuthenticationTimeout", _} -> "pairing took too long"
      {"ConnectionAttemptFailed", _} -> "the device didn't answer (is it on, and in pairing mode?)"
      {"AlreadyExists", _} -> "already paired"
      {"InProgress", _} -> "already in progress"
      {"NotReady", _} -> "the adapter is off (bluetooth on)"
      {"NoReply", _} -> "no answer from bluetoothd"
      {_, ""} -> name
      {_, text} -> text
    end
  end

  # -- the agent ---------------------------------------------------------------------------------------

  @doc """
  The pairing agent (org.bluez.Agent1). Questions go to the prompter as
  `{:bt_agent, from, ref, {member, device_name, args}}`, where member is
  `"RequestPinCode"` (answer `{:pin, text}`), `"DisplayPinCode"` and
  `"DisplayPasskey"` (show it; answer `:ok`), `"RequestPasskey"` (answer
  `{:passkey, n}`), `"RequestConfirmation"` and `"RequestAuthorization"`
  (answer `:yes` or `:no`); and `"Cancel"`. With no one pairing, devices
  already paired may use their services and everything else is refused.
  """
  def agent(member, args, _msg) do
    case member do
      m when m in ["Release", "AuthorizeService"] ->
        {:reply, "", []}

      "Cancel" ->
        if p = prompter(), do: send(p, {:bt_agent, self(), make_ref(), {"Cancel", nil, []}})
        {:reply, "", []}

      _ ->
        case prompter() do
          nil when member in ["DisplayPinCode", "DisplayPasskey"] -> {:reply, "", []}
          nil -> {:error, "org.bluez.Error.Rejected", "no one is pairing"}
          p -> ask(p, member, args)
        end
    end
  end

  defp ask(p, member, [path | rest]) do
    ref = make_ref()
    name = Enum.find_value(summary().devices, path, &(&1.path == path && &1.name))
    send(p, {:bt_agent, self(), ref, {member, name, rest}})

    receive do
      {:bt_answer, ^ref, answer} ->
        case {member, answer} do
          {"RequestPinCode", {:pin, pin}} -> {:reply, "s", [pin]}
          {"RequestPasskey", {:passkey, n}} -> {:reply, "u", [n]}
          {_, a} when a in [:ok, :yes] -> {:reply, "", []}
          _ -> {:error, "org.bluez.Error.Rejected", "refused"}
        end
    after
      60_000 -> {:error, "org.bluez.Error.Canceled", "no answer"}
    end
  end

  defp prompter do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :get_prompter), else: nil
  end

  # -- the service ----------------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Lepton.Sys.native?(), do: send(self(), :tick)
    {:ok, %{daemons: %{}, conn: nil, agent_registered: false, adapter: nil, prompter: nil, stop_discovery: nil}}
  end

  @impl true
  def handle_call(:conn, _from, %{conn: nil} = st), do: {:reply, :not_running, st}
  def handle_call(:conn, _from, st), do: {:reply, {:ok, st.conn, st.adapter}, st}
  def handle_call(:get_prompter, _from, st), do: {:reply, st.prompter, st}
  def handle_call({:prompter, p}, _from, st), do: {:reply, :ok, %{st | prompter: p}}
  def handle_call(:refresh, _from, st), do: {:reply, :ok, refresh_state(st)}

  def handle_call({:discover, ms}, _from, %{conn: c, adapter: a} = st) when c != nil and a != nil do
    if st.stop_discovery, do: Process.cancel_timer(st.stop_discovery)

    started =
      case DBus.call(c, @bluez, a, "org.bluez.Adapter1", "StartDiscovery") do
        {:ok, _} -> :ok
        {:error, "org.bluez.Error.InProgress", _} -> :ok
        err -> result(err)
      end

    if started == :ok,
      do: {:reply, :ok, refresh_state(%{st | stop_discovery: Process.send_after(self(), :stop_discovery, ms)})},
      else: {:reply, started, st}
  end

  def handle_call({:discover, _}, _from, %{conn: nil} = st), do: {:reply, {:error, "Bluetooth isn't running"}, st}
  def handle_call({:discover, _}, _from, st), do: {:reply, {:error, "no Bluetooth adapter"}, st}

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)
    st = if Apps.installed?(@app), do: st |> update() |> ensure_daemons() |> ensure_conn(), else: st
    {:noreply, refresh_state(st)}
  end

  def handle_info(:stop_discovery, %{conn: c, adapter: a} = st) when c != nil and a != nil do
    DBus.call(c, @bluez, a, "org.bluez.Adapter1", "StopDiscovery")
    {:noreply, refresh_state(%{st | stop_discovery: nil})}
  end

  def handle_info({port, {:data, {_, line}}}, st) when is_port(port) do
    name = Enum.find_value(st.daemons, fn {n, p} -> p == port && n end)
    Logger.debug("bluetooth: #{name}: #{line}")
    {:noreply, st}
  end

  def handle_info({port, {:exit_status, code}}, st) when is_port(port) do
    case Enum.find(st.daemons, fn {_, p} -> p == port end) do
      {name, _} ->
        Logger.warning("bluetooth: #{name} exited (#{code}); starting it again")
        # The bus going means starting everything again.
        st =
          case name do
            "dbus-daemon" -> %{st | daemons: %{}, conn: nil, agent_registered: false}
            "bluetoothd" -> %{st | daemons: Map.delete(st.daemons, name), agent_registered: false}
            _ -> %{st | daemons: Map.delete(st.daemons, name)}
          end

        {:noreply, st}

      nil ->
        {:noreply, st}
    end
  end

  def handle_info({:EXIT, _, _}, st), do: {:noreply, st}
  def handle_info({:DOWN, _, :process, pid, _}, %{conn: pid} = st), do: {:noreply, %{st | conn: nil, agent_registered: false}}
  def handle_info(_msg, st), do: {:noreply, st}

  # -- the daemons -------------------------------------------------------------------------------------

  # Before the daemons start (at boot, or after an install): an update
  # downloaded earlier is applied, and one is looked for when due.
  defp update(%{daemons: d} = st) when d == %{} do
    with {:updated, v} <- Apps.maintain(@app), do: Logger.info("bluetooth: updated to #{v}")
    st
  end

  defp update(st), do: st

  defp ensure_daemons(st) do
    prefix = Apps.dir(@app)

    st
    |> start("dbus-daemon", fn ->
      prepare()
      File.rm(DBus.system_bus())
      {Path.join(prefix, "usr/bin/dbus-daemon"), ["--config-file=" <> bus_config(), "--nofork", "--nopidfile", "--nosyslog"]}
    end, fn -> File.exists?(DBus.system_bus()) end)
    |> start("bluetoothd", fn -> {Path.join(prefix, "usr/lib/bluetooth/bluetoothd"), ["-n"]} end, nil)
    |> start("bluealsa", fn -> {Path.join(prefix, "usr/bin/bluealsa"), ["-p", "a2dp-source"]} end, nil)
  end

  # Start a daemon unless it runs; `ready` (if given) is waited for (3 s at most).
  defp start(st, name, how, ready) do
    if Map.has_key?(st.daemons, name) do
      st
    else
      {exe, args} = how.()

      port =
        Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, {:line, 1024}, args: args, env: Enum.map(env(), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)])

      if ready, do: Enum.find(1..30, fn _ -> ready.() || (Process.sleep(100) && false) end)
      Logger.info("bluetooth: started #{name}")
      %{st | daemons: Map.put(st.daemons, name, port)}
    end
  end

  # Drivers, device nodes, and where pairings are kept.
  defp prepare do
    Enum.each(~w(bluetooth btusb hidp uhid), &Lepton.Kmod.modprobe/1)
    File.mkdir_p("/run/dbus")
    keep = Lepton.Persist.state_path("bluetooth")
    File.mkdir_p(keep)
    File.chmod(keep, 0o700)

    case File.lstat("/var/lib/bluetooth") do
      {:ok, %File.Stat{type: :symlink}} -> :ok
      {:ok, _} -> :ok
      _ -> File.mkdir_p("/var/lib") && File.ln_s(keep, "/var/lib/bluetooth")
    end
  end

  # A system bus anyone on this machine may use.
  defp bus_config do
    path = "/run/lepton/dbus-system.conf"
    File.mkdir_p(Path.dirname(path))

    File.write!(path, """
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>system</type>
      <listen>unix:path=#{DBus.system_bus()}</listen>
      <auth>EXTERNAL</auth>
      <policy context="default">
        <allow user="*"/>
        <allow own="*"/>
        <allow send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_type="method_return"/>
        <allow send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="signal"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
      </policy>
    </busconfig>
    """)

    path
  end

  defp ensure_conn(%{conn: nil} = st) do
    case DBus.connect() do
      {:ok, c} ->
        Process.monitor(c)
        DBus.export(c, @agent, &agent/3)
        %{st | conn: c} |> register_agent()

      _ ->
        st
    end
  end

  defp ensure_conn(st), do: register_agent(st)

  # Once bluetoothd is on the bus: be its default agent, able to show a
  # passkey and to take one (a keyboard and a display, as a computer is).
  defp register_agent(%{agent_registered: true} = st), do: st

  defp register_agent(st) do
    case DBus.call(st.conn, @bluez, "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", "os", [@agent, "KeyboardDisplay"]) do
      {:ok, _} ->
        DBus.call(st.conn, @bluez, "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent", "o", [@agent])
        %{st | agent_registered: true}

      _ ->
        st
    end
  end

  # -- what BlueZ and bluealsa say ---------------------------------------------------------------------------

  defp refresh_state(st) do
    controllers = controllers()

    summary =
      case st.conn && DBus.call(st.conn, @bluez, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", [], 5_000) do
        {:ok, [objects]} ->
          adapter_path = objects |> Enum.filter(fn {_, ifs} -> Map.has_key?(ifs, "org.bluez.Adapter1") end) |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

          adapter =
            if adapter_path do
              a = objects[adapter_path]["org.bluez.Adapter1"]
              %{path: adapter_path, address: a["Address"], name: a["Alias"] || a["Name"], powered: a["Powered"] == true, discovering: a["Discovering"] == true}
            end

          devices =
            for {path, ifs} <- objects, d = ifs["org.bluez.Device1"], d != nil, d["Adapter"] == adapter_path do
              %{
                path: path,
                address: d["Address"],
                name: d["Alias"] || d["Name"] || d["Address"],
                kind: kind(d["Icon"]),
                paired: d["Paired"] == true or d["Bonded"] == true,
                connected: d["Connected"] == true,
                trusted: d["Trusted"] == true,
                rssi: d["RSSI"],
                battery: get_in(ifs, ["org.bluez.Battery1", "Percentage"])
              }
            end
            |> Enum.sort_by(&{not &1.connected, not &1.paired, -(&1.rssi || -200), &1.name})

          %{@empty | installed: true, running: true, controllers: controllers, adapter: adapter, devices: devices, outputs: outputs(st.conn, devices)}

        _ ->
          %{@empty | installed: Apps.installed?(@app), running: st.conn != nil, controllers: controllers}
      end

    if summary != summary(), do: :persistent_term.put({__MODULE__, :summary}, summary)
    %{st | adapter: summary.adapter && summary.adapter.path}
  end

  # Headphones and speakers: bluealsa's A2DP PCMs that play to a device.
  defp outputs(conn, devices) do
    if Enum.any?(devices, & &1.connected) do
      case DBus.call(conn, @bluealsa, "/org/bluealsa", "org.bluealsa.Manager1", "GetPCMs", "", [], 3_000) do
        {:ok, [pcms]} ->
          for {pcm, p} <- pcms, p["Transport"] =~ "A2DP", p["Mode"] == "sink", d = Enum.find(devices, &(&1.path == p["Device"])), d != nil do
            %{pcm: pcm, address: d.address, name: d.name, channels: p["Channels"] || 2, rate: p["Rate"] || p["Sampling"] || 44100}
          end

        _ ->
          []
      end
    else
      []
    end
  end
end
