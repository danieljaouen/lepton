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

  The one app so far is Firefox. Its packages leave out what a software-
  rendered browser in a VM doesn't load: Mesa and LLVM (GPU drawing).
  FFmpeg's decoders (libavcodec) are in: Firefox plays WebM and AV1 with
  its own, but H.264 and AAC (MP4 video: TikTok, LinkedIn, Instagram)
  only through FFmpeg. One package comes from Alpine 3.23: gdk-pixbuf,
  whose 3.24 build decodes images in sandboxed helper programs.
  """

  alias Lepton.Alpine

  @apps %{
    "firefox" => %{
      title: "Firefox",
      summary: "the Firefox web browser",
      packages: ["firefox", "font-dejavu", "icu-data-en"],
      # 3.24's gdk-pixbuf decodes images through glycin, whose loaders run
      # in a bubblewrap sandbox at fixed paths; 3.23's (2.44 too) has its own.
      pins: %{"gdk-pixbuf" => "v3.23"},
      # (FFmpeg's libavcodec is linked with its encoders' libraries too: they stay in.)
      exclude: ~r/^(mesa.*|llvm.*|spirv-.*|busybox.*|bubblewrap|pkgconf|libxshmfence|libxxf86vm|mkfontscale)$/,
      exe: "usr/lib/firefox/firefox",
      gtk: true,
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
    }
  }

  def names, do: Map.keys(@apps) |> Enum.sort()
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
  The app's programs running as `uid` (from `/proc`: their executable is
  in the app's directory). Firefox's content processes are among them.
  """
  def processes(name, uid) do
    prefix = dir(name) <> "/"

    for entry <- Path.wildcard("/proc/[0-9]*"),
        {:ok, exe} <- [File.read_link(Path.join(entry, "exe"))],
        String.starts_with?(exe, prefix),
        {:ok, status} <- [File.read(Path.join(entry, "status"))],
        [_, owner] <- [Regex.run(~r/^Uid:\s+(\d+)/m, status)],
        String.to_integer(owner) == uid,
        do: String.to_integer(Path.basename(entry))
  end

  @doc """
  Stop an app's programs that were left behind (hung, or with no window
  any more) and the locks they leave in its profile, so it can start
  again. Returns how many were stopped.
  """
  def clear_leftovers(name, %Lepton.Users{uid: uid}, home) do
    pids = processes(name, uid)
    for pid <- pids, do: Lepton.Sys.shim("kill", ["-9", to_string(pid)])

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

  defp setup(name, prefix) do
    if get(name)[:gtk], do: setup_gtk(prefix), else: :ok
  end

  defp setup_gtk(prefix) do
    env = env(prefix, %{})

    with :ok <- run(prefix, "usr/bin/glib-compile-schemas", [Path.join(prefix, "usr/share/glib-2.0/schemas")], env),
         # The MIME database: how GIO (and so gdk-pixbuf) tells a PNG from a JPEG.
         :ok <- run(prefix, "usr/bin/update-mime-database", [Path.join(prefix, "usr/share/mime")], env),
         :ok <- pixbuf_loaders(prefix, env),
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
  for example.
  """
  def firefox_policies(prefix) do
    dir = Path.join(prefix, "usr/lib/firefox/distribution")

    if File.dir?(dir) do
      policies = %{
        "policies" => %{
          "DontCheckDefaultBrowser" => true,
          "Preferences" => %{
            "browser.tabs.inTitlebar" => %{"Value" => 0, "Status" => "default"},
            "media.gmp-gmpopenh264.enabled" => %{"Value" => false, "Status" => "locked"},
            "media.gmp-gmpopenh264.autoupdate" => %{"Value" => false, "Status" => "locked"},
            "browser.tabs.unloadOnLowMemory" => %{"Value" => true, "Status" => "default"},
            "browser.low_commit_space_threshold_percent" => %{"Value" => 10, "Status" => "default"}
          }
        }
      }

      File.write(Path.join(dir, "policies.json"), JSON.encode!(policies))
    else
      :ok
    end
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

  defp fonts_conf(prefix) do
    conf = """
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>#{prefix}/usr/share/fonts</dir>
      <cachedir prefix="xdg">fontconfig</cachedir>
      <include ignore_missing="yes">#{prefix}/etc/fonts/conf.d</include>
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
    env = env(prefix, ctx.env) |> Map.put("HOME", home) |> Map.merge(alsa_env(prefix)) |> bluetooth_libs(name) |> Map.merge(Lepton.Proxy.app_env(ctx.env))
    if Lepton.Sys.native?(), do: musl_path(prefix)
    # Firefox installed before a policy was added gets it too.
    firefox_policies(prefix)
    # As the user, not as root (the VM's own user): see Lepton.RunAs.
    {exe, argv} = Lepton.RunAs.command(user, Path.join(prefix, app.exe), args)

    {lpid, _beam} =
      Lepton.Proc.spawn(name, [], fn _pid ->
        {:ok, out} = File.open(log, [:write, :binary])
        own(log, user)
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: home, env: charlists(env)])
        relay(port, out)
      end)

    {:ok, lpid}
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
