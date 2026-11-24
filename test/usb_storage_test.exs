defmodule Lepton.USB.StorageTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.USB.Storage

  # A fake /sys/bus/usb/devices: a T7 (UAS-capable, so usb-storage left its
  # interface unclaimed) and a USB stick that usb-storage has.
  defp sysfs do
    root = tmp_dir("usbsys")
    write = fn path, text -> File.mkdir_p!(Path.dirname(Path.join(root, path))); File.write!(Path.join(root, path), text <> "\n") end
    write.("4-1/idVendor", "04e8")
    write.("4-1/idProduct", "4001")
    write.("4-1:1.0/bInterfaceClass", "08")
    write.("1-2/idVendor", "0781")
    write.("1-2/idProduct", "5567")
    write.("1-2:1.0/bInterfaceClass", "08")
    File.mkdir_p!(Path.join(root, "1-2:1.0/driver"))
    # a keyboard: not storage
    write.("1-3/idVendor", "05ac")
    write.("1-3/idProduct", "024f")
    write.("1-3:1.0/bInterfaceClass", "03")
    root
  end

  test "an unclaimed drive in QEMU gets usb-storage's ignore-UAS quirk and is probed again" do
    root = sysfs()
    files = tmp_dir("usbparams")
    quirks = Path.join(files, "quirks")
    probe = Path.join(files, "drivers_probe")
    File.write!(quirks, "\n")

    assert Storage.unclaimed(root) == [{"4-1:1.0", "04e8", "4001"}]
    assert Storage.fallback(vm: true, root: root, quirks: quirks, probe: probe) == ["4-1:1.0"]
    assert File.read!(quirks) == "04e8:4001:u"
    assert File.read!(probe) == "4-1:1.0"

    # On real hardware: nothing.
    File.rm!(probe)
    assert Storage.fallback(vm: false, root: root, quirks: quirks, probe: probe) == []
    refute File.exists?(probe)
  end

  test "quirks: kept, not repeated, within usb-storage's 128 characters (the oldest go first)" do
    assert Storage.with_quirks("0bc2:2322:u\n", [{"04e8", "4001"}]) == "0bc2:2322:u,04e8:4001:u"
    assert Storage.with_quirks("04e8:4001:u", [{"04e8", "4001"}]) == "04e8:4001:u"
    many = Enum.map(1..12, &{"aaaa", String.pad_leading(to_string(&1), 4, "0")})
    s = Storage.with_quirks("", many)
    assert String.length(s) <= 127 and String.ends_with?(s, "aaaa:0012:u") and not String.contains?(s, "aaaa:0001:")
  end
end
