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

  @doc "The gamepads plugged in: their device paths, in order."
  def devices(sys \\ "/sys/class/input") do
    for dir <- Path.wildcard(Path.join(sys, "event*")) |> Enum.sort_by(&number/1),
        gamepad?(Path.join(dir, "device/capabilities")),
        do: "/dev/input/" <> Path.basename(dir)
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
  def start(target), do: spawn(fn -> watch(target, Process.monitor(target), %{}) end)

  @rescan 1_000

  defp watch(target, ref, readers) do
    readers =
      Enum.reduce(devices(), readers, fn path, readers ->
        free = Enum.find([0, 1], fn p -> not Enum.any?(readers, fn {_, {_, _, q}} -> q == p end) end)

        cond do
          Map.has_key?(readers, path) or free == nil ->
            readers

          true ->
            me = self()
            {pid, mref} = spawn_monitor(fn -> read(path, free, target, me) end)
            send(target, {:snes_pad_added, free, Lepton.Photon.Input.name(path) || "a gamepad"})
            Map.put(readers, path, {pid, mref, free})
        end
      end)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        Enum.each(readers, fn {_, {pid, _, _}} -> Process.exit(pid, :kill) end)

      {:DOWN, mref, _, _, _} ->
        case Enum.find(readers, fn {_, {_, r, _}} -> r == mref end) do
          {path, {_, _, player}} ->
            send(target, {:snes_pad, player, 0})
            send(target, {:snes_pad_removed, player})
            watch(target, ref, Map.delete(readers, path))

          nil ->
            watch(target, ref, readers)
        end
    after
      @rescan -> watch(target, ref, readers)
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
