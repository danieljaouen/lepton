defmodule Lepton.Sound.ALSA do
  @moduledoc """
  The kernel's sound API (ALSA), spoken directly: there is no alsa-lib.

  A sound card is a set of device files in `/dev/snd`: `controlCn` for
  its mixer controls, `pcmCnDdp` for playing sound. Both are driven with
  `ioctl` (`Lepton.FD.ioctl/3`), whose structures are built here
  byte by byte, as the aarch64 kernel lays them out:

    * **PCM**: `HW_PARAMS` (608 bytes of masks and intervals: access,
      format, channels, rate, period and buffer) picks how the device
      plays; `PREPARE`, then the samples are written with `write(2)`,
      then `DRAIN` waits for them to be heard.
    * **Controls**: `ELEM_LIST` counts them, `ELEM_INFO` (272 bytes) says
      what each is (`"Master Playback Volume"`, an integer from 0 to 87,
      2 channels), `ELEM_READ`/`ELEM_WRITE` (1224 bytes) get and set
      their values, and `ELEM_ADD` creates a control of our own.
  """

  import Bitwise

  # PCM ioctls ('A')
  @hw_params 0xC2604111
  @prepare 0x4140
  @drain 0x4144
  # control ioctls ('U')
  @card_info 0x81785501
  @elem_list 0xC0505510
  @elem_info 0xC1105511
  @elem_read 0xC4C85512
  @elem_write 0xC4C85513
  @elem_add 0xC1105517
  @tlv_write 0xC008551B

  @iface_mixer 2
  @type_boolean 1
  @type_integer 2
  @access_rw 3
  @access_tlv_rw 0x30
  @access_user 1 <<< 29

  # snd_pcm_hw_params: interval indices (after the 3 masks)
  @access_rw_interleaved 3
  @format_s16_le 2
  @i_channels 2
  @i_rate 3
  @i_period_time 4
  @i_period_size 5
  @i_buffer_time 8
  @i_buffer_size 9

  # -- cards ------------------------------------------------------------------------------------------

  @doc """
  The sound cards: `[%{index, id, name, playback}]` (from `/proc/asound`),
  `playback` the PCM devices that play (from `dev`).
  """
  def cards(proc \\ "/proc/asound", dev \\ "/dev/snd") do
    case File.read(Path.join(proc, "cards")) do
      {:ok, text} ->
        for [_, n, id, name] <- Regex.scan(~r/^\s*(\d+) \[(\S+)\s*\]: .*? - (.*)$/m, text) do
          index = String.to_integer(n)

          playback =
            for f <- Path.wildcard(Path.join(dev, "pcmC#{index}D*p")),
                [_, d] <- [Regex.run(~r/D(\d+)p$/, f)],
                do: String.to_integer(d)

          %{index: index, id: id, name: String.trim(name), playback: Enum.sort(playback)}
        end

      _ ->
        []
    end
  end

  # -- playing ------------------------------------------------------------------------------------------

  @doc """
  Open card `card`'s PCM device `device` for playing S16 samples at about
  `rate` with `channels`. The device may want another rate or channel
  count: what it agreed to is returned, `{:ok, pcm}` with
  `pcm = %{file, rate, channels, period, buffer}` (in frames).
  """
  def open_pcm(card, device, rate, channels) do
    path = "/dev/snd/pcmC#{card}D#{device}p"

    with {:ok, f} <- :file.open(String.to_charlist(path), [:raw, :binary, :write]) do
      # The rate and channels asked for, else what the device has nearby.
      tries = for r <- Enum.uniq([rate, 48000, 44100]), c <- Enum.uniq([channels, 2, 1]), do: {r, c}

      case Enum.find_value(tries, &hw_params(f, &1)) do
        nil ->
          :file.close(f)
          {:error, "#{path}: plays none of the usual formats"}

        pcm ->
          case Lepton.FD.ioctl(f, @prepare, <<>>) do
            {:ok, _, _} -> {:ok, Map.put(pcm, :file, f)}
            {:error, e} -> :file.close(f) && {:error, "#{path}: #{e}"}
          end
      end
    else
      {:error, :ebusy} -> {:error, "#{path} is in use (another program is playing)"}
      {:error, reason} -> {:error, "#{path}: #{reason}"}
    end
  end

  defp hw_params(f, {rate, channels}) do
    case Lepton.FD.ioctl(f, @hw_params, hw_params_struct(rate, channels)) do
      {:ok, _, out} ->
        %{
          rate: interval(out, @i_rate) |> elem(0),
          channels: interval(out, @i_channels) |> elem(0),
          period: interval(out, @i_period_size) |> elem(0),
          buffer: interval(out, @i_buffer_size) |> elem(0)
        }

      {:error, _} ->
        nil
    end
  end

  @doc """
  The `snd_pcm_hw_params` structure asking for interleaved S16_LE at
  `rate` with `channels`, 20 to 50 ms periods and 80 to 250 ms of buffer;
  everything else is left for the kernel to choose.
  """
  def hw_params_struct(rate, channels) do
    mask = fn bit -> <<1 <<< bit::little-32, 0::size(7 * 32)>> end
    any = {0, 0xFFFFFFFF, false}

    intervals =
      for i <- 0..11 do
        {min, max, integer?} =
          case i do
            @i_channels -> {channels, channels, true}
            @i_rate -> {rate, rate, true}
            @i_period_time -> {20_000, 50_000, false}
            @i_buffer_time -> {80_000, 250_000, false}
            _ -> any
          end

        <<min::little-32, max::little-32, if(integer?, do: 4, else: 0)::little-32>>
      end

    IO.iodata_to_binary([
      # flags; masks: access, format, subformat (standard)
      <<0::little-32>>,
      mask.(@access_rw_interleaved),
      mask.(@format_s16_le),
      mask.(0),
      <<0::size(5 * 32 * 8)>>,
      intervals,
      <<0::size(9 * 12 * 8)>>,
      # rmask (refine everything), cmask, info, msbits, rate_num, rate_den
      <<0xFFFFFFFF::little-32, 0::size(5 * 32)>>,
      # fifo_size, reserved
      <<0::64, 0::size(64 * 8)>>
    ])
  end

  @doc "Interval `i` of a hw_params structure: `{min, max}`."
  def interval(params, i) do
    <<min::little-32, max::little-32, _::little-32>> = binary_part(params, 4 + 3 * 32 + 5 * 32 + i * 12, 12)
    {min, max}
  end

  @doc "Write S16_LE frames (blocking while the device's buffer is full). An underrun is recovered from."
  def write(%{file: f}, data) do
    case :file.write(f, data) do
      :ok ->
        :ok

      {:error, :epipe} ->
        # It ran dry: start again.
        Lepton.FD.ioctl(f, @prepare, <<>>)
        :file.write(f, data)

      other ->
        other
    end
  end

  @doc "Wait until everything written has been played, and close."
  def drain_and_close(%{file: f}) do
    Lepton.FD.ioctl(f, @drain, <<>>)
    :file.close(f)
  end

  # -- controls -----------------------------------------------------------------------------------------

  @doc "The card's name and mixer name: `%{id, name, mixer}`."
  def card_info(card) do
    with_control(card, fn f ->
      case Lepton.FD.ioctl(f, @card_info, <<0::size(376 * 8)>>) do
        {:ok, _, <<_::64, id::binary-16, _driver::binary-16, name::binary-32, _::binary-96, mixer::binary-80, _::binary>>} ->
          {:ok, %{id: cstr(id), name: cstr(name), mixer: cstr(mixer)}}

        {:error, e} ->
          {:error, e}
      end
    end)
  end

  @doc """
  The card's controls: `[%{numid, name, type, count, min, max, user}]`
  (`type` `:integer`, `:boolean` or `:other`).
  """
  def controls(card) do
    with_control(card, fn f ->
      with {:ok, _, <<_::32, _::32, _used::little-32, count::little-32, _::binary>>} <- Lepton.FD.ioctl(f, @elem_list, <<0::size(80 * 8)>>) do
        # numids usually run 1..count; look a little further for gaps.
        found =
          Enum.reduce_while(1..(count * 2 + 8), [], fn numid, acc ->
            acc = case info(f, %{numid: numid}) do
              {:ok, c} -> [c | acc]
              _ -> acc
            end

            if length(acc) >= count, do: {:halt, acc}, else: {:cont, acc}
          end)

        {:ok, Enum.reverse(found)}
      end
    end)
    |> case do
      {:ok, list} -> list
      _ -> []
    end
  end

  defp info(f, id) do
    case Lepton.FD.ioctl(f, @elem_info, elem_id(id) <> <<0::size((272 - 64) * 8)>>) do
      {:ok, _, <<numid::little-32, _iface::little-32, _::binary-8, name::binary-44, _index::little-32, type::little-32, access::little-32, count::little-32, _owner::32, min::little-signed-64, max::little-signed-64, _::binary>>} ->
        {:ok,
         %{
           numid: numid,
           name: cstr(name),
           type: case type do
             @type_integer -> :integer
             @type_boolean -> :boolean
             _ -> :other
           end,
           count: count,
           min: if(type == @type_integer, do: min, else: 0),
           max: if(type == @type_integer, do: max, else: 1),
           user: (access &&& @access_user) != 0
         }}

      {:error, e} ->
        {:error, e}
    end
  end

  # snd_ctl_elem_id {numid, iface, device, subdevice, name[44], index}:
  # a mixer control by name (it may have been made again since, with
  # another numid), or by numid.
  defp elem_id(%{name: name}), do: <<0::little-32, @iface_mixer::little-32, 0::64>> <> pad(name, 44) <> <<0::32>>
  defp elem_id(%{numid: n}), do: <<n::little-32, 0::size(60 * 8)>>

  @doc "A control's values (one per channel)."
  def read(card, %{count: count} = control) do
    with_control(card, fn f ->
      case Lepton.FD.ioctl(f, @elem_read, elem_id(control) <> <<0::size((1224 - 64) * 8)>>) do
        {:ok, _, <<_::binary-72, values::binary-1024, _::binary>>} ->
          {:ok, for(<<v::little-signed-64 <- binary_part(values, 0, count * 8)>>, do: v)}

        {:error, e} ->
          {:error, e}
      end
    end)
  end

  @doc "Set every channel of a control to `value`."
  def write_control(card, %{count: count} = control, value) do
    values = :binary.copy(<<value::little-signed-64>>, count)
    data = elem_id(control) <> <<0::32, 0::32>> <> values <> <<0::size((1024 - count * 8 + 128) * 8)>>

    with_control(card, fn f ->
      case Lepton.FD.ioctl(f, @elem_write, data) do
        {:ok, _, _} -> :ok
        {:error, e} -> {:error, e}
      end
    end)
  end

  @doc """
  Add a mixer control of our own: an integer from 0 to `max` for
  `channels` channels, with a dB scale from `min_db` to 0 dB (silent at
  0), made as alsa-lib's `softvol` makes its control, so that `softvol`
  uses it rather than making its own. (User controls stay until the card
  goes away.)
  """
  def add_control(card, name, max, min_db, channels \\ 2) do
    data =
      elem_id(%{name: name}) <>
        <<@type_integer::little-32, @access_rw ||| @access_tlv_rw::little-32, channels::little-32, 0::32, 0::little-64, max::little-64, 0::little-64>> <>
        <<0::size((128 - 24 + 64) * 8)>>

    with_control(card, fn f ->
      with {:ok, _, <<numid::little-32, _::binary>>} <- Lepton.FD.ioctl(f, @elem_add, data) do
        # snd_ctl_tlv {numid, length, TLV_DB_SCALE: type 1, length 8, min (0.01 dB), step | mute at minimum}
        min = round(min_db * 100)
        step = div(-min, max) ||| 0x10000
        tlv = <<numid::little-32, 16::little-32, 1::little-32, 8::little-32, min::little-signed-32, step::little-32>>
        Lepton.FD.ioctl(f, @tlv_write, tlv)
        :ok
      else
        {:error, e} -> {:error, e}
      end
    end)
  end

  defp with_control(card, fun) do
    case :file.open(String.to_charlist("/dev/snd/controlC#{card}"), [:raw, :binary, :read, :write]) do
      {:ok, f} ->
        try do
          fun.(f)
        after
          :file.close(f)
        end

      {:error, e} ->
        {:error, e}
    end
  end

  defp pad(s, n), do: binary_part(s <> :binary.copy(<<0>>, n), 0, n)
  defp cstr(bin), do: bin |> String.split(<<0>>) |> hd() |> String.trim()
end
