defmodule LeptonBuild.Sources do
  @moduledoc """
  Fetches the pre-built substrate Lepton runs on top of.

  Nothing here is authored by us: the Linux kernel and its modules, the
  Erlang runtime (ERTS + OTP), the glibc shared libraries ERTS links
  against, GRUB, CA certificates and a static busybox used purely as a
  syscall shim (mount, init_module, termios ioctls). Every byte of
  userland *behaviour* lives in `lib/lepton`.

  Versions are resolved from upstream package indices at fetch time and
  recorded in `sources.lock` inside the cache directory.
  """

  @otp_version "OTP-29.1.2"
  @otp_url "https://builds.hex.pm/builds/otp/arm64/ubuntu-24.04"

  @alpine_mirror "https://dl-cdn.alpinelinux.org/alpine"
  @alpine_branch "v3.24"
  # linux-lts rather than linux-virt: the same kernel, built with the
  # 802.11 stack and Wi-Fi drivers. The image keeps only the modules Lepton
  # uses (LeptonBuild.Image).
  @alpine_packages [
    {"main", "linux-lts"},
    {"main", "busybox-static"},
    {"main", "ca-certificates-bundle"},
    # The IANA time zones (/usr/share/zoneinfo), for Lepton.TZ and native programs.
    {"main", "tzdata"}
  ]

  # Wi-Fi: wpa_supplicant (and hostapd, for the self-tests' simulated access
  # point), the musl libraries they link against, the regulatory database,
  # and firmware for the USB/SDIO Wi-Fi and USB Bluetooth drivers in the
  # image (rtl_bt: Realtek Bluetooth adapters). Only the
  # firmware files those drivers request are copied into the image.
  @alpine_wifi_packages [
    {"main", "musl"},
    {"main", "libcrypto3"},
    {"main", "libssl3"},
    {"main", "libnl3"},
    {"main", "pcsc-lite-libs"},
    {"main", "dbus-libs"},
    {"main", "wpa_supplicant"},
    {"main", "hostapd"},
    {"main", "wireless-regdb"}
  ]

  @alpine_firmware ~w(mediatek rtw88 rtw89 rtlwifi realtek rtl_bt ath9k_htc brcm cypress other)
                   |> Enum.map(&{"main", "linux-firmware-" <> &1})

  def wifi_packages, do: Enum.map(@alpine_wifi_packages, &elem(&1, 1))
  def firmware_packages, do: Enum.map(@alpine_firmware, &elem(&1, 1))

  @ubuntu_mirror "http://ports.ubuntu.com/ubuntu-ports"
  @ubuntu_suites ["noble-updates", "noble"]
  @ubuntu_packages ~w(libc6 libtinfo6 zlib1g libstdc++6 libgcc-s1 libssl3t64)

  @debian_mirror "https://deb.debian.org/debian"
  @debian_suite "trixie"
  @debian_packages ~w(grub-efi-arm64-unsigned)

  def cache_dir, do: Path.join([File.cwd!(), "_build", "lepton", "cache"])
  def extract_dir(name), do: Path.join([cache_dir(), "extract", name])

  @doc "Fetch and extract everything. Returns a map of component => extract dir."
  def fetch_all do
    File.mkdir_p!(cache_dir())
    :inets.start()
    :ssl.start()

    lock =
      Map.new(
        [fetch_otp()] ++
          Enum.map(@alpine_packages ++ @alpine_wifi_packages ++ @alpine_firmware, &fetch_alpine/1) ++
          fetch_debs(@ubuntu_mirror, @ubuntu_suites, @ubuntu_packages, "ubuntu") ++
          fetch_debs(@debian_mirror, [@debian_suite], @debian_packages, "debian")
      )

    File.write!(Path.join(cache_dir(), "sources.lock"), inspect(lock, pretty: true, limit: :infinity))
    lock
  end

  def otp_version, do: @otp_version

  # -- OTP -------------------------------------------------------------------

  defp fetch_otp do
    builds = http_get!("#{@otp_url}/builds.txt")

    sha =
      builds
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, " ") do
          [@otp_version, _ref, _date, sha | _] -> sha
          _ -> nil
        end
      end) || raise "#{@otp_version} not listed in #{@otp_url}/builds.txt"

    file = download!("#{@otp_url}/#{@otp_version}.tar.gz", "#{@otp_version}.tar.gz", sha256: sha)
    dir = extract_dir("otp")
    extract_once!(file, dir)
    {"otp", %{version: @otp_version, sha256: sha, dir: Path.join(dir, @otp_version)}}
  end

  # -- Alpine ----------------------------------------------------------------

  defp fetch_alpine({repo, name}) do
    base = "#{@alpine_mirror}/#{@alpine_branch}/#{repo}/aarch64"
    index = alpine_index(base, repo)
    version = Map.get(index, name) || raise "alpine package #{name} not found"
    apk = "#{name}-#{version}.apk"
    file = download!("#{base}/#{apk}", apk)
    dir = extract_dir(name)
    extract_once!(file, dir)
    {name, %{version: version, dir: dir}}
  end

  defp alpine_index(base, repo) do
    key = {__MODULE__, :alpine, repo}

    case Process.get(key) do
      nil ->
        tgz = download!("#{base}/APKINDEX.tar.gz", "APKINDEX-#{@alpine_branch}-#{repo}.tar.gz", refresh: true)
        # Signed indices are two concatenated gzip streams; let tar cope.
        tmp = Path.join(cache_dir(), "apkindex-#{repo}")
        File.rm_rf!(tmp)
        File.mkdir_p!(tmp)
        system_tar!(tgz, tmp)
        text = File.read!(Path.join(tmp, "APKINDEX"))

        index =
          text
          |> String.split("\n\n", trim: true)
          |> Map.new(fn record ->
            fields =
              for line <- String.split(record, "\n"), String.length(line) > 2, into: %{} do
                {String.at(line, 0), String.slice(line, 2..-1//1)}
              end

            {fields["P"], fields["V"]}
          end)

        Process.put(key, index)
        index

      index ->
        index
    end
  end

  # -- Debian / Ubuntu -------------------------------------------------------

  defp fetch_debs(mirror, suites, packages, distro) do
    indices =
      Enum.map(suites, fn suite ->
        gz = download!("#{mirror}/dists/#{suite}/main/binary-arm64/Packages.gz", "Packages-#{distro}-#{suite}.gz", refresh: true)
        parse_packages(:zlib.gunzip(File.read!(gz)))
      end)

    Enum.map(packages, fn name ->
      pkg = Enum.find_value(indices, &Map.get(&1, name)) || raise "#{distro} package #{name} not found"
      deb = download!("#{mirror}/#{pkg["Filename"]}", Path.basename(pkg["Filename"]), sha256: pkg["SHA256"])
      dir = extract_dir(name)

      unless File.dir?(dir) do
        tmp = dir <> ".tmp"
        File.rm_rf!(tmp)
        File.mkdir_p!(tmp)

        {_name, data} =
          deb |> File.read!() |> LeptonBuild.Ar.entries() |> Enum.find(fn {n, _} -> String.starts_with?(n, "data.tar") end)

        data_file = Path.join(tmp, "data.tar")
        File.write!(data_file, data)
        system_tar!(data_file, tmp)
        File.rm!(data_file)
        File.rename!(tmp, dir)
      end

      {name, %{version: pkg["Version"], sha256: pkg["SHA256"], dir: dir}}
    end)
  end

  defp parse_packages(text) do
    text
    |> String.split("\n\n", trim: true)
    |> Enum.reduce(%{}, fn record, acc ->
      fields =
        for line <- String.split(record, "\n"),
            [k, v] <- [String.split(line, ": ", parts: 2)],
            into: %{},
            do: {k, v}

      # First occurrence wins; indices list newest suite first.
      Map.put_new(acc, fields["Package"], fields)
    end)
  end

  # -- helpers ---------------------------------------------------------------

  defp extract_once!(archive, dir) do
    unless File.dir?(dir) do
      tmp = dir <> ".tmp"
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)
      system_tar!(archive, tmp)
      File.rename!(tmp, dir)
    end
  end

  # Archive formats (gzip, xz, zstd) are decoded by the host's tar; this is
  # build-host plumbing only and never ends up in the image.
  defp system_tar!(archive, dir) do
    {out, status} = System.cmd("tar", ["-xf", archive, "-C", dir], stderr_to_stdout: true)
    # apk archives carry PAX headers bsdtar warns about; only fail on real errors.
    if status != 0 and not String.contains?(out, "Ignoring") do
      raise "tar failed for #{archive}: #{out}"
    end
  end

  def download!(url, name, opts \\ []) do
    dest = Path.join([cache_dir(), "downloads", name])
    File.mkdir_p!(Path.dirname(dest))

    if opts[:refresh] || not File.exists?(dest) do
      Mix.shell().info("  fetch  #{url}")
      File.write!(dest <> ".part", http_get!(url))
      File.rename!(dest <> ".part", dest)
    end

    if sha = opts[:sha256] do
      actual = :crypto.hash(:sha256, File.read!(dest)) |> Base.encode16(case: :lower)

      if actual != String.downcase(sha) do
        File.rm!(dest)
        raise "checksum mismatch for #{name}: expected #{sha}, got #{actual}"
      end
    end

    dest
  end

  defp http_get!(url) do
    ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]

    case :httpc.request(:get, {String.to_charlist(url), []}, [ssl: ssl, timeout: 600_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> body
      {:ok, {{_, code, _}, _, _}} -> raise "GET #{url} -> HTTP #{code}"
      {:error, reason} -> raise "GET #{url} failed: #{inspect(reason)}"
    end
  end
end
