defmodule Lepton.PhotonTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Photon
  alias Lepton.Photon.{Input, Output, Render}
  alias Lepton.Wayland.{Client, Font, Keymap, Wire}

  # Unix socket paths are short: keep the runtime directory in /tmp.
  defp runtime_dir do
    dir = "/tmp/lph-#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start_photon(opts \\ []) do
    dir = runtime_dir()
    out = Output.file(Path.join(dir, "fb"), 640, 400)
    {:ok, ph} = Photon.start([output: out, socket: Path.join(dir, "wayland-0")] ++ opts)
    on_exit(fn -> if Process.alive?(ph), do: Photon.stop(ph) end)
    env = %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0", "HOME" => tmp_dir("phhome"), "PATH" => "/bin", "NO_COLOR" => "1"}
    {ph, out, env}
  end

  # Events that arrive within `ms`.
  defp events(c, ms \\ 300) do
    sock = c.sock

    receive do
      {:wl_data, ^sock, data, fds} ->
        {evs, c} = Client.handle_data(c, data, fds)
        {more, c} = events(c, ms)
        {evs ++ more, c}
    after
      ms -> {[], c}
    end
  end

  # Events until `done?` holds for them (or 3 seconds pass).
  defp events_until(c, done?, acc \\ [], deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3000
    {evs, c} = events(c, 50)
    acc = acc ++ evs

    if done?.(acc) or System.monotonic_time(:millisecond) > deadline,
      do: {acc, c},
      else: events_until(c, done?, acc, deadline)
  end

  defp names(evs), do: Enum.map(evs, fn {_, iface, name, _} -> {iface, name} end)

  # A client with a mapped xdg_toplevel showing a w x h buffer of `pixel`.
  defp window(env, w, h, pixel, shm_iface \\ "wl_shm") do
    {:ok, c} = Client.connect(Lepton.Wayland.Conn.socket_path(env))
    {c, _globals} = Client.registry(c)
    {c, comp} = Client.bind(c, "wl_compositor", 4)
    {c, shm} = Client.bind(c, shm_iface, 1)
    {c, wm} = Client.bind(c, "xdg_wm_base", 1)
    {c, seat} = Client.bind(c, "wl_seat", 5)
    {c, surf} = Client.create(c, comp, :create_surface, "wl_surface")
    {c, xdg} = Client.create(c, wm, :get_xdg_surface, "xdg_surface", [:new, surf])
    {c, top} = Client.create(c, xdg, :get_toplevel, "xdg_toplevel")
    c = c |> Client.request(top, :set_title, ["test window"]) |> Client.request(surf, :commit, [])
    {evs, c} = events(c)
    assert {_, "xdg_toplevel", :configure, [0, 0, states]} = Enum.find(evs, &match?({_, "xdg_toplevel", :configure, _}, &1))
    assert states == <<4::native-32>>, "the first window is activated"
    {_, _, :configure, [serial]} = Enum.find(evs, &match?({_, "xdg_surface", :configure, _}, &1))
    c = Client.request(c, xdg, :ack_configure, [serial])

    {c, pool, file} = Client.shm_pool(c, shm, w * h * 4, env["XDG_RUNTIME_DIR"])
    :ok = :file.pwrite(file, 0, :binary.copy(pixel, w * h))
    {c, buf} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, w, h, w * 4, 1])
    c = c |> Client.request(surf, :attach, [buf, 0, 0]) |> Client.request(surf, :damage_buffer, [0, 0, w, h])
    {c, cb} = Client.create(c, surf, :frame, "wl_callback")
    c = Client.request(c, surf, :commit, [])
    {evs, c} = events_until(c, fn evs -> Enum.any?(evs, &match?({^cb, "wl_callback", :done, _}, &1)) end)
    assert {buf, "wl_buffer", :release, []} in evs
    assert Enum.any?(evs, &match?({^cb, "wl_callback", :done, _}, &1))
    %{c: c, seat: seat, surface: surf, top: top, xdg: xdg, buffer: buf, file: file, pool: pool, w: w, h: h, events: evs}
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  defp pixel_at(out, x, y), do: Output.read(out, x, y, 1, 1)

  test "the wire format: every argument type, both ways" do
    types = [:int, :uint, :fixed, :string, :string, {:object, "x"}, {:new_id, "y"}, :array, :fd, {:new_id, nil}]
    args = [-5, 7, -1.5, "héllo", nil, nil, 9, <<1, 2, 3>>, 42, {"wl_seat", 5, 12}]
    {data, fds} = Wire.encode(3, 2, types, args)
    bin = IO.iodata_to_binary(data)
    assert rem(byte_size(bin), 4) == 0 and fds == [42]
    assert {[{3, 2, payload}], ""} = Wire.split(bin <> <<1, 2>>) |> then(fn {m, r} -> {m, if(r == <<1, 2>>, do: "", else: r)} end)
    assert {^args, []} = Wire.decode(types, payload, [42])
    assert_raise ArgumentError, fn -> Wire.decode([:string], <<9::native-32, "ab">>, []) end
    assert_raise ArgumentError, fn -> Wire.decode([:fd], <<>>, []) end

    # The header's second word is size << 16 | opcode, as libwayland writes it:
    # wl_display.get_registry(new id 2), little-endian.
    assert IO.iodata_to_binary(elem(Wire.encode(1, 1, [{:new_id, "wl_registry"}], [2]), 0)) == <<1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0>>
    assert {[{1, 1, <<2, 0, 0, 0>>}], ""} = Wire.split(<<1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0>>)
  end

  test "the US keymap: keys for clients, and the XKB keymap sent to them" do
    assert Keymap.key_name(30, 0) == "a"
    assert Keymap.key_name(30, Keymap.shift()) == "A"
    assert Keymap.key_name(30, Keymap.caps()) == "A"
    assert Keymap.key_name(30, Keymap.ctrl()) == "C-a"
    assert Keymap.key_name(45, Keymap.alt()) == "M-x"
    assert Keymap.key_name(2, Keymap.shift()) == "!"
    assert Keymap.key_name(28, 0) == "RET"
    assert Keymap.key_name(57, 0) == "SPC"
    assert Keymap.key_name(103, 0) == "<up>"
    assert Keymap.key_name(42, Keymap.shift()) == nil
    xkb = Keymap.xkb()
    assert xkb =~ "<K30> = 38;"
    assert xkb =~ ~s(key <K30> { type = "ALPHABETIC", [ a, A ] };)
    assert xkb =~ ~s(key <K2> { type = "TWO_LEVEL", [ 1, exclam ] };)
    assert xkb =~ "modifier_map Control { <K29>, <K97> };"
  end

  test "evdev: events, motion gathered per frame, capability bitmaps" do
    assert {[{:key, 30, true}], %{}} = Input.decode(1, 30, 1, :keyboard, %{})
    assert {[], %{}} = Input.decode(1, 30, 2, :keyboard, %{})
    assert {[{:button, 0x110, false}], %{}} = Input.decode(1, 0x110, 0, :mouse, %{})
    {[], acc} = Input.decode(2, 0, 5, :mouse, %{})
    {[], acc} = Input.decode(2, 1, -3, :mouse, acc)
    {[], acc} = Input.decode(2, 8, -1, :mouse, acc)
    assert {[{:motion, 5, -3}, {:wheel, 1}], %{}} = Input.decode(0, 0, 0, :mouse, acc)
    {[], acc} = Input.decode(3, 0, 32767, :tablet, %{})
    assert {[{:abs, 1.0, nil}], %{}} = Input.decode(0, 0, 0, :tablet, acc)
    assert Input.bitmap("120013") == 0x120013
    assert Input.bitmap("1 0") == Bitwise.bsl(1, 64)
  end

  test "the font: PSF glyphs, text rows, and PNG screenshots" do
    assert Font.bitmap(?A) |> byte_size() == 16
    assert Font.has?(?é) and Font.has?(0x2500)
    [row | _] = rows = Font.text_rows("hi", <<1, 1, 1, 255>>, <<0, 0, 0, 255>>, 40)
    assert length(rows) == 16 and byte_size(row) == 40 * 4
    png = Output.png(:binary.copy(Render.px(255, 0, 0), 4), 2, 2)
    assert <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 2::32, 2::32, 8, 2, _::binary>> = png
  end

  test "registry, shm buffers and xdg toplevels: a window appears with its pixels" do
    {ph, out, env} = start_photon()
    {:ok, c} = Client.connect(Lepton.Wayland.Conn.socket_path(env))
    {c, globals} = Client.registry(c)
    assert globals |> Map.new(fn {k, {_, v}} -> {k, v} end) == %{"wl_compositor" => 4, "wl_shm" => 1, "wl_seat" => 5, "wl_output" => 2, "xdg_wm_base" => 1, "lepton_shm" => 1, "wl_subcompositor" => 1, "wl_data_device_manager" => 3, "org_kde_kwin_server_decoration_manager" => 1}
    {c, shm} = Client.bind(c, "wl_shm", 1)
    {c, output} = Client.bind(c, "wl_output", 2)
    {evs, _c} = events(c)
    assert {shm, "wl_shm", :format, [0]} in evs and {shm, "wl_shm", :format, [1]} in evs
    assert {output, "wl_output", :mode, [3, 640, 400, 60_000]} in evs
    assert {output, "wl_output", :done, []} in evs

    red = Render.px(255, 0, 0)
    win = window(env, 50, 20, red)
    assert [%{title: "test window", width: 50, height: 20, focused: true, x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    assert pixel_at(out, cx, cy) == red
    assert pixel_at(out, cx + 49, cy + 19) == red
    assert pixel_at(out, cx + 50, cy + 19) != red

    # Partial update: only the damaged rows are copied.
    green = Render.px(0, 255, 0)
    :ok = :file.pwrite(win.file, 0, :binary.copy(green, 50 * 20))
    c = win.c |> Client.request(win.surface, :attach, [win.buffer, 0, 0]) |> Client.request(win.surface, :damage_buffer, [0, 5, 50, 1]) |> Client.request(win.surface, :commit, [])
    {c, _} = Client.roundtrip(c)
    Photon.sync(ph)
    assert pixel_at(out, cx, cy + 5) == green
    assert pixel_at(out, cx, cy + 6) == red

    # Destroying the toplevel unmaps the window; destroyed IDs come back.
    c = Client.request(c, win.top, :destroy, [])
    {c, _} = Client.roundtrip(c)
    refute Map.has_key?(c.objects, win.top)
    Photon.sync(ph)
    assert Photon.info(ph).windows == []
    assert pixel_at(out, cx, cy) != red
  end

  test "subsurfaces are drawn over their window, where they are put" do
    {ph, out, env} = start_photon()
    # (the pointer starts at the centre, over the window: move it aside)
    Photon.input(ph, {:abs, 0.0, 0.0})
    win = window(env, 60, 40, Render.px(255, 0, 0))
    {c, comp} = Client.bind(win.c, "wl_compositor", 4)
    {c, subc} = Client.bind(c, "wl_subcompositor", 1)
    {c, shm} = Client.bind(c, "wl_shm", 1)
    {c, child} = Client.create(c, comp, :create_surface, "wl_surface")
    {c, sub} = Client.create(c, subc, :get_subsurface, "wl_subsurface", [:new, child, win.surface])
    c = Client.request(c, sub, :set_position, [10, 5])
    {c, pool, file} = Client.shm_pool(c, shm, 8 * 4 * 4, env["XDG_RUNTIME_DIR"])
    green = Render.px(0, 255, 0)
    :ok = :file.pwrite(file, 0, :binary.copy(green, 32))
    {c, buf} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, 8, 4, 32, 1])
    c = c |> Client.request(child, :attach, [buf, 0, 0]) |> Client.request(child, :damage_buffer, [0, 0, 8, 4]) |> Client.request(child, :commit, [])
    {c, _} = Client.roundtrip(c)
    Photon.sync(ph)
    [%{x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    assert pixel_at(out, cx + 10, cy + 5) == green
    assert pixel_at(out, cx + 17, cy + 8) == green
    assert pixel_at(out, cx + 18, cy + 5) == Render.px(255, 0, 0)
    assert pixel_at(out, cx + 9, cy + 5) == Render.px(255, 0, 0)

    # Moving it redraws both places; destroying it uncovers the window.
    c = Client.request(c, sub, :set_position, [30, 20])
    {c, _} = Client.roundtrip(c)
    Photon.sync(ph)
    assert pixel_at(out, cx + 10, cy + 5) == Render.px(255, 0, 0)
    assert pixel_at(out, cx + 30, cy + 20) == green
    c = Client.request(c, sub, :destroy, [])
    {c, _} = Client.roundtrip(c)
    Photon.sync(ph)
    assert pixel_at(out, cx + 30, cy + 20) == Render.px(255, 0, 0)

    # The data device manager exists (toolkits bind it), with no clipboard yet.
    {c, ddm} = Client.bind(c, "wl_data_device_manager", 3)
    {c, _dev} = Client.create(c, ddm, :get_data_device, "wl_data_device", [:new, win.seat])
    {c, src} = Client.create(c, ddm, :create_data_source, "wl_data_source")
    c = Client.request(c, src, :offer, ["text/plain"])
    assert {c, _} = Client.roundtrip(c)

    # Server-side decorations: the default, and the answer to any request.
    {c, mgr} = Client.bind(c, "org_kde_kwin_server_decoration_manager", 1)
    {c, deco} = Client.create(c, mgr, :create, "org_kde_kwin_server_decoration", [:new, win.surface])
    c = Client.request(c, deco, :request_mode, [1])
    {evs, _} = events_until(c, fn evs -> length(for {^deco, _, :mode, _} <- evs, do: 1) == 2 end)
    assert {mgr, "org_kde_kwin_server_decoration_manager", :default_mode, [2]} in evs
    assert [[2], [2]] = for({^deco, _, :mode, args} <- evs, do: args)
  end

  test "a maximized window keeps its size when it loses and regains the focus" do
    {ph, _out, env} = start_photon()
    a = window(env, 100, 50, Render.px(1, 1, 1))
    c = Client.request(a.c, a.top, :set_maximized, [])
    {evs, c} = events(c)
    {bw, bh} = Render.frame_size(0, 0)
    max = [640 - bw, 400 - bh]
    assert Enum.any?(evs, fn {id, _, :configure, [w, h, _]} -> id == a.top and [w, h] == max; _ -> false end)

    # Another window takes the focus, then the first gets it back: every
    # configure it receives still says maximized, at the maximized size.
    b = window(env, 80, 40, Render.px(2, 2, 2))
    Photon.input(ph, {:key, 56, true})
    Photon.input(ph, {:key, 15, true})
    Photon.input(ph, {:key, 15, false})
    Photon.input(ph, {:key, 56, false})
    {evs, _} = events(c)
    configures = for {id, "xdg_toplevel", :configure, [w, h, states]} <- evs, id == a.top, do: {[w, h], for(<<x::native-32 <- states>>, do: x)}
    assert length(configures) >= 2
    for {size, states} <- configures, do: assert(size == max and 1 in states)
    assert [%{maximized: true, x: 0, y: 0} | _] = Enum.sort_by(Photon.info(ph).windows, &(&1.title != "test window" or &1.width == 80))
    _ = b
  end

  test "a window bigger than the screen is asked to fit it" do
    {ph, _out, env} = start_photon()
    win = window(env, 700, 500, Render.px(9, 9, 9))
    {bw, bh} = Render.frame_size(0, 0)
    assert {win.top, "xdg_toplevel", :configure, [640 - bw, 400 - bh, <<4::native-32>>]} in win.events
    assert [%{x: 0, y: 0}] = Photon.info(ph).windows

    # One that grows later moves back up into the screen.
    small = window(env, 100, 50, Render.px(8, 8, 8))
    {c, shm} = Client.bind(small.c, "wl_shm", 1)
    {c, pool, _file} = Client.shm_pool(c, shm, 100 * 340 * 4, env["XDG_RUNTIME_DIR"])
    {c, buf} = Client.create(c, pool, :create_buffer, "wl_buffer", [:new, 0, 100, 340, 400, 1])
    c = c |> Client.request(small.surface, :attach, [buf, 0, 0]) |> Client.request(small.surface, :commit, [])
    {_c, _} = Client.roundtrip(c)
    [%{y: y, height: 340} | _] = Photon.info(ph).windows
    assert y + elem(Render.frame_size(100, 340), 1) <= 400

    # The cascade of new windows stays inside it too.
    for _ <- 1..6, do: window(env, 300, 330, Render.px(7, 7, 7))
    for w <- Photon.info(ph).windows, w.height == 330, do: assert(w.y + elem(Render.frame_size(300, 330), 1) <= 400)
  end

  test "protocol errors are reported and end the connection" do
    {_ph, _out, env} = start_photon()
    {:ok, c} = Client.connect(Lepton.Wayland.Conn.socket_path(env))
    {c, _} = Client.registry(c)
    # A request on an object that does not exist.
    :ok = Lepton.Wayland.Conn.send_data(c.sock, <<77::native-32, 8 * 65536::native-32>>)
    assert_raise RuntimeError, ~r/invalid object 77/, fn -> events(c) end
    assert_receive {:wl_closed, _}, 2000
  end

  test "lepton_shm: pools by path, only in the runtime directory, and no keymap" do
    {ph, out, env} = start_photon()
    blue = Render.px(0, 0, 255)
    win = window(env, 30, 10, blue, "lepton_shm")
    [%{x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    assert pixel_at(out, cx, cy) == blue
    # Photon removed the pool file once it had it open.
    assert File.ls!(env["XDG_RUNTIME_DIR"]) |> Enum.filter(&String.starts_with?(&1, "lepton-shm")) == []
    {c, kbd} = Client.create(win.c, win.seat, :get_keyboard, "wl_keyboard")
    {evs, _c} = events(c)
    refute Enum.any?(evs, &match?({^kbd, _, :keymap, _}, &1))

    # A file anywhere else is refused.
    {:ok, c} = Client.connect(Lepton.Wayland.Conn.socket_path(env))
    {c, _} = Client.registry(c)
    {c, shm} = Client.bind(c, "lepton_shm", 1)
    outside = Path.join(tmp_dir("shm"), "pool")
    File.write!(outside, :binary.copy(<<0>>, 64))
    {c, pool} = Client.new_id(c, "wl_shm_pool")
    c = Client.request(c, shm, :create_pool, [pool, outside, 64])
    assert_raise RuntimeError, ~r/not a file in/, fn -> events(c) end
    assert File.exists?(outside)
  end

  test "input: pointer focus and coordinates, buttons, keyboard focus, keys and modifiers" do
    {ph, _out, env} = start_photon()
    win = window(env, 100, 60, Render.px(0, 0, 255))
    {c, ptr} = Client.create(win.c, win.seat, :get_pointer, "wl_pointer")
    {c, kbd} = Client.create(c, win.seat, :get_keyboard, "wl_keyboard")
    {evs, c} = events(c)
    assert {_, "wl_keyboard", :keymap, [1, fd, size]} = Enum.find(evs, &match?({^kbd, _, :keymap, _}, &1))
    assert size > 1000
    {:ok, keymap} = Lepton.Wayland.Conn.open_fd(fd)
    assert {:ok, "xkb_keymap {" <> _} = :file.pread(keymap, 0, 12)
    assert {kbd, "wl_keyboard", :repeat_info, [25, 400]} in evs
    assert Enum.any?(evs, &match?({^kbd, _, :enter, [_, _, ""]}, &1))

    [%{x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    Photon.input(ph, {:abs, (cx + 10) / 639, (cy + 20) / 399})
    {evs, c} = events(c)
    assert [{"wl_pointer", :enter}, {"wl_pointer", :frame}, {"wl_pointer", :motion}, {"wl_pointer", :frame}] = names(evs)
    {_, _, :motion, [_t, sx, sy]} = Enum.at(evs, 2)
    assert_in_delta sx, 10, 1
    assert_in_delta sy, 20, 1

    Photon.input(ph, {:button, 0x110, true})
    Photon.input(ph, {:button, 0x110, false})
    {evs, c} = events(c)
    assert [[_, _, 0x110, 1], [_, _, 0x110, 0]] = for({^ptr, _, :button, args} <- evs, do: args)

    # Shift+A
    Photon.input(ph, {:key, 42, true})
    Photon.input(ph, {:key, 30, true})
    Photon.input(ph, {:key, 30, false})
    Photon.input(ph, {:key, 42, false})
    {evs, _c} = events(c)
    keys = for {^kbd, _, ev, args} <- evs, ev in [:key, :modifiers], do: {ev, if(ev == :key, do: Enum.slice(args, 2, 2), else: Enum.at(args, 1))}
    assert keys == [{:key, [42, 1]}, {:modifiers, 1}, {:key, [30, 1]}, {:key, [30, 0]}, {:key, [42, 0]}, {:modifiers, 0}]
  end

  test "window management: move by the title bar, close button, Alt+Return, Alt+Tab, Ctrl+Alt+Backspace" do
    me = self()
    {ph, _out, env} = start_photon(spawn: fn _ -> send(me, :spawned) end)
    a = window(env, 80, 40, Render.px(9, 9, 9))
    _b = window(env, 80, 40, Render.px(8, 8, 8))
    [%{title: "test window", focused: true}, %{focused: false, x: ax, y: ay}] = Photon.info(ph).windows

    # Drag A's title bar: it is raised, focused and moved.
    Photon.input(ph, {:abs, (ax + 20) / 639, (ay + 8) / 399})
    Photon.input(ph, {:button, 0x110, true})
    Photon.input(ph, {:motion, 30, 15})
    Photon.input(ph, {:button, 0x110, false})
    assert [%{focused: true, x: nx, y: ny}, %{focused: false}] = Photon.info(ph).windows
    assert {nx, ny} == {ax + 30, ay + 15}
    {evs, c} = events(a.c)
    assert Enum.any?(evs, &match?({_, "xdg_toplevel", :configure, [0, 0, <<4::native-32>>]}, &1))

    # The close button asks the client to close.
    {fw, _} = Render.frame_size(80, 40)
    Photon.input(ph, {:abs, (nx + fw - 10) / 639, (ny + 12) / 399})
    Photon.input(ph, {:button, 0x110, true})
    Photon.input(ph, {:button, 0x110, false})
    {evs, _c} = events(c)
    assert {a.top, "xdg_toplevel", :close, []} in evs

    # Alt+Tab focuses the other window.
    Photon.input(ph, {:key, 56, true})
    Photon.input(ph, {:key, 15, true})
    Photon.input(ph, {:key, 15, false})
    # Alt+Return opens a terminal.
    Photon.input(ph, {:key, 28, true})
    Photon.input(ph, {:key, 28, false})
    Photon.input(ph, {:key, 56, false})
    assert_receive :spawned, 1000
    assert [%{focused: true, x: bx}, %{x: ^nx}] = Photon.info(ph).windows
    assert bx != nx

    ref = Process.monitor(ph)
    for {k, down} <- [{29, true}, {56, true}, {14, true}], do: Photon.input(ph, {:key, k, down})
    assert_receive {:DOWN, ^ref, _, _, :normal}, 2000
  end

  test "the classic desktop: frames, taskbar, minimize and restore, maximize, Start menu, icons" do
    alias Lepton.Photon.WM.Classic
    me = self()
    {ph, out, env} = start_photon(wm: "classic", spawn: fn opts -> send(me, {:spawned, opts}) end)
    click = fn x, y ->
      Photon.input(ph, {:abs, x / 639, y / 399})
      Photon.input(ph, {:button, 0x110, true})
      Photon.input(ph, {:button, 0x110, false})
      Photon.sync(ph)
    end

    # The teal desktop and the grey taskbar at the bottom.
    Photon.sync(ph)
    assert pixel_at(out, 300, 150) == Render.rgb("#008080")
    assert pixel_at(out, 320, 390) == Render.rgb("#c0c0c0")

    a = window(env, 100, 50, Render.px(1, 1, 1))
    _b = window(env, 100, 50, Render.px(2, 2, 2))
    [%{focused: true} = top, %{focused: false}] = Photon.info(ph).windows
    # The content sits inside the bevelled frame and below the navy title bar.
    {dx, dy} = Classic.content_offset()
    assert pixel_at(out, top.x + dx, top.y + dy) == Render.px(2, 2, 2)
    assert pixel_at(out, top.x + 10, top.y + 4) == Render.rgb("#000080")
    assert top.y + elem(Classic.frame_size(100, 50), 1) <= 400 - 28

    # The minimize button hides the window; the other one gets the keyboard.
    {fw, _} = Classic.frame_size(100, 50)
    click.(top.x + fw - 48, top.y + 10)
    assert [%{focused: true}, %{minimized: true, focused: false}] = Photon.info(ph).windows
    assert pixel_at(out, top.x + dx, top.y + dy) != Render.px(2, 2, 2)

    # Its taskbar button (the second) brings it back; clicking again minimizes it.
    click.(74 + 164 + 20, 390)
    assert [%{minimized: false, focused: true}, _] = Photon.info(ph).windows
    click.(74 + 164 + 20, 390)
    assert [_, %{minimized: true}] = Photon.info(ph).windows
    click.(74 + 164 + 20, 390)

    # The maximize button fills the work area above the taskbar.
    [top | _] = Photon.info(ph).windows
    click.(top.x + fw - 32, top.y + 10)
    {evs, _} = events(a.c)
    {bw, bh} = Classic.frame_size(0, 0)
    assert Enum.any?(evs, &match?({_, "xdg_toplevel", :configure, [w, h, _]} when w == 640 - bw and h == 400 - 28 - bh, &1)) or
             match?([%{maximized: true, x: 0, y: 0} | _], Photon.info(ph).windows)

    # The Start menu: Firefox first, then Terminal; Ctrl+Esc opens it too.
    menu_top = 400 - 28 - 158 + 2
    click.(20, 390)
    Photon.sync(ph)
    assert pixel_at(out, 100, 400 - 28 - 20) == Render.rgb("#c0c0c0")
    click.(80, menu_top + 10)
    assert_receive {:spawned, [app: "firefox", title: "Firefox"]}, 1000
    click.(20, 390)
    click.(80, menu_top + 3 + 24 + 10)
    assert_receive {:spawned, []}, 1000
    for {k, down} <- [{29, true}, {1, true}, {1, false}, {29, false}], do: Photon.input(ph, {:key, k, down})
    Photon.sync(ph)
    assert pixel_at(out, 100, 400 - 28 - 20) == Render.rgb("#c0c0c0")

    # Double-clicking the Text Editor icon (the third) opens le.
    click.(500, 300)
    click.(60, 12 + 2 * 76 + 20)
    click.(60, 12 + 2 * 76 + 20)
    assert_receive {:spawned, [command: "le", title: "Text Editor"]}, 1000

    # Exit Desktop... quits.
    ref = Process.monitor(ph)
    click.(20, 390)
    click.(80, 400 - 28 - 10)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 2000
  end

  test "the terminal: a shell in a window, typed into through the compositor" do
    {ph, out, env} = start_photon()
    {:ok, term} = Photon.Term.start(env: env, user: "root", size: {10, 40})
    ref = Process.monitor(term)
    assert eventually(fn -> match?([%{app_id: "lepton.term", width: 328, height: 168}], Photon.info(ph).windows) end)

    # "echo hi" RET
    for code <- [18, 46, 35, 24, 57, 35, 23, 28] do
      Photon.input(ph, {:key, code, true})
      Photon.input(ph, {:key, code, false})
    end

    assert eventually(fn -> Lepton.Screen.text(:sys.get_state(term).screen) =~ ~r/echo hi\n+hi\n/ end)
    Photon.sync(ph)
    # The text is on the screen: some pixel in the window is the foreground colour.
    [%{x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    assert Output.read(out, cx, cy, 328, 168) =~ Photon.Term.colors("") |> elem(0)

    # Dragging the bottom-right corner resizes the terminal in whole cells.
    {fw, fh} = Render.frame_size(328, 168)
    Photon.input(ph, {:abs, (x + fw - 3) / 639, (y + fh - 3) / 399})
    Photon.input(ph, {:button, 0x110, true})
    Photon.input(ph, {:motion, 85, 40})
    Photon.input(ph, {:button, 0x110, false})
    assert eventually(fn -> match?([%{width: 408, height: 200}], Photon.info(ph).windows) end)
    assert %{rows: 12, cols: 50} = :sys.get_state(term)

    # "exit" RET: the shell ends and the window closes.
    for code <- [18, 45, 23, 20, 28] do
      Photon.input(ph, {:key, code, true})
      Photon.input(ph, {:key, code, false})
    end

    assert_receive {:DOWN, ^ref, _, _, _}, 5000
    assert eventually(fn -> Photon.info(ph).windows == [] end)
  end

  test "photon: info and term without a running compositor" do
    assert {"Photon is not running. Start it with: photon\n", 0} = sh("photon info")
    assert {"", 1} = sh("photon term")
    assert {"", 2} = sh("photon frobnicate")
  end

  # Inside Lepton: the real framebuffer (QEMU's ramfb) and input devices.
  @tag :native
  test "the framebuffer and evdev devices of the VM" do
    assert {:ok, fb} = Output.framebuffer()
    assert fb.width > 0 and fb.height > 0
    kinds = Input.devices() |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert :keyboard in kinds and :tablet in kinds

    dir = runtime_dir()
    {:ok, ph} = Photon.start(output: fb, socket: Path.join(dir, "wayland-0"))
    on_exit(fn -> if Process.alive?(ph), do: Photon.stop(ph) end)
    env = %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0"}
    fb = Output.open(fb)
    # (descriptors come and go while listing them: skip those)
    fds = fn -> for f <- File.ls!("/proc/self/fd"), t = elem(File.read_link("/proc/self/fd/" <> f), 1), is_binary(t), do: t end
    before = fds.()
    yellow = Render.px(255, 255, 0)
    win = window(env, 64, 32, yellow, "lepton_shm")
    [%{x: x, y: y}] = Photon.info(ph).windows
    {cx, cy} = Render.content_origin(x, y)
    assert Output.read(fb, cx, cy, 1, 1) == yellow

    # A lepton_shm client leaves no descriptors behind.
    Client.close(win.c)
    :file.close(win.file)
    assert eventually(fn -> Photon.info(ph).windows == [] end)
    assert eventually(fn -> fds.() -- before == [] end), "left open: #{inspect(fds.() -- before)}"

    # Nor does a wl_shm client, whose pools arrive as descriptors (closed by Lepton.FD).
    win = window(env, 64, 32, yellow, "wl_shm")
    {c, kbd} = Client.create(win.c, win.seat, :get_keyboard, "wl_keyboard")
    {evs, _} = events(c)
    {_, _, :keymap, [_, keymap_fd, _]} = Enum.find(evs, &match?({^kbd, _, :keymap, _}, &1))
    assert Lepton.FD.close(keymap_fd) == :ok
    assert Lepton.FD.close(keymap_fd) == {:error, :ebadf}
    Client.close(win.c)
    :file.close(win.file)
    assert eventually(fn -> Photon.info(ph).windows == [] end)
    assert eventually(fn -> fds.() -- before == [] end), "left open: #{inspect(fds.() -- before)}"
  end
end
