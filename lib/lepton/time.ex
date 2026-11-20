defmodule Lepton.Time do
  @moduledoc """
  The time zone, and local time.

  The zone is `/var/lib/lepton/timezone` ("NAME auto" or "NAME manual"):
  automatic by default, looked up from the network address by `ntpd`
  (`Lepton.NTP`), or set by hand with `timedatectl set-timezone`. Until
  it is known, it is UTC. Lepton's own clocks (`date`, `ls -l`, logs,
  cron, the desktop's clock) use it, a `TZ` variable overrides it for one
  command, and `/etc/localtime` is kept in step for native programs
  (Firefox).
  """

  alias Lepton.TZ

  defp state, do: Lepton.Persist.state_path("timezone")

  @doc "`{zone, :auto | :manual}`."
  def setting do
    path = state()
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      nil ->
        value =
          case File.read(path) do
            {:ok, text} ->
              case String.split(text) do
                [zone, "manual"] -> {zone, :manual}
                [zone | _] -> {zone, :auto}
                _ -> {"UTC", :auto}
              end

            _ ->
              {"UTC", :auto}
          end

        :persistent_term.put(key, value)
        localtime(elem(value, 0))
        value

      value ->
        value
    end
  end

  def zone, do: elem(setting(), 0)
  def auto?, do: elem(setting(), 1) == :auto

  @doc "Set the zone (`mode`: `:auto` when looked up, `:manual` when chosen)."
  def set_zone(zone, mode) when mode in [:auto, :manual] do
    if TZ.exists?(zone) do
      File.mkdir_p!(Path.dirname(state()))
      File.write!(state(), "#{zone} #{mode}\n")
      :persistent_term.put({__MODULE__, state()}, {zone, mode})
      localtime(zone)
      :ok
    else
      {:error, "unknown time zone #{zone}"}
    end
  end

  # /etc/localtime for native programs, which read the zone from it.
  defp localtime(zone) do
    if Lepton.Sys.native?() do
      File.rm("/etc/localtime")
      if zone == "UTC", do: File.write("/etc/localtime", utc_tzif()), else: File.ln_s(Path.join(TZ.dir(), zone), "/etc/localtime")
      File.write("/etc/timezone", zone <> "\n")
    end
  end

  # A TZif file for UTC (the zone files may not include one).
  defp utc_tzif do
    header = fn -> <<"TZif", "2", 0::size(15 * 8), 0::32, 0::32, 0::32, 0::32, 1::32, 4::32>> end
    data = <<0::32, 0, 0>> <> "UTC" <> <<0>>
    header.() <> data <> header.() <> data <> "\nUTC0\n"
  end

  @doc "The zone a command sees: its `TZ` variable, else the system's."
  def zone(%{env: env}) do
    case Map.get(env || %{}, "TZ") do
      nil -> zone()
      "" -> "UTC"
      tz -> tz |> String.trim_leading(":") |> String.replace_prefix(TZ.dir() <> "/", "")
    end
  end

  def zone(_), do: zone()

  @doc "Unix time `unix` (default now) in `zone`, as a `DateTime` with its offset and abbreviation."
  def local(unix \\ System.os_time(:second), zone \\ zone()) do
    {off, dst, abbr} = TZ.period(zone, unix)
    std = if dst, do: guess_dst_shift(zone, unix, off), else: 0
    utc = DateTime.from_unix!(unix + off)

    %{utc | time_zone: zone, zone_abbr: abbr, utc_offset: off - std, std_offset: std}
  end

  # How much of the offset is daylight saving: the difference from the
  # zone's standard offset half a year away (usually one hour).
  defp guess_dst_shift(zone, unix, off) do
    {o2, dst2, _} = TZ.period(zone, unix + 182 * 86_400)
    if dst2, do: 3600, else: off - o2
  end

  @doc "Now (or `unix`), locally, as `{{y, m, d}, {h, min, s}}`."
  def erl(unix \\ System.os_time(:second), zone \\ zone()) do
    dt = local(unix, zone)
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second}}
  end

  @doc "The offset as `+0100`."
  def offset(%DateTime{utc_offset: u, std_offset: s}) do
    total = u + s
    sign = if total < 0, do: "-", else: "+"
    a = abs(total)
    sign <> String.pad_leading(to_string(div(a, 3600)), 2, "0") <> String.pad_leading(to_string(div(rem(a, 3600), 60)), 2, "0")
  end
end
