defmodule Lepton.Persist do
  @moduledoc """
  Persistent storage for an installed system.

  Lepton always runs from its initramfs; an installed disk adds a GPT
  partition named `LEPTON-DATA` (ext2). At boot it is mounted on
  `/persist` and bind-mounted over:

    * `/root`            <- `/persist/root`   (root's home)
    * `/home`            <- `/persist/home`   (users' homes, from the installer)
    * `/var/lib/lepton`  <- `/persist/lepton` (accounts, Wi-Fi, packages, flags)

  On the first boot after installation `/persist/root` is seeded from the
  image's `/root`.
  """

  require Logger
  alias Lepton.Sys

  @state "/var/lib/lepton"

  # LEPTON_STATE_DIR relocates state for tests and hosted mode.
  def state_dir, do: System.get_env("LEPTON_STATE_DIR") || @state
  def state_path(name), do: Path.join(state_dir(), name)
  def installed?, do: :persistent_term.get({__MODULE__, :installed}, false)
  def first_boot?, do: :persistent_term.get({__MODULE__, :first_boot}, false)

  def flag?(name), do: File.exists?(state_path(name))
  def set_flag(name, contents \\ "") do
    File.mkdir_p!(state_dir())
    File.write!(state_path(name), contents)
  end

  @doc """
  Find and mount the data partition. Returns :installed | :live. The
  `lepton.live=1` boot option (the boot menu's "live" entry) leaves it
  alone, as on a machine without one: to erase that disk, say.
  """
  def mount do
    File.mkdir_p!(@state)

    case (not Sys.cmdline_flag?("lepton.live=1")) && data_partition() do
      v when v in [nil, false] ->
        :live

      dev ->
        Lepton.Kmod.modprobe("ext4")
        # A disk made bigger: the partition and its file system grow into it
        # (Lepton.Persist.Grow), before they're mounted.
        if not Sys.cmdline_flag?("lepton.nogrow=1") do
          for {what, from, to} <- Lepton.Persist.Grow.run(dev) do
            Logger.info("persist: grew the data #{what} from #{Lepton.Install.Disk.human(from)} to #{Lepton.Install.Disk.human(to)}")
          end
        end

        case Sys.mount("ext2", dev, "/persist") do
          :ok ->
            first = not File.dir?("/persist/root")
            if first, do: File.cp_r!("/root", "/persist/root")
            File.mkdir_p!("/persist/lepton")
            File.mkdir_p!("/persist/home")
            bind("/persist/root", "/root")
            bind("/persist/home", "/home")
            bind("/persist/lepton", @state)
            :persistent_term.put({__MODULE__, :installed}, true)
            :persistent_term.put({__MODULE__, :first_boot}, first or not flag?("booted"))
            set_flag("booted")
            :installed

          {:error, reason} ->
            Logger.error("persist: cannot mount #{dev}: #{reason}")
            :live
        end
    end
  end

  defp bind(from, to) do
    File.mkdir_p!(to)
    Sys.shim("mount", ["-o", "bind", from, to])
  end

  @doc "The block device of the partition named LEPTON-DATA, if any."
  def data_partition do
    with {:ok, names} <- File.ls("/sys/class/block") do
      Enum.find_value(names, fn n ->
        case File.read("/sys/class/block/#{n}/uevent") do
          {:ok, text} -> if text =~ ~r/^PARTNAME=LEPTON-DATA$/m, do: "/dev/" <> n
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  @doc "Flush and make the data partition read-only (before power off)."
  def shutdown do
    if installed?() do
      # The log is kept there (/var/log): a file open for writing would keep it writable.
      :logger.remove_handler(:lepton_file)
      Sys.sync()
      Sys.shim("mount", ["-o", "remount,ro", "/persist"])
    end

    :ok
  end
end

defmodule Lepton.Installer do
  @moduledoc """
  `lepton-install`: installs Lepton from the boot ISO onto a disk, or
  upgrades the Lepton already there.

  Layout written (all in Elixir - no partitioning or mkfs tools):

      GPT  ┌──────────────┬──────────────────────────────────────┐
           │ LEPTON-OS    │ LEPTON-DATA  (rest of the disk)      │
           │ 512 MiB      │ ext2                                 │
           │ FAT16 (ESP)  │ /home, /root and /var/lib/lepton:    │
           │ GRUB, kernel │ your files, accounts, apps and       │
           │ initramfs    │ settings                             │
           └──────────────┴──────────────────────────────────────┘

  The OS partition is everything Lepton is (it runs from its initramfs);
  the data partition is everything you made. So an **upgrade** rewrites
  the OS partition from a newer ISO and leaves the data partition as it
  is: boot the new ISO and run `lepton-install` (it finds the install and
  offers to upgrade), or, on the installed system, `sudo lepton-install
  --iso lepton.iso` with a downloaded ISO (it runs from memory, so it can
  rewrite its own OS partition; the next boot starts the new release).
  Disks installed before the OS partition was named have a 200 MiB "EFI
  System" partition, which is upgraded the same way while releases fit.

  **Alongside** other systems (`places/1`, `install_into/4`): on a disk
  with partitions, Lepton goes into an empty partition (no filesystem,
  or an empty one) or into free space, never into a system partition
  (EFI, Apple's, Microsoft's) or one with files. LEPTON-OS and LEPTON-DATA
  are made there; every other partition table entry is kept as it was
  (number, IDs, attributes), as is the MBR, and nothing else is written.
  The firmware boots LEPTON-OS: it's the EFI system partition with a boot
  loader in it.

  In UTM: add a VirtIO (or NVMe) drive to the VM, boot the ISO, run
  `lepton-install`, power off, clear the CD/DVD drive, boot again.
  """

  alias Lepton.IO
  alias Lepton.Install.{Disk, Ext2, FAT16, GPT}
  alias Lepton.Media.FS

  @os_mib 512
  @media "/run/install/media"

  def run(args, ctx) do
    {opts, rest} = Lepton.Args.getopt(join_iso(args), "yu:")
    yes = opts["y"] == true || opts["yes"] == true

    with {:ok, media} <- mount_media(ctx, opts["iso"]),
         {:ok, disk, partition} <- choose_disk(ctx, rest),
         {:ok, mode} <- mode(ctx, disk, partition, opts, yes) do
      case mode do
        {:upgrade, existing} -> run_upgrade(ctx, disk, existing, media, opts["iso"] != nil)
        :install -> run_install(ctx, disk, :disk, media, opts, yes)
        {:into, place} -> run_install(ctx, disk, place, media, opts, yes)
      end
    else
      error -> finish(ctx, error)
    end
  end

  # `--iso FILE` as `--iso=FILE` (long options take values after `=`).
  defp join_iso(["--iso", file | rest]), do: ["--iso=" <> file | join_iso(rest)]
  defp join_iso([a | rest]), do: [a | join_iso(rest)]
  defp join_iso([]), do: []

  # `place` is :disk (all of it) or a place on it (`places/1`).
  defp run_install(ctx, disk, place, media, opts, yes) do
    with :ok <- confirm(ctx, disk, place, yes),
         {:ok, account} <- account(ctx, opts) do
      if place == :disk, do: install(ctx, disk, media), else: install_into(ctx, disk, place, media)
      create_account(ctx, disk, account)
      where = if place == :disk, do: disk.path, else: "#{disk.path}, alongside the partitions already there"

      IO.puts(ctx, """

      \e[1;32mLepton is installed on #{where}.\e[0m

      Next steps:
        1. poweroff
        2. In UTM: remove the ISO (CD/DVD -> Clear), then start the VM again.
           With QEMU: boot without -cdrom.
        3. Log in as #{account.name}. Use sudo for administration (sudo poweroff).
           On first boot you'll be offered a short tutorial.

      To upgrade to a newer release later, boot its ISO and run lepton-install
      again: it replaces Lepton and keeps your files, apps and accounts.
      """)

      0
    else
      error -> finish(ctx, error)
    end
  end

  # From an ISO file on the installed system, a restart starts the new
  # release; from a booted ISO, the ISO has to go first.
  defp run_upgrade(ctx, disk, existing, media, iso_file?) do
    case upgrade(ctx, disk, existing, media) do
      {:ok, from, to} ->
        next =
          if iso_file?,
            do: "Restart (sudo reboot) to start the new release.",
            else: "Power off (sudo poweroff), remove the ISO (in UTM: CD/DVD -> Clear) and start the VM again."

        IO.puts(ctx, """

        \e[1;32mLepton on #{disk.path} is upgraded#{if from != to, do: " (build #{from} -> #{to})", else: " (build #{to}, reinstalled)"}.\e[0m
        Your files, apps, accounts and settings were kept.
        #{next}
        """)

        0

      error ->
        finish(ctx, error)
    end
  end

  defp finish(ctx, {:error, msg}) do
    IO.err(ctx, "lepton-install: #{msg}")
    1
  end

  defp finish(ctx, :cancelled) do
    IO.puts(ctx, "Cancelled; nothing was written.")
    1
  end

  # -- install media ---------------------------------------------------------------------

  # The ISO Lepton booted from (a CD, a USB stick), or an ISO file (`--iso`).
  defp mount_media(ctx, iso) when is_binary(iso) do
    path = Lepton.Ctx.path(ctx, iso)
    Lepton.Sys.umount(@media)
    Enum.each(~w(loop isofs), &Lepton.Kmod.modprobe/1)

    cond do
      not File.regular?(path) ->
        {:error, "#{iso}: no such file"}

      Lepton.Sys.mount("iso9660", path, @media, "ro,loop") != :ok ->
        {:error, "#{iso}: can't be read as an ISO image"}

      not File.exists?(Path.join(@media, ".disk/info")) ->
        Lepton.Sys.umount(@media)
        {:error, "#{iso} isn't a Lepton ISO"}

      true ->
        IO.puts(ctx, "Install media: #{iso}")
        {:ok, @media}
    end
  end

  defp mount_media(ctx, _iso) do
    if File.exists?(Path.join(@media, ".disk/info")) do
      {:ok, @media}
    else
      for m <- ~w(sr_mod usb-storage uas sd_mod isofs), do: Lepton.Kmod.modprobe(m)
      Process.sleep(300)

      candidates =
        case File.ls("/sys/block") do
          {:ok, names} -> Enum.filter(names, &Regex.match?(~r/^(sr\d+|sd[a-z]+|vd[a-z]+)$/, &1))
          _ -> []
        end

      found =
        Enum.find_value(candidates, fn name ->
          dev = "/dev/" <> name

          with {:ok, fd} <- :file.open(dev, [:read, :raw, :binary]),
               {:ok, <<1, "CD001", _::binary>>} <- (try do :file.pread(fd, 32768, 64) after :file.close(fd) end),
               :ok <- Lepton.Sys.mount("iso9660", dev, @media, "ro"),
               true <- File.exists?(Path.join(@media, ".disk/info")) do
            IO.puts(ctx, "Install media: #{dev}")
            @media
          else
            _ -> nil
          end
        end)

      if found,
        do: {:ok, found},
        else: {:error, "install media not found (boot from the Lepton ISO, or give a downloaded one: lepton-install --iso lepton.iso)"}
    end
  end

  # -- target disk ---------------------------------------------------------------------------

  # `{:ok, disk, partition}`: a disk, and a partition number when one was named.
  defp choose_disk(ctx, rest) do
    case pick_disk(ctx, rest) do
      {:ok, disk} -> {:ok, disk, nil}
      other -> other
    end
  end

  defp pick_disk(ctx, rest) do
    media_dev = media_device()
    disks = Disk.disks() |> Enum.reject(&(&1.path == media_dev or &1.bytes < 512 * 1024 * 1024))

    case {rest, disks} do
      {[path | _], _} ->
        case {Enum.find(Disk.disks(), &(&1.path == path)), partition_of(path)} do
          {nil, {disk_name, index}} -> {:ok, Enum.find(Disk.disks(), &(&1.name == disk_name)), index}
          {nil, nil} -> {:error, "no such disk or partition: #{path}"}
          {d, _} -> {:ok, d}
        end

      {[], []} ->
        {:error, "no suitable disk found. In UTM add a drive (Drives -> New -> VirtIO, 4 GB or more), then boot again."}

      {[], [only]} ->
        {:ok, only}

      {[], many} ->
        # A disk with Lepton on it is the likely one: upgrading it.
        case Enum.filter(many, &existing(&1)) do
          [one] ->
            {:ok, one}

          _ ->
            IO.puts(ctx, "Available disks:")

            Enum.with_index(many, 1)
            |> Enum.each(fn {d, i} -> IO.puts(ctx, "  #{i}) #{d.path}  #{Disk.human(d.bytes)}  #{d.model}#{if existing(d), do: "  (Lepton is installed)", else: ""}") end)

            case ask(ctx, "Install to which disk? [1-#{length(many)}]: ") do
              nil ->
                :cancelled

              answer ->
                case Integer.parse(answer) do
                  {i, _} when i >= 1 and i <= length(many) -> {:ok, Enum.at(many, i - 1)}
                  _ -> :cancelled
                end
            end
        end
    end
  end

  # /dev/vda3 -> {"vda", 3}, from sysfs.
  defp partition_of("/dev/" <> name) do
    with {:ok, n} <- File.read("/sys/class/block/#{name}/partition"),
         {:ok, link} <- File.read_link("/sys/class/block/#{name}") do
      {link |> Path.dirname() |> Path.basename(), n |> String.trim() |> String.to_integer()}
    else
      _ -> nil
    end
  end

  defp partition_of(_), do: nil

  defp media_device do
    Enum.find_value(Lepton.Sys.mounts(), fn m -> if m.dir == @media, do: m.device end)
  end

  @doc """
  The Lepton installed on `disk`, if any: `%{os, data}` (GPT entries: the
  OS partition, an EFI system partition, and LEPTON-DATA after it).
  """
  def existing(disk) do
    case Disk.open_read(disk.path) do
      {:ok, fd} ->
        try do
          parts = GPT.read(fd)
          data = Enum.find(parts, &(&1.name == "LEPTON-DATA"))

          # LEPTON-OS; on disks from before it was named, the EFI system
          # partition just before the data (another system's comes earlier).
          os =
            data &&
              (Enum.find(parts, &(&1.name == "LEPTON-OS")) ||
                 parts |> Enum.filter(&(&1.type == GPT.guid(GPT.esp_type()) and &1.last < data.first)) |> Enum.max_by(& &1.last, fn -> nil end))

          if os && data, do: %{os: os, data: data}
        after
          :file.close(fd)
        end

      _ ->
        nil
    end
  end

  # Upgrade, install alongside, or erase: `--upgrade`, a partition named
  # on the command line and `--erase` say; otherwise a disk with Lepton is
  # upgraded when asked (and with -y), and on one without, Lepton goes
  # where there's room (an empty partition, free space), or on the whole
  # disk when there's nothing on it.
  defp mode(ctx, disk, partition, opts, yes) do
    found = existing(disk)
    own? = own_disk?(disk)

    cond do
      opts["upgrade"] && found == nil -> {:error, "Lepton isn't installed on #{disk.path} (to install it: lepton-install #{disk.path})"}
      opts["upgrade"] -> {:ok, {:upgrade, found}}
      (opts["erase"] || partition) && own? -> {:error, "#{disk.path}'s data partition is in use (Lepton mounted it at boot), so it can only be upgraded. To erase it, start the ISO again and choose \"live: leave installed disks alone\" in the boot menu"}
      partition -> into_partition(disk, partition)
      opts["erase"] -> {:ok, :install}
      found != nil and (yes or own?) -> {:ok, {:upgrade, found}}
      found != nil -> ask_mode(ctx, disk, found)
      true -> where(ctx, disk, yes)
    end
  end

  defp into_partition(disk, index) do
    layout = places(disk)

    case Enum.find(layout.places, &(&1[:index] == index)) do
      nil ->
        what = Enum.find(layout.parts, &(&1.index == index))
        {:error, "#{part_name(disk, index)} can't take Lepton: #{(what && what.why) || "no such partition"}"}

      place ->
        {:ok, {:into, place}}
    end
  end

  # A disk without Lepton: where to put it.
  defp where(ctx, disk, yes) do
    layout = places(disk)

    cond do
      layout.parts == [] and not layout.mbr -> {:ok, :install}
      yes and layout.places != [] -> {:ok, {:into, hd(layout.places)}}
      yes -> {:error, "#{disk.path} has no empty partition or free space for Lepton (1 GiB or more). To erase the whole disk: lepton-install --erase #{disk.path}"}
      true -> ask_place(ctx, disk, layout)
    end
  end

  defp ask_place(ctx, disk, layout) do
    IO.puts(ctx, "\n#{disk.path} (#{Disk.human(disk.bytes)}, #{disk.model}) has:")

    if layout.mbr and layout.parts == [],
      do: IO.puts(ctx, "  an MBR partition table (Lepton installs alongside GPT ones only)"),
      else: for(p <- layout.parts, do: IO.puts(ctx, "  #{part_name(disk, p.index)}  #{String.pad_leading(Disk.human(p.bytes), 9)}  #{p.what}"))

    choices = Enum.map(layout.places, &{:into, &1}) ++ [:erase]

    IO.puts(ctx, "\nWhere should Lepton go?")

    Enum.with_index(choices, 1)
    |> Enum.each(fn
      {{:into, %{kind: :partition} = pl}, i} -> IO.puts(ctx, "  #{i}) #{part_name(disk, pl.index)}: #{pl.what}, #{Disk.human(pl.bytes)}#{if i == 1, do: " (recommended)"}")
      {{:into, pl}, i} -> IO.puts(ctx, "  #{i}) free space, #{Disk.human(pl.bytes)}#{if i == 1, do: " (recommended)"}")
      {:erase, i} -> IO.puts(ctx, "  #{i}) erase the whole disk (everything on it is lost)")
    end)

    IO.puts(ctx, "Every other partition is left as it is.")

    case ask(ctx, "Choose [1-#{length(choices)}, Enter for 1]: ") do
      nil ->
        :cancelled

      answer ->
        case Integer.parse(if answer == "", do: "1", else: answer) do
          {i, ""} when i >= 1 and i <= length(choices) ->
            case Enum.at(choices, i - 1) do
              :erase -> {:ok, :install}
              choice -> {:ok, choice}
            end

          _ ->
            :cancelled
        end
    end
  end

  defp part_name(disk, index) do
    sep = if disk.path =~ ~r/\d$/, do: "p", else: ""
    "#{disk.path}#{sep}#{index}"
  end

  defp ask_mode(ctx, disk, found) do
    IO.puts(ctx, """

    Lepton is already installed on #{disk.path}#{case installed_build(disk, found) do
      nil -> ""
      b -> " (build #{b})"
    end}.
      u) Upgrade it: replace Lepton with this release, keep your files, apps,
         accounts and settings (the data partition, #{Disk.human((found.data.last - found.data.first + 1) * 512)})
      e) Erase the disk and install from scratch
    """)

    case ask(ctx, "Upgrade or erase? [U/e]: ") do
      a when a in ["", "u", "U", "upgrade"] -> {:ok, {:upgrade, found}}
      a when a in ["e", "E", "erase"] -> {:ok, :install}
      _ -> :cancelled
    end
  end

  # The disk the running system keeps its data on (it can't be erased under it).
  defp own_disk?(disk) do
    Enum.any?(Lepton.Sys.mounts(), &(&1.dir == "/persist" and String.starts_with?(&1.device, disk.path)))
  end

  defp confirm(_ctx, _disk, _place, true), do: :ok

  defp confirm(ctx, disk, :disk, false) do
    IO.puts(ctx, "\n\e[1;31mThis will ERASE everything on #{disk.path} (#{Disk.human(disk.bytes)}, #{disk.model}).\e[0m")
    if ask(ctx, "Type 'yes' to continue: ") == "yes", do: :ok, else: :cancelled
  end

  defp confirm(ctx, disk, place, false) do
    target = if place.kind == :partition, do: "#{part_name(disk, place.index)} (#{place.what})", else: "the free space"
    IO.puts(ctx, "\nLepton will be installed in #{target} on #{disk.path}, #{Disk.human(place.bytes)}. The disk's other partitions are left as they are.")
    if ask(ctx, "Type 'yes' to continue: ") == "yes", do: :ok, else: :cancelled
  end

  defp ask(ctx, prompt) do
    Elixir.IO.write(ctx.stdout, prompt)
    case IO.read_line(ctx.stdin) do
      :eof -> nil
      line -> String.trim(line)
    end
  end

  # -- your account ----------------------------------------------------------------------------

  # The account the installed system logs in with (it may use sudo):
  # asked for, or `-u NAME --password-stdin` for unattended installs.
  defp account(ctx, opts) do
    name = opts["u"] || opts["user"]

    cond do
      is_binary(name) and opts["password-stdin"] ->
        password = case IO.read_line(ctx.stdin) do
          line when is_binary(line) -> String.trim_trailing(line, "\n")
          _ -> ""
        end

        check_account(name, password, name)

      ctx.tty ->
        IO.puts(ctx, "\n\e[1mCreate your user account\e[0m (it can run administrative commands with sudo)")
        ask_account(ctx)

      true ->
        {:error, "a user account is needed: run interactively, or pass -u NAME --password-stdin"}
    end
  end

  defp ask_account(ctx) do
    with name when is_binary(name) and name != "" <- ask(ctx, "User name: "),
         gecos when is_binary(gecos) <- ask(ctx, "Full name (optional): "),
         pass when is_binary(pass) <- Lepton.Setup.read_secret(ctx, "Password: "),
         again when is_binary(again) <- Lepton.Setup.read_secret(ctx, "Password again: ") do
      cond do
        pass != again -> IO.puts(ctx, "The passwords don't match. Try again."); ask_account(ctx)
        true ->
          case check_account(name, pass, if(gecos == "", do: name, else: gecos)) do
            {:error, msg} -> IO.puts(ctx, msg <> ". Try again."); ask_account(ctx)
            ok -> ok
          end
      end
    else
      _ -> :cancelled
    end
  end

  defp check_account(name, password, gecos) do
    cond do
      not Lepton.Users.valid_name?(name) -> {:error, "'#{name}' can't be a user name (lowercase letters, digits, - and _; not a system name)"}
      String.length(password) < 4 -> {:error, "Use a password of at least 4 characters"}
      true -> {:ok, %{name: name, password: password, gecos: gecos}}
    end
  end

  # Mount the new data partition and create the account and its home there.
  defp create_account(ctx, disk, account) do
    step(ctx, "Creating user #{account.name}")
    Lepton.Sys.shim("blockdev", ["--rereadpt", disk.path])
    dev = wait_for_partition(Path.basename(disk.path), 40) || raise "the new data partition did not appear"
    Lepton.Kmod.modprobe("ext2")
    target = "/run/install/data"
    File.mkdir_p!(target)
    :ok = Lepton.Sys.mount("ext2", dev, target)

    try do
      {:ok, _} = Lepton.Users.create(account.name, account.password, gecos: account.gecos, state_dir: Path.join(target, "lepton"), home_root: Path.join(target, "home"))
    after
      Lepton.Sys.umount(target)
    end
  end

  defp wait_for_partition(_disk, 0), do: nil

  defp wait_for_partition(disk, tries) do
    found =
      Enum.find_value(Path.wildcard("/sys/class/block/#{disk}/#{disk}*/uevent"), fn uevent ->
        if File.read!(uevent) =~ ~r/^PARTNAME=LEPTON-DATA$/m, do: "/dev/" <> Path.basename(Path.dirname(uevent))
      end)

    found || (Process.sleep(100); wait_for_partition(disk, tries - 1))
  end

  # -- writing ------------------------------------------------------------------------------

  @doc "Install afresh: partition `disk`, write the OS partition and format the data partition."
  def install(ctx, disk, media) do
    sectors = div(disk.bytes, 512)
    os_first = 2048
    os_last = os_first + @os_mib * 2048 - 1
    data_first = os_last + 1
    data_last = sectors - 34 - 1
    data_last = data_last - rem(data_last - data_first + 1, 8)

    {:ok, fd} = Disk.open(disk.path)

    try do
      step(ctx, "Writing GPT partition table")
      # Clear old signatures at the start of the disk first.
      Disk.zero(fd, 0, 4 * 1024 * 1024)

      for {off, data} <- GPT.build(sectors, [
            %{type: GPT.esp_type(), name: "LEPTON-OS", first: os_first, last: os_last},
            %{type: GPT.linux_type(), name: "LEPTON-DATA", first: data_first, last: data_last}
          ]),
          do: Disk.pwrite(fd, off, data)

      step(ctx, "Writing Lepton to LEPTON-OS (FAT16 EFI system partition: GRUB, kernel and initramfs)")
      write_os(fd, os_first, os_last - os_first + 1, os_files(media))

      step(ctx, "Formatting LEPTON-DATA (ext2, #{Disk.human((data_last - data_first + 1) * 512)})")
      Ext2.format(fd, data_first * 512, (data_last - data_first + 1) * 512)
      :file.sync(fd)
      step(ctx, "Done")
    after
      :file.close(fd)
    end
  end

  # -- alongside other systems ----------------------------------------------------------------

  @min_bytes 1024 * 1024 * 1024

  # Partition types that are never Lepton's to take, whatever is in them:
  # EFI system, BIOS boot, Microsoft reserved and recovery, and Apple's
  # (APFS, HFS+, boot, recovery, Core Storage).
  @system_types [
    "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
    "21686148-6449-6E6F-744E-656564454649",
    "E3C9E316-0B5C-4DB8-817D-F92DF00215AE",
    "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC",
    "7C3457EF-0000-11AA-AA11-00306543ECAC",
    "48465300-0000-11AA-AA11-00306543ECAC",
    "426F6F74-0000-11AA-AA11-00306543ECAC",
    "5265636F-7665-11AA-AA11-00306543ECAC",
    "53746F72-6167-11AA-AA11-00306543ECAC"
  ]

  @doc """
  What is on `disk`, and where Lepton could go without touching anything
  else: `%{parts, places, mbr}`. `parts` are the partitions (`%{index,
  bytes, what, why}`: what it holds, and why Lepton won't take it);
  `places` are, best first, partitions with nothing in them (none of the
  types above, no filesystem, or an empty one) and free space, of 1 GiB
  or more: `%{kind: :partition | :free, index, first, last, bytes, what}`.
  `mbr` says the disk has an old-style (MBR) partition table instead.
  """
  def places(disk) do
    {:ok, fd} = Disk.open_read(disk.path)

    try do
      header = GPT.header(fd)
      parts = if header, do: GPT.read(fd), else: []

      described =
        for p <- parts do
          {fs, label} = FS.detect(fn off, len -> read_at(fd, p.first * 512 + off, len) end)
          bytes = (p.last - p.first + 1) * 512
          system? = Enum.any?(@system_types, &(GPT.guid(&1) == p.type))

          {what, why} =
            cond do
              system? -> {describe(p, fs, label), "it's a system partition (#{p.name})"}
              bytes < @min_bytes -> {describe(p, fs, label), "it's smaller than 1 GiB"}
              fs == nil -> {"empty", nil}
              FS.mountable?(fs) and fs_empty?(disk, p, fs) -> {"empty #{fs}" <> if(label, do: " \"#{label}\"", else: ""), nil}
              true -> {describe(p, fs, label), "it holds a #{fs} filesystem with files in it"}
            end

          Map.merge(p, %{bytes: bytes, what: what, why: why})
        end

      free = if header, do: free_space(header, parts), else: []
      takeable = for p <- described, p.why == nil, do: %{kind: :partition, index: p.index, first: p.first, last: p.last, bytes: p.bytes, what: p.what}

      %{parts: described, places: Enum.sort_by(takeable, &(-&1.bytes)) ++ Enum.sort_by(free, &(-&1.bytes)), mbr: header == nil and mbr_partitions?(fd)}
    after
      :file.close(fd)
    end
  end

  defp describe(p, fs, label) do
    [p.name, fs && "(#{fs}#{if label, do: " \"#{label}\"", else: ""})"] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") |> then(&if(&1 == "", do: "a partition", else: &1))
  end

  defp read_at(fd, off, len) do
    case :file.pread(fd, off, len) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  # Gaps between partitions (aligned to 1 MiB) of 1 GiB or more.
  defp free_space(header, parts) do
    used = parts |> Enum.map(&{&1.first, &1.last}) |> Enum.sort()

    {gaps, at} =
      Enum.reduce(used, {[], header.first_usable}, fn {first, last}, {gaps, at} ->
        {[{at, first - 1} | gaps], max(at, last + 1)}
      end)

    for {first, last} <- Enum.reverse([{at, header.last_usable} | gaps]),
        first = align(first, 2048),
        (last - first + 1) * 512 >= @min_bytes,
        do: %{kind: :free, index: nil, first: first, last: last, bytes: (last - first + 1) * 512, what: "free space"}
  end

  defp align(n, a), do: div(n + a - 1, a) * a

  # An MBR (not a protective one) with partitions in it.
  defp mbr_partitions?(fd) do
    case :file.pread(fd, 446, 66) do
      {:ok, <<entries::binary-64, 0x55, 0xAA>>} -> Enum.any?(for(<<_::binary-4, type, _::binary-11 <- entries>>, do: type), &(&1 not in [0, 0xEE]))
      _ -> false
    end
  end

  # A filesystem with nothing in it but what systems leave in new ones.
  @leftovers [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store", "System Volume Information", "lost+found", "$RECYCLE.BIN"]

  defp fs_empty?(disk, part, fs) do
    with dev when dev != nil <- partition_device(disk, part.index),
         _ <- Enum.each(Map.get(%{"vfat" => ~w(nls_cp437 nls_iso8859-1 vfat), "exfat" => ~w(exfat), "ntfs3" => ~w(ntfs3), "ext4" => ~w(ext4)}, fs, []), &Lepton.Kmod.modprobe/1),
         dir = "/run/install/check",
         :ok <- Lepton.Sys.mount(fs, dev, dir, "ro") do
      try do
        case File.ls(dir) do
          {:ok, names} -> Enum.all?(names, &(&1 in @leftovers or String.starts_with?(&1, "._")))
          _ -> false
        end
      after
        Lepton.Sys.umount(dir)
      end
    else
      _ -> false
    end
  end

  @doc """
  Install into one place on `disk` (`places/1`): LEPTON-OS and LEPTON-DATA
  are made there, and the partition table keeps every other partition as
  it was (its number, IDs, attributes); nothing else on the disk is written.
  """
  def install_into(ctx, disk, place, media) do
    {:ok, fd} = Disk.open(disk.path)
    sectors = div(disk.bytes, 512)

    try do
      header = GPT.header(fd)
      kept = Enum.reject(GPT.read(fd), &(&1.index == place[:index]))
      first = align(place.first, 2048)
      os_last = first + @os_mib * 2048 - 1
      data_first = os_last + 1
      data_last = place.last - rem(place.last - data_first + 1, 8)
      if data_last - data_first + 1 < 256 * 2048, do: raise("not enough room for Lepton there")

      # LEPTON-OS takes the partition's number; LEPTON-DATA the first free one.
      taken = MapSet.new(kept, & &1.index)
      os_index = place[:index] || Enum.find(1..128, &(not MapSet.member?(taken, &1)))
      data_index = Enum.find(1..128, &(not MapSet.member?(taken, &1) and &1 != os_index))

      partitions =
        kept ++
          [
            %{index: os_index, type: GPT.esp_type(), name: "LEPTON-OS", first: first, last: os_last},
            %{index: data_index, type: GPT.linux_type(), name: "LEPTON-DATA", first: data_first, last: data_last}
          ]

      step(ctx, "Writing the partition table (keeping #{length(kept)} partition#{if length(kept) == 1, do: "", else: "s"} as they are)")

      # (the MBR stays: the disk's other systems may rely on theirs)
      for {off, data} <- GPT.build(sectors, partitions, header.disk_guid), off != 0, do: Disk.pwrite(fd, off, data)

      step(ctx, "Writing Lepton to LEPTON-OS (FAT16 EFI system partition: GRUB, kernel and initramfs)")
      write_os(fd, first, os_last - first + 1, os_files(media))

      step(ctx, "Formatting LEPTON-DATA (ext2, #{Disk.human((data_last - data_first + 1) * 512)})")
      Ext2.format(fd, data_first * 512, (data_last - data_first + 1) * 512)
      :file.sync(fd)
      step(ctx, "Done")
    after
      :file.close(fd)
    end

    # The kernel reads the new table only with nothing on the disk mounted.
    for m <- Lepton.Sys.mounts(), String.starts_with?(m.device, disk.path), String.starts_with?(m.dir, "/media/"), do: Lepton.Sys.umount(m.dir)
    :ok
  end

  @doc """
  Upgrade: write this release to the OS partition of `existing` and leave
  every other byte of the disk alone. `{:ok, old_build, new_build}`.
  """
  def upgrade(ctx, disk, existing, media) do
    files = os_files(media)
    %{os: os} = existing
    sectors = os.last - os.first + 1

    case FAT16.fits?(sectors, files) do
      {:error, need, free} ->
        {:error,
         "this release (#{Disk.human(need)}) doesn't fit in #{disk.path}'s OS partition (#{Disk.human(free)}). " <>
           "Copy your files elsewhere, then install afresh: lepton-install --erase #{disk.path}"}

      :ok ->
        from = installed_build(disk, existing) || "unknown"
        {_, info} = List.keyfind(files, "BOOT/INFO", 0)
        to = info |> elem(1) |> build_of()
        step(ctx, "Upgrading Lepton on #{disk.path} (build #{from} -> #{to}); your data partition is not touched")
        {:ok, fd} = Disk.open(disk.path)

        try do
          write_os(fd, os.first, sectors, files)
          :file.sync(fd)
        after
          :file.close(fd)
        end

        step(ctx, "Done")
        {:ok, from, to}
    end
  end

  defp write_os(fd, first, sectors, files), do: FAT16.format(fd, first * 512, sectors, first, files)

  # What the OS partition holds: GRUB, its configuration, the kernel and
  # initramfs, and BOOT/INFO (the release and its build: a hash of the
  # kernel and initramfs, the same for the same release).
  defp os_files(media) do
    grub_cfg = File.read!(Path.join(media, "boot/grub/grub.cfg"))
    kernel = Path.join(media, "boot/vmlinuz")
    initrd = Path.join(media, "boot/initrd.img")
    info = String.trim(File.read!(Path.join(media, ".disk/info"))) <> "\nbuild #{build([kernel, initrd])}\n"

    [
      {"EFI/BOOT/BOOTAA64.EFI", {:path, Path.join(media, "EFI/BOOT/BOOTAA64.EFI")}},
      {"EFI/BOOT/GRUB.CFG", {:data, grub_cfg}},
      {"BOOT/GRUB/GRUB.CFG", {:data, grub_cfg}},
      {"BOOT/VMLINUZ", {:path, kernel}},
      {"BOOT/INITRD.IMG", {:path, initrd}},
      {"BOOT/INFO", {:data, info}}
    ]
  end

  @doc "A release's build id: the first 12 hex digits of SHA-256 over its files."
  def build(paths) do
    paths
    |> Enum.reduce(:crypto.hash_init(:sha256), fn p, h -> File.stream!(p, 1_048_576) |> Enum.reduce(h, &:crypto.hash_update(&2, &1)) end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp build_of(info) do
    case Regex.run(~r/^build (\w+)$/m, info) do
      [_, b] -> b
      _ -> nil
    end
  end

  # The build on the disk's OS partition (BOOT/INFO; older installs have no build line).
  defp installed_build(disk, %{os: os}) do
    with dev when dev != nil <- partition_device(disk, os.index),
         # (vfat's default character sets too)
         _ <- Enum.each(~w(nls_cp437 nls_iso8859-1 vfat), &Lepton.Kmod.modprobe/1),
         dir = "/run/install/os",
         :ok <- Lepton.Sys.mount("vfat", dev, dir, "ro") do
      try do
        # (uppercase 8.3 names, which the kernel matches only as written)
        case File.read(Path.join(dir, "BOOT/INFO")) do
          {:ok, info} -> build_of(info) || "from before builds were recorded"
          _ -> nil
        end
      after
        Lepton.Sys.umount(dir)
      end
    else
      _ -> nil
    end
  end

  # /dev/vda1, /dev/nvme0n1p1: the partition numbered `index` of `disk`.
  defp partition_device(disk, index) do
    name = Path.basename(disk.path)

    Enum.find_value(Path.wildcard("/sys/class/block/#{name}/#{name}*/partition"), fn f ->
      if String.trim(File.read!(f)) == to_string(index), do: "/dev/" <> Path.basename(Path.dirname(f))
    end)
  end

  defp step(ctx, text), do: IO.puts(ctx, "\e[1;36m==>\e[0m " <> text)
end
