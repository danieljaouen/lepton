defmodule Lepton.Photon do
  @moduledoc """
  Photon, Lepton's Wayland compositor.

  A Wayland server written in Elixir: clients connect to a Unix socket
  (`$XDG_RUNTIME_DIR/wayland-0`) and speak the real protocol
  (`Lepton.Wayland.Protocol`: the core interfaces and `xdg-shell`). Any
  client that draws with `wl_shm` buffers can use it, Lepton's own
  terminal (`Lepton.Photon.Term`) included.

  * **Output**: the framebuffer (`Lepton.Photon.Output`); only damaged
    rectangles are recomposed and written, at most once a frame (60 Hz).
  * **Windows**: server-side decorations (title bar, close button,
    border), click to focus and raise, drag the title bar (or Alt+drag
    anywhere) to move, drag the bottom-right corner (or Alt+right-drag) to
    resize.
  * **Input**: evdev keyboards, mice and tablets (`Lepton.Photon.Input`),
    delivered to clients as `wl_keyboard`/`wl_pointer` events with a US
    XKB keymap (`Lepton.Wayland.Keymap`).
  * **Keys**: Alt+Return opens a terminal, Alt+Tab cycles windows, Alt+F4
    closes one, Ctrl+Alt+Backspace quits.

  Buffers are copied when committed (from the client's memory file) and
  released at once, so clients never wait on Photon. Lepton's own clients
  pass their memory files by path (`lepton_shm`, see
  `Lepton.Wayland.Protocol`), other clients by descriptor (`wl_shm`).
  """

  use GenServer

  require Logger

  alias Lepton.Photon.{Output, Render}
  alias Lepton.Wayland.{Conn, Keymap, Protocol, Wire}

  import Bitwise

  @frame_ms 16
  @help "Photon   Alt+Return: terminal   Alt+Tab: next window   Alt+F4: close   Ctrl+Alt+Backspace: quit"

  @globals [{1, "wl_compositor"}, {2, "wl_shm"}, {3, "wl_seat"}, {4, "wl_output"}, {5, "xdg_wm_base"}, {6, "lepton_shm"}]

  # wl_shm formats: ARGB8888 and XRGB8888 (alpha is ignored: windows are opaque).
  @formats [0, 1]

  # xdg_toplevel states
  @maximized 1
  @resizing 3
  @activated 4

  defmodule Client do
    @moduledoc false
    # lepton: the client uses lepton_shm (no descriptors, no keymap)
    defstruct [:sock, :reader, buf: "", fds: [], objects: %{}, pools: %{}, lepton: false]
  end

  defmodule Surface do
    @moduledoc false
    defstruct pending: %{buffer: :unchanged, damage: [], frames: [], geometry: nil},
              content: nil,
              w: 0,
              h: 0,
              role: nil,
              xdg: nil,
              configured: false,
              title: nil,
              app_id: nil,
              geometry: nil
  end

  defmodule Win do
    @moduledoc false
    # x, y: the frame's top-left (toplevels) or the content's (popups)
    defstruct [:key, :kind, :x, :y, :title_rows, :parent, maximized: nil]
  end

  defstruct [
    :output,
    :socket_path,
    :listener,
    :keymap,
    :spawn,
    :background,
    clients: %{},
    windows: [],
    serial: 0,
    pointer: {0.0, 0.0},
    pointer_focus: nil,
    keyboard_focus: nil,
    buttons: MapSet.new(),
    grab: nil,
    mods: 0,
    locked: 0,
    bound_keys: MapSet.new(),
    damage: [],
    repaint: nil,
    frame_callbacks: [],
    place: 0,
    started: 0,
    owner: nil,
    console: false
  ]

  # -- API ---------------------------------------------------------------------------------

  @doc """
  Start Photon. Options:

    * `:output` - a `Lepton.Photon.Output` (required)
    * `:socket` - the socket path (required)
    * `:input` - `:evdev` to read the kernel's input devices (default: none)
    * `:spawn` - a function Alt+Return calls to open a terminal
    * `:name` - register under this name
    * `:console` - take the display from the text console: stop fbcon
      drawing and mute `/dev/tty1` while Photon runs
    * `:session` - stop when this process exits (the `photon` command;
      C-c kills it)
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.put(opts, :owner, self()), name: opts[:name])
  def start(opts), do: GenServer.start(__MODULE__, Keyword.put(opts, :owner, self()), name: opts[:name])

  def stop(server), do: GenServer.stop(server)

  @doc "Inject an input event (see `Lepton.Photon.Input`)."
  def input(server, event), do: send(server, {:input, event})

  @doc "Clients, windows and the output, for `photon info`."
  def info(server), do: GenServer.call(server, :info)

  @doc "The composed screen as a PNG."
  def screenshot(server), do: GenServer.call(server, :screenshot, 30_000)

  @doc "Wait until everything damaged so far is on the output."
  def sync(server), do: GenServer.call(server, :sync, 10_000)

  # -- server ------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    out = Output.open(Keyword.fetch!(opts, :output))
    path = Keyword.fetch!(opts, :socket)

    case Conn.listen(path) do
      {:ok, listener} ->
        me = self()
        spawn_link(fn -> Conn.accept_loop(listener, fn sock -> send(me, {:accepted, sock}) end) end)
        if opts[:input] == :evdev, do: Lepton.Photon.Input.start(me)
        if opts[:session], do: Process.monitor(opts[:session])

        if opts[:console] do
          Output.text_console(false)
          if tty = Lepton.TTY.whereis("/dev/tty1"), do: Lepton.TTY.mute(tty, me)
        end

        st = %__MODULE__{
          output: out,
          socket_path: path,
          listener: listener,
          keymap: keymap_file(path),
          spawn: opts[:spawn],
          background: Render.background(out.width, out.height, @help),
          pointer: {out.width / 2, out.height / 2},
          started: System.monotonic_time(:millisecond),
          owner: opts[:owner],
          console: opts[:console] == true
        }

        {:ok, damage(st, {0, 0, out.width, out.height})}

      {:error, reason} ->
        {:stop, "cannot listen on #{path}: #{inspect(reason)}"}
    end
  end

  # The XKB keymap clients map with wl_keyboard.keymap: a file next to the socket.
  defp keymap_file(socket) do
    path = socket <> ".xkb"
    text = Keymap.xkb() <> <<0>>
    File.write!(path, text)
    {:ok, f} = :file.open(String.to_charlist(path), [:raw, :read, :binary])
    File.rm(path)
    {f, Conn.file_fd(f), byte_size(text)}
  end

  @impl true
  def terminate(_reason, st) do
    for {sock, _} <- st.clients, do: :socket.close(sock)
    :socket.close(st.listener)
    File.rm(st.socket_path)
    # The console comes back as it was (the TTY unmutes when we exit).
    if st.console, do: Output.text_console(true)
    :ok
  end

  @impl true
  def handle_call(:info, _from, st) do
    clients = map_size(st.clients)

    windows =
      for w <- Enum.reverse(st.windows) do
        s = surface(st, w.key)
        %{title: s.title, app_id: s.app_id, kind: w.kind, x: w.x, y: w.y, width: s.w, height: s.h, focused: w.key == st.keyboard_focus}
      end

    {:reply, %{socket: st.socket_path, clients: clients, windows: windows, output: {st.output.width, st.output.height}}, st}
  end

  def handle_call(:screenshot, _from, st) do
    st = repaint(st)
    %{width: w, height: h} = st.output
    {:reply, Output.png(Output.read(st.output, 0, 0, w, h), w, h), st}
  end

  def handle_call(:sync, _from, st), do: {:reply, :ok, repaint(st)}

  @impl true
  def handle_info({:accepted, sock}, st) do
    reader = Conn.start_reader(sock, self())
    {:noreply, put_in(st.clients[sock], %Client{sock: sock, reader: reader})}
  end

  def handle_info({:wl_data, sock, data, fds}, st) do
    case st.clients[sock] do
      nil ->
        {:noreply, st}

      c ->
        c = %{c | buf: c.buf <> data, fds: c.fds ++ fds}
        st = put_in(st.clients[sock], c)
        {:noreply, process(st, sock)}
    end
  end

  def handle_info({:wl_closed, sock}, st), do: {:noreply, disconnect(st, sock)}

  def handle_info({:input, event}, st), do: {:noreply, handle_input(event, st)}

  def handle_info(:repaint, st), do: {:noreply, repaint(%{st | repaint: nil})}
  def handle_info(:quit, st), do: {:stop, :normal, st}

  def handle_info({:EXIT, _pid, _reason}, st), do: {:noreply, st}
  def handle_info({:DOWN, _, :process, _session, _}, st), do: {:stop, :normal, st}

  def handle_info(_msg, st), do: {:noreply, st}

  # -- requests ----------------------------------------------------------------------------

  defp process(st, sock) do
    c = st.clients[sock]

    {msgs, rest} =
      try do
        Wire.split(c.buf)
      rescue
        ArgumentError -> {:error, nil}
      end

    if msgs == :error do
      disconnect(st, sock)
    else
      st = put_in(st.clients[sock].buf, rest)
      Enum.reduce_while(msgs, st, fn msg, st ->
        st = dispatch(st, sock, msg)
        if Map.has_key?(st.clients, sock), do: {:cont, st}, else: {:halt, st}
      end)
    end
  end

  defp dispatch(st, sock, {id, opcode, payload}) do
    c = st.clients[sock]

    case c.objects[id] || if(id == 1, do: %{iface: "wl_display", version: 1, data: nil}) do
      nil ->
        protocol_error(st, sock, 1, 0, "invalid object #{id}")

      obj ->
        case Protocol.request(obj.iface, opcode) do
          nil ->
            protocol_error(st, sock, id, 1, "invalid method #{opcode} on #{obj.iface}@#{id}")

          {name, types} ->
            try do
              {args, fds} = Wire.decode(types, payload, c.fds)
              st = put_in(st.clients[sock].fds, fds)
              st = request(st, sock, id, obj, name, args)

              if Protocol.destructor?(obj.iface, name) and Map.has_key?(st.clients, sock),
                do: destroy(st, sock, id),
                else: st
            rescue
              e in ArgumentError ->
                protocol_error(st, sock, 1, 1, "#{obj.iface}.#{name}: #{Exception.message(e)}")
            end
        end
    end
  end

  defp request(st, sock, _id, _obj, :sync, [cb]) do
    emit(st, sock, cb, "wl_callback", :done, [st.serial])
    emit(st, sock, 1, "wl_display", :delete_id, [cb])
    st
  end

  defp request(st, sock, _id, _obj, :get_registry, [reg]) do
    st = new_object(st, sock, reg, "wl_registry", 1)
    for {name, iface} <- @globals, do: emit(st, sock, reg, "wl_registry", :global, [name, iface, Protocol.version(iface)])
    st
  end

  defp request(st, sock, _id, %{iface: "wl_registry"}, :bind, [name, {iface, version, new}]) do
    case List.keyfind(@globals, name, 0) do
      {^name, ^iface} when version >= 1 ->
        if version > Protocol.version(iface) do
          protocol_error(st, sock, 1, 0, "#{iface} v#{version} is not supported (max #{Protocol.version(iface)})")
        else
          st |> new_object(sock, new, iface, version) |> bound(sock, new, iface, version)
        end

      _ ->
        protocol_error(st, sock, 1, 0, "invalid global #{name} (#{iface})")
    end
  end

  # wl_compositor
  defp request(st, sock, _id, obj, :create_surface, [new]), do: new_object(st, sock, new, "wl_surface", obj.version, %Surface{})
  defp request(st, sock, _id, obj, :create_region, [new]), do: new_object(st, sock, new, "wl_region", obj.version, [])

  # wl_region (input and opaque regions are not used: windows are opaque rectangles)
  defp request(st, _sock, _id, %{iface: "wl_region"}, _op, _args), do: st

  # wl_shm
  defp request(st, sock, _id, %{iface: "wl_shm"}, :create_pool, [new, fd, size]) do
    case Conn.open_fd(fd) do
      {:ok, file} -> new_pool(st, sock, new, file, size)
      {:error, reason} -> protocol_error(st, sock, 1, 2, "wl_shm.create_pool: cannot open the pool: #{inspect(reason)}")
    end
  end

  # lepton_shm: the pool is a file in our runtime directory, which we open and remove.
  defp request(st, sock, id, %{iface: "lepton_shm"}, :create_pool, [new, path, size]) do
    path = Path.expand(path)

    with true <- Path.dirname(path) == Path.dirname(st.socket_path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, file} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      File.rm(path)
      st = put_in(st.clients[sock].lepton, true)
      new_pool(st, sock, new, file, size)
    else
      _ -> protocol_error(st, sock, id, 0, "lepton_shm.create_pool: #{path} is not a file in #{Path.dirname(st.socket_path)}")
    end
  end

  # wl_shm_pool
  defp request(st, sock, id, obj, :create_buffer, [new, offset, w, h, stride, format]) do
    pool = st.clients[sock].pools[obj.data]

    cond do
      format not in @formats ->
        protocol_error(st, sock, id, 0, "unsupported format #{format}")

      w <= 0 or h <= 0 or stride < w * 4 or offset < 0 or offset + stride * h > pool.size ->
        protocol_error(st, sock, id, 2, "invalid buffer #{w}x#{h} stride #{stride} offset #{offset} in a #{pool.size}-byte pool")

      true ->
        st = update_in(st.clients[sock].pools[obj.data].buffers, &(&1 + 1))
        new_object(st, sock, new, "wl_buffer", 1, %{pool: obj.data, offset: offset, w: w, h: h, stride: stride})
    end
  end

  defp request(st, sock, _id, obj, :resize, [size]), do: put_in(st.clients[sock].pools[obj.data].size, size)

  # wl_surface
  defp request(st, sock, id, _obj, :attach, [buffer, _x, _y]), do: update_surface(st, sock, id, &put_in(&1.pending.buffer, buffer))

  defp request(st, sock, id, %{iface: "wl_surface"}, op, [x, y, w, h]) when op in [:damage, :damage_buffer],
    do: update_surface(st, sock, id, &update_in(&1.pending.damage, fn d -> [{x, y, w, h} | d] end))

  defp request(st, sock, id, _obj, :frame, [cb]) do
    st = new_object(st, sock, cb, "wl_callback", 1)
    update_surface(st, sock, id, &update_in(&1.pending.frames, fn f -> [cb | f] end))
  end

  defp request(st, sock, id, _obj, :commit, []), do: commit(st, sock, id)

  defp request(st, _sock, _id, %{iface: "wl_surface"}, op, _args) when op in [:set_opaque_region, :set_input_region, :set_buffer_transform, :set_buffer_scale], do: st

  # wl_seat
  defp request(st, sock, _id, obj, :get_pointer, [new]), do: new_object(st, sock, new, "wl_pointer", obj.version)

  defp request(st, sock, _id, obj, :get_keyboard, [new]) do
    st = new_object(st, sock, new, "wl_keyboard", obj.version)
    {_f, fd, size} = st.keymap
    unless st.clients[sock].lepton, do: emit(st, sock, new, "wl_keyboard", :keymap, [1, fd, size])
    if obj.version >= 4, do: emit(st, sock, new, "wl_keyboard", :repeat_info, [25, 400])

    case st.keyboard_focus do
      {^sock, sid} ->
        emit(st, sock, new, "wl_keyboard", :enter, [next_serial(st), sid, ""])
        emit(st, sock, new, "wl_keyboard", :modifiers, [st.serial, st.mods, 0, st.locked, 0])
        bump(st)

      _ ->
        st
    end
  end

  defp request(st, sock, _id, obj, :get_touch, [new]), do: new_object(st, sock, new, "wl_touch", obj.version)
  defp request(st, _sock, _id, %{iface: "wl_pointer"}, :set_cursor, _args), do: st
  defp request(st, _sock, _id, _obj, :release, []), do: st

  # xdg_wm_base
  defp request(st, sock, _id, _obj, :create_positioner, [new]), do: new_object(st, sock, new, "xdg_positioner", 1, %{size: {1, 1}, anchor_rect: {0, 0, 1, 1}, anchor: 0, gravity: 0, offset: {0, 0}})

  defp request(st, sock, _id, _obj, :get_xdg_surface, [new, sid]) do
    case surface(st, {sock, sid}) do
      %Surface{role: nil, content: nil} ->
        st = new_object(st, sock, new, "xdg_surface", 1, %{surface: sid})
        update_surface(st, sock, sid, &%{&1 | xdg: new})

      %Surface{} ->
        protocol_error(st, sock, new, 2, "wl_surface@#{sid} already has a role or a buffer")
    end
  end

  defp request(st, _sock, _id, _obj, :pong, _), do: st

  # xdg_positioner
  defp request(st, sock, id, %{iface: "xdg_positioner"}, op, args) do
    {key, value} =
      case {op, args} do
        {:set_size, [w, h]} -> {:size, {w, h}}
        {:set_anchor_rect, [x, y, w, h]} -> {:anchor_rect, {x, y, w, h}}
        {:set_anchor, [a]} -> {:anchor, a}
        {:set_gravity, [g]} -> {:gravity, g}
        {:set_offset, [x, y]} -> {:offset, {x, y}}
        {_, _} -> {:ignored, nil}
      end

    update_in(st.clients[sock].objects[id].data, &Map.put(&1, key, value))
  end

  # xdg_surface
  defp request(st, sock, id, obj, :get_toplevel, [new]) do
    st = new_object(st, sock, new, "xdg_toplevel", 1, %{xdg: id, surface: obj.data.surface})
    update_surface(st, sock, obj.data.surface, &%{&1 | role: {:toplevel, new}})
  end

  defp request(st, sock, id, obj, :get_popup, [new, parent, positioner]) do
    pos = st.clients[sock].objects[positioner].data
    parent_sid = parent && st.clients[sock].objects[parent] && st.clients[sock].objects[parent].data.surface
    st = new_object(st, sock, new, "xdg_popup", 1, %{xdg: id, surface: obj.data.surface})
    update_surface(st, sock, obj.data.surface, &%{&1 | role: {:popup, new, parent_sid, pos}})
  end

  defp request(st, sock, _id, obj, :set_window_geometry, [x, y, w, h]),
    do: update_surface(st, sock, obj.data.surface, &put_in(&1.pending.geometry, {x, y, w, h}))

  defp request(st, _sock, _id, _obj, :ack_configure, [_serial]), do: st

  # xdg_toplevel
  defp request(st, sock, _id, obj, :set_title, [title]) do
    st = update_surface(st, sock, obj.data.surface, &%{&1 | title: title})
    redecorate(st, {sock, obj.data.surface})
  end

  defp request(st, sock, _id, obj, :set_app_id, [app_id]), do: update_surface(st, sock, obj.data.surface, &%{&1 | app_id: app_id})

  defp request(st, sock, _id, obj, :move, [_seat, _serial]) do
    key = {sock, obj.data.surface}

    case {window(st, key), st.buttons != MapSet.new()} do
      {%Win{} = w, true} ->
        {px, py} = st.pointer
        %{st | grab: {:move, key, px - w.x, py - w.y}}

      _ ->
        st
    end
  end

  defp request(st, sock, _id, obj, :resize, [_seat, _serial, _edges]) do
    if st.buttons != MapSet.new(), do: start_resize(st, {sock, obj.data.surface}), else: st
  end

  defp request(st, sock, _id, obj, :set_maximized, []), do: maximize(st, {sock, obj.data.surface}, true)
  defp request(st, sock, _id, obj, :unset_maximized, []), do: maximize(st, {sock, obj.data.surface}, false)
  defp request(st, sock, _id, obj, :set_fullscreen, [_output]), do: maximize(st, {sock, obj.data.surface}, true)
  defp request(st, sock, _id, obj, :unset_fullscreen, []), do: maximize(st, {sock, obj.data.surface}, false)

  defp request(st, _sock, _id, %{iface: "xdg_toplevel"}, op, _args) when op in [:set_parent, :show_window_menu, :set_max_size, :set_min_size, :set_minimized], do: st
  defp request(st, _sock, _id, %{iface: "xdg_popup"}, :grab, _args), do: st

  # destructors: the object goes in destroy/3
  defp request(st, _sock, _id, _obj, :destroy, []), do: st

  defp request(st, sock, id, obj, name, _args), do: protocol_error(st, sock, id, 1, "#{obj.iface}.#{name} is not implemented")

  # Initial events after binding a global.
  defp bound(st, sock, id, "wl_shm", _v) do
    for f <- @formats, do: emit(st, sock, id, "wl_shm", :format, [f])
    st
  end

  defp bound(st, sock, id, "wl_seat", v) do
    emit(st, sock, id, "wl_seat", :capabilities, [3])
    if v >= 2, do: emit(st, sock, id, "wl_seat", :name, ["seat0"])
    st
  end

  defp bound(st, sock, id, "wl_output", v) do
    %{width: w, height: h} = st.output
    emit(st, sock, id, "wl_output", :geometry, [0, 0, round(w / 3.78), round(h / 3.78), 0, "Lepton", "Photon display", 0])
    emit(st, sock, id, "wl_output", :mode, [3, w, h, 60_000])

    if v >= 2 do
      emit(st, sock, id, "wl_output", :scale, [1])
      emit(st, sock, id, "wl_output", :done, [])
    end

    st
  end

  defp bound(st, _sock, _id, _iface, _v), do: st

  defp new_pool(st, sock, id, file, size) do
    ref = make_ref()
    st = put_in(st.clients[sock].pools[ref], %{file: file, size: size, buffers: 0, alive: true})
    new_object(st, sock, id, "wl_shm_pool", 1, ref)
  end

  # -- objects -----------------------------------------------------------------------------

  defp new_object(st, sock, id, iface, version, data \\ nil) do
    cond do
      id == 0 or id >= 0xFF000000 -> protocol_error(st, sock, 1, 0, "invalid new id #{id}")
      Map.has_key?(st.clients[sock].objects, id) -> protocol_error(st, sock, 1, 0, "id #{id} already in use")
      true -> put_in(st.clients[sock].objects[id], %{iface: iface, version: version, data: data})
    end
  end

  defp destroy(st, sock, id) do
    obj = st.clients[sock].objects[id]
    st = release_object(st, sock, id, obj)
    st = update_in(st.clients[sock].objects, &Map.delete(&1, id))
    emit(st, sock, 1, "wl_display", :delete_id, [id])
    st
  end

  defp release_object(st, sock, _id, %{iface: "wl_shm_pool", data: ref}) do
    st = put_in(st.clients[sock].pools[ref].alive, false)
    maybe_close_pool(st, sock, ref)
  end

  defp release_object(st, sock, _id, %{iface: "wl_buffer", data: %{pool: ref}}) do
    st = update_in(st.clients[sock].pools[ref].buffers, &(&1 - 1))
    maybe_close_pool(st, sock, ref)
  end

  defp release_object(st, sock, id, %{iface: "wl_surface"}), do: unmap(st, {sock, id})
  defp release_object(st, sock, _id, %{iface: "xdg_toplevel", data: %{surface: sid}}), do: unmap(st, {sock, sid}) |> clear_role(sock, sid)
  defp release_object(st, sock, _id, %{iface: "xdg_popup", data: %{surface: sid}}), do: unmap(st, {sock, sid}) |> clear_role(sock, sid)
  defp release_object(st, _sock, _id, _obj), do: st

  defp clear_role(st, sock, sid), do: update_surface(st, sock, sid, &%{&1 | role: nil, configured: false, content: nil})

  defp maybe_close_pool(st, sock, ref) do
    case st.clients[sock].pools[ref] do
      %{alive: false, buffers: n, file: f} when n <= 0 ->
        :file.close(f)
        update_in(st.clients[sock].pools, &Map.delete(&1, ref))

      _ ->
        st
    end
  end

  defp surface(st, {sock, sid}) do
    with %Client{objects: objs} <- st.clients[sock], %{data: %Surface{} = s} <- objs[sid], do: s, else: (_ -> nil)
  end

  defp update_surface(st, sock, sid, fun) do
    case st.clients[sock] && st.clients[sock].objects[sid] do
      %{data: %Surface{}} -> update_in(st.clients[sock].objects[sid].data, fun)
      _ -> st
    end
  end

  defp window(st, key), do: Enum.find(st.windows, &(&1.key == key))

  # -- commit ------------------------------------------------------------------------------

  defp commit(st, sock, sid) do
    key = {sock, sid}
    old = surface(st, key)
    p = old.pending
    {st, s, area} = apply_buffer(st, sock, old, p)
    {s, area} = if p.geometry && p.geometry != s.geometry, do: {%{s | geometry: p.geometry}, :all}, else: {s, area}
    s = %{s | pending: %{buffer: :unchanged, damage: [], frames: [], geometry: nil}}

    # A frame that changes size is damaged before and after.
    st = if area == :all, do: damage_window(st, key), else: st
    st = put_in(st.clients[sock].objects[sid].data, s)
    st = %{st | frame_callbacks: Enum.map(Enum.reverse(p.frames), &{sock, &1}) ++ st.frame_callbacks}

    st =
      case area do
        :all -> st |> redecorate(key) |> damage_window(key)
        {x, y, w, h} -> damage_content(st, key, {x, y, w, h})
        nil -> st
      end

    st = role_commit(st, sock, sid, s)
    if p.frames != [], do: schedule(st), else: st
  end

  # Copies the attached buffer's pixels (the damaged rows) and releases it.
  # Returns `{st, surface, damaged}` with damaged :all, a rectangle or nil.
  defp apply_buffer(st, _sock, s, %{buffer: :unchanged}), do: {st, s, nil}
  defp apply_buffer(st, _sock, s, %{buffer: nil}), do: {st, %{s | content: nil, w: 0, h: 0}, :all}

  defp apply_buffer(st, sock, s, %{buffer: bid, damage: damage}) do
    c = st.clients[sock]

    case c.objects[bid] do
      %{iface: "wl_buffer", data: b} ->
        pool = c.pools[b.pool]
        resized = s.content == nil or b.w != s.w or b.h != s.h

        {y0, y1} =
          if resized or damage == [] do
            {0, b.h}
          else
            ys = Enum.flat_map(damage, fn {_x, y, _w, h} -> [max(y, 0), min(y + h, b.h)] end)
            {Enum.min(ys), max(Enum.max(ys), Enum.min(ys))}
          end

        content =
          if y1 > y0 do
            {:ok, data} = :file.pread(pool.file, b.offset + y0 * b.stride, (y1 - y0) * b.stride)
            data = pad_to(data, (y1 - y0) * b.stride)
            stride = b.stride
            rows = if stride == b.w * 4, do: data, else: (for <<row::binary-size(^stride) <- data>>, into: <<>>, do: binary_part(row, 0, b.w * 4))

            if resized, do: rows, else: binary_part(s.content, 0, y0 * b.w * 4) <> rows <> binary_part(s.content, y1 * b.w * 4, (b.h - y1) * b.w * 4)
          else
            s.content
          end

        emit(st, sock, bid, "wl_buffer", :release, [])
        {st, %{s | content: content, w: b.w, h: b.h}, if(resized, do: :all, else: {0, y0, b.w, y1 - y0})}

      _ ->
        {st, s, nil}
    end
  end

  defp pad_to(data, n) when byte_size(data) >= n, do: data
  defp pad_to(data, n), do: data <> :binary.copy(<<0>>, n - byte_size(data))

  defp role_commit(st, sock, sid, s) do
    key = {sock, sid}

    case s.role do
      {kind, role_id, _, _} when kind == :popup -> xdg_commit(st, sock, key, s, :popup, role_id)
      {:toplevel, role_id} -> xdg_commit(st, sock, key, s, :toplevel, role_id)
      _ -> st
    end
  end

  defp xdg_commit(st, sock, key, s, kind, role_id) do
    cond do
      not s.configured ->
        st = update_surface(st, sock, elem(key, 1), &%{&1 | configured: true})

        if kind == :toplevel do
          configure(st, key, 0, 0, [@activated])
        else
          {_, _, _, pos} = s.role
          {w, h} = pos.size
          {x, y} = popup_position(pos, w, h)
          emit(st, sock, role_id, "xdg_popup", :configure, [x, y, w, h])
          emit(st, sock, s.xdg, "xdg_surface", :configure, [next_serial(st)])
          bump(st)
        end

      s.content != nil and window(st, key) == nil ->
        map_window(st, key, kind)

      s.content == nil and window(st, key) != nil ->
        unmap(st, key)

      true ->
        # Geometry or size changes move the frame's edges.
        st
    end
  end

  defp configure(st, {sock, _sid} = key, w, h, states) do
    s = surface(st, key)
    {:toplevel, top} = s.role
    emit(st, sock, top, "xdg_toplevel", :configure, [w, h, for(x <- states, into: <<>>, do: <<x::native-32>>)])
    emit(st, sock, s.xdg, "xdg_surface", :configure, [next_serial(st)])
    bump(st)
  end

  defp map_window(st, key, :toplevel) do
    s = surface(st, key)
    {cw, ch} = content_size(s)
    {fw, fh} = Render.frame_size(cw, ch)
    %{width: ow, height: oh} = st.output
    n = st.place
    x = max(div(ow - fw, 2) + rem(n, 8) * 32, 0)
    y = max(div(oh - fh, 2) + rem(n, 8) * 32, 0)
    win = %Win{key: key, kind: :toplevel, x: x, y: y}
    st = %{st | windows: st.windows ++ [win], place: n + 1}
    st |> focus(key) |> redecorate(key) |> damage_window(key)
  end

  defp map_window(st, key, :popup) do
    s = surface(st, key)
    {:popup, _, parent, pos} = s.role
    {cw, ch} = content_size(s)

    {x, y} =
      case window(st, {elem(key, 0), parent}) do
        nil ->
          {0, 0}

        pw ->
          {ox, oy} = content_origin(st, pw)
          {dx, dy} = popup_position(pos, cw, ch)
          {ox + dx, oy + dy}
      end

    win = %Win{key: key, kind: :popup, x: x, y: y, parent: parent}
    damage_window(%{st | windows: st.windows ++ [win]}, key)
  end

  defp popup_position(pos, w, h) do
    {rx, ry, rw, rh} = pos.anchor_rect

    ax = cond do
      pos.anchor in [3, 5, 6] -> rx
      pos.anchor in [4, 7, 8] -> rx + rw
      true -> rx + div(rw, 2)
    end

    ay = cond do
      pos.anchor in [1, 5, 7] -> ry
      pos.anchor in [2, 6, 8] -> ry + rh
      true -> ry + div(rh, 2)
    end

    x = cond do
      pos.gravity in [3, 5, 6] -> ax - w
      pos.gravity in [4, 7, 8] -> ax
      true -> ax - div(w, 2)
    end

    y = cond do
      pos.gravity in [1, 5, 7] -> ay - h
      pos.gravity in [2, 6, 8] -> ay
      true -> ay - div(h, 2)
    end

    {ox, oy} = pos.offset
    {x + ox, y + oy}
  end

  defp unmap(st, key) do
    case window(st, key) do
      nil ->
        st

      _w ->
        st = damage_window(st, key)
        st = %{st | windows: Enum.reject(st.windows, &(&1.key == key or (&1.kind == :popup and {elem(&1.key, 0), &1.parent} == key)))}
        st = if match?({:move, ^key, _, _}, st.grab) or match?({:resize, ^key, _, _}, st.grab), do: %{st | grab: nil}, else: st
        st = if st.pointer_focus == key, do: %{st | pointer_focus: nil}, else: st

        if st.keyboard_focus == key do
          next = st.windows |> Enum.filter(&(&1.kind == :toplevel)) |> List.last()
          %{st | keyboard_focus: nil} |> focus(next && next.key)
        else
          st
        end
    end
  end

  defp content_size(%Surface{geometry: {_, _, gw, gh}, w: w, h: h}) when gw > 0 and gh > 0, do: {min(gw, w), min(gh, h)}
  defp content_size(%Surface{w: w, h: h}), do: {w, h}

  defp content_origin(_st, %Win{kind: :popup, x: x, y: y}), do: {x, y}
  defp content_origin(_st, %Win{x: x, y: y}), do: Render.content_origin(x, y)

  # -- focus and decorations ----------------------------------------------------------------

  defp focus(st, key) when key == st.keyboard_focus, do: st

  defp focus(st, key) do
    old = st.keyboard_focus
    st = %{st | keyboard_focus: key}

    st =
      case old && surface(st, old) do
        %Surface{} ->
          {sock, sid} = old
          for k <- keyboards(st, sock), do: emit(st, sock, k, "wl_keyboard", :leave, [next_serial(st), sid])
          # The border changes colour too.
          st |> bump() |> reconfigure(old) |> redecorate(old) |> damage_window(old)

        _ ->
          st
      end

    case key && surface(st, key) do
      %Surface{} ->
        {sock, sid} = key

        for k <- keyboards(st, sock) do
          emit(st, sock, k, "wl_keyboard", :enter, [next_serial(st), sid, ""])
          emit(st, sock, k, "wl_keyboard", :modifiers, [next_serial(st), st.mods, 0, st.locked, 0])
        end

        st = raise_window(st, key) |> raise_popups(key)
        st |> bump() |> reconfigure(key) |> redecorate(key) |> damage_window(key)

      _ ->
        st
    end
  end

  defp raise_window(st, key) do
    case window(st, key) do
      nil -> st
      win -> %{st | windows: List.delete(st.windows, win) ++ [win]}
    end
  end

  defp raise_popups(st, {sock, sid}) do
    {popups, rest} = Enum.split_with(st.windows, &(&1.kind == :popup and elem(&1.key, 0) == sock and &1.parent == sid))
    %{st | windows: rest ++ popups}
  end

  defp reconfigure(st, key) do
    case surface(st, key) do
      %Surface{role: {:toplevel, _}} ->
        w = window(st, key)
        states = if(key == st.keyboard_focus, do: [@activated], else: []) ++ if(w && w.maximized, do: [@maximized], else: [])
        configure(st, key, 0, 0, states)

      _ ->
        st
    end
  end

  defp redecorate(st, key) do
    case {window(st, key), surface(st, key)} do
      {%Win{kind: :toplevel} = w, %Surface{} = s} ->
        {cw, ch} = content_size(s)
        {fw, _} = Render.frame_size(cw, ch)
        rows = Render.title_rows(s.title || s.app_id || "", fw, key == st.keyboard_focus)
        st = put_window(st, %{w | title_rows: {fw, rows}})
        damage(st, {w.x, w.y, fw, Render.border() + Render.title_height()})

      _ ->
        st
    end
  end

  defp put_window(st, w), do: %{st | windows: Enum.map(st.windows, &if(&1.key == w.key, do: w, else: &1))}

  defp maximize(st, key, on?) do
    case window(st, key) do
      %Win{} = w ->
        %{width: ow, height: oh} = st.output
        {cw, ch} = content_size(surface(st, key))

        if on? do
          st = put_window(st, %{w | maximized: {w.x, w.y, cw, ch}, x: 0, y: 0})
          {bw, bh} = Render.frame_size(0, 0)
          configure(st, key, ow - bw, oh - bh, [@maximized, @activated]) |> damage_window(key)
        else
          case w.maximized do
            {x, y, pw, ph} ->
              st = damage_window(st, key) |> put_window(%{w | maximized: nil, x: x, y: y})
              configure(st, key, pw, ph, [@activated])

            nil ->
              st
          end
        end

      nil ->
        st
    end
  end

  # -- damage and painting -------------------------------------------------------------------

  defp damage(st, {x, y, w, h}) do
    %{width: ow, height: oh} = st.output
    x0 = max(x, 0)
    y0 = max(y, 0)
    x1 = min(x + w, ow)
    y1 = min(y + h, oh)
    if x1 > x0 and y1 > y0, do: schedule(%{st | damage: [{x0, y0, x1 - x0, y1 - y0} | st.damage]}), else: st
  end

  defp damage_window(st, key) do
    case {window(st, key), surface(st, key)} do
      {%Win{} = w, %Surface{} = s} -> damage(st, window_rect(w, s))
      _ -> st
    end
  end

  defp window_rect(%Win{kind: :popup, x: x, y: y}, s), do: Tuple.insert_at(Tuple.insert_at(content_size(s), 0, y), 0, x)

  defp window_rect(%Win{x: x, y: y}, s) do
    {cw, ch} = content_size(s)
    {fw, fh} = Render.frame_size(cw, ch)
    {x, y, fw, fh}
  end

  # Damage in surface coordinates, on screen.
  defp damage_content(st, key, {x, y, w, h}) do
    case {window(st, key), surface(st, key)} do
      {%Win{} = win, %Surface{} = s} ->
        {ox, oy} = content_origin(st, win)
        {gx, gy} = geometry_origin(s)
        damage(st, {ox + x - gx, oy + y - gy, w, h})

      _ ->
        st
    end
  end

  defp geometry_origin(%Surface{geometry: {gx, gy, _, _}}), do: {gx, gy}
  defp geometry_origin(_), do: {0, 0}

  defp schedule(%{repaint: nil} = st), do: %{st | repaint: Process.send_after(self(), :repaint, @frame_ms)}
  defp schedule(st), do: st

  defp repaint(st) do
    if st.repaint, do: Process.cancel_timer(st.repaint)
    layers = layers(st)
    cursor = cursor(st)

    rows = Enum.flat_map(merge(st.damage), &Render.compose(&1, st.background, layers, cursor))
    if rows != [], do: Output.write(st.output, rows)

    now = System.monotonic_time(:millisecond) - st.started
    st = Enum.reduce(st.frame_callbacks, st, fn {sock, cb}, st ->
      if Map.has_key?(st.clients, sock) and Map.has_key?(st.clients[sock].objects, cb) do
        emit(st, sock, cb, "wl_callback", :done, [band(now, 0xFFFFFFFF)])
        update_in(st.clients[sock].objects, &Map.delete(&1, cb)) |> tap(&emit(&1, sock, 1, "wl_display", :delete_id, [cb]))
      else
        st
      end
    end)

    %{st | damage: [], frame_callbacks: [], repaint: nil}
  end

  # Overlapping or touching rectangles become their bounding box.
  defp merge(rects) do
    Enum.reduce(rects, [], fn r, acc ->
      {overlapping, rest} = Enum.split_with(acc, &touch?(&1, r))
      [Enum.reduce(overlapping, r, &union/2) | rest]
    end)
    |> then(fn merged -> if length(merged) < length(rects), do: merge(merged), else: merged end)
  end

  defp touch?({x1, y1, w1, h1}, {x2, y2, w2, h2}), do: x1 <= x2 + w2 and x2 <= x1 + w1 and y1 <= y2 + h2 and y2 <= y1 + h1

  defp union({x1, y1, w1, h1}, {x2, y2, w2, h2}) do
    x = min(x1, x2)
    y = min(y1, y2)
    {x, y, max(x1 + w1, x2 + w2) - x, max(y1 + h1, y2 + h2) - y}
  end

  defp layers(st) do
    for w <- st.windows, s = surface(st, w.key), s != nil and s.content != nil do
      {cw, ch} = content_size(s)
      {gx, gy} = case s.geometry do
        {gx, gy, gw, gh} when gw > 0 and gh > 0 -> {min(max(gx, 0), s.w - cw), min(max(gy, 0), s.h - ch)}
        _ -> {0, 0}
      end

      content = s.content
      stride = s.w * 4
      row = fn r -> binary_part(content, (gy + r) * stride + gx * 4, cw * 4) end

      case w.kind do
        :popup ->
          %{x: w.x, y: w.y, w: cw, h: ch, row: row}

        :toplevel ->
          {fw, rows} = w.title_rows || {0, nil}
          {need, _} = Render.frame_size(cw, ch)
          rows = if fw == need and rows, do: rows, else: Render.title_rows(s.title || "", need, w.key == st.keyboard_focus)
          Render.frame_layer(w.x, w.y, cw, ch, rows, w.key == st.keyboard_focus, row)
      end
    end
  end

  defp cursor(st) do
    {x, y} = st.pointer
    {trunc(x), trunc(y)}
  end

  defp damage_cursor(st) do
    {x, y} = cursor(st)
    {w, h} = Render.cursor_size()
    damage(st, {x, y, w, h})
  end

  # -- input ---------------------------------------------------------------------------------

  defp handle_input({:motion, dx, dy}, st) do
    {x, y} = st.pointer
    move_pointer(st, x + dx, y + dy)
  end

  defp handle_input({:abs, fx, fy}, st) do
    {x, y} = st.pointer
    move_pointer(st, if(fx, do: fx * (st.output.width - 1), else: x), if(fy, do: fy * (st.output.height - 1), else: y))
  end

  defp handle_input({:button, code, pressed?}, st) do
    st = %{st | buttons: if(pressed?, do: MapSet.put(st.buttons, code), else: MapSet.delete(st.buttons, code))}
    if pressed?, do: press(st, code), else: release(st, code)
  end

  defp handle_input({:wheel, steps}, st) do
    case st.pointer_focus do
      {sock, _} ->
        for p <- pointers(st, sock) do
          emit(st, sock, p, "wl_pointer", :axis, [now(st), 0, steps * 10.0])
          pointer_frame(st, sock, p)
        end

        st

      nil ->
        st
    end
  end

  defp handle_input({:key, code, pressed?}, st), do: key(st, code, pressed?)
  defp handle_input(_event, st), do: st

  defp move_pointer(st, x, y) do
    x = x |> max(0) |> min(st.output.width - 1)
    y = y |> max(0) |> min(st.output.height - 1)
    st = damage_cursor(st)
    st = %{st | pointer: {x / 1, y / 1}} |> damage_cursor()

    case st.grab do
      {:move, key, dx, dy} ->
        case window(st, key) do
          nil -> %{st | grab: nil}
          w -> st |> damage_window(key) |> put_window(%{w | x: round(x - dx), y: round(y - dy)}) |> damage_window(key)
        end

      {:resize, key, {px, py}, {w0, h0}} ->
        w = max(round(w0 + x - px), 64)
        h = max(round(h0 + y - py), 32)
        configure(st, key, w, h, [@resizing, @activated])

      _ ->
        pointer_motion(st)
    end
  end

  # Which window, and which part of it, is at the pointer.
  defp under_pointer(st) do
    {px, py} = st.pointer

    st.windows
    |> Enum.reverse()
    |> Enum.find_value(fn w ->
      s = surface(st, w.key)
      {x, y, ww, wh} = window_rect(w, s)

      if px >= x and px < x + ww and py >= y and py < y + wh do
        part = if w.kind == :popup, do: :content, else: Render.frame_part(ww, wh, trunc(px - x), trunc(py - y))
        {ox, oy} = content_origin(st, w)
        {gx, gy} = geometry_origin(s)
        {w, part, {px - ox + gx, py - oy + gy}}
      end
    end)
  end

  defp pointer_motion(st) do
    # While a button is held, the client that got the press keeps the pointer.
    target =
      case {st.buttons != MapSet.new() and st.pointer_focus, under_pointer(st)} do
        {key, _} when is_tuple(key) -> {key, local(st, key)}
        {_, {w, :content, pos}} -> {w.key, pos}
        _ -> nil
      end

    case target do
      nil ->
        leave_pointer(st)

      {key, {sx, sy}} ->
        st = if st.pointer_focus != key, do: st |> leave_pointer() |> enter_pointer(key, sx, sy), else: st
        {sock, _} = key

        for p <- pointers(st, sock) do
          emit(st, sock, p, "wl_pointer", :motion, [now(st), sx, sy])
          pointer_frame(st, sock, p)
        end

        st
    end
  end

  defp local(st, key) do
    case window(st, key) do
      nil ->
        {0.0, 0.0}

      w ->
        {px, py} = st.pointer
        {ox, oy} = content_origin(st, w)
        {gx, gy} = geometry_origin(surface(st, key))
        {px - ox + gx, py - oy + gy}
    end
  end

  defp enter_pointer(st, {sock, sid} = key, sx, sy) do
    for p <- pointers(st, sock) do
      emit(st, sock, p, "wl_pointer", :enter, [next_serial(st), sid, sx, sy])
      pointer_frame(st, sock, p)
    end

    %{bump(st) | pointer_focus: key}
  end

  defp leave_pointer(%{pointer_focus: nil} = st), do: st

  defp leave_pointer(%{pointer_focus: {sock, sid}} = st) do
    if surface(st, {sock, sid}) do
      for p <- pointers(st, sock) do
        emit(st, sock, p, "wl_pointer", :leave, [next_serial(st), sid])
        pointer_frame(st, sock, p)
      end
    end

    %{bump(st) | pointer_focus: nil}
  end

  defp pointer_frame(st, sock, p) do
    if st.clients[sock].objects[p].version >= 5, do: emit(st, sock, p, "wl_pointer", :frame, [])
  end

  @btn_left 0x110
  @btn_right 0x111

  defp press(st, code) do
    alt? = band(st.mods, Keymap.alt()) != 0

    case under_pointer(st) do
      nil ->
        dismiss_popups(st, nil)

      {w, part, _pos} ->
        st = dismiss_popups(st, w)
        st = if w.kind == :toplevel, do: focus(st, w.key), else: st

        cond do
          alt? and code == @btn_left and w.kind == :toplevel -> start_move(st, w)
          alt? and code == @btn_right and w.kind == :toplevel -> start_resize(st, w.key)
          part == :title and code == @btn_left -> start_move(st, w)
          part == :corner and code == @btn_left -> start_resize(st, w.key)
          part == :close and code == @btn_left -> close(st, w.key)
          part == :content -> st |> pointer_motion() |> send_button(code, 1)
          true -> st
        end
    end
  end

  defp release(st, code) do
    case st.grab do
      {:resize, key, _, _} ->
        st = %{st | grab: nil}
        if MapSet.size(st.buttons) == 0, do: reconfigure(st, key), else: st

      {:move, _, _, _} ->
        %{st | grab: nil}

      nil ->
        st = send_button(st, code, 0)
        if MapSet.size(st.buttons) == 0, do: pointer_motion(st), else: st
    end
  end

  defp send_button(st, code, state) do
    case st.pointer_focus do
      {sock, _} ->
        for p <- pointers(st, sock) do
          emit(st, sock, p, "wl_pointer", :button, [next_serial(st), now(st), code, state])
          pointer_frame(st, sock, p)
        end

        bump(st)

      nil ->
        st
    end
  end

  defp start_move(st, w) do
    {px, py} = st.pointer
    %{st | grab: {:move, w.key, px - w.x, py - w.y}}
  end

  defp start_resize(st, key) do
    case surface(st, key) do
      %Surface{role: {:toplevel, _}} = s -> %{st | grab: {:resize, key, st.pointer, content_size(s)}}
      _ -> st
    end
  end

  defp close(st, {sock, _} = key) do
    case surface(st, key) do
      %Surface{role: {:toplevel, top}} -> emit(st, sock, top, "xdg_toplevel", :close, [])
      _ -> :ok
    end

    st
  end

  defp dismiss_popups(st, clicked) do
    {popups, _} = Enum.split_with(st.windows, &(&1.kind == :popup))

    Enum.reduce(popups, st, fn p, st ->
      if clicked && (p.key == clicked.key or elem(p.key, 0) == elem(clicked.key, 0)) do
        st
      else
        case surface(st, p.key) do
          %Surface{role: {:popup, id, _, _}} ->
            emit(st, elem(p.key, 0), id, "xdg_popup", :popup_done, [])
            unmap(st, p.key)

          _ ->
            st
        end
      end
    end)
  end

  @key_backspace 14
  @key_tab 15
  @key_return 28
  @key_f4 62

  defp key(st, code, pressed?) do
    st =
      case Keymap.modifier(code) do
        nil when code == 58 and pressed? -> %{st | locked: bxor(st.locked, Keymap.caps())}
        nil -> st
        bit -> %{st | mods: if(pressed?, do: bor(st.mods, bit), else: band(st.mods, bnot(bit)))}
      end

    alt? = band(st.mods, Keymap.alt() ||| Keymap.super()) != 0
    ctrl? = band(st.mods, Keymap.ctrl()) != 0

    binding =
      cond do
        not pressed? -> nil
        ctrl? and band(st.mods, Keymap.alt()) != 0 and code == @key_backspace -> :quit
        alt? and code == @key_return -> :terminal
        alt? and code == @key_tab -> :next
        alt? and code == @key_f4 -> :close
        true -> nil
      end

    cond do
      binding != nil ->
        %{st | bound_keys: MapSet.put(st.bound_keys, code)} |> run_binding(binding)

      not pressed? and MapSet.member?(st.bound_keys, code) ->
        %{st | bound_keys: MapSet.delete(st.bound_keys, code)}

      true ->
        send_key(st, code, pressed?)
    end
  end

  defp run_binding(st, :quit) do
    send(self(), :quit)
    if st.owner, do: send(st.owner, {:photon_quit, self()})
    st
  end

  defp run_binding(st, :terminal) do
    # The new client talks to us: start it from another process.
    if st.spawn, do: spawn(st.spawn)
    st
  end

  defp run_binding(st, :next) do
    case Enum.filter(st.windows, &(&1.kind == :toplevel)) do
      [first | _] when length(st.windows) > 1 -> focus(st, first.key)
      _ -> st
    end
  end

  defp run_binding(st, :close), do: if(st.keyboard_focus, do: close(st, st.keyboard_focus), else: st)

  defp send_key(st, code, pressed?) do
    case st.keyboard_focus do
      {sock, _} ->
        for k <- keyboards(st, sock) do
          emit(st, sock, k, "wl_keyboard", :key, [next_serial(st), now(st), code, if(pressed?, do: 1, else: 0)])
          if Keymap.modifier(code) || code == 58, do: emit(st, sock, k, "wl_keyboard", :modifiers, [next_serial(st), st.mods, 0, st.locked, 0])
        end

        bump(st)

      nil ->
        st
    end
  end

  defp pointers(st, sock), do: objects_of(st, sock, "wl_pointer")
  defp keyboards(st, sock), do: objects_of(st, sock, "wl_keyboard")

  defp objects_of(st, sock, iface) do
    case st.clients[sock] do
      nil -> []
      c -> for {id, %{iface: ^iface}} <- c.objects, do: id
    end
  end

  defp now(st), do: band(System.monotonic_time(:millisecond) - st.started, 0xFFFFFFFF)
  defp next_serial(st), do: st.serial + 1
  defp bump(st), do: %{st | serial: st.serial + 1}

  # -- clients ---------------------------------------------------------------------------------

  defp emit(st, sock, id, iface, event, args) do
    {op, types} = Protocol.event_op(iface, event)
    {data, fds} = Wire.encode(id, op, types, args)

    if Map.has_key?(st.clients, sock) do
      case Conn.send_data(sock, data, fds) do
        :ok -> :ok
        {:error, _} -> send(self(), {:wl_closed, sock})
      end
    end

    st
  end

  defp protocol_error(st, sock, id, code, message) do
    Logger.debug("photon: protocol error: #{message}")
    emit(st, sock, 1, "wl_display", :error, [id, code, message])
    disconnect(st, sock)
  end

  defp disconnect(st, sock) do
    case st.clients[sock] do
      nil ->
        st

      c ->
        st = Enum.reduce(st.windows, st, fn w, st -> if elem(w.key, 0) == sock, do: unmap(st, w.key), else: st end)
        for {_, %{file: f}} <- c.pools, do: :file.close(f)
        :socket.close(sock)
        st = %{st | clients: Map.delete(st.clients, sock), frame_callbacks: Enum.reject(st.frame_callbacks, &(elem(&1, 0) == sock))}
        st = if match?({^sock, _}, st.pointer_focus), do: %{st | pointer_focus: nil}, else: st
        if match?({^sock, _}, st.keyboard_focus), do: %{st | keyboard_focus: nil}, else: st
    end
  end
end
