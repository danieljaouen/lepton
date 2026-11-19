defmodule Lepton.Wifi do
  @moduledoc """
  Wi-Fi: saved networks, and a `wpa_supplicant` for each wireless interface.

  **Saved networks** live in `/var/lib/lepton/wpa_supplicant.conf`, in
  wpa_supplicant's own format, with each passphrase replaced by its WPA PSK:
  PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32), exactly what
  `wpa_passphrase` computes. (WPA3-only networks need the passphrase itself,
  so they are not supported; WPA2 and WPA2/WPA3 networks are.)

  **The manager** (this GenServer, started at boot) checks for Wi-Fi
  hardware every two seconds (`Lepton.USB` loads the drivers for adapters
  plugged in later), starts
  `/usr/libexec/lepton/wpa_supplicant` on each wireless interface with the
  saved networks, and once an interface has associated, configures it with
  DHCP (`Lepton.Net.configure/1`).

  **Control** goes through wpa_supplicant's control socket
  (`/run/wpa_supplicant/IFACE`), as `wpa_cli` does: `status/1`, `scan/1`,
  `select/1`.

  **The desktop** (the classic desktop's Wi-Fi applet) reads `summary/0`,
  which the manager keeps up to date every tick, and asks for scans with
  `scan_async/0`; neither waits for wpa_supplicant.
  """

  use GenServer
  require Logger

  alias Lepton.Persist

  @supplicant "/usr/libexec/lepton/wpa_supplicant"
  @ctrl_dir "/run/wpa_supplicant"
  @tick 2_000

  # -- saved networks ----------------------------------------------------------------------

  def conf_path, do: Persist.state_path("wpa_supplicant.conf")

  @header "# written by Lepton (wifi connect / wifi setup)\nctrl_interface=#{@ctrl_dir}\n"

  def psk(ssid, passphrase), do: :crypto.pbkdf2_hmac(:sha, passphrase, ssid, 4096, 32) |> Base.encode16(case: :lower)

  @doc "Save (or replace) a network. An empty passphrase means an open network."
  def save(ssid, passphrase) do
    blocks = conf_blocks(read_conf()) |> Enum.reject(&(block_ssid(&1) == ssid))
    write_conf(blocks ++ [network_block(ssid, passphrase)])
    reconfigure()
    :ok
  end

  @doc "Forget one saved network, or all of them (`nil`)."
  def forget(nil) do
    File.rm(conf_path())
    File.rm(Persist.state_path("wifi-skipped"))
    reconfigure()
    :ok
  end

  def forget(ssid) do
    blocks = conf_blocks(read_conf())

    if Enum.any?(blocks, &(block_ssid(&1) == ssid)) do
      write_conf(Enum.reject(blocks, &(block_ssid(&1) == ssid)))
      reconfigure()
      :ok
    else
      {:error, :not_found}
    end
  end

  def networks, do: read_conf() |> conf_blocks() |> Enum.map(&block_ssid/1)

  def configured?, do: networks() != [] or Persist.flag?("wifi-skipped")

  @doc false
  def network_block(ssid, passphrase) do
    key = if passphrase == "", do: "key_mgmt=NONE", else: "psk=#{psk(ssid, passphrase)}"
    "network={\n\tssid=#{encode_ssid(ssid)}\n\t#{key}\n}\n"
  end

  # Quoted when printable, else hex (wpa_supplicant accepts both).
  defp encode_ssid(ssid) do
    if String.printable?(ssid) and not String.contains?(ssid, ["\"", "\n"]),
      do: "\"#{ssid}\"",
      else: Base.encode16(ssid, case: :lower)
  end

  @doc false
  def conf_blocks(text), do: for([b] <- Regex.scan(~r/network=\{.*?\n\}\n?/s, text), do: b)

  @doc false
  def block_ssid(block) do
    case Regex.run(~r/^\s*ssid=(.*)$/m, block) do
      [_, "\"" <> quoted] -> String.trim_trailing(quoted, "\"")
      [_, hex] -> case Base.decode16(String.trim(hex), case: :mixed) do
          {:ok, s} -> s
          :error -> hex
        end
      nil -> ""
    end
  end

  defp read_conf do
    case File.read(conf_path()) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp write_conf(blocks) do
    File.mkdir_p!(Path.dirname(conf_path()))
    File.write!(conf_path(), @header <> Enum.join(blocks))
    File.chmod(conf_path(), 0o600)
  end

  # -- interfaces and control ----------------------------------------------------------------

  def wireless_interfaces do
    case File.ls("/sys/class/net") do
      {:ok, names} -> names |> Enum.filter(&(File.dir?("/sys/class/net/#{&1}/wireless") or File.dir?("/sys/class/net/#{&1}/phy80211"))) |> Enum.sort()
      _ -> []
    end
  end

  @doc "Send a command to the interface's wpa_supplicant; `{:ok, reply}`."
  def ctrl(iface, command, timeout \\ 3_000), do: with_ctrl(iface, &request(&1, command, timeout))

  # One control-socket session (a bound local datagram socket), like wpa_cli.
  defp with_ctrl(iface, fun) do
    dir = "/run/lepton"
    File.mkdir_p(dir)
    local = Path.join(dir, "wpa_ctrl_#{System.unique_integer([:positive])}")

    with {:ok, sock} <- :socket.open(:local, :dgram, :default) do
      try do
        with :ok <- :socket.bind(sock, %{family: :local, path: local}),
             :ok <- :socket.connect(sock, %{family: :local, path: Path.join(@ctrl_dir, iface)}) do
          fun.(sock)
        end
      after
        :socket.close(sock)
        File.rm(local)
      end
    end
  end

  # A command's reply; unsolicited events ("<N>CTRL-EVENT-...") are skipped.
  defp request(sock, command, timeout) do
    with :ok <- :socket.send(sock, command), do: reply(sock, timeout)
  end

  defp reply(sock, timeout) do
    case :socket.recv(sock, 0, timeout) do
      {:ok, "<" <> _event} -> reply(sock, timeout)
      other -> other
    end
  end

  defp await_event(sock, event, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      case :socket.recv(sock, 0, left) do
        {:ok, "<" <> msg} -> if String.contains?(msg, event), do: :ok, else: await_event(sock, event, deadline)
        {:ok, _} -> await_event(sock, event, deadline)
        err -> err
      end
    end
  end

  @doc "wpa_supplicant's STATUS as a map (`wpa_state`, `ssid`, `ip_address`, ...)."
  def status(iface) do
    case ctrl(iface, "STATUS") do
      {:ok, text} -> {:ok, parse_status(text)}
      err -> err
    end
  end

  @doc false
  def parse_status(text) do
    for line <- String.split(text, "\n"), [k, v] <- [String.split(line, "=", parts: 2)], into: %{}, do: {k, v}
  end

  @doc "Scan and return `[%{ssid, signal, security, frequency}]`, strongest first, one entry per network."
  def scan(iface, timeout \\ 15_000) do
    # Subscribe to events, start a scan, and wait for its results event.
    with_ctrl(iface, fn sock ->
      deadline = System.monotonic_time(:millisecond) + timeout

      with {:ok, "OK\n"} <- request(sock, "ATTACH", 3_000),
           {:ok, started} when started in ["OK\n", "FAIL-BUSY\n"] <- request(sock, "SCAN", 3_000),
           :ok <- await_event(sock, "CTRL-EVENT-SCAN-RESULTS", deadline),
           {:ok, text} <- request(sock, "SCAN_RESULTS", 3_000) do
        request(sock, "DETACH", 1_000)
        {:ok, parse_scan(text)}
      else
        {:ok, other} -> {:error, String.trim(other)}
        err -> err
      end
    end)
  end

  @doc false
  def parse_scan(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [_bssid, freq, signal, flags | ssid] ->
          [%{ssid: Enum.join(ssid, "\t"), frequency: String.to_integer(freq), signal: String.to_integer(signal), security: security(flags)}]

        _ ->
          []
      end
    end)
    |> Enum.reject(&(&1.ssid == ""))
    |> Enum.sort_by(& &1.signal, :desc)
    |> Enum.uniq_by(& &1.ssid)
  end

  defp security(flags) do
    cond do
      flags =~ "SAE" and flags =~ "PSK" -> "WPA2/WPA3"
      flags =~ "SAE" -> "WPA3"
      flags =~ "WPA2" or flags =~ "RSN" -> "WPA2"
      flags =~ "WPA" -> "WPA"
      flags =~ "WEP" -> "WEP"
      true -> "open"
    end
  end

  @doc """
  Use the saved network `ssid` now, rather than whichever saved network
  wpa_supplicant would pick (the others come back with the next change to
  the saved networks).
  """
  def select(ssid) do
    for iface <- wireless_interfaces(),
        {:ok, list} <- [ctrl(iface, "LIST_NETWORKS")],
        id = network_id(list, ssid),
        id != nil,
        do: ctrl(iface, "SELECT_NETWORK #{id}")

    :ok
  end

  @doc "The id of `ssid` in wpa_supplicant's LIST_NETWORKS reply."
  def network_id(text, ssid) do
    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.find_value(fn line ->
      case String.split(line, "\t") do
        [id, ^ssid | _] -> id
        _ -> nil
      end
    end)
  end

  # -- the desktop's view -------------------------------------------------------------------------

  @doc """
  What Wi-Fi looks like now, without asking wpa_supplicant:
  `%{iface, state, ssid, ip, signal, networks, scanning, saved}`.
  `iface` is nil without Wi-Fi hardware; `networks` are the last scan's
  (`scan/2`'s maps); `signal` is the connection's, in dBm.
  """
  def summary do
    :persistent_term.get({__MODULE__, :summary}, %{iface: nil, state: nil, ssid: nil, ip: nil, signal: nil, networks: [], scanning: false, saved: []})
  end

  @doc "The networks wpa_supplicant knows from its last scan (it scans by itself too), without scanning."
  def known_networks(iface) do
    case ctrl(iface, "SCAN_RESULTS") do
      {:ok, text} -> {:ok, parse_scan(text)}
      err -> err
    end
  end

  @doc """
  Scan in the background; the results appear in `summary/0`: at once the
  networks wpa_supplicant already knows, then a fresh scan's (keeping the
  known ones if wpa_supplicant can't scan just then).
  """
  def scan_async do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :scan)
    :ok
  end

  @doc "Signal strength as bars, 0 to 4, from dBm."
  def bars(nil), do: 0
  def bars(dbm) when dbm >= -55, do: 4
  def bars(dbm) when dbm >= -65, do: 3
  def bars(dbm) when dbm >= -75, do: 2
  def bars(_dbm), do: 1

  @doc "Wait until `iface` has associated: `{:ok, status}` or `{:error, last_state}`."
  def await_associated(iface, timeout_ms) do
    poll(timeout_ms, fn ->
      st = case status(iface) do
        {:ok, s} -> s
        _ -> %{}
      end

      if st["wpa_state"] == "COMPLETED", do: {:ok, st}, else: {:retry, st["wpa_state"] || "UNKNOWN"}
    end)
  end

  @doc "Wait for the DHCP lease the manager gets after association: `{:ok, lease}` or `{:error, :timeout}`."
  def await_lease(iface, timeout_ms) do
    poll(timeout_ms, fn ->
      case Lepton.Net.leases()[iface] do
        nil -> {:retry, :timeout}
        lease -> {:ok, lease}
      end
    end)
  end

  defp poll(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case fun.() do
        {:retry, last} -> if System.monotonic_time(:millisecond) > deadline, do: {:error, last}, else: (Process.sleep(500); nil)
        result -> result
      end
    end)
    |> Enum.find(& &1)
  end

  def status_lines do
    wired = for {iface, l} <- Lepton.Net.leases(), iface not in wireless_interfaces(), do: "wired #{iface}: #{Lepton.Net.format_ip(l.ip)}/#{l.prefix} (DHCP)"

    wifi =
      case wireless_interfaces() do
        [] -> ["wireless: no Wi-Fi hardware (UTM/QEMU have none; pass a USB Wi-Fi adapter through to the VM)"]
        list -> Enum.map(list, &interface_line/1)
      end

    saved = case networks() do
      [] -> []
      ns -> ["saved Wi-Fi networks: " <> Enum.join(ns, ", ")]
    end

    (if wired == [], do: ["wired: no DHCP lease yet"], else: wired) ++ wifi ++ saved
  end

  defp interface_line(iface) do
    case status(iface) do
      {:ok, %{"wpa_state" => "COMPLETED"} = st} ->
        addr = case Lepton.Net.leases()[iface] do
          nil -> "waiting for DHCP"
          l -> "#{Lepton.Net.format_ip(l.ip)}/#{l.prefix}"
        end

        "wireless #{iface}: connected to #{st["ssid"]} (#{addr})"

      {:ok, st} ->
        "wireless #{iface}: #{String.downcase(st["wpa_state"] || "unknown")}#{if networks() == [], do: " (no saved networks: wifi connect SSID)", else: ""}"

      _ ->
        "wireless #{iface}: starting"
    end
  end

  # -- manager ----------------------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tell every running wpa_supplicant to re-read the saved networks."
  def reconfigure do
    for iface <- wireless_interfaces(), do: ctrl(iface, "RECONFIGURE")
    :ok
  end

  @doc "Stop managing `iface` (e.g. to run an access point on it)."
  def release(iface), do: call({:release, iface})

  @doc "Manage `iface` again."
  def manage(iface), do: call({:manage, iface})

  defp call(msg) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, msg, 10_000), else: {:error, :not_running}
  end

  @impl true
  def init(_opts) do
    # Only on a booted Lepton (not `mix test` on a Mac) with the supplicant.
    if Lepton.Sys.native?() and File.exists?(@supplicant), do: send(self(), :tick)
    {:ok, %{supplicants: %{}, configured: MapSet.new(), dhcp: %{}, released: MapSet.new(), networks: [], scanning: nil}}
  end

  @impl true
  def handle_cast(:scan, %{scanning: nil} = st) do
    case managed(st) do
      [iface | _] ->
        me = self()

        {pid, _} =
          spawn_monitor(fn ->
            send(me, {:scanned, self(), known_networks(iface)})
            send(me, {:scanned, self(), scan(iface)})
            send(me, {:scan_done, self()})
          end)
        {:noreply, publish(%{st | scanning: pid})}

      [] ->
        {:noreply, st}
    end
  end

  def handle_cast(:scan, st), do: {:noreply, st}

  @impl true
  def handle_call({:release, iface}, _from, st) do
    st = stop_supplicant(st, iface)
    {:reply, :ok, %{st | released: MapSet.put(st.released, iface)}}
  end

  def handle_call({:manage, iface}, _from, st) do
    send(self(), :tick)
    {:reply, :ok, %{st | released: MapSet.delete(st.released, iface)}}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)
    ifaces = managed(st)
    st = Enum.reduce(Map.keys(st.supplicants) -- ifaces, st, &stop_supplicant(&2, &1))
    st = Enum.reduce(ifaces -- Map.keys(st.supplicants), st, &start_supplicant(&2, &1))
    {:noreply, ifaces |> Enum.reduce(st, &check_dhcp(&2, &1)) |> publish()}
  end

  def handle_info({:scanned, pid, result}, %{scanning: pid} = st) do
    case result do
      {:ok, nets} when nets != [] -> {:noreply, publish(%{st | networks: nets})}
      _ -> {:noreply, st}
    end
  end

  def handle_info({:scan_done, pid}, %{scanning: pid} = st), do: {:noreply, publish(%{st | scanning: nil})}

  def handle_info({:DOWN, _, :process, pid, _}, %{scanning: pid} = st), do: {:noreply, publish(%{st | scanning: nil})}

  def handle_info({port, {:data, {_, line}}}, st) when is_port(port) do
    Logger.debug("wpa_supplicant: #{line}")
    {:noreply, st}
  end

  def handle_info({port, {:exit_status, code}}, st) when is_port(port) do
    case Enum.find(st.supplicants, fn {_, p} -> p == port end) do
      {iface, _} ->
        Logger.warning("wifi: wpa_supplicant on #{iface} exited (#{code}); restarting")
        {:noreply, %{st | supplicants: Map.delete(st.supplicants, iface), configured: MapSet.delete(st.configured, iface)}}

      nil ->
        {:noreply, st}
    end
  end

  def handle_info({ref, result}, st) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(st.dhcp, fn {_, r} -> r == ref end) do
      {iface, _} ->
        st = %{st | dhcp: Map.delete(st.dhcp, iface)}

        case result do
          {:ok, lease} ->
            Logger.info("wifi: #{iface} bound to #{Lepton.Net.format_ip(lease.ip)}")
            {:noreply, %{st | configured: MapSet.put(st.configured, iface)}}

          err ->
            Logger.warning("wifi: DHCP on #{iface} failed: #{inspect(err)}")
            {:noreply, st}
        end

      nil ->
        {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp managed(st), do: wireless_interfaces() |> Enum.reject(&MapSet.member?(st.released, &1))

  # The summary the desktop reads (summary/0): the first managed interface's state.
  defp publish(st) do
    summary =
      case managed(st) do
        [iface | _] ->
          status = case status(iface) do
            {:ok, s} -> s
            _ -> %{}
          end

          connected? = status["wpa_state"] == "COMPLETED"

          signal =
            with true <- connected?,
                 {:ok, text} <- ctrl(iface, "SIGNAL_POLL"),
                 [_, rssi] <- Regex.run(~r/^RSSI=(-?\d+)/m, text) do
              String.to_integer(rssi)
            else
              _ -> nil
            end

          %{
            iface: iface,
            state: status["wpa_state"],
            ssid: if(connected?, do: status["ssid"]),
            ip: case Lepton.Net.leases()[iface] do
              nil -> nil
              l -> Lepton.Net.format_ip(l.ip)
            end,
            signal: signal,
            networks: st.networks,
            scanning: st.scanning != nil,
            saved: networks()
          }

        [] ->
          %{iface: nil, state: nil, ssid: nil, ip: nil, signal: nil, networks: [], scanning: false, saved: networks()}
      end

    if summary != summary(), do: :persistent_term.put({__MODULE__, :summary}, summary)
    st
  end

  defp start_supplicant(st, iface) do
    # Always the saved-networks file, so RECONFIGURE picks up changes.
    conf = conf_path()
    unless File.exists?(conf), do: write_conf([])

    port =
      Port.open({:spawn_executable, @supplicant}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1024},
        args: ["-i", iface, "-D", "nl80211", "-c", conf]
      ])

    Logger.info("wifi: wpa_supplicant started on #{iface}")
    %{st | supplicants: Map.put(st.supplicants, iface, port)}
  rescue
    e ->
      Logger.warning("wifi: cannot start wpa_supplicant on #{iface}: #{Exception.message(e)}")
      st
  end

  defp stop_supplicant(st, iface) do
    case Map.pop(st.supplicants, iface) do
      {nil, _} ->
        st

      {port, rest} ->
        ctrl(iface, "TERMINATE", 1_000)
        # Wait for it to let go of the interface (its control socket goes).
        wait_until(fn -> not File.exists?(Path.join(@ctrl_dir, iface)) end, 60)

        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

        %{st | supplicants: rest, configured: MapSet.delete(st.configured, iface)}
    end
  end

  defp wait_until(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50); wait_until(fun, tries - 1)
    end
  end

  defp dhcp(iface) do
    Lepton.Net.configure(iface)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Configure the interface by DHCP each time it (re)associates.
  defp check_dhcp(st, iface) do
    associated = match?({:ok, %{"wpa_state" => "COMPLETED"}}, status(iface))

    cond do
      not associated -> %{st | configured: MapSet.delete(st.configured, iface)}
      MapSet.member?(st.configured, iface) or Map.has_key?(st.dhcp, iface) -> st
      true -> %{st | dhcp: Map.put(st.dhcp, iface, Task.async(fn -> dhcp(iface) end).ref)}
    end
  end
end
