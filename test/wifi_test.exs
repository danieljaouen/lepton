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
      alias pci:v00001AF4d00001050sv*sd*bc*sc*i* virtio_gpu
      """)

    assert length(table) == 3
    assert Kmod.modules_for("usb:v148Fp7601d0000dc00dsc00dp00icFFiscFFipFFin00", table) == ["mt7601u"]
    assert Kmod.modules_for("usb:v0BDAp8179d0200dc00dsc00dp00icFFiscFFipFFin00", table) == ["rtl8xxxu"]
    assert Kmod.modules_for("usb:v0BDAp1234d0000dc00dsc00dp00icAisc00ip00in00", table) == ["rtw88_8822bu"]
    assert Kmod.modules_for("usb:v0BDAp1234d0000dc00dsc00dp00icBisc00ip00in00", table) == []
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
