defmodule Lepton.Vault.App do
  @moduledoc """
  The Passwords window: a Wayland client (as `Lepton.Photon.Term` is)
  showing `Lepton.Vault.UI`. It draws the whole window into a `wl_shm`
  buffer after each change, turns key codes into keys with the US keymap
  (repeating them itself, as the protocol expects) and pointer buttons
  and the wheel into clicks and scrolling. A tick each second keeps the
  one-time code's countdown moving and notices the vault locking.

  The classic desktop's Start menu opens it (`vault gui` does too, from a
  terminal on the desktop).
  """

  use GenServer, restart: :temporary

  import Bitwise

  alias Lepton.Photon.Canvas
  alias Lepton.Vault
  alias Lepton.Vault.UI
  alias Lepton.Wayland.{Client, Keymap}

  @repeat_delay 400
  @repeat_rate 33

  @doc "Open the window. Options: `:env` (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `HOME`), `:user`, `:size` (`{w, h}`)."
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc false
  def ui(pid), do: GenServer.call(pid, :ui)

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
    user = opts[:user] || "root"
    {c, globals} = Client.registry(c)
    {c, compositor} = Client.bind(c, "wl_compositor", 4)
    {c, shm} = if Map.has_key?(globals, "lepton_shm"), do: Client.bind(c, "lepton_shm", 1), else: Client.bind(c, "wl_shm", 1)
    {c, wm} = Client.bind(c, "xdg_wm_base", 1)
    {c, seat} = if Map.has_key?(globals, "wl_seat"), do: Client.bind(c, "wl_seat", 5), else: {c, nil}
    {c, surface} = Client.create(c, compositor, :create_surface, "wl_surface")
    {c, xdg} = Client.create(c, wm, :get_xdg_surface, "xdg_surface", [:new, surface])
    {c, top} = Client.create(c, xdg, :get_toplevel, "xdg_toplevel")
    c = c |> Client.request(top, :set_title, ["Passwords"]) |> Client.request(top, :set_app_id, ["lepton.vault"])
    c = Client.request(c, surface, :commit, [])
    {w, h} = opts[:size] || {640, 420}
    :timer.send_interval(1000, :tick)

    %{
      c: c,
      ids: %{shm: shm, wm: wm, seat: seat, surface: surface, xdg: xdg, top: top, keyboard: nil, pointer: nil},
      ui: UI.new(user: user, path: Vault.path(env["HOME"] || "/root", env), w: w, h: h),
      configured: false,
      pending_size: nil,
      buffer: nil,
      busy: false,
      dirty: true,
      mods: 0,
      group: 0,
      repeat: nil,
      pointer: {0, 0},
      dir: env["XDG_RUNTIME_DIR"] || System.tmp_dir!()
    }
  end

  # -- events ------------------------------------------------------------------------------

  @impl true
  def handle_call(:ui, _from, st), do: {:reply, st.ui, st}

  @impl true
  def handle_info({:wl_data, sock, data, fds}, %{c: %{sock: sock}} = st) do
    {events, c} = Client.handle_data(st.c, data, fds)
    {:noreply, Enum.reduce(events, %{st | c: c}, &event/2) |> maybe_draw()}
  end

  def handle_info({:wl_closed, _}, st), do: {:stop, :normal, st}

  def handle_info(:tick, st), do: {:noreply, ui(st, :tick) |> maybe_draw()}

  def handle_info({:job_done, job, result}, st), do: {:noreply, ui(st, {:job_done, job, result}) |> maybe_draw()}

  def handle_info({:repeat, code}, %{repeat: {code, _}} = st) do
    st = key(st, code)
    {:noreply, %{st | repeat: {code, Process.send_after(self(), {:repeat, code}, @repeat_rate)}} |> maybe_draw()}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    Client.close(st.c)
    :ok
  end

  # An unlock or create the window asked for (it says "Unlocking..." in the
  # meantime): in a task, so the window keeps drawing.
  defp start_job(%{job: nil}, %{job: job} = new) when job != nil do
    me = self()
    spawn(fn -> send(me, {:job_done, job, UI.run_job(new, job)}) end)
    new
  end

  defp start_job(_old, new), do: new

  # Something happened to the window's contents: redraw if it looks different.
  defp ui(st, event) do
    new = UI.handle(st.ui, event)
    new = start_job(st.ui, new)
    # Each second, only the one-time code's countdown changes.
    counting? = event == :tick and new.screen == :main and new.mode == :view and (UI.selected(new) || %{})["otp"] != nil
    %{st | ui: new, dirty: st.dirty or counting? or Map.drop(new, [:regions]) != Map.drop(st.ui, [:regions])}
  end

  defp event({_, "xdg_toplevel", :configure, [w, h, _states]}, st) do
    %{st | pending_size: if(w > 0 and h > 0, do: {w, h})}
  end

  defp event({_, "xdg_toplevel", :close, []}, st) do
    send(self(), {:wl_closed, st.c.sock})
    st
  end

  defp event({_, "xdg_surface", :configure, [serial]}, st) do
    st = %{st | c: Client.request(st.c, st.ids.xdg, :ack_configure, [serial]), configured: true}

    case st.pending_size do
      {w, h} when {w, h} != {st.ui.w, st.ui.h} -> %{ui(st, {:resize, w, h}) | buffer: free_buffer(st), busy: false, dirty: true, pending_size: nil}
      _ -> %{st | pending_size: nil}
    end
  end

  defp event({_, "wl_seat", :capabilities, [caps]}, st) do
    st = if band(caps, 2) != 0 and st.ids.keyboard == nil, do: create_input(st, :get_keyboard, "wl_keyboard", :keyboard), else: st
    if band(caps, 1) != 0 and st.ids.pointer == nil, do: create_input(st, :get_pointer, "wl_pointer", :pointer), else: st
  end

  defp event({_, "wl_keyboard", :modifiers, [_serial, depressed, latched, locked, group]}, st), do: %{st | mods: depressed ||| latched ||| locked, group: group}

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, 1]}, st) do
    st = cancel_repeat(st)
    st = key(st, code)
    if Keymap.modifier(code) == nil and code != Keymap.capslock(), do: %{st | repeat: {code, Process.send_after(self(), {:repeat, code}, @repeat_delay)}}, else: st
  end

  defp event({_, "wl_keyboard", :key, [_serial, _time, code, 0]}, st) do
    if match?({^code, _}, st.repeat), do: cancel_repeat(st), else: st
  end

  defp event({_, "wl_keyboard", :leave, _}, st), do: cancel_repeat(st)

  defp event({_, "wl_pointer", :enter, [_serial, _surface, x, y]}, st), do: %{st | pointer: {trunc(x), trunc(y)}}
  defp event({_, "wl_pointer", :motion, [_time, x, y]}, st), do: %{st | pointer: {trunc(x), trunc(y)}}

  defp event({_, "wl_pointer", :button, [_serial, _time, 0x110, 1]}, st) do
    {x, y} = st.pointer
    ui(st, {:click, x, y})
  end

  # Vertical scrolling: a wheel notch is 10 (or 15) units.
  defp event({_, "wl_pointer", :axis, [_time, 0, v]}, st) when v != 0, do: ui(st, {:wheel, if(v > 0, do: 1, else: -1)})

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

  defp key(st, code) do
    case Keymap.key_name(code, st.mods, st.group) do
      nil -> st
      name -> ui(st, {:key, name, st.mods})
    end
  end

  # -- drawing -------------------------------------------------------------------------------

  defp maybe_draw(%{configured: false} = st), do: st
  defp maybe_draw(%{busy: true} = st), do: st
  defp maybe_draw(%{dirty: false} = st), do: st

  defp maybe_draw(st) do
    {canvas, ui} = UI.render(st.ui)
    st = ensure_buffer(%{st | ui: ui, dirty: false})
    :ok = :file.pwrite(st.buffer.file, 0, Canvas.rows(canvas))
    c = Client.request(st.c, st.ids.surface, :damage_buffer, [0, 0, ui.w, ui.h])
    c = Client.request(c, st.ids.surface, :attach, [st.buffer.id, 0, 0])
    c = Client.request(c, st.ids.surface, :commit, [])
    %{st | c: c, busy: true}
  end

  defp ensure_buffer(%{buffer: nil} = st) do
    %{w: w, h: h} = st.ui
    {c, pool, file} = Client.shm_pool(st.c, st.ids.shm, w * h * 4, st.dir)
    {c, id} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, w, h, w * 4, 1])
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
