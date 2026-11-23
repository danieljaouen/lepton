defmodule Lepton.Widevine do
  @moduledoc """
  Widevine, the DRM plugin (a "content decryption module") Firefox needs
  for Spotify's web player, Netflix, Disney+ and other streaming sites.

  Firefox downloads Widevine by itself on x86-64 Linux, but Mozilla
  offers no build for ARM64 Linux. Google's Chrome for ARM64 Linux
  carries one (`WidevineCdm/_platform_specific/linux_arm64`), so
  `widevine install` downloads Chrome's package from Google's own
  repository (`dl.google.com`, checked against the SHA-256 the
  repository lists), takes the plugin out of it and keeps nothing else.
  Widevine's license doesn't let Lepton distribute it: it comes from
  Google, onto your machine, when you ask.

  The plugin is built for glibc. Firefox's `gcompat` package (glibc's
  names over musl) provides what musl lacks, and Alpine's Firefox
  preloads it for the plugin; the four relocations musl can't do are
  resolved when it is installed (`Lepton.Widevine.Elf`). Firefox finds it through `MOZ_GMP_PATH` (`env/1`) and the
  preferences `prefs/0` gives (`Lepton.Apps.firefox_policies/1`).
  """

  alias Lepton.Alpine

  @repo "https://dl.google.com/linux/chrome/deb/"
  @index @repo <> "dists/stable/main/binary-arm64/Packages"
  @package "google-chrome-stable"
  @member "./opt/google/chrome/WidevineCdm"

  @doc "Where Widevine is kept (the data partition, on an installed system)."
  def dir, do: Path.join(Lepton.Persist.state_dir(), "widevine")

  @doc "The plugin's folder, as Firefox wants it (`MOZ_GMP_PATH`)."
  def gmp_dir, do: Path.join(dir(), "gmp-widevinecdm/system-installed")

  def installed?,
    do:
      File.exists?(Path.join(gmp_dir(), "libwidevinecdm.so")) and
        File.exists?(Path.join(gmp_dir(), "manifest.json"))

  @doc "The installed plugin's version (from its manifest), or nil."
  def version do
    with {:ok, text} <- File.read(Path.join(gmp_dir(), "manifest.json")),
         {:ok, %{"version" => v}} <- JSON.decode(text),
         do: v,
         else: (_ -> nil)
  end

  @doc "Firefox's environment when Widevine is installed."
  def env, do: if(installed?(), do: %{"MOZ_GMP_PATH" => gmp_dir()}, else: %{})

  @doc """
  Firefox's preferences for an installed Widevine: use the one in
  `MOZ_GMP_PATH` ("system-installed"), and don't look for updates (there
  are none for ARM64 Linux at Mozilla; `widevine update` gets Google's).
  """
  def prefs do
    if installed?() do
      %{
        "media.gmp-widevinecdm.version" => "system-installed",
        "media.gmp-widevinecdm.visible" => true,
        "media.gmp-widevinecdm.enabled" => true,
        "media.gmp-widevinecdm.autoupdate" => false
      }
    else
      %{}
    end
  end

  @doc """
  The newest Chrome package in Google's repository: `{:ok, %{version,
  filename, size, sha256}}`.
  """
  def latest do
    with {:ok, text} <- Alpine.get(@index) do
      case parse_index(text) do
        nil -> {:error, "no #{@package} in Google's repository"}
        pkg -> {:ok, pkg}
      end
    end
  end

  @doc "The `#{@package}` entry of a Debian `Packages` index (nil if absent)."
  def parse_index(text) do
    text
    |> String.split(~r/\n\n+/, trim: true)
    |> Enum.map(fn stanza ->
      for line <- String.split(stanza, "\n"),
          [k, v] <- [String.split(line, ": ", parts: 2)],
          into: %{},
          do: {k, String.trim(v)}
    end)
    |> Enum.find(&(&1["Package"] == @package))
    |> case do
      nil ->
        nil

      p ->
        %{
          version: p["Version"],
          filename: p["Filename"],
          size: String.to_integer(p["Size"] || "0"),
          sha256: String.downcase(p["SHA256"] || "")
        }
    end
  end

  @doc """
  Download Chrome's package `pkg` (from `latest/0`) and install the
  Widevine in it (replacing one there). `say` gets progress lines. `:ok` or `{:error, reason}`.
  """
  def install(pkg, say \\ fn _ -> :ok end) do
    if File.exists?(xz()),
      do: download_install(pkg, say),
      else:
        {:error,
         "install Firefox first (sudo app install firefox), or update it (sudo app update firefox)"}
  end

  defp download_install(pkg, say) do
    work = dir() <> ".download"
    File.rm_rf(work)
    File.mkdir_p!(work)
    deb = Path.join(work, "chrome.deb")

    try do
      say.(
        "Downloading Google Chrome #{pkg.version} for its Widevine (#{div(pkg.size, 1_000_000)} MB)..."
      )

      with :ok <- Alpine.download(@repo <> pkg.filename, deb, fn _ -> :ok end),
           :ok <- check_sha256(deb, pkg.sha256),
           {:ok, data} <- deb_member(deb, "data.tar"),
           :ok <- untar(deb, data, work),
           :ok <- place(Path.join(work, @member), pkg.version) do
        say.("Installed Widevine #{version()}.")
        :ok
      end
    after
      File.rm_rf(work)
    end
  end

  @doc "The Chrome version the installed Widevine came from, or nil."
  def chrome_version do
    case File.read(Path.join(dir(), "chrome-version")) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  @doc "Remove Widevine."
  def remove do
    File.rm_rf(dir())
    :ok
  end

  defp check_sha256(path, want) do
    got =
      File.stream!(path, 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if got == want,
      do: :ok,
      else: {:error, "the download's SHA-256 doesn't match Google's index (#{got})"}
  end

  @doc """
  Find a member of a `.deb` (an `ar` archive) whose name starts with
  `prefix`: `{:ok, {name, offset, size}}`.
  """
  def deb_member(path, prefix) do
    {:ok, f} = File.open(path, [:read, :binary])

    try do
      case IO.binread(f, 8) do
        "!<arch>\n" -> ar_find(f, 8, prefix)
        _ -> {:error, "not a .deb package"}
      end
    after
      File.close(f)
    end
  end

  defp ar_find(f, pos, prefix) do
    case IO.binread(f, 60) do
      <<name::binary-16, _::binary-32, size::binary-10, "`\n">> ->
        name = name |> String.trim() |> String.trim_trailing("/")
        size = size |> String.trim() |> String.to_integer()

        if String.starts_with?(name, prefix) do
          {:ok, {name, pos + 60, size}}
        else
          next = pos + 60 + size + rem(size, 2)
          {:ok, _} = :file.position(f, next)
          ar_find(f, next, prefix)
        end

      _ ->
        {:error, "no #{prefix} in the package"}
    end
  end

  # The data member to a file of its own, then Firefox's xz (busybox's
  # can't: Chrome's is packed with a 256 MB dictionary) into busybox's tar,
  # which takes the plugin's folder out of it.
  defp untar(deb, {name, offset, size}, work) do
    tar = Path.join(work, name)
    {:ok, src} = File.open(deb, [:read, :binary, :raw])
    {:ok, dst} = File.open(tar, [:write, :binary, :raw])
    {:ok, _} = :file.position(src, offset)
    {:ok, ^size} = :file.copy(src, dst, size)
    File.close(src)
    File.close(dst)

    script =
      if String.ends_with?(name, ".xz"),
        do: "set -o pipefail; '#{xz()}' -dc '#{tar}' | /bin/busybox tar -xf - -C '#{work}' '#{@member}'",
        else: "/bin/busybox tar -xzf '#{tar}' -C '#{work}' '#{@member}'"

    case Lepton.Sys.shim("sh", ["-c", script]) do
      {_, 0} -> File.rm(tar)
      {out, _} -> {:error, "unpacking Chrome's package failed: #{String.trim(out)}"}
    end
  end

  defp xz do
    prefix = Lepton.Apps.dir("firefox")
    if Lepton.Sys.native?(), do: Lepton.Apps.musl_path(prefix)
    Path.join(prefix, "usr/bin/xz")
  end

  # The plugin, made loadable by musl (Lepton.Widevine.Elf), its manifest and license.
  defp place(src, chrome) do
    lib = Path.join(src, "_platform_specific/linux_arm64/libwidevinecdm.so")
    manifest = Path.join(src, "manifest.json")

    with true <- (File.exists?(lib) and File.exists?(manifest)) || {:error, "Chrome's package has no ARM64 Widevine"},
         {:ok, fixed, _count} <- Lepton.Widevine.Elf.fix_irelative(File.read!(lib)) do
      File.rm_rf(dir())
      File.mkdir_p!(gmp_dir())
      File.write!(Path.join(gmp_dir(), "libwidevinecdm.so"), fixed)
      File.chmod!(Path.join(gmp_dir(), "libwidevinecdm.so"), 0o755)
      File.cp!(manifest, Path.join(gmp_dir(), "manifest.json"))
      if File.exists?(Path.join(src, "LICENSE")), do: File.cp!(Path.join(src, "LICENSE"), Path.join(dir(), "LICENSE"))
      File.write!(Path.join(dir(), "chrome-version"), chrome <> "\n")
      :ok
    else
      {:error, reason} -> {:error, "this Widevine can't be made to load on Lepton: #{reason}"}
    end
  end
end
