defmodule Lepton.MediaTest do
  use ExUnit.Case
  import Lepton.TestHelpers
  import Bitwise

  alias Lepton.Media
  alias Lepton.Media.FS

  defp reader(bin), do: fn off, len -> if off >= byte_size(bin), do: "", else: binary_part(bin, off, min(len, byte_size(bin) - off)) end

  test "filesystems and labels from the first sectors: FAT, exFAT, NTFS, ext, ISO 9660" do
    # A FAT16 boot sector, labelled; FAT32 keeps its label further in.
    bpb = <<0xEB, 0x3C, 0x90, "MSDOS5.0", 512::little-16, 4, 1::little-16, 2, 0::size(21 * 8), 0x29, 0::32, "HOLIDAY    ", "FAT16   ">>
    fat = bpb <> :binary.copy(<<0>>, 510 - byte_size(bpb)) <> <<0x55, 0xAA>>
    assert FS.detect(reader(fat)) == {"vfat", "HOLIDAY"}
    <<head::binary-43, _::binary-11, rest::binary>> = fat
    assert FS.detect(reader(head <> "NO NAME    " <> rest)) == {"vfat", nil}

    # ext2 as the installer writes it, labelled.
    dir = tmp_dir("media")
    path = Path.join(dir, "ext.img")
    File.write!(path, :binary.copy(<<0>>, 8 <<< 20))
    {:ok, fd} = Lepton.Install.Disk.open(path)
    Lepton.Install.Ext2.format(fd, 0, 8 <<< 20, "backups")
    :file.close(fd)
    assert FS.probe(path) == {"ext4", "backups"}

    # exFAT: the label is in the root directory (cluster 4, 512-byte sectors, 8 per cluster).
    root = <<0x83, 5, :unicode.characters_to_binary("CARDS", :utf8, {:utf16, :little})::binary, 0::size(20 * 8)>>
    boot = <<0xEB, 0x76, 0x90, "EXFAT   ", 0::size(77 * 8), 64::little-32, 4::little-32, 0::size(12 * 8), 9, 3>>
    exfat = (boot <> :binary.copy(<<0>>, 512 - byte_size(boot))) |> then(&(&1 <> :binary.copy(<<0>>, 64 * 512 + 2 * 4096 - byte_size(&1)))) |> Kernel.<>(root)
    assert FS.detect(reader(exfat)) == {"exfat", "CARDS"}

    assert FS.detect(reader(<<0xEB, 0x52, 0x90, "NTFS    ", 0::size(500 * 8)>>)) == {"ntfs3", nil}

    iso = :binary.copy(<<0>>, 32768) <> <<1, "CD001", 1, 0>> <> :binary.copy(<<0>>, 32) <> String.pad_trailing("LEPTON", 32) <> :binary.copy(<<0>>, 1976)
    assert FS.detect(reader(iso)) == {"iso9660", "LEPTON"}

    assert FS.detect(reader(:binary.copy(<<0>>, 65536))) == {nil, nil}
    assert FS.probe(Path.join(dir, "missing")) == {nil, nil}
  end

  # A sysfs-like /sys/class/block: links into a device tree, as the kernel makes them.
  defp sysfs do
    root = tmp_dir("blocksys")
    devices = Path.join(root, "devices")
    class = Path.join(root, "class")
    File.mkdir_p!(class)

    add = fn path, name, attrs ->
      dir = Path.join(devices, path)
      File.mkdir_p!(dir)
      for {k, v} <- attrs, do: File.write!(Path.join(dir, k), v)
      File.ln_s!(dir, Path.join(class, name))
    end

    usb = "pci0000:00/0000:00:02.0/usb1/1-1/1-1.3/1-1.3:1.0/host0/target0:0:0/0:0:0:0/block"
    add.("#{usb}/sdb", "sdb", %{"size" => "2097152", "removable" => "1"})
    add.("#{usb}/sdb/sdb1", "sdb1", %{"size" => "2095104", "partition" => "1"})
    add.("#{usb}/sdc", "sdc", %{"size" => "65536", "removable" => "1"})
    sd = "platform/fe340000.mmc/mmc_host/mmc0/mmc0:aaaa/block"
    add.("#{sd}/mmcblk0", "mmcblk0", %{"size" => "1000000", "removable" => "0"})
    add.("#{sd}/mmcblk0/mmcblk0p1", "mmcblk0p1", %{"size" => "500000", "partition" => "1"})
    add.("#{sd}/mmcblk0/mmcblk0p2", "mmcblk0p2", %{"size" => "499000", "partition" => "1"})
    add.("#{sd}/mmcblk0boot0", "mmcblk0boot0", %{"size" => "8192"})
    add.("pci0000:00/0000:00:04.0/virtio1/block/vda", "vda", %{"size" => "4000000"})
    add.("pci0000:00/0000:00:04.0/virtio1/block/vda/vda1", "vda1", %{"size" => "3999000", "partition" => "1"})
    class
  end

  test "block devices: disks and partitions, by bus; what is mounted" do
    devices = Media.block_devices(sysfs())
    assert Enum.map(devices, & &1.name) == ~w(mmcblk0 mmcblk0p1 mmcblk0p2 sdb sdb1 sdc vda vda1)
    by = Map.new(devices, &{&1.name, &1})
    assert %{disk: "sdb", partition?: true, bus: :usb, removable: true, size: 1_072_693_248} = by["sdb1"]
    assert %{bus: :mmc, disk: "mmcblk0"} = by["mmcblk0p2"]
    assert by["vda1"].bus == nil

    # Partitions of USB and SD devices, a USB device without a partition
    # table, and never the disk Lepton runs from (here the SD card).
    assert devices |> Media.candidates(nil) |> Enum.map(& &1.name) == ~w(mmcblk0p1 mmcblk0p2 sdb1 sdc)
    assert devices |> Media.candidates("mmcblk0") |> Enum.map(& &1.name) == ~w(sdb1 sdc)
  end

  test "a drive that isn't mounted says why: a Mac's format, encryption, or nothing Lepton knows" do
    assert Media.not_mounted_message("sdc1", "hfsplus") =~ "sdc1 isn't mounted: it's HFS+ (Mac OS Extended), a Mac's format"
    assert Media.not_mounted_message("sdc1", "hfsplus") =~ "Format it as exFAT"
    assert Media.not_mounted_message("sdc1", "apfs") =~ "it's APFS"
    assert Media.not_mounted_message("sdd1", "crypto_LUKS") =~ "encrypted (LUKS)"
    assert Media.not_mounted_message("sdd1", "bitlocker") =~ "BitLocker"
    assert Media.not_mounted_message("sde", nil) =~ "doesn't recognise its filesystem"
    assert Media.not_mounted_message("sde", "xfs") =~ "can't mount xfs"
  end

  test "mount points: the label made safe, else the device; no clashes" do
    assert Media.mount_point("My Photos", "sdb1", []) == "/media/My_Photos"
    assert Media.mount_point(nil, "sdb1", []) == "/media/sdb1"
    assert Media.mount_point("../..", "sdb1", []) == "/media/sdb1"
    assert Media.mount_point("STICK", "sdc", ["/media/STICK"]) == "/media/STICK-2"
  end

  test "eject and lsblk without removable media" do
    if Process.whereis(Media) == nil or Media.mounted() == [] do
      assert {"", 1} = sh("eject")
    end

    {out, 0} = sh("lsblk")
    assert out =~ "MOUNTPOINT"
  end

  # Inside Lepton: `mix lepton.qemu --test` plugs a FAT USB stick labelled
  # LEPTONSTICK into the hub.
  @tag :native
  test "a USB stick is mounted when it appears, and ejected" do
    assert Enum.find_value(1..50, fn _ -> Enum.find(Media.mounted(), &(&1.dir == "/media/LEPTONSTICK")) || (Process.sleep(200) && nil) end)
    assert File.read!("/media/LEPTONSTICK/HELLO.TXT") == "hello from a USB stick\n"
    File.write!("/media/LEPTONSTICK/NOTE.TXT", "written by Lepton\n")
    assert {out, 0} = sh("lsblk")
    assert out =~ ~r/vfat\s+LEPTONSTICK\s+\/media\/LEPTONSTICK/
    assert {"Ejected /media/LEPTONSTICK: it's safe to remove.\n", 0} = sh("eject /media/LEPTONSTICK")
    refute Enum.any?(Lepton.Sys.mounts(), &(&1.dir == "/media/LEPTONSTICK"))
    refute File.exists?("/media/LEPTONSTICK")
  end
end
