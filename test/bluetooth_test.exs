defmodule Lepton.Test.FakeHCI do
  @moduledoc """
  A pretend Bluetooth controller for the self-tests, through the kernel's
  virtual HCI driver (`/dev/vhci`, module `hci_vhci`): the kernel sends it
  HCI commands and it answers them, so the kernel and BlueZ see an
  adapter (address `@address`). While the kernel inquires, it reports one
  device: a keyboard called "Lepton Test Keyboard" (and it advertises as
  one while the kernel scans for Low Energy devices). Connecting to that
  keyboard fails as if it were switched off (page timeout).
  """

  @address <<0x01, 0x00, 0x00, 0x0E, 0x70, 0x1E>>
  @device <<0x02, 0x00, 0x00, 0x0E, 0x70, 0x1E>>
  @device_name "Lepton Test Keyboard"

  def address, do: "1E:70:0E:00:00:01"
  def device_address, do: "1E:70:0E:00:00:02"
  def device_name, do: @device_name

  @doc "Start the controller; returns the process (stop it to remove the adapter)."
  def start do
    :ok = Lepton.Kmod.modprobe("hci_vhci")
    me = self()

    pid =
      spawn(fn ->
        # Each read of /dev/vhci is one packet (and a short buffer loses the
        # rest), so it is read through a port, which does one read() at a
        # time, rather than :file, which reads until its buffer is full.
        {:ok, f} = :file.open(~c"/dev/vhci", [:raw, :binary, :read, :write])
        <<fd::native-32>> = :prim_file.get_handle(f)
        port = Port.open({:fd, fd, fd}, [:binary])
        # A primary (BR/EDR and LE) controller.
        Port.command(port, <<0xFF, 0x00>>)
        send(me, {:fake_hci, self()})
        loop(port, f)
      end)

    receive do
      {:fake_hci, ^pid} -> pid
    after
      5000 -> raise "no /dev/vhci"
    end
  end

  defp loop(port, f) do
    receive do
      {^port, {:data, <<0x01, opcode::little-16, _len, params::binary>>}} ->
        # What a device sends comes a moment after the command is answered,
        # as over the air (the kernel ignores results before it is ready for them).
        {now, later} = Enum.split_while(answer(opcode, params), &(&1 != :later))
        Enum.each(now, &Port.command(port, &1))
        if later != [], do: Process.send_after(self(), {:send, tl(later)}, 300)
        loop(port, f)

      {:send, packets} ->
        Enum.each(packets, &Port.command(port, &1))
        loop(port, f)

      {^port, {:data, _other}} ->
        loop(port, f)

      :stop ->
        Port.close(port)
        :file.close(f)
    end
  end

  # Commands answered with Command Status (their results come as events).
  @status_only [0x0401, 0x0405, 0x0419, 0x041B, 0x041C, 0x200D, 0x2043]

  defp answer(0x0401, _params) do
    # Inquiry: our keyboard, then the end of the inquiry.
    eir = eir(0x09, @device_name)
    result = <<1>> <> @device <> <<0x01, 0x00, 0x40, 0x25, 0x00, 0x00, 0x00, -50::signed>> <> pad(eir, 240)
    [status(0x0401), :later, event(0x2F, result), event(0x01, <<0>>)]
  end

  defp answer(0x0405, <<bdaddr::binary-6, _::binary>>) do
    # Create Connection: nobody there (page timeout).
    [status(0x0405), :later, event(0x03, <<0x04, 0::little-16>> <> bdaddr <> <<0x01, 0x00>>)]
  end

  defp answer(0x200C, <<1, _::binary>>) do
    # LE Set Scan Enable (on): the keyboard advertises its name and appearance.
    data = <<2, 0x01, 0x06>> <> eir(0x09, @device_name) <> <<3, 0x19, 0xC1, 0x03>>
    report = <<0x02, 1, 0x00, 0x00>> <> @device <> <<byte_size(data)>> <> data <> <<-50::signed>>
    [complete(0x200C, <<0>>), :later, event(0x3E, report)]
  end

  defp answer(0x200D, params) do
    # LE Create Connection: no answer either (connection failed to be established).
    <<_::binary-6, _filter, addr_type, bdaddr::binary-6, _::binary>> = params
    [status(0x200D), :later, event(0x3E, <<0x01, 0x3E, 0::little-16, 0, addr_type>> <> bdaddr <> <<0::size(7 * 8)>>)]
  end

  defp answer(opcode, _params) when opcode in @status_only, do: [status(opcode)]
  defp answer(opcode, _params), do: [complete(opcode, <<0>> <> result(opcode))]

  # Return parameters (after the status) the kernel reads during setup.
  defp result(0x1001), do: <<0x09, 0x0000::little-16, 0x09, 0x05F1::little-16, 0x0000::little-16>>
  defp result(0x1002), do: :binary.copy(<<0>>, 64)
  defp result(0x1003), do: <<0xFF, 0xFE, 0x0F, 0xFE, 0xDB, 0xFF, 0x7B, 0x87>>
  defp result(0x1004), do: <<1, 1>> <> :binary.copy(<<0>>, 8)
  defp result(0x1005), do: <<1021::little-16, 255, 8::little-16, 0::little-16>>
  defp result(0x1009), do: @address
  defp result(0x0C14), do: pad("Lepton", 248)
  defp result(0x0C23), do: <<0x0C, 0x01, 0x1C>>
  defp result(0x2002), do: <<251::little-16, 8>>
  defp result(0x2003), do: :binary.copy(<<0>>, 8)
  defp result(0x201C), do: :binary.copy(<<0xFF>>, 8)
  defp result(_), do: :binary.copy(<<0>>, 32)

  defp complete(opcode, ret), do: event(0x0E, <<1, opcode::little-16>> <> ret)
  defp status(opcode), do: event(0x0F, <<0, 1, opcode::little-16>>)
  defp event(code, params), do: <<0x04, code, byte_size(params)>> <> params

  defp eir(type, data), do: <<byte_size(data) + 1, type>> <> data
  defp pad(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))
end

defmodule Lepton.BluetoothTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Bluetooth
  alias Lepton.Photon.WM.Classic
  alias Lepton.Test.FakeHCI

  defp device(name, address, attrs \\ []) do
    Map.merge(%{path: "/org/bluez/hci0/dev_" <> String.replace(address, ":", "_"), address: address, name: name, kind: :device, paired: false, connected: false, trusted: false, rssi: nil, battery: nil}, Map.new(attrs))
  end

  test "devices: by address or name, and what they are" do
    devices = [device("MX Keys", "AA:BB:CC:DD:EE:01"), device("Speaker", "AA:BB:CC:DD:EE:02"), device("Speaker", "AA:BB:CC:DD:EE:03")]
    assert {:ok, %{name: "MX Keys"}} = Bluetooth.find(devices, "mx keys")
    assert {:ok, %{address: "AA:BB:CC:DD:EE:02"}} = Bluetooth.find(devices, "aa:bb:cc:dd:ee:02")
    assert {:error, "several devices are called \"Speaker\"" <> _} = Bluetooth.find(devices, "Speaker")
    assert {:error, "no device \"Mouse\"" <> _} = Bluetooth.find(devices, "Mouse")
    assert Enum.map(~w(input-keyboard input-mouse audio-headphones audio-headset phone x), &Bluetooth.kind/1) == [:keyboard, :mouse, :headphones, :headphones, :phone, :device]
  end

  test "the classic desktop's Bluetooth applet: devices to pair, connect or disconnect" do
    key = {Bluetooth, :summary}
    # The running Bluetooth service (inside Lepton) would put the real state
    # (no adapter) over this one: it waits until the test is done.
    bt = Process.whereis(Bluetooth)
    if bt, do: :sys.suspend(bt)

    on_exit(fn ->
      :persistent_term.erase(key)
      if bt && Process.alive?(bt), do: :sys.resume(bt)
    end)

    devices = [
      device("Headphones", "AA:BB:CC:DD:EE:01", kind: :headphones, paired: true, connected: true),
      device("Mouse", "AA:BB:CC:DD:EE:02", kind: :mouse, paired: true),
      device("Bob's Keyboard", "AA:BB:CC:DD:EE:03", kind: :keyboard, rssi: -60)
    ]

    :persistent_term.put(key, %{installed: true, running: true, controllers: ["hci0"], adapter: %{path: "/org/bluez/hci0", address: "00:11:22:33:44:55", name: "lepton", powered: true, discovering: true}, devices: devices, outputs: []})

    s = Classic.init(1024, 768, {1024, 768})
    tray = Classic.tray(s)
    assert tray.bluetooth != nil and tray.speaker == tray.bluetooth + 20
    assert {:handled, %{bluetooth: true} = s, []} = Classic.click(s, [], {tray.bluetooth + 8, 760}, 0x110, false)
    assert {_below, [_taskbar, _popup]} = Classic.layers(s, [])

    %{rows: [{_, phones}, {_, mouse}, {_, kbd}], button: button} = Classic.bt_layout(s)
    center = fn {x, y, w, h} -> {x + div(w, 2), y + div(h, 2)} end
    run = fn pos -> {:handled, %{bluetooth: false}, [{:spawn, opts}]} = Classic.click(s, [], pos, 0x110, false); opts[:bluetooth] end
    assert run.(center.(phones)) == ["disconnect", "AA:BB:CC:DD:EE:01"]
    assert run.(center.(mouse)) == ["connect", "AA:BB:CC:DD:EE:02"]
    assert run.(center.(kbd)) == ["pair", "AA:BB:CC:DD:EE:03"]
    assert run.(center.(button)) == ["off"]
    assert {_, %{bluetooth: false}, _} = Classic.click(s, [], {500, 300}, 0x110, false)

    assert Lepton.Commands.Desktop.bluetooth_command(["pair", "AA:BB:CC:DD:EE:03"], false) =~ ~r/^sudo bluetooth pair AA:BB:CC:DD:EE:03 && /
    assert Lepton.Commands.Desktop.bluetooth_command(["install"], true) =~ ~r/^app install bluetooth && /

    # Not installed yet: the button installs it. No adapter: no icon.
    :persistent_term.put(key, %{Bluetooth.summary() | installed: false, adapter: nil, devices: []})
    assert run.(center.(Classic.bt_layout(s).button)) == ["install"]
    :persistent_term.put(key, %{Bluetooth.summary() | controllers: []})
    assert Classic.tray(s).bluetooth == nil
  end

  test "bluetooth: usage" do
    assert {"", 2} = sh("bluetooth frob")
    assert {"", 1} = sh("bluetooth scan 500")
    unless Lepton.Apps.installed?("bluetooth") do
      assert {"Bluetooth isn't installed. Install it with: sudo app install bluetooth\n", 0} = sh("bluetooth")
    end
  end

  # Inside Lepton: Bluetooth installed (from Alpine: the network), a
  # pretend adapter, the keyboard it finds, and pairing with a keyboard
  # that doesn't answer.
  @tag :native
  @tag :network
  @tag timeout: 300_000
  test "Bluetooth with a pretend adapter: on, a scan finds a keyboard, pairing fails cleanly" do
    unless Lepton.Apps.installed?("bluetooth"), do: assert(:ok = Lepton.Apps.install("bluetooth"))
    assert eventually(fn -> :sys.get_state(Bluetooth).agent_registered end, 150), "bluetoothd didn't start, or the agent wasn't registered"

    hci = FakeHCI.start()
    on_exit(fn -> send(hci, :stop) end)
    assert eventually(fn -> match?(%{adapter: %{powered: true}}, Bluetooth.summary()) end, 150)
    assert Bluetooth.summary().adapter.address == FakeHCI.address()
    assert {out, 0} = sh("bluetooth")
    assert out =~ "Bluetooth is on: "

    assert {out, 0} = sh("bluetooth scan 8")
    assert out =~ ~r/#{FakeHCI.device_address()}\s+Lepton Test Keyboard\s+keyboard/

    assert {out, 1} = sh("bluetooth pair '#{FakeHCI.device_name()}'")
    assert out =~ "Pairing with Lepton Test Keyboard"
    refute Enum.find(Bluetooth.summary().devices, &(&1.name == FakeHCI.device_name())).paired
  end

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end
end
