defmodule Lepton.DiskFreeTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.DiskFree

  # An installed system: the data partition mounted on /persist, then bound
  # on /home and /root; the root in memory; proc and sysfs left out.
  @mounts [
    %{device: "rootfs", dir: "/", type: "rootfs"},
    %{device: "proc", dir: "/proc", type: "proc"},
    %{device: "sysfs", dir: "/sys", type: "sysfs"},
    %{device: "tmpfs", dir: "/run", type: "tmpfs"},
    %{device: "/dev/vda2", dir: "/persist", type: "ext4"},
    %{device: "/dev/vda2", dir: "/home", type: "ext4"},
    %{device: "/dev/vda2", dir: "/root", type: "ext4"}
  ]

  @gib 1024 * 1024 * 1024
  @mem %{"MemTotal" => 4 * @gib, "MemAvailable" => 3 * @gib}

  defp statfs("/persist"), do: {:ok, %{size: 20 * @gib, used: 4 * @gib, avail: 15 * @gib}}
  defp statfs("/home"), do: statfs("/persist")
  defp statfs("/root"), do: statfs("/persist")
  defp statfs("/run"), do: {:ok, %{size: 2 * @gib, used: 0, avail: 2 * @gib}}
  # (ramfs keeps no size: statfs says 0)
  defp statfs("/"), do: {:ok, %{size: 0, used: 0, avail: 0}}

  test "disks from statfs, listed once where first mounted; the root in memory from meminfo; pseudo file systems left out" do
    rows = DiskFree.rows(@mounts, [], &statfs/1, @mem)
    assert Enum.map(rows, & &1.dir) == ["/", "/run", "/persist"]
    assert %{device: "/dev/vda2", size: size, used: used, avail: avail} = List.last(rows)
    assert {size, used, avail} == {20 * @gib, 4 * @gib, 15 * @gib}
    assert %{size: size, used: used} = hd(rows)
    assert {size, used} == {4 * @gib, @gib}

    # GNU df's Use%: used over used plus available, rounded up (4/19 is 21.05%).
    assert DiskFree.percent(List.last(rows)) == "22%"
    assert DiskFree.percent(%{used: 0, avail: 0}) == "-"
  end

  test "with paths: the file system each is on" do
    rows = DiskFree.rows(@mounts, ["/root/notes.org", "/tmp", "/home"], &statfs/1, @mem)
    assert Enum.map(rows, &{&1.device, &1.dir}) == [{"/dev/vda2", "/root"}, {"rootfs", "/"}, {"/dev/vda2", "/home"}]
  end

  # The real thing, in Lepton: statfs through the shim.
  @tag :native
  test "df reports a disk's own size, not the machine's memory" do
    {:ok, %{size: size, used: used, avail: avail}} = Lepton.Sys.statfs("/run")
    assert size > 0 and used + avail <= size
    {out, 0} = sh("df -h /run")
    assert [_, line] = String.split(out, "\n", trim: true)
    assert line =~ ~r/^tmpfs\s+\S+\s+\S+\s+\S+\s+\d+% \/run$/
    {out, 0} = sh("df")
    assert out =~ "1K-blocks"
    refute out =~ "/proc"
  end
end
