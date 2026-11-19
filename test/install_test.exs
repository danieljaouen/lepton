defmodule Lepton.InstallTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Install.{Disk, Ext2, FAT16, GPT}

  defp image(mib) do
    path = Path.join(tmp_dir("img"), "disk.img")
    {:ok, fd} = :file.open(path, [:read, :write, :raw, :binary])
    :ok = :file.pwrite(fd, mib * 1024 * 1024 - 1, <<0>>)
    {path, fd}
  end

  test "GPT round trip" do
    {_path, fd} = image(64)
    sectors = 64 * 2048

    for {off, data} <- GPT.build(sectors, [
          %{type: GPT.esp_type(), name: "EFI System", first: 2048, last: 4095},
          %{type: GPT.linux_type(), name: "LEPTON-DATA", first: 4096, last: sectors - 40}
        ]),
        do: Disk.pwrite(fd, off, data)

    assert [%{name: "EFI System", first: 2048}, %{name: "LEPTON-DATA", first: 4096}] = GPT.read(fd)
    {:ok, <<_::binary-size(510), 0x55, 0xAA>>} = :file.pread(fd, 0, 512)
    # primary header CRC is valid
    {:ok, <<head::binary-size(16), crc::little-32, rest::binary-size(72)>>} = :file.pread(fd, 512, 92)
    assert :erlang.crc32(head <> <<0::32>> <> rest) == crc
  end

  test "FAT16 ESP layout" do
    {_path, fd} = image(80)
    src = Path.join(tmp_dir("src"), "kernel")
    File.write!(src, :binary.copy("K", 10_000))
    sectors = 70 * 2048
    :ok = FAT16.format(fd, 1024 * 1024, sectors, 2048, [{"EFI/BOOT/BOOTAA64.EFI", {:data, "MZgrub"}}, {"BOOT/VMLINUZ", {:path, src}}])
    {:ok, bpb} = :file.pread(fd, 1024 * 1024, 512)
    <<_::binary-size(11), 512::little-16, 8, 4::little-16, 2, 512::little-16, 0::16, 0xF8, fat::little-16, _::binary-size(8), total::little-32, _::binary-size(3), _::binary-size(4), "LEPTON ESP ", "FAT16   ", _::binary>> = bpb
    assert total == sectors
    assert fat > 0
    assert binary_part(bpb, 510, 2) == <<0x55, 0xAA>>
  end

  test "ext2 superblock and root directory" do
    {_path, fd} = image(300)
    %{groups: groups} = Ext2.format(fd, 0, 300 * 1024 * 1024)
    assert groups == 3
    {:ok, sb} = :file.pread(fd, 1024, 1024)
    <<inodes::little-32, blocks::little-32, _::binary-size(48), 0xEF53::little-16, _::binary>> = sb
    assert inodes == groups * 8192
    assert blocks == div(300 * 1024 * 1024, 4096)
    # backup superblock in group 1 (sparse_super)
    {:ok, <<_::binary-size(56), magic::little-16, _::binary>>} = :file.pread(fd, 32_768 * 4096, 64)
    assert magic == 0xEF53
  end

  # A pretend ISO: what the installer copies to the OS partition.
  defp media(release) do
    dir = tmp_dir("media")
    for d <- ~w(boot/grub .disk EFI/BOOT), do: File.mkdir_p!(Path.join(dir, d))
    File.write!(Path.join(dir, "boot/grub/grub.cfg"), "menuentry Lepton {}\n")
    File.write!(Path.join(dir, ".disk/info"), "Lepton OS 0.1.0 aarch64\n")
    File.write!(Path.join(dir, "EFI/BOOT/BOOTAA64.EFI"), "MZgrub")
    File.write!(Path.join(dir, "boot/vmlinuz"), "KERNEL-" <> release)
    File.write!(Path.join(dir, "boot/initrd.img"), "INITRD-" <> release <> :binary.copy(".", 100_000))
    dir
  end

  defp ctx do
    {:ok, out} = StringIO.open("")
    %Lepton.Ctx{stdout: out, stderr: out}
  end

  defp os_region(fd, %{first: first}) do
    {:ok, data} = :file.pread(fd, first * 512, 4 * 1024 * 1024)
    data
  end

  test "install: an OS partition and a data partition; upgrade rewrites only the OS" do
    {path, fd} = image(1024)
    disk = %{path: path, bytes: 1024 * 1024 * 1024, model: "test"}
    Lepton.Installer.install(ctx(), disk, media("one"))

    assert [%{name: "LEPTON-OS", first: 2048, last: last}, %{name: "LEPTON-DATA"} = data] = GPT.read(fd)
    assert (last - 2048 + 1) * 512 == 512 * 1024 * 1024
    # FAT16 over 512 MiB: 16 KiB clusters
    assert {:ok, <<_::binary-11, 512::little-16, 32, _::binary>>} = :file.pread(fd, 2048 * 512, 16)

    assert %{os: os, data: ^data} = Lepton.Installer.existing(disk)
    assert os_region(fd, os) =~ "INITRD-one"

    # Things on the data partition (its superblock, and a user's file).
    {:ok, before} = :file.pread(fd, data.first * 512, 2 * 1024 * 1024)
    marker = "my files" <> :binary.copy("!", 4088)
    :ok = :file.pwrite(fd, (data.first + 100_000) * 512, marker)

    newer = media("two")
    build = Lepton.Installer.build([Path.join(newer, "boot/vmlinuz"), Path.join(newer, "boot/initrd.img")])
    assert {:ok, _from, ^build} = Lepton.Installer.upgrade(ctx(), disk, %{os: os, data: data}, newer)
    assert os_region(fd, os) =~ "INITRD-two"
    refute os_region(fd, os) =~ "INITRD-one"
    assert os_region(fd, os) =~ "build #{build}"
    assert {:ok, ^before} = :file.pread(fd, data.first * 512, 2 * 1024 * 1024)
    assert {:ok, ^marker} = :file.pread(fd, (data.first + 100_000) * 512, byte_size(marker))
    assert GPT.read(fd) == [%{os | name: "LEPTON-OS"}, data]
  end

  test "upgrade: disks from before (a 200 MiB EFI System partition), and a release that doesn't fit" do
    {path, fd} = image(600)
    sectors = 600 * 2048
    disk = %{path: path, bytes: 600 * 1024 * 1024, model: "test"}

    for {off, data} <- GPT.build(sectors, [
          %{type: GPT.esp_type(), name: "EFI System", first: 2048, last: 2048 + 200 * 2048 - 1},
          %{type: GPT.linux_type(), name: "LEPTON-DATA", first: 2048 + 200 * 2048, last: sectors - 40}
        ]),
        do: Disk.pwrite(fd, off, data)

    assert %{os: %{name: "EFI System"} = os} = existing = Lepton.Installer.existing(disk)
    assert {:ok, _, _} = Lepton.Installer.upgrade(ctx(), disk, existing, media("three"))
    assert os_region(fd, os) =~ "INITRD-three"

    # A release bigger than the partition: refused, nothing written.
    big = media("huge")
    File.write!(Path.join(big, "boot/initrd.img"), :binary.copy("x", 210 * 1024 * 1024))
    assert {:error, "this release (" <> _} = Lepton.Installer.upgrade(ctx(), disk, existing, big)
    assert os_region(fd, os) =~ "INITRD-three"

    # A disk without Lepton.
    {path2, _} = image(64)
    assert Lepton.Installer.existing(%{path: path2}) == nil
  end

  # A disk as macOS leaves it, with room made for Lepton.
  defp mac_disk do
    {path, fd} = image(5120)
    sectors = 5120 * 2048
    mib = 2048
    apfs = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    basic = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

    for {off, data} <- GPT.build(sectors, [
          %{type: GPT.esp_type(), name: "EFI System Partition", first: 40, last: 40 + 200 * mib - 1},
          %{type: apfs, name: "Macintosh HD", first: 210 * mib, last: 1300 * mib - 1, attrs: 1},
          %{type: basic, name: "Untitled", first: 1300 * mib, last: 2600 * mib - 1},
          # (a partition that says it's ordinary data, but holds APFS)
          %{type: basic, name: "Mislabelled", first: 2600 * mib, last: 2700 * mib + 1100 * mib - 1}
        ]),
        do: Disk.pwrite(fd, off, data)

    # macOS's data: APFS's container superblock, and some files' bytes.
    :ok = :file.pwrite(fd, 210 * mib * 512 + 32, "NXSB")
    :ok = :file.pwrite(fd, 300 * mib * 512, :binary.copy("photos", 10_000))
    :ok = :file.pwrite(fd, 2600 * mib * 512 + 32, "NXSB")
    {path, fd, %{path: path, bytes: sectors * 512, model: "test"}}
  end

  defp hash(fd, first_lba, bytes) do
    {:ok, data} = :file.pread(fd, first_lba * 512, bytes)
    :crypto.hash(:sha256, data)
  end

  test "alongside macOS: the empty partition and free space are offered, nothing else" do
    {_path, fd, disk} = mac_disk()
    layout = Lepton.Installer.places(disk)
    refute layout.mbr

    assert [%{index: 3, kind: :partition, what: "empty"}, %{kind: :free, first: first_free}] = layout.places
    assert first_free == 3800 * 2048
    whys = Map.new(layout.parts, &{&1.index, &1.why})
    assert whys[1] =~ "system partition" and whys[2] =~ "system partition"
    assert whys[4] =~ "apfs"
    assert whys[3] == nil

    before = for {lba, n} <- [{0, 512}, {40, 4 * 1024 * 1024}, {210 * 2048, 200 * 1024 * 1024}, {2600 * 2048, 2 * 1024 * 1024}], do: hash(fd, lba, n)
    [_, mac | _] = parts_before = GPT.read(fd)

    Lepton.Installer.install_into(ctx(), disk, hd(layout.places), media("one"))

    # The other partitions: the same entries, the same bytes; the MBR too.
    after_parts = GPT.read(fd)
    assert Enum.find(after_parts, &(&1.index == 2)) == mac
    for i <- [1, 2, 4], do: assert(Enum.find(after_parts, &(&1.index == i)) == Enum.find(parts_before, &(&1.index == i)))
    assert for({lba, n} <- [{0, 512}, {40, 4 * 1024 * 1024}, {210 * 2048, 200 * 1024 * 1024}, {2600 * 2048, 2 * 1024 * 1024}], do: hash(fd, lba, n)) == before

    # Lepton in partition 3's place (and a new entry for its data).
    assert %{name: "LEPTON-OS", first: os_first} = os = Enum.find(after_parts, &(&1.index == 3))
    assert os_first == 1300 * 2048
    assert %{name: "LEPTON-DATA", first: data_first, last: data_last} = Enum.find(after_parts, &(&1.index == 5))
    assert data_first == os.last + 1 and data_last < 2600 * 2048
    assert {:ok, <<_::binary-56, 0x53, 0xEF, _::binary>>} = :file.pread(fd, data_first * 512 + 1024, 64)

    # Upgrades find Lepton's OS partition, not macOS's EFI one.
    assert %{os: %{index: 3}, data: %{index: 5}} = existing = Lepton.Installer.existing(disk)
    assert {:ok, _, _} = Lepton.Installer.upgrade(ctx(), disk, existing, media("two"))
    assert hash(fd, 40, 4 * 1024 * 1024) == Enum.at(before, 1)
    assert Lepton.Installer.places(disk).places |> Enum.map(& &1.kind) == [:free]
  end

  test "alongside: into free space, and a blank disk is all Lepton's" do
    {_path, fd, disk} = mac_disk()
    free = Lepton.Installer.places(disk).places |> Enum.find(&(&1.kind == :free))
    Lepton.Installer.install_into(ctx(), disk, free, media("one"))
    parts = GPT.read(fd)
    assert Enum.map(parts, & &1.name) == ["EFI System Partition", "Macintosh HD", "Untitled", "Mislabelled", "LEPTON-OS", "LEPTON-DATA"]
    assert %{first: first} = Enum.find(parts, &(&1.name == "LEPTON-OS"))
    assert first == 3800 * 2048

    {path, _} = image(2048)
    assert %{parts: [], places: [], mbr: false} = Lepton.Installer.places(%{path: path})
  end

  test "WPA PSK matches the IEEE 802.11i test vector" do
    assert Lepton.Wifi.psk("IEEE", "password") == "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
  end

  test "lpm installs a local package and registers its commands" do
    state = tmp_dir("state")
    System.put_env("LEPTON_STATE_DIR", state)

    try do
      proj = tmp_dir("pkg")
      File.write!(Path.join(proj, "mix.exs"), ~s|defmodule Cowsay.MixProject do\n  use Mix.Project\n  def project, do: [app: :lepton_cowsay, version: "0.1.0"]\nend\n|)
      File.mkdir_p!(Path.join(proj, "lib"))

      File.write!(Path.join(proj, "lib/cowsay.ex"), """
      defmodule LeptonCowsay do
        use Lepton.Command
        defcmd "cowsay", "a talking cow" do
          IO.puts(ctx, "< " <> Enum.join(args, " ") <> " >\\n   \\\\  ^__^")
          0
        end
      end
      """)

      {:ok, sink} = StringIO.open("")
      ctx = %Lepton.Ctx{cwd: proj, env: %{}, stdout: sink, stderr: sink}
      assert {:ok, %{version: "0.1.0"}} = Lepton.Pkg.install_local(ctx, proj)
      assert {"< moo >\n" <> _, 0} = sh("cowsay moo")
      assert Map.has_key?(Lepton.Pkg.installed(), "lepton_cowsay")
    after
      System.delete_env("LEPTON_STATE_DIR")
    end
  end

  @tag :network
  test "lpm installs a package from hex.pm" do
    {:ok, sink} = StringIO.open("")
    ctx = %Lepton.Ctx{cwd: "/", env: %{}, stdout: sink, stderr: sink}
    assert {:ok, _} = Lepton.Pkg.install(ctx, "decimal", "~> 2.0", true)
    assert {"3\n", 0} = sh(~s|elixir -e 'IO.puts(Decimal.add(1, 2))'|)
  end
end
