defmodule Lepton.USBTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.USB

  # A sysfs-like tree: a root hub, a hub on port 1 with a keyboard on its
  # port 2 and a DisplayLink adapter on its port 10, and a disk on port 2.
  defp sysfs do
    root = tmp_dir("usbsys")
    drivers = Path.join(root, "drivers")

    dev = fn name, attrs ->
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      for {k, v} <- attrs, do: File.write!(Path.join(dir, k), v <> "\n")
      dir
    end

    iface = fn name, class, driver, nodes ->
      dir = dev.(name, %{"bInterfaceClass" => class})

      if driver do
        File.mkdir_p!(Path.join(drivers, driver))
        File.ln_s!(Path.join(drivers, driver), Path.join(dir, "driver"))
      end

      for n <- nodes, do: File.mkdir_p!(Path.join(dir, n))
      # sysfs links back up the tree: never followed
      File.ln_s!(root, Path.join(dir, "subsystem"))
    end

    dev.("usb1", %{"busnum" => "1", "idVendor" => "1d6b", "idProduct" => "0002", "product" => "xHCI Host Controller", "bDeviceClass" => "09", "speed" => "480", "maxchild" => "4"})
    iface.("1-0:1.0", "09", "hub", [])
    dev.("1-1", %{"busnum" => "1", "idVendor" => "0409", "idProduct" => "55aa", "product" => "QEMU USB Hub", "bDeviceClass" => "09", "speed" => "12", "maxchild" => "8"})
    iface.("1-1:1.0", "09", "hub", ["1-1-port1"])
    dev.("1-1.2", %{"busnum" => "1", "idVendor" => "0627", "idProduct" => "0001", "product" => "QEMU USB Keyboard", "bDeviceClass" => "00", "speed" => "12"})
    iface.("1-1.2:1.0", "03", "usbhid", ["0003:0627:0001.0001/input/input3/event2"])
    dev.("1-1.10", %{"busnum" => "1", "idVendor" => "17e9", "idProduct" => "02a9", "bDeviceClass" => "ff", "speed" => "480"})
    iface.("1-1.10:1.0", "ff", "udl", ["drm/card1", "graphics/fb1"])
    dev.("1-2", %{"busnum" => "1", "idVendor" => "0781", "idProduct" => "5581", "manufacturer" => "SanDisk", "product" => "Ultra", "bDeviceClass" => "00", "speed" => "5000"})
    iface.("1-2:1.0", "08", "usb-storage", ["host0/target0:0:0/0:0:0:0/block/sda", "net/eth1"])
    root
  end

  test "port paths: each device hangs off its hub" do
    assert USB.parent("usb1") == nil
    assert USB.parent("1-1") == "usb1"
    assert USB.parent("1-1.2") == "1-1"
    assert USB.parent("2-3.1.4") == "2-3.1"
  end

  test "the device tree: hubs, their ports, drivers and what devices became" do
    devices = USB.devices(sysfs())
    assert Enum.map(devices, & &1.name) == ["usb1", "1-1", "1-1.2", "1-1.10", "1-2"]

    by = Map.new(devices, &{&1.name, &1})
    assert USB.kind(by["usb1"]) == "root hub"
    assert USB.kind(by["1-1"]) == "hub" and by["1-1"].ports == 8
    assert USB.kind(by["1-1.2"]) == "HID"
    assert by["1-1.2"].drivers == ["usbhid"] and by["1-1.2"].nodes == ["event2"]
    assert USB.kind(by["1-1.10"]) == "display"
    assert by["1-1.10"].nodes == ["fb1"]
    assert USB.label(by["1-1.10"]) == "17e9:02a9"
    assert Enum.sort(by["1-2"].nodes) == ["eth1", "sda"]

    assert Enum.map(USB.tree(devices), fn {depth, d} -> {depth, d.name} end) ==
             [{0, "usb1"}, {1, "1-1"}, {2, "1-1.2"}, {2, "1-1.10"}, {1, "1-2"}]

    assert USB.describe(devices) == [
             "usb1  xHCI Host Controller (root hub, 4 ports) [480 Mbit/s]",
             "  1-1 0409:55aa  QEMU USB Hub (hub, 8 ports) [12 Mbit/s]",
             "    1-1.2 0627:0001  QEMU USB Keyboard (HID) [12 Mbit/s; usbhid] -> event2",
             "    1-1.10 17e9:02a9  17e9:02a9 (display) [480 Mbit/s; udl] -> fb1",
             "  1-2 0781:5581  Ultra (storage) [5 Gbit/s; usb-storage] -> " <> Enum.join(by["1-2"].nodes, " ")
           ]
  end

  test "usb: no controllers on a machine without USB in sysfs" do
    unless File.dir?("/sys/bus/usb/devices") do
      assert {"No USB controllers (the VM has none, or its driver isn't loaded).\n", 0} = sh("usb")
    end

    assert {"", 2} = sh("usb frob")
  end

  # Inside Lepton: QEMU's keyboard is plugged into a USB hub (mix lepton.qemu).
  @tag :native
  test "the VM's hub and the keyboard behind it" do
    devices = USB.devices()
    hub = Enum.find(devices, &(USB.kind(&1) == "hub"))
    assert hub, "no hub in #{inspect(Enum.map(devices, & &1.name))}"
    kbd = Enum.find(devices, &(&1.parent == hub.name))
    assert kbd && "usbhid" in kbd.drivers
    assert Enum.any?(kbd.nodes, &String.starts_with?(&1, "event"))
    assert {out, 0} = sh("usb")
    assert out =~ "(hub, "
    assert out =~ ~r/#{Regex.escape(kbd.name)} .*usbhid/
  end
end
