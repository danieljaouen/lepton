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
    usage: "app [list] | install NAME | reinstall NAME | update [NAME] | remove NAME" do
    app(args, ctx)
  end

  defcmd "keyboard", "input sources on the desktop: keyboard layouts (Thai, Hindi, Arabic, ...) and Korean",
    usage: "keyboard [list] | use ID | next | add ID... | remove ID... | set ID..." do
    keyboard(args, ctx)
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
            # One started moments ago has no window yet: wait for it, rather than stop it as a leftover.
            await_starting_firefox()
            stopped = clear_hung("firefox", ctx, env)
            if stopped > 0, do: IO.puts(ctx, "Stopped #{stopped} Firefox process#{if stopped == 1, do: "", else: "es"} left running without a window.")
            user = Users.get(ctx.user)

            cond do
              # Running, on the desktop: a new tab, through its session bus.
              user && firefox_window?() && Apps.session_bus("firefox", user, env)[:start] == false ->
                {:ok, _} = Apps.launch("firefox", args, %{ctx | env: env})
                if args != [], do: IO.puts(ctx, "Opening in Firefox (a new tab).")
                0

              # Started before it had a bus: a second one would only say it is running already.
              user && firefox_window?() ->
                IO.err(ctx, "firefox: Firefox is already running, and was started before it could open new tabs for other programs. Close Firefox and run this again: from then on, each opens in a new tab.")
                1

              true ->
                {:ok, pid} = Apps.launch("firefox", args, %{ctx | env: env})
                IO.puts(ctx, "Firefox is starting (process #{pid}; log: ~/.cache/lepton/firefox.log).")
                0
            end

          {:error, reason} ->
            IO.err(ctx, "firefox: #{reason}; Firefox runs on the desktop")
            1
        end
    end
  end

  defcmd "open", "open files, folders and web addresses in the right app: text in le; images, PDFs, folders and pages in Firefox",
    usage: "open FILE|DIR|URL...", aliases: ["xdg-open"] do
    open(args, ctx)
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
        on = if st.card, do: " on #{st.card.name}", else: " (no sound card)"
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
    usage: "sound [list] | use N | use bluetooth | use auto | test" do
    case args do
      a when a in [[], ["list"]] ->
        st = Sound.status()

        if st.cards == [] do
          IO.puts(ctx, "No sound card. Add a sound device to the VM (UTM: Sound), or plug in USB audio.")
        else
          for c <- st.cards do
            mark = if st.card && st.card.id == c.id, do: "*", else: " "

            {n, vol} =
              cond do
                c[:type] == :bluetooth -> {"bt", "Bluetooth headphones"}
                c[:software] -> {c.index, "volume: #{c.master.name}"}
                true -> {c.index, "no volume control"}
              end

            IO.puts(ctx, "#{mark} #{String.pad_trailing(to_string(n), 2)} #{String.pad_trailing(c.name, 28)} #{vol}")
          end

          how = if st.chosen, do: "chosen with sound use", else: "the card added last"
          IO.puts(ctx, "(* plays sound: #{how})")
        end

        0

      ["use", "auto"] ->
        sound_result(ctx, Sound.use_card(nil))

      ["use", b] when b in ["bluetooth", "bt"] ->
        sound_result(ctx, Sound.use_card(:bluetooth))

      ["use", n] ->
        case Integer.parse(n) do
          {i, ""} -> sound_result(ctx, Sound.use_card(i))
          _ ->
            IO.err(ctx, "usage: sound use N | bluetooth | auto")
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
        IO.err(ctx, "usage: sound [list] | use N | use bluetooth | use auto | test")
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

  # -- open (xdg-open) ---------------------------------------------------------------------------

  @images ~w(.png .jpg .jpeg .gif .webp .svg .bmp .ico .avif)
  @text ~w(.txt .md .ex .exs .erl .hrl .sh .zsh .bash .toml .json .yml .yaml .xml .css .js .ts .py .rb .c .h .rs .go .conf .cfg .ini .log .csv .el .lisp .heex .eex)

  defp open([], ctx) do
    IO.err(ctx, "usage: open FILE|DIR|URL...")
    2
  end

  defp open(args, ctx) do
    case open_plan(args, ctx) do
      {:ok, %{browser: urls, editor: files}} ->
        status = if urls == [], do: 0, else: Lepton.Commands.invoke(elem(Lepton.Commands.lookup("firefox"), 1), urls, ctx)
        if files == [] or status != 0, do: status, else: edit(files, ctx)

      {:error, msg} ->
        IO.err(ctx, "open: " <> msg)
        1
    end
  end

  @doc false
  # What opens where: `{:ok, %{browser: [url], editor: [path]}}` or `{:error, message}`.
  def open_plan(args, ctx) do
    Enum.reduce_while(args, {:ok, %{browser: [], editor: []}}, fn arg, {:ok, plan} ->
      case open_kind(arg, Lepton.Ctx.path(ctx, arg)) do
        {:browser, url} -> {:cont, {:ok, %{plan | browser: plan.browser ++ [url]}}}
        {:editor, path} -> {:cont, {:ok, %{plan | editor: plan.editor ++ [path]}}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  @doc false
  def open_kind(arg, path) do
    cond do
      Regex.match?(~r/^(https?|file|ftp):/i, arg) -> {:browser, arg}
      File.dir?(path) -> {:browser, file_url(path <> "/")}
      not File.exists?(path) -> {:error, "#{arg}: no such file or directory"}
      true -> by_contents(arg, path)
    end
  end

  defp file_url(path), do: "file://" <> URI.encode(String.replace(path, ~r{/+}, "/"))

  defp by_contents(arg, path) do
    head = case File.open(path, [:read, :binary], &:file.read(&1, 8192)) do
      {:ok, {:ok, data}} -> data
      _ -> ""
    end

    ext = String.downcase(Path.extname(path))

    cond do
      match?("%PDF" <> _, head) or ext == ".pdf" -> {:browser, file_url(path)}
      image?(head) or ext in @images -> {:browser, file_url(path)}
      ext in @text or text?(head) -> {:editor, path}
      true -> {:error, "#{arg}: don't know what opens this kind of file"}
    end
  end

  defp image?(<<0x89, "PNG", _::binary>>), do: true
  defp image?(<<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  defp image?("GIF8" <> _), do: true
  defp image?(<<"RIFF", _::binary-4, "WEBP", _::binary>>), do: true
  defp image?("BM" <> _), do: true
  defp image?(_), do: false

  # UTF-8 with no NUL bytes (an empty file is text too). The 8 KiB read may cut a character short.
  defp text?(head), do: not String.contains?(head, <<0>>) and Enum.any?(0..3, &String.valid?(binary_part(head, 0, max(byte_size(head) - &1, 0))))

  # In the terminal: le, here. Without one (on the desktop): le in a terminal window.
  defp edit(files, ctx) do
    cond do
      ctx.tty ->
        Lepton.Commands.invoke(elem(Lepton.Commands.lookup("le"), 1), files, ctx)

      match?({:ok, _}, session_env(ctx)) ->
        {:ok, env} = session_env(ctx)
        command = Enum.map_join(["le" | files], " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))
        {:ok, _} = Term.start(env: env, user: ctx.user, cwd: ctx.cwd, command: command, title: "Text Editor")
        0

      true ->
        IO.err(ctx, "open: le needs a terminal (or the desktop)")
        1
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
            "#{Apps.version(name)} (#{length(pkgs)} packages, #{div(size, 1_000_000)} MB#{checked})#{ready}"

          nil ->
            "not installed"
        end

      IO.puts(ctx, "#{String.pad_trailing(name, 12)} #{String.pad_trailing(app.summary, 28)} #{status}")
    end

    0
  end

  defp app([cmd | _], ctx) when cmd in ~w(install reinstall update remove) and ctx.user != "root", do: Users.denied(ctx, "app #{cmd}")

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

  # Download and set up every package again (the profile in your home is kept).
  defp app(["reinstall", name], ctx) do
    cond do
      Apps.get(name) == nil ->
        IO.err(ctx, "app: no app called #{name} (apps: #{Enum.join(Apps.names(), ", ")})")
        1

      Apps.running?(name) ->
        IO.err(ctx, "app: #{name} is running: close it first")
        1

      true ->
        for u <- Users.list(), Apps.processes(name, u.uid) != [], do: Apps.clear_leftovers(name, u, u.home)
        File.rm_rf(Apps.staged_dir(name))

        case Apps.install(name, &IO.puts(ctx, &1)) do
          :ok ->
            IO.puts(ctx, "Reinstalled #{name} (#{Apps.version(name)}).")
            0

          {:error, reason} ->
            IO.err(ctx, "app: #{reason} (#{name} was left as it was)")
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
    IO.err(ctx, "usage: app [list] | install NAME | reinstall NAME | update [NAME] | remove NAME")
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

      opts[:vault] ->
        Lepton.Vault.App.start(env: env, user: ctx.user)

      args = opts[:bluetooth] ->
        Term.start(env: env, user: ctx.user, cwd: env["HOME"], command: bluetooth_command(args, Users.root?(ctx)), title: opts[:title] || "Bluetooth")

      app && Apps.installed?(app) ->
        Apps.maintain(app)
        clear_hung(app, ctx, env)
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
    admin_command(["wifi", "connect", ssid] ++ if(open?, do: [""], else: []), root?)
  end

  @doc false
  # The Bluetooth applet's commands: `bluetooth ...`, or installing it.
  def bluetooth_command(["install"], root?), do: admin_command(["app", "install", "bluetooth"], root?)
  def bluetooth_command(args, root?), do: admin_command(["bluetooth" | args], root?)

  # A command that changes the system, for a terminal of its own: with
  # sudo unless root, quoted for the shell; the window closes itself when
  # it worked, and waits for Enter when it didn't.
  defp admin_command(argv, root?) do
    quoted = Enum.map_join(argv, " ", &if(&1 =~ ~r/^[A-Za-z0-9_.:\/-]+$/, do: &1, else: "'" <> String.replace(&1, "'", "'\\''") <> "'"))
    "#{if root?, do: "", else: "sudo "}#{quoted} && sleep 2 || read -p 'Press Enter to close this window. ' answer"
  end

  # An app with programs still running but no window on the desktop is
  # hung, or was closed and didn't finish exiting (Firefox then refuses to
  # start: "already running"): stop what's left. One with a window is left
  # alone (Firefox opens another window in it).
  # An app's programs left without a window (the desktop went away under
  # them, or they hung), and for Firefox its session bus: stopped, so it
  # can start afresh. (Its bus would otherwise take the addresses `open`
  # passes on, to a Firefox nobody can see.)
  defp clear_hung(app, ctx, env) do
    user = Users.get(ctx.user)

    cond do
      user == nil or app_window?(app) ->
        0

      true ->
        stopped = if Apps.processes(app, user.uid) != [], do: Apps.clear_leftovers(app, user, env["HOME"] || "/root"), else: 0
        if Apps.get(app)[:bus], do: Apps.stop_session_bus(user, env)
        stopped
    end
  end

  defp app_window?(app), do: with(pid when is_pid(pid) <- Process.whereis(Photon), do: Enum.any?(Photon.info(pid).windows, &(&1.app_id == app)), else: (_ -> false))
  defp firefox_window?, do: app_window?("firefox")

  defp await_starting_firefox do
    now = System.monotonic_time(:millisecond)
    starting? = Enum.any?(Lepton.Proc.list(), &(&1.cmd == "firefox" and now - &1.started < 30_000))
    if starting? and not firefox_window?(), do: Enum.find(1..80, fn _ -> firefox_window?() || (Process.sleep(250) && false) end)
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

  # -- keyboard ------------------------------------------------------------------------------

  defp keyboard([], ctx) do
    kb = Lepton.Keyboard.state()

    for id <- kb.sources do
      mark = if id == kb.current, do: "*", else: " "
      extra = if id == "ko" and id == kb.current, do: if(kb.hangul, do: " (typing Hangul)", else: " (typing English)"), else: ""
      IO.puts(ctx, "#{mark} #{String.pad_trailing(id, 4)}#{Lepton.Keyboard.name(id)}#{extra}")
    end

    if length(kb.sources) > 1, do: IO.puts(ctx, "Super+Space: the next one.")
    if "ko" in kb.sources, do: IO.puts(ctx, "Korean: the Hangul key, Right Alt or Shift+Space switch between Hangul and English.")
    0
  end

  defp keyboard(["list"], ctx) do
    kb = Lepton.Keyboard.state()
    for {id, name} <- Lepton.Keyboard.known(), do: IO.puts(ctx, "#{if id in kb.sources, do: "+", else: " "} #{String.pad_trailing(id, 4)}#{name}")
    0
  end

  defp keyboard(["use", id], ctx), do: keyboard_result(Lepton.Keyboard.use(id), ctx)
  defp keyboard(["next"], ctx), do: keyboard_result(Lepton.Keyboard.next(), ctx)
  defp keyboard(["set" | ids], ctx) when ids != [], do: keyboard_result(Lepton.Keyboard.set_sources(ids), ctx)

  defp keyboard(["add" | ids], ctx) when ids != [],
    do: keyboard_result(Lepton.Keyboard.set_sources(Lepton.Keyboard.state().sources ++ ids), ctx)

  defp keyboard(["remove" | ids], ctx) when ids != [] do
    case Lepton.Keyboard.state().sources -- ids do
      [] -> keyboard_result({:error, "that would leave no input source"}, ctx)
      rest -> keyboard_result(Lepton.Keyboard.set_sources(rest), ctx)
    end
  end

  defp keyboard(_, ctx) do
    IO.err(ctx, "usage: keyboard [list] | use ID | next | add ID... | remove ID... | set ID...")
    2
  end

  defp keyboard_result({:ok, _}, ctx), do: keyboard([], ctx)

  defp keyboard_result({:error, msg}, ctx) do
    IO.err(ctx, "keyboard: " <> msg)
    1
  end
end
