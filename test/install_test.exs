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
