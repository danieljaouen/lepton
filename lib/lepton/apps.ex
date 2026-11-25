defmodule Lepton.Apps do
  @moduledoc """
  Native apps: Linux programs from Alpine's packages, installed on demand
  and run under Photon (Wayland).

  An app is a set of Alpine packages unpacked into its own directory,
  `/var/lib/lepton/apps/NAME` (kept on the data partition of an installed
  system; in memory on the live ISO), plus the setup its packages'
  install scripts would have done (GSettings schemas, image loaders,
  fonts). It runs with its libraries on `LD_LIBRARY_PATH` and its data
  found through environment variables, so nothing outside its directory
  changes.

  Firefox is the one you open; Bluetooth and PostgreSQL are daemons
  Lepton runs (`Lepton.Bluetooth`, `Lepton.Postgres`). Firefox's packages leave out what a software-
  rendered browser in a VM doesn't load: Mesa and LLVM (GPU drawing).
  FFmpeg's decoders (libavcodec) are in: Firefox plays WebM and AV1 with
  its own, but H.264 and AAC (MP4 video: TikTok, LinkedIn, Instagram)
  only through FFmpeg. One package comes from Alpine 3.23: gdk-pixbuf,
  whose 3.24 build decodes images in sandboxed helper programs.
  """

  alias Lepton.Alpine

  @asian_fonts ~w(font-noto-cjk font-droid-nonlatin font-noto-bengali font-noto-khmer font-noto-lao font-noto-myanmar)

  @doc "The font packages Firefox gets for Asian scripts."
  def asian_fonts, do: @asian_fonts

  @apps %{
    "firefox" => %{
      title: "Firefox",
      summary: "the Firefox web browser",
      # dbus: the session bus a second start hands its addresses over (see session_bus/3).
      # Fonts: DejaVu for Latin, Greek and Cyrillic; Noto CJK for Chinese,
      # Japanese and Korean; Droid's non-Latin set for Thai, Devanagari,
      # Tamil, Arabic, Hebrew, Georgian, Armenian and Ethiopic; Noto for
      # Bengali, Khmer, Lao and Myanmar. Without one, a script shows as boxes.
      # gcompat: glibc's names over musl, for Widevine (the DRM plugin,
      # built for glibc, that `widevine install` gets from Google; Alpine's
      # Firefox preloads gcompat for it): Spotify, Netflix and the like.
      # xz: unpacks the Chrome package Widevine comes in (busybox's
      # decoder can't: it was packed with a 256 MB dictionary).
      packages: ["firefox", "font-dejavu", "icu-data-en", "dbus", "gcompat", "xz"] ++ @asian_fonts,
      # 3.24's gdk-pixbuf decodes images through glycin, whose loaders run
      # in a bubblewrap sandbox at fixed paths; 3.23's (2.44 too) has its own.
      pins: %{"gdk-pixbuf" => "v3.23"},
      # (FFmpeg's libavcodec is linked with its encoders' libraries too: they stay in.)
      exclude: ~r/^(mesa.*|llvm.*|spirv-.*|busybox.*|bubblewrap|pkgconf|libxshmfence|libxxf86vm|mkfontscale)$/,
      exe: "usr/lib/firefox/firefox",
      gtk: true,
      bus: true,
      # Where it keeps its files in the home (made the user's if root's).
      home: [".mozilla", ".config/mozilla", ".cache/mozilla", ".cache/fontconfig"]
    },
    # Not a program you open: the Bluetooth daemons Lepton.Bluetooth runs
    # (BlueZ's bluetoothd on a D-Bus system bus, and bluez-alsa for
    # headphones).
    "bluetooth" => %{
      title: "Bluetooth",
      summary: "Bluetooth (BlueZ, bluez-alsa)",
      packages: ["bluez", "bluez-alsa", "bluez-alsa-utils", "dbus"],
      exclude: ~r/^(busybox.*)$/,
      main: "bluez",
      exe: nil,
      gtk: false
    },
    # Not a program you open either: the database server Lepton.Postgres
    # runs as the postgresql service (and its tools: psql, pg_dump, ...).
    # Programs Mix runs (Lepton.MixVM puts them on its VM's PATH only): git,
    # for git dependencies (Phoenix's heroicons; Lepton's git is a command
    # of Lepton's, which another VM can't run), and inotifywait, for
    # Phoenix's live reload (file_system). In the shell, git is Lepton's.
    "mix-tools" => %{
      title: "Mix tools",
      summary: "git, inotifywait and tar, for Mix",
      # tar, xz and zstd: what Lepton's own build (`mix lepton.iso`, in a
      # checkout of Lepton) unpacks its sources with.
      packages: ["git", "inotify-tools", "tar", "xz", "zstd"],
      exclude: ~r/^(busybox.*)$/,
      main: "git",
      exe: nil,
      gtk: false
    },
    # Not a program you open: what Claude Code (Lepton.ClaudeCode, whose
    # binary is Anthropic's, downloaded on its own) needs from a Linux
    # system: bash for its Bash tool, ripgrep and git, util-linux's
    # script for a terminal, CA certificates for git over HTTPS.
    "claude-code" => %{
      title: "Claude Code's tools",
      summary: "bash, git, ripgrep and a terminal, for Claude Code",
      packages: ["bash", "git", "ripgrep", "util-linux-misc", "libgcc", "libstdc++", "ca-certificates-bundle"],
      exclude: ~r/^(busybox.*)$/,
      main: "bash",
      exe: nil,
      gtk: false
    },
    # QEMU, for virtual machines (Lepton.VM, `vm`; and `mix lepton.qemu`
    # in a checkout of Lepton): the arm64 emulator, qemu-img and UEFI
    # firmware (AAVMF). Not a program you open: machines run headless, on
    # their serial consoles.
    "qemu" => %{
      title: "QEMU",
      summary: "QEMU, for virtual machines",
      packages: ["qemu-system-aarch64", "qemu-img", "aavmf"],
      exclude: ~r/^(busybox.*)$/,
      main: "qemu-system-aarch64",
      exe: nil,
      gtk: false
    },
    # Not a program you open: FFmpeg, which decodes what the media player
    # (`play`) and the radio (`radio`) play; Lepton plays the sound
    # (Lepton.Sound) and draws the pictures (Lepton.Player.Window) itself.
    # Mesa's drivers and LLVM stay out (ffmpeg needs neither; mpv, which
    # links Mesa and through it LLVM, would have been 250 MB more).
    "ffmpeg" => %{
      title: "FFmpeg",
      summary: "FFmpeg, for the media player and the radio",
      packages: ["ffmpeg"],
      exclude: ~r/^(mesa-dri.*|mesa-vulkan.*|llvm.*|busybox.*|wireplumber.*|bluez.*)$/,
      main: "ffmpeg",
      exe: nil,
      gtk: false
    },
    # Typst, the typesetting system (`typst compile paper.typ`): the
    # command line program, run by Lepton's `typst` (Lepton.Typst). CA
    # certificates: it fetches packages (`@preview/...`) over HTTPS.
    "typst" => %{
      title: "Typst",
      summary: "Typst, the typesetting system (typst compile, watch, fonts)",
      packages: ["typst", "ca-certificates-bundle"],
      exclude: ~r/^(busybox.*)$/,
      main: "typst",
      exe: nil,
      gtk: false
    },
    # ImageMagick 7 (`magick`, `convert`, `identify`, ...; Lepton.ImageMagick):
    # the formats most images come in (Alpine splits them into modules),
    # SVG (librsvg) and PDF and PostScript (Ghostscript, which ImageMagick
    # runs as `gs`: 60 MB of the 140). DejaVu: for text drawn on images.
    "imagemagick" => %{
      title: "ImageMagick",
      summary: "ImageMagick, for magick, convert, identify and mogrify",
      packages: ~w(imagemagick imagemagick-jpeg imagemagick-webp imagemagick-tiff imagemagick-heic imagemagick-jxl imagemagick-jp2 imagemagick-svg imagemagick-pdf ghostscript font-dejavu),
      exclude: ~r/^(busybox.*)$/,
      main: "imagemagick",
      exe: nil,
      gtk: false
    },
    # xz and zstd, for tar's .tar.xz and .tar.zst (Lepton.Archive.Compress;
    # gzip is Lepton's own, bzip2 and reading xz busybox's).
    "compressors" => %{
      title: "Compressors",
      summary: "xz and zstd, for tar's .tar.xz and .tar.zst",
      packages: ["xz", "zstd"],
      exclude: ~r/^(busybox.*)$/,
      main: "xz",
      exe: nil,
      gtk: false
    },
    # The SNES emulator (`snes`, Lepton.SNES): bsnes as a libretro core,
    # and the Tiny C Compiler with musl's headers, which build the small
    # frontend Lepton runs it with (lepton-snes). Lepton draws the
    # pictures and plays the sound itself, as for the media player.
    "snes" => %{
      title: "SNES",
      summary: "the SNES emulator (bsnes), for snes",
      # alsa-lib: the frontend plays its sound through ALSA's mixer.
      packages: ["libretro-bsnes", "tcc", "tcc-libs", "tcc-libs-static", "musl-dev", "alsa-lib"],
      exclude: ~r/^(busybox.*|pkgconf)$/,
      main: "libretro-bsnes",
      exe: nil,
      gtk: false
    },
    "postgresql" => %{
      title: "PostgreSQL",
      summary: "the PostgreSQL database",
      packages: ["postgresql18", "postgresql18-client", "postgresql18-contrib"],
      exclude: ~r/^(busybox.*)$/,
      main: "postgresql18",
      exe: nil,
      gtk: false
    }
  }

  def names, do: Map.keys(@apps) |> Enum.sort()

  @doc """
  An app something needs isn't installed: in a terminal, ask whether to
  install it now (`sudo app install NAME`, which asks for your password),
  else say how. `what` says what it's for ("FFmpeg plays videos and
  music"). Returns `:installed`, `:declined` or `:missing` (no terminal,
  or the install failed). The desktop's apps open in a terminal, so
  clicking one is enough.
  """
  def offer_install(ctx, name, what) do
    tty = ctx.tty
    title = get(name).title

    if tty && is_pid(tty) && Process.alive?(tty) do
      Lepton.IO.puts(ctx, "#{what}, and #{title} isn't installed yet (#{get(name).summary}).")
      Lepton.TTY.set_mode(tty, :raw)
      Lepton.TTY.write(tty, "Install it now? (y/n) ")
      key = Lepton.TTY.read_key(tty)
      Lepton.TTY.set_mode(tty, :cooked)
      Lepton.TTY.write(tty, "\r\n")

      if key in ["y", "Y", "RET"] do
        {cmd, args} = if ctx.user in [nil, "root"], do: {"app", ["install", name]}, else: {"sudo", ["app", "install", name]}
        status = Lepton.Shell.Exec.exec(cmd, args, %Lepton.Shell{ctx: ctx})
        if status == 0 and installed?(name), do: :installed, else: :missing
      else
        Lepton.IO.puts(ctx, "Not installed. (Later: sudo app install #{name})")
        :declined
      end
    else
      Lepton.IO.err(ctx, "#{title} isn't installed. Install it with: sudo app install #{name}")
      :missing
    end
  end
  def get(name), do: Map.get(@apps, name)

  def root, do: Path.join(Lepton.Persist.state_dir(), "apps")
  def dir(name), do: Path.join(root(), name)
  def installed?(name), do: File.exists?(Path.join(dir(name), ".lepton-app"))

  @doc "What is installed: `%{packages: [{name, version}], size: bytes, branch: branch}`, or nil."
  def info(name), do: read_record(dir(name))

  @doc """
  Install app `name`: resolve its packages, download and unpack them, set
  them up. `say` reports progress (a function of a string).
  """
  def install(name, say \\ fn _ -> :ok end) do
    with {:ok, _} <- stage(name, say, force: true) do
      say.("Setting up...")
      apply_staged(name)
    end
  end

  def remove(name) do
    if installed?(name) do
      if name == "postgresql", do: Lepton.Postgres.unlink_tools()
      if name == "claude-code", do: File.rm_rf(Lepton.ClaudeCode.dir())
      File.rm_rf(dir(name))
      File.rm_rf(staged_dir(name))
      File.rm(checked_file(name))
      :ok
    else
      {:error, "#{name} is not installed"}
    end
  end

  # -- updates ----------------------------------------------------------------------------------------
  #
  # Alpine rebuilds Firefox for each release (every four weeks, more often
  # for security fixes). Starting an app checks for a newer build every
  # 10 days and downloads it beside the installed one ("staged"); the
  # next start, with the app not running, swaps it in. `app update` does
  # both at once.

  @check_every 10 * 24 * 60 * 60

  def staged_dir(name), do: dir(name) <> ".staged"
  def staged?(name), do: File.exists?(Path.join(staged_dir(name), ".lepton-app"))
  defp checked_file(name), do: Path.join(root(), name <> ".checked")

  @doc "When app `name` was last checked for updates (Unix seconds), or nil."
  def checked_at(name) do
    case File.read(checked_file(name)) do
      {:ok, text} -> text |> String.trim() |> Integer.parse() |> then(fn {n, _} -> n; :error -> nil end)
      _ -> nil
    end
  end

  @doc "Is a check for updates due (none yet, or the last 10 or more days ago)?"
  def check_due?(name, now \\ System.os_time(:second)) do
    case checked_at(name) do
      nil -> true
      t -> now - t >= @check_every
    end
  end

  @doc "The packages that differ between two package lists: `[{name, old_version | nil, new_version | nil}]`."
  def changes(old, new) do
    old = Map.new(old)
    new = Map.new(new)

    for name <- Enum.sort(Enum.uniq(Map.keys(old) ++ Map.keys(new))), old[name] != new[name], do: {name, old[name], new[name]}
  end

  @doc """
  Download app `name`'s current packages into its staging directory if
  they differ from what is installed (or always, with `force: true`).
  Returns `{:ok, :current}` or `{:ok, {:staged, changes}}`. `index:`
  supplies the package index (tests).
  """
  def stage(name, say \\ fn _ -> :ok end, opts \\ []) do
    with %{} = app <- get(name) || {:error, "no app called #{name} (apps: #{Enum.join(names(), ", ")})"},
         _ = say.("Reading the Alpine #{Alpine.branch()} package index..."),
         {:ok, index} <- if(opts[:index], do: {:ok, opts[:index]}, else: Alpine.index()),
         {:ok, index} <- if(opts[:index], do: {:ok, index}, else: Alpine.pin(index, Map.get(app, :pins, %{}))),
         {:ok, pkgs} <- Alpine.resolve(index, app.packages, app.exclude) do
      File.mkdir_p!(root())
      File.write!(checked_file(name), Integer.to_string(System.os_time(:second)))
      versions = Enum.map(pkgs, &{&1.name, &1.version})
      changes = changes((info(name) || %{packages: []}).packages, versions)

      cond do
        changes == [] and !opts[:force] ->
          # (a definition that changes nothing: recorded, so it isn't checked again)
          if redefined?(name), do: write_record(dir(name), Map.put(info(name), :definition, definition(app)))
          {:ok, :current}

        staged?(name) and changes(staged_info(name).packages, versions) == [] and !opts[:force] ->
          {:ok, {:staged, changes}}

        true ->
          download(app, name, pkgs, versions, say) |> then(&if(&1 == :ok, do: {:ok, {:staged, changes}}, else: &1))
      end
    else
      {:error, {:unresolved, dep}} -> {:error, "cannot resolve #{dep}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp download(app, name, pkgs, versions, say) do
    total = Enum.sum(Enum.map(pkgs, & &1.size))
    installed = Enum.sum(Enum.map(pkgs, & &1.installed_size))
    say.("#{app.title}: #{length(pkgs)} packages, #{mb(total)} to download, #{mb(installed)} installed.")
    staged = staged_dir(name)
    File.rm_rf!(staged)

    result =
      pkgs
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {pkg, i}, :ok ->
        say.("[#{i}/#{length(pkgs)}] #{pkg.name} #{pkg.version} (#{mb(pkg.size)})")

        case Alpine.install(pkg, staged) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "#{pkg.name}: #{inspect(reason)}"}}
        end
      end)

    case result do
      :ok ->
        # The record is written last: a staging directory without one is incomplete.
        write_record(staged, %{packages: versions, size: installed, branch: Alpine.branch(), definition: definition(app)})

      err ->
        File.rm_rf(staged)
        err
    end
  end

  defp staged_info(name), do: read_record(staged_dir(name))
  defp write_record(dir, record), do: File.write(Path.join(dir, ".lepton-app"), Base.encode64(:erlang.term_to_binary(record)))

  defp read_record(dir) do
    case File.read(Path.join(dir, ".lepton-app")) do
      {:ok, text} -> :erlang.binary_to_term(Base.decode64!(text))
      _ -> nil
    end
  end

  @doc """
  Swap a staged version of app `name` in and set it up; the old one comes
  back if setup fails. `:none` when nothing is staged. Not while the app
  runs (callers check `running?/1`).
  """
  def apply_staged(name, setup \\ &setup/2) do
    if staged?(name) do
      old = dir(name) <> ".old"
      File.rm_rf!(old)
      had_old = File.dir?(dir(name))
      if had_old, do: :ok = File.rename(dir(name), old)
      :ok = File.rename(staged_dir(name), dir(name))

      # Setup writes absolute paths (loader caches, fonts.conf): it runs in place.
      case setup.(name, dir(name)) do
        :ok ->
          File.rm_rf(old)
          :ok

        err ->
          File.rm_rf(dir(name))
          if had_old, do: File.rename(old, dir(name))
          err
      end
    else
      :none
    end
  end

  @doc "Is app `name` running (a Lepton process of that name)?"
  def running?(name), do: Enum.any?(Lepton.Proc.list(), &(&1.cmd == name))

  @doc """
  The app's programs running as `uid` (`:any`: anyone's), from `/proc`:
  their executable is in the app's directory. Firefox's content
  processes are among them.
  """
  def processes(name, uid) do
    prefix = dir(name) <> "/"

    for entry <- Path.wildcard("/proc/[0-9]*"),
        {:ok, exe} <- [File.read_link(Path.join(entry, "exe"))],
        String.starts_with?(exe, prefix),
        {:ok, status} <- [File.read(Path.join(entry, "status"))],
        [_, owner] <- [Regex.run(~r/^Uid:\s+(\d+)/m, status)],
        uid == :any or String.to_integer(owner) == uid,
        do: String.to_integer(Path.basename(entry))
  end

  @doc """
  Stop the apps that are open (Firefox) and wait for them to finish, up
  to `timeout` ms (then they are killed). Done at power-off and reboot,
  before the disk is flushed and made read-only, so nothing is cut off
  halfway through a write. Firefox's tabs aren't lost: it saves its
  session every few seconds and opens it again when it starts (see
  `firefox_policies/1`). Firefox takes SIGTERM as a crash, not as Quit:
  it exits at once, and the session it saved last is the one restored.
  Each app's main program gets SIGTERM (its helpers end with it).
  Returns how many main programs were stopped.
  """
  def quit_all(timeout \\ 15_000) do
    names = for {name, %{gtk: true}} <- @apps, do: name
    running = fn -> Enum.flat_map(names, &processes(&1, :any)) end
    mains = main_programs(Map.new(running.(), &{&1, parent(&1)}))
    for pid <- mains, do: Lepton.Sys.shim("kill", ["-TERM", to_string(pid)])
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> running.() == [] || (Process.sleep(100) && false) end)
    |> Enum.find(fn done -> done || System.monotonic_time(:millisecond) > deadline end)

    for pid <- running.(), do: Lepton.Sys.shim("kill", ["-KILL", to_string(pid)])
    length(mains)
  end

  @doc """
  The main programs among an app's processes (`%{pid => parent pid}`):
  those whose parent isn't one of them. (Firefox's helpers can't be told
  by their command lines: they write over them.)
  """
  def main_programs(parents), do: for({pid, ppid} <- parents, not Map.has_key?(parents, ppid), do: pid) |> Enum.sort()

  defp parent(pid) do
    with {:ok, status} <- File.read("/proc/#{pid}/status"),
         [_, ppid] <- Regex.run(~r/^PPid:\s+(\d+)/m, status) do
      String.to_integer(ppid)
    else
      _ -> nil
    end
  end

  @doc """
  Stop an app's programs that were left behind (hung, or with no window
  any more) and the locks they leave in its profile, so it can start
  again. Returns how many were stopped.
  """
  def clear_leftovers(name, %Lepton.Users{uid: uid}, home) do
    pids = processes(name, uid)
    for pid <- pids, do: Lepton.Sys.shim("kill", ["-9", to_string(pid)])
    # Gone before anything starts again (a dying Firefox still holds its profile and bus name).
    Enum.find(1..30, fn _ -> processes(name, uid) == [] || (Process.sleep(100) && false) end)

    # Firefox's profile locks: a symlink and a lock file.
    for lock <- Path.wildcard(Path.join(home, ".mozilla/firefox/*/{lock,.parentlock}"), match_dot: true), do: File.rm(lock)
    length(pids)
  end

  @doc """
  What starting an app does about updates: apply a staged one (if the app
  isn't running), and, when a check is due, look for a newer build in the
  background. Returns what was applied: `{:updated, version}` or `:none`.
  """
  def maintain(name) do
    applied =
      if staged?(name) and not running?(name) do
        version = staged_info(name).packages |> List.keyfind(main(name), 0) |> then(&(&1 && elem(&1, 1)))
        if apply_staged(name) == :ok, do: {:updated, version}, else: :none
      else
        :none
      end

    if check_due?(name) or redefined?(name), do: Lepton.Proc.spawn("#{name}-update", [], fn _ -> stage(name) end)
    applied
  end

  @doc """
  Was app `name` installed from a different definition (packages, pins,
  exclusions) than Lepton's now? Then it is updated without waiting for
  the 10 days: a package Lepton added comes with the next start.
  """
  def redefined?(name) do
    case {info(name), get(name)} do
      {%{} = record, %{} = app} -> record[:definition] != definition(app)
      _ -> false
    end
  end

  defp definition(app), do: :erlang.phash2({app.packages, Map.get(app, :pins, %{}), Regex.source(Map.get(app, :exclude, ~r/^$/))})

  @doc "The installed version of app `name`'s main package."
  def version(name) do
    with %{packages: pkgs} <- info(name), {_, v} <- List.keyfind(pkgs, main(name), 0), do: v, else: (_ -> nil)
  end

  # The package an app's version is (Firefox's is firefox; Bluetooth's, bluez).
  defp main(name), do: (get(name) || %{})[:main] || name

  # Sizes as macOS's Finder shows them: decimal megabytes.
  defp mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  # -- setup: what the packages' install triggers would do ---------------------------------------------

  defp setup("postgresql", _prefix), do: Lepton.Postgres.prepare()

  defp setup(name, prefix) do
    if get(name)[:gtk], do: setup_gtk(prefix), else: :ok
  end

  defp setup_gtk(prefix) do
    env = env(prefix, %{})

    with :ok <- run(prefix, "usr/bin/glib-compile-schemas", [Path.join(prefix, "usr/share/glib-2.0/schemas")], env),
         # The MIME database: how GIO (and so gdk-pixbuf) tells a PNG from a JPEG.
         :ok <- run(prefix, "usr/bin/update-mime-database", [Path.join(prefix, "usr/share/mime")], env),
         :ok <- pixbuf_loaders(prefix, env),
         :ok <- im_modules(prefix, env),
         :ok <- fonts_conf(prefix) do
      firefox_policies(prefix)
    end
  end

  @doc """
  Write Firefox's `policies.json` under `prefix` (when Firefox is there):
  Photon draws the title bar, so Firefox uses it rather than drawing its
  own buttons in the tab strip; it doesn't ask to be the default; it
  unloads background tabs when memory runs short (at 10% available,
  before `Lepton.Memory` steps in at 5%); and it doesn't use OpenH264. Firefox downloads that video plugin itself, and
  Mozilla's aarch64 build of it needs glibc: on Lepton (musl) it crashes
  ("gmpopenh264 crashed") as soon as a page uses H.264, in WebRTC calls
  for example. Speech synthesis (the Web Speech API's `speechSynthesis`)
  is off: Firefox speaks through Speech Dispatcher, which Lepton doesn't
  have, so a page that used it got "You can't use speech synthesis
  because the Speech Dispatcher library is missing". With it off, pages
  don't see the API and don't try. And it opens the previous session's
  windows and tabs when it starts, without asking even after power-off
  or reboot ended it (`quit_all/1`), from a session it saves every 5
  seconds.
  """
  def firefox_policies(prefix) do
    dir = Path.join(prefix, "usr/lib/firefox/distribution")

    if File.dir?(dir) do
      policies = %{
        "policies" => %{
          "DontCheckDefaultBrowser" => true,
          # Magnet links and .torrent files: to Lepton's Torrents, without
          # asking (the helper runs `torrent open`).
          "Handlers" => torrent_handlers(),
          # DRM (Widevine) on, without asking: Spotify's web player and
          # other streaming sites need it.
          "EncryptedMediaExtensions" => %{"Enabled" => true},
          "Preferences" => %{
            "browser.tabs.inTitlebar" => %{"Value" => 0, "Status" => "default"},
            "media.gmp-gmpopenh264.enabled" => %{"Value" => false, "Status" => "locked"},
            "media.gmp-gmpopenh264.autoupdate" => %{"Value" => false, "Status" => "locked"},
            "media.webspeech.synth.enabled" => %{"Value" => false, "Status" => "locked"},
            # Open the last session's windows and tabs (Settings > General
            # > "Open previous windows and tabs" can turn it off).
            "browser.startup.page" => %{"Value" => 3, "Status" => "default"},
            # Lepton's power-off ends Firefox (SIGTERM, which it takes as a
            # crash): restore without asking (-1: not even after several
            # in a row, or after six hours off), from a session saved
            # every 5 seconds rather than 15.
            "browser.sessionstore.resume_from_crash" => %{"Value" => true, "Status" => "default"},
            "browser.sessionstore.max_resumed_crashes" => %{"Value" => -1, "Status" => "default"},
            "browser.sessionstore.interval" => %{"Value" => 5000, "Status" => "default"},
            "browser.tabs.unloadOnLowMemory" => %{"Value" => true, "Status" => "default"},
            "browser.low_commit_space_threshold_percent" => %{"Value" => 10, "Status" => "default"}
          }
          # Widevine, once `widevine install` has put it in (Lepton.Widevine).
          |> Map.merge(Map.new(Lepton.Widevine.prefs(), fn {k, v} -> {k, %{"Value" => v, "Status" => "default"}} end))
        }
      }

      File.write(Path.join(dir, "policies.json"), JSON.encode!(policies))
    else
      :ok
    end
  end

  @open_torrent "/usr/libexec/lepton/open-torrent"

  @doc false
  # Firefox's Handlers policy: magnet: links and application/x-bittorrent
  # files go to the helper, which adds them to Torrents.
  def torrent_handlers do
    handler = %{"action" => "useHelperApp", "ask" => false, "handlers" => [%{"name" => "Torrents", "path" => @open_torrent}]}

    %{
      "schemes" => %{"magnet" => handler},
      "mimeTypes" => %{"application/x-bittorrent" => handler},
      "extensions" => %{"torrent" => handler}
    }
  end

  @doc """
  GTK's input-method modules, through a cache file like gdk-pixbuf's
  loaders: only `wayland`, which takes composed text (Korean) from
  Photon over text-input v3, and falls back to GTK's own compose and
  dead keys. Made at setup, and at launch for apps installed before.
  """
  def im_modules(prefix, env) do
    {dir, cache} = im_paths(prefix)
    module = Path.join(dir, "im-wayland.so")

    cond do
      not File.exists?(module) -> :ok
      File.exists?(cache) -> :ok
      true ->
        case native(Path.join(prefix, "usr/bin/gtk-query-immodules-3.0"), [module], env) do
          {out, 0} -> File.write(cache, out)
          {out, status} -> {:error, "gtk-query-immodules-3.0 failed (#{status}): #{String.slice(out, 0, 300)}"}
        end
    end
  end

  defp im_paths(prefix) do
    base = Path.join(prefix, "usr/lib/gtk-3.0/3.0.0")
    {Path.join(base, "immodules"), Path.join(base, "immodules.cache")}
  end

  # gdk-pixbuf finds its image loaders (PNG, SVG, ...) through a cache file.
  defp pixbuf_loaders(prefix, env) do
    case Path.wildcard(Path.join(prefix, "usr/lib/gdk-pixbuf-2.0/*/loaders")) do
      [dir | _] ->
        loaders = Path.wildcard(Path.join(dir, "*.so"))

        case native(Path.join(prefix, "usr/bin/gdk-pixbuf-query-loaders"), loaders, env) do
          {out, 0} -> File.write(Path.join(Path.dirname(dir), "loaders.cache"), out)
          {out, status} -> {:error, "gdk-pixbuf-query-loaders failed (#{status}): #{String.slice(out, 0, 300)}"}
        end

      [] ->
        :ok
    end
  end

  @doc false
  def fonts_conf(prefix) do
    conf = """
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>#{prefix}/usr/share/fonts</dir>
      <cachedir prefix="xdg">fontconfig</cachedir>
      <include ignore_missing="yes">#{prefix}/etc/fonts/conf.d</include>
      <!-- Droid's CJK fallbacks (Chinese glyph shapes for Japanese, poorly
           spaced Hangul): Noto CJK covers all they do, and better. -->
      <selectfont>
        <rejectfont>
          <glob>*/DroidSansFallback*</glob>
          <glob>*/DroidSansJapanese*</glob>
        </rejectfont>
      </selectfont>
    </fontconfig>
    """

    File.mkdir_p!(Path.join(prefix, "etc/fonts"))
    File.write(Path.join(prefix, "etc/fonts/lepton.conf"), conf)
  end

  defp run(prefix, exe, args, env) do
    case native(Path.join(prefix, exe), args, env) do
      {_, 0} -> :ok
      {out, status} -> {:error, "#{Path.basename(exe)} failed (#{status}): #{String.slice(out, 0, 300)}"}
    end
  end

  defp native(exe, args, env) do
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, env: charlists(env)])
    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, [acc, d])
      {^port, {:exit_status, s}} -> {IO.iodata_to_binary(acc), s}
    end
  end

  defp charlists(env), do: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

  # -- running ----------------------------------------------------------------------------------------

  @doc """
  The environment an app runs in: its libraries, its data, and, for
  Firefox, Wayland and software rendering.
  """
  def env(prefix, base) do
    lib = Enum.map_join(["usr/lib/firefox", "usr/lib", "lib"], ":", &Path.join(prefix, &1))
    icu = Path.wildcard(Path.join(prefix, "usr/share/icu/*")) |> List.first()

    base
    |> Map.merge(%{
      "LD_LIBRARY_PATH" => lib,
      "XDG_DATA_DIRS" => Path.join(prefix, "usr/share"),
      "GSETTINGS_SCHEMA_DIR" => Path.join(prefix, "usr/share/glib-2.0/schemas"),
      "GSETTINGS_BACKEND" => "memory",
      "GDK_PIXBUF_MODULE_FILE" => Path.wildcard(Path.join(prefix, "usr/lib/gdk-pixbuf-2.0/*/loaders.cache")) |> List.first() |> to_string(),
      "FONTCONFIG_FILE" => Path.join(prefix, "etc/fonts/lepton.conf"),
      "GTK_IM_MODULE_FILE" => elem(im_paths(prefix), 1),
      "GTK_IM_MODULE" => "wayland",
      "XKB_CONFIG_ROOT" => Path.join(prefix, "usr/share/X11/xkb"),
      "GDK_BACKEND" => "wayland",
      "MOZ_ENABLE_WAYLAND" => "1",
      "MOZ_CRASHREPORTER_DISABLE" => "1",
      "LIBGL_ALWAYS_SOFTWARE" => "1",
      "NO_AT_BRIDGE" => "1",
      "LANG" => base["LANG"] || "C.UTF-8"
    })
    |> then(&if(icu, do: Map.put(&1, "ICU_DATA", icu), else: &1))
  end

  @doc """
  Start app `name` with `args` in a Lepton process of its own, as the
  user `ctx` runs as (call `maintain/1` first for updates); its output
  goes to `~/.cache/lepton/NAME.log`. `ctx` gives the environment
  (`WAYLAND_DISPLAY`, `HOME`). Returns `{:ok, lepton_pid}`.
  """
  def launch(name, args, ctx) do
    prefix = dir(name)
    app = get(name)
    home = ctx.env["HOME"] || "/root"
    user = Lepton.Users.get(ctx.user) || Lepton.Users.get("root")
    log = Path.join([home, ".cache", "lepton", name <> ".log"])
    File.mkdir_p!(Path.dirname(log))
    prepare_home(home, user, app)
    # The proxy, if any, through Lepton's forwarder (Firefox reads http_proxy & co.).
    env = env(prefix, ctx.env) |> Map.put("HOME", home) |> Map.merge(alsa_env(prefix)) |> bluetooth_libs(name) |> Map.merge(Lepton.Proxy.app_env(ctx.env)) |> Map.merge(if(name == "firefox", do: Lepton.Widevine.env(), else: %{}))
    if Lepton.Sys.native?(), do: musl_path(prefix)
    # Firefox installed before a policy (or the input-method cache) was added gets it too.
    firefox_policies(prefix)
    if app[:gtk], do: im_modules(prefix, env)
    bus = if app[:bus], do: session_bus(name, user, ctx.env)
    env = if bus, do: Map.put(env, "DBUS_SESSION_BUS_ADDRESS", "unix:path=" <> bus.path), else: env
    # As the user, not as root (the VM's own user): see Lepton.RunAs.
    {exe, argv} = Lepton.RunAs.command(user, Path.join(prefix, app.exe), args)

    {lpid, _beam} =
      Lepton.Proc.spawn(name, [], fn _pid ->
        {:ok, out} = File.open(log, [:write, :binary])
        own(log, user)
        daemon = if bus && bus.start, do: start_bus(bus, user, home)
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: home, env: charlists(env)])
        status = relay(port, out)
        if daemon, do: stop_bus(daemon, bus)
        status
      end)

    {:ok, lpid}
  end

  @doc """
  The directory of busybox's applets (`sed`, `basename`, `ls`, ...) for
  native programs, last on their PATH: Alpine's programs are shell
  scripts at times (git's submodule command), which expect them. Made
  when first needed (`applets/0`).
  """
  def applets_dir, do: "/run/lepton/busybox"

  @doc "Make the applets directory (once), and return it."
  def applets do
    dir = applets_dir()

    if Lepton.Sys.native?() and not File.dir?(dir) do
      File.mkdir_p!(dir)

      case System.cmd("/bin/busybox", ["--list"], stderr_to_stdout: true) do
        {out, 0} -> for a <- String.split(out, "\n", trim: true), a not in ["sh", "env"], do: File.ln_s("/bin/busybox", Path.join(dir, a))
        _ -> :ok
      end
    end

    dir
  end

  @musl_path "/etc/ld-musl-aarch64.path"

  @doc """
  Add the app's library folders to musl's own search path (`#{@musl_path}`),
  after the system's. `LD_LIBRARY_PATH` alone isn't enough: Firefox names
  its content processes ("Web Content") by writing over the memory that
  held the environment, where musl's loader still reads
  `LD_LIBRARY_PATH`, so the libraries those processes load later (NSS's
  softoken needs libsqlite3, and without it every `crypto.subtle` call
  fails, and sign-in pages with them) were not found.
  """
  def musl_path(prefix, file \\ @musl_path) do
    have = case File.read(file) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end

    want = Enum.uniq(have ++ Enum.map(["usr/lib", "lib"], &Path.join(prefix, &1)))
    if want != have, do: File.write(file, Enum.join(want, "\n") <> "\n"), else: :ok
  end

  @doc """
  What a native program of the app in `prefix` (with alsa-lib) needs to
  play through ALSA's `default`, as Firefox does: the mixer, at the
  system volume, or Bluetooth headphones. Merged into `env`.
  """
  def sound_env(env, prefix) do
    env
    |> Map.merge(alsa_env(prefix))
    |> Map.put_new("LD_LIBRARY_PATH", Path.join(prefix, "usr/lib"))
    |> bluetooth_libs(nil)
  end

  # Sound through alsa-lib (Firefox): its own configuration files, then
  # Lepton's, which sends the default device to the default card at the
  # system volume (Lepton.Sound.alsa_config/0).
  defp alsa_env(prefix) do
    alsa = Path.join(prefix, "usr/share/alsa")
    conf = "/run/lepton/asound.conf"
    File.mkdir_p("/run/lepton")
    File.write(conf, Lepton.Sound.alsa_config())
    %{"ALSA_CONFIG_DIR" => alsa, "ALSA_CONFIG_PATH" => Path.join(alsa, "alsa.conf") <> ":" <> conf}
  end

  # Bluetooth headphones play through bluez-alsa's ALSA plugin, whose
  # libraries are the Bluetooth app's: found after the app's own.
  defp bluetooth_libs(env, name) do
    if name != "bluetooth" and installed?("bluetooth"),
      do: Map.update!(env, "LD_LIBRARY_PATH", &(&1 <> ":" <> Lepton.Bluetooth.env()["LD_LIBRARY_PATH"])),
      else: env
  end

  @doc """
  Make the parts of `home` an app writes the user's: `.cache` and
  `.config` (and Lepton's log folder), and the app's own folders when a
  program running as root made them root's.
  """
  def prepare_home(home, %Lepton.Users{uid: uid} = user, app) when uid != 0 do
    for dir <- [".cache", ".cache/lepton", ".config"], path = Path.join(home, dir) do
      File.mkdir_p(path)
      if root_owned?(path), do: own(path, user)
    end

    for dir <- Map.get(app, :home, []), path = Path.join(home, dir), root_owned?(path) do
      for p <- [path | Path.wildcard(Path.join(path, "**"), match_dot: true)], do: own(p, user)
    end

    :ok
  end

  def prepare_home(_home, _user, _app), do: :ok

  defp root_owned?(path), do: match?({:ok, %File.Stat{uid: 0}}, File.lstat(path))

  defp own(path, %Lepton.Users{uid: uid, gid: gid}) do
    File.chown(path, uid)
    File.chgrp(path, gid)
  end

  # -- the session bus ---------------------------------------------------------------------------

  @doc """
  The D-Bus session bus for app `name` run by `user`, at
  `$XDG_RUNTIME_DIR/bus`. Firefox on Wayland passes a second start's
  addresses to the one already running over it (its only way to: without a
  bus, the second start finds the profile in use and says Firefox is
  already running), so each `firefox URL` (and `open`) is a new tab.

  `%{path: socket, start: false}` when one is listening already, `%{path:
  socket, start: true, exe: dbus-daemon, env: env}` when the app's start
  must run it, and nil without a `dbus-daemon` (an app installed before it
  came with Firefox: the next update brings it).
  """
  def session_bus(name, %Lepton.Users{} = user, env) do
    dir = env["XDG_RUNTIME_DIR"] || "/run/user/#{user.uid}"
    path = Path.join(dir, "bus")

    daemon =
      Enum.find_value([name, "bluetooth"], fn app ->
        exe = Path.join(dir(app), "usr/bin/dbus-daemon")
        if File.exists?(exe), do: {exe, dir(app)}
      end)

    cond do
      bus_listening?(path) -> %{path: path, start: false}
      daemon -> %{path: path, start: true, exe: elem(daemon, 0), env: %{"LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(elem(daemon, 1), &1))}}
      true -> nil
    end
  end

  def session_bus(_name, _user, _env), do: nil

  @doc """
  Stop `user`'s session bus (a `dbus-daemon` with Lepton's session
  configuration in the runtime directory, whichever app's it is) and
  remove its socket. For a bus left behind by a Firefox that is gone.
  """
  def stop_session_bus(%Lepton.Users{uid: uid} = user, env) do
    dir = env["XDG_RUNTIME_DIR"] || "/run/user/#{uid}"
    conf = Path.join(dir, "dbus-session.conf")

    pids =
      for entry <- Path.wildcard("/proc/[0-9]*"),
          {:ok, cmdline} <- [File.read(Path.join(entry, "cmdline"))],
          String.contains?(cmdline, "--config-file=" <> conf),
          {:ok, status} <- [File.read(Path.join(entry, "status"))],
          [_, owner] <- [Regex.run(~r/^Uid:\s+(\d+)/m, status)],
          String.to_integer(owner) == user.uid,
          do: Path.basename(entry)

    for pid <- pids, do: Lepton.Sys.shim("kill", ["-9", pid])
    File.rm(Path.join(dir, "bus"))
    length(pids)
  end

  @doc "Is a bus answering on the socket at `path`?"
  def bus_listening?(path) do
    with {:ok, sock} <- :socket.open(:local, :stream, :default) do
      result = :socket.connect(sock, %{family: :local, path: path}) == :ok
      :socket.close(sock)
      result
    else
      _ -> false
    end
  end

  # dbus-daemon as the user, with a session bus's configuration of its own
  # (the package's points at /usr/share/dbus-1); until the socket answers.
  defp start_bus(bus, user, home) do
    _ = File.rm(bus.path)
    conf = Path.join(Path.dirname(bus.path), "dbus-session.conf")

    File.write!(conf, """
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>session</type>
      <listen>unix:path=#{bus.path}</listen>
      <auth>EXTERNAL</auth>
      <policy context="default">
        <allow user="*"/>
        <allow own="*"/>
        <allow send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_type="method_return"/>
        <allow send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="signal"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
      </policy>
    </busconfig>
    """)

    own(conf, user)
    {exe, argv} = Lepton.RunAs.command(user, bus.exe, ["--config-file=" <> conf, "--nofork", "--nopidfile", "--nosyslog"])
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: home, env: charlists(bus.env)])
    Enum.find(1..40, fn _ -> bus_listening?(bus.path) || (Process.sleep(50) && false) end)
    port
  end

  defp stop_bus(port, bus) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> Lepton.Sys.shim("kill", [to_string(pid)])
      _ -> :ok
    end

    catch_close(port)
    File.rm(bus.path)
  end

  defp catch_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp relay(port, out) do
    receive do
      {^port, {:data, d}} ->
        IO.binwrite(out, d)
        relay(port, out)

      {^port, {:exit_status, status}} ->
        File.close(out)
        status
    end
  end
end
