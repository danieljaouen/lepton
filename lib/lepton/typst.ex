defmodule Lepton.Typst do
  @moduledoc """
  Typst (`typst`), the typesetting system: the real `typst` program, an
  app (`sudo app install typst`), run by Lepton as you, in your folder,
  its output in your terminal. Ctrl-C stops it (`typst watch` runs until
  then).

  Fonts: Typst's own (Libertinus, New Computer Modern, DejaVu Sans Mono)
  are built in; it also finds yours, in `~/.local/share/fonts` and
  `~/.fonts`, and, if Firefox is installed, Firefox's (DejaVu, Noto CJK
  and the other scripts'). Packages (`#import "@preview/..."`) are
  downloaded once into `~/.cache/typst`.
  """

  alias Lepton.Apps
  alias Lepton.IO, as: LIO

  @app "typst"

  # (`config :lepton, typst_prefix: DIR`: an unpacked copy, for development)
  defp prefix, do: Application.get_env(:lepton, :typst_prefix) || Apps.dir(@app)

  def installed?, do: if(Application.get_env(:lepton, :typst_prefix), do: File.exists?(program()), else: Apps.installed?(@app))
  def program, do: Path.join([prefix(), "usr/bin/typst"])

  @doc "The environment typst runs with: its libraries, certificates and fonts."
  def env(ctx) do
    home = Lepton.Ctx.home(ctx)
    p = prefix()
    fonts = [Path.join(home, ".local/share/fonts"), Path.join(home, ".fonts")] ++ firefox_fonts()

    ctx.env
    |> Map.merge(%{
      "HOME" => home,
      "LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib"], ":", &Path.join(p, &1)),
      "SSL_CERT_FILE" => Path.join(p, "etc/ssl/certs/ca-certificates.crt"),
      "TYPST_FONT_PATHS" => fonts |> Enum.filter(&File.dir?/1) |> Enum.join(":")
    })
    |> Map.merge(Lepton.Proxy.app_env(ctx.env))
  end

  defp firefox_fonts do
    dir = Path.join(Apps.dir("firefox"), "usr/share/fonts")
    if Apps.installed?("firefox") and File.dir?(dir), do: [dir], else: []
  end

  @doc "Run `typst ARGS`: its exit status."
  def run(args, ctx) do
    if installed?() or Apps.offer_install(ctx, @app, "typst is the Typst typesetting system") == :installed do
      user = Lepton.Users.get(ctx.user || "root") || Lepton.Users.get("root")
      # (colours when it writes to a terminal, as it would itself)
      color = if Lepton.Style.color?(ctx) and ctx.tty != nil and args != [] and hd(args) not in ["--color"], do: ["--color", "always"], else: []
      {exe, argv} = Lepton.RunAs.command(user, program(), color ++ args)
      env = for {k, v} <- env(ctx), is_binary(v), do: {String.to_charlist(k), String.to_charlist(v)}
      port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: argv, cd: ctx.cwd || Lepton.Ctx.home(ctx), env: env])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      # (stopped with the command, however it ends)
      Lepton.MixVM.guard(os_pid, self())
      loop(port, os_pid, ctx)
    else
      # (offer_install said how, or the install failed)
      1
    end
  end

  @doc """
  Compile `path` (a `.typ` file) beside it, the way the editor does:
  `{:ok, pdf, output}` (output: any warnings), `{:error, output, where}`
  (`where`: `{file, line, column}` of the first error, 1-based, or nil),
  or `{:missing, message}`.
  """
  def compile(path, ctx, out \\ nil) do
    if installed?() do
      out = out || Path.rootname(path) <> ".pdf"
      user = Lepton.Users.get(ctx.user || "root") || Lepton.Users.get("root")
      {exe, argv} = Lepton.RunAs.command(user, program(), ["compile", "--diagnostic-format", "human", path, out])
      env = for {k, v} <- env(ctx), is_binary(v), do: {String.to_charlist(k), String.to_charlist(v)}
      port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: argv, cd: Path.dirname(path), env: env])
      Lepton.Sys.guard(port)
      {status, output} = collect(port, [])

      if status == 0, do: {:ok, out, output}, else: {:error, output, where(output)}
    else
      {:missing, "Typst isn't installed. Install it with: sudo app install typst"}
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, [acc, d])
      {^port, {:exit_status, s}} -> {s, IO.iodata_to_binary(acc)}
    after
      120_000 -> Port.close(port); {124, IO.iodata_to_binary(acc) <> "\n(typst took over two minutes: stopped)"}
    end
  end

  @doc "Where typst's first error is: `{file, line, column}` from its report, or nil."
  def where(output) do
    case Regex.run(~r/^error:.*?\n\s*\S+\s+([^\s:]+):(\d+):(\d+)/msu, output, capture: :all_but_first) do
      [file, l, c] -> {file, String.to_integer(l), String.to_integer(c)}
      _ -> nil
    end
  end

  @doc "The first error's message (its first line), or the output's first line."
  def summary(output) do
    lines = String.split(output, "\n", trim: true)
    Enum.find(lines, List.first(lines) || "", &String.starts_with?(&1, "error:"))
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
