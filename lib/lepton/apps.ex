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
  rendered browser in a VM doesn't load: Mesa and LLVM (GPU drawing),
  and FFmpeg and its video codecs (Firefox plays WebM and AV1 with its
  own decoders). One package comes from Alpine 3.23: gdk-pixbuf, whose
  3.24 build decodes images in sandboxed helper programs.
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
      exclude:
        ~r/^(mesa.*|llvm.*|spirv-.*|ffmpeg-.*|x26[45]-libs|aom-libs|libSvtAv1Enc|rav1e-libs|libdav1d|xvidcore|lame-libs|libtheora|libvorbis|opus|libogg|soxr|libva|libvdpau|libjxl|libhwy|busybox.*|bubblewrap|pkgconf|hwdata-.*|pciutils-libs|libpciaccess|libdrm|libxshmfence|libxxf86vm|mkfontscale|libgomp)$/,
      exe: "usr/lib/firefox/firefox"
    }
  }

  def names, do: Map.keys(@apps) |> Enum.sort()
  def get(name), do: Map.get(@apps, name)

  def root, do: Path.join(Lepton.Persist.state_dir(), "apps")
  def dir(name), do: Path.join(root(), name)
  def installed?(name), do: File.exists?(Path.join(dir(name), ".lepton-app"))

  @doc "What is installed: `%{name => %{packages: n, size: bytes}}` from the app's record."
  def info(name) do
    case File.read(Path.join(dir(name), ".lepton-app")) do
      {:ok, text} -> :erlang.binary_to_term(Base.decode64!(text))
      _ -> nil
    end
  end

  @doc """
  Install app `name`: resolve its packages, download and unpack them, set
  them up. `say` reports progress (a function of a string).
  """
  def install(name, say \\ fn _ -> :ok end) do
    with %{} = app <- get(name) || {:error, "no app called #{name} (apps: #{Enum.join(names(), ", ")})"},
         _ = say.("Reading the Alpine #{Alpine.branch()} package index..."),
         {:ok, index} <- Alpine.index(),
         {:ok, index} <- Alpine.pin(index, Map.get(app, :pins, %{})),
         {:ok, pkgs} <- Alpine.resolve(index, app.packages, app.exclude) do
      total = Enum.sum(Enum.map(pkgs, & &1.size))
      installed = Enum.sum(Enum.map(pkgs, & &1.installed_size))
      say.("#{app.title}: #{length(pkgs)} packages, #{mib(total)} to download, #{mib(installed)} installed.")
      tmp = dir(name) <> ".new"
      File.rm_rf!(tmp)

      result =
        pkgs
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {pkg, i}, :ok ->
          say.("[#{i}/#{length(pkgs)}] #{pkg.name} #{pkg.version} (#{mib(pkg.size)})")

          case Alpine.install(pkg, tmp) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "#{pkg.name}: #{inspect(reason)}"}}
          end
        end)

      # Setup writes absolute paths (loader caches, fonts.conf): do it in place.
      with :ok <- result,
           _ = File.rm_rf!(dir(name)),
           :ok <- File.rename(tmp, dir(name)),
           _ = say.("Setting up..."),
           :ok <- setup(name, dir(name)) do
        record = %{packages: Enum.map(pkgs, &{&1.name, &1.version}), size: installed, branch: Alpine.branch()}
        File.write!(Path.join(dir(name), ".lepton-app"), Base.encode64(:erlang.term_to_binary(record)))
        :ok
      else
        err ->
          File.rm_rf(tmp)
          File.rm_rf(dir(name))
          err
      end
    else
      {:error, {:unresolved, dep}} -> {:error, "cannot resolve #{dep}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def remove(name) do
    if installed?(name), do: File.rm_rf(dir(name)) |> then(fn _ -> :ok end), else: {:error, "#{name} is not installed"}
  end

  defp mib(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  # -- setup: what the packages' install triggers would do ---------------------------------------------

  defp setup(_name, prefix) do
    env = env(prefix, %{})

    with :ok <- run(prefix, "usr/bin/glib-compile-schemas", [Path.join(prefix, "usr/share/glib-2.0/schemas")], env),
         # The MIME database: how GIO (and so gdk-pixbuf) tells a PNG from a JPEG.
         :ok <- run(prefix, "usr/bin/update-mime-database", [Path.join(prefix, "usr/share/mime")], env),
         :ok <- pixbuf_loaders(prefix, env),
         :ok <- fonts_conf(prefix) do
      firefox_policies(prefix)
    end
  end

  # Photon draws the title bar: Firefox uses it rather than drawing its
  # own buttons in the tab strip; and it doesn't ask to be the default.
  defp firefox_policies(prefix) do
    dir = Path.join(prefix, "usr/lib/firefox/distribution")

    if File.dir?(dir) do
      policies = %{
        "policies" => %{
          "DontCheckDefaultBrowser" => true,
          "Preferences" => %{"browser.tabs.inTitlebar" => %{"Value" => 0, "Status" => "default"}}
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
  Start app `name` with `args` in a Lepton process of its own; its output
  goes to `~/.cache/lepton/NAME.log`. `ctx` gives the environment
  (`WAYLAND_DISPLAY`, `HOME`). Returns `{:ok, lepton_pid}`.
  """
  def launch(name, args, ctx) do
    prefix = dir(name)
    app = get(name)
    home = ctx.env["HOME"] || "/root"
    log = Path.join([home, ".cache", "lepton", name <> ".log"])
    File.mkdir_p!(Path.dirname(log))
    env = env(prefix, ctx.env) |> Map.put("HOME", home)

    {lpid, _beam} =
      Lepton.Proc.spawn(name, [], fn _pid ->
        {:ok, out} = File.open(log, [:write, :binary])
        port = Port.open({:spawn_executable, Path.join(prefix, app.exe)}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, cd: home, env: charlists(env)])
        relay(port, out)
      end)

    {:ok, lpid}
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
