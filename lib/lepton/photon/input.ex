defmodule Lepton.Photon.Input do
  @moduledoc """
  Keyboards and pointers, from the kernel's evdev devices
  (`/dev/input/event*`).

  Each device gets a reader process that sends its target Photon events:

    * `{:key, code, pressed?}` - a key (Linux key code)
    * `{:button, code, pressed?}` - a mouse button (`BTN_LEFT` = 0x110, ...)
    * `{:motion, dx, dy}` - a mouse moved
    * `{:abs, fx, fy}` - a tablet (QEMU's and UTM's pointer) at a fraction
      of the screen
    * `{:wheel, steps}` - the wheel turned (positive: down)

  The devices are not grabbed: keys also reach the text console, which
  Photon mutes while it runs (`Lepton.TTY.mute/2`).
  """

  import Bitwise

  @ev_syn 0
  @ev_key 1
  @ev_rel 2
  @ev_abs 3
  @btn_left 0x110
  # QEMU's and UTM's tablets report 0..32767 on both axes.
  @abs_max 32767

  @doc "Input devices Photon can use: `[{path, :keyboard | :mouse | :tablet}]`."
  def devices do
    for dir <- Path.wildcard("/sys/class/input/event*"),
        kind = kind(Path.join(dir, "device/capabilities")),
        kind != nil,
        do: {"/dev/input/" <> Path.basename(dir), kind}
  end

  defp kind(caps) do
    ev = bits(caps, "ev")
    key = bits(caps, "key")

    cond do
      bit?(ev, @ev_abs) and bit?(bits(caps, "abs"), 0) and bit?(key, @btn_left) -> :tablet
      bit?(ev, @ev_rel) and bit?(bits(caps, "rel"), 0) -> :mouse
      bit?(ev, @ev_key) and bit?(key, 30) -> :keyboard
      true -> nil
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

  @doc "Start reading every device for `target`."
  def start(target) do
    for {path, kind} <- devices(), do: spawn(fn -> read(path, kind, target) end)
  end

  defp read(path, kind, target) do
    ref = Process.monitor(target)

    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, f} -> loop(f, kind, target, ref, %{})
      _ -> :ok
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
            Enum.each(events, &send(target, {:input, &1}))
            loop(f, kind, target, ref, acc)

          _ ->
            :file.close(f)
        end
    end
  end

  @doc """
  Turn one evdev event into Photon events. Motion is gathered until the
  `SYN_REPORT` that ends the frame. Returns `{events, acc}`.
  """
  def decode(@ev_key, code, value, _kind, acc) when value in [0, 1] do
    ev = if code >= @btn_left and code < @btn_left + 8, do: :button, else: :key
    {[{ev, code, value == 1}], acc}
  end

  # Auto-repeat (value 2) is the client's business.
  def decode(@ev_key, _code, _value, _kind, acc), do: {[], acc}
  def decode(@ev_rel, 0, v, _kind, acc), do: {[], Map.update(acc, :dx, v, &(&1 + v))}
  def decode(@ev_rel, 1, v, _kind, acc), do: {[], Map.update(acc, :dy, v, &(&1 + v))}
  def decode(@ev_rel, 8, v, _kind, acc), do: {[], Map.update(acc, :wheel, -v, &(&1 - v))}
  def decode(@ev_abs, 0, v, _kind, acc), do: {[], Map.put(acc, :ax, v / @abs_max)}
  def decode(@ev_abs, 1, v, _kind, acc), do: {[], Map.put(acc, :ay, v / @abs_max)}

  def decode(@ev_syn, 0, _v, _kind, acc) do
    motion = if Map.has_key?(acc, :dx) or Map.has_key?(acc, :dy), do: [{:motion, acc[:dx] || 0, acc[:dy] || 0}], else: []
    abs = if Map.has_key?(acc, :ax) or Map.has_key?(acc, :ay), do: [{:abs, acc[:ax], acc[:ay]}], else: []
    wheel = if acc[:wheel], do: [{:wheel, acc[:wheel]}], else: []
    {motion ++ abs ++ wheel, %{}}
  end

  def decode(_type, _code, _value, _kind, acc), do: {[], acc}
end
