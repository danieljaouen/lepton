defmodule Lepton.Pipe do
  @moduledoc """
  A unidirectional byte pipe implemented as an Erlang I/O server.

  Writers block once 64 KiB are buffered (back-pressure). When every
  writer has closed, readers see EOF; when the reader has gone away,
  writers get `{:error, :epipe}`, which `Lepton.IO.write/2` turns into an
  exit - the BEAM equivalent of SIGPIPE.
  """

  use GenServer

  @limit 65_536

  defstruct buf: <<>>, writers: 1, reader: nil, waiting_reads: :queue.new(), blocked_writes: :queue.new(), broken: false

  def open(writers \\ 1), do: GenServer.start(__MODULE__, writers)
  def close_write(pipe), do: GenServer.cast(pipe, :close_write)
  def close_read(pipe), do: GenServer.cast(pipe, :close_read)
  def set_reader(pipe, pid), do: GenServer.cast(pipe, {:reader, pid})

  @impl true
  def init(writers), do: {:ok, %__MODULE__{writers: writers}}

  @impl true
  def handle_cast(:close_write, state) do
    state = %{state | writers: max(state.writers - 1, 0)}
    finish(serve(state))
  end

  def handle_cast(:close_read, state), do: {:noreply, break(state)}

  def handle_cast({:reader, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | reader: pid}}
  end

  @impl true
  def handle_info({:io_request, from, reply_as, req}, state) do
    state = request(from, reply_as, req, state)
    finish(serve(state))
  end

  def handle_info({:DOWN, _, :process, pid, _}, %{reader: pid} = state) do
    {:noreply, break(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp finish(%{writers: 0, buf: <<>>, broken: _} = state) do
    if :queue.is_empty(state.waiting_reads), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp finish(state), do: {:noreply, state}

  defp break(state) do
    for {from, reply_as, _} <- :queue.to_list(state.blocked_writes), do: send(from, {:io_reply, reply_as, {:error, :epipe}})
    %{state | broken: true, buf: <<>>, blocked_writes: :queue.new()}
  end

  defp request(from, reply_as, req, state) do
    case req do
      {:put_chars, enc, chars} -> put(from, reply_as, bytes(enc, chars), state)
      {:put_chars, enc, m, f, a} -> put(from, reply_as, bytes(enc, apply(m, f, a)), state)
      {:setopts, _} -> reply(from, reply_as, :ok, state)
      :getopts -> reply(from, reply_as, [binary: true, encoding: :unicode], state)
      {:get_geometry, _} -> reply(from, reply_as, {:error, :enotsup}, state)
      {:requests, reqs} -> Enum.reduce(reqs, state, &request(from, reply_as, &1, &2))
      r when elem(r, 0) in [:get_line, :get_chars, :get_until] -> %{state | waiting_reads: :queue.in({from, reply_as, r}, state.waiting_reads)}
      _ -> reply(from, reply_as, {:error, :request}, state)
    end
  end

  defp reply(from, reply_as, value, state) do
    send(from, {:io_reply, reply_as, value})
    state
  end

  defp put(from, reply_as, _data, %{broken: true} = state), do: reply(from, reply_as, {:error, :epipe}, state)

  defp put(from, reply_as, data, state) do
    state = %{state | buf: state.buf <> data}

    if byte_size(state.buf) > @limit do
      %{state | blocked_writes: :queue.in({from, reply_as, :ok}, state.blocked_writes)}
    else
      reply(from, reply_as, :ok, state)
    end
  end

  defp serve(state) do
    case :queue.out(state.waiting_reads) do
      {{:value, {from, reply_as, req}}, rest} ->
        case read(req, state) do
          {:ok, value, state} ->
            send(from, {:io_reply, reply_as, value})
            serve(release_writers(%{state | waiting_reads: rest}))

          :wait ->
            state
        end

      {:empty, _} ->
        release_writers(state)
    end
  end

  defp release_writers(state) do
    if byte_size(state.buf) <= @limit do
      for {from, reply_as, v} <- :queue.to_list(state.blocked_writes), do: send(from, {:io_reply, reply_as, v})
      %{state | blocked_writes: :queue.new()}
    else
      state
    end
  end

  defp read({:get_line, _enc, _prompt}, state) do
    case :binary.match(state.buf, "\n") do
      {pos, 1} ->
        line = binary_part(state.buf, 0, pos + 1)
        rest = binary_part(state.buf, pos + 1, byte_size(state.buf) - pos - 1)
        {:ok, line, %{state | buf: rest}}

      :nomatch ->
        cond do
          state.writers == 0 and state.buf == <<>> -> {:ok, :eof, state}
          state.writers == 0 -> {:ok, state.buf, %{state | buf: <<>>}}
          true -> :wait
        end
    end
  end

  defp read({:get_chars, _enc, _prompt, n}, state) do
    cond do
      byte_size(state.buf) >= n ->
        <<chunk::binary-size(^n), rest::binary>> = state.buf
        {:ok, chunk, %{state | buf: rest}}

      state.buf != <<>> ->
        {:ok, state.buf, %{state | buf: <<>>}}

      state.writers == 0 ->
        {:ok, :eof, state}

      true ->
        :wait
    end
  end

  defp read({:get_until, _enc, _prompt, m, f, a}, state) do
    if state.writers > 0 do
      :wait
    else
      chars = if state.buf == <<>>, do: :eof, else: :binary.bin_to_list(state.buf)

      result =
        case apply(m, f, [[], chars | a]) do
          {:done, r, _} -> r
          {:more, cont} -> case apply(m, f, [cont, :eof | a]) do
              {:done, r, _} -> r
              _ -> :eof
            end
        end

      result = if is_list(result), do: :erlang.list_to_binary(result), else: result
      {:ok, result, %{state | buf: <<>>}}
    end
  end

  defp bytes(_enc, chars) when is_binary(chars), do: chars

  defp bytes(_enc, chars) do
    case :unicode.characters_to_binary(chars) do
      b when is_binary(b) -> b
      _ -> IO.iodata_to_binary(chars)
    end
  end
end
