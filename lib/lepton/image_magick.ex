defmodule Lepton.ImageMagick do
  @moduledoc """
  ImageMagick (`magick`, and its tools `convert`, `identify`, `mogrify`,
  `composite`, `montage`, `compare`): the real ImageMagick 7, an app
  (`sudo app install imagemagick`), run by Lepton as you, in your
  folder. Ctrl-C stops it.

  Formats: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, JPEG 2000, BMP, PDF,
  PostScript and dozens more read and write; SVG and HEIC (iPhone
  photos) read (SVG through librsvg, PDF through Ghostscript). Text (`label:`,
  `-annotate`) is drawn in DejaVu, which the app brings.

  ImageMagick looks for its format modules and settings where Alpine put
  them (`/usr/lib/ImageMagick-7...`); the app lives in its own folder, so
  the environment points it there (`MAGICK_CODER_MODULE_PATH` and the
  others). Its standard error goes to a file of its own and is shown
  after it, so an image written to standard output (`png:-`) comes
  through unmixed.
  """

  alias Lepton.Apps
  alias Lepton.IO, as: LIO

  @app "imagemagick"
  @tools ~w(convert identify mogrify composite montage compare)

  @doc "The tools `magick` runs as its first argument, each a command of its own too."
  def tools, do: @tools

  # (`config :lepton, imagemagick_prefix: DIR`: an unpacked copy elsewhere, for development)
  defp prefix, do: Application.get_env(:lepton, :imagemagick_prefix) || Apps.dir(@app)

  def installed?, do: if(Application.get_env(:lepton, :imagemagick_prefix), do: File.exists?(program()), else: Apps.installed?(@app))
  def program, do: Path.join(prefix(), "usr/bin/magick")

  @doc "The environment it runs with: its libraries, modules, settings and fonts."
  def env(ctx) do
    p = prefix()
    modules = Path.wildcard(Path.join(p, "usr/lib/ImageMagick-*/modules-*")) |> List.first() || ""
    config = Path.wildcard(Path.join(p, "etc/ImageMagick-*")) |> List.first() || ""
    fonts = Path.join(p, "etc/fonts/lepton.conf")
    if not File.exists?(fonts), do: Apps.fonts_conf(p)
    types = Path.join(p, "etc/ImageMagick-lepton")
    if not File.exists?(Path.join(types, "type.xml")), do: type_map(p)

    ctx.env
    |> Map.merge(%{
      "HOME" => Lepton.Ctx.home(ctx),
      "LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(p, &1)),
      "MAGICK_CODER_MODULE_PATH" => Path.join(modules, "coders"),
      "MAGICK_CODER_FILTER_PATH" => Path.join(modules, "filters"),
      "MAGICK_CONFIGURE_PATH" => types <> ":" <> config,
      "FONTCONFIG_FILE" => fonts,
      # PDF and PostScript: Ghostscript, which ImageMagick runs as `gs`
      # (first on the path), with its resources where the app has them.
      "PATH" => Path.join(p, "usr/bin") <> ":" <> (ctx.env["PATH"] || "/bin"),
      "GS_LIB" => Enum.map_join(["Resource/Init", "lib", "Resource/Font"], ":", &Path.join([p, "usr/share/ghostscript", &1]))
    })
  end

  @doc """
  Run `magick` with `args` (for a tool such as `identify`, `tool` is put
  first, as `magick identify ...`): its exit status.
  """
  def run(tool, args, ctx) do
    # Updates, as for Firefox: one downloaded earlier goes in now; a new
    # definition (SVG and PDF, added later) is fetched for next time.
    if !Application.get_env(:lepton, :imagemagick_prefix) and installed?(), do: Apps.maintain(@app)

    if installed?() or Apps.offer_install(ctx, @app, "#{tool} is ImageMagick's") == :installed do
      user = Lepton.Users.get(ctx.user || "root") || Lepton.Users.get("root")
      args = if tool == "magick", do: args, else: [tool | args]
      err = Path.join(System.tmp_dir!(), "lepton-magick-#{System.unique_integer([:positive])}.err")
      File.write!(err, "")
      if user.uid != 0, do: Lepton.Users.lchown(err, user.uid, user.gid)

      try do
        sh = if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
        script = ~S'exec "$0" "$@" 2>>"$LEPTON_MAGICK_ERR"'
        {exe, argv} = Lepton.RunAs.command(user, sh, ["-c", script, program() | args])
        env = for {k, v} <- Map.put(env(ctx), "LEPTON_MAGICK_ERR", err), is_binary(v), do: {String.to_charlist(k), String.to_charlist(v)}
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, args: argv, cd: ctx.cwd || Lepton.Ctx.home(ctx), env: env])
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        Lepton.MixVM.guard(os_pid, self())
        status = loop(port, os_pid, ctx)

        case File.read(err) do
          {:ok, text} when text != "" -> LIO.write(%{ctx | stdout: ctx.stderr}, text)
          _ -> :ok
        end

        status
      after
        File.rm(err)
      end
    else
      1
    end
  end

  # ImageMagick's own names for fonts (Helvetica, its default; Arial,
  # Times, Courier), as DejaVu's (it finds those through fontconfig too,
  # as DejaVu-Sans and the like): without them, text failed with
  # "UnableToReadFont".
  @families [
    {"Helvetica", "DejaVuSans"},
    {"Arial", "DejaVuSans"},
    {"Times", "DejaVuSerif"},
    {"Times-Roman", "DejaVuSerif"},
    {"Times-New-Roman", "DejaVuSerif"},
    {"Courier", "DejaVuSansMono"},
    {"Courier-New", "DejaVuSansMono"}
  ]

  @doc false
  def type_map(p) do
    dir = Path.join(p, "usr/share/fonts/dejavu")

    types =
      for {name, file} <- @families, bold <- [false, true] do
        glyphs = Path.join(dir, file <> if(bold, do: "-Bold", else: "") <> ".ttf")
        full = name <> if(bold, do: "-Bold", else: "")
        family = name |> String.replace("-", " ") |> String.replace(" Roman", "")
        weight = if bold, do: 700, else: 400
        ~s(  <type name="#{full}" fullname="#{full}" family="#{family}" style="normal" stretch="normal" weight="#{weight}" glyphs="#{glyphs}"/>\n)
      end

    out = Path.join(p, "etc/ImageMagick-lepton")
    File.mkdir_p!(out)
    File.write(Path.join(out, "type.xml"), [~s(<?xml version="1.0" encoding="UTF-8"?>\n<typemap>\n), types, "</typemap>\n"])
  end

  defp loop(port, os_pid, ctx) do
    receive do
      {^port, {:data, d}} ->
        LIO.write(ctx, d)
        loop(port, os_pid, ctx)

      {^port, {:exit_status, s}} ->
        s

      {:signal, sig} when sig in [:int, :term] ->
        Lepton.Sys.shim("kill", ["-#{sig |> Atom.to_string() |> String.upcase()}", to_string(os_pid)])
        loop(port, os_pid, ctx)
    end
  end
end
