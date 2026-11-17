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

  @otp_apps ~w(kernel stdlib compiler crypto public_key asn1 ssl inets sasl runtime_tools syntax_tools parsetools tools)
  @elixir_apps ~w(elixir eex ex_unit iex logger mix)
  @erts_bins ~w(beam.smp erlexec erl_child_setup inet_gethost epmd)

  # Drivers Lepton's init loads (dependencies are resolved from modules.dep).
  @kernel_modules ~w(
    simpledrm virtio-gpu
    xhci-pci usbhid hid-generic virtio_input evdev
    virtio_net af_packet virtio_rng
    virtio_blk virtio_scsi sr_mod isofs
    usb-storage uas sd_mod nvme ext4
  )

  @lib_dir "/usr/lib/aarch64-linux-gnu"
  @erlang_root "/usr/lib/erlang"

  def build!(opts \\ []) do
    out_dir = opts[:out_dir] || "out"
    dotfiles = opts[:dotfiles] || "dotfiles"
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
      ~w(/bin /dev /etc /etc/ssl /etc/ssl/certs /home /mnt /proc /root /run /sbin /sys /tmp /usr /usr/bin
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
    dir = src["linux-virt"].dir
    [kver] = File.ls!(Path.join(dir, "lib/modules"))
    image = dir |> Path.join("boot/vmlinuz-virt") |> File.read!() |> Kernel.unwrap()
    {image, kver}
  end

  defp kernel_modules(src, kver) do
    root = Path.join([src["linux-virt"].dir, "lib/modules", kver])

    deps =
      root
      |> Path.join("modules.dep")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [mod, rest] = String.split(line, ":", parts: 2)
        {mod, String.split(rest)}
      end)

    by_name = Map.new(Map.keys(deps), &{module_name(&1), &1})

    wanted =
      @kernel_modules
      |> Enum.map(&Map.get(by_name, String.replace(&1, "-", "_")))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&[&1 | deps[&1]])
      |> Enum.uniq()

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
        {:file, "#{dest}/modules.alias", 0o644, {:path, Path.join(root, "modules.alias")}},
        {:file, "#{dest}/modules.builtin", 0o644, {:path, Path.join(root, "modules.builtin")}}
      ]
  end

  defp module_name(path), do: path |> Path.basename() |> String.replace(~r/\.ko(\.gz|\.zst|\.xz)?$/, "") |> String.replace("-", "_")
  defp strip_gz(path), do: String.replace_suffix(path, ".gz", "")

  defp misc_substrate(src) do
    [
      {:file, "/bin/busybox", 0o755, {:path, Path.join(src["busybox-static"].dir, "bin/busybox.static")}},
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
    if File.dir?(dotfiles) do
      for {rel, contents} <- Dotfiles.entries(dotfiles) do
        case contents do
          :dir -> {:dir, "/root/" <> rel, 0o755}
          bin -> {:file, "/root/" <> rel, 0o644, {:data, bin}}
        end
      end ++ [{:file, "/root/.dotfiles-source", 0o644, {:data, Path.expand(dotfiles) <> "\n"}}]
    else
      Mix.shell().info("  (no dotfiles repo at #{dotfiles}; using built-in defaults)")
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
