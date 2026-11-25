defmodule Lepton.Torrent.Peer do
  @moduledoc """
  One connection to a peer (BEP 3's wire protocol): the handshake, then
  messages, each a 4-byte length and an id (`packet: 4` does the
  framing). It asks the torrent's `Lepton.Torrent.Session` for a piece
  the peer has and it lacks, requests its 16 KiB blocks a few at a time,
  and hands the piece back whole for checking. It answers the peer's
  requests for pieces the session has (everyone interested is unchoked:
  simple, and generous), and trades the `info` dictionary for magnet
  links (BEP 9 and 10: `ut_metadata`).
  """

  alias Lepton.Torrent.{Metainfo, Storage}

  @block 16_384
  @pipeline 8
  @idle 150_000
  @keepalive 90_000

  @choke 0
  @unchoke 1
  @interested 2
  @not_interested 3
  @have 4
  @bitfield 5
  @request 6
  @piece 7
  @extended 20

  @doc """
  Connect to `addr` (`{host, port}`), or take over `{:socket, sock}` (an
  incoming peer whose handshake the listener has read). Linked to the
  caller (the session).
  """
  def start_link(session, addr, info) do
    pid = spawn_link(fn -> init(session, addr, info) end)
    {:ok, pid}
  end

  @doc "The handshake: protocol name, reserved bits (extensions: 0x10 in byte 5), info hash, peer id."
  def handshake(info_hash, peer_id), do: <<19, "BitTorrent protocol", 0, 0, 0, 0, 0, 0x10, 0, 0, info_hash::binary-20, peer_id::binary-20>>

  defp init(session, addr, info) do
    case connect(addr, info) do
      {:ok, sock, their_id, ext?} ->
        :ok = :inet.setopts(sock, packet: 4, packet_size: 4 * 1024 * 1024, active: :once)

        st = %{
          sock: sock,
          session: session,
          info_hash: info.info_hash,
          meta: info.meta,
          dir: info.dir,
          have: info.have,
          their: MapSet.new(),
          their_id: their_id,
          choked: true,
          interested: false,
          they_interested: false,
          we_choke: true,
          ext: %{},
          meta_size: nil,
          meta_parts: %{},
          piece: nil,
          last: now()
        }

        if ext?, do: send_ext_handshake(st)
        if st.meta && MapSet.size(st.have) > 0, do: send_msg(st, @bitfield, bitfield(st.have, Metainfo.piece_count(st.meta)))
        send(session, {:peer_up, self(), their_id})
        Process.send_after(self(), :tick, 10_000)
        loop(st)

      {:error, _why} ->
        exit(:normal)
    end
  end

  # (the listener gives the socket over, then says so)
  defp connect({:socket, sock, their_id, ext?}, _info) do
    receive do
      :socket_ready -> {:ok, sock, their_id, ext?}
    after
      5_000 -> {:error, :no_socket}
    end
  end

  defp connect({host, port}, info) do
    with {:ok, sock} <- :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: :raw], 10_000),
         :ok <- :gen_tcp.send(sock, handshake(info.info_hash, info.peer_id)),
         {:ok, <<19, "BitTorrent protocol", reserved::binary-8, hash::binary-20, their_id::binary-20>>} <- :gen_tcp.recv(sock, 68, 15_000),
         true <- hash == info.info_hash || {:error, :wrong_torrent},
         true <- their_id != info.peer_id || {:error, :ourselves} do
      <<_::40, ext, _::16>> = reserved
      {:ok, sock, their_id, Bitwise.band(ext, 0x10) != 0}
    else
      {:ok, _} -> {:error, :bad_handshake}
      {:error, why} -> {:error, why}
      other -> {:error, other}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # -- the loop ------------------------------------------------------------------------------

  defp loop(st) do
    receive do
      {:tcp, _, data} ->
        :inet.setopts(st.sock, active: :once)
        st |> Map.put(:last, now()) |> message(data) |> loop()

      {:tcp_closed, _} ->
        exit(:normal)

      {:tcp_error, _, _} ->
        exit(:normal)

      # From the session: a piece it now has; the torrent's info (a magnet's).
      {:have, i} ->
        if !MapSet.member?(st.their, i), do: send_msg(st, @have, <<i::32>>)
        st = %{st | have: MapSet.put(st.have, i)}
        st |> update_interest() |> loop()

      {:meta, meta, have} ->
        st = %{st | meta: meta, have: have}
        if MapSet.size(have) > 0, do: send_msg(st, @bitfield, bitfield(have, Metainfo.piece_count(meta)))
        st |> update_interest() |> request_more() |> loop()

      # The session checked the piece this peer brought: on to the next.
      {:piece_done, i} ->
        st = if match?(%{index: ^i}, st.piece), do: %{st | piece: nil}, else: st
        st |> update_interest() |> request_more() |> loop()

      :tick ->
        if now() - st.last > @idle, do: exit(:normal)
        if now() - Process.get(:sent, 0) > @keepalive, do: (:gen_tcp.send(st.sock, <<>>); Process.put(:sent, now()))
        Process.send_after(self(), :tick, 10_000)
        loop(st)

      :close ->
        :gen_tcp.close(st.sock)
        exit(:normal)
    end
  end

  # -- messages ------------------------------------------------------------------------------

  # (an empty message: a keep-alive)
  defp message(st, <<>>), do: st
  defp message(st, <<@choke>>), do: %{st | choked: true}
  defp message(st, <<@unchoke>>), do: request_more(%{st | choked: false})

  defp message(st, <<@interested>>) do
    # Everyone interested may download from us.
    if st.we_choke, do: send_msg(st, @unchoke, <<>>)
    %{st | they_interested: true, we_choke: false}
  end

  defp message(st, <<@not_interested>>), do: %{st | they_interested: false}

  defp message(st, <<@have, i::32>>) do
    st = %{st | their: MapSet.put(st.their, i)}
    send(st.session, {:peer_have, self(), [i]})
    st |> update_interest() |> request_more()
  end

  defp message(st, <<@bitfield, bits::binary>>) do
    their = for {1, i} <- Enum.with_index(for(<<b::1 <- bits>>, do: b)), into: MapSet.new(), do: i
    their = if st.meta, do: MapSet.filter(their, &(&1 < Metainfo.piece_count(st.meta))), else: their
    send(st.session, {:peer_have, self(), MapSet.to_list(their)})
    %{st | their: their} |> update_interest() |> request_more()
  end

  defp message(st, <<@request, i::32, begin::32, len::32>>) do
    if !st.we_choke && st.meta && MapSet.member?(st.have, i) && len <= 4 * @block do
      case Storage.read(st.meta, st.dir, i, begin, len) do
        {:ok, data} ->
          send_msg(st, @piece, [<<i::32, begin::32>>, data])
          send(st.session, {:uploaded, byte_size(data)})

        :error ->
          :ok
      end
    end

    st
  end

  defp message(st, <<@piece, i::32, begin::32, data::binary>>) do
    case st.piece do
      %{index: ^i} = p ->
        p = %{p | blocks: Map.put(p.blocks, begin, data), out: MapSet.delete(p.out, begin)}
        send(st.session, {:downloaded, byte_size(data)})

        if map_size(p.blocks) == length(p.offsets) do
          whole = p.offsets |> Enum.map(&p.blocks[&1]) |> IO.iodata_to_binary()
          send(st.session, {:piece, self(), i, whole})
          # (kept until the session says it's done with it)
          %{st | piece: %{p | out: MapSet.new(), done: true}}
        else
          request_more(%{st | piece: p})
        end

      _ ->
        st
    end
  end

  defp message(st, <<@extended, 0, dict::binary>>) do
    case Lepton.Torrent.Bencode.decode(dict) do
      {:ok, %{} = d} ->
        ext = d["m"] || %{}
        size = d["metadata_size"]
        st = %{st | ext: ext, meta_size: if(is_integer(size) and size > 0 and size < 16 * 1024 * 1024, do: size)}
        request_metadata(st)

      _ ->
        st
    end
  end

  defp message(st, <<@extended, 1, payload::binary>>), do: metadata_message(st, payload)
  defp message(st, _other), do: st

  # -- downloading ---------------------------------------------------------------------------

  defp update_interest(%{meta: nil} = st), do: st

  defp update_interest(st) do
    want = Enum.any?(st.their, &(not MapSet.member?(st.have, &1)))

    cond do
      want and not st.interested -> send_msg(st, @interested, <<>>); %{st | interested: true}
      not want and st.interested and st.piece == nil -> send_msg(st, @not_interested, <<>>); %{st | interested: false}
      true -> st
    end
  end

  defp request_more(%{meta: nil} = st), do: st
  defp request_more(%{choked: true} = st), do: st
  defp request_more(%{piece: %{done: true}} = st), do: st

  defp request_more(%{piece: nil} = st) do
    case GenServer.call(st.session, {:assign, self(), st.their}, 30_000) do
      {:ok, i} ->
        size = Metainfo.piece_size(st.meta, i)
        offsets = Enum.to_list(0..(size - 1)//@block)
        request_more(%{st | piece: %{index: i, size: size, offsets: offsets, blocks: %{}, out: MapSet.new(), done: false}})

      :none ->
        st
    end
  catch
    :exit, _ -> st
  end

  defp request_more(%{piece: p} = st) do
    wanted = Enum.reject(p.offsets, &(Map.has_key?(p.blocks, &1) or MapSet.member?(p.out, &1)))
    room = @pipeline - MapSet.size(p.out)

    out =
      wanted
      |> Enum.take(max(room, 0))
      |> Enum.reduce(p.out, fn begin, out ->
        len = min(@block, p.size - begin)
        send_msg(st, @request, <<p.index::32, begin::32, len::32>>)
        MapSet.put(out, begin)
      end)

    %{st | piece: %{p | out: out}}
  end

  # -- the info dictionary (BEP 9) -------------------------------------------------------------

  defp send_ext_handshake(st) do
    d = %{"m" => %{"ut_metadata" => 1}, "v" => "Lepton"}
    d = if st.meta, do: Map.put(d, "metadata_size", byte_size(st.meta.info)), else: d
    send_msg(st, @extended, [0, Lepton.Torrent.Bencode.encode(d)])
  end

  # Ask for the pieces of the info dictionary (16 KiB each), if we lack it.
  defp request_metadata(%{meta: nil, meta_size: size} = st) when is_integer(size) do
    case st.ext["ut_metadata"] do
      id when is_integer(id) and id > 0 ->
        for p <- 0..div(size - 1, @block), do: send_msg(st, @extended, [id, Lepton.Torrent.Bencode.encode(%{"msg_type" => 0, "piece" => p})])
        st

      _ ->
        st
    end
  end

  defp request_metadata(st), do: st

  defp metadata_message(st, payload) do
    with {:ok, d, rest} <- Lepton.Torrent.Bencode.decode_prefix(payload) do
      case d do
        # a request: send that part of ours (or say no)
        %{"msg_type" => 0, "piece" => p} ->
          id = st.ext["ut_metadata"]

          if st.meta && is_integer(id) do
            info = st.meta.info
            from = p * @block

            if from < byte_size(info) do
              part = binary_part(info, from, min(@block, byte_size(info) - from))
              send_msg(st, @extended, [id, Lepton.Torrent.Bencode.encode(%{"msg_type" => 1, "piece" => p, "total_size" => byte_size(info)}), part])
            end
          else
            if is_integer(id), do: send_msg(st, @extended, [id, Lepton.Torrent.Bencode.encode(%{"msg_type" => 2, "piece" => p})])
          end

          st

        # data
        %{"msg_type" => 1, "piece" => p} when st.meta == nil and is_integer(st.meta_size) ->
          parts = Map.put(st.meta_parts, p, rest)
          count = div(st.meta_size - 1, @block) + 1

          if map_size(parts) == count do
            info = 0..(count - 1) |> Enum.map(&parts[&1]) |> IO.iodata_to_binary()
            send(st.session, {:metadata, self(), info})
            %{st | meta_parts: %{}}
          else
            %{st | meta_parts: parts}
          end

        _ ->
          st
      end
    else
      _ -> st
    end
  end

  # -- sending ---------------------------------------------------------------------------------

  defp send_msg(st, id, payload) do
    :gen_tcp.send(st.sock, [id, payload])
    Process.put(:sent, now())
  end

  @doc "A bitfield: one bit a piece, the first piece the high bit of the first byte."
  def bitfield(have, count) do
    bits = for i <- 0..(count - 1)//1, into: <<>>, do: <<if(MapSet.member?(have, i), do: 1, else: 0)::1>>
    pad = rem(8 - rem(bit_size(bits), 8), 8)
    <<bits::bitstring, 0::size(pad)>>
  end
end
