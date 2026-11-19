defmodule Lepton.Commands.Desktop do
  @moduledoc "The graphical desktop: Photon, Lepton's Wayland compositor."

  use Lepton.Command
  alias Lepton.{Apps, Photon, Sound, Users}
  alias Lepton.Photon.{Output, Term}

  defcmd "photon", "the graphical desktop (Photon, a Wayland compositor) and its terminal windows",
    usage: "photon [start] | term [COMMAND...] | info | display [extend|mirror] | screenshot FILE.png | stop" do
    photon(args, ctx)
  end

  defcmd "classic", "the classic desktop: Photon with a Windows 95-style window manager",
    usage: "classic" do
    case args do
      [] ->
        start(ctx, "classic")

      _ ->
        IO.err(ctx, "usage: classic")
        2
    end
  end

  defcmd "app", "native Linux apps (from Alpine's packages): list, install, update, remove",
    usage: "app [list] | install NAME | update [NAME] | remove NAME" do
    app(args, ctx)
  end

  defcmd "firefox", "the Firefox web browser (installs it the first time; needs Photon)",
    usage: "firefox [URL...]" do
    cond do
      not Apps.installed?("firefox") and not Users.root?(ctx) ->
        IO.err(ctx, "firefox: Firefox isn't installed yet. Install it with: sudo app install firefox")
        1

      not Apps.installed?("firefox") and app(["install", "firefox"], ctx) != 0 ->
        1

      true ->
        case session_env(ctx) do
          {:ok, env} ->
            with {:updated, version} <- Apps.maintain("firefox"), do: IO.puts(ctx, "Updated Firefox to #{version}.")
            {:ok, pid} = Apps.launch("firefox", args, %{ctx | env: env})
            IO.puts(ctx, "Firefox is starting (process #{pid}; log: ~/.cache/lepton/firefox.log).")
            0

          {:error, reason} ->
            IO.err(ctx, "firefox: #{reason}; Firefox runs on the desktop")
            1
        end
    end
  end

  defcmd "volume", "the sound volume: show it, set it (0-100, +N, -N), mute or unmute",
    usage: "volume [N | +N | -N | up | down | mute | unmute | toggle]" do
    result =
      case args do
        [] -> {:ok, Sound.status()}
        ["up"] -> Sound.change(5)
        ["down"] -> Sound.change(-5)
        ["mute"] -> Sound.mute(true)
        ["unmute"] -> Sound.mute(false)
        ["toggle"] -> Sound.mute(:toggle)
        ["+" <> n] -> with {d, ""} <- Integer.parse(n), do: Sound.change(d), else: (_ -> :usage)
        ["-" <> n] -> with {d, ""} <- Integer.parse(n), do: Sound.change(-d), else: (_ -> :usage)
        [n] -> with {v, ""} when v in 0..100 <- Integer.parse(String.trim_trailing(n, "%")), do: Sound.set_volume(v), else: (_ -> :usage)
        _ -> :usage
      end

    case result do
      {:ok, st} ->
        on = if st.card, do: " on #{st.card.name}#{if st.card[:software], do: " (software volume)"}", else: " (no sound card)"
        IO.puts(ctx, "Volume: #{st.volume}%#{if st.muted, do: ", muted"}#{on}")
        0

      {:error, reason} ->
        IO.err(ctx, "volume: #{reason}")
        1

      :usage ->
        IO.err(ctx, "usage: volume [N | +N | -N | up | down | mute | unmute | toggle]")
        2
    end
  end

  defcmd "play", "play a sound file (WAV) on the sound card; C-c stops it", usage: "play FILE.wav..." do
    case args do
      [] ->
        IO.err(ctx, "usage: play FILE.wav...")
        2

      files ->
        Enum.reduce_while(files, 0, fn file, _ ->
          path = Lepton.Ctx.path(ctx, file)

          case playing(ctx, fn -> Sound.play_wav(path) end) do
            :ok -> {:cont, 0}
            :stopped -> {:halt, 130}
            {:error, reason} -> {:cont, sound_error(ctx, "play", "#{file}: #{reason}")}
          end
        end)
    end
  end

  defcmd "beep", "play a tone (default 880 Hz for 150 ms)", usage: "beep [HZ [MS]]" do
    case beep_args(args) do
      {:ok, hz, ms} ->
        case playing(ctx, fn -> Sound.beep(hz, ms) end) do
          :ok -> 0
          :stopped -> 130
          {:error, reason} -> sound_error(ctx, "beep", reason)
        end

      :usage ->
        IO.err(ctx, "usage: beep [HZ [MS]] (20-20000 Hz, up to 10000 ms)")
        2
    end
  end

  defp beep_args(args) do
    case Enum.map(args, &Integer.parse/1) do
      nums when length(nums) <= 2 ->
        if Enum.all?(nums, &match?({_, ""}, &1)) do
          [hz, ms] = Enum.map(nums, &elem(&1, 0)) ++ Enum.drop([880, 150], length(nums))
          if hz in 20..20_000 and ms in 1..10_000, do: {:ok, hz, ms}, else: :usage
        else
          :usage
        end

      _ ->
        :usage
    end
  end

  defp sound_error(ctx, cmd, reason) do
    IO.err(ctx, "#{cmd}: #{reason}")
    1
  end

  defcmd "sound", "sound cards: list them, choose where sound plays, play a test tone",
    usage: "sound [list] | use N | use auto | test" do
    case args do
      a when a in [[], ["list"]] ->
        st = Sound.status()

        if st.cards == [] do
          IO.puts(ctx, "No sound card. Add a sound device to the VM (UTM: Sound), or plug in USB audio.")
        else
          for c <- st.cards do
            mark = if st.card && st.card.index == c.index, do: "*", else: " "
            vol = if c[:software], do: "software volume", else: "volume: #{c.master && c.master.name}"
            IO.puts(ctx, "#{mark} #{c.index}  #{String.pad_trailing(c.name, 28)} #{vol}")
          end

          how = if st.chosen, do: "chosen with sound use", else: "the card added last"
          IO.puts(ctx, "(* plays sound: #{how})")
        end

        0

      ["use", "auto"] ->
        sound_result(ctx, Sound.use_card(nil))

      ["use", n] ->
        case Integer.parse(n) do
          {i, ""} -> sound_result(ctx, Sound.use_card(i))
          _ ->
            IO.err(ctx, "usage: sound use N | auto")
            2
        end

      ["test"] ->
        # Three rising notes: C, E, G.
        chime = fn ->
          Enum.reduce_while([523, 659, 784], :ok, fn hz, :ok ->
            case Sound.beep(hz, 180) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end

        case playing(ctx, chime) do
          :ok -> 0
          :stopped -> 130
          {:error, reason} -> sound_error(ctx, "sound", reason)
        end

      _ ->
        IO.err(ctx, "usage: sound [list] | use N | use auto | test")
        2
    end
  end

  defp sound_result(ctx, {:ok, st}) do
    IO.puts(ctx, "Sound plays on #{(st.card && st.card.name) || "no card"}.")
    0
  end

  defp sound_result(ctx, {:error, reason}), do: sound_error(ctx, "sound", reason)

  # Play in a process of its own, so C-c (or the shell going away) stops the sound.
  defp playing(_ctx, fun) do
    me = self()
    {pid, ref} = spawn_monitor(fn -> send(me, {:played, self(), fun.()}) end)
    wait_playing(pid, ref)
  end

  defp wait_playing(pid, ref) do
    receive do
      {:played, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:signal, sig} when sig in [:int, :term] ->
        Process.exit(pid, :kill)
        :stopped

      {:DOWN, ^ref, _, _, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp app(args, ctx) when args in [[], ["list"]] do
    for name <- Apps.names() do
      app = Apps.get(name)

      status =
        case Apps.info(name) do
          %{packages: pkgs, size: size} ->
            checked = if t = Apps.checked_at(name), do: ", checked for updates #{Calendar.strftime(DateTime.from_unix!(t), "%Y-%m-%d")}", else: ""
            ready = if Apps.staged?(name), do: "; an update is ready (applies when it next starts)", else: ""
            "#{Apps.version(name)} (#{length(pkgs)} packages, #{div(size, 1_048_576)} MiB#{checked})#{ready}"

          nil ->
            "not installed"
        end

      IO.puts(ctx, "#{String.pad_trailing(name, 12)} #{String.pad_trailing(app.summary, 28)} #{status}")
    end

    0
  end

  defp app([cmd | _], ctx) when cmd in ~w(install update remove) and ctx.user != "root", do: Users.denied(ctx, "app #{cmd}")

  defp app(["update"], ctx) do
    Apps.names() |> Enum.filter(&Apps.installed?/1) |> Enum.map(&app(["update", &1], ctx)) |> Enum.max(fn -> 0 end)
  end

  defp app(["update", name], ctx) do
    cond do
      not Apps.installed?(name) ->
        IO.err(ctx, "app: #{name} is not installed")
        1

      true ->
        case Apps.stage(name, &IO.puts(ctx, &1)) do
          {:ok, :current} ->
            IO.puts(ctx, "#{name} is up to date (#{Apps.version(name)}).")
            0

          {:ok, {:staged, changes}} ->
            for {pkg, old, new} <- changes, do: IO.puts(ctx, "  #{pkg}: #{old || "(new)"} -> #{new || "(removed)"}")

            if Apps.running?(name) do
              IO.puts(ctx, "#{name} is running: the update applies when it next starts.")
              0
            else
              IO.puts(ctx, "Setting up...")

              case Apps.apply_staged(name) do
                :ok ->
                  IO.puts(ctx, "Updated #{name} to #{Apps.version(name)}.")
                  0

                {:error, reason} ->
                  IO.err(ctx, "app: #{reason} (#{name} was left as it was)")
                  1
              end
            end

          {:error, reason} ->
            IO.err(ctx, "app: #{reason}")
            1
        end
    end
  end

  defp app(["install", name], ctx) do
    if Apps.installed?(name) do
      IO.puts(ctx, "#{name} is already installed.")
      0
    else
      case Apps.install(name, &IO.puts(ctx, &1)) do
        :ok ->
          IO.puts(ctx, "Installed #{name}.")
          0

        {:error, reason} ->
          IO.err(ctx, "app: #{reason}")
          1
      end
    end
  end

  defp app(["remove", name], ctx) do
    case Apps.remove(name) do
      :ok ->
        IO.puts(ctx, "Removed #{name}.")
        0

      {:error, reason} ->
        IO.err(ctx, "app: #{reason}")
        1
    end
  end

  defp app(_args, ctx) do
    IO.err(ctx, "usage: app [list] | install NAME | update [NAME] | remove NAME")
    2
  end

  defp photon(args, ctx) when args in [[], ["start"]], do: start(ctx, "photon")

  defp photon(["term" | command], ctx) do
    with {:ok, env} <- session_env(ctx),
         {:ok, _} <- Term.start(env: env, user: ctx.user, cwd: ctx.cwd, command: if(command != [], do: Enum.join(command, " "))) do
      0
    else
      {:error, reason} when is_binary(reason) ->
        IO.err(ctx, "photon: #{reason}")
        1

      {:error, reason} ->
        IO.err(ctx, "photon: cannot open a terminal: #{inspect(reason)}")
        1
    end
  end

  defp photon(["info"], ctx) do
    case Process.whereis(Photon) do
      nil ->
        IO.puts(ctx, "Photon is not running. Start it with: photon")
        0

      pid ->
        info = Photon.info(pid)
        {w, h} = info.output
        style = if info.wm == Lepton.Photon.WM.Classic, do: "classic", else: "photon"
        displays = Photon.displays(pid)
        n = length(displays.displays)
        on = if n > 1, do: " on #{n} displays (#{displays.mode})", else: ""
        IO.puts(ctx, "Photon: #{w}x#{h}#{on}, #{style} window manager, socket #{info.socket}")
        IO.puts(ctx, "#{info.clients} client(s), #{length(info.windows)} window(s)")

        for win <- info.windows do
          mark = cond do
            win.focused -> "*"
            win[:minimized] -> "_"
            true -> " "
          end
          IO.puts(ctx, " #{mark} #{String.pad_trailing(win.title || "(untitled)", 30)} #{String.pad_trailing(win.app_id || "", 14)} #{win.width}x#{win.height} at #{win.x},#{win.y}")
        end

        0
    end
  end

  defp photon(["display" | mode], ctx) when mode in [[], ["extend"], ["mirror"]] do
    case Process.whereis(Photon) do
      nil ->
        IO.err(ctx, "photon: not running")
        1

      pid ->
        info = if mode == [], do: Photon.displays(pid), else: Photon.display_mode(pid, String.to_existing_atom(hd(mode)))
        n = length(info.displays)
        how = if n > 1, do: ", #{if info.mode == :mirror, do: "mirrored", else: "extended side by side"}", else: ""
        IO.puts(ctx, "#{n} display#{if n != 1, do: "s"}#{how}:")

        for {d, i} <- Enum.with_index(info.displays) do
          where = if info.mode == :extend, do: " at #{d.x},#{d.y}", else: ""
          primary = if i == 0, do: " (primary)", else: ""
          IO.puts(ctx, "  #{d.path}  #{d.width}x#{d.height}  #{d.driver || "framebuffer"}#{where}#{primary}")
        end

        0
    end
  end

  defp photon(["screenshot", file], ctx) do
    path = Lepton.Ctx.path(ctx, file)

    cond do
      Process.whereis(Photon) == nil ->
        IO.err(ctx, "photon: not running")
        1

      Users.check_write(ctx, path) != :ok ->
        IO.err(ctx, "photon: #{file}: permission denied")
        1

      true ->
        File.write!(path, Photon.screenshot(Photon))
        IO.puts(ctx, "Saved #{file}")
        0
    end
  end

  defp photon(["stop"], ctx) do
    case Process.whereis(Photon) do
      nil ->
        IO.err(ctx, "photon: not running")
        1

      pid ->
        GenServer.stop(pid)
        0
    end
  end

  defp photon(_args, ctx) do
    IO.err(ctx, "usage: photon [start] | term [COMMAND...] | info | display [extend|mirror] | screenshot FILE.png | stop")
    2
  end

  defp start(ctx, wm) do
    with nil <- Process.whereis(Photon),
         {:ok, out} <- Output.framebuffer() do
      dir = runtime_dir(ctx)
      env = Map.merge(ctx.env, %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0"})
      open = fn opts -> open(opts, env, ctx) end

      opts = [output: out, displays: :auto, socket: Path.join(dir, "wayland-0"), input: :evdev, spawn: open, name: Photon, console: true, session: self(), wm: wm]

      case Photon.start(opts) do
        {:ok, pid} ->
          own(Path.join(dir, "wayland-0"), ctx)
          ref = Process.monitor(pid)
          open.([])
          name = if wm == "classic", do: "The classic desktop", else: "Photon"
          IO.puts(ctx, "#{name} is running on the display (#{out.width}x#{out.height}). Ctrl+Alt+Backspace quits.")
          wait(ref, pid, ctx)

        {:error, reason} ->
          IO.err(ctx, "photon: #{reason}")
          1
      end
    else
      pid when is_pid(pid) ->
        IO.err(ctx, "photon: already running (open a terminal with: photon term)")
        1

      {:error, reason} ->
        IO.err(ctx, "photon: #{reason}")
        1
    end
  end

  # Open a terminal, or an app (in a terminal the first time, to show it
  # installing), or join a Wi-Fi network (in a terminal, for the passphrase).
  defp open(opts, env, ctx) do
    app = opts[:app]

    cond do
      ssid = opts[:wifi] ->
        Term.start(env: env, user: ctx.user, cwd: env["HOME"], command: wifi_command(ssid, opts[:open], Users.root?(ctx)), title: "Wi-Fi: #{ssid}")

      app && Apps.installed?(app) ->
        Apps.maintain(app)
        Apps.launch(app, [], %{ctx | env: env})

      app ->
        install = if Users.root?(ctx), do: "app install #{app}", else: "sudo app install #{app}"
        command = "#{install} && #{app} || read -p 'Press Enter to close this window. ' answer"
        Term.start(env: env, user: ctx.user, cwd: env["HOME"], command: command, title: "Installing #{opts[:title] || app}")

      true ->
        Term.start(env: env, user: ctx.user, cwd: opts[:cwd] || env["HOME"], command: opts[:command], title: opts[:title])
    end
  end

  @doc false
  # `wifi connect` for the applet's terminal: open networks need no
  # passphrase; the window closes itself once connected.
  def wifi_command(ssid, open?, root?) do
    quoted = "'" <> String.replace(ssid, "'", "'\\''") <> "'"
    connect = "#{if root?, do: "", else: "sudo "}wifi connect #{quoted}#{if open?, do: " ''", else: ""}"
    "#{connect} && sleep 2 || read -p 'Press Enter to close this window. ' answer"
  end

  defp wait(ref, pid, ctx) do
    receive do
      {:DOWN, ^ref, _, _, _} ->
        IO.puts(ctx, "Photon stopped.")
        0

      {:signal, sig} when sig in [:int, :term] ->
        GenServer.stop(pid)
        wait(ref, pid, ctx)

      _ ->
        wait(ref, pid, ctx)
    end
  end

  # The environment Wayland clients need: from this shell (inside Photon) or the running Photon.
  defp session_env(ctx) do
    cond do
      ctx.env["WAYLAND_DISPLAY"] && ctx.env["XDG_RUNTIME_DIR"] ->
        {:ok, ctx.env}

      pid = Process.whereis(Photon) ->
        socket = Photon.info(pid).socket
        {:ok, Map.merge(ctx.env, %{"XDG_RUNTIME_DIR" => Path.dirname(socket), "WAYLAND_DISPLAY" => Path.basename(socket)})}

      true ->
        {:error, "Photon is not running (start it with: photon)"}
    end
  end

  # $XDG_RUNTIME_DIR: /run/user/UID, private to the user.
  defp runtime_dir(ctx) do
    uid = case Users.get(ctx.user) do
      %Users{uid: uid} -> uid
      nil -> 0
    end

    dir = if Lepton.Sys.native?(), do: "/run/user/#{uid}", else: Path.join(System.tmp_dir!(), "lepton-run-#{uid}")
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    # The user's own: programs running as them (Firefox) connect here.
    own(dir, ctx)
    dir
  end

  defp own(path, ctx) do
    case Users.get(ctx.user) do
      %Users{uid: uid, gid: gid} when uid != 0 ->
        File.chown(path, uid)
        File.chgrp(path, gid)

      _ ->
        :ok
    end
  end
end
