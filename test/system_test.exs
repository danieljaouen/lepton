defmodule Lepton.SystemTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  test "elisp reader" do
    {:ok, [form]} = Lepton.Elisp.read_all(~s|(define-key evil-normal-state-map (kbd ";") 'evil-ex) ; comment|)
    assert [{:sym, "define-key"}, {:sym, "evil-normal-state-map"}, [{:sym, "kbd"}, ";"], {:quote, {:sym, "evil-ex"}}] = form
  end

  test "toml reader" do
    cfg = Lepton.TOML.parse(~s|add_newline = true\n[username]\nformat = "[$user]($style) "\nshow_always = true\n|)
    assert cfg["add_newline"] == true
    assert cfg["username"]["format"] == "[$user]($style) "
  end

  test "gitconfig parsing with includes" do
    dir = tmp_dir("cfg")
    File.write!(Path.join(dir, ".gitconfig.local"), "[user]\n  name = Local\n")
    cfg = Lepton.Git.Config.parse("[include]\n path = .gitconfig.local\n[alias]\n st = status\n", dir)
    assert Lepton.Git.Config.get(cfg, "user", "name") == "Local"
    assert Lepton.Git.Config.get(cfg, "alias", "st") == "status"
  end

  test "DHCP packets" do
    mac = <<1, 2, 3, 4, 5, 6>>
    pkt = Lepton.Net.DHCP.packet(1, mac, 42, [])
    assert byte_size(pkt) > 240
    reply = <<2>> <> binary_part(pkt, 1, 15) <> <<10, 0, 2, 15>> <> binary_part(pkt, 20, 216) <> <<99, 130, 83, 99, 53, 1, 2, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 3, 255>>
    msg = Lepton.Net.DHCP.parse(reply)
    assert msg.yiaddr == {10, 0, 2, 15}
    assert msg.options[3] == {10, 0, 2, 2}
    assert msg.options[6] == [{10, 0, 2, 3}]
    assert Lepton.Net.mask_to_prefix({255, 255, 255, 0}) == 24
  end

  test "html layout for the text browser" do
    {lines, links} = "<h1>Title</h1><p>Hello <a href='/x'>link</a> &amp; more</p><ul><li>one</li></ul>" |> Lepton.Browser.parse() |> Lepton.Browser.layout(40)
    text = Enum.map_join(lines, "\n", &Lepton.Style.strip/1)
    assert text =~ "Title"
    assert text =~ "Hello link[1] & more"
    assert text =~ "• one"
    assert links == ["/x"]
  end

  @tag :dotfiles
  test "~/.iex.exs helpers (sh, ~x) run commands in lsh" do
    {:ok, out} = StringIO.open("")
    ctx = %Lepton.Ctx{cwd: tmp_dir("iex"), env: %{"HOME" => dotfiles_home(), "NO_COLOR" => "1"}, stdin: elem(StringIO.open("MyIExHelpers.sh(\"echo from-iex\")\n"), 1), stdout: out, stderr: out}
    assert Lepton.IEx.run(ctx) == 0
    {_, text} = StringIO.contents(out)
    assert text =~ "from-iex"
  end

  @tag :dotfiles
  test "keys shows bindings loaded from every dotfile" do
    {out, 0} = sh("keys")
    assert out =~ "evil-normal-state-map"
    assert out =~ "prefix: C-t"
    assert out =~ "git gl"
  end

  @tag :native
  test "virtual filesystems are mounted" do
    mounts = Enum.map(Lepton.Sys.mounts(), & &1.dir)
    for dir <- ["/proc", "/sys", "/dev", "/run"], do: assert(dir in mounts, "#{dir} not mounted")
  end

  @tag :native
  test "we are PID 1 and drivers are loaded" do
    assert Lepton.Sys.pid1?()
    loaded = Enum.map(Lepton.Kmod.loaded(), & &1.name)
    assert "virtio_net" in loaded
    assert "simpledrm" in loaded or "virtio_gpu" in loaded
  end

  test "Lepton is the init process; another VM on it is a program (Mix building Lepton in Lepton)" do
    assert Lepton.Sys.pid1?("1") and Lepton.Sys.pid1?(~c"1")
    refute Lepton.Sys.pid1?("4242")
    # Here: the OS itself in lepton-test, a program on a Mac.
    assert Lepton.Sys.native?() == (Lepton.Sys.pid1?() and File.exists?("/bin/busybox"))
  end

  test "/etc/os-release has Lepton's version" do
    file = Enum.find(["rootfs/etc/os-release", "/etc/os-release"], &File.exists?/1)
    assert File.read!(file) =~ ~s(VERSION_ID="#{Lepton.Init.version()}"\n)
  end

  # The build tasks live in the repository only, like the docs (:docs).
  @tag :docs
  test "a publish bumps the minor version" do
    assert Mix.Tasks.Lepton.Version.bump("1.0.0") == "1.1.0"
    assert Mix.Tasks.Lepton.Version.bump("1.9.3") == "1.10.0"
    assert Mix.Tasks.Lepton.Version.bump("1.0.0", :patch) == "1.0.1"
  end

  @tag :native
  test "uname, hostname and memory come from the kernel" do
    {out, 0} = sh("uname -a")
    assert out =~ "Linux lepton"
    assert {"lepton\n", 0} = sh("hostname")
    assert Lepton.Sys.meminfo()["MemTotal"] > 0
  end

  @tag :native
  @tag :dotfiles
  test "dotfiles are installed in /root per the locations/ layout" do
    for f <- ~w(.tmux.conf .gitconfig .zshrc .spacemacs .spacemacs.d/keybindings.el .config/starship.toml .iex.exs) do
      assert File.exists?(Path.join("/root", f)), "missing ~/#{f}"
    end
  end

  @tag :network
  test "network is configured by DHCP and DNS resolves" do
    assert Lepton.Net.leases() != %{}
    assert {:ok, _} = :inet.getaddr(~c"github.com", :inet)
  end
end
