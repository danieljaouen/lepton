defmodule Lepton.Torrent.Session do
  @moduledoc """
  One torrent being downloaded or seeded: its pieces, its peers
  (`Lepton.Torrent.Peer`, up to #{40} at once) and where they come from
  (trackers, `Lepton.Torrent.Tracker`; the DHT, `Lepton.Torrent.DHT`,
  for a magnet link that names none or when peers are few; and peers
  that connect to us, through `Lepton.Torrent.Listener`).

  Pieces are handed out rarest first (the fewest connected peers have
  them), one peer each; at the end (no piece left that nobody is
  fetching) the missing ones go to more than one peer, and whichever
  arrives first counts. A piece is kept only if its SHA-1 is right.

  A magnet link starts without the files' list: the first peer that has
  the `info` dictionary sends it (and its hash must be the link's).
  Files already in the folder are checked first, so a stopped download
  resumes, and complete files seed.
  """

  use GenServer, restart: :temporary

  alias Lepton.Torrent
  alias Lepton.Torrent.{DHT, Metainfo, Peer, Storage, Tracker}

  @max_peers 40
  @connect_per_tick 6
  @dht_every 300_000

  # (`:key`: registered under another name than its hash, so that a test
  # can run a second session of the same torrent: the one the listener
  # doesn't find)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:key] || opts[:info_hash]))
  def via(hash), do: {:via, Registry, {Torrent.Registry, hash}}

  def whereis(hash) do
    case Registry.lookup(Torrent.Registry, hash) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def status(pid), do: GenServer.call(pid, :status)
  def add_peers(pid, addrs), do: GenServer.cast(pid, {:add_peers, addrs})

  # -- the server ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    meta = opts[:meta]

    st = %{
      info_hash: opts[:info_hash],
      name: (meta && meta.name) || opts[:name] || Base.encode16(opts[:info_hash], case: :lower),
      meta: meta,
      dir: opts[:dir],
      home: opts[:home],
      trackers: Enum.uniq((meta && meta.trackers || []) ++ (opts[:trackers] || [])),
      peer_id: Torrent.peer_id(),
      have: MapSet.new(),
      in_progress: %{},
      availability: %{},
      peers: %{},
      known: MapSet.new(),
      queue: [],
      state: if(meta, do: :checking, else: :metadata),
      check: 0.0,
      error: nil,
      downloaded: 0,
      uploaded: 0,
      window: {0, 0},
      rates: {0.0, 0.0},
      announces: %{},
      announced: %{},
      dht_at: 0,
      # (`dht: false`: never; for tests, and private trackers)
      use_dht: opts[:dht] != false,
      dht: nil,
      bad: 0,
      started: System.monotonic_time(:millisecond)
    }

    st = Enum.reduce(opts[:peers] || [], st, &learn(&2, &1))
    send(self(), :start)
    :timer.send_interval(1000, :tick)
    {:ok, st}
  end

  @impl true
  def handle_call(:status, _from, st), do: {:reply, view(st), st}

  def handle_call({:assign, pid, their}, _from, st) do
    case pick(st, pid, their) do
      nil -> {:reply, :none, st}
      i -> {:reply, {:ok, i}, %{st | in_progress: Map.update(st.in_progress, i, MapSet.new([pid]), &MapSet.put(&1, pid))}}
    end
  end

  # An incoming connection the listener matched to this torrent.
  def handle_call({:incoming, sock, their_id, ext?}, _from, st) do
    if map_size(st.peers) >= @max_peers + 10 do
      {:reply, :full, st}
    else
      {:ok, pid} = Peer.start_link(self(), {:socket, sock, their_id, ext?}, peer_info(st))
      {:reply, {:ok, pid}, %{st | peers: Map.put(st.peers, pid, %{addr: :incoming, their: MapSet.new(), up: false})}}
    end
  end

  @impl true
  def handle_cast({:add_peers, addrs}, st), do: {:noreply, Enum.reduce(addrs, st, &learn(&2, &1))}

  @impl true
  def handle_info(:start, %{meta: nil} = st), do: {:noreply, st |> announce_all(:started) |> maybe_dht(true)}
  def handle_info(:start, st), do: {:noreply, st |> start_check()}

  def handle_info({:checked, have}, st) do
    st = %{st | have: have, state: state_for(st.meta, have), check: 1.0}
    for pid <- Map.keys(st.peers), do: send(pid, {:meta, st.meta, have})
    Torrent.save_record(st)
    {:noreply, st |> announce_all(:started) |> maybe_dht(st.trackers == [])}
  end

  def handle_info({:check_progress, f}, st), do: {:noreply, %{st | check: f}}

  def handle_info(:tick, st) do
    {:noreply, st |> rates() |> connect_more() |> announce_due() |> maybe_dht(false)}
  end

  # -- from peers --

  def handle_info({:peer_up, pid, _id}, st), do: {:noreply, update_in(st.peers, &(if Map.has_key?(&1, pid), do: put_in(&1, [pid, :up], true), else: &1))}

  def handle_info({:peer_have, pid, pieces}, st) do
    case st.peers[pid] do
      nil -> {:noreply, st}
      p ->
        new = Enum.reject(pieces, &MapSet.member?(p.their, &1))
        avail = Enum.reduce(new, st.availability, fn i, a -> Map.update(a, i, 1, &(&1 + 1)) end)
        {:noreply, %{st | availability: avail, peers: Map.put(st.peers, pid, %{p | their: Enum.into(new, p.their)})}}
    end
  end

  def handle_info({:downloaded, n}, st), do: {:noreply, %{st | downloaded: st.downloaded + n}}
  def handle_info({:uploaded, n}, st), do: {:noreply, %{st | uploaded: st.uploaded + n}}

  def handle_info({:piece, pid, i, data}, st) do
    holders = Map.get(st.in_progress, i, MapSet.new())

    cond do
      st.meta == nil or MapSet.member?(st.have, i) ->
        send(pid, {:piece_done, i})
        {:noreply, st}

      :crypto.hash(:sha, data) == elem(st.meta.pieces, i) ->
        :ok = Storage.write_piece(st.meta, st.dir, i, data)
        have = MapSet.put(st.have, i)
        for p <- Map.keys(st.peers), do: send(p, {:have, i})
        for p <- holders, p != pid, do: send(p, {:piece_done, i})
        send(pid, {:piece_done, i})
        st = %{st | have: have, in_progress: Map.delete(st.in_progress, i)}

        if MapSet.size(have) == Metainfo.piece_count(st.meta) and st.state == :downloading do
          st = %{st | state: :seeding}
          Torrent.save_record(st)
          {:noreply, announce_all(st, :completed)}
        else
          {:noreply, st}
        end

      true ->
        # A bad piece: that peer's copy is dropped.
        send(pid, {:piece_done, i})
        {:noreply, %{st | bad: st.bad + 1, in_progress: drop_holder(st.in_progress, i, pid)}}
    end
  end

  def handle_info({:metadata, _pid, info}, %{meta: nil} = st) do
    if :crypto.hash(:sha, info) == st.info_hash do
      case Metainfo.from_info(info, st.trackers) do
        {:ok, meta} ->
          st = %{st | meta: meta, name: meta.name, state: :checking}
          Torrent.save_record(st)
          {:noreply, start_check(st)}

        {:error, _} ->
          {:noreply, st}
      end
    else
      {:noreply, st}
    end
  end

  def handle_info({:metadata, _, _}, st), do: {:noreply, st}

  # -- peers from trackers and the DHT --

  def handle_info({:announced, url, result}, st) do
    now = System.monotonic_time(:millisecond)

    case result do
      {:ok, %{interval: interval, peers: peers}} ->
        st = Enum.reduce(peers, st, &learn(&2, &1))
        {:noreply, %{st | announces: Map.put(st.announces, url, now + max(interval, 120) * 1000), announced: Map.put(st.announced, url, {:ok, length(peers)})}}

      {:error, why} ->
        {:noreply, %{st | announces: Map.put(st.announces, url, now + 600_000), announced: Map.put(st.announced, url, {:error, why})}}
    end
  end

  def handle_info({:dht_peers, peers}, st), do: {:noreply, Enum.reduce(peers, %{st | dht: length(peers)}, &learn(&2, &1))}

  def handle_info({:EXIT, pid, _}, st) do
    case Map.pop(st.peers, pid) do
      {nil, _} ->
        {:noreply, st}

      {p, peers} ->
        avail = Enum.reduce(p.their, st.availability, fn i, a -> Map.update(a, i, 0, &max(&1 - 1, 0)) end)
        in_progress = st.in_progress |> Enum.map(fn {i, set} -> {i, MapSet.delete(set, pid)} end) |> Enum.reject(fn {_, s} -> MapSet.size(s) == 0 end) |> Map.new()
        {:noreply, %{st | peers: peers, availability: avail, in_progress: in_progress}}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    if st.meta, do: spawn(fn -> for url <- st.trackers, do: Tracker.announce(url, announce_args(st, :stopped)) end)
    :ok
  end

  # -- pieces --------------------------------------------------------------------------------

  defp state_for(meta, have), do: if(MapSet.size(have) == Metainfo.piece_count(meta), do: :seeding, else: :downloading)

  defp start_check(st) do
    me = self()
    {meta, dir} = {st.meta, st.dir}
    spawn_link(fn -> send(me, {:checked, Storage.check(meta, dir, &send(me, {:check_progress, &1}))}) end)
    %{st | state: :checking}
  end

  # Rarest first among what the peer has and we lack and nobody fetches;
  # then (the end) what others fetch, if this peer isn't one of them.
  defp pick(%{meta: nil}, _pid, _their), do: nil
  defp pick(%{state: s}, _pid, _their) when s != :downloading, do: nil

  defp pick(st, pid, their) do
    wanted = Enum.reject(their, &MapSet.member?(st.have, &1))
    free = Enum.reject(wanted, &Map.has_key?(st.in_progress, &1))

    case free do
      [] ->
        others = Enum.filter(wanted, fn i -> not MapSet.member?(Map.get(st.in_progress, i, MapSet.new()), pid) end)
        if others == [], do: nil, else: Enum.random(others)

      list ->
        rarest = list |> Enum.map(&Map.get(st.availability, &1, 0)) |> Enum.min()
        list |> Enum.filter(&(Map.get(st.availability, &1, 0) == rarest)) |> Enum.random()
    end
  end

  defp drop_holder(in_progress, i, pid) do
    case Map.get(in_progress, i) do
      nil -> in_progress
      set -> s = MapSet.delete(set, pid); if MapSet.size(s) == 0, do: Map.delete(in_progress, i), else: Map.put(in_progress, i, s)
    end
  end

  # -- peers ---------------------------------------------------------------------------------

  defp learn(st, {host, port}) when is_binary(host) and is_integer(port) and port > 0 do
    addr = {host, port}
    if MapSet.member?(st.known, addr), do: st, else: %{st | known: MapSet.put(st.known, addr), queue: st.queue ++ [addr]}
  end

  defp learn(st, _), do: st

  defp peer_info(st), do: %{info_hash: st.info_hash, peer_id: st.peer_id, meta: st.meta, dir: st.dir, have: st.have}

  defp connect_more(%{state: s} = st) when s in [:checking], do: st

  defp connect_more(st) do
    # (seeding: peers that want what we have find us; we don't go looking)
    room = if st.state == :seeding, do: 0, else: min(@max_peers - map_size(st.peers), @connect_per_tick)
    {now, later} = Enum.split(st.queue, max(room, 0))

    peers =
      Enum.reduce(now, st.peers, fn addr, peers ->
        {:ok, pid} = Peer.start_link(self(), addr, peer_info(st))
        Map.put(peers, pid, %{addr: addr, their: MapSet.new(), up: false})
      end)

    %{st | peers: peers, queue: later}
  end

  # -- trackers and the DHT --------------------------------------------------------------------

  defp announce_args(st, event) do
    left = if st.meta, do: max(st.meta.length - have_bytes(st), 0), else: 16_384
    %{info_hash: st.info_hash, peer_id: st.peer_id, port: Torrent.Listener.port(), uploaded: st.uploaded, downloaded: st.downloaded, left: left, event: event}
  end

  defp announce_all(st, event) do
    now = System.monotonic_time(:millisecond)
    Enum.reduce(st.trackers, st, fn url, st -> announce(st, url, event, now) end)
  end

  defp announce_due(st) do
    now = System.monotonic_time(:millisecond)
    Enum.reduce(st.trackers, st, fn url, st -> if Map.get(st.announces, url, 0) <= now, do: announce(st, url, nil, now), else: st end)
  end

  defp announce(st, url, event, now) do
    me = self()
    args = announce_args(st, event)
    spawn(fn -> send(me, {:announced, url, Tracker.announce(url, args)}) end)
    # (not again until it answers, or for 10 minutes)
    %{st | announces: Map.put(st.announces, url, now + 600_000)}
  end

  # The DHT: for a torrent without trackers at once, else when peers are few.
  defp maybe_dht(st, now?) do
    t = System.monotonic_time(:millisecond)
    few = map_size(st.peers) + length(st.queue) < 10
    due = t - st.dht_at > @dht_every

    if st.use_dht && st.state != :seeding && (now? || (few && due)) && !(st.meta && st.meta.private) do
      me = self()
      hash = st.info_hash
      spawn(fn -> send(me, {:dht_peers, DHT.get_peers(hash)}) end)
      %{st | dht_at: t}
    else
      st
    end
  end

  # -- status --------------------------------------------------------------------------------

  defp have_bytes(%{meta: nil}), do: 0
  defp have_bytes(st), do: Enum.reduce(st.have, 0, &(&2 + Metainfo.piece_size(st.meta, &1)))

  # Rates: bytes over the last second, smoothed.
  defp rates(st) do
    {d0, u0} = st.window
    {rd, ru} = st.rates
    d = st.downloaded - d0
    u = st.uploaded - u0
    %{st | window: {st.downloaded, st.uploaded}, rates: {rd * 0.7 + d * 0.3, ru * 0.7 + u * 0.3}}
  end

  defp view(st) do
    {down, up} = st.rates
    size = st.meta && st.meta.length
    done = have_bytes(st)

    %{
      id: Base.encode16(st.info_hash, case: :lower),
      name: st.name,
      state: st.state,
      size: size,
      done: done,
      progress: cond do
        st.state == :checking -> st.check
        size in [nil, 0] -> 0.0
        true -> done / size
      end,
      pieces: st.meta && Metainfo.piece_count(st.meta),
      have: MapSet.size(st.have),
      peers: Enum.count(st.peers, fn {_, p} -> p.up end),
      connecting: Enum.count(st.peers, fn {_, p} -> not p.up end),
      known: MapSet.size(st.known),
      down_rate: down,
      up_rate: up,
      downloaded: st.downloaded,
      uploaded: st.uploaded,
      dir: st.dir,
      trackers: st.announced,
      dht: st.dht,
      bad: st.bad,
      error: st.error,
      eta: if(down > 1 and size, do: round((size - done) / down))
    }
  end
end
