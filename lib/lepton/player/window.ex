defmodule Lepton.Player.Window do
  @moduledoc """
  The media player's window: a Wayland client (as the Passwords window,
  `Lepton.Vault.App`, is) showing a video with a bar under it (title,
  position, a progress line to click).

  The pictures come from an ffmpeg of its own (`Lepton.FFmpeg.video_args/4`),
  scaled to the window as `bgr0` frames: the bytes `wl_shm`'s XRGB8888
  wants, written into the buffer as they come. A frame that arrives while
  the compositor still holds the last one replaces any waiting: the
  newest is drawn, so a slow machine drops frames rather than falls
  behind. The `Lepton.Player` that opened it says when to start and stop
  (`{:start_video, url, seconds, live}`, `:stop_video`) and sends its
  status for the bar; keys and clicks go back to it.

  In a virtual machine the picture is at most 768x672, black around it in
  a bigger window or full screen, and only it (and the bar) is redrawn:
  UTM's display stopped showing a bigger moving picture (see
  `Lepton.SNES.Window`). Each picture goes once the compositor has shown
  the last (its frame callback).

  Keys: Space (or a click on the picture) pauses, Left/Right seek 5
  seconds, Up/Down a minute, `9`/`0` (or `-`/`+`) the volume, `m` mutes,
  `f` (or a double click) fills the screen, `q` or Esc closes.
  """

  use GenServer, restart: :temporary

  import Bitwise

  alias Lepton.{FFmpeg, Player, Sound}
  alias Lepton.Photon.Canvas
  alias Lepton.Wayland.{Client, Keymap}

  @bar 30
  @vm_picture {768, 672}
  @bg <<0x2B, 0x2B, 0x2B, 0xFF>>
  @fg <<0xEE, 0xEE, 0xEE, 0xFF>>
  @dim <<0x99, 0x99, 0x99, 0xFF>>
  @track <<0x55, 0x55, 0x55, 0xFF>>
  @done <<0x00, 0x99, 0xFF, 0xFF>>
  @max {960, 540}

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "The size it opens at for a video of `vw`x`vh`: fitted in 960x540, plus the bar."
  def initial_size(nil), do: {640, 360 + @bar}

  def initial_size(%{w: vw, h: vh}) when is_integer(vw) and is_integer(vh) and vw > 0 and vh > 0 do
    {mw, mh} = @max
    scale = Enum.min([mw / vw, mh / vh, 1.0])
    {max(even(vw * scale), 160), max(even(vh * scale), 90) + @bar}
  end

  def initial_size(_), do: initial_size(nil)

  defp even(x), do: trunc(x / 2) * 2

  @impl true
  def init(opts) do
    env = opts[:env] || %{}

    case Client.connect(Lepton.Wayland.Conn.socket_path(env)) do
      {:ok, c} -> {:ok, setup(c, opts)}
      {:error, reason} -> {:stop, {:connect, reason}}
    end
  end

  defp setup(c, opts) do
    env = opts[:env] || %{}
    {c, globals} = Client.registry(c)
    {c, compositor} = Client.bind(c, "wl_compositor", 4)
    {c, shm} = if Map.has_key?(globals, "lepton_shm"), do: Client.bind(c, "lepton_shm", 1), else: Client.bind(c, "wl_shm", 1)
    {c, wm} = Client.bind(c, "xdg_wm_base", 1)
    {c, seat} = if Map.has_key?(globals, "wl_seat"), do: Client.bind(c, "wl_seat", 5), else: {c, nil}
    {c, surface} = Client.create(c, compositor, :create_surface, "wl_surface")
    {c, xdg} = Client.create(c, wm, :get_xdg_surface, "xdg_surface", [:new, surface])
    {c, top} = Client.create(c, xdg, :get_toplevel, "xdg_toplevel")
    c = c |> Client.request(top, :set_title, [opts[:title] || "Media Player"]) |> Client.request(top, :set_app_id, ["lepton.player"])
    c = Client.request(c, surface, :commit, [])
    {w, h} = initial_size(opts[:video])
    :timer.send_interval(500, :tick)

    %{
      c: c,
      ids: %{shm: shm, wm: wm, seat: seat, surface: surface, xdg: xdg, top: top, keyboard: nil, pointer: nil},
      player: opts[:player],
      w: w,
      h: h,
      configured: false,
      pending_size: nil,
      buffer: nil,
      busy: false,
      dirty: true,
      frame: nil,
      buf: <<>>,
      port: nil,
      video: nil,
      status: %{state: :paused, position: 0.0, duration: nil, title: opts[:title] || "", now_playing: nil, error: nil, live: false},
      mods: 0,
      group: 0,
      pointer: {0, 0},
      last_click: nil,
      fullscreen: false,
      cap: Keyword.get_lazy(opts, :max_picture, fn -> if Lepton.Sys.qemu?(), do: @vm_picture end),
      cleared: false,
      shown: nil,
      last_bar: nil,
      dims: (case opts[:video] do
        %{w: vw, h: vh} when is_integer(vw) and is_integer(vh) and vw > 0 and vh > 0 -> {vw, vh}
        _ -> nil
      end),
      dir: env["XDG_RUNTIME_DIR"] || System.tmp_dir!(),
      user: opts[:user],
      log: Path.join([env["HOME"] || "/root", ".cache", "lepton", "ffmpeg.log"])
    }
  end

  # -- messages ------------------------------------------------------------------------------

  @impl true
  def handle_info({:wl_data, sock, data, fds}, %{c: %{sock: sock}} = st) do
    {events, c} = Client.handle_data(st.c, data, fds)
    {:noreply, Enum.reduce(events, %{st | c: c}, &event/2) |> draw()}
  end

  def handle_info({:wl_closed, _}, st), do: close(st)

  def handle_info({:player, _pid, status}, st), do: {:noreply, draw(%{st | status: status, dirty: true})}

  def handle_info({:start_video, url, start, live}, st), do: {:noreply, st |> stop_video() |> start_video(url, start, live)}
  def handle_info(:stop_video, st), do: {:noreply, stop_video(st)}

  # Frames: whole ones are taken; only the newest is kept for drawing.
  def handle_info({port, {:data, data}}, %{port: port} = st) do
    size = frame_size(st)
    buf = st.buf <> data
    n = div(byte_size(buf), size)

    if n == 0 do
      {:noreply, %{st | buf: buf}}
    else
      frame = binary_part(buf, (n - 1) * size, size)
      rest = binary_part(buf, n * size, byte_size(buf) - n * size)
      {:noreply, draw(%{st | buf: rest, frame: frame, dirty: true})}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = st), do: {:noreply, %{st | port: nil}}

  def handle_info(:tick, st), do: {:noreply, draw(%{st | dirty: true})}
  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    stop_video(st)
    Client.close(st.c)
    :ok
  end

  defp close(st) do
    if st.player, do: send(st.player, {:window_closed, self()})
    {:stop, :normal, st}
  end

  # -- video ---------------------------------------------------------------------------------

  defp video_size(st), do: {st.w, max(st.h - @bar, 2)}
  defp frame_size(st), do: (fn {_, _, w, h} -> w * h * 4 end).(box(st))
  defp box(st), do: (fn {w, h} -> box(w, h, st.cap, st.dims) end).(video_size(st))

  @doc """
  Where the pictures go in a `w` by `h` video area: `{x, y, w, h}`, all of
  it, or (`cap`, in a virtual machine) at most that big, in the middle,
  and then (`dims`, the video's size) just the video's shape: the black
  above and below a wide video isn't redrawn with every picture.
  """
  def box(w, h, cap, dims \\ nil)
  def box(w, h, nil, _dims), do: {0, 0, w, h}

  def box(w, h, {cw, ch}, dims) do
    {bw, bh} = {min(w, cw), min(h, ch)}

    {bw, bh} =
      case dims do
        {vw, vh} -> if bw * vh <= bh * vw, do: {bw, div(bw * vh, vw)}, else: {div(bh * vw, vh), bh}
        nil -> {bw, bh}
      end

    {bw, bh} = {max(even(bw), 2), max(even(bh), 2)}
    {div(w - bw, 2), div(h - bh, 2), bw, bh}
  end

  defp start_video(st, url, start, live) do
    {_, _, w, h} = box(st)
    Lepton.Users.own_new_in_home(Path.dirname(st.log), fn -> File.mkdir_p(Path.dirname(st.log)) end)
    port = FFmpeg.open("ffmpeg", FFmpeg.video_args(url, w, h, start: start, live: live), log: st.log, user: st.user)
    %{st | port: port, buf: <<>>, video: {url, live}}
  end

  defp stop_video(%{port: nil} = st), do: st

  defp stop_video(st) do
    port = st.port
    Port.close(port)
    flush(port)
    %{st | port: nil, buf: <<>>}
  catch
    _, _ -> %{st | port: nil, buf: <<>>}
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  # A new size: the pictures again, at the new size, from where it is.
  defp resized(st) do
    st = %{st | frame: nil, buffer: free_buffer(st), busy: false, dirty: true, cleared: false, shown: nil}

    case {st.port, st.video} do
      {nil, _} -> st
      {_, {url, live}} -> st |> stop_video() |> start_video(url, st.status.position || 0.0, live)
    end
  end

  # -- input ---------------------------------------------------------------------------------

  defp event({_, "xdg_toplevel", :configure, [w, h, _states]}, st), do: %{st | pending_size: if(w > 0 and h > 0, do: {even(w), h})}
  defp event({_, "xdg_toplevel", :close, []}, st) do
    send(self(), {:wl_closed, st.c.sock})
    st
  end

  defp event({_, "xdg_surface", :configure, [serial]}, st) do
    st = %{st | c: Client.request(st.c, st.ids.xdg, :ack_configure, [serial]), configured: true}

    case st.pending_size do
      {w, h} when {w, h} != {st.w, st.h} -> resized(%{st | w: w, h: h, pending_size: nil})
      _ -> %{st | pending_size: nil}
    end
  end

  defp event({_, "wl_seat", :capabilities, [caps]}, st) do
    st = if band(caps, 2) != 0 and st.ids.keyboard == nil, do: create_input(st, :get_keyboard, "wl_keyboard", :keyboard), else: st
    if band(caps, 1) != 0 and st.ids.pointer == nil, do: create_input(st, :get_pointer, "wl_pointer", :pointer), else: st
  end

  defp event({_, "wl_keyboard", :modifiers, [_serial, depressed, latched, locked, group]}, st), do: %{st | mods: depressed ||| latched ||| locked, group: group}

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, 1]}, st) do
    case Keymap.key_name(code, st.mods, st.group) do
      nil -> st
      name -> key(st, name)
    end
  end

  defp event({_, "wl_pointer", :enter, [_serial, _surface, x, y]}, st), do: %{st | pointer: {trunc(x), trunc(y)}}
  defp event({_, "wl_pointer", :motion, [_time, x, y]}, st), do: %{st | pointer: {trunc(x), trunc(y)}}

  defp event({_, "wl_pointer", :button, [_serial, _time, 0x110, 1]}, st) do
    {x, y} = st.pointer
    click(st, x, y)
  end

  defp event({id, "wl_buffer", :release, _}, %{buffer: %{id: id}} = st), do: %{st | busy: false}
  defp event({id, "wl_callback", :done, _}, %{shown: id} = st), do: %{st | shown: nil}
  defp event(_event, st), do: st

  defp create_input(st, req, iface, key) do
    {c, id} = Client.create(st.c, st.ids.seat, req, iface)
    %{st | c: c, ids: Map.put(st.ids, key, id)}
  end

  @doc false
  # What a key does: `{:player, fun_and_args} | :volume_up | ... | :close | :fullscreen | nil`.
  def action(name) do
    case name do
      k when k in ["SPC", "p"] -> {:player, :toggle, []}
      "<left>" -> {:player, :seek, [-5]}
      "<right>" -> {:player, :seek, [5]}
      "<up>" -> {:player, :seek, [60]}
      "<down>" -> {:player, :seek, [-60]}
      k when k in ["0", "+", "="] -> {:volume, 5}
      k when k in ["9", "-"] -> {:volume, -5}
      "m" -> :mute
      "f" -> :fullscreen
      k when k in ["q", "ESC"] -> :close
      _ -> nil
    end
  end

  defp key(st, name) do
    case action(name) do
      {:player, fun, args} -> (if st.player, do: apply(Player, fun, [st.player | args])); st
      {:volume, d} -> Sound.change(d); %{st | dirty: true}
      :mute -> Sound.mute(:toggle); %{st | dirty: true}
      :fullscreen -> fullscreen(st, !st.fullscreen)
      :close when name == "ESC" and st.fullscreen -> fullscreen(st, false)
      :close -> send(self(), {:wl_closed, st.c.sock}); st
      nil -> st
    end
  end

  defp fullscreen(st, on) do
    c = if on, do: Client.request(st.c, st.ids.top, :set_fullscreen, [0]), else: Client.request(st.c, st.ids.top, :unset_fullscreen, [])
    %{st | c: c, fullscreen: on}
  end

  @doc """
  Is a click at `now` (milliseconds, the monotonic clock) the second of a
  double click, the last one at `last` (nil: none, or it ended a double
  click)? A first click never is: the VM's monotonic clock starts far
  below 0, so measured from 0 it always was, and one click filled the
  screen.
  """
  def double?(nil, _now), do: false
  def double?(last, now), do: now - last < 400

  # The bar: a click on the progress line seeks there; on the picture,
  # pause (a double click: fill the screen).
  defp click(st, x, y) do
    now = System.monotonic_time(:millisecond)
    {_, vh} = video_size(st)

    cond do
      y >= vh ->
        case {progress_line(st), st.status.duration} do
          {{x0, x1}, d} when is_number(d) and x >= x0 and x <= x1 and st.player != nil ->
            Player.seek(st.player, {:to, d * (x - x0) / max(x1 - x0, 1)})
            st

          _ ->
            st
        end

      double?(st.last_click, now) ->
        fullscreen(%{st | last_click: nil}, !st.fullscreen)

      true ->
        if st.player, do: Player.toggle(st.player)
        %{st | last_click: now}
    end
  end

  # -- drawing -------------------------------------------------------------------------------

  defp progress_line(st) do
    time_w = Canvas.text_width("00:00:00 / 00:00:00") + 16
    {40, max(st.w - time_w - 8, 48)}
  end

  @doc false
  # The bar, as rows of pixels.
  def bar(st) do
    s = st.status
    c = Canvas.new(st.w, @bar, @bg)
    icon = case s.state do
      :playing -> "||"
      _ -> ">"
    end

    c = Canvas.text(c, 14, 8, icon, @fg, @bg, bold: true)
    {x0, x1} = progress_line(st)
    vol = Sound.status()
    vol_text = if vol.muted, do: "muted", else: "#{vol.volume}%"

    c =
      if s.live || s.duration == nil do
        label = Enum.join(Enum.reject([s.title, s.now_playing, s.error], &(&1 in [nil, ""])), " - ")
        Canvas.text(c, x0, 8, label, @fg, @bg, max_w: max(x1 - x0, 10))
      else
        done = trunc((x1 - x0) * min((s.position || 0) / max(s.duration, 0.001), 1.0))
        c |> Canvas.fill(x0, 13, x1 - x0, 4, @track) |> Canvas.fill(x0, 13, done, 4, @done)
      end

    time = if s.live || s.duration == nil, do: vol_text, else: "#{Player.clock(s.position)} / #{Player.clock(s.duration)}  #{vol_text}"
    Canvas.text(c, x1 + 12, 8, time, @dim, @bg, max_w: st.w - x1 - 14)
    |> Canvas.rows()
  end

  defp draw(%{configured: false} = st), do: st
  defp draw(%{busy: true} = st), do: st
  defp draw(%{dirty: false} = st), do: st
  defp draw(%{shown: id} = st) when id != nil, do: st

  # Nothing new: no picture since the last, the bar as it was.
  defp draw(%{cleared: true, frame: nil, buffer: b} = st) when b != nil do
    if IO.iodata_to_binary(bar(st)) == st.last_bar, do: %{st | dirty: false}, else: paint(st)
  end

  defp draw(st), do: paint(st)

  defp paint(st) do
    st = ensure_buffer(%{st | dirty: false})
    {w, vh} = video_size(st)
    {bx, by, bw, bh} = box(st)
    black = <<0, 0, 0, 0xFF>>

    # The picture's rows where the box is (the whole area, without a cap),
    # the bar under it; the first time at a size, black around the box.
    rows =
      case st.frame do
        # (none yet: the black of the first time at this size)
        nil -> []
        f when bw == w -> [{by * w * 4, f}]
        f -> for r <- 0..(bh - 1)//1, do: {((by + r) * w + bx) * 4, binary_part(f, r * bw * 4, bw * 4)}
      end

    clear = if st.cleared, do: [], else: [{0, :binary.copy(black, w * vh)}]
    # (the bar only when what it shows changed: about once a second)
    bar = IO.iodata_to_binary(bar(st))
    new_bar = !st.cleared or bar != st.last_bar
    :ok = :file.pwrite(st.buffer.file, clear ++ rows ++ if(new_bar, do: [{w * vh * 4, bar}], else: []))

    c =
      if st.cleared do
        c = if st.frame, do: Client.request(st.c, st.ids.surface, :damage_buffer, [bx, by, bw, bh]), else: st.c
        if new_bar, do: Client.request(c, st.ids.surface, :damage_buffer, [0, vh, st.w, st.h - vh]), else: c
      else
        Client.request(st.c, st.ids.surface, :damage_buffer, [0, 0, st.w, st.h])
      end

    c = Client.request(c, st.ids.surface, :attach, [st.buffer.id, 0, 0])
    {c, shown} = Client.create(c, st.ids.surface, :frame, "wl_callback")
    c = Client.request(c, st.ids.surface, :commit, [])
    # (the picture is in the buffer now: drawn again only when a new one comes)
    %{st | c: c, busy: true, cleared: true, shown: shown, last_bar: bar, frame: nil}
  end

  defp ensure_buffer(%{buffer: nil} = st) do
    {c, pool, file} = Client.shm_pool(st.c, st.ids.shm, st.w * st.h * 4, st.dir)
    {c, id} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, st.w, st.h, st.w * 4, 1])
    %{st | c: c, buffer: %{id: id, pool: pool, file: file}}
  end

  defp ensure_buffer(st), do: st

  defp free_buffer(%{buffer: nil}), do: nil

  defp free_buffer(%{buffer: b} = st) do
    Client.request(st.c, b.id, :destroy, [])
    Client.request(st.c, b.pool, :destroy, [])
    :file.close(b.file)
    nil
  end
end
