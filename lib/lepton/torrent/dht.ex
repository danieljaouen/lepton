defmodule Lepton.Torrent.DHT do
  @moduledoc """
  Finding peers without a tracker: BitTorrent's DHT (BEP 5), a network of
  nodes each keeping track of who has which torrents. `get_peers/2` asks
  well-known nodes, then the nodes they name that are closer to the info
  hash (XOR distance), several at a time, for a few rounds, and returns
  the peers they gave. It looks things up; it doesn't keep a routing
  table or answer other nodes' queries.
  """

  alias Lepton.Torrent.Bencode

  @bootstrap [{"router.bittorrent.com", 6881}, {"dht.transmissionbt.com", 6881}, {"router.utorrent.com", 6881}, {"dht.libtorrent.org", 25401}]
  @alpha 8
  @rounds 8
  @wait 2_500

  @doc "Peers for `info_hash` (`[{ip, port}]`). Options: `:bootstrap` (nodes to start from), `:rounds`."
  def get_peers(info_hash, opts \\ []) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: true])

    try do
      id = :crypto.strong_rand_bytes(20)
      start = for {h, p} <- opts[:bootstrap] || @bootstrap, ip = resolve(h), do: {nil, ip, p}
      lookup(sock, id, info_hash, start, MapSet.new(), MapSet.new(), opts[:rounds] || @rounds)
    after
      :gen_udp.close(sock)
    end
  end

  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  # Each round: ask the closest nodes not asked yet.
  defp lookup(_sock, _id, _hash, _nodes, _asked, peers, 0), do: MapSet.to_list(peers)
  defp lookup(_sock, _id, _hash, [], _asked, peers, _), do: MapSet.to_list(peers)

  defp lookup(sock, id, hash, nodes, asked, peers, rounds) do
    batch = nodes |> Enum.reject(fn {_, ip, p} -> MapSet.member?(asked, {ip, p}) end) |> Enum.take(@alpha)

    if batch == [] do
      MapSet.to_list(peers)
    else
      tids =
        for {{_, ip, port}, n} <- Enum.with_index(batch), into: %{} do
          tid = <<rounds, n>>
          msg = Bencode.encode(%{"t" => tid, "y" => "q", "q" => "get_peers", "a" => %{"id" => id, "info_hash" => hash}})
          :gen_udp.send(sock, ip, port, msg)
          {tid, {ip, port}}
        end

      {found_nodes, found_peers} = collect(tids, @wait, [], [])
      asked = Enum.reduce(batch, asked, fn {_, ip, p}, a -> MapSet.put(a, {ip, p}) end)
      peers = Enum.into(found_peers, peers)

      # (enough peers: stop early)
      if MapSet.size(peers) >= 60 do
        MapSet.to_list(peers)
      else
        nodes = (nodes ++ found_nodes) |> Enum.uniq_by(fn {_, ip, p} -> {ip, p} end) |> Enum.sort_by(fn {nid, _, _} -> distance(nid, hash) end)
        lookup(sock, id, hash, nodes, asked, peers, rounds - 1)
      end
    end
  end

  defp collect(tids, wait, nodes, peers) when map_size(tids) == 0 or wait <= 0, do: {nodes, peers}

  defp collect(tids, wait, nodes, peers) do
    t0 = System.monotonic_time(:millisecond)

    receive do
      {:udp, _, _ip, _port, data} ->
        left = wait - (System.monotonic_time(:millisecond) - t0)

        case Bencode.decode(data) do
          {:ok, %{"t" => tid, "y" => "r", "r" => r}} when is_map_key(tids, tid) ->
            more_nodes = compact_nodes(r["nodes"])
            more_peers = for v <- List.wrap(r["values"]), is_binary(v), p <- Lepton.Torrent.Tracker.peers(v), do: p
            collect(Map.delete(tids, tid), left, nodes ++ more_nodes, peers ++ more_peers)

          _ ->
            collect(tids, left, nodes, peers)
        end
    after
      wait -> {nodes, peers}
    end
  end

  @doc false
  # 26 bytes a node: its id, IPv4 address, port.
  def compact_nodes(bin) when is_binary(bin), do: for(<<nid::binary-20, a, b, c, d, port::16 <- bin>>, port > 0, do: {nid, {a, b, c, d}, port})
  def compact_nodes(_), do: []

  defp distance(nil, _), do: <<255::160>>
  defp distance(a, b), do: :crypto.exor(a, b)
end
