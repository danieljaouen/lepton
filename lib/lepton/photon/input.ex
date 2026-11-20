defmodule Lepton.Photon.Input do
  @moduledoc """
  Keyboards and pointers, from the kernel's evdev devices
  (`/dev/input/event*`).

  Each device gets a reader process that sends its target Photon events:

    * `{:key, code, pressed?}` - a key (Linux key code)
    * `{:button, code, pressed?}` - a mouse button (`BTN_LEFT` = 0x110, ...)
    * `{:motion, dx, dy}` - a mouse moved
    * `{:abs, fx, fy, n}` - tablet `n` (QEMU's and UTM's pointer, a
      drawing tablet, a touchscreen; numbered in device order) at a
      fraction of its display: with several displays, tablet `n` points
      at display `n` (QEMU binds one tablet to each display; UTM's one
      tablet is the primary display's)
    * `{:abs_px, x, y, n}` - the pointer at pixel (x, y) of display `n`
      (UTM's mouse while its SPICE agent is connected: `Lepton.VDAgent`)
    * `{:wheel, steps}` - the wheel turned (positive: down);
      `{:hwheel, steps}` - tilted, or a horizontal wheel (positive: right)

  A touchpad moves the pointer like a mouse: the finger's movement, in
  millimetres where the device says how big it is. An absolute device's
  range comes from the device (`EVIOCGABS`, through `Lepton.FD.ioctl/3`).

  Devices plugged in while Photon runs are picked up within a second.
  The devices are not grabbed: keys also reach the text console, which
  Photon mutes while it runs (`Lepton.TTY.mute/2`).
  """

  import Bitwise

  @ev_syn 0
  @ev_key 1
  @ev_rel 2
  @ev_abs 3
  @btn_left 0x110
  @btn_touch 0x14A
  @btn_tool_finger 0x145
  @key_mute 113
  @key_volumeup 115
  # QEMU's and UTM's tablets report 0..32767 on both axes (the range when
  # the device can't be asked).
  @abs_range {0, 32767}
  # A touchpad's pointer moves this many pixels per millimetre.
  @touchpad_px_per_mm 6

  @doc "Input devices Photon can use: `[{path, :keyboard | :mouse | :tablet | :touchpad}]`."
  def devices do
    for dir <- Enum.sort_by(Path.wildcard("/sys/class/input/event*"), &number/1),
        kind = kind(Path.join(dir, "device/capabilities")),
        kind != nil,
        do: {"/dev/input/" <> Path.basename(dir), kind}
  end

  defp number(path), do: path |> Path.basename() |> String.trim_leading("event") |> String.to_integer()

  defp kind(caps) do
    ev = bits(caps, "ev")
    key = bits(caps, "key")
    # INPUT_PROP_POINTER: a touchpad (it points indirectly)
    pointer? = bit?(bits(Path.join(caps, ".."), "properties"), 0)
    abs? = bit?(ev, @ev_abs) and bit?(bits(caps, "abs"), 0)

    cond do
      abs? and pointer? and bit?(key, @btn_tool_finger) -> :touchpad
      abs? and (bit?(key, @btn_left) or bit?(key, @btn_touch)) -> :tablet
      bit?(ev, @ev_rel) and bit?(bits(caps, "rel"), 0) -> :mouse
      # (a keyboard, or the media keys a keyboard has as a device of their own)
      bit?(ev, @ev_key) and (bit?(key, 30) or bit?(key, @key_volumeup) or bit?(key, @key_mute)) -> :keyboard
      true -> nil
    end
  end

  @doc "A device's name, as the kernel has it (`QEMU USB Keyboard`)."
  def name(path) do
    case File.read(Path.join(["/sys/class/input", Path.basename(path), "device/name"])) do
      {:ok, n} -> String.trim(n)
      _ -> nil
    end
  end

  @doc "Every input device: `[%{path, name, kind, usb}]` (`kind` nil for ones Photon ignores; `usb` the port path)."
  def all do
    for dir <- Enum.sort_by(Path.wildcard("/sys/class/input/event*"), &number/1) do
      path = "/dev/input/" <> Path.basename(dir)

      # The USB port path (1-1.2) is in the device's place in sysfs.
      usb =
        with {:ok, link} <- File.read_link(dir),
             [_, port] <- Regex.run(~r{/(\d+-[\d.]+):[\d.]+/}, link) do
          port
        else
          _ -> nil
        end

      %{path: path, name: name(path), kind: kind(Path.join(dir, "device/capabilities")), usb: usb}
    end
  end

  @doc "Parse a sysfs capability bitmap (hex words, most significant first)."
  def bitmap(text) do
    text
    |> String.split()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {word, i}, acc -> acc ||| String.to_integer(word, 16) <<< (64 * i) end)
  end

  defp bits(caps, name) do
    case File.read(Path.join(caps, name)) do
      {:ok, text} -> bitmap(text)
      _ -> 0
    end
  end

  defp bit?(map, n), do: (map >>> n &&& 1) == 1

  @rescan 1_000

  @doc """
  Read every device for `target`, including ones plugged in later (a USB
  keyboard or mouse, directly or through a hub): a watcher looks for new
  devices every second and starts a reader for each. A reader stops when
  its device goes away (the read fails), or after `target` has.
  """
  def start(target), do: spawn(fn -> watch(target, Process.monitor(target), %{}) end)

  defp watch(target, ref, readers) do
    devices = devices()
    tablets = for {path, :tablet} <- devices, do: path

    readers =
      Enum.reduce(devices, readers, fn {path, kind}, readers ->
        if Map.has_key?(readers, path) do
          readers
        else
          kind = if kind == :tablet, do: {:tablet, Enum.find_index(tablets, &(&1 == path))}, else: kind
          {pid, mref} = spawn_monitor(fn -> read(path, kind, target) end)
          Map.put(readers, path, {pid, mref})
        end
      end)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        :ok

      {:DOWN, mref, _, _, _} ->
        watch(target, ref, Map.reject(readers, fn {_, {_, r}} -> r == mref end))
    after
      @rescan -> watch(target, ref, readers)
    end
  end

  defp read(path, kind, target) do
    ref = Process.monitor(target)

    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, f} -> loop(f, device(f, kind), target, ref, %{})
      _ -> :ok
    end
  end

  # What decoding needs to know: the kind, and an absolute device's ranges.
  defp device(f, {:tablet, n}), do: %{device(f, :tablet) | index: n}

  defp device(f, kind) when kind in [:tablet, :touchpad] do
    {x, rx} = absinfo(f, 0)
    {y, ry} = absinfo(f, 1)
    %{kind: kind, index: 0, x: x, y: y, res: {rx, ry}}
  end

  defp device(_f, kind), do: %{kind: kind, index: 0}

  # EVIOCGABS(axis): struct input_absinfo {value, minimum, maximum, fuzz, flat, resolution}.
  defp absinfo(f, axis) do
    case Lepton.FD.ioctl(f, 0x80184540 + axis, <<0::size(24 * 8)>>) do
      {:ok, _, <<_::signed-native-32, min::signed-native-32, max::signed-native-32, _::binary-8, res::signed-native-32>>} when max > min -> {{min, max}, res}
      _ -> {@abs_range, 0}
    end
  end

  # One read returns one 24-byte input_event; a blocked read ends at the
  # next event, after which a reader whose Photon has gone stops.
  defp loop(f, kind, target, ref, acc) do
    receive do
      {:DOWN, ^ref, _, _, _} -> :file.close(f)
    after
      0 ->
        case :file.read(f, 24) do
          {:ok, <<_sec::native-64, _usec::native-64, type::native-16, code::native-16, value::native-signed-32>>} ->
            {events, acc} = decode(type, code, value, kind, acc)
            Enum.each(events, &send(target, {:input, tag(&1, kind)}))
            loop(f, kind, target, ref, acc)

          _ ->
            :file.close(f)
        end
    end
  end

  defp tag({:abs, fx, fy}, %{kind: :tablet, index: n}), do: {:abs, fx, fy, n}
  defp tag(event, _dev), do: event

  @doc """
  Turn one evdev event into Photon events. Motion is gathered until the
  `SYN_REPORT` that ends the frame. `dev` is a kind (`:mouse`, ...) or a
  device with its ranges (`%{kind, x: {min, max}, y: {min, max}, res}`).
  Returns `{events, acc}`.
  """
  def decode(type, code, value, kind, acc) when is_atom(kind),
    do: decode(type, code, value, %{kind: kind, index: 0, x: @abs_range, y: @abs_range, res: {0, 0}}, acc)

  # A touchpad's finger: where it was is kept from frame to frame.
  # (a finger put down starts from where it lands: no jump)
  def decode(@ev_key, @btn_touch, value, %{kind: :touchpad}, acc), do: {[], acc |> Map.put(:touch, value != 0) |> Map.delete(:last)}

  def decode(@ev_key, code, value, _dev, acc) when value in [0, 1] do
    cond do
      code >= @btn_left and code < @btn_left + 8 -> {[{:button, code, value == 1}], acc}
      # Other buttons (a tablet's pen, touch, tools) aren't keys.
      code >= 0x100 and code < 0x160 -> {[], acc}
      true -> {[{:key, code, value == 1}], acc}
    end
  end

  # Auto-repeat (value 2) is the client's business.
  def decode(@ev_key, _code, _value, _dev, acc), do: {[], acc}
  def decode(@ev_rel, 0, v, _dev, acc), do: {[], Map.update(acc, :dx, v, &(&1 + v))}
  def decode(@ev_rel, 1, v, _dev, acc), do: {[], Map.update(acc, :dy, v, &(&1 + v))}
  def decode(@ev_rel, 6, v, _dev, acc), do: {[], Map.update(acc, :hwheel, v, &(&1 + v))}
  def decode(@ev_rel, 8, v, _dev, acc), do: {[], Map.update(acc, :wheel, -v, &(&1 - v))}
  def decode(@ev_abs, 0, v, _dev, acc), do: {[], Map.put(acc, :ax, v)}
  def decode(@ev_abs, 1, v, _dev, acc), do: {[], Map.put(acc, :ay, v)}

  def decode(@ev_syn, 0, _v, %{kind: :touchpad} = dev, acc) do
    {lx, ly} = acc[:last] || {nil, nil}
    x = acc[:ax] || lx
    y = acc[:ay] || ly
    {events, _} = decode(@ev_syn, 0, 0, %{dev | kind: :mouse}, Map.drop(acc, [:ax, :ay, :last, :touch]))

    # Movement while the finger is down, scaled to pixels.
    moved =
      if acc[:touch] != false and lx != nil and x != nil and {x, y} != {lx, ly} do
        {sx, sy} = touch_scale(dev)
        [{:motion, (x - lx) * sx, (y - ly) * sy}]
      else
        []
      end

    {moved ++ events, %{touch: Map.get(acc, :touch, true), last: if(x, do: {x, y})}}
  end

  def decode(@ev_syn, 0, _v, dev, acc) do
    motion = if Map.has_key?(acc, :dx) or Map.has_key?(acc, :dy), do: [{:motion, acc[:dx] || 0, acc[:dy] || 0}], else: []
    abs = if Map.has_key?(acc, :ax) or Map.has_key?(acc, :ay), do: [{:abs, fraction(acc[:ax], dev[:x]), fraction(acc[:ay], dev[:y])}], else: []
    wheel = if acc[:wheel], do: [{:wheel, acc[:wheel]}], else: []
    hwheel = if acc[:hwheel], do: [{:hwheel, acc[:hwheel]}], else: []
    {motion ++ abs ++ wheel ++ hwheel, %{}}
  end

  def decode(_type, _code, _value, _dev, acc), do: {[], acc}

  defp fraction(nil, _), do: nil
  defp fraction(v, {min, max}), do: min(max((v - min) / (max - min), 0.0), 1.0)

  # Pixels per device unit: by the device's resolution (units per mm),
  # else as if the pad were 100 mm wide (and its units square).
  defp touch_scale(%{x: {x0, x1}, res: {rx, ry}}) do
    sx = if rx > 0, do: @touchpad_px_per_mm / rx, else: 100 * @touchpad_px_per_mm / (x1 - x0)
    sy = if ry > 0, do: @touchpad_px_per_mm / ry, else: sx
    {sx, sy}
  end
end
