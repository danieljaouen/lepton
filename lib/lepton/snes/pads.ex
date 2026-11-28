defmodule Lepton.SNES.Pads do
  @moduledoc """
  Game controllers for the SNES emulator: USB and Bluetooth gamepads,
  read from their input devices (`/dev/input/event*`, which only root may
  read: Lepton reads them, and the window passes the buttons on to the
  frontend). Photon leaves gamepads alone, so nothing else sees them.

  Up to two pads, players 1 and 2, in the order they were plugged in; one
  plugged in during a game is found within a second, and one unplugged
  lets go of its buttons.

  Buttons go by their place, as on a SNES pad: the bottom face button is
  B, the right one A, the left one Y, the top one X (Linux reports a
  gamepad's buttons by position, `BTN_SOUTH` and so on, whatever is
  printed on them); the shoulders are L and R (the triggers too), and
  Select and Start are Select and Start. The D-pad comes as a hat, as
  D-pad buttons, or from the left stick (pushed past a quarter of its
  way). The cheap USB pads made to look like a SNES pad report as
  joysticks with numbered buttons: those get the mapping they commonly
  use (1 X, 2 A, 3 B, 4 Y, 5 L, 6 R, 9 Select, 10 Start).

  XInput pads (Xbox 360 pads, and the many made like them: Logitech's
  F310 and F710 with their switch on X, 8BitDo's in X mode) have no driver
  in Lepton's kernel, so no input device: they're read straight from USB
  by `lepton-xinput` (`xinput.c`, built with the snes app's tcc), found
  by their interface (vendor class 0xff, subclass 0x5d, protocol 1).
  """

  import Bitwise

  @ev_key 1
  @ev_abs 3

  # libretro's joypad bits: B 0, Y 1, Select 2, Start 3, Up 4, Down 5,
  # Left 6, Right 7, A 8, X 9, L 10, R 11.
  @buttons %{
    # gamepads (BTN_SOUTH, EAST, NORTH, WEST; TL, TR, TL2, TR2; SELECT, START)
    0x130 => 0, 0x131 => 8, 0x133 => 9, 0x134 => 1,
    0x136 => 10, 0x137 => 11, 0x138 => 10, 0x139 => 11,
    0x13A => 2, 0x13B => 3,
    # D-pad buttons
    0x220 => 4, 0x221 => 5, 0x222 => 6, 0x223 => 7,
    # joysticks (BTN_TRIGGER and on): the SNES-style USB pads
    0x120 => 9, 0x121 => 8, 0x122 => 0, 0x123 => 1,
    0x124 => 10, 0x125 => 11, 0x126 => 10, 0x127 => 11,
    0x128 => 2, 0x129 => 3
  }

  @abs_x 0x00
  @abs_y 0x01
  @hat_x 0x10
  @hat_y 0x11

  @doc "The joypad bit a button (evdev code) presses, or nil."
  def button(code), do: Map.get(@buttons, code)

  @doc "The gamepads plugged in: their input devices' paths, in order."
  def devices(sys \\ "/sys/class/input") do
    for dir <- Path.wildcard(Path.join(sys, "event*")) |> Enum.sort_by(&number/1),
        gamepad?(Path.join(dir, "device/capabilities")),
        do: "/dev/input/" <> Path.basename(dir)
  end

  @doc """
  The XInput pads plugged in (no driver, no input device): `%{key, device,
  interface, in, out, name}` each, `device` its `/dev/bus/usb` node, `in`
  and `out` its endpoints (hex).
  """
  def xinput(usb \\ "/sys/bus/usb/devices", dev \\ "/dev/bus/usb") do
    for dir <- Path.wildcard(Path.join(usb, "*:*")) |> Enum.sort(),
        attr(dir, "bInterfaceClass") == "ff" and attr(dir, "bInterfaceSubClass") == "5d" and attr(dir, "bInterfaceProtocol") == "01",
        parent = Path.join(usb, dir |> Path.basename() |> String.split(":") |> hd()),
        {bus, ""} <- [Integer.parse(attr(parent, "busnum") || "")],
        {num, ""} <- [Integer.parse(attr(parent, "devnum") || "")],
        ep_in = endpoint(dir, "in"),
        ep_in != nil do
      %{
        key: "usb:" <> Path.basename(dir),
        device: Path.join(dev, :io_lib.format("~3..0B/~3..0B", [bus, num]) |> to_string()),
        interface: attr(dir, "bInterfaceNumber") |> to_string() |> Integer.parse(16) |> elem(0),
        in: ep_in,
        out: endpoint(dir, "out") || "0",
        name: attr(parent, "product") || "an XInput pad"
      }
    end
  end

  defp attr(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  # An interrupt endpoint of the interface going `dir` ("in" or "out"): its address, hex.
  defp endpoint(dir, way) do
    Path.wildcard(Path.join(dir, "ep_*"))
    |> Enum.find_value(fn ep ->
      if attr(ep, "direction") == way and attr(ep, "type") == "Interrupt", do: attr(ep, "bEndpointAddress")
    end)
  end

  defp number(path), do: path |> Path.basename() |> String.trim_leading("event") |> Integer.parse() |> elem(0)

  @doc "Do a device's capabilities (its sysfs folder) make it a gamepad or joystick?"
  def gamepad?(caps) do
    ev = bits(caps, "ev")
    key = bits(caps, "key")
    (ev >>> @ev_key &&& 1) == 1 and (key >>> 0x120 &&& 0xFFFFFFFF) != 0
  end

  defp bits(caps, name) do
    case File.read(Path.join(caps, name)) do
      {:ok, text} -> Lepton.Photon.Input.bitmap(text)
      _ -> 0
    end
  end

  @doc """
  Read the pads for `target`, which gets `{:snes_pad, player, buttons}`
  (player 0 or 1; `buttons` libretro's bits) whenever they change, and
  `{:snes_pad_added, player, name}` / `{:snes_pad_removed, player}`.
  Returns the watcher's pid; it, and its readers, end with `target`, or
  when killed.
  """
  def start(target), do: spawn(fn -> watch(target, Process.monitor(target), %{}, MapSet.new()) end)

  @rescan 1_000
  # A reader that ends this soon couldn't read its pad (the device went
  # wrong, or it can't be opened): the pad is left alone, not tried again
  # every second, until it's plugged in again.
  @failed_ms 2_000

  defp watch(target, ref, readers, failed) do
    found =
      Enum.map(devices(), fn path -> {path, Lepton.Photon.Input.name(path) || "a gamepad", fn p, me -> read(path, p, target, me) end} end) ++
        Enum.map(xinput(), fn x -> {x.key, x.name, fn p, me -> read_xinput(x, p, target, me) end} end)

    # (unplugged: tried again when it comes back)
    failed = MapSet.intersection(failed, MapSet.new(found, &elem(&1, 0)))

    readers =
      Enum.reduce(found, readers, fn {key, name, reader}, readers ->
        free = Enum.find([0, 1], fn p -> not Enum.any?(readers, fn {_, r} -> r.player == p end) end)

        cond do
          Map.has_key?(readers, key) or free == nil or MapSet.member?(failed, key) ->
            readers

          true ->
            me = self()
            {pid, mref} = spawn_monitor(fn -> reader.(free, me) end)
            send(target, {:snes_pad_added, free, name})
            Map.put(readers, key, %{pid: pid, ref: mref, player: free, since: System.monotonic_time(:millisecond)})
        end
      end)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        Enum.each(readers, fn {_, r} -> Process.exit(r.pid, :kill) end)

      {:DOWN, mref, _, _, _} ->
        case Enum.find(readers, fn {_, r} -> r.ref == mref end) do
          {key, r} ->
            send(target, {:snes_pad, r.player, 0})
            send(target, {:snes_pad_removed, r.player})
            quick = System.monotonic_time(:millisecond) - r.since < @failed_ms
            watch(target, ref, Map.delete(readers, key), if(quick, do: MapSet.put(failed, key), else: failed))

          nil ->
            watch(target, ref, readers, failed)
        end
    after
      @rescan -> watch(target, ref, readers, failed)
    end
  end

  defp read(path, player, target, watcher) do
    Process.link(watcher)

    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, f} ->
        dev = %{x: range(f, @abs_x), y: range(f, @abs_y)}
        loop(f, dev, player, target, %{keys: 0, hat: {0, 0}, stick: {0, 0}}, 0)

      _ ->
        :ok
    end
  end

  # An XInput pad, through lepton-xinput: its reports, as they come.
  defp read_xinput(x, player, target, watcher) do
    Process.link(watcher)

    with {:ok, exe} <- Lepton.SNES.xinput_reader() do
      port = Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :exit_status, args: [x.device, "#{x.interface}", x.in, x.out]])
      xinput_loop(port, player, target, 0)
    end
  end

  defp xinput_loop(port, player, target, sent) do
    receive do
      {^port, {:data, report}} ->
        case xinput_mask(report) do
          nil -> xinput_loop(port, player, target, sent)
          ^sent -> xinput_loop(port, player, target, sent)
          now -> send(target, {:snes_pad, player, now}); xinput_loop(port, player, target, now)
        end

      {^port, {:exit_status, _}} ->
        :ok
    end
  end

  @doc """
  An XInput report's buttons, as the SNES's (libretro's bits), or nil for
  a report that isn't the buttons. By place, as on a SNES pad: A (the
  bottom button) is B, B is A, X is Y, Y is X; the bumpers and triggers L
  and R; Back Select, Start Start; the D-pad, or the left stick past a
  quarter of its way.
  """
  def xinput_mask(<<0, len, b1, b2, lt, rt, lx::little-signed-16, ly::little-signed-16, _::binary>>) when len >= 14 do
    bit = fn byte, n, to -> if (byte >>> n &&& 1) == 1, do: 1 <<< to, else: 0 end
    up = (b1 &&& 1) != 0 or ly > 8192
    down = (b1 &&& 2) != 0 or ly < -8192
    left = (b1 &&& 4) != 0 or lx < -8192
    right = (b1 &&& 8) != 0 or lx > 8192

    bit.(b2, 4, 0) ||| bit.(b2, 5, 8) ||| bit.(b2, 6, 1) ||| bit.(b2, 7, 9) |||
      bit.(b2, 0, 10) ||| bit.(b2, 1, 11) ||| if(lt > 128, do: 1 <<< 10, else: 0) ||| if(rt > 128, do: 1 <<< 11, else: 0) |||
      bit.(b1, 5, 2) ||| bit.(b1, 4, 3) |||
      if(up, do: 1 <<< 4, else: 0) ||| if(down, do: 1 <<< 5, else: 0) ||| if(left, do: 1 <<< 6, else: 0) ||| if(right, do: 1 <<< 7, else: 0)
  end

  def xinput_mask(_), do: nil

  # EVIOCGABS(axis): {minimum, maximum}, or nil.
  defp range(f, axis) do
    case Lepton.FD.ioctl(f, 0x80184540 + axis, <<0::size(24 * 8)>>) do
      {:ok, _, <<_::signed-native-32, min::signed-native-32, max::signed-native-32, _::binary>>} when max > min -> {min, max}
      _ -> nil
    end
  end

  defp loop(f, dev, player, target, st, sent) do
    case :file.read(f, 24) do
      {:ok, <<_sec::native-64, _usec::native-64, type::native-16, code::native-16, value::native-signed-32>>} ->
        st = decode(type, code, value, dev, st)
        now = mask(st)
        if now != sent, do: send(target, {:snes_pad, player, now})
        loop(f, dev, player, target, st, now)

      _ ->
        :file.close(f)
    end
  end

  @doc false
  # One event into the pad's state: `%{keys, hat: {x, y}, stick: {x, y}}`
  # (each of x, y: -1, 0 or 1); `dev` has the stick's ranges.
  def decode(@ev_key, code, value, _dev, st) do
    case button(code) do
      nil -> st
      bit when value == 0 -> %{st | keys: st.keys &&& bnot(1 <<< bit)}
      bit -> %{st | keys: st.keys ||| 1 <<< bit}
    end
  end

  def decode(@ev_abs, @hat_x, v, _dev, st), do: %{st | hat: {sign(v), elem(st.hat, 1)}}
  def decode(@ev_abs, @hat_y, v, _dev, st), do: %{st | hat: {elem(st.hat, 0), sign(v)}}
  def decode(@ev_abs, @abs_x, v, dev, st), do: %{st | stick: {axis(v, dev.x), elem(st.stick, 1)}}
  def decode(@ev_abs, @abs_y, v, dev, st), do: %{st | stick: {elem(st.stick, 0), axis(v, dev.y)}}
  def decode(_type, _code, _value, _dev, st), do: st

  defp sign(v) when v < 0, do: -1
  defp sign(v) when v > 0, do: 1
  defp sign(_), do: 0

  # A stick's position: past a quarter of the way from the middle, a direction.
  defp axis(_v, nil), do: 0

  defp axis(v, {min, max}) do
    mid = (min + max) / 2
    quarter = (max - min) / 8

    cond do
      v < mid - quarter -> -1
      v > mid + quarter -> 1
      true -> 0
    end
  end

  @doc "The buttons a pad's state presses: libretro's bits."
  def mask(%{keys: keys, hat: {hx, hy}, stick: {sx, sy}}) do
    x = if hx != 0, do: hx, else: sx
    y = if hy != 0, do: hy, else: sy
    keys ||| if(y < 0, do: 1 <<< 4, else: 0) ||| if(y > 0, do: 1 <<< 5, else: 0) ||| if(x < 0, do: 1 <<< 6, else: 0) ||| if(x > 0, do: 1 <<< 7, else: 0)
  end
end
