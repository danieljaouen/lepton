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
