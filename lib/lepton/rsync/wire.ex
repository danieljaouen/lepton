defmodule Lepton.Rsync.Wire do
  @moduledoc """
  rsync's byte stream (protocol 27): little-endian integers, and the
  multiplexing envelope the server wraps around everything it sends
  after the handshake (a 4-byte header: tag + 7 in the top byte, length
  below; tag 0 is data, 1 an error, 2 information, 3 a log line).

  A connection is a reader and a writer process over a transport's
  `recv` (`fn n -> binary | :eof end`, up to n bytes) and `send`
  (`fn iodata -> :ok end`), so the sender, the receiver and the
  generator can use it from their own processes.
  """

  defstruct [:r, :w]

  @mplex_base 7
  @msg_data 0

  def open(recv, send, log) do
    {:ok, r} = GenServer.start_link(__MODULE__.Reader, {recv, log})
    {:ok, w} = GenServer.start_link(__MODULE__.Writer, send)
    %__MODULE__{r: r, w: w}
  end

  def close(%__MODULE__{r: r, w: w}) do
    for pid <- [r, w], Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Bytes `{read, written}` so far."
  def counts(%__MODULE__{r: r, w: w}), do: {GenServer.call(r, :count), GenServer.call(w, :count)}

  @doc "Unwrap the envelope when reading (the client, after the handshake)."
  def demux(%__MODULE__{r: r}), do: GenServer.call(r, :mplex)
  @doc "Wrap writes in the envelope (the server, after the handshake)."
  def mux(%__MODULE__{w: w}), do: GenServer.call(w, :mplex)

  # -- reading ----------------------------------------------------------------------------

  def read(%__MODULE__{r: r}, 0) when is_pid(r), do: ""

  def read(%__MODULE__{r: r}, n) do
    case GenServer.call(r, {:read, n}, :infinity) do
      {:ok, data} -> data
      {:error, reason} -> throw({:rsync_error, 12, reason})
    end
  end

  def read_int(c), do: (<<i::little-signed-32>> = read(c, 4); i)
  def read_byte(c), do: (<<b>> = read(c, 1); b)

  def read_long(c) do
    case read_int(c) do
      -1 -> <<l::little-signed-64>> = read(c, 8); l
      i -> i
    end
  end

  # -- writing ----------------------------------------------------------------------------

  def write(%__MODULE__{w: w}, data), do: GenServer.call(w, {:write, @msg_data, data}, :infinity)

  @doc "An out-of-band message from the server (`:error` or `:info`), shown by the client."
  def message(%__MODULE__{w: w}, kind, text), do: GenServer.call(w, {:message, kind, text}, :infinity)

  def int(i), do: <<i::little-signed-32>>
  def byte(b), do: <<b>>
  def long(l) when l >= 0 and l <= 0x7FFFFFFF, do: int(l)
  def long(l), do: [int(-1), <<l::little-signed-64>>]

  def write_int(c, i), do: write(c, int(i))
  def write_long(c, l), do: write(c, long(l))

  defmodule Reader do
    @moduledoc false
    use GenServer

    def init({recv, log}), do: {:ok, %{recv: recv, log: log, mplex: false, raw: <<>>, data: <<>>, left: 0, count: 0}}

    def handle_call(:mplex, _from, st), do: {:reply, :ok, %{st | mplex: true}}
    def handle_call(:count, _from, st), do: {:reply, st.count, st}

    def handle_call({:read, n}, _from, st) do
      case fill(st, n) do
        {:ok, st} ->
          <<chunk::binary-size(^n), rest::binary>> = st.data
          {:reply, {:ok, chunk}, %{st | data: rest}}

        {:error, reason, st} ->
          {:reply, {:error, reason}, st}
      end
    end

    defp fill(%{data: data} = st, n) when byte_size(data) >= n, do: {:ok, st}
    defp fill(%{mplex: false} = st, n), do: with({:ok, bytes, st} <- raw(st, n - byte_size(st.data), :some), do: fill(%{st | data: st.data <> bytes}, n))

    defp fill(%{left: 0} = st, n) do
      with {:ok, <<len::little-24, tag>>, st} <- raw(st, 4, :all) do
        case tag - 7 do
          0 ->
            fill(%{st | left: len}, n)

          kind ->
            with {:ok, text, st} <- raw(st, len, :all) do
              st.log.(if(kind == 1, do: :error, else: :info), text)
              fill(st, n)
            end
        end
      end
    end

    defp fill(st, n) do
      with {:ok, bytes, st} <- raw(st, min(st.left, n - byte_size(st.data)), :some) do
        fill(%{st | data: st.data <> bytes, left: st.left - byte_size(bytes)}, n)
      end
    end

    # `n` raw bytes (`:all`), or at least one and at most n (`:some`).
    defp raw(%{raw: buf} = st, n, how) when byte_size(buf) >= n do
      <<chunk::binary-size(^n), rest::binary>> = buf
      _ = how
      {:ok, chunk, %{st | raw: rest}}
    end

    defp raw(%{raw: buf} = st, _n, :some) when buf != <<>>, do: {:ok, buf, %{st | raw: <<>>}}

    defp raw(st, n, how) do
      case st.recv.(max(n - byte_size(st.raw), 65_536)) do
        data when is_binary(data) and data != "" -> raw(%{st | raw: st.raw <> data, count: st.count + byte_size(data)}, n, how)
        _ -> {:error, "connection unexpectedly closed", st}
      end
    end
  end

  defmodule Writer do
    @moduledoc false
    use GenServer

    @tags %{error: 1, info: 2}

    def init(send), do: {:ok, %{send: send, mplex: false, count: 0}}

    def handle_call(:mplex, _from, st), do: {:reply, :ok, %{st | mplex: true}}
    def handle_call(:count, _from, st), do: {:reply, st.count, st}

    def handle_call({:write, tag, data}, _from, st) do
      data = IO.iodata_to_binary(data)
      {:reply, out(st, tag, data), %{st | count: st.count + byte_size(data)}}
    end

    # Without the envelope (the client), messages are the caller's to show.
    def handle_call({:message, kind, text}, _from, %{mplex: true} = st), do: {:reply, out(st, @tags[kind], text), st}
    def handle_call({:message, _kind, _text}, _from, st), do: {:reply, :ok, st}

    defp out(%{mplex: false} = st, _tag, data), do: st.send.(data)
    defp out(_st, _tag, ""), do: :ok

    defp out(st, tag, data), do: st.send.(frames(data, tag))

    # The envelope's length field has 24 bits.
    defp frames(<<chunk::binary-size(0xFFFFFF), rest::binary>>, tag), do: [frame(chunk, tag) | frames(rest, tag)]
    defp frames("", _tag), do: []
    defp frames(data, tag), do: [frame(data, tag)]

    defp frame(data, tag), do: [<<byte_size(data)::little-24, tag + 7>>, data]
  end

  @doc false
  def mplex_base, do: @mplex_base
end
