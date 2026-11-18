defmodule Lepton.Media do
  @moduledoc """
  Plug-and-play storage: USB drives and sticks, SD cards (in a slot or a
  USB card reader), mounted when they appear and unmounted when they go.

  This GenServer (started at boot) looks at `/sys/class/block` every
  second. A partition on a USB or MMC (SD) device, or such a device with
  no partition table, is probed (`Lepton.Media.FS`: FAT, exFAT, NTFS,
  ext2/3/4, ISO 9660) and mounted at `/media/LABEL` (its label, else its
  device name). FAT, exFAT and NTFS have no owners or permissions, so
  everyone may write to them.

    * **Removed** without ejecting: the mount is detached and its
      directory removed. Writes not yet on the device are lost, so...
    * **Eject** first (`eject/1`, the `eject` command): it syncs and
      unmounts, and a USB drive is detached from the system, so it is
      safe to unplug and isn't mounted again. An SD card or a drive
      unmounted by hand stays unmounted until it is plugged in again.

  Card readers keep their device when the card comes out, so the kernel
  is asked to check them for a card every two seconds.

  Lepton's own disk (the one holding `LEPTON-DATA`) is never touched.
  """

  use GenServer
  require Logger

  alias Lepton.Media.FS
  alias Lepton.Sys

  @root "/media"
  @tick 1_000

  @options %{
    "vfat" => "iocharset=utf8,umask=000,flush",
    "exfat" => "iocharset=utf8,umask=000",
    "ntfs3" => "iocharset=utf8,umask=000",
    "iso9660" => "ro"
  }

  @modules %{
    "vfat" => ~w(nls_cp437 nls_utf8 vfat),
    "exfat" => ~w(nls_utf8 exfat),
    "ntfs3" => ~w(nls_utf8 ntfs3),
    "ext4" => ~w(ext4),
    "iso9660" => ~w(isofs)
  }

  # -- block devices ----------------------------------------------------------------------------

  @doc """
  Every block device: `%{name, disk, partition?, bus, size, removable}`,
  disks before their partitions. `bus` is `:usb`, `:mmc` or `nil`.
  """
  def block_devices(sys \\ "/sys/class/block") do
    case File.ls(sys) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 =~ ~r/^(loop|ram|zram|dm-)|boot\d+$|rpmb$/))
        |> Enum.map(&block_device(sys, &1))
        |> Enum.sort_by(&{&1.disk, &1.partition?, natural(&1.name)})

      _ ->
        []
    end
  end

  defp block_device(sys, name) do
    dir = Path.join(sys, name)
    link = case File.read_link(dir) do
      {:ok, l} -> l
      _ -> ""
    end

    partition? = File.exists?(Path.join(dir, "partition"))
    disk = if partition?, do: link |> Path.dirname() |> Path.basename(), else: name

    %{
      name: name,
      disk: disk,
      partition?: partition?,
      bus: cond do
        link =~ "/usb" -> :usb
        link =~ "/mmc" -> :mmc
        true -> nil
      end,
      size: read_int(Path.join(dir, "size")) * 512,
      removable: read_int(Path.join([sys, disk, "removable"])) == 1
    }
  end

  defp natural(name), do: Regex.split(~r/(\d+)/, name, include_captures: true) |> Enum.map(&(Integer.parse(&1) |> then(fn {n, ""} -> n; _ -> &1 end)))

  defp read_int(path) do
    with {:ok, text} <- File.read(path), {n, _} <- Integer.parse(String.trim(text)), do: n, else: (_ -> 0)
  end

  @doc """
  The devices to mount: filesystems on USB and SD devices (partitions, or
  the whole device when it has none), not on Lepton's own disk.
  """
  def candidates(devices, own_disk) do
    with_parts = MapSet.new(for d <- devices, d.partition?, do: d.disk)

    Enum.filter(devices, fn d ->
      d.bus in [:usb, :mmc] and d.size > 0 and d.disk != own_disk and (d.partition? or not MapSet.member?(with_parts, d.name))
    end)
  end

  @doc "Where a filesystem is mounted: `/media/LABEL`, or `/media/NAME`; `taken` are directories in use."
  def mount_point(label, name, taken) do
    base =
      # (no hidden directories: leading dots go too)
      case label && label |> String.replace(~r/[^A-Za-z0-9._-]+/, "_") |> String.replace(~r/^[._]+|_+$/, "") do
        x when x in [nil, ""] -> name
        safe -> safe
      end

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: Path.join(@root, base), else: Path.join(@root, "#{base}-#{&1}")))
    |> Enum.find(&(&1 not in taken))
  end

  @doc "What is mounted now: `[%{device, dir, type, label}]` (also read by the classic desktop)."
  def mounted, do: :persistent_term.get({__MODULE__, :mounted}, [])

  @doc "Unmount (and for a USB drive, detach) a device, a disk's partitions, or a mount point."
  def eject(target), do: GenServer.call(__MODULE__, {:eject, target}, 60_000)

  # -- the manager ----------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Sys.native?() do
      # Card readers: look for a card every two seconds.
      File.write("/sys/module/block/parameters/events_dfl_poll_msecs", "2000")
      send(self(), :tick)
    end

    {:ok, %{mounts: %{}, skip: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, scan(st)}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def handle_call({:eject, target}, _from, st) do
    target = String.replace_prefix(target, "/dev/", "")

    hits =
      Enum.filter(st.mounts, fn {dev, m} ->
        dev == target or m.dir == target or String.starts_with?(target, m.dir <> "/") or disk_of(dev) == target
      end)

    if hits == [] do
      {:reply, {:error, "#{target}: not a mounted drive (see lsblk)"}, st}
    else
      Sys.shim("sync", [])

      Enum.reduce_while(hits, {:ok, st}, fn {dev, m}, {:ok, st} ->
        case Sys.umount(m.dir) do
          :ok ->
            File.rmdir(m.dir)
            Logger.info("media: ejected #{dev} (#{m.dir})")
            {:cont, {:ok, %{st | mounts: Map.delete(st.mounts, dev), skip: MapSet.put(st.skip, dev)}}}

          {:error, reason} ->
            {:halt, {:error, "#{m.dir}: #{reason} (is a program using it? cd out of it)", st}}
        end
      end)
      |> case do
        {:ok, st} ->
          disks = hits |> Enum.map(&disk_of(elem(&1, 0))) |> Enum.uniq()
          # A USB drive is detached: it's safe to unplug, and isn't mounted again.
          for disk <- disks, File.exists?("/sys/block/#{disk}/device/delete"), do: File.write("/sys/block/#{disk}/device/delete", "1")
          {:reply, {:ok, Enum.map(hits, &elem(&1, 1).dir)}, publish(st)}

        {:error, msg, st} ->
          {:reply, {:error, msg}, publish(st)}
      end
    end
  end

  defp disk_of(dev) do
    case Enum.find(block_devices(), &(&1.name == dev)) do
      %{disk: disk} -> disk
      nil -> dev
    end
  end

  defp scan(st) do
    devices = block_devices()
    present = MapSet.new(devices, & &1.name)
    mounts = Sys.mounts()
    mounted_devs = MapSet.new(mounts, &String.replace_prefix(&1.device, "/dev/", ""))
    mounted_dirs = MapSet.new(mounts, & &1.dir)

    # Pulled out: detach what was mounted. Unmounted by hand: leave it.
    st =
      Enum.reduce(st.mounts, st, fn {dev, m}, st ->
        cond do
          not MapSet.member?(present, dev) ->
            Sys.umount(m.dir, lazy: true)
            File.rmdir(m.dir)
            Logger.warning("media: #{dev} was removed without ejecting (#{m.dir})")
            %{st | mounts: Map.delete(st.mounts, dev)}

          not MapSet.member?(mounted_dirs, m.dir) ->
            File.rmdir(m.dir)
            %{st | mounts: Map.delete(st.mounts, dev), skip: MapSet.put(st.skip, dev)}

          true ->
            st
        end
      end)

    st = %{st | skip: MapSet.intersection(st.skip, present)}
    own = own_disk(devices)

    devices
    |> candidates(own)
    |> Enum.reject(&(Map.has_key?(st.mounts, &1.name) or MapSet.member?(st.skip, &1.name) or MapSet.member?(mounted_devs, &1.name)))
    |> Enum.reduce(st, &automount(&2, &1))
    |> publish()
  end

  defp own_disk(devices) do
    case Lepton.Persist.data_partition() do
      "/dev/" <> part -> Enum.find_value(devices, &(&1.name == part && &1.disk))
      _ -> nil
    end
  end

  defp automount(st, dev) do
    path = "/dev/" <> dev.name

    case FS.probe(path) do
      {nil, _} ->
        # Nothing we can mount (or the device node isn't there yet: try again).
        if File.exists?(path), do: %{st | skip: MapSet.put(st.skip, dev.name)}, else: st

      {type, label} ->
        Enum.each(@modules[type], &Lepton.Kmod.modprobe/1)
        dir = mount_point(label, dev.name, Enum.map(st.mounts, &elem(&1, 1).dir))
        File.mkdir_p!(dir)

        # A filesystem the kernel won't write (an NTFS volume Windows left
        # hibernated, say) is mounted read-only.
        result =
          with {:error, _} <- Sys.mount(type, path, dir, @options[type]),
               do: Sys.mount(type, path, dir, Enum.join(Enum.reject([@options[type], "ro"], &is_nil/1), ","))

        case result do
          :ok ->
            Logger.info("media: #{dev.name} (#{type}#{if label, do: " \"#{label}\""}) mounted at #{dir}")
            put_in(st.mounts[dev.name], %{dir: dir, type: type, label: label})

          {:error, reason} ->
            File.rmdir(dir)
            Logger.warning("media: cannot mount #{dev.name} (#{type}): #{reason}")
            %{st | skip: MapSet.put(st.skip, dev.name)}
        end
    end
  end

  defp publish(st) do
    list = for {dev, m} <- Enum.sort(st.mounts), do: %{device: "/dev/" <> dev, dir: m.dir, type: m.type, label: m.label}
    if list != mounted(), do: :persistent_term.put({__MODULE__, :mounted}, list)
    st
  end
end
