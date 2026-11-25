defmodule Lepton.GrowTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Install.{Ext2, GPT}
  alias Lepton.Persist.Grow

  @mib div(1024 * 1024, 512)

  defp entry(index, first, last, name), do: %{index: index, first: first, last: last, name: name, type: GPT.guid(GPT.linux_type()), guid: GPT.random_guid(), attrs: 0}

  test "the plan: the last partition grows to the disk's end, a whole number of 4 KiB blocks; else nothing" do
    os = entry(1, 2048, 2048 + 512 * @mib - 1, "LEPTON-OS")
    data = entry(2, os.last + 1, 20 * 1024 * @mib - 34, "LEPTON-DATA")
    sectors = 64 * 1024 * @mib
    assert {:grow, [^os, grown]} = Grow.plan(sectors, [os, data], 2)
    assert grown.first == data.first and grown.last <= sectors - 34 and grown.last > sectors - 34 - 8
    assert rem(grown.last - grown.first + 1, 8) == 0
    assert Map.delete(grown, :last) == Map.delete(data, :last)
    # The same disk: nothing to gain. A little more: not worth it.
    assert Grow.plan(20 * 1024 * @mib, [os, data], 2) == :same
    assert Grow.plan(20 * 1024 * @mib + 32 * @mib, [os, data], 2) == :same
    # Another system's partition after it: left alone.
    other = entry(3, data.last + 1, data.last + 100 * @mib, "macOS")
    assert Grow.plan(sectors, [os, data, other], 2) == :same
    assert Grow.plan(sectors, [os], 2) == :same
  end

  # A disk image as the installer makes one: LEPTON-OS and LEPTON-DATA (ext2), `mib` MiB.
  defp image(mib, data_mib) do
    path = Path.join(tmp_dir("grow"), "disk.img")
    {:ok, f} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
    sectors = mib * @mib
    :ok = :file.pwrite(f, sectors * 512 - 1, <<0>>)
    os = entry(1, 2048, 2048 + 16 * @mib - 1, "LEPTON-OS")
    data = entry(2, os.last + 1, os.last + data_mib * @mib, "LEPTON-DATA")
    for {off, bin} <- GPT.build(sectors, [os, data]), do: :ok = :file.pwrite(f, off, bin)
    Ext2.format(f, data.first * 512, data_mib * 1024 * 1024)
    :file.close(f)
    {path, data}
  end

  test "an image made bigger: its table written again, the data partition to the end, the backup header at the new end" do
    {path, data} = image(64, 40)
    {:ok, f} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
    disk_guid = GPT.header(f).disk_guid
    # (as UTM's Resize would: more disk after it)
    :ok = :file.pwrite(f, 256 * @mib * 512 - 1, <<0>>)
    assert {:grown, old, new} = Grow.rewrite_table(f, 256 * @mib, 2)
    assert old == 40 * @mib and new > 230 * @mib
    [os2, data2] = GPT.read(f)
    assert os2.name == "LEPTON-OS" and data2.name == "LEPTON-DATA" and data2.first == data.first and data2.guid == data.guid
    assert GPT.header(f).disk_guid == disk_guid and GPT.header(f).last_usable == 256 * @mib - 34
    {:ok, <<"EFI PART", _::binary-size(16), my_lba::little-64, _::binary>>} = :file.pread(f, (256 * @mib - 1) * 512, 92)
    assert my_lba == 256 * @mib - 1
    # Again: nothing more to do.
    assert Grow.rewrite_table(f, 256 * @mib, 2) == :same
    :file.close(f)
  end

  # The real thing, in the VM: a loop device's partition and its ext2, grown
  # past what one block of group descriptors covers (16 GiB: ext4 switches
  # the file system to meta_bg), a file in it kept, mounted again as ext2.
  @tag :native
  @tag timeout: 300_000
  test "on a loop device: the partition and the file system grow; the files stay; it mounts as ext2" do
    Lepton.Kmod.modprobe("loop")
    {path, _data} = image(1100, 1000)
    # (busybox's losetup: attach to the first free device, then find which)
    {_, 0} = Lepton.Sys.shim("losetup", ["-P", "-f", path])
    {listing, 0} = Lepton.Sys.shim("losetup", ["-a"])
    [loop] = for line <- String.split(listing, "\n"), String.contains?(line, path), do: line |> String.split(":") |> hd()
    part = loop <> "p2"
    assert eventually(fn -> File.exists?(part) end, 50)
    mnt = tmp_dir("growmnt")

    try do
      :ok = Lepton.Sys.mount("ext2", part, mnt)
      File.write!(Path.join(mnt, "keep.txt"), "still here")
      Lepton.Sys.umount(mnt)
      {:ok, %{blocks: before}} = Grow.superblock(part)

      # The disk grows to 18 GiB (sparse), and the loop device sees it.
      {:ok, f} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
      :ok = :file.pwrite(f, 18 * 1024 * 1024 * 1024 - 1, <<0>>)
      :file.close(f)
      {_, 0} = Lepton.Sys.shim("losetup", ["-c", loop])

      done = Grow.run(part, mount_at: tmp_dir("growtmp"))
      assert [{:partition, _, p}, {:filesystem, _, fs}] = done
      assert p > 17 * 1024 * 1024 * 1024 and fs > 17 * 1024 * 1024 * 1024
      {:ok, %{blocks: after_, block_size: bs}} = Grow.superblock(part)
      assert after_ > before and after_ * bs == fs

      :ok = Lepton.Sys.mount("ext2", part, mnt)
      assert File.read!(Path.join(mnt, "keep.txt")) == "still here"
      {out, 0} = Lepton.Sys.shim("df", ["-k", mnt])
      [_, line | _] = String.split(out, "\n")
      [_, total | _] = String.split(line)
      assert String.to_integer(total) > 16 * 1024 * 1024
      Lepton.Sys.umount(mnt)
      # Grown already: nothing more.
      assert Grow.run(part, mount_at: tmp_dir("growtmp")) == []
    after
      Lepton.Sys.umount(mnt)
      Lepton.Sys.shim("losetup", ["-d", loop])
      File.rm(path)
    end
  end

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end
end
