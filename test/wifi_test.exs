defmodule Lepton.WifiTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Kmod, Wifi}

  setup do
    state = tmp_dir("wifistate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    :ok
  end

  test "saved networks: several, replaced by SSID, forgotten one at a time, PSK not passphrase" do
    :ok = Wifi.save("Home", "correct horse")
    :ok = Wifi.save("Café ☕", "battery staple")
    :ok = Wifi.save("Guest", "")
    :ok = Wifi.save("Home", "new passphrase")
    assert Wifi.networks() == ["Café ☕", "Guest", "Home"]

    conf = File.read!(Wifi.conf_path())
    assert conf =~ "ctrl_interface=/run/wpa_supplicant\n"
    assert conf =~ "psk=#{Wifi.psk("Home", "new passphrase")}"
    refute conf =~ "passphrase" or conf =~ "correct horse"
    assert conf =~ "ssid=\"Guest\"\n\tkey_mgmt=NONE"
    assert File.stat!(Wifi.conf_path()).mode |> Bitwise.band(0o777) == 0o600

    assert Wifi.forget("Guest") == :ok
    assert Wifi.forget("Nope") == {:error, :not_found}
    assert Wifi.networks() == ["Café ☕", "Home"]
    assert Wifi.forget(nil) == :ok
    assert Wifi.networks() == []
  end

  test "the wpa_passphrase PSK and SSIDs wpa_supplicant can't take quoted" do
    assert Wifi.psk("IEEE", "password") == "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
    block = Wifi.network_block(~s(say "hi"), "")
    assert block =~ "ssid=#{Base.encode16(~s(say "hi"), case: :lower)}\n"
    assert Wifi.block_ssid(block) == ~s(say "hi")
  end

  test "parses wpa_supplicant's STATUS and SCAN_RESULTS" do
    st = Wifi.parse_status("bssid=02:00:00:00:01:00\nfreq=2412\nssid=lepton-test\nwpa_state=COMPLETED\nkey_mgmt=WPA2-PSK\n")
    assert st["wpa_state"] == "COMPLETED" and st["ssid"] == "lepton-test"

    results = """
    bssid / frequency / signal level / flags / ssid
    aa:bb:cc:00:00:01\t2412\t-71\t[WPA2-PSK-CCMP][ESS]\tHome
    aa:bb:cc:00:00:02\t5180\t-48\t[WPA2-PSK-CCMP][ESS]\tHome
    aa:bb:cc:00:00:03\t2437\t-60\t[WPA2-PSK+SAE-CCMP][ESS]\tMixed
    aa:bb:cc:00:00:04\t2462\t-80\t[ESS]\tCoffee Shop
    aa:bb:cc:00:00:05\t2462\t-30\t[RSN-SAE-CCMP][ESS]\t
    """

    assert Wifi.parse_scan(results) == [
             %{ssid: "Home", frequency: 5180, signal: -48, security: "WPA2"},
             %{ssid: "Mixed", frequency: 2437, signal: -60, security: "WPA2/WPA3"},
             %{ssid: "Coffee Shop", frequency: 2462, signal: -80, security: "open"}
           ]
  end

  test "drivers are found by hardware ID, as modules.alias describes them" do
    table =
      Kmod.parse_aliases("""
      alias usb:v148Fp7601d*dc*dsc*dp*ic*isc*ip*in* mt7601u
      alias usb:v0BDAp8179d*dc*dsc*dp*icFFiscFFipFFin* rtl8xxxu
      alias usb:v0BDAp*d*dc*dsc*dp*ic[0-9A]*isc*ip*in* rtw88-8822bu
      alias pci:v00001B36d00000007sv*sd*bc*sc*i* sdhci-pci
      alias acpi:QEMU0002:* fw_cfg
      """)

    assert length(table) == 4
    assert Kmod.modules_for("pci:v00001B36d00000007sv00001AF4sd00001100bc08sc05i01", table) == ["sdhci_pci"]
    assert Kmod.modules_for("usb:v148Fp7601d0000dc00dsc00dp00icFFiscFFipFFin00", table) == ["mt7601u"]
    assert Kmod.modules_for("usb:v0BDAp8179d0200dc00dsc00dp00icFFiscFFipFFin00", table) == ["rtl8xxxu"]
    assert Kmod.modules_for("usb:v0BDAp1234d0000dc00dsc00dp00icAisc00ip00in00", table) == ["rtw88_8822bu"]
    assert Kmod.modules_for("usb:v0BDAp1234d0000dc00dsc00dp00icBisc00ip00in00", table) == []
  end

  test "choosing a saved network: its id in wpa_supplicant's list" do
    list = "network id / ssid / bssid / flags\n0\thome\tany\t\n1\tBob's Wi-Fi\tany\t[CURRENT]\n"
    assert Wifi.network_id(list, "Bob's Wi-Fi") == "1"
    assert Wifi.network_id(list, "home") == "0"
    assert Wifi.network_id(list, "elsewhere") == nil
    assert Enum.map([-40, -60, -70, -90, nil], &Wifi.bars/1) == [4, 3, 2, 1, 0]
  end

  test "the classic desktop's Wi-Fi applet: signal in the tray, networks to join" do
    alias Lepton.Photon.WM.Classic
    key = {Wifi, :summary}
    # On a machine with Wi-Fi of its own the service runs, and its refreshes
    # (opening the list scans) would put the real state over this one: it
    # waits until the test is done.
    wifi = Process.whereis(Wifi)
    if wifi, do: :sys.suspend(wifi)

    on_exit(fn ->
      :persistent_term.erase(key)
      if wifi && Process.alive?(wifi), do: :sys.resume(wifi)
    end)

    nets = [%{ssid: "home", signal: -50, security: "WPA2", frequency: 2437}, %{ssid: "Bob's café", signal: -80, security: "open", frequency: 5180}]
    :persistent_term.put(key, %{iface: "wlan0", state: "COMPLETED", ssid: "home", ip: "192.168.1.5", signal: -50, networks: nets, scanning: false, saved: ["home"]})

    s = Classic.init(1024, 768, {1024, 768})
    tray = Classic.tray(s)
    assert tray.wifi != nil and tray.speaker == tray.wifi + 20
    assert {:handled, %{wifi: true} = s, []} = Classic.click(s, [], {tray.wifi + 4, 760}, 0x110, false)
    assert {_below, [_taskbar, _popup]} = Classic.layers(s, [])

    %{rows: [{_, home}, {_, cafe}]} = Classic.wifi_layout(s)
    center = fn {x, y, w, h} -> {x + div(w, 2), y + div(h, 2)} end
    # The network it's on: nothing to do. Another: a terminal joins it.
    assert {:handled, %{wifi: true}, []} = Classic.click(s, [], center.(home), 0x110, false)
    assert {:handled, %{wifi: false}, [{:spawn, opts}]} = Classic.click(s, [], center.(cafe), 0x110, false)
    assert opts[:wifi] == "Bob's café" and opts[:open] == true
    # Clicking elsewhere closes the list.
    assert {_, %{wifi: false}, _} = Classic.click(s, [], {500, 300}, 0x110, false)

    # The terminal's command, quoted for the shell (and without sudo for root).
    cmd = Lepton.Commands.Desktop.wifi_command("Bob's café", true, false)
    assert cmd =~ ~r/^sudo wifi connect 'Bob'\\''s café' '' && /
    assert {"Bob's café\n", 0} = sh("echo 'Bob'\\''s café'")
    refute Lepton.Commands.Desktop.wifi_command("home", false, true) =~ "sudo"

    # No Wi-Fi hardware: no icon.
    :persistent_term.put(key, %{Wifi.summary() | iface: nil})
    assert Classic.tray(s).wifi == nil
  end

  # Two simulated radios (mac80211_hwsim): hostapd runs a WPA2 network on
  # one, and Lepton's manager joins it from the other with `wifi connect`.
  @tag :native
  test "joins a WPA2 network: hostapd on one simulated radio, wpa_supplicant on the other" do
    before = Wifi.wireless_interfaces()
    :ok = Kmod.modprobe("mac80211_hwsim", ["radios=2"])
    on_exit(fn -> Kmod.rmmod("mac80211_hwsim") end)
    assert eventually(fn -> length(Wifi.wireless_interfaces() -- before) == 2 end)
    [sta, ap] = Wifi.wireless_interfaces() -- before

    # The access point's radio is hostapd's, not the manager's.
    :ok = Wifi.release(ap)
    dir = tmp_dir("hostapd")

    File.write!(Path.join(dir, "hostapd.conf"), """
    interface=#{ap}
    driver=nl80211
    ssid=lepton-test
    hw_mode=g
    channel=6
    wpa=2
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
    wpa_passphrase=hunter2hunter2
    """)

    hostapd = Port.open({:spawn_executable, "/usr/libexec/lepton/hostapd"}, [:binary, :exit_status, :stderr_to_stdout, args: [Path.join(dir, "hostapd.conf")]])
    on_exit(fn ->
      try do
        Port.close(hostapd)
      rescue
        _ -> :ok
      end
    end)
    assert await_output(hostapd, "AP-ENABLED", 15_000), "hostapd did not start"

    # The manager has started wpa_supplicant on the station radio.
    assert eventually(fn -> match?({:ok, _}, Wifi.status(sta)) end, 200)
    {:ok, nets} = Wifi.scan(sta)
    assert %{ssid: "lepton-test", security: "WPA2", frequency: 2437} = Enum.find(nets, &(&1.ssid == "lepton-test"))

    {_, 0} = sh("wifi connect lepton-test hunter2hunter2 || true", home: tmp_dir("wifihome"))
    assert eventually(fn -> match?({:ok, %{"wpa_state" => "COMPLETED", "ssid" => "lepton-test"}}, Wifi.status(sta)) end, 300)
    {:ok, st} = Wifi.status(sta)
    assert st["key_mgmt"] == "WPA2-PSK" and st["pairwise_cipher"] == "CCMP"

    {out, 0} = sh("wifi", home: tmp_dir("wifihome"))
    assert out =~ "wireless #{sta}: "
    assert out =~ "saved Wi-Fi networks: lepton-test"

    # What the desktop's applet sees, and a saved network joined again
    # without its passphrase.
    assert eventually(fn -> match?(%{iface: ^sta, ssid: "lepton-test"}, Wifi.summary()) end, 100)
    Wifi.scan_async()
    assert eventually(fn -> Enum.any?(Wifi.summary().networks, &(&1.ssid == "lepton-test")) end, 200)
    # (no DHCP server on the simulated network, so it ends without an address)
    assert {out, 0} = sh("wifi connect lepton-test || true", home: tmp_dir("wifihome"))
    assert out =~ "Connecting to \"lepton-test\""
    assert out =~ "Associated with lepton-test"
    assert Wifi.networks() == ["lepton-test"]
    :ok = Wifi.manage(ap)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  defp await_output(port, text, timeout, acc \\ "") do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if String.contains?(acc, text), do: true, else: await_output(port, text, timeout, acc)

      {^port, {:exit_status, _}} ->
        false
    after
      timeout -> false
    end
  end
end
