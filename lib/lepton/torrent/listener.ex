defmodule Lepton.Torrent.Listener do
  @moduledoc """
  Where other peers connect to us: a TCP port (the first free one of
  6881-6889), shared by every torrent. A connection's handshake says
  which torrent it's for (its info hash); that torrent's session takes
  it, if it has one.
  """

  use GenServer, restart: :transient

  alias Lepton.Torrent.{Peer, Session}

  @ports 6881..6889

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Start it (once)."
  def ensure_started do
    if Process.whereis(__MODULE__) == nil do
      DynamicSupervisor.start_child(Lepton.Torrent.Supervisor, %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}, restart: :transient})
    end

    :ok
  end

  @doc "The port it listens on (what trackers are told)."
  def port, do: :persistent_term.get({__MODULE__, :port}, Enum.at(@ports, 0))

  @impl true
  def init(nil) do
    case Enum.find_value(@ports, &listen/1) do
      {sock, port} ->
        :persistent_term.put({__MODULE__, :port}, port)
        me = self()
        spawn_link(fn -> accept(sock, me) end)
        {:ok, %{sock: sock, port: port}}

      nil ->
        # (no port: we still connect out)
        {:ok, %{sock: nil, port: nil}}
    end
  end

  defp listen(port) do
    case :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, sock} -> {sock, port}
      _ -> nil
    end
  end

  defp accept(sock, owner) do
    case :gen_tcp.accept(sock) do
      {:ok, conn} ->
        pid = spawn(fn -> greet(conn) end)
        :gen_tcp.controlling_process(conn, pid)
        send(pid, :go)
        accept(sock, owner)

      {:error, _} ->
        :ok
    end
  end

  # Read their handshake, find the torrent, answer, and hand the socket over.
  defp greet(conn) do
    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end

    with {:ok, <<19, "BitTorrent protocol", reserved::binary-8, hash::binary-20, their_id::binary-20>>} <- :gen_tcp.recv(conn, 68, 10_000),
         session when is_pid(session) <- Session.whereis(hash),
         %{} = status <- Session.status(session),
         _ = status,
         {:ok, pid} <- GenServer.call(session, {:incoming, conn, their_id, ext?(reserved)}) do
      :gen_tcp.send(conn, Peer.handshake(hash, Lepton.Torrent.peer_id()))
      :gen_tcp.controlling_process(conn, pid)
      send(pid, :socket_ready)
    else
      _ -> :gen_tcp.close(conn)
    end
  catch
    _, _ -> :gen_tcp.close(conn)
  end

  defp ext?(<<_::40, b, _::16>>), do: Bitwise.band(b, 0x10) != 0
end
