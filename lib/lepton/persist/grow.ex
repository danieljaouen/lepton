defmodule Lepton.Persist.Grow do
  @moduledoc """
  Growing the data partition into a bigger disk: give a VM's disk more
  room (UTM: Drives, the disk, Resize; QEMU: `qemu-img resize`), start
  Lepton, and `LEPTON-DATA` grows to fill it.

  At boot, before the data partition is mounted (`Lepton.Persist.mount/0`):

  1. **The partition.** When `LEPTON-DATA` is the disk's last partition
     and at least 64 MiB lies after it, the GPT is written again for the
     disk's size (its backup copy moves to the new end), every partition
     kept as it was (number, type, GUID, name) and `LEPTON-DATA` ending at
     the disk's end. The kernel reads the table again (`BLKRRPART`:
     nothing on the disk is in use yet).
  2. **The file system.** Lepton's ext2 is mounted once with the ext4
     driver, which can grow a mounted file system (`EXT4_IOC_RESIZE_FS`;
     the ext2 driver Lepton mounts it with can't), at a private place;
     grown to the partition's size; unmounted. More group descriptors
     than fit after the superblock: ext4 switches it to `meta_bg`, which
     the ext2 driver reads too.

  Nothing happens on a disk that didn't grow, nor for a partition that
  other partitions follow (another system's, after an install beside
  it). `lepton.nogrow=1` on the kernel's command line skips it all.
  """

  require Logger

  alias Lepton.Install.GPT

  # ioctl requests: BLKRRPART = _IO(0x12, 95); EXT4_IOC_RESIZE_FS = _IOW('f', 16, __u64)
  @blkrrpart 0x125F
  @resize_fs 0x40086610
  # Growing by less than this isn't worth it (64 MiB, in 512-byte sectors).
  @min_gain 131_072
  # The GPT's entry array: 128 entries of 128 bytes, 32 sectors.
  @entry_sectors 32

  @doc """
  Grow the data partition `dev` (`/dev/vda2`) and its file system as far
  as the disk allows. Returns a list of what was done, for the boot log:
  `[{:partition, old_bytes, new_bytes}, {:filesystem, old_bytes, new_bytes}]`
  (empty when nothing changed); never raises.
  """
  def run(dev, opts \\ []) do
    part =
      case partition(dev) do
        {:grown, a, b} -> [{:partition, a * 512, b * 512}]
        :same -> []
        {:error, why} -> Logger.warning("grow: #{dev}: #{why}"); []
      end

    fs =
      case filesystem(dev, opts[:mount_at] || "/run/lepton/grow") do
        {:grown, a, b} -> [{:filesystem, a, b}]
        :same -> []
        {:error, why} -> Logger.warning("grow: #{dev}'s file system: #{why}"); []
      end

    part ++ fs
  rescue
    e ->
      Logger.error("grow: #{Exception.message(e)}")
      []
  end

  # -- the partition ---------------------------------------------------------------------------------

  @doc """
  The partition table for a disk of `sectors` on which partition `index`
  (the data partition) should grow: `{:grow, entries}` (all of them, that
  one's `last` moved to the disk's end, its size a whole number of 4 KiB
  blocks) or `:same` (not the last partition, or too little to gain).
  """
  def plan(sectors, entries, index) do
    data = Enum.find(entries, &(&1.index == index))
    last_usable = sectors - 1 - @entry_sectors - 1

    cond do
      data == nil -> :same
      Enum.any?(entries, &(&1.index != index and &1.last > data.last)) -> :same
      last_usable - data.last < @min_gain -> :same
      true ->
        length = div(last_usable - data.first + 1, 8) * 8
        {:grow, Enum.map(entries, fn e -> if e.index == index, do: %{e | last: data.first + length - 1}, else: e end)}
    end
  end

  @doc "Grow partition `dev` (`/dev/vda2`) to the end of its disk: `{:grown, old_sectors, new_sectors}`, `:same` or `{:error, why}`."
  def partition(dev) do
    name = Path.basename(dev)

    with {:ok, disk} <- parent(name),
         {:ok, index} <- read_int("/sys/class/block/#{name}/partition"),
         {:ok, sectors} <- read_int("/sys/class/block/#{disk}/size"),
         {:ok, fd} <- :file.open(~c"/dev/#{disk}", [:read, :write, :raw, :binary]) do
      try do
        case rewrite_table(fd, sectors, index) do
          {:grown, old, new} ->
            case Lepton.FD.ioctl(fd, @blkrrpart, <<>>) do
              {:ok, _, _} ->
                wait_size(name, new, 40)
                {:grown, old, new}

              {:error, e} ->
                {:error, "the table is written, but the kernel didn't read it again (#{e}): it will at the next start"}
            end

          other ->
            other
        end
      after
        :file.close(fd)
      end
    else
      {:error, why} -> {:error, inspect(why)}
    end
  end

  @doc """
  Write the table of the disk open as `fd` (`sectors` long) again, with
  partition `index` grown to the end (`plan/3`): `{:grown, old_sectors,
  new_sectors}` or `:same`. A disk without a GPT is left alone.
  """
  def rewrite_table(fd, sectors, index) do
    header = GPT.header(fd)
    entries = GPT.read(fd)
    old = Enum.find(entries, &(&1.index == index))

    case header && plan(sectors, entries, index) do
      {:grow, new_entries} ->
        new = Enum.find(new_entries, &(&1.index == index))
        for {offset, bin} <- GPT.build(sectors, new_entries, header.disk_guid), do: :ok = :file.pwrite(fd, offset, bin)
        :file.sync(fd)
        {:grown, old.last - old.first + 1, new.last - new.first + 1}

      _ ->
        :same
    end
  end

  # The disk a partition is on: the directory its sysfs entry is in.
  defp parent(name) do
    case File.read_link("/sys/class/block/#{name}") do
      {:ok, target} -> {:ok, target |> Path.dirname() |> Path.basename()}
      _ -> {:error, "#{name} isn't a partition"}
    end
  end

  defp read_int(path) do
    with {:ok, text} <- File.read(path), {n, _} <- Integer.parse(String.trim(text)) do
      {:ok, n}
    else
      _ -> {:error, "can't read #{path}"}
    end
  end

  defp wait_size(_name, _want, 0), do: :ok

  defp wait_size(name, want, tries) do
    case read_int("/sys/class/block/#{name}/size") do
      {:ok, ^want} -> :ok
      _ -> Process.sleep(50); wait_size(name, want, tries - 1)
    end
  end

  # -- the file system ---------------------------------------------------------------------------------

  @doc """
  Grow the ext2 file system on `dev` to the partition's size, through a
  passing ext4 mount at `dir`: `{:grown, old_bytes, new_bytes}`, `:same`
  or `{:error, why}`. `dev` must not be mounted.
  """
  def filesystem(dev, dir) do
    name = Path.basename(dev)

    with {:ok, sectors} <- read_int("/sys/class/block/#{name}/size"),
         {:ok, %{blocks: blocks, block_size: bs}} <- superblock(dev) do
      target = min(div(sectors * 512, bs), 0xFFFFFFFF)

      if target - blocks < div(@min_gain * 512, bs) do
        :same
      else
        grow_mounted(dev, dir, blocks, target, bs)
      end
    end
  end

  @doc "The ext2 superblock's block count and block size: `{:ok, %{blocks, block_size}}`."
  def superblock(dev) do
    with {:ok, f} <- :file.open(String.to_charlist(dev), [:read, :raw, :binary]),
         {:ok, sb} <- :file.pread(f, 1024, 1024) do
      :file.close(f)

      case sb do
        <<_::32, blocks::little-32, _::binary-size(16), log::little-32, _::binary-size(28), 0xEF53::little-16, _::binary>> -> {:ok, %{blocks: blocks, block_size: 1024 <<< log}}
        _ -> {:error, "no ext2 file system"}
      end
    else
      :eof -> {:error, "no ext2 file system"}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp grow_mounted(dev, dir, blocks, target, bs) do
    Lepton.Kmod.modprobe("ext4")
    File.mkdir_p!(dir)

    case Lepton.Sys.mount("ext4", dev, dir) do
      :ok ->
        try do
          # (a file on the file system to make the request through)
          probe = Path.join(dir, ".lepton-grow")
          {:ok, f} = :file.open(String.to_charlist(probe), [:write, :raw, :binary])

          result =
            try do
              Lepton.FD.ioctl(f, @resize_fs, <<target::native-64>>)
            after
              :file.close(f)
              File.rm(probe)
            end

          case result do
            {:ok, _, _} -> {:grown, blocks * bs, target * bs}
            {:error, e} -> {:error, "the kernel wouldn't grow it (#{e})"}
          end
        after
          Lepton.Sys.umount(dir)
        end

      {:error, why} ->
        {:error, "can't mount it with the ext4 driver: #{why}"}
    end
  end

  defp a <<< b, do: Bitwise.bsl(a, b)
end
