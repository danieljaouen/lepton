defmodule Lepton.NTP do
  @moduledoc """
  `ntpd`: Lepton's time keeping, run by the `ntpd` service (on by
  default).

  It asks NTP servers for the time (SNTP, RFC 4330: one UDP packet each
  way), takes the answer with the shortest round trip, and sets the
  system clock when it is off by more than 128 ms, as ntpd steps. It asks
  again every 64 seconds until it has the time, then less often (up to
  every 17 minutes) while the clock stays right. The servers are the
  `server` lines of `/etc/ntp.conf`.

  It also finds the time zone, when it is automatic: from the network's
  public address (a GeoIP lookup), when the network is up, then every
  six hours (the machine may have moved). Without the network the zone
  stays as it was: UTC until it has been found once.

  The system clock is set with busybox's `date -s @SECONDS`, which takes
  whole seconds: it runs as the corrected second begins, so the clock is
  right to within a few milliseconds.
  """


  @epoch_offset 2_208_988_800
  @step 0.128
  @min_poll 64
  @max_poll 1024
  @retry 15
  @geo_every 6 * 3600

  @default_servers ["pool.ntp.org", "time.cloudflare.com"]

  # -- configuration ----------------------------------------------------------------------------

  @doc "The servers: `server`/`pool` lines of /etc/ntp.conf, or the defaults."
  def servers(path \\ "/etc/ntp.conf") do
    case File.read(path) do
      {:ok, text} ->
        list = for line <- String.split(text, "\n"), [kind, host | _] <- [String.split(line)], kind in ["server", "pool"], do: host
        if list == [], do: @default_servers, else: list

      _ ->
        @default_servers
    end
  end

  # -- SNTP ---------------------------------------------------------------------------------------

  @doc """
  Ask one server (`{ip, port}` or a host name): `{:ok, %{offset, delay,
  server, stratum}}` (seconds; offset = how far the local clock is
  behind) or `{:error, reason}`.
  """
  def query(server, timeout \\ 2000)

  def query({ip, port}, timeout) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

    try do
      t1 = now()
      {s1, f1} = to_ntp(t1)
      packet = <<0::2, 4::3, 3::3, 0, 6, -20::signed, 0::32, 0::32, 0::32, 0::64, 0::64, 0::64, s1::32, f1::32>>
      :ok = :gen_udp.send(sock, ip, port, packet)

      case :gen_udp.recv(sock, 48, timeout) do
        {:ok, {_, _, <<li::2, _vn::3, mode::3, stratum, _poll, _prec, _rd::32, _rdisp::32, _ref::32, _rt::64, os::32, of::32, rs::32, rf::32, ts::32, tf::32, _::binary>>}} ->
          t4 = now()

          cond do
            mode != 4 -> {:error, :not_a_server_reply}
            li == 3 or stratum == 0 or stratum > 15 -> {:error, :unsynchronised}
            {os, of} != {s1, f1} -> {:error, :reply_to_something_else}
            true ->
              t2 = from_ntp(rs, rf)
              t3 = from_ntp(ts, tf)
              {:ok, %{offset: (t2 - t1 + (t3 - t4)) / 2, delay: t4 - t1 - (t3 - t2), server: ip, stratum: stratum}}
          end

        {:ok, _} -> {:error, :short_reply}
        {:error, reason} -> {:error, reason}
      end
    after
      :gen_udp.close(sock)
    end
  end

  def query(host, timeout) when is_binary(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> query({ip, 123}, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Ask the servers (up to four addresses each); the best answer, by round trip."
  def sample(servers \\ servers()) do
    answers =
      for host <- servers,
          {:ok, ips} <- [:inet.getaddrs(String.to_charlist(host), :inet)],
          ip <- Enum.take(ips, 4),
          {:ok, a} <- [query({ip, 123})],
          a.delay >= 0,
          do: Map.put(a, :host, host)

    case Enum.sort_by(answers, & &1.delay) do
      [best | _] -> {:ok, best, length(answers)}
      [] -> {:error, :no_server_answered}
    end
  end

  defp now, do: System.os_time(:nanosecond) / 1.0e9
  defp to_ntp(t), do: {trunc(t) + @epoch_offset, trunc((t - trunc(t)) * 4_294_967_296)}
  defp from_ntp(s, f), do: s - @epoch_offset + f / 4_294_967_296

  # -- the clock --------------------------------------------------------------------------------

  @doc """
  Move the system clock by `offset` seconds: wait for the moment the
  corrected clock starts a second, then set that second.
  """
  def step(offset) do
    target = now() + offset
    wait = 1 - (target - trunc(target))
    Process.sleep(round(wait * 1000))
    second = round(now() + offset)

    case Lepton.Sys.shim("date", ["-u", "-s", "@#{second}"]) do
      {_, 0} ->
        # Keep the hardware clock in step, for the next boot.
        if File.exists?("/dev/rtc0"), do: Lepton.Sys.shim("hwclock", ["-w", "-u"])
        :ok

      {out, _} ->
        {:error, String.trim(out)}
    end
  end

  # -- the time zone -------------------------------------------------------------------------------

  @geo [
    {"https://ipapi.co/timezone", :text},
    {"http://ip-api.com/line/?fields=timezone", :text}
  ]

  @doc "The time zone of this network's public address: `{:ok, zone}` or `{:error, reason}`."
  def geo_zone(lookups \\ @geo) do
    Enum.find_value(lookups, {:error, :no_answer}, fn {url, :text} ->
      case fetch(url) do
        {:ok, body} ->
          zone = String.trim(body)
          if Lepton.TZ.exists?(zone), do: {:ok, zone}

        _ ->
          nil
      end
    end)
  end

  defp fetch(url) do
    :inets.start()
    :ssl.start()
    ssl = Lepton.Git.Remote.ssl_opts([])
    headers = [{~c"user-agent", ~c"lepton-ntpd"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [ssl: ssl, timeout: 8000, connect_timeout: 5000], [body_format: :binary], Lepton.Proxy.httpc_profile(url)) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  # -- status ----------------------------------------------------------------------------------------

  @doc "What the daemon last did (for `timedatectl`): a map, or nil before it ran."
  def status, do: :persistent_term.get({__MODULE__, :status}, nil)

  defp put_status(changes) do
    :persistent_term.put({__MODULE__, :status}, Map.merge(status() || %{}, changes))
  end

  # -- the daemon ----------------------------------------------------------------------------------

  @doc """
  `ntpd`: keep the clock and (when automatic) the zone right until told
  to stop. `log` gets each line worth logging. Returns 0.
  """
  def daemon(log, opts \\ []) do
    _ = Lepton.Time.setting()
    put_status(%{running: true, synced: false})
    log.("ntpd started; servers: #{Enum.join(opts[:servers] || servers(), ", ")}")
    loop(log, opts, %{poll: @retry, failures: 0, geo_at: nil})
  end

  defp loop(log, opts, st) do
    st = maybe_geo(log, st)
    st = sync(log, opts, st)

    receive do
      {:signal, sig} when sig in [:term, :int] ->
        put_status(%{running: false})
        0
    after
      st.poll * 1000 -> loop(log, opts, st)
    end
  end

  defp sync(log, opts, st) do
    case sample(opts[:servers] || servers()) do
      {:ok, a, n} ->
        stepped = abs(a.offset) > @step

        result = if stepped, do: step(a.offset), else: :ok

        case result do
          :ok ->
            if stepped or st.failures > 0 or status()[:last_sync] == nil,
              do: log.("synchronised with #{a.host} (#{:inet.ntoa(a.server)}, stratum #{a.stratum}): offset #{fmt(a.offset)} s, delay #{fmt(a.delay)} s#{if stepped, do: "; clock stepped", else: ""}")

            put_status(%{synced: true, last_sync: System.os_time(:second), offset: a.offset, delay: a.delay, server: "#{a.host} (#{:inet.ntoa(a.server)})", answers: n})
            # In step: ask less often; after a step, check again soon.
            poll = if stepped, do: @min_poll, else: min(max(st.poll * 2, @min_poll), @max_poll)
            %{st | poll: poll, failures: 0}

          {:error, msg} ->
            log.("could not set the clock: #{msg}")
            %{st | poll: @min_poll, failures: st.failures + 1}
        end

      {:error, reason} ->
        if st.failures == 0, do: log.("no time server answered (#{inspect(reason)}); trying again")
        put_status(%{synced: status()[:last_sync] != nil and System.os_time(:second) - status()[:last_sync] < 3 * @max_poll})
        poll = if status()[:last_sync], do: @min_poll, else: @retry
        %{st | poll: poll, failures: st.failures + 1}
    end
  end

  defp maybe_geo(log, st) do
    due = st.geo_at == nil or System.monotonic_time(:second) >= st.geo_at

    if Lepton.Time.auto?() and due do
      case geo_zone() do
        {:ok, zone} ->
          if zone != Lepton.Time.zone() do
            :ok = Lepton.Time.set_zone(zone, :auto)
            log.("time zone: #{zone} (looked up from this network's address)")
          end

          put_status(%{zone_lookup: System.os_time(:second)})
          %{st | geo_at: System.monotonic_time(:second) + @geo_every}

        {:error, _} ->
          # No network yet: try again with the next poll.
          st
      end
    else
      st
    end
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3) |> then(&if(x >= 0, do: "+" <> &1, else: &1))

  @doc "`ntpd -q`: set the clock once and exit. Returns `{:ok, answer, stepped?}` or `{:error, reason}`."
  def once(servers \\ servers()) do
    with {:ok, a, _} <- sample(servers) do
      if abs(a.offset) > @step do
        with :ok <- step(a.offset), do: {:ok, a, true}
      else
        {:ok, a, false}
      end
    end
  end
end
