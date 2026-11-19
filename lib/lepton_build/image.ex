defmodule LeptonBuild.Image do
  @moduledoc """
  Assembles the Lepton root filesystem (initramfs) and the bootable ISO.

      substrate (fetched)              Lepton (this repo)
      ─────────────────────────────    ──────────────────────────────
      Linux kernel + modules           lib/lepton/**  -> lepton app
      ERTS + OTP apps + glibc libs     Elixir stdlib apps (pure .beam)
      GRUB (EFI), CA bundle            rootfs/ overlay, dotfiles -> /root
      busybox (syscall shim only)      test/ -> /usr/share/lepton/test
  """

  alias LeptonBuild.{Cpio, Dotfiles, ELF, FAT, ISO9660, Kernel, Sources}

  @otp_apps ~w(kernel stdlib compiler crypto public_key asn1 ssl ssh inets sasl runtime_tools syntax_tools parsetools tools)
  @elixir_apps ~w(elixir eex ex_unit iex logger mix)
  @erts_bins ~w(beam.smp erlexec erl_child_setup inet_gethost epmd)

  # Drivers Lepton's init loads (dependencies are resolved from modules.dep).
  # linux-lts builds the virtio transports, virtio_console (hvc0) and ext2
  # as modules, where linux-virt had them built in.
  @kernel_modules ~w(
    virtio_pci virtio_mmio virtio_console ext2
    simpledrm virtio-gpu
    xhci-pci ehci-pci ohci-pci usbhid hid-generic virtio_input evdev
    virtio_net af_packet virtio_rng
    virtio_blk virtio_scsi sr_mod isofs
    usb-storage uas sd_mod nvme ext4
    gpio-pl061 button
  )

  # USB devices loaded by hardware ID when they appear (directly or through
  # a hub or dock; Lepton.USB): display adapters (DisplayLink's older
  # DL-1x0/1x5 chips, and Generic USB Display gadgets), the Ethernet ports
  # of docks and adapters, and keyboards, mice, touchpads and tablets that
  # need more than hid-generic.
  @usb_modules ~w(
    udl gud
    r8152 ax88179_178a cdc_ether cdc_ncm asix
    hid-apple hid-magicmouse hid-logitech-dj hid-logitech-hidpp hid-microsoft
    hid-multitouch hid-lenovo hid-cherry hid-asus hid-elan wacom
  )

  # Removable storage (Lepton.Media): SD card slots and USB card readers,
  # and the filesystems USB drives and SD cards come with.
  @storage_modules ~w(
    mmc_block sdhci-pci sdhci-pltfm sdhci-iproc bcm2835 rtsx_usb_sdmmc ums-realtek
    vfat exfat ntfs3 udf nls_cp437 nls_utf8 nls_iso8859-1
  )

  # Bluetooth (Lepton.Bluetooth): the stack, USB adapters (with Realtek's,
  # Broadcom's, Intel's and MediaTek's setup, as btusb's dependencies),
  # classic and Low Energy input devices, and virtual adapters for tests.
  # The rest of Bluetooth (BlueZ) is an app, installed when wanted.
  @bluetooth_modules ~w(bluetooth btusb hidp uhid hci_vhci)

  # Sound (Lepton.Sound): Intel HD Audio (QEMU's and UTM's sound device)
  # with the generic codec driver, virtio-sound, and USB audio. Loaded by
  # hardware ID.
  @sound_modules ~w(snd-hda-intel snd-hda-codec-generic virtio_snd snd-usb-audio)

  # Wi-Fi: the 802.11 stack, the crypto WPA uses (the kernel would request
  # these on demand), the simulated radios the self-tests use, and drivers
  # for common USB Wi-Fi adapters and SDIO chips (Raspberry Pi). They are
  # loaded when matching hardware appears (Lepton.Kmod.load_for_hardware/0).
  @wifi_modules ~w(
    cfg80211 mac80211 mac80211_hwsim
    ccm gcm ctr cmac michael_mic aes-ce-ccm aes-ce-blk ghash-ce
    mt7601u mt76x0u mt76x2u mt7921u rt2800usb rt73usb rt2500usb
    rtl8xxxu rtl8192cu rtw88_8723du rtw88_8812au rtw88_8814au rtw88_8821au
    rtw88_8821cu rtw88_8822bu rtw88_8822cu rtw89_8851bu rtw89_8852bu
    ath9k_htc carl9170 ath6kl_usb p54usb rsi_usb mwifiex_usb
    brcmfmac brcmfmac-cyw brcmfmac-bca brcmfmac-wcc
  )

  # The musl-linked Wi-Fi programs (Alpine), kept apart from ERTS's glibc
  # libraries: binaries in /usr/libexec/lepton, libraries in /usr/lib/musl.
  @musl_programs [{"wpa_supplicant", "sbin/wpa_supplicant"}, {"hostapd", "usr/sbin/hostapd"}]
  @musl_lib_dir "/usr/lib/musl"

  @lib_dir "/usr/lib/aarch64-linux-gnu"
  @erlang_root "/usr/lib/erlang"

  def build!(opts \\ []) do
    out_dir = opts[:out_dir] || "out"
    dotfiles = opts[:dotfiles] || LeptonBuild.Paths.dotfiles()
    File.mkdir_p!(out_dir)

    info("fetching substrate")
    src = Sources.fetch_all()

    info("assembling root filesystem")
    {kernel_image, kver} = kernel(src)
    otp_dir = src["otp"].dir
    erts = otp_dir |> File.ls!() |> Enum.find(&String.starts_with?(&1, "erts-"))
    otp_release = otp_dir |> Path.join("releases") |> File.ls!() |> Enum.find(&(&1 =~ ~r/^\d+$/))

    entries =
      base_layout() ++
        otp(otp_dir, erts, otp_release) ++
        elixir_apps() ++
        lepton_app() ++
        shared_libs(src, otp_dir, erts) ++
        kernel_modules(src, kver) ++
        firmware(src, kver) ++
        musl_programs(src) ++
        misc_substrate(src) ++
        overlay("rootfs") ++
        tests() ++
        home(dotfiles)

    entries = normalize(entries)

    initrd = Path.join(out_dir, "initrd.img")
    info("writing #{initrd} (#{length(entries)} entries)")
    Cpio.write_gzip!(entries, initrd)

    kernel_path = Path.join(out_dir, "vmlinuz")
    File.write!(kernel_path, kernel_image)

    grub_cfg = grub_cfg(erts, otp_release)
    File.write!(Path.join(out_dir, "grub.cfg"), grub_cfg)

    grub_efi = Path.join(src["grub-efi-arm64-unsigned"].dir, "usr/lib/grub/arm64-efi/monolithic/gcdaa64.efi")

    efi_img =
      FAT.image([
        {"EFI/BOOT/BOOTAA64.EFI", File.read!(grub_efi)},
        {"EFI/BOOT/GRUB.CFG", fallback_grub_cfg()}
      ])

    iso = Path.join(out_dir, "lepton.iso")
    info("writing #{iso}")

    size =
      ISO9660.write!(
        iso,
        [
          {"/boot/vmlinuz", {:path, kernel_path}},
          {"/boot/initrd.img", {:path, initrd}},
          {"/boot/grub/grub.cfg", {:data, grub_cfg}},
          {"/EFI/BOOT/BOOTAA64.EFI", {:path, grub_efi}},
          {"/.disk/info", {:data, "Lepton OS #{version()} aarch64\n"}},
          {"/README.TXT", {:data, readme()}}
        ],
        efi_img,
        volume_id: "LEPTON"
      )

    info("done: #{iso} (#{div(size, 1024 * 1024)} MiB, kernel #{kver}, #{Sources.otp_version()})")
    iso
  end

  def version, do: Application.spec(:lepton, :vsn) |> to_string()

  def kernel_cmdline(erts, otp_release, extra \\ "") do
    env =
      "BINDIR=#{@erlang_root}/#{erts}/bin ROOTDIR=#{@erlang_root} EMU=beam PROGNAME=erl HOME=/root TERM=linux"

    erl_args =
      "-noshell -noinput -boot #{@erlang_root}/releases/#{otp_release}/start_clean " <>
        "+fnu +sbwt none +sbwtdcpu none +sbwtdio none +Bi -s Elixir.Lepton.Init main"

    "console=ttyAMA0 console=hvc0 console=tty0 quiet loglevel=3 panic=10 rdinit=/init #{extra} #{env} -- #{erl_args}"
    |> String.replace(~r/\s+/, " ")
  end

  defp grub_cfg(erts, otp_release) do
    """
    set timeout=3
    set default=0
    insmod all_video
    insmod gzio

    menuentry "Lepton OS #{version()}" {
      linux /boot/vmlinuz #{kernel_cmdline(erts, otp_release)}
      initrd /boot/initrd.img
    }

    menuentry "Lepton OS #{version()} (verbose boot)" {
      linux /boot/vmlinuz #{kernel_cmdline(erts, otp_release) |> String.replace(" quiet loglevel=3", "")} lepton.verbose=1
      initrd /boot/initrd.img
    }

    menuentry "Lepton OS #{version()} (run self-tests on boot)" {
      linux /boot/vmlinuz #{kernel_cmdline(erts, otp_release, "lepton.selftest=1")}
      initrd /boot/initrd.img
    }
    """
  end

  defp fallback_grub_cfg do
    """
    search --no-floppy --file --set=root /.disk/info
    set prefix=($root)/boot/grub
    configfile ($root)/boot/grub/grub.cfg
    """
  end

  defp readme do
    """
    Lepton OS #{version()} - a Unix-like operating system written in Elixir.

    Boot this image in UTM (Virtualize > Linux, or Emulate > ARM64 virt)
    or with QEMU:  mix lepton.qemu
    """
  end

  # -- pieces --------------------------------------------------------------------

  defp base_layout do
    dirs =
      ~w(/bin /dev /etc /etc/skel /etc/ssl /etc/ssl/certs /home /mnt /proc /root /run /sbin /sys /tmp /usr /usr/bin
         /usr/lib /usr/share /usr/share/lepton /var /var/log /var/tmp)

    Enum.map(dirs, &{:dir, &1, if(&1 in ["/tmp", "/var/tmp"], do: 0o1777, else: 0o755)}) ++
      [
        {:symlink, "/lib", "usr/lib"},
        {:chardev, "/dev/console", 0o600, 5, 1},
        {:chardev, "/dev/null", 0o666, 1, 3},
        {:chardev, "/dev/tty", 0o666, 5, 0},
        {:symlink, "/init", "#{String.trim_leading(@erlang_root, "/")}/bin/erlexec"}
      ]
  end

  defp otp(otp_dir, erts, otp_release) do
    erts_bin = Path.join([otp_dir, erts, "bin"])

    bins =
      for b <- @erts_bins, File.exists?(Path.join(erts_bin, b)) do
        {:file, "#{@erlang_root}/#{erts}/bin/#{b}", 0o755, {:path, Path.join(erts_bin, b)}}
      end

    apps =
      for app <- @otp_apps,
          dir = find_app(Path.join(otp_dir, "lib"), app),
          entry <- copy_app(dir, "#{@erlang_root}/lib/#{Path.basename(dir)}") do
        entry
      end

    release =
      for f <- ~w(start_clean.boot start_clean.script OTP_VERSION) do
        {:file, "#{@erlang_root}/releases/#{otp_release}/#{f}", 0o644,
         {:path, Path.join([otp_dir, "releases", otp_release, f])}}
      end

    bins ++
      apps ++
      release ++
      [
        {:symlink, "#{@erlang_root}/bin/erlexec", "../#{erts}/bin/erlexec"},
        {:file, "#{@erlang_root}/bin/start_clean.boot", 0o644,
         {:path, Path.join([otp_dir, "releases", otp_release, "start_clean.boot"])}}
      ]
  end

  defp find_app(lib, app) do
    lib |> File.ls!() |> Enum.find(&(&1 == app or String.starts_with?(&1, app <> "-"))) |> then(&(&1 && Path.join(lib, &1)))
  end

  defp copy_app(dir, dest) do
    for sub <- ["ebin", "priv"],
        root = Path.join(dir, sub),
        File.dir?(root),
        file <- Path.wildcard(Path.join(root, "**/*"), match_dot: true),
        File.regular?(file),
        not String.contains?(file, ["/priv/obj/", "/priv/src/", "otp_test_engine"]) do
      rel = Path.relative_to(file, dir)
      mode = if executable?(file), do: 0o755, else: 0o644
      {:file, Path.join(dest, rel), mode, {:path, file}}
    end
  end

  defp executable?(file) do
    import Bitwise
    (File.stat!(file).mode &&& 0o111) != 0
  end

  defp elixir_apps do
    for app <- @elixir_apps,
        dir = :code.lib_dir(String.to_atom(app)) |> to_string(),
        entry <- copy_app(dir, "#{@erlang_root}/lib/#{app}-#{System.version()}") do
      entry
    end
  end

  # The lepton app minus build tooling (LeptonBuild.* and Mix tasks).
  defp lepton_app do
    ebin = Path.join(Mix.Project.app_path(), "ebin")
    dest = "#{@erlang_root}/lib/lepton-#{version()}/ebin"

    beams =
      for file <- Path.wildcard(Path.join(ebin, "*.beam")),
          name = Path.basename(file, ".beam"),
          shipped?(name) do
        {name, {:file, Path.join(dest, Path.basename(file)), 0o644, {:path, file}}}
      end

    {:ok, [{:application, :lepton, props}]} = :file.consult(Path.join(ebin, "lepton.app"))
    modules = for {name, _} <- beams, do: String.to_atom(name)
    props = Keyword.put(props, :modules, modules)
    app_file = :io_lib.format(~c"~p.~n", [{:application, :lepton, props}]) |> IO.iodata_to_binary()

    [{:file, Path.join(dest, "lepton.app"), 0o644, {:data, app_file}} | Enum.map(beams, &elem(&1, 1))]
  end

  defp shipped?(module) do
    not String.starts_with?(module, ["Elixir.LeptonBuild", "Elixir.Mix.Tasks."])
  end

  defp shared_libs(src, otp_dir, erts) do
    # soname -> host path, from every extracted Ubuntu package.
    available =
      for pkg <- ~w(libc6 libtinfo6 zlib1g libstdc++6 libgcc-s1 libssl3t64),
          dir <- [Path.join(src[pkg].dir, "usr/lib/aarch64-linux-gnu"), Path.join(src[pkg].dir, "lib/aarch64-linux-gnu")],
          File.dir?(dir),
          file <- File.ls!(dir),
          String.contains?(file, ".so"),
          into: %{} do
        {file, Path.join(dir, file)}
      end

    roots =
      Enum.map(@erts_bins, &Path.join([otp_dir, erts, "bin", &1])) ++
        Path.wildcard(Path.join(otp_dir, "lib/{#{Enum.join(@otp_apps, ",")}}-*/priv/lib/*.so"))

    needed = closure(roots |> Enum.filter(&File.exists?/1), available, MapSet.new())

    libs =
      for soname <- Enum.sort(needed) do
        {:file, "#{@lib_dir}/#{soname}", 0o755, {:path, Map.fetch!(available, soname)}}
      end

    links =
      for soname <- Enum.sort(needed) do
        {:symlink, "/usr/lib/#{soname}", "aarch64-linux-gnu/#{soname}"}
      end

    libs ++ links ++ [{:file, "/etc/ld.so.conf", 0o644, {:data, "#{@lib_dir}\n"}}]
  end

  defp closure([], _available, acc), do: acc

  defp closure([file | rest], available, acc) do
    new =
      file
      |> File.read!()
      |> ELF.needed()
      |> Enum.reject(&MapSet.member?(acc, &1))

    missing = Enum.reject(new, &Map.has_key?(available, &1))
    if missing != [], do: raise("unresolved shared libraries for #{file}: #{inspect(missing)}")

    closure(rest ++ Enum.map(new, &available[&1]), available, Enum.reduce(new, acc, &MapSet.put(&2, &1)))
    |> MapSet.put("ld-linux-aarch64.so.1")
  end

  defp kernel(src) do
    dir = src["linux-lts"].dir
    [kver] = File.ls!(Path.join(dir, "lib/modules"))
    image = dir |> Path.join("boot/vmlinuz-lts") |> File.read!() |> Kernel.unwrap()
    {image, kver}
  end

  defp modules_root(src, kver), do: Path.join([src["linux-lts"].dir, "lib/modules", kver])

  # modules.dep paths of `names` and everything they depend on.
  defp module_closure(root, names) do
    deps = module_deps(root)
    by_name = Map.new(Map.keys(deps), &{module_name(&1), &1})

    names
    |> Enum.map(fn n -> Map.get(by_name, String.replace(n, "-", "_")) || raise("kernel module #{n} not found") end)
    |> Enum.flat_map(&[&1 | deps[&1]])
    |> Enum.uniq()
  end

  defp module_deps(root) do
    root
    |> Path.join("modules.dep")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [mod, rest] = String.split(line, ":", parts: 2)
      {mod, String.split(rest)}
    end)
  end

  defp kernel_modules(src, kver) do
    root = modules_root(src, kver)

    deps = module_deps(root)
    wanted = module_closure(root, @kernel_modules ++ @usb_modules ++ @storage_modules ++ @sound_modules ++ @bluetooth_modules ++ @wifi_modules)
    shipped = MapSet.new(wanted, &module_name/1)

    # Aliases of the shipped modules only, for loading drivers by hardware
    # ID (Lepton.Kmod) and for the kernel's on-demand requests (modprobe).
    aliases =
      root
      |> Path.join("modules.alias")
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(fn line ->
        match?(["alias", _, _], String.split(line)) and MapSet.member?(shipped, String.replace(List.last(String.split(line)), "-", "_"))
      end)

    dest = "/usr/lib/modules/#{kver}"

    files =
      for mod <- wanted do
        data = File.read!(Path.join(root, mod))
        data = if String.ends_with?(mod, ".gz"), do: :zlib.gunzip(data), else: data
        {:file, "#{dest}/#{strip_gz(mod)}", 0o644, {:data, data}}
      end

    dep_lines =
      for mod <- wanted, do: "#{strip_gz(mod)}: #{Enum.map_join(deps[mod], " ", &strip_gz/1)}" |> String.trim_trailing()

    files ++
      [
        {:file, "#{dest}/modules.dep", 0o644, {:data, Enum.join(dep_lines, "\n") <> "\n"}},
        {:file, "#{dest}/modules.alias", 0o644, {:data, Enum.join(aliases, "\n") <> "\n"}},
        {:file, "#{dest}/modules.builtin", 0o644, {:path, Path.join(root, "modules.builtin")}}
      ]
  end

  # Firmware the shipped Wi-Fi and Bluetooth drivers request (their `firmware=` modinfo,
  # which may be a glob), from the Alpine firmware packages, plus the
  # wireless regulatory database cfg80211 reads.
  defp firmware(src, kver) do
    root = modules_root(src, kver)
    dirs = Enum.map(Sources.firmware_packages(), &Path.join(src[&1].dir, "lib/firmware"))

    names =
      for mod <- module_closure(root, @wifi_modules ++ @bluetooth_modules),
          [_, name] <- Regex.scan(~r/(?:^|\0)firmware=([^\0]+)/, read_module(Path.join(root, mod))),
          uniq: true,
          do: name

    files =
      for name <- names, dir <- dirs, file <- Path.wildcard(Path.join(dir, name <> "{,.zst,.xz}")), File.regular?(file), uniq: true do
        rel = Path.relative_to(file, dir)
        {:file, "/usr/lib/firmware/" <> rel, 0o644, {:path, file}}
      end

    regdb = Path.join(src["wireless-regdb"].dir, "lib/firmware")

    files ++
      for f <- ~w(regulatory.db regulatory.db.p7s), do: {:file, "/usr/lib/firmware/" <> f, 0o644, {:path, Path.join(regdb, f)}}
  end

  defp read_module(path) do
    data = File.read!(path)
    if String.ends_with?(path, ".gz"), do: :zlib.gunzip(data), else: data
  end

  defp musl_programs(src) do
    pkgs = Sources.wifi_packages()

    available =
      for pkg <- pkgs, sub <- ["lib", "usr/lib"], dir = Path.join(src[pkg].dir, sub), File.dir?(dir),
          file <- File.ls!(dir), String.contains?(file, ".so"), into: %{} do
        {file, Path.join(dir, file)}
      end

    bins = for {pkg, rel} <- @musl_programs, do: Path.join(src[pkg].dir, rel)
    needed = musl_closure(bins, available, MapSet.new()) |> MapSet.delete("libc.musl-aarch64.so.1")
    musl = Path.join(src["musl"].dir, "lib/ld-musl-aarch64.so.1")

    [{:dir, "/usr/libexec", 0o755}, {:dir, "/usr/libexec/lepton", 0o755}, {:dir, @musl_lib_dir, 0o755}] ++
      for({name, rel} <- @musl_programs, do: {:file, "/usr/libexec/lepton/#{name}", 0o755, {:path, Path.join(src[name].dir, rel)}}) ++
      for(soname <- Enum.sort(needed), do: {:file, "#{@musl_lib_dir}/#{soname}", 0o755, {:path, available[soname]}}) ++
      [
        # The interpreter musl binaries name; /lib is /usr/lib.
        {:file, "/usr/lib/ld-musl-aarch64.so.1", 0o755, {:path, musl}},
        {:symlink, "#{@musl_lib_dir}/libc.musl-aarch64.so.1", "../ld-musl-aarch64.so.1"},
        # Search only Alpine's libraries: /usr/lib also holds glibc's libssl.
        {:file, "/etc/ld-musl-aarch64.path", 0o644, {:data, @musl_lib_dir <> "\n"}}
      ]
  end

  defp musl_closure([], _available, acc), do: acc

  defp musl_closure([file | rest], available, acc) do
    new = file |> File.read!() |> ELF.needed() |> Enum.reject(&(MapSet.member?(acc, &1) or &1 == "libc.musl-aarch64.so.1"))
    missing = Enum.reject(new, &Map.has_key?(available, &1))
    if missing != [], do: raise("unresolved musl libraries for #{file}: #{inspect(missing)}")
    musl_closure(rest ++ Enum.map(new, &available[&1]), available, Enum.reduce(new, acc, &MapSet.put(&2, &1)))
  end

  defp module_name(path), do: path |> Path.basename() |> String.replace(~r/\.ko(\.gz|\.zst|\.xz)?$/, "") |> String.replace("-", "_")
  defp strip_gz(path), do: String.replace_suffix(path, ".gz", "")

  defp misc_substrate(src) do
    [
      {:file, "/bin/busybox", 0o755, {:path, Path.join(src["busybox-static"].dir, "bin/busybox.static")}},
      # The kernel runs /sbin/modprobe to load modules on demand (crypto for
      # WPA, for example); busybox's applet reads modules.dep and .alias.
      {:symlink, "/sbin/modprobe", "../bin/busybox"},
      {:file, "/etc/ssl/certs/ca-certificates.crt", 0o644,
       {:path, Path.join(src["ca-certificates-bundle"].dir, "etc/ssl/certs/ca-certificates.crt")}}
    ]
  end

  defp overlay(dir) do
    for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true) do
      dest = "/" <> Path.relative_to(file, dir)

      if File.dir?(file),
        do: {:dir, dest, 0o755},
        else: {:file, dest, if(executable?(file), do: 0o755, else: 0o644), {:path, file}}
    end
  end

  defp tests do
    for file <- Path.wildcard("test/**/*.{exs,ex,txt}") do
      {:file, "/usr/share/lepton/" <> file, 0o644, {:path, file}}
    end
  end

  defp home(dotfiles) do
    if dotfiles && File.dir?(dotfiles) do
      # root's home, and /etc/skel: the starting point of every user's home.
      for base <- ["/root/", "/etc/skel/"], {rel, contents} <- Dotfiles.entries(dotfiles) do
        case contents do
          :dir -> {:dir, base <> rel, 0o755}
          bin -> {:file, base <> rel, 0o644, {:data, bin}}
        end
      end ++ [{:file, "/root/.dotfiles-source", 0o644, {:data, Path.expand(dotfiles) <> "\n"}}]
    else
      Mix.shell().info("  (no dotfiles repo#{if dotfiles, do: " at #{dotfiles}"}; using built-in defaults - pass --dotfiles PATH)")
      []
    end
  end

  # Add missing parent directories, drop duplicates (last wins), sort so
  # parents precede children.
  defp normalize(entries) do
    by_path = Enum.reduce(entries, %{}, fn e, acc -> Map.put(acc, elem(e, 1), e) end)

    parents =
      for {path, _} <- by_path,
          parent <- ancestors(path),
          not Map.has_key?(by_path, parent),
          into: %{} do
        {parent, {:dir, parent, 0o755}}
      end

    by_path
    |> Map.merge(parents)
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp ancestors(path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reject(&(&1 == "/"))
  end

  defp info(msg), do: Mix.shell().info([:cyan, "==> ", :reset, msg])
end
