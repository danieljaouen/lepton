defmodule Lepton.Torrent.Tracker do
  @moduledoc """
  Asking a tracker for peers (an "announce"): over HTTP(S), a GET whose
  reply is bencoded (BEP 3, compact peer lists BEP 23), or over UDP
  (BEP 15: a connection id first, then the announce).
  """

  alias Lepton.Torrent.Bencode

  @doc """
  Announce to `url`. `a`: `%{info_hash, peer_id, port, uploaded, downloaded,
  left, event}` (`event`: `:started | :completed | :stopped | nil`). Returns
  `{:ok, %{interval: seconds, peers: [{ip, port}]}}` or `{:error, why}`.
  """
  def announce(url, a) do
    case URI.parse(url) do
      %{scheme: s} when s in ["http", "https"] -> http(url, a)
      %{scheme: "udp", host: h, port: p} when is_binary(h) and is_integer(p) -> udp(h, p, a)
      _ -> {:error, "unsupported tracker: #{url}"}
    end
  end

  # -- HTTP ----------------------------------------------------------------------------------------

  defp http(url, a) do
    params =
      [
        {"info_hash", a.info_hash},
        {"peer_id", a.peer_id},
        {"port", a.port},
        {"uploaded", a.uploaded},
        {"downloaded", a.downloaded},
        {"left", a.left},
        {"compact", 1},
        {"numwant", 80}
      ] ++ if(a[:event], do: [{"event", Atom.to_string(a.event)}], else: [])

    query = Enum.map_join(params, "&", fn {k, v} -> k <> "=" <> escape(to_string(v)) end)
    sep = if String.contains?(url, "?"), do: "&", else: "?"

    case Lepton.Alpine.get(url <> sep <> query) do
      {:ok, body} -> reply(body)
      {:error, {:http, code, _}} -> {:error, "the tracker answered #{code}"}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  # Every byte that isn't unreserved, %-escaped (the hashes are bytes, not text).
  defp escape(s), do: for(<<c <- s>>, into: "", do: if(c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-_.~", do: <<c>>, else: "%" <> Base.encode16(<<c>>)))

  @doc false
  def reply(body) do
    case Bencode.decode(body) do
      {:ok, %{"failure reason" => why}} -> {:error, "the tracker says: #{why}"}
      {:ok, %{} = d} -> {:ok, %{interval: d["interval"] || 1800, peers: peers(d["peers"]) ++ peers6(d["peers6"])}}
      _ -> {:error, "the tracker's reply isn't bencoded"}
    end
  end

  @doc false
  def peers(compact) when is_binary(compact), do: for(<<a, b, c, d, port::16 <- compact>>, port > 1, do: {"#{a}.#{b}.#{c}.#{d}", port})
  def peers(list) when is_list(list), do: for(%{"ip" => ip, "port" => p} <- list, is_binary(ip) and is_integer(p), do: {ip, p})
  def peers(_), do: []

  defp peers6(compact) when is_binary(compact) do
    for <<ip::binary-16, port::16 <- compact>>, port > 0 do
      words = for <<w::16 <- ip>>, do: w
      {:inet.ntoa(List.to_tuple(words)) |> to_string(), port}
    end
  end

  defp peers6(_), do: []

  # -- UDP -----------------------------------------------------------------------------------------

  @magic 0x41727101980

  defp udp(host, port, a) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

    try do
      with {:ok, conn} <- udp_connect(sock, host, port),
           {:ok, peers, interval} <- udp_announce(sock, host, port, conn, a) do
        {:ok, %{interval: interval, peers: peers}}
      end
    after
      :gen_udp.close(sock)
    end
  end

  defp udp_connect(sock, host, port) do
    tid = :rand.uniform(0xFFFFFFFF)

    case exchange(sock, host, port, <<@magic::64, 0::32, tid::32>>, tid) do
      {:ok, <<0::32, ^tid::32, conn::64, _::binary>>} -> {:ok, conn}
      {:ok, <<3::32, ^tid::32, msg::binary>>} -> {:error, "the tracker says: #{msg}"}
      {:ok, _} -> {:error, "a bad reply from the tracker"}
      err -> err
    end
  end

  defp udp_announce(sock, host, port, conn, a) do
    tid = :rand.uniform(0xFFFFFFFF)
    event = %{nil => 0, completed: 1, started: 2, stopped: 3}[a[:event]] || 0
    key = :rand.uniform(0xFFFFFFFF)
    msg = <<conn::64, 1::32, tid::32, a.info_hash::binary-20, a.peer_id::binary-20, a.downloaded::64, a.left::64, a.uploaded::64, event::32, 0::32, key::32, -1::signed-32, a.port::16>>

    case exchange(sock, host, port, msg, tid) do
      {:ok, <<1::32, ^tid::32, interval::32, _leechers::32, _seeders::32, peers::binary>>} -> {:ok, peers(peers), interval}
      {:ok, <<3::32, ^tid::32, msg::binary>>} -> {:error, "the tracker says: #{msg}"}
      {:ok, _} -> {:error, "a bad reply from the tracker"}
      err -> err
    end
  end

  # Send, and wait for the reply with this transaction id (BEP 15's
  # retries: 15 s, then 30 s; shortened here).
  defp exchange(sock, host, port, msg, tid) do
    Enum.reduce_while([5_000, 10_000], {:error, "the tracker didn't answer"}, fn wait, err ->
      case :gen_udp.send(sock, String.to_charlist(host), port, msg) do
        :ok ->
          case recv_tid(sock, tid, wait) do
            {:ok, data} -> {:halt, {:ok, data}}
            :timeout -> {:cont, err}
          end

        {:error, why} ->
          {:halt, {:error, "the tracker: #{:inet.format_error(why)}"}}
      end
    end)
  end

  defp recv_tid(sock, tid, wait) do
    case :gen_udp.recv(sock, 0, wait) do
      {:ok, {_, _, <<_::32, ^tid::32, _::binary>> = data}} -> {:ok, data}
      {:ok, _} -> recv_tid(sock, tid, wait)
      {:error, _} -> :timeout
    end
  end
end
