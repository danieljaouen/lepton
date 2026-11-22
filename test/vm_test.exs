defmodule Lepton.VMTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.VM

  test "the qemu app: the emulator, qemu-img and UEFI firmware" do
    app = Lepton.Apps.get("qemu")
    assert app.packages == ["qemu-system-aarch64", "qemu-img", "aavmf"]
    assert app.exe == nil and app.gtk == false
  end

  test "names, sizes and settings" do
    assert VM.valid_name?("lepton-1.2") and VM.valid_name?("a")
    refute VM.valid_name?("../x") or VM.valid_name?("") or VM.valid_name?("-x") or VM.valid_name?("a b")
    assert VM.parse_size("16G") == 16 * 1024 ** 3
    assert VM.parse_size("512M") == 512 * 1024 ** 2
    assert VM.parse_size("10GiB") == 10 * 1024 ** 3
    assert VM.parse_size("lots") == nil

    {:ok, cfg} = VM.update(%{"iso" => ""}, ["memory=4096", "cpus=4", "forward=2222:22, 8080:80", "iso=/root/x.iso"])
    assert cfg["memory"] == 4096 and cfg["cpus"] == 4 and cfg["iso"] == "/root/x.iso"
    assert cfg["forward"] == ["2222:22", "8080:80"]
    assert {:error, _} = VM.update(cfg, ["memory=lots"])
    assert {:error, _} = VM.update(cfg, ["forward=22"])
    assert {:error, msg} = VM.update(cfg, ["colour=blue"])
    assert msg =~ "unknown setting"
  end

  test "settings are kept as TOML and read back with defaults" do
    home = tmp_dir("vmhome")
    File.mkdir_p!(VM.dir(home, "test"))
    VM.write_config(home, "test", %{"memory" => 1024, "iso" => "/root/lepton.iso", "forward" => ["2222:22"]})
    assert File.read!(VM.config_file(home, "test")) == ~s(memory = 1024\ncpus = 2\niso = "/root/lepton.iso"\nforward = ["2222:22"]\n)
    cfg = VM.config(home, "test")
    assert cfg["memory"] == 1024 and cfg["cpus"] == 2 and cfg["forward"] == ["2222:22"] and cfg["name"] == "test"
    assert VM.list(home) == ["test"]
    assert VM.exists?(home, "test")
    refute VM.running?(home, "test")
    assert :ok = VM.delete(home, "test")
    assert VM.list(home) == []
  end

  test "QEMU's arguments: KVM or emulated, the disk, the CD first, the console and monitor sockets" do
    paths = %{disk: "/vms/t/disk.qcow2", firmware: "/fw/QEMU_EFI.fd", data: "/q/share/qemu", serial: "/run/s.sock", qmp: "/run/q.sock"}
    cfg = %{"name" => "t", "memory" => 1024, "cpus" => 2, "iso" => "/root/lepton.iso", "forward" => ["2222:22"]}
    args = VM.args(cfg, paths, true)
    s = Enum.join(args, " ")
    assert s =~ "-accel kvm -cpu host"
    assert s =~ "-smp 2 -m 1024"
    assert s =~ "-bios /fw/QEMU_EFI.fd -L /q/share/qemu"
    assert s =~ "file=/vms/t/disk.qcow2,format=qcow2"
    assert s =~ "file=/root/lepton.iso,media=cdrom,readonly=on"
    assert s =~ "scsi-cd,drive=cd0,bootindex=0"
    assert s =~ "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22"
    assert s =~ "socket,id=ser0,path=/run/s.sock,server=on,wait=off"
    assert s =~ "-qmp unix:/run/q.sock,server=on,wait=off -display none"

    s = Enum.join(VM.args(%{cfg | "iso" => "", "forward" => []}, paths, false), " ")
    assert s =~ "-accel tcg,thread=multi -cpu max"
    refute s =~ "cdrom" or s =~ "hostfwd"
  end

  # The build tasks live in the repository only (:docs).
  @tag :docs
  test "lepton.qemu runs the guest on Hypervisor.framework, KVM, or emulated" do
    assert Mix.Tasks.Lepton.Qemu.accel({:unix, :darwin}, true, false) == ["-accel", "hvf", "-cpu", "host"]
    assert Mix.Tasks.Lepton.Qemu.accel({:unix, :linux}, true, true) == ["-accel", "kvm", "-cpu", "host"]
    assert Mix.Tasks.Lepton.Qemu.accel({:unix, :linux}, true, false) == ["-accel", "tcg,thread=multi", "-cpu", "max"]
  end

  test "vm without QEMU or machines says what to do" do
    home = tmp_dir("vmcmd")
    System.put_env("LEPTON_STATE_DIR", tmp_dir("vmstate"))

    try do
      {out, 0} = sh("HOME=#{home} vm")
      assert out =~ "No machines yet" and out =~ "sudo app install qemu"
      {out, 1} = sh("HOME=#{home} vm create test 2>&1")
      assert out =~ "QEMU isn't installed"
      {out, 1} = sh("HOME=#{home} vm start nope 2>&1")
      assert out =~ "no machine called nope"
      {out, 1} = sh("HOME=#{home} vm create ../x 2>&1")
      assert out =~ "isn't a valid name" or out =~ "QEMU isn't installed"
    after
      System.delete_env("LEPTON_STATE_DIR")
    end
  end
end
