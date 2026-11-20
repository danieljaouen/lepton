defmodule Lepton.TZ do
  @moduledoc """
  Time zones, from the compiled zone files in `/usr/share/zoneinfo`
  (TZif, RFC 8536: the IANA database as every Unix ships it).

  A file lists the zone's transitions (UTC offset, daylight saving,
  abbreviation from each instant on), and ends with a POSIX TZ rule
  (such as `CET-1CEST,M3.5.0,M10.5.0/3`) for the times after its last
  transition, which is how today's dates are covered.
  """

  @dir "/usr/share/zoneinfo"

  def dir, do: @dir

  @doc "Does zone `name` exist (`Europe/Paris`, `UTC`)?"
  def exists?(name), do: valid_name?(name) and match?({:ok, _}, load(name))

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+)*$/, name)

  @doc "Every zone, by name (Area/City, and UTC)."
  def zones do
    tab = Enum.find([Path.join(@dir, "zone1970.tab"), Path.join(@dir, "zone.tab")], &File.exists?/1)

    from_tab =
      case tab && File.read(tab) do
        {:ok, text} -> for line <- String.split(text, "\n"), not String.starts_with?(line, "#"), [_, _, z | _] <- [String.split(line, "\t")], do: z
        _ -> []
      end

    Enum.sort(Enum.uniq(["UTC" | from_tab]))
  end

  @doc """
  The local time in zone `name` at `utc` (Unix seconds):
  `{offset_seconds, dst?, abbreviation}`. Unknown zones are UTC.
  """
  def period(name, utc) do
    case load(name) do
      {:ok, z} -> lookup(z, utc)
      _ -> {0, false, "UTC"}
    end
  end

  # -- loading (cached) ----------------------------------------------------------------------

  def load("UTC"), do: {:ok, %{transitions: {}, types: {{0, false, "UTC"}}, rule: {:fixed, 0, "UTC"}}}

  def load(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        result =
          with true <- valid_name?(name) || {:error, :badname},
               {:ok, bin} <- File.read(Path.join(@dir, name)),
               {:ok, z} <- parse(bin) do
            {:ok, z}
          else
            {:error, _} = e -> e
            _ -> {:error, :invalid}
          end

        if match?({:ok, _}, result), do: :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  @doc "Parse a TZif file."
  def parse(<<"TZif", version, _::binary-15, _::binary>> = bin) do
    with {:ok, v1, rest} <- block(binary_part(bin, 20, byte_size(bin) - 20), 4) do
      if version >= ?2 do
        # The 64-bit data follows the 32-bit block, with its own header.
        <<"TZif", _, _::binary-15, rest2::binary>> = rest
        with {:ok, v2, footer} <- block(rest2, 8), do: {:ok, %{v2 | rule: rule_from_footer(footer)}}
      else
        {:ok, %{v1 | rule: nil}}
      end
    end
  end

  def parse(_), do: {:error, :not_tzif}

  defp block(<<isutcnt::32, isstdcnt::32, leapcnt::32, timecnt::32, typecnt::32, charcnt::32, rest::binary>>, size) do
    times_len = timecnt * size
    <<times::binary-size(^times_len), idx::binary-size(^timecnt), types::binary-size(^typecnt * 6), chars::binary-size(^charcnt), rest::binary>> = rest
    skip = leapcnt * (size + 4) + isstdcnt + isutcnt
    <<_::binary-size(^skip), rest::binary>> = rest

    bits = size * 8
    times = for <<t::signed-size(^bits) <- times>>, do: t
    idx = for <<i <- idx>>, do: i

    types =
      for <<off::signed-32, dst, ai <- types>> do
        abbr = chars |> binary_part(ai, charcnt - ai) |> String.split(<<0>>) |> hd()
        {off, dst == 1, abbr}
      end

    {:ok, %{transitions: List.to_tuple(Enum.zip(times, idx)), types: List.to_tuple(types), rule: nil}, rest}
  end

  defp block(_, _), do: {:error, :truncated}

  defp rule_from_footer(<<"\n", rest::binary>>) do
    case String.split(rest, "\n", parts: 2) do
      [tz, _] when tz != "" -> parse_rule(tz)
      _ -> nil
    end
  end

  defp rule_from_footer(_), do: nil

  # -- lookup ---------------------------------------------------------------------------------

  defp lookup(%{transitions: tr, types: types, rule: rule}, utc) do
    n = tuple_size(tr)

    cond do
      n == 0 and rule != nil -> rule_period(rule, utc)
      n == 0 -> elem(types, 0)
      utc < elem(elem(tr, 0), 0) -> first_standard(types)
      utc >= elem(elem(tr, n - 1), 0) and rule != nil -> rule_period(rule, utc)
      true -> elem(types, elem(elem(tr, search(tr, utc, 0, n - 1)), 1))
    end
  end

  # The last transition at or before `utc`.
  defp search(_tr, _utc, lo, hi) when lo == hi, do: lo

  defp search(tr, utc, lo, hi) do
    mid = div(lo + hi + 1, 2)
    if elem(elem(tr, mid), 0) <= utc, do: search(tr, utc, mid, hi), else: search(tr, utc, lo, mid - 1)
  end

  defp first_standard(types) do
    types |> Tuple.to_list() |> Enum.find(fn {_, dst, _} -> not dst end) || elem(types, 0)
  end

  # -- POSIX TZ rules --------------------------------------------------------------------------
  #
  #   std offset [dst [offset] [,start[/time],end[/time]]]
  #
  # Offsets are west-positive (EST5 is UTC-5); names may be <+0530>. The
  # dates are Mm.w.d (month, week 1-5 where 5 is the last, weekday 0=Sun),
  # Jn (day 1-365, no Feb 29) or n (day 0-365); times default to 02:00 and
  # may be negative or past 24.

  @doc false
  def parse_rule(tz) do
    with {std, rest} <- name(tz),
         {std_off, rest} <- offset(rest) do
      case rest do
        "" ->
          {:fixed, -std_off, std}

        _ ->
          with {dst, rest} <- name(rest) do
            {dst_off, rest} =
              case offset(rest) do
                {o, r} -> {o, r}
                :error -> {std_off - 3600, rest}
              end

            case String.split(rest, ",") do
              ["", start, stop] -> {:dst, -std_off, std, -dst_off, dst, date_rule(start), date_rule(stop)}
              _ -> {:fixed, -std_off, std}
            end
          else
            _ -> {:fixed, -std_off, std}
          end
      end
    else
      _ -> nil
    end
  end

  defp name("<" <> rest) do
    case String.split(rest, ">", parts: 2) do
      [n, r] -> {n, r}
      _ -> :error
    end
  end

  defp name(s) do
    case Regex.run(~r/^([A-Za-z]{3,})(.*)$/s, s) do
      [_, n, r] -> {n, r}
      _ -> :error
    end
  end

  defp offset(s) do
    case Regex.run(~r/^([+-]?)(\d{1,3})(?::(\d{1,2}))?(?::(\d{1,2}))?(.*)$/s, s) do
      [_, sign, h | more] ->
        [m, sec, rest] = pad3(more)
        v = String.to_integer(h) * 3600 + int(m) * 60 + int(sec)
        {if(sign == "-", do: -v, else: v), rest}

      _ ->
        :error
    end
  end

  defp pad3([m, s, r]), do: [m, s, r]
  defp pad3([m, r]), do: [m, "", r]
  defp pad3([r]), do: ["", "", r]

  defp int(""), do: 0
  defp int(s), do: String.to_integer(s)

  defp date_rule(spec) do
    {date, time} =
      case String.split(spec, "/", parts: 2) do
        [d, t] -> {d, (case offset(t) do {v, _} -> v; :error -> 7200 end)}
        [d] -> {d, 7200}
      end

    rule =
      case date do
        "M" <> mwd -> (with [m, w, d] <- String.split(mwd, "."), do: {:m, int(m), int(w), int(d)})
        "J" <> n -> {:j, int(n)}
        n -> {:n, int(n)}
      end

    {rule, time}
  end

  @doc false
  def rule_period({:fixed, off, abbr}, _utc), do: {off, false, abbr}

  def rule_period({:dst, std_off, std, dst_off, dst, start, stop}, utc) do
    {{y, _, _}, _} = :calendar.gregorian_seconds_to_datetime(utc + std_off + 62_167_219_200)

    # Transition instants in UTC: the start is in standard time, the end in daylight time.
    in_dst? = fn year ->
      s = transition(year, start) - std_off
      e = transition(year, stop) - dst_off

      if s < e, do: utc >= s and utc < e, else: utc >= s or utc < e
    end

    if in_dst?.(y), do: {dst_off, true, dst}, else: {std_off, false, std}
  end

  # Seconds since the epoch of the rule's local wall time in `year`.
  defp transition(year, {rule, time}) do
    day =
      case rule do
        {:m, m, w, d} ->
          first = Date.new!(year, m, 1)
          dow = rem(Date.day_of_week(first), 7)
          first_match = 1 + rem(d - dow + 7, 7)
          days = Date.days_in_month(first)
          day = first_match + (w - 1) * 7
          day = if day > days, do: day - 7, else: day
          Date.new!(year, m, day)

        {:j, n} ->
          # 1-365, never counting February 29.
          base = Date.add(Date.new!(year, 1, 1), n - 1)
          if Date.leap_year?(base) and n >= 60, do: Date.add(base, 1), else: base

        {:n, n} ->
          Date.add(Date.new!(year, 1, 1), n)
      end

    {:ok, dt} = NaiveDateTime.new(day, ~T[00:00:00])
    NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00]) + time
  end
end
