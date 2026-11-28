defmodule Lepton.SNES do
  @moduledoc """
  The SNES emulator: Super Nintendo (Super Famicom) games, from ROM files
  (`.sfc`, `.smc`), in a window on the desktop (`snes GAME.sfc`).

  The emulation is bsnes's (the `libretro-bsnes` core: cycle-accurate,
  every enhancement chip, full speed), from the `snes` app (`sudo app
  install snes`). bsnes is a library, a libretro core, rather than a
  program: what runs it is `lepton-snes`, a small libretro frontend in C
  (`host.c`, beside this file) compiled with the app's own Tiny C
  Compiler the first time it's needed, and again when Lepton brings a
  new one (it's named by the source's hash, in `/run/lepton/snes`).

  It draws nothing itself. It runs the game at its own rate, 60 frames a
  second (50 for a PAL game), and sends each frame, scaled to the window,
  and its sound, resampled to 48 kHz, over its standard output; the
  window (`Lepton.SNES.Window`, a Wayland client) shows the pictures,
  Lepton plays the sound (`Lepton.Sound`), and the keys go back over its
  standard input. The cartridge's battery RAM, a game's own saves, is
  written to `~/.local/share/snes/GAME.srm` when it changes and on quit;
  save states go beside it (`GAME.state1` to `GAME.state9`).
  """

  alias Lepton.{Apps, Ctx, IO}

  @app "snes"
  @source_path Path.join(__DIR__, "snes/host.c")
  @external_resource @source_path
  @source File.read!(@source_path)
  @hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  # The XInput pads' reader (Lepton.SNES.Pads), built the same way.
  @xinput_path Path.join(__DIR__, "snes/xinput.c")
  @external_resource @xinput_path
  @xinput File.read!(@xinput_path)
  @xinput_hash :crypto.hash(:sha256, @xinput) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @roms ~w(.sfc .smc .swc .fig)

  @doc "The frontend's C source."
  def source, do: @source

  @doc "Is `path` a SNES ROM (by its name)?"
  def rom?(path), do: String.downcase(Path.extname(path)) in @roms

  # (`config :lepton, snes_prefix: DIR`: an unpacked copy elsewhere, for development)
  defp prefix, do: Application.get_env(:lepton, :snes_prefix) || Apps.dir(@app)

  def installed? do
    if Application.get_env(:lepton, :snes_prefix), do: File.exists?(core()), else: Apps.installed?(@app) and File.exists?(core())
  end

  @doc "The emulator core (bsnes, as a libretro library)."
  def core, do: Path.join(prefix(), "usr/lib/libretro/bsnes_libretro.so")

  @doc "Where the game's saves go: `~/.local/share/snes`."
  def save_dir(env), do: Path.join([env["HOME"] || "/root", ".local/share/snes"])

  @doc "The libraries the core and the frontend load (libstdc++, libgomp)."
  # And ALSA's, for its sound: through the mixer, at the system volume, as Firefox's.
  def env, do: Apps.sound_env(%{"LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(prefix(), &1))}, prefix())

  @doc """
  The frontend program, compiled (with the app's tcc) if it isn't yet:
  `{:ok, path}` or `{:error, message}`.
  """
  def host do
    dir = build_dir()
    exe = Path.join(dir, "lepton-snes-" <> @hash)

    if File.exists?(exe), do: {:ok, exe}, else: build(exe)
  end

  @doc """
  The XInput pads' reader (`xinput.c`: Xbox 360 pads and those made like
  them, which the kernel has no driver for), compiled if it isn't yet:
  `{:ok, path}` or `{:error, message}`.
  """
  def xinput_reader do
    exe = Path.join(build_dir(), "lepton-xinput-" <> @xinput_hash)
    if File.exists?(exe), do: {:ok, exe}, else: build(exe, @xinput, "the gamepad reader (lepton-xinput)")
  end

  defp build_dir do
    run = "/run/lepton/snes"

    cond do
      Application.get_env(:lepton, :snes_build_dir) -> Application.get_env(:lepton, :snes_build_dir)
      File.mkdir_p(run) == :ok and File.chmod(run, 0o755) == :ok -> run
      true -> Path.join(System.tmp_dir!(), "lepton-snes")
    end
  end

  @doc false
  def build(exe, source \\ @source, what \\ "the SNES frontend (lepton-snes)") do
    p = prefix()
    tcc = Path.join(p, "usr/bin/tcc")
    lib = Path.join(p, "usr/lib")
    File.mkdir_p!(Path.dirname(exe))
    src = exe <> ".c"
    tmp = exe <> ".tmp"
    File.write!(src, source)

    # tcc's own folders are Alpine's (/usr/lib, /usr/include): everything
    # is named here instead, from the app's folder.
    args =
      ["-nostdinc", "-nostdlib", "-I", Path.join(lib, "tcc/include"), "-I", Path.join(p, "usr/include"), "-O2", "-o", tmp,
       Path.join(lib, "crt1.o"), Path.join(lib, "crti.o"), src, "-L", lib, "-lc", Path.join(lib, "tcc/libtcc1.a"), Path.join(lib, "crtn.o")]

    case System.cmd(tcc, args, env: Enum.to_list(env()), stderr_to_stdout: true) do
      {_, 0} ->
        File.chmod!(tmp, 0o755)
        File.rename!(tmp, exe)
        File.rm(src)
        {:ok, exe}

      {out, _} ->
        File.rm(tmp)
        {:error, "couldn't build #{what}: " <> String.trim(out)}
    end
  rescue
    e -> {:error, "couldn't build #{what}: " <> Exception.message(e)}
  end

  # -- the command ----------------------------------------------------------------------------

  @doc "The `snes` command."
  def cli(args, ctx) do
    case args do
      [h | _] when h in ["-h", "--help"] ->
        IO.puts(ctx, "usage: snes [ROM]   (a .sfc or .smc file; without one, choose from your files)\n\n" <> keys_help())
        0

      ["-" <> _ = flag | _] ->
        IO.err(ctx, "snes: unknown option #{flag}")
        2

      [] ->
        if ready?(ctx), do: choose(ctx, ctx.env["HOME"] || ctx.cwd), else: 1

      [rom] ->
        path = Ctx.path(ctx, rom)

        cond do
          not File.regular?(path) -> IO.err(ctx, "snes: #{rom}: no such file") && 1
          not ready?(ctx) -> 1
          true -> play(ctx, path)
        end

      _ ->
        IO.err(ctx, "usage: snes [ROM]")
        2
    end
  end

  # The app, and the desktop to show it on.
  defp ready?(ctx) do
    cond do
      Lepton.Wayland.Conn.socket_path(ctx.env) |> File.exists?() |> Kernel.not() ->
        IO.err(ctx, "snes: games play in a window: start the desktop first (photon)")
        false

      installed?() ->
        true

      true ->
        Apps.offer_install(ctx, @app, "The SNES emulator plays games with bsnes") == :installed
    end
  end

  @doc """
  Play `path` in a window; returns when the window closes (its exit
  status: 0, or 1 if the game couldn't start).
  """
  def play(ctx, path, opts \\ []) do
    # Updates, as for Firefox: one downloaded earlier goes in now; a new
    # definition (alsa-lib, added for the sound) is fetched for next time.
    if !Application.get_env(:lepton, :snes_prefix), do: Apps.maintain(@app)

    with {:ok, exe} <- host(),
         {:ok, win} <- Lepton.SNES.Window.start(rom: path, host: exe, env: ctx.env, user: ctx.user, title: title(path), notify: self()) do
      ref = Process.monitor(win)
      unless opts[:quiet], do: IO.puts(ctx, "Playing #{Path.basename(path)} (keys: snes --help, or man snes). Close its window to stop.")

      receive do
        {:snes_failed, ^win, why} ->
          receive do: ({:DOWN, ^ref, _, _, _} -> :ok), after: (2000 -> :ok)
          IO.err(ctx, "snes: " <> why)
          1

        {:DOWN, ^ref, _, _, _} ->
          0
      end
    else
      {:error, {:connect, reason}} -> IO.err(ctx, "snes: can't reach the desktop (#{inspect(reason)})") && 1
      {:error, why} when is_binary(why) -> IO.err(ctx, "snes: " <> why) && 1
      {:error, why} -> IO.err(ctx, "snes: #{inspect(why)}") && 1
    end
  end

  @doc "A window title for a ROM: its file name, without the extension."
  def title(path), do: Path.basename(path, Path.extname(path))

  # -- choosing a game (the desktop's SNES app opens with this) ---------------------------------

  @doc "The folders and ROMs in `dir`."
  def entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names = Enum.reject(names, &String.starts_with?(&1, "."))
        dirs = names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort_by(&String.downcase/1) |> Enum.map(&{:dir, &1})
        roms = names |> Enum.filter(&(rom?(&1) and File.regular?(Path.join(dir, &1)))) |> Enum.sort_by(&String.downcase/1) |> Enum.map(&{:file, &1})
        dirs ++ roms

      _ ->
        []
    end
  end

  defp choose(ctx, dir) do
    tty = ctx.tty

    if !(is_pid(tty) and Process.alive?(tty)) do
      IO.err(ctx, "usage: snes ROM")
      2
    else
      Lepton.FileBrowser.run(ctx, dir,
        title: "SNES",
        entries: &entries/1,
        only: &rom?/1,
        empty: "(no games here: .sfc or .smc files)",
        foot: "Enter: play or open   /: find   Backspace: up   q: quit",
        open: fn _dir, [file | _] ->
          Lepton.TTY.write(tty, ["\e[H\e[2J", "\e[1m SNES\e[0m  #{Path.basename(file)}\r\n\r\n", keys_help() |> String.replace("\n", "\r\n"), "\r\n"])
          {:ok, err} = StringIO.open("")
          status = play(%{ctx | stderr: err}, file, quiet: true)
          {:ok, {_, why}} = StringIO.close(err)
          if status != 0, do: String.trim(why)
        end
      )
    end
  end

  @doc "The keys, as `snes --help` and the chooser show them."
  def keys_help do
    """
    Pad:  arrows: D-pad   X: A   Z: B   S: X   A: Y   Q: L   W: R
          Enter: Start   Right Shift (or Backspace): Select
    Game: P (or Pause): pause   Ctrl+R: reset   F11 (or a double click): full screen
          F5: save state   F9: load state   (1-9 pick the slot first)   Esc: close
    """
  end
end
