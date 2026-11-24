defmodule Lepton.DiskFree do
  @moduledoc """
  What `df` reports: each mounted file system's size, space used and
  available, from the kernel (statfs, `Lepton.Sys.statfs/1`). Bind mounts
  of one device (an installed system's data partition, mounted on
  `/persist`, then `/home`, `/root`, ...) are listed once, where the
  device was mounted first. ramfs, which keeps no size, is reported from
  the machine's memory.
  """

  # File systems worth listing (not proc, sysfs, cgroup and the like).
  @types ~w(rootfs tmpfs ramfs devtmpfs iso9660 ext4 ext3 ext2 vfat btrfs xfs f2fs exfat)

  @doc """
  The rows for `mounts` (`Lepton.Sys.mounts/0`'s), or for the file
  systems holding `paths` if any are given: `%{device, dir, size, used,
  avail}` in bytes. `statfs` is a function from a mount point to
  `{:ok, %{size, used, avail}}` or `:error`; `mem` is
  `Lepton.Sys.meminfo/0`'s map.
  """
  def rows(mounts, paths, statfs, mem) do
    mounts = Enum.filter(mounts, &(&1.type in @types))

    chosen =
      if paths == [] do
        Enum.uniq_by(mounts, &if(String.starts_with?(&1.device, "/dev/"), do: &1.device, else: {&1.device, &1.dir}))
      else
        paths |> Enum.map(&mount_of(mounts, &1)) |> Enum.reject(&is_nil/1)
      end

    for m <- chosen do
      sizes =
        case statfs.(m.dir) do
          {:ok, %{size: size} = s} when size > 0 -> s
          _ -> memory(m, mem)
        end

      Map.merge(%{device: m.device, dir: m.dir}, sizes)
    end
  end

  # The mount a path is on: the longest mount point that contains it.
  defp mount_of(mounts, path) do
    path = Path.expand(path)

    mounts
    |> Enum.filter(fn m -> m.dir == "/" or path == m.dir or String.starts_with?(path, m.dir <> "/") end)
    |> Enum.max_by(&String.length(&1.dir), fn -> nil end)
  end

  defp memory(m, mem) do
    total = Map.get(mem, "MemTotal", 0)
    avail = Map.get(mem, "MemAvailable", 0)
    if m.type in ["rootfs", "ramfs"], do: %{size: total, used: total - avail, avail: avail}, else: %{size: total, used: 0, avail: total}
  end

  @doc "Use%, as GNU df rounds it: used over used plus available, rounded up."
  def percent(%{used: used, avail: avail}) when used + avail > 0, do: "#{div(used * 100 + used + avail - 1, used + avail)}%"
  def percent(_), do: "-"
end
