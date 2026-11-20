defmodule Lepton.VDAgent do
  @moduledoc """
  The SPICE guest agent's clipboard (what `spice-vdagent` does on Linux):
  UTM (and virt-manager, or any SPICE client) shares the Mac's clipboard
  with Lepton's (`Lepton.Clipboard`), both ways.

  The client talks over a virtio serial port named `com.redhat.spice.0`
  (`/dev/vportNpM`), which UTM adds when the VM's **Clipboard Sharing** is
  on. The stream is SPICE's agent protocol (spice-protocol's
  `vd_agent.h`): chunks (`VDIChunkHeader`: port, size; at most 2048 bytes
  of data each) carrying messages (`VDAgentMessage`: protocol, type,
  opaque, size, data). The clipboard is by demand:

    * text copied on the Mac: the client says `CLIPBOARD_GRAB` (UTF-8
      text); the agent asks for it at once (`CLIPBOARD_REQUEST`) and puts
      the answer (`CLIPBOARD`) on Lepton's clipboard, for `pbpaste`, tmux,
      the editor and the desktop's programs;
    * text copied in Lepton: the agent says `CLIPBOARD_GRAB`, and answers
      the client's `CLIPBOARD_REQUEST` with it when the Mac pastes.

  While an agent is connected, the SPICE server also sends it the mouse
  (`MOUSE_STATE`: the position on a display, and the buttons) instead of
  moving the VM's tablet, so the agent passes it on to the desktop
  (Photon, which registers with `watch_pointer/1`).

  Without the port (another VM, real hardware, the host) it does nothing.
  """

  use GenServer
  import Bitwise

  # VDIChunkHeader ports, VDAgentMessage types and capabilities (vd_agent.h)
  @client_port 1
  @max_chunk 2048
  @protocol 1

  @mouse_state 1
  @clipboard 4
  @announce 6
  @grab 7
  @request 8
  @release 9

  @utf8_text 1

  # VDAgentMouseState buttons: SPICE's masks, and the evdev codes Photon takes
  @buttons [{1 <<< 1, 0x110}, {1 <<< 2, 0x112}, {1 <<< 3, 0x111}]
  @wheel_up 1 <<< 4
  @wheel_down 1 <<< 5

  @cap_clipboard_by_demand 5
  @cap_guest_lineend_lf 8

  @port_name "com.redhat.spice.0"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Whether the agent is talking to a SPICE client's port (for pbpaste's man page and tests)."
  def connected?(server \\ __MODULE__) do
    case Process.whereis(server) || server do
      pid when is_pid(pid) -> GenServer.call(pid, :connected?)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc "Send `pid` the SPICE client's mouse, as Photon input events (`{:input, event}`)."
  def watch_pointer(pid) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:watch_pointer, pid})
    :ok
  end

  # -- the protocol -------------------------------------------------------------------------------

  @doc "A message, as chunks for the virtio port."
  def encode(type, data) do
    msg = <<@protocol::little-32, type::little-32, 0::little-64, byte_size(data)::little-32>> <> data
    chunks(msg)
  end

  defp chunks(<<part::binary-size(@max_chunk), rest::binary>>) when rest != "", do: [chunk(part) | chunks(rest)]
  defp chunks(part), do: [chunk(part)]
  defp chunk(part), do: <<@client_port::little-32, byte_size(part)::little-32>> <> part

  @doc """
  Bytes read from the port, added to `buf` (`%{chunks: binary, msgs: %{port => binary}}`):
  `{messages, buf}`, each message `{type, data}`.
  """
  def decode(bytes, buf \\ %{chunks: "", msgs: %{}}) do
    {msgs, buf} = take_chunks(buf.chunks <> bytes, buf.msgs)
    {complete, msgs} = take_messages(msgs)
    {complete, %{chunks: buf, msgs: msgs}}
  end

  defp take_chunks(<<port::little-32, size::little-32, data::binary-size(size), rest::binary>>, msgs),
    do: take_chunks(rest, Map.update(msgs, port, data, &(&1 <> data)))

  defp take_chunks(partial, msgs), do: {msgs, partial}

  defp take_messages(msgs) do
    Enum.reduce(msgs, {[], %{}}, fn {port, stream}, {done, left} ->
      {found, rest} = messages(stream, [])
      {done ++ found, Map.put(left, port, rest)}
    end)
  end

  defp messages(<<_proto::little-32, type::little-32, _opaque::little-64, size::little-32, data::binary-size(size), rest::binary>>, acc),
    do: messages(rest, [{type, data} | acc])

  defp messages(partial, acc), do: {Enum.reverse(acc), partial}

  defp announce(request) do
    caps = (1 <<< @cap_clipboard_by_demand) ||| (1 <<< @cap_guest_lineend_lf)
    encode(@announce, <<request::little-32, caps::little-32>>)
  end

  # -- the agent -----------------------------------------------------------------------------------

  # opts: `:send` (a fun given the bytes to write; tests), else the port is
  # looked for in /sys/class/virtio-ports.
  @impl true
  def init(opts) do
    state = %{port: nil, send: opts[:send], buf: %{chunks: "", msgs: %{}}, from_host: nil, tries: 0, pointers: [], mouse: 0}

    if state.send do
      {:ok, start(state)}
    else
      send(self(), :find)
      {:ok, state}
    end
  end

  defp start(state) do
    Lepton.Clipboard.watch(self())
    write(state, announce(1))
    state
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.port != nil or state.send != nil, state}

  @impl true
  def handle_cast({:watch_pointer, pid}, state), do: {:noreply, %{state | pointers: Enum.uniq([pid | Enum.filter(state.pointers, &Process.alive?/1)])}}

  @impl true
  def handle_info(:find, state) do
    case find_port() do
      nil ->
        # virtio_console is loaded during boot: look for a while.
        if state.tries < 20 and File.dir?("/sys/class"), do: Process.send_after(self(), :find, 3000)
        {:noreply, %{state | tries: state.tries + 1}}

      dev ->
        case open(dev) do
          {:ok, port} -> {:noreply, start(%{state | port: port})}
          _ -> {:noreply, state}
        end
    end
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = state), do: received(bytes, state)
  def handle_info({:vdagent_data, bytes}, state), do: received(bytes, state)

  # Copied in Lepton: tell the client there is text to paste (unless it came from the client).
  def handle_info({:clipboard, text}, state) do
    if text != state.from_host and text != "", do: write(state, encode(@grab, <<@utf8_text::little-32>>))
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp received(bytes, state) do
    {msgs, buf} = decode(bytes, state.buf)
    {:noreply, Enum.reduce(msgs, %{state | buf: buf}, &message/2)}
  end

  # The client's capabilities; when it asks, ours again.
  defp message({@announce, <<request::little-32, _::binary>>}, state) do
    if request != 0, do: write(state, announce(0))
    state
  end

  # Copied on the Mac: fetch it now, so pbpaste has it.
  defp message({@grab, types}, state) do
    if @utf8_text in (for <<t::little-32 <- types>>, do: t), do: write(state, encode(@request, <<@utf8_text::little-32>>))
    state
  end

  defp message({@clipboard, <<@utf8_text::little-32, text::binary>>}, state) do
    text = String.trim_trailing(text, <<0>>)
    state = %{state | from_host: text}
    Lepton.Clipboard.put(text)
    state
  end

  # The Mac pastes what Lepton copied.
  defp message({@request, <<@utf8_text::little-32, _::binary>>}, state) do
    write(state, encode(@clipboard, <<@utf8_text::little-32>> <> Lepton.Clipboard.get()))
    state
  end

  defp message({@request, _}, state) do
    write(state, encode(@clipboard, <<0::little-32>>))
    state
  end

  # The mouse: where it is on display `id` (pixels), and what changed of its buttons.
  defp message({@mouse_state, <<x::little-32, y::little-32, buttons::little-32, id, _::binary>>}, state) do
    pressed = fn mask, b -> (b &&& mask) != 0 end
    was = state.mouse

    events =
      [{:abs_px, x, y, id}] ++
        for({mask, code} <- @buttons, pressed.(mask, buttons) != pressed.(mask, was), do: {:button, code, pressed.(mask, buttons)}) ++
        if(pressed.(@wheel_up, buttons) and not pressed.(@wheel_up, was), do: [{:wheel, -1}], else: []) ++
        if(pressed.(@wheel_down, buttons) and not pressed.(@wheel_down, was), do: [{:wheel, 1}], else: [])

    for pid <- state.pointers, e <- events, do: send(pid, {:input, e})
    %{state | mouse: buttons}
  end

  defp message({@release, _}, state), do: state
  defp message(_, state), do: state

  defp write(%{send: f}, data) when is_function(f), do: f.(IO.iodata_to_binary(data))
  defp write(%{port: port}, data) when port != nil, do: Port.command(port, data)
  defp write(_, _), do: :ok

  # -- the port ---------------------------------------------------------------------------------------

  defp find_port do
    Path.wildcard("/sys/class/virtio-ports/*/name")
    |> Enum.find_value(fn name ->
      if File.read(name) |> elem(1) |> to_string() |> String.trim() == @port_name, do: "/dev/" <> Path.basename(Path.dirname(name))
    end)
  rescue
    _ -> nil
  end

  # Read by an fd port: one read(2) at a time (a raw file's reads wait to fill their buffer).
  defp open(dev) do
    with {:ok, file} <- :file.open(String.to_charlist(dev), [:read, :write, :raw, :binary]) do
      <<fd::native-32>> = :prim_file.get_handle(file)
      Process.put(:vdagent_file, file)
      {:ok, Port.open({:fd, fd, fd}, [:binary, :stream])}
    end
  end
end
