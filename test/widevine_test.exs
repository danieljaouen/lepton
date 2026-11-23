defmodule Lepton.WidevineTest do
  use ExUnit.Case
  import Bitwise
  import Lepton.TestHelpers

  alias Lepton.{Apps, Widevine}
  alias Lepton.Widevine.Elf

  setup do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("wvstate"))
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
  end

  # A tiny ELF like Widevine's: one load segment, a dynamic section whose
  # RELA table holds an IRELATIVE relocation (resolver `code`) and a
  # RELATIVE one, and the resolver's instructions at 0x200.
  defp elf(code) do
    dyn_at = 0x100
    rela_at = 0x180
    code_at = 0x200
    size = code_at + 4 * length(code)
    header = <<0x7F, "ELF", 2, 1, 1, 0::72, 3::little-16, 183::little-16, 1::little-32, 0::little-64, 64::little-64, 0::little-64, 0::little-32, 64::little-16, 56::little-16, 2::little-16, 0::little-16, 0::little-16, 0::little-16>>
    load = <<1::little-32, 5::little-32, 0::little-64, 0::little-64, 0::little-64, size::little-64, size::little-64, 0x1000::little-64>>
    dynamic = <<2::little-32, 6::little-32, dyn_at::little-64, dyn_at::little-64, dyn_at::little-64, 48::little-64, 48::little-64, 8::little-64>>
    dyn = <<7::little-64, rela_at::little-64, 8::little-64, 48::little-64, 0::little-64, 0::little-64>>
    rela = <<0x300::little-64, 1032::little-64, code_at::little-64, 0x308::little-64, 1027::little-64, 0x42::little-64>>
    body = for(w <- code, into: <<>>, do: <<w::little-32>>)
    pad = fn bin, to -> bin <> :binary.copy(<<0>>, to - byte_size(bin)) end
    header |> Kernel.<>(load) |> Kernel.<>(dynamic) |> pad.(dyn_at) |> Kernel.<>(dyn) |> pad.(rela_at) |> Kernel.<>(rela) |> pad.(code_at) |> Kernel.<>(body)
  end

  # tbz x8, #62, +n instructions
  defp tbz_x8_62(n), do: 0x36000000 ||| 1 <<< 31 ||| 30 <<< 19 ||| n <<< 5 ||| 8

  test "IRELATIVE relocations become RELATIVE ones to what the resolver picks without CPU features" do
    # Widevine's: the plain version unless the loader says the CPU has MTE.
    code = [0xD503245F, 0xAA0003E8, 0x90000000, 0x91048C00, tbz_x8_62(3), 0xF9400828, 0xF9400828, 0xD65F03C0]
    {:ok, fixed, 1} = Elf.fix_irelative(elf(code))
    <<_::binary-0x180, _::binary-8, info::little-64, addend::little-64, _::binary-8, info2::little-64, addend2::little-64, _::binary>> = fixed
    assert {info, addend} == {1027, 0x123}
    # The RELATIVE one stays as it was, and so does everything else.
    assert {info2, addend2} == {1027, 0x42}
    assert byte_size(fixed) == byte_size(elf(code))
    assert {:ok, ^fixed, 0} = Elf.fix_irelative(fixed)
  end

  test "a resolver it can't follow is an error, not a guess" do
    # ldr x8, [x1, #16] on the path taken.
    code = [0xD503245F, 0xF9400828, 0xD65F03C0]
    assert {:error, msg} = Elf.fix_irelative(elf(code))
    assert msg =~ "can't interpret"
    assert {:error, _} = Elf.fix_irelative("not an ELF")
  end

  test "adr and tbnz: the resolver's other shapes" do
    # adr x0, +16; tbnz x8, #62, +2 (not taken: x8 = 0); ret
    adr = 0x10000000 ||| (16 >>> 2) <<< 5
    tbnz = tbz_x8_62(2) ||| 1 <<< 24
    {:ok, fixed, 1} = Elf.fix_irelative(elf([adr, 0xAA0003E8, tbnz, 0xD65F03C0, 0xD65F03C0]))
    <<_::binary-0x180, _::binary-8, 1027::little-64, addend::little-64, _::binary>> = fixed
    assert addend == 0x200 + 16
  end

  test "Chrome's package in Google's repository index; a .deb's members" do
    index = """
    Package: google-chrome-beta
    Version: 159.0.1-1
    Filename: pool/main/g/google-chrome-beta/beta.deb
    Size: 10
    SHA256: AA

    Package: google-chrome-stable
    Version: 158.0.8127.36-1
    Filename: pool/main/g/google-chrome-stable/google-chrome-stable_158.0.8127.36-1_arm64.deb
    Size: 142048460
    SHA256: E06DC16E
    """

    assert Widevine.parse_index(index) == %{version: "158.0.8127.36-1", filename: "pool/main/g/google-chrome-stable/google-chrome-stable_158.0.8127.36-1_arm64.deb", size: 142_048_460, sha256: "e06dc16e"}
    assert Widevine.parse_index("Package: other\n") == nil

    member = fn name, data -> String.pad_trailing(name, 16) <> String.pad_trailing("0", 32) <> String.pad_trailing(to_string(byte_size(data)), 10) <> "`\n" <> data <> if(rem(byte_size(data), 2) == 1, do: "\n", else: "") end
    deb = Path.join(tmp_dir("deb"), "x.deb")
    File.write!(deb, "!<arch>\n" <> member.("debian-binary", "2.0\n") <> member.("control.tar.xz/", "abc") <> member.("data.tar.xz/", "DATA!"))
    {:ok, {"data.tar.xz", offset, 5}} = Widevine.deb_member(deb, "data.tar")
    assert binary_part(File.read!(deb), offset, 5) == "DATA!"
    assert {:error, _} = Widevine.deb_member(deb, "nothing")
  end

  test "Firefox: DRM on, gcompat and xz in its packages, and Widevine's preferences once it is installed" do
    assert "gcompat" in Apps.get("firefox").packages
    assert "xz" in Apps.get("firefox").packages
    prefix = tmp_dir("wvff")
    File.mkdir_p!(Path.join(prefix, "usr/lib/firefox/distribution"))
    policies = fn -> JSON.decode!(File.read!(Path.join(prefix, "usr/lib/firefox/distribution/policies.json")))["policies"] end

    Apps.firefox_policies(prefix)
    assert policies.()["EncryptedMediaExtensions"] == %{"Enabled" => true}
    refute policies.()["Preferences"]["media.gmp-widevinecdm.version"]
    assert Widevine.env() == %{}

    File.mkdir_p!(Widevine.gmp_dir())
    File.write!(Path.join(Widevine.gmp_dir(), "libwidevinecdm.so"), "")
    File.write!(Path.join(Widevine.gmp_dir(), "manifest.json"), ~s({"version": "4.10.3112.0"}))
    Apps.firefox_policies(prefix)
    assert policies.()["Preferences"]["media.gmp-widevinecdm.version"]["Value"] == "system-installed"
    assert policies.()["Preferences"]["media.gmp-widevinecdm.autoupdate"]["Value"] == false
    assert Widevine.env() == %{"MOZ_GMP_PATH" => Widevine.gmp_dir()}
    assert Widevine.version() == "4.10.3112.0"
  end

  test "the widevine command: status, root only for changes, remove" do
    {out, 0} = sh("widevine")
    assert out =~ "not installed"
    assert {_, 1} = sh("widevine install", user: "nobody")
    assert {_, 2} = sh("widevine frobnicate")

    File.mkdir_p!(Widevine.gmp_dir())
    File.write!(Path.join(Widevine.gmp_dir(), "libwidevinecdm.so"), "")
    File.write!(Path.join(Widevine.gmp_dir(), "manifest.json"), ~s({"version": "4.10.3112.0"}))
    {out, 0} = sh("widevine status")
    assert out =~ "Widevine 4.10.3112.0 is installed"
    {_, 0} = sh("widevine remove")
    refute Widevine.installed?()
  end
end
