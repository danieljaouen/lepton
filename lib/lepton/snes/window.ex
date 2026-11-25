defmodule Lepton.SNES.Window do
  @moduledoc """
  The SNES emulator's window: a Wayland client (as the media player's,
  `Lepton.Player.Window`) running `lepton-snes` (see `Lepton.SNES`) and
  showing its frames.

  The frontend sends packets (`{:packet, 4}`): `I` (the game's frame rate
  and sample rate, once it's running), `V` (a frame, scaled to the
  window, in `wl_shm`'s XRGB8888, written into the buffer as it comes:
  the newest is drawn, so a busy machine drops frames rather than falls
  behind), `A` (sound, played by a process of its own through
  `Lepton.Sound`; it keeps no more than a fifth of a second queued, so
  the sound stays with the pictures) and `M` (a message, shown in the
  title for a while). The window sends the pad's buttons (`K`), its size
  (`S`), pause (`P`), reset (`R`), states (`W`/`L`) and quit (`Q`).

  Keys are read by position (evdev codes), not by what they type, so the
  pad is the same on every keyboard layout. Leaving the window lets go of
  every button.
  """

  use GenServer, restart: :temporary

  import Bitwise

  alias Lepton.Wayland.Client

  # libretro's joypad bits: B Y Select Start Up Down Left Right A X L R.
  @pad %{
    # Z, X, A, S, Q, W
    44 => 0, 45 => 8, 30 => 1, 31 => 9, 16 => 10, 17 => 11,
    # Enter (and the keypad's), Right Shift, Backspace
    28 => 3, 96 => 3, 54 => 2, 14 => 2,
    # arrows
    103 => 4, 108 => 5, 105 => 6, 106 => 7
  }
  @esc 1
  @key_p 25
  @pause 119
  @key_r 19
  @f5 63
  @f9 67
  @f11 87
  @ctrl [29, 97]
  @digits 2..10

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "The joypad bit a key (evdev code) presses, or nil."
  def pad_bit(code), do: Map.get(@pad, code)

  @impl true
  def init(opts) do
    env = opts[:env] || %{}

    # The command that opened it ending (its terminal closed): the game
    # closes too, saving as it does.
    if is_pid(opts[:notify]), do: Process.monitor(opts[:notify])

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
    title = opts[:title] || "SNES"
    c = c |> Client.request(top, :set_title, [title]) |> Client.request(top, :set_app_id, ["lepton.snes"])
    c = Client.request(c, surface, :commit, [])
    # Twice the SNES's 256x224.
    {w, h} = {512, 448}

    st = %{
      c: c,
      ids: %{shm: shm, wm: wm, seat: seat, surface: surface, xdg: xdg, top: top, keyboard: nil, pointer: nil},
      w: w,
      h: h,
      title: title,
      configured: false,
      pending_size: nil,
      buffer: nil,
      busy: false,
      frame: nil,
      drawn: false,
      buttons: 0,
      ctrl: MapSet.new(),
      paused: false,
      slot: 1,
      fullscreen: false,
      last_click: 0,
      notify: opts[:notify],
      started: false,
      dir: env["XDG_RUNTIME_DIR"] || System.tmp_dir!(),
      log: Path.join([env["HOME"] || "/root", ".cache", "lepton", "snes.log"])
    }

    save_dir = Lepton.SNES.save_dir(env)
    Lepton.Users.own_new_in_home(save_dir, fn -> File.mkdir_p(save_dir) end)
    Lepton.Users.own_new_in_home(Path.dirname(st.log), fn -> File.mkdir_p(Path.dirname(st.log)) end)
    port = open_host(opts[:host], [Lepton.SNES.core(), opts[:rom], save_dir, "#{w}", "#{h}"], st.log, opts[:user])
    # (sound: the frontend plays it through ALSA; Lepton plays it only if
    # that can't, when the first of it comes here: see audio/2)
    Map.merge(st, %{port: port, audio: nil})
  end

  # The frontend, as the user (a ROM from their files is read with their
  # rights); its messages go to ~/.cache/lepton/snes.log.
  defp open_host(exe, args, log, user) do
    script = ~S'exec "$0" "$@" 2>>"$LEPTON_SNES_LOG"'
    sh = if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
    env = Map.put(Lepton.SNES.env(), "LEPTON_SNES_LOG", log)

    {exe, argv} =
      case user && Lepton.Users.get(user) do
        %Lepton.Users{uid: uid} = u when uid != 0 -> Lepton.RunAs.command(u, sh, ["-c", script, exe | args])
        _ -> {sh, ["-c", script, exe | args]}
      end

    Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :exit_status, args: argv, env: Enum.map(env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)])
    |> tap(&Lepton.Sys.guard/1)
  end

  # -- messages ------------------------------------------------------------------------------

  @impl true
  def handle_info({:wl_data, sock, data, fds}, %{c: %{sock: sock}} = st) do
    {events, c} = Client.handle_data(st.c, data, fds)
    {:noreply, Enum.reduce(events, %{st | c: c}, &event/2) |> draw()}
  end

  def handle_info({:wl_closed, _}, st), do: {:stop, :normal, st}
  def handle_info({:DOWN, _, :process, pid, _}, %{notify: pid} = st), do: {:stop, :normal, st}

  def handle_info({port, {:data, <<?V, w::16, h::16, pixels::binary>>}}, %{port: port} = st) do
    # (a frame made before the last resize is the wrong size: left out)
    if {w, h} == {st.w, st.h}, do: {:noreply, draw(%{st | frame: pixels})}, else: {:noreply, st}
  end

  def handle_info({port, {:data, <<?A, samples::binary>>}}, %{port: port} = st) do
    st = audio(st)
    send(st.audio, {:samples, samples})
    {:noreply, st}
  end

  def handle_info({port, {:data, <<?I, _::binary>>}}, %{port: port} = st), do: {:noreply, %{st | started: true}}
  def handle_info({port, {:data, <<?M, text::binary>>}}, %{port: port} = st), do: {:noreply, show(st, text)}
  def handle_info({port, {:data, _}}, %{port: port} = st), do: {:noreply, st}

  # The frontend ended: before the game started, it couldn't (its log says why).
  def handle_info({port, {:exit_status, status}}, %{port: port} = st) do
    if !st.started and st.notify, do: send(st.notify, {:snes_failed, self(), failure(st, status)})
    {:stop, :normal, %{st | port: nil}}
  end

  def handle_info(:title, st), do: {:noreply, %{st | c: Client.request(st.c, st.ids.top, :set_title, [title(st)])}}
  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    # Quit: the frontend writes the game's saves and ends.
    if st.port do
      port = st.port
      send_host(st, <<?Q>>)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        3000 -> :ok
      end
    end

    if st.audio, do: Process.exit(st.audio, :kill)
    Client.close(st.c)
    :ok
  catch
    _, _ -> :ok
  end

  defp failure(st, status) do
    last =
      case File.read(st.log) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> List.last()
        _ -> nil
      end

    case last do
      "lepton-snes: " <> why -> why
      nil -> "the emulator stopped (#{status})"
      line -> "the emulator stopped (#{status}): #{line}"
    end
  end

  defp send_host(%{port: nil}, _msg), do: :ok

  defp send_host(st, msg) do
    Port.command(st.port, msg)
  catch
    _, _ -> :ok
  end

  defp show(st, text) do
    Process.send_after(self(), :title, 2500)
    %{st | c: Client.request(st.c, st.ids.top, :set_title, ["#{st.title} — #{text}"])}
  end

  defp title(st), do: if(st.paused, do: "#{st.title} (paused)", else: st.title)

  # -- sound ---------------------------------------------------------------------------------

  # Without ALSA in the frontend: Lepton.Sound plays what comes, in a
  # process of its own (the window isn't held up by the sound card). It
  # writes to the card itself, which then plays nothing else, so it's
  # started only when sound comes this way, and it ends with the window,
  # however the window ends. (It used to start with every game and
  # outlive the window: a normal exit doesn't end a linked process, and
  # the card stayed taken, every other sound silent, until a restart.)
  # More than 0.2 s waiting (the card slower than the game, or it
  # started late): the oldest is let go.
  defp audio(%{audio: nil} = st) do
    window = self()
    %{st | audio: spawn(fn -> audio_loop(Process.monitor(window)) end)}
  end

  defp audio(st), do: st

  defp audio_loop(ref) do
    chunks =
      Stream.resource(
        fn -> :ok end,
        fn :ok ->
          receive do
            {:samples, data} -> {[data | catch_up([])], :ok}
            # (the card's file closes as this process ends)
            {:DOWN, ^ref, _, _, _} -> exit(:normal)
          end
        end,
        fn _ -> :ok end
      )

    case Lepton.Sound.play(chunks, 48_000, 2) do
      # No sound card: the game plays silently.
      {:error, _} -> drain(ref)
      _ -> :ok
    end
  end

  defp catch_up(acc) do
    receive do
      {:samples, data} -> catch_up([data | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.take(-10) |> limit()
    end
  end

  # 0.2 s of 48 kHz stereo S16: 38,400 bytes.
  defp limit(chunks), do: if(Enum.sum(Enum.map(chunks, &byte_size/1)) > 38_400, do: Enum.take(chunks, -2), else: chunks)

  defp drain(ref) do
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
      _ -> drain(ref)
    end
  end

  # -- input ---------------------------------------------------------------------------------

  defp event({_, "xdg_toplevel", :configure, [w, h, _states]}, st), do: %{st | pending_size: if(w > 0 and h > 0, do: {w, h})}

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

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, pressed]}, st), do: key(st, code, pressed == 1)
  defp event({_, "wl_keyboard", :leave, _}, st), do: set_buttons(%{st | ctrl: MapSet.new()}, 0)

  defp event({_, "wl_pointer", :button, [_serial, _time, 0x110, 1]}, st) do
    now = System.monotonic_time(:millisecond)
    double? = now - st.last_click < 400
    st = %{st | last_click: now}
    if double?, do: fullscreen(st, !st.fullscreen), else: st
  end

  defp event({id, "wl_buffer", :release, _}, %{buffer: %{id: id}} = st), do: draw(%{st | busy: false})
  defp event(_event, st), do: st

  defp create_input(st, req, iface, key) do
    {c, id} = Client.create(st.c, st.ids.seat, req, iface)
    %{st | c: c, ids: Map.put(st.ids, key, id)}
  end

  @doc false
  # What a key does (pressed, or let go), as the window acts on it.
  def action(code, pressed, ctrl?) do
    cond do
      bit = pad_bit(code) -> if ctrl? and code == @key_r, do: nil, else: {:pad, bit, pressed}
      code in @ctrl -> {:ctrl, pressed}
      not pressed -> nil
      code == @esc -> :close
      code in [@key_p, @pause] -> :pause
      code == @key_r and ctrl? -> :reset
      code == @f5 -> :save
      code == @f9 -> :load
      code == @f11 -> :fullscreen
      code in @digits -> {:slot, code - 1}
      true -> nil
    end
  end

  defp key(st, code, pressed) do
    case action(code, pressed, MapSet.size(st.ctrl) > 0) do
      {:pad, bit, true} -> set_buttons(st, bor(st.buttons, bsl(1, bit)))
      {:pad, bit, false} -> set_buttons(st, band(st.buttons, bnot(bsl(1, bit))))
      {:ctrl, true} -> %{st | ctrl: MapSet.put(st.ctrl, code)}
      {:ctrl, false} -> %{st | ctrl: MapSet.delete(st.ctrl, code)}
      :close -> (send(self(), {:wl_closed, st.c.sock}); st)
      :pause -> pause(st, !st.paused)
      :reset -> (send_host(st, <<?R>>); st)
      :save -> (send_host(st, <<?W, st.slot>>); st)
      :load -> (send_host(st, <<?L, st.slot>>); st)
      :fullscreen -> fullscreen(st, !st.fullscreen)
      {:slot, n} -> show(%{st | slot: n}, "slot #{n} (F5 saves, F9 loads)")
      nil -> st
    end
  end

  defp set_buttons(%{buttons: b} = st, b), do: st

  defp set_buttons(st, b) do
    send_host(st, <<?K, b::16>>)
    %{st | buttons: b}
  end

  defp pause(st, on) do
    send_host(st, <<?P, if(on, do: 1, else: 0)>>)
    st = %{st | paused: on}
    %{st | c: Client.request(st.c, st.ids.top, :set_title, [title(st)])}
  end

  defp fullscreen(st, on) do
    c = if on, do: Client.request(st.c, st.ids.top, :set_fullscreen, [0]), else: Client.request(st.c, st.ids.top, :unset_fullscreen, [])
    %{st | c: c, fullscreen: on}
  end

  # A new size: a new buffer, and the frontend scales to it.
  defp resized(st) do
    free_buffer(st)
    send_host(st, <<?S, st.w::16, st.h::16>>)
    %{st | frame: nil, buffer: nil, busy: false, drawn: false}
  end

  # -- drawing -------------------------------------------------------------------------------

  defp draw(%{configured: false} = st), do: st
  defp draw(%{busy: true} = st), do: st
  # Nothing new since the last (black, until the first frame comes).
  defp draw(%{frame: nil, drawn: true} = st), do: st

  defp draw(st) do
    st = ensure_buffer(st)
    picture = st.frame || :binary.copy(<<0, 0, 0, 0xFF>>, st.w * st.h)
    :ok = :file.pwrite(st.buffer.file, 0, picture)
    c = Client.request(st.c, st.ids.surface, :damage_buffer, [0, 0, st.w, st.h])
    c = Client.request(c, st.ids.surface, :attach, [st.buffer.id, 0, 0])
    c = Client.request(c, st.ids.surface, :commit, [])
    # (drawn: the next frame waits for the compositor to let this buffer go)
    %{st | c: c, busy: true, frame: nil, drawn: true}
  end

  defp ensure_buffer(%{buffer: nil} = st) do
    {c, pool, file} = Client.shm_pool(st.c, st.ids.shm, st.w * st.h * 4, st.dir)
    {c, id} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, st.w, st.h, st.w * 4, 1])
    %{st | c: c, buffer: %{id: id, pool: pool, file: file}}
  end

  defp ensure_buffer(st), do: st

  defp free_buffer(%{buffer: nil}), do: :ok

  defp free_buffer(%{buffer: b} = st) do
    Client.request(st.c, b.id, :destroy, [])
    Client.request(st.c, b.pool, :destroy, [])
    :file.close(b.file)
    :ok
  end
end
