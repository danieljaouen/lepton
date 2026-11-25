defmodule Lepton.SNESTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Photon, SNES}
  alias Lepton.Photon.{Output, Render}
  alias Lepton.SNES.Window

  # A 32 KiB test cartridge: the backdrop is the pad (JOY1H, then JOY1L),
  # which also goes to its battery RAM (see test/fixtures/snes).
  @rom Path.expand("fixtures/snes/pad.sfc", __DIR__)

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  defp runtime_dir do
    dir = "/tmp/lsn-#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "ROMs by name; the pad's keys by position; what other keys do" do
    assert SNES.rom?("Game.SFC") and SNES.rom?("x/y.smc") and not SNES.rom?("a.zip")
    assert SNES.title("/a/Super Game (USA).sfc") == "Super Game (USA)"
    # Z: B (0), X: A (8), A: Y (1), S: X (9), Q/W: L/R, Enter: Start, arrows.
    assert Enum.map([44, 45, 30, 31, 16, 17, 28, 54, 103, 108, 105, 106], &Window.pad_bit/1) == [0, 8, 1, 9, 10, 11, 3, 2, 4, 5, 6, 7]
    assert Window.action(44, true, false) == {:pad, 0, true}
    assert Window.action(44, false, false) == {:pad, 0, false}
    assert Window.action(25, true, false) == :pause
    assert Window.action(19, true, true) == :reset
    assert Window.action(19, true, false) == nil
    assert Window.action(63, true, false) == :save and Window.action(67, true, false) == :load
    assert Window.action(4, true, false) == {:slot, 3}
    assert Window.action(1, true, false) == :close
    assert Window.action(1, false, false) == nil
    assert SNES.keys_help() =~ "F5: save state"
    assert SNES.source() =~ "retro_load_game"
  end

  test "the chooser lists folders and games; open sends games to the emulator" do
    dir = tmp_dir("snes")
    File.mkdir_p!(Path.join(dir, "Games"))
    for f <- ["b.sfc", "A.smc", "notes.txt", ".hidden.sfc"], do: File.write!(Path.join(dir, f), "x")
    assert SNES.entries(dir) == [{:dir, "Games"}, {:file, "A.smc"}, {:file, "b.sfc"}]
    ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dir}}
    assert {:ok, %{snes: [game], player: [], browser: []}} = Lepton.Commands.Desktop.open_plan(["b.sfc"], ctx)
    assert game == Path.join(dir, "b.sfc")
  end

  test "snes: needs the desktop, and a ROM that exists" do
    dir = tmp_dir("snes-cli")
    {:ok, err} = StringIO.open("")
    assert {_, 1} = sh("snes nope.sfc", cwd: dir, stderr: err)
    File.write!(Path.join(dir, "g.sfc"), "x")
    assert {_, 1} = sh("snes g.sfc", cwd: dir, stderr: err, env: %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "none"})
    assert {_, 2} = sh("snes --bogus", cwd: dir, stderr: err)
    assert {help, 0} = sh("snes --help", cwd: dir)
    assert help =~ "usage: snes" and help =~ "Start"
    {:ok, {_, text}} = StringIO.close(err)
    assert text =~ "no such file" and text =~ "start the desktop"
  end

  test "with bsnes: the game in a window, the pad changing it, its battery RAM saved on close" do
    if SNES.installed?() do
      Application.put_env(:lepton, :snes_build_dir, tmp_dir("snes-build"))
      on_exit(fn -> Application.delete_env(:lepton, :snes_build_dir) end)
      assert {:ok, exe} = SNES.host()
      assert File.exists?(exe)

      dir = runtime_dir()
      out = Output.file(Path.join(dir, "fb"), 800, 600)
      {:ok, ph} = Photon.start(output: out, socket: Path.join(dir, "wayland-0"))
      on_exit(fn -> if Process.alive?(ph), do: Photon.stop(ph) end)
      home = tmp_dir("snes-home")
      env = %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0", "HOME" => home}

      {:ok, win} = Window.start(rom: @rom, host: exe, env: env, title: "pad", notify: self())
      ref = Process.monitor(win)
      assert eventually(fn -> match?([%{title: "pad"}], Photon.info(ph).windows) end, 50)
      [%{x: x, y: y}] = Photon.info(ph).windows
      {cx, cy} = Render.content_origin(x, y)
      fb = out
      # (off the middle: the pointer is there; the colour without its alpha byte)
      rgb = fn -> binary_part(Output.read(fb, cx + 100, cy + 224, 1, 1), 0, 3) end
      black = <<0, 0, 0>>
      assert eventually(fn -> rgb.() == black end, 50)

      # B, Y and Start (Z, A, Enter): JOY1H = $D0, a colour on the screen.
      for k <- [44, 30, 28], do: Photon.input(ph, {:key, k, true})
      assert eventually(fn -> rgb.() != black end, 50)
      for k <- [44, 30, 28], do: Photon.input(ph, {:key, k, false})
      assert eventually(fn -> rgb.() == black end, 50)

      # Hold B, close: what the game wrote to its battery RAM is saved.
      Photon.input(ph, {:key, 44, true})
      Process.sleep(200)
      GenServer.stop(win)
      assert_receive {:DOWN, ^ref, _, _, _}, 5000
      assert <<0x80, 0, _::binary>> = File.read!(Path.join(home, ".local/share/snes/pad.srm"))
      refute_received {:snes_failed, _, _}
      # The sound went one way or the other (ALSA's mixer, or Lepton's own
      # when that can't open), and nothing of the window is left after it:
      # a sound process holding the card kept every other sound silent.
      assert File.read!(Path.join(home, ".cache/lepton/snes.log")) =~ ~r/sound through (ALSA|Lepton)/
      Process.sleep(100)
      left = for p <- Process.list(), {:current_function, {Window, _, _}} <- [Process.info(p, :current_function)], do: p
      assert left == []
    end
  end

  test "a ROM that can't be read: the window says why and closes" do
    if SNES.installed?() do
      Application.put_env(:lepton, :snes_build_dir, tmp_dir("snes-build2"))
      on_exit(fn -> Application.delete_env(:lepton, :snes_build_dir) end)
      {:ok, exe} = SNES.host()
      dir = runtime_dir()
      out = Output.file(Path.join(dir, "fb"), 640, 480)
      {:ok, ph} = Photon.start(output: out, socket: Path.join(dir, "wayland-0"))
      on_exit(fn -> if Process.alive?(ph), do: Photon.stop(ph) end)
      # (gone between choosing it and starting)
      bad = Path.join(tmp_dir("snes-bad"), "gone.sfc")
      env = %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0", "HOME" => tmp_dir("snes-home2")}
      {:ok, win} = Window.start(rom: bad, host: exe, env: env, notify: self())
      assert_receive {:snes_failed, ^win, why}, 10_000
      assert why =~ "can't read"
    end
  end
end
