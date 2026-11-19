defmodule Lepton.Photon.Term do
  @moduledoc """
  A terminal window: a Wayland client that runs `lsh` (or a command) on a
  Lepton TTY, interprets its output with `Lepton.Screen` (the
  multiplexer's VT100/xterm emulator) and draws the cells with the
  Terminus bitmap font into a `wl_shm` buffer.

  Only rows that changed are redrawn and damaged. Keys arrive as Linux key
  codes and are turned into terminal input through the US keymap
  (`Lepton.Wayland.Keymap`), with key repeat done here as the protocol
  expects. The window resizes in whole cells. Closing the window ends the
  shell; the shell exiting closes the window.
  """

  use GenServer, restart: :temporary

  import Bitwise

  alias Lepton.{Screen, TTY}
  alias Lepton.Wayland.{Client, Font, Keymap}

  @cw 8
  @ch 16
  # margin around the text, in pixels
  @pad 4

  # Characters the font lacks that prompts and tools like, drawn as the nearest it has.
  @fallback %{0x276F => ?>, 0x276E => ?<, 0x2714 => 0x221A, 0x2713 => 0x221A, 0x2718 => ?x, 0x2717 => ?x, 0x26A1 => ?!, 0x2026 => ?., 0x23F5 => ?>}

  # Monokai
  @palette ~w(272822 f92672 a6e22e f4bf75 66d9ef ae81ff a1efe4 f8f8f2 75715e f92672 a6e22e f4bf75 66d9ef ae81ff a1efe4 f9f8f5)
  @fg "f8f8f2"
  @bg "272822"
  @default {28, 96}
  @repeat_delay 400
  @repeat_rate 33

  defmodule Backend do
    @moduledoc false
    # TTY backend: output goes to the terminal window.
    def open({term, size}, _tty), do: {:ok, {term, size}}
    def size({_term, size}), do: size
    def write({term, _}, data), do: send(term, {:term_output, data})
  end

  @doc """
  Open a terminal window. Options: `:env` (needs `WAYLAND_DISPLAY` and
  `XDG_RUNTIME_DIR`), `:user`, `:cwd`, `:command` (default: an
  interactive shell), `:size` (`{rows, cols}`).
  """
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    env = Keyword.fetch!(opts, :env)

    case Client.connect(Lepton.Wayland.Conn.socket_path(env)) do
      {:ok, c} -> {:ok, setup(c, opts)}
      {:error, reason} -> {:stop, {:connect, reason}}
    end
  end

  defp setup(c, opts) do
    env = opts[:env]
    {c, globals} = Client.registry(c)
    {c, compositor} = Client.bind(c, "wl_compositor", 4)
    # lepton_shm where Photon offers it: pools by path, no descriptors to leak.
    {c, shm} = if Map.has_key?(globals, "lepton_shm"), do: Client.bind(c, "lepton_shm", 1), else: Client.bind(c, "wl_shm", 1)
    {c, wm} = Client.bind(c, "xdg_wm_base", 1)
    {c, seat} = if Map.has_key?(globals, "wl_seat"), do: Client.bind(c, "wl_seat", 5), else: {c, nil}
    {c, surface} = Client.create(c, compositor, :create_surface, "wl_surface")
    {c, xdg} = Client.create(c, wm, :get_xdg_surface, "xdg_surface", [:new, surface])
    {c, top} = Client.create(c, xdg, :get_toplevel, "xdg_toplevel")
    title = opts[:title] || "#{opts[:user] || "root"}@#{Lepton.Sys.hostname()}"
    c = c |> Client.request(top, :set_title, [title]) |> Client.request(top, :set_app_id, ["lepton.term"])
    c = Client.request(c, surface, :commit, [])

    {rows, cols} = opts[:size] || @default
    {:ok, tty} = TTY.start(backend: {Backend, {self(), {rows, cols}}}, name: "photon term", term: "xterm-256color")

    %{
      c: c,
      env: env,
      opts: opts,
      ids: %{compositor: compositor, shm: shm, wm: wm, seat: seat, surface: surface, xdg: xdg, top: top, keyboard: nil, pointer: nil},
      title: title,
      tty: tty,
      shell: nil,
      screen: Screen.new(rows, cols, history_limit: 0),
      rows: rows,
      cols: cols,
      pending_size: nil,
      buffer: nil,
      busy: false,
      waiting_frame: false,
      drawn: %{},
      mods: 0,
      repeat: nil,
      dir: env["XDG_RUNTIME_DIR"] || System.tmp_dir!(),
      cache: %{}
    }
  end

  # -- events ------------------------------------------------------------------------------

  @impl true
  def handle_info({:wl_data, sock, data, fds}, %{c: %{sock: sock}} = st) do
    {events, c} = Client.handle_data(st.c, data, fds)
    st = Enum.reduce(events, %{st | c: c}, &event/2)
    {:noreply, maybe_draw(st)}
  end

  def handle_info({:wl_closed, _}, st), do: {:stop, :normal, st}

  def handle_info({:term_output, data}, st) do
    {:noreply, maybe_draw(%{st | screen: Screen.feed(st.screen, data)})}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %{shell: {_, pid}} = st), do: {:stop, :normal, st}

  def handle_info({:repeat, code}, %{repeat: {code, _}} = st) do
    st = type_key(st, code)
    {:noreply, %{st | repeat: {code, Process.send_after(self(), {:repeat, code}, @repeat_rate)}}}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    if st.shell, do: Process.exit(elem(st.shell, 1), :kill)
    Client.close(st.c)
    :ok
  end

  defp event({_, "xdg_toplevel", :configure, [w, h, _states]}, st) do
    size = if w > 0 and h > 0, do: {max(div(h - 2 * @pad, @ch), 2), max(div(w - 2 * @pad, @cw), 10)}, else: nil
    %{st | pending_size: size}
  end

  defp event({_, "xdg_toplevel", :close, []}, st) do
    send(self(), {:wl_closed, st.c.sock})
    st
  end

  defp event({_, "xdg_surface", :configure, [serial]}, st) do
    st = %{st | c: Client.request(st.c, st.ids.xdg, :ack_configure, [serial])}
    st = if st.pending_size && st.pending_size != {st.rows, st.cols}, do: resize(st, st.pending_size), else: st
    st = %{st | pending_size: nil}
    if st.shell == nil, do: start_shell(st), else: st
  end

  defp event({_, "wl_seat", :capabilities, [caps]}, st) do
    st = if band(caps, 2) != 0 and st.ids.keyboard == nil, do: create_input(st, :get_keyboard, "wl_keyboard", :keyboard), else: st
    if band(caps, 1) != 0 and st.ids.pointer == nil, do: create_input(st, :get_pointer, "wl_pointer", :pointer), else: st
  end

  defp event({_, "wl_keyboard", :modifiers, [_serial, depressed, latched, locked, _group]}, st), do: %{st | mods: depressed ||| latched ||| locked}

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, 1]}, st) do
    st = cancel_repeat(st)
    st = type_key(st, code)
    if Keymap.modifier(code) == nil and code != Keymap.capslock(), do: %{st | repeat: {code, Process.send_after(self(), {:repeat, code}, @repeat_delay)}}, else: st
  end

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, 0]}, st) do
    if match?({^code, _}, st.repeat), do: cancel_repeat(st), else: st
  end

  defp event({_, "wl_keyboard", :leave, _}, st), do: cancel_repeat(st)

  defp event({_, "wl_callback", :done, _}, st), do: %{st | waiting_frame: false}
  defp event({id, "wl_buffer", :release, _}, %{buffer: %{id: id}} = st), do: %{st | busy: false}
  defp event(_event, st), do: st

  defp create_input(st, req, iface, key) do
    {c, id} = Client.create(st.c, st.ids.seat, req, iface)
    %{st | c: c, ids: Map.put(st.ids, key, id)}
  end

  defp cancel_repeat(%{repeat: {_, ref}} = st) do
    Process.cancel_timer(ref)
    %{st | repeat: nil}
  end

  defp cancel_repeat(st), do: st

  @key_v 47

  # Ctrl+Shift+V pastes the clipboard (what Firefox copied too; newlines as
  # Return, as a terminal types them).
  defp type_key(st, @key_v) when band(st.mods, 5) == 5 do
    TTY.input(st.tty, String.replace(Lepton.Clipboard.get(), "\n", "\r"))
    st
  end

  defp type_key(st, code) do
    case Keymap.key_name(code, st.mods) do
      nil -> st
      key ->
        TTY.input(st.tty, Lepton.Keys.encode(key))
        st
    end
  end

  # -- the shell -----------------------------------------------------------------------------

  defp start_shell(st) do
    {rows, cols} = {st.rows, st.cols}

    env =
      st.env
      |> Map.put("TERM", "xterm-256color")
      |> Map.put("COLUMNS", to_string(cols))
      |> Map.put("LINES", to_string(rows))
      |> Map.put("LEPTON_OUTER_TERM", "xterm-256color")

    tty = st.tty
    user = st.opts[:user] || "root"
    cwd = st.opts[:cwd] || env["HOME"] || "/"
    ctx = %Lepton.Ctx{cwd: cwd, env: env, stdin: tty, stdout: tty, stderr: tty, tty: tty, user: user}
    command = st.opts[:command]

    {_lpid, proc, _ref} =
      Lepton.Proc.spawn(command || "lsh", [tty: tty, monitor: true], fn pid ->
        ctx = %{ctx | pid: pid}

        if command,
          do: Lepton.Shell.run_string(command, cwd: cwd, env: env, stdin: tty, stdout: tty, stderr: tty, tty: tty, rc: true, user: user),
          else: Lepton.Shell.interactive(ctx)
      end)

    %{st | shell: {nil, proc}}
  end

  # -- drawing -------------------------------------------------------------------------------

  defp resize(st, {rows, cols}) do
    TTY.set_size(st.tty, {rows, cols})
    %{st | rows: rows, cols: cols, screen: Screen.resize(st.screen, rows, cols), buffer: free_buffer(st), busy: false, drawn: %{}}
  end

  defp free_buffer(%{buffer: nil}), do: nil

  defp free_buffer(%{buffer: b} = st) do
    Client.request(st.c, b.id, :destroy, [])
    Client.request(st.c, b.pool, :destroy, [])
    :file.close(b.file)
    nil
  end

  defp maybe_draw(%{shell: nil} = st), do: st
  defp maybe_draw(%{waiting_frame: true} = st), do: st
  defp maybe_draw(%{busy: true} = st), do: st
  defp maybe_draw(st), do: draw(st)

  defp draw(st) do
    st = ensure_buffer(st)
    %{rows: rows, cols: cols, screen: screen} = st
    cursor = if screen.cursor_visible, do: {screen.x, screen.y}

    {changed, drawn, cache} =
      Enum.reduce(0..(rows - 1), {[], st.drawn, st.cache}, fn y, {changed, drawn, cache} ->
        cells = for x <- 0..(cols - 1), do: cell(screen, x, y, cursor)

        if drawn[y] == cells do
          {changed, drawn, cache}
        else
          {pixels, cache} = render_row(cells, cache)
          {[{y, pixels} | changed], Map.put(drawn, y, cells), cache}
        end
      end)

    cache = if map_size(cache) > 4096, do: %{}, else: cache
    st = %{st | drawn: drawn, cache: cache}
    if changed == [], do: st, else: present(st, changed)
  end

  defp cell(screen, x, y, cursor) do
    {g, sgr} = Screen.cell(screen, x, y)
    if cursor == {x, y}, do: {g, sgr, :cursor}, else: {g, sgr}
  end

  defp present(st, changed) do
    b = st.buffer
    width = st.cols * @cw
    stride = (width + 2 * @pad) * 4

    writes =
      for {y, px} <- changed, r <- 0..(@ch - 1),
          do: {(@pad + y * @ch + r) * stride + @pad * 4, binary_part(px, r * width * 4, width * 4)}

    :ok = :file.pwrite(b.file, writes)
    c = Enum.reduce(changed, st.c, fn {y, _}, c -> Client.request(c, st.ids.surface, :damage_buffer, [@pad, @pad + y * @ch, width, @ch]) end)
    c = Client.request(c, st.ids.surface, :attach, [b.id, 0, 0])
    {c, _cb} = Client.create(c, st.ids.surface, :frame, "wl_callback")
    c = Client.request(c, st.ids.surface, :commit, [])
    maybe_retitle(%{st | c: c, busy: true, waiting_frame: true})
  end

  defp maybe_retitle(%{screen: %{title: t}} = st) when is_binary(t) and t != "" and t != st.title do
    %{st | title: t, c: Client.request(st.c, st.ids.top, :set_title, [t])}
  end

  defp maybe_retitle(st), do: st

  defp ensure_buffer(%{buffer: nil} = st) do
    w = st.cols * @cw + 2 * @pad
    h = st.rows * @ch + 2 * @pad
    size = w * h * 4
    {c, pool, file} = Client.shm_pool(st.c, st.ids.shm, size, st.dir)
    # The margin is the background colour; the text is drawn inside it.
    :ok = :file.pwrite(file, 0, :binary.copy(hex(@bg), w * h))
    {c, id} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, w, h, w * 4, 1])
    %{st | c: c, buffer: %{id: id, pool: pool, file: file}, drawn: %{}}
  end

  defp ensure_buffer(st), do: st

  # 16 pixel rows for a row of cells.
  defp render_row(cells, cache) do
    {glyphs, cache} =
      Enum.map_reduce(cells, cache, fn cell, cache ->
        case cache do
          %{^cell => rows} ->
            {rows, cache}

          _ ->
            rows = glyph(cell)
            {rows, Map.put(cache, cell, rows)}
        end
      end)

    pixels = for r <- 0..(@ch - 1), do: Enum.map(glyphs, &elem(&1, r))
    {IO.iodata_to_binary(pixels), cache}
  end

  defp glyph(cell) do
    {g, sgr, cursor?} =
      case cell do
        {g, sgr, :cursor} -> {g, sgr, true}
        {g, sgr} -> {g, sgr, false}
      end

    {fg, bg, bold?} = colors(sgr)
    {fg, bg} = if cursor?, do: {bg, fg}, else: {fg, bg}
    cp = g |> String.to_charlist() |> List.first() || ?\s
    cp = if Font.has?(cp), do: cp, else: Map.get(@fallback, cp, ??)
    List.to_tuple(Font.rows(cp, fg, bg, bold?))
  end

  # -- colours (Monokai) -------------------------------------------------------------------------


  defp hex(h), do: h |> Base.decode16!(case: :lower) |> then(fn <<r, g, b>> -> <<b, g, r, 255>> end)

  @doc false
  def colors(sgr) do
    {fg, bg, bold, rev} =
      sgr
      |> String.split(";", trim: true)
      |> Enum.map(&Integer.parse/1)
      |> Enum.flat_map(fn {n, _} -> [n]; :error -> [] end)
      |> sgr_params({nil, nil, false, false})

    fg = fg || hex(@fg)
    bg = bg || hex(@bg)
    {fg, bg} = if rev, do: {bg, fg}, else: {fg, bg}
    {fg, bg, bold}
  end

  defp sgr_params([], acc), do: acc
  defp sgr_params([0 | rest], _), do: sgr_params(rest, {nil, nil, false, false})
  defp sgr_params([1 | rest], {f, b, _, r}), do: sgr_params(rest, {f, b, true, r})
  defp sgr_params([7 | rest], {f, b, bo, _}), do: sgr_params(rest, {f, b, bo, true})
  defp sgr_params([22 | rest], {f, b, _, r}), do: sgr_params(rest, {f, b, false, r})
  defp sgr_params([27 | rest], {f, b, bo, _}), do: sgr_params(rest, {f, b, bo, false})
  defp sgr_params([n | rest], {_, b, bo, r}) when n in 30..37, do: sgr_params(rest, {indexed(n - 30), b, bo, r})
  defp sgr_params([n | rest], {_, b, bo, r}) when n in 90..97, do: sgr_params(rest, {indexed(n - 90 + 8), b, bo, r})
  defp sgr_params([n | rest], {f, _, bo, r}) when n in 40..47, do: sgr_params(rest, {f, indexed(n - 40), bo, r})
  defp sgr_params([n | rest], {f, _, bo, r}) when n in 100..107, do: sgr_params(rest, {f, indexed(n - 100 + 8), bo, r})
  defp sgr_params([39 | rest], {_, b, bo, r}), do: sgr_params(rest, {nil, b, bo, r})
  defp sgr_params([49 | rest], {f, _, bo, r}), do: sgr_params(rest, {f, nil, bo, r})
  defp sgr_params([38, 5, n | rest], {_, b, bo, r}), do: sgr_params(rest, {indexed(n), b, bo, r})
  defp sgr_params([48, 5, n | rest], {f, _, bo, r}), do: sgr_params(rest, {f, indexed(n), bo, r})
  defp sgr_params([38, 2, rr, g, bb | rest], {_, b, bo, r}), do: sgr_params(rest, {<<bb, g, rr, 255>>, b, bo, r})
  defp sgr_params([48, 2, rr, g, bb | rest], {f, _, bo, r}), do: sgr_params(rest, {f, <<bb, g, rr, 255>>, bo, r})
  defp sgr_params([_ | rest], acc), do: sgr_params(rest, acc)

  @doc false
  def indexed(n) when n in 0..15, do: hex(Enum.at(@palette, n))

  def indexed(n) when n in 16..231 do
    i = n - 16
    level = fn v -> if v == 0, do: 0, else: 55 + v * 40 end
    <<level.(rem(i, 6)), level.(rem(div(i, 6), 6)), level.(div(i, 36)), 255>>
  end

  def indexed(n) when n in 232..255 do
    v = 8 + (n - 232) * 10
    <<v, v, v, 255>>
  end

  def indexed(_), do: hex(@fg)
end
