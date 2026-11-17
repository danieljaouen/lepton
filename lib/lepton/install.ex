defmodule Lepton.Persist do
  @moduledoc """
  Persistent storage for an installed system.

  Lepton always runs from its initramfs; an installed disk adds a GPT
  partition named `LEPTON-DATA` (ext2). At boot it is mounted on
  `/persist` and bind-mounted over:

    * `/root`            <- `/persist/root`   (home, dotfiles, git repos)
    * `/var/lib/lepton`  <- `/persist/lepton` (Wi-Fi config, packages, flags)

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

  @doc "Find and mount the data partition. Returns :installed | :live."
  def mount do
    File.mkdir_p!(@state)

    case data_partition() do
      nil ->
        :live

      dev ->
        Lepton.Kmod.modprobe("ext4")

        case Sys.mount("ext2", dev, "/persist") do
          :ok ->
            first = not File.dir?("/persist/root")
            if first, do: File.cp_r!("/root", "/persist/root")
            File.mkdir_p!("/persist/lepton")
            bind("/persist/root", "/root")
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
      Sys.sync()
      Sys.shim("mount", ["-o", "remount,ro", "/persist"])
    end

    :ok
  end
end

defmodule Lepton.Installer do
  @moduledoc """
  `lepton-install`: installs Lepton from the boot ISO onto a disk.

  Layout written (all in Elixir - no partitioning or mkfs tools):

      GPT  ┌──────────────┬──────────────────────────────────────┐
           │ ESP  200 MiB │ LEPTON-DATA  (rest of the disk)      │
           │ FAT16        │ ext2                                 │
           │ GRUB, kernel │ /root and /var/lib/lepton, persisted │
           │ initramfs    │                                      │
           └──────────────┴──────────────────────────────────────┘

  In UTM: add a VirtIO (or NVMe) drive to the VM, boot the ISO, run
  `lepton-install`, power off, clear the CD/DVD drive, boot again.
  """

  alias Lepton.IO
  alias Lepton.Install.{Disk, Ext2, FAT16, GPT}

  @esp_mib 200
  @media "/run/install/media"

  def run(args, ctx) do
    {opts, rest} = Lepton.Args.getopt(args, "y")

    with {:ok, media} <- mount_media(ctx),
         {:ok, disk} <- choose_disk(ctx, rest),
         :ok <- confirm(ctx, disk, opts["y"] == true || opts["yes"] == true) do
      install(ctx, disk, media)
      IO.puts(ctx, """

      \e[1;32mLepton is installed on #{disk.path}.\e[0m

      Next steps:
        1. poweroff
        2. In UTM: remove the ISO (CD/DVD -> Clear), then start the VM again.
           With QEMU: boot without -cdrom.
        3. On first boot you'll be asked for Wi-Fi details and offered a short tutorial.
      """)

      0
    else
      {:error, msg} ->
        IO.err(ctx, "lepton-install: #{msg}")
        1

      :cancelled ->
        IO.puts(ctx, "Installation cancelled; nothing was written.")
        1
    end
  end

  # -- install media ---------------------------------------------------------------------

  defp mount_media(ctx) do
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

      if found, do: {:ok, found}, else: {:error, "install media not found (boot from the Lepton ISO to install)"}
    end
  end

  # -- target disk ---------------------------------------------------------------------------

  defp choose_disk(ctx, rest) do
    media_dev = media_device()
    disks = Disk.disks() |> Enum.reject(&(&1.path == media_dev or &1.bytes < 512 * 1024 * 1024))

    case {rest, disks} do
      {[path | _], _} ->
        case Enum.find(Disk.disks(), &(&1.path == path)) do
          nil -> {:error, "no such disk: #{path}"}
          d -> {:ok, d}
        end

      {[], []} ->
        {:error, "no suitable disk found. In UTM add a drive (Drives -> New -> VirtIO, 4 GB or more), then boot again."}

      {[], [only]} ->
        {:ok, only}

      {[], many} ->
        IO.puts(ctx, "Available disks:")
        Enum.with_index(many, 1) |> Enum.each(fn {d, i} -> IO.puts(ctx, "  #{i}) #{d.path}  #{Disk.human(d.bytes)}  #{d.model}") end)

        case ask(ctx, "Install to which disk? [1-#{length(many)}]: ") do
          nil -> :cancelled
          answer ->
            case Integer.parse(answer) do
              {i, _} when i >= 1 and i <= length(many) -> {:ok, Enum.at(many, i - 1)}
              _ -> :cancelled
            end
        end
    end
  end

  defp media_device do
    Enum.find_value(Lepton.Sys.mounts(), fn m -> if m.dir == @media, do: m.device end)
  end

  defp confirm(_ctx, _disk, true), do: :ok

  defp confirm(ctx, disk, false) do
    IO.puts(ctx, "\n\e[1;31mThis will ERASE everything on #{disk.path} (#{Disk.human(disk.bytes)}, #{disk.model}).\e[0m")
    if ask(ctx, "Type 'yes' to continue: ") == "yes", do: :ok, else: :cancelled
  end

  defp ask(ctx, prompt) do
    Elixir.IO.write(ctx.stdout, prompt)
    case IO.read_line(ctx.stdin) do
      :eof -> nil
      line -> String.trim(line)
    end
  end

  # -- writing ------------------------------------------------------------------------------

  def install(ctx, disk, media) do
    sectors = div(disk.bytes, 512)
    esp_first = 2048
    esp_last = esp_first + @esp_mib * 2048 - 1
    data_first = esp_last + 1
    data_last = sectors - 34 - 1
    data_last = data_last - rem(data_last - data_first + 1, 8)

    {:ok, fd} = Disk.open(disk.path)

    try do
      step(ctx, "Writing GPT partition table")
      # Clear old signatures at the start of the disk first.
      Disk.zero(fd, 0, 4 * 1024 * 1024)

      for {off, data} <- GPT.build(sectors, [
            %{type: GPT.esp_type(), name: "EFI System", first: esp_first, last: esp_last},
            %{type: GPT.linux_type(), name: "LEPTON-DATA", first: data_first, last: data_last}
          ]),
          do: Disk.pwrite(fd, off, data)

      step(ctx, "Creating EFI system partition (FAT16) with GRUB, kernel and initramfs")
      grub_cfg = File.read!(Path.join(media, "boot/grub/grub.cfg"))
      info = File.read!(Path.join(media, ".disk/info"))

      FAT16.format(fd, esp_first * 512, esp_last - esp_first + 1, esp_first, [
        {"EFI/BOOT/BOOTAA64.EFI", {:path, Path.join(media, "EFI/BOOT/BOOTAA64.EFI")}},
        {"EFI/BOOT/GRUB.CFG", {:data, grub_cfg}},
        {"BOOT/GRUB/GRUB.CFG", {:data, grub_cfg}},
        {"BOOT/VMLINUZ", {:path, Path.join(media, "boot/vmlinuz")}},
        {"BOOT/INITRD.IMG", {:path, Path.join(media, "boot/initrd.img")}},
        {"BOOT/INFO", {:data, info}}
      ])

      step(ctx, "Formatting LEPTON-DATA (ext2, #{Disk.human((data_last - data_first + 1) * 512)})")
      Ext2.format(fd, data_first * 512, (data_last - data_first + 1) * 512)
      :file.sync(fd)
      step(ctx, "Done")
    after
      :file.close(fd)
    end
  end

  defp step(ctx, text), do: IO.puts(ctx, "\e[1;36m==>\e[0m " <> text)
end
