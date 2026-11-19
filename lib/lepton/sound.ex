defmodule Lepton.Sound do
  @moduledoc """
  Sound: the sound cards, one volume for the system, and playing sounds.

  **Cards** come from the kernel's drivers: Intel HD Audio (QEMU's and
  UTM's sound device), virtio-sound, and USB audio (headsets, speakers,
  docks), loaded by hardware ID (`Lepton.Kmod`). Sound plays on the
  *default card*: the one chosen with `use_card/1`, else the card added
  last (plug in a USB headset and sound goes there).

  **The volume** (0 to 100, and muted or not) is kept here and saved
  (`/var/lib/lepton/sound`). It works in software, on every card: each
  gets a `Lepton Playback Volume` control made by Lepton (`ELEM_ADD`),
  Lepton's own sounds are scaled by it, and so is Firefox's, through
  ALSA's `softvol` plugin (`alsa_config/0`). The card's own volume and
  mute (`Master Playback Volume` and `Switch`) are held at full and on:
  a virtual machine's sound card may only pass them on to its host
  rather than apply them (QEMU's SPICE audio, which UTM uses, does), so
  they can't be relied on to make anything quieter.

  **Playing** (`play_wav/2`, `tone/3`) converts to what the card plays
  (16-bit, its rate and channels) and writes to its PCM device
  (`Lepton.Sound.ALSA`) in the calling process; stopping that process
  stops the sound.
  """

  use GenServer
  require Logger

  alias Lepton.Sound.ALSA

  @tick 2_000
  @master "Master Playback Volume"
  @switch "Master Playback Switch"
  @soft "Lepton Playback Volume"
  # The software volume control: 0..255, from -51 dB to 0 dB (softvol's defaults).
  @soft_max 255
  @soft_min_db -51.0

  # -- the volume -------------------------------------------------------------------------------------

  @doc "`%{volume, muted, card, cards}` (also what the classic desktop shows)."
  def status, do: :persistent_term.get({__MODULE__, :status}, %{volume: 50, muted: false, card: nil, cards: []})

  @doc "Set the volume (0 to 100); unmutes."
  def set_volume(v) when is_number(v), do: call({:set, max(0, min(100, round(v))), false})

  @doc "Change the volume by `delta` points."
  def change(delta), do: call({:change, delta})

  @doc "Mute (`true`), unmute (`false`) or toggle (`:toggle`)."
  def mute(how), do: call({:mute, how})

  @doc "Read the saved settings again (once the data partition is mounted, at boot)."
  def reload, do: call(:reload)

  @doc "Play on card `index` (or `:bluetooth`, the Bluetooth headphones) from now on (`nil`: the one added last)."
  def use_card(index), do: call({:use, index})

  defp call(msg) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, msg, 10_000), else: {:error, "the sound service isn't running"}
  end

  @doc """
  Where sound goes now: `{:ok, %{type: :alsa, card, device, gain}}`
  (`gain` the software volume), or
  `{:ok, %{type: :bluetooth, pcm, rate, channels, gain}}` for headphones.
  """
  def output do
    case status() do
      %{card: nil} -> {:error, "no sound card (add a sound device to the VM, or plug in USB audio or Bluetooth headphones)"}
      %{card: %{type: :bluetooth} = c} -> {:ok, %{type: :bluetooth, pcm: c.pcm, rate: c.rate, channels: c.channels, gain: 1.0}}
      %{card: card} = st -> {:ok, %{type: :alsa, card: card.index, device: hd(card.playback), gain: gain(st, card)}}
    end
  end

  defp gain(%{muted: true}, _card), do: 0.0
  defp gain(%{volume: v}, _card), do: soft_gain(soft_value(v))

  @doc "The software control's value for a volume (0..100)."
  def soft_value(volume), do: round(volume * @soft_max / 100)

  @doc "The gain softvol applies at control value `v` (0..255): linear in dB, silent at 0."
  def soft_gain(0), do: 0.0
  def soft_gain(v), do: :math.pow(10, @soft_min_db * (1 - v / @soft_max) / 20)

  # -- playing -------------------------------------------------------------------------------------------

  @doc """
  Play a stream of S16_LE frames (`chunks`, an enumerable of binaries) at
  `rate` with `channels`, converted for the card. Returns when it has been
  heard.
  """
  def play(chunks, rate, channels) do
    case output() do
      {:ok, %{type: :bluetooth} = out} -> play_bluetooth(chunks, rate, channels, out)
      {:ok, out} -> play_alsa(chunks, rate, channels, out)
      error -> error
    end
  end

  defp play_alsa(chunks, rate, channels, out) do
    with {:ok, pcm} <- ALSA.open_pcm(out.card, out.device, rate, channels) do
      try do
        Enum.each(chunks, fn data ->
          # (the volume can change while it plays)
          gain = case output() do
            {:ok, now} -> now.gain
            _ -> out.gain
          end

          :ok = ALSA.write(pcm, convert(data, rate, channels, pcm, gain))
        end)

        ALSA.drain_and_close(pcm)
        :ok
      rescue
        e ->
          :file.close(pcm.file)
          {:error, Exception.message(e)}
      end
    end
  end

  # Headphones: bluealsa takes the samples (S16_LE at the PCM's rate and
  # channels) on bluealsa-cli's standard input; the volume is bluealsa's.
  defp play_bluetooth(chunks, rate, channels, out) do
    port =
      Port.open({:spawn_executable, Lepton.Bluetooth.program("usr/bin/bluealsa-cli")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["open", out.pcm],
        env: Enum.map(Lepton.Bluetooth.env(), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
      ])

    Enum.each(chunks, &Port.command(port, convert(&1, rate, channels, out, 1.0)))
    send(port, {self(), :close})

    receive do
      {^port, {:exit_status, s}} when s != 0 -> {:error, "bluealsa-cli failed (#{s})"}
      {^port, :closed} -> :ok
    after
      30_000 -> :ok
    end
  end

  @doc """
  Frames as the device wants them: its channel count (mono doubled, or
  channels mixed down), its rate (linear interpolation), the volume.
  """
  def convert(data, rate, channels, %{rate: rate, channels: channels}, gain) when gain == 1.0, do: data
  def convert(data, rate, channels, %{rate: rate, channels: channels}, gain), do: scale(data, gain)

  def convert(data, rate, channels, %{rate: out_rate, channels: out_channels}, gain) do
    frames = for <<frame::binary-size(^channels * 2) <- data>>, do: for(<<s::little-signed-16 <- frame>>, do: s)

    # Other channel counts: through mono (the average), copied to each channel.
    frames =
      if channels == out_channels,
        do: frames,
        else: Enum.map(frames, &List.duplicate(div(Enum.sum(&1), channels), out_channels))

    frames = if rate == out_rate, do: frames, else: resample(frames, rate, out_rate)
    data = for f <- frames, s <- f, into: <<>>, do: <<s::little-signed-16>>
    if gain == 1.0, do: data, else: scale(data, gain)
  end

  defp scale(data, gain), do: for(<<s::little-signed-16 <- data>>, into: <<>>, do: <<(round(s * gain) |> max(-32768) |> min(32767))::little-signed-16>>)

  defp resample([], _from, _to), do: []

  defp resample(frames, from, to) do
    src = List.to_tuple(frames)
    n = tuple_size(src)
    count = div(n * to, from)

    for i <- 0..(count - 1)//1 do
      pos = i * from / to
      j = trunc(pos)
      t = pos - j
      a = elem(src, min(j, n - 1))
      b = elem(src, min(j + 1, n - 1))
      Enum.zip_with(a, b, fn x, y -> round(x + (y - x) * t) end)
    end
  end

  @doc "A sine tone of `hz` for `ms` milliseconds (with 5 ms fades): mono S16 at 48 kHz."
  def tone(hz, ms, rate \\ 48_000) do
    n = div(rate * ms, 1000)
    fade = div(rate * 5, 1000)

    for i <- 0..(n - 1)//1, into: <<>> do
      env = min(1.0, min(i, n - 1 - i) / max(fade, 1))
      <<round(:math.sin(2 * :math.pi() * hz * i / rate) * 12_000 * env)::little-signed-16>>
    end
  end

  @doc "Play a tone."
  def beep(hz \\ 880, ms \\ 150), do: play([tone(hz, ms)], 48_000, 1)

  # -- WAV files ------------------------------------------------------------------------------------------

  @doc """
  A WAV file's format and where its samples are: `{:ok, %{rate, channels,
  bits, float, offset, size}}`. PCM (8, 16, 24 or 32 bits) and 32-bit
  float, including WAVE_FORMAT_EXTENSIBLE.
  """
  def wav_info(path) do
    with {:ok, f} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      try do
        case :file.pread(f, 0, 12) do
          {:ok, <<"RIFF", _::little-32, "WAVE">>} -> wav_chunks(f, 12, %{})
          _ -> {:error, "not a WAV file"}
        end
      after
        :file.close(f)
      end
    end
  end

  defp wav_chunks(f, off, fmt) do
    case :file.pread(f, off, 8) do
      {:ok, <<"fmt ", size::little-32>>} ->
        {:ok, <<tag::little-16, channels::little-16, rate::little-32, _::little-32, _::little-16, bits::little-16, rest::binary>>} = :file.pread(f, off + 8, size)
        # WAVE_FORMAT_EXTENSIBLE: the real format is the subformat GUID's first two bytes.
        tag = if tag == 0xFFFE and byte_size(rest) >= 10, do: :binary.decode_unsigned(binary_part(rest, 8, 2), :little), else: tag
        wav_chunks(f, off + 8 + size + rem(size, 2), %{tag: tag, channels: channels, rate: rate, bits: bits})

      {:ok, <<"data", size::little-32>>} ->
        cond do
          fmt == %{} -> {:error, "no format chunk"}
          fmt.tag == 1 and fmt.bits in [8, 16, 24, 32] -> {:ok, Map.merge(Map.delete(fmt, :tag), %{float: false, offset: off + 8, size: size})}
          fmt.tag == 3 and fmt.bits == 32 -> {:ok, Map.merge(Map.delete(fmt, :tag), %{float: true, offset: off + 8, size: size})}
          true -> {:error, "unsupported WAV encoding (format #{fmt.tag}, #{fmt.bits} bits)"}
        end

      {:ok, <<_id::binary-4, size::little-32>>} ->
        wav_chunks(f, off + 8 + size + rem(size, 2), fmt)

      _ ->
        {:error, "no data chunk"}
    end
  end

  @doc "Play a WAV file (blocks until it has been heard)."
  def play_wav(path) do
    with {:ok, w} <- wav_info(path) do
      frame = div(w.bits, 8) * w.channels
      # About a fifth of a second at a time.
      chunk = max(div(w.rate, 5), 1) * frame
      {:ok, f} = :file.open(String.to_charlist(path), [:raw, :binary, :read])

      chunks =
        Stream.unfold(0, fn
          done when done >= w.size -> nil
          done ->
            case :file.pread(f, w.offset + done, min(chunk, w.size - done)) do
              {:ok, data} -> {to_s16(data, w), done + byte_size(data)}
              _ -> nil
            end
        end)

      try do
        play(chunks, w.rate, w.channels)
      after
        :file.close(f)
      end
    end
  end

  @doc "Samples of a WAV's encoding as S16_LE."
  def to_s16(data, %{bits: 16, float: false}), do: data
  def to_s16(data, %{bits: 8}), do: for(<<s <- data>>, into: <<>>, do: <<(s - 128) * 256::little-signed-16>>)
  def to_s16(data, %{bits: 24}), do: for(<<_, s::little-signed-16 <- data>>, into: <<>>, do: <<s::little-signed-16>>)
  def to_s16(data, %{bits: 32, float: false}), do: for(<<_::16, s::little-signed-16 <- data>>, into: <<>>, do: <<s::little-signed-16>>)

  def to_s16(data, %{bits: 32, float: true}),
    do: for(<<x::little-float-32 <- data>>, into: <<>>, do: <<round(max(-1.0, min(1.0, x)) * 32767)::little-signed-16>>)

  # -- the service ----------------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    st = Map.merge(%{volume: 50, muted: false, chosen: nil, cards: []}, load())
    if Lepton.Sys.native?(), do: send(self(), :tick)
    {:ok, publish(st)}
  end

  @impl true
  def handle_call({:set, v, muted}, _from, st), do: reply(%{st | volume: v, muted: muted})
  def handle_call({:change, d}, _from, st), do: reply(%{st | volume: max(0, min(100, st.volume + d)), muted: false})
  def handle_call({:mute, :toggle}, _from, st), do: reply(%{st | muted: not st.muted})
  def handle_call({:mute, m}, _from, st), do: reply(%{st | muted: m})

  def handle_call(:reload, _from, st), do: reply(Map.merge(st, load()), save: false)

  def handle_call({:use, :bluetooth}, _from, st) do
    case Enum.find(st.cards, &(&1[:type] == :bluetooth)) do
      nil -> {:reply, {:error, "no Bluetooth headphones are connected"}, st}
      card -> reply(%{st | chosen: card.id})
    end
  end

  def handle_call({:use, index}, _from, st) do
    case index && Enum.find(st.cards, &(&1.index == index)) do
      nil when index != nil -> {:reply, {:error, "no card #{index}"}, st}
      card -> reply(%{st | chosen: card && card.id})
    end
  end

  defp reply(st, opts \\ []) do
    st = apply_volume(st)
    if Keyword.get(opts, :save, true), do: save(st)
    st = publish(st)
    {:reply, {:ok, status()}, st}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)
    # Sound cards, then Bluetooth headphones (connected last, so they're preferred).
    found = (ALSA.cards() |> Enum.filter(&(&1.playback != []))) ++ bluetooth_outputs()

    if Enum.map(found, &{&1.index, &1.id}) == Enum.map(st.cards, &{&1.index, &1.id}) do
      {:noreply, enforce(st)}
    else
      bind_hda_codecs()
      # Programs running as the user (Firefox) open the devices too.
      for dev <- Path.wildcard("/dev/snd/*"), do: File.chmod(dev, 0o666)
      known = Map.new(st.cards, &{&1.id, &1})
      cards = for c <- found, do: Map.get(known, c.id) || setup(c)
      for c <- cards, not Map.has_key?(known, c.id), do: Logger.info("sound: #{c.name}#{if c.software, do: ", software volume"}")
      {:noreply, %{st | cards: cards} |> apply_volume() |> publish()}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp bluetooth_outputs do
    for o <- Lepton.Bluetooth.summary().outputs,
        do: %{type: :bluetooth, index: nil, id: "bt:" <> o.address, name: o.name, pcm: o.pcm, rate: o.rate, channels: o.channels, playback: [], master: nil, hardware: [], software: false}
  end

  # A card's volume control, one we add (software volume), and its own
  # volume and mute, `hardware`: `{control, value}`s held at full and on.
  defp setup(%{type: :bluetooth} = card), do: card

  defp setup(card) do
    controls = ALSA.controls(card.index)

    hw_master =
      Enum.find(controls, &(&1.name == @master and &1.type == :integer)) ||
        Enum.find(controls, &(&1.name in ["PCM Playback Volume", "Speaker Playback Volume", "Headphone Playback Volume"] and &1.type == :integer))

    hw_switch = Enum.find(controls, &(&1.name == @switch and &1.type == :boolean))

    # (made already if the service started again, or by softvol)
    soft =
      Enum.find(controls, &(&1.name == @soft)) ||
        (ALSA.add_control(card.index, @soft, @soft_max, @soft_min_db) && Enum.find(ALSA.controls(card.index), &(&1.name == @soft)))

    hardware = for {c, v} <- [{hw_master, hw_master && hw_master.max}, {hw_switch, 1}], c != nil, do: {c, v}
    Map.merge(card, %{master: soft, hardware: hardware, software: soft != nil})
  end

  # HD Audio codecs bind to a codec driver; load the generic one if none did.
  defp bind_hda_codecs do
    for dev <- Path.wildcard("/sys/bus/hdaudio/devices/*"), not File.exists?(Path.join(dev, "driver")) do
      Lepton.Kmod.modprobe("snd-hda-codec-generic")
      File.write("/sys/bus/hdaudio/drivers_probe", Path.basename(dev))
    end
  end

  defp apply_volume(st) do
    for %{type: :bluetooth, pcm: pcm} <- st.cards, do: Lepton.Bluetooth.set_volume(pcm, st.volume, st.muted)

    for %{master: m} = card <- st.cards, m != nil do
      ALSA.write_control(card.index, m, level(st, card))
    end

    for %{hardware: hw} = card <- st.cards, {c, v} <- hw, do: ALSA.write_control(card.index, c, v)
    st
  end

  # A program can set the controls too, or (alsa-lib's softvol) make the
  # software control again at full volume: put the volume back.
  defp enforce(st) do
    drifted =
      Enum.any?(st.cards, fn
        %{master: m} = card when m != nil -> Enum.any?([{m, level(st, card)} | card.hardware], fn {c, v} -> differs?(card.index, c, v) end)
        _ -> false
      end)

    if drifted, do: apply_volume(st), else: st
  end

  defp differs?(index, control, value) do
    case ALSA.read(index, control) do
      {:ok, values} -> Enum.any?(values, &(&1 != value))
      _ -> false
    end
  end

  # (muted: the software control at 0, which is silent)
  defp level(st, %{master: m}) do
    if st.muted, do: m.min, else: m.min + round((m.max - m.min) * st.volume / 100)
  end

  defp current(st) do
    Enum.find(st.cards, &(&1.id == st.chosen)) || List.last(st.cards)
  end

  defp publish(st) do
    :persistent_term.put({__MODULE__, :status}, %{volume: st.volume, muted: st.muted, card: current(st), cards: st.cards, chosen: st.chosen})
    st
  end

  # -- saved settings -------------------------------------------------------------------------------------

  defp path, do: Lepton.Persist.state_path("sound")

  defp load do
    case File.read(path()) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), [k, v] <- [String.split(line, "=", parts: 2)], into: %{} do
          case k do
            "volume" -> {:volume, String.to_integer(v)}
            "muted" -> {:muted, v == "true"}
            "card" -> {:chosen, if(v == "", do: nil, else: v)}
            _ -> {:ignored, v}
          end
        end
        |> Map.delete(:ignored)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp save(st) do
    File.mkdir_p(Path.dirname(path()))
    File.write(path(), "volume=#{st.volume}\nmuted=#{st.muted}\ncard=#{st.chosen}\n")
  end

  # -- Firefox ---------------------------------------------------------------------------------------------

  @doc """
  ALSA configuration for programs that use alsa-lib (Firefox): the default
  device is the default card, through `softvol` when its volume is
  Lepton's software control, so their sound follows the volume too.
  """
  def alsa_config do
    case status() do
      %{card: %{type: :bluetooth, id: "bt:" <> address}} ->
        # bluez-alsa's plugin, from the Bluetooth app.
        plugins = Lepton.Bluetooth.program("usr/lib/alsa-lib")

        """
        pcm_type.bluealsa { lib "#{plugins}/libasound_module_pcm_bluealsa.so" }
        ctl_type.bluealsa { lib "#{plugins}/libasound_module_ctl_bluealsa.so" }
        pcm.!default { type plug; slave.pcm { type bluealsa; device "#{address}"; profile "a2dp" } }
        ctl.!default { type bluealsa }
        """

      %{card: %{index: n, software: true}} ->
        """
        pcm.!default { type plug; slave.pcm "lepton_volume" }
        pcm.lepton_volume { type softvol; slave.pcm "hw:#{n}"; control { name "#{@soft}"; card #{n} }; min_dB #{@soft_min_db}; max_dB 0.0; resolution #{@soft_max + 1} }
        ctl.!default { type hw; card #{n} }
        """

      %{card: %{index: n}} ->
        """
        pcm.!default { type plug; slave.pcm "hw:#{n}" }
        ctl.!default { type hw; card #{n} }
        """

      _ ->
        ""
    end
  end
end
