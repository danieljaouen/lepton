defmodule Lepton.Archive.Compress do
  @moduledoc """
  The compressors `tar` uses beside gzip (which is Erlang's zlib, in
  Lepton itself):

  - **bzip2** (`.tar.bz2`): busybox's `bzip2`, which every Lepton has
    (`/bin/busybox`), both ways.
  - **xz** (`.tar.xz`): the `compressors` app's `xz` when it's installed;
    reading also works without it, with busybox's `xzcat` (all but
    archives packed with the very largest dictionaries).
  - **zstd** (`.tar.zst`): the `compressors` app's `zstd`.

  Making an `.tar.xz` or anything zstd without the app offers to install
  it (`sudo app install compressors`, about 1 MB). The programs run on a
  file (the archive, or a temporary copy of what came on standard
  input); their messages are kept apart and passed on when they fail.
  """

  alias Lepton.Apps

  @app "compressors"

  # (`config :lepton, compressors_prefix: DIR`: an unpacked copy elsewhere, for development)
  defp prefix, do: Application.get_env(:lepton, :compressors_prefix) || Apps.dir(@app)

  @doc "Is the app (xz, zstd) there?"
  def installed? do
    if Application.get_env(:lepton, :compressors_prefix), do: File.exists?(program("xz")), else: Apps.installed?(@app)
  end

  defp program(name), do: Path.join([prefix(), "usr/bin", name])

  @busybox "/bin/busybox"

  @doc "The compression a file's name asks for: :gzip, :bzip2, :xz, :zstd or :none."
  def by_name(name) do
    cond do
      String.ends_with?(name, [".tar.gz", ".tgz", ".gz"]) -> :gzip
      String.ends_with?(name, [".tar.bz2", ".tbz2", ".tbz", ".bz2"]) -> :bzip2
      String.ends_with?(name, [".tar.xz", ".txz", ".xz"]) -> :xz
      String.ends_with?(name, [".tar.zst", ".tzst", ".zst"]) -> :zstd
      true -> :none
    end
  end

  @doc """
  Decompress `data` (`kind`: :bzip2, :xz, :zstd); `path` names a file
  holding it already (nil: it's written to a temporary one).
  `{:ok, binary}` or `{:error, message}`.
  """
  def decompress(kind, data, path, ctx) do
    with {:ok, {exe, args}} <- tool(kind, :decompress, ctx) do
      on_file(data, path, fn file -> run(exe, args ++ [file], kind) end)
    end
  end

  @doc "Compress `data` with `kind` (:bzip2, :xz, :zstd): `{:ok, binary}` or `{:error, message}`."
  def compress(kind, data, ctx) do
    with {:ok, {exe, args}} <- tool(kind, :compress, ctx) do
      on_file(data, nil, fn file -> run(exe, args ++ [file], kind) end)
    end
  end

  # The program, and its arguments before the file, writing to stdout.
  defp tool(:bzip2, :decompress, _ctx), do: busybox(["bzip2", "-dc"])
  defp tool(:bzip2, :compress, _ctx), do: busybox(["bzip2", "-c"])

  defp tool(:xz, :decompress, ctx) do
    cond do
      installed?() -> {:ok, {program("xz"), ["-dc", "-T0"]}}
      File.exists?(@busybox) -> {:ok, {@busybox, ["xzcat"]}}
      true -> need(ctx, "xz")
    end
  end

  defp tool(:xz, :compress, ctx), do: app_tool(ctx, "xz", ["-c", "-T0"])
  defp tool(:zstd, :decompress, ctx), do: app_tool(ctx, "zstd", ["-dc", "-q"])
  defp tool(:zstd, :compress, ctx), do: app_tool(ctx, "zstd", ["-c", "-q", "-T0", "-19"])
  defp tool(other, _, _ctx), do: {:error, "#{other}-compressed archives aren't supported (gzip, bzip2, xz and zstd are)"}

  defp busybox(args) do
    if File.exists?(@busybox), do: {:ok, {@busybox, args}}, else: {:error, "#{hd(args)} needs busybox, which this system lacks"}
  end

  defp app_tool(ctx, name, args) do
    if installed?() or need(ctx, name) == :installed, do: {:ok, {program(name), args}}, else: {:error, "#{name} isn't installed: sudo app install #{@app}"}
  end

  defp need(ctx, name) do
    case Apps.offer_install(ctx, @app, "tar uses #{name} for these archives") do
      :installed -> :installed
      _ -> {:error, "#{name} isn't installed: sudo app install #{@app}"}
    end
  end

  defp on_file(_data, path, fun) when is_binary(path), do: fun.(path)

  defp on_file(data, nil, fun) do
    tmp = Path.join(System.tmp_dir!(), "lepton-tar-#{System.unique_integer([:positive])}")

    try do
      File.write!(tmp, data)
      File.chmod!(tmp, 0o600)
      fun.(tmp)
    after
      File.rm(tmp)
    end
  end

  defp run(exe, args, kind) do
    err = Path.join(System.tmp_dir!(), "lepton-tar-#{System.unique_integer([:positive])}.err")
    sh = if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
    env = if String.starts_with?(exe, prefix()), do: [{"LD_LIBRARY_PATH", Path.join(prefix(), "usr/lib")}], else: []

    try do
      case System.cmd(sh, ["-c", ~S'exec "$0" "$@" 2>"$LEPTON_TAR_ERR"', exe | args], env: [{"LEPTON_TAR_ERR", err} | env]) do
        {out, 0} -> {:ok, out}
        {_, status} -> {:error, "#{kind} failed (#{status}): " <> (err |> File.read() |> elem(1) |> to_string() |> String.trim())}
      end
    after
      File.rm(err)
    end
  end
end
