defmodule Lepton.AppsTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Alpine, Apps}

  @index """
  C:Q1abc=
  P:firefox
  V:160.0-r0
  S:1000
  I:5000
  D:so:libgtk-3.so.0 so:libc.musl-aarch64.so.1 mesa-egl !firefox-esr

  P:gtk+3.0
  V:3.24.49-r0
  S:200
  I:900
  D:so:libc.musl-aarch64.so.1 cmd:glib-compile-schemas
  p:so:libgtk-3.so.0=0 so:libgdk-3.so.0=0

  P:musl
  V:1.2.5-r10
  S:10
  I:20
  p:so:libc.musl-aarch64.so.1=1

  P:glib
  V:2.84.4-r0
  S:300
  I:800
  D:so:libc.musl-aarch64.so.1
  p:cmd:glib-compile-schemas=2.84.4-r0

  P:mesa-egl
  V:25.1.9-r0
  S:9000
  I:90000
  D:llvm22-libs
  """

  defp index do
    pkgs = Alpine.parse_index(@index, "main")
    Enum.reduce(pkgs, %{packages: %{}, provides: %{}}, fn p, acc ->
      %{acc | packages: Map.put(acc.packages, p.name, p), provides: Enum.reduce(p.provides, acc.provides, &Map.put(&2, &1, p.name))}
    end)
  end

  test "the package index: fields, provides, dependencies, exclusions" do
    [ff | _] = Alpine.parse_index(@index, "community")
    assert %Alpine.Pkg{name: "firefox", version: "160.0-r0", repo: "community", size: 1000, installed_size: 5000} = ff
    assert "mesa-egl" in ff.deps

    assert {:ok, pkgs} = Alpine.resolve(index(), ["firefox"], ~r/^mesa.*$/)
    assert Enum.map(pkgs, & &1.name) |> Enum.sort() == ["firefox", "glib", "gtk+3.0", "musl"]
    # Without the exclusion, mesa-egl's missing dependency is reported.
    assert {:error, {:unresolved, "llvm22-libs"}} = Alpine.resolve(index(), ["firefox"])
  end

  test "unpacking packages: gzip members back to back, PAX names, links, metadata left out" do
    src = tmp_dir("apksrc")
    long = String.duplicate("d", 120)
    File.mkdir_p!(Path.join([src, "usr/lib", long]))
    File.write!(Path.join([src, "usr/lib", long, "libx.so.1"]), "ELF!")
    File.write!(Path.join(src, ".PKGINFO"), "pkgname = x\n")
    File.mkdir_p!(Path.join(src, "usr/bin"))
    File.write!(Path.join(src, "usr/bin/tool"), "#!/bin/sh\n")
    File.chmod!(Path.join(src, "usr/bin/tool"), 0o755)
    File.ln_s!("libx.so.1", Path.join([src, "usr/lib", long, "libx.so"]))

    tar = fn name, files ->
      path = Path.join(tmp_dir("tar"), name)
      File.cd!(src, fn -> :ok = :erl_tar.create(String.to_charlist(path), Enum.map(files, &String.to_charlist/1), [:compressed]) end)
      File.read!(path)
    end

    # An apk is a signature archive, a metadata archive and the files, each gzipped.
    apk = Path.join(tmp_dir("apk"), "x.apk")
    File.write!(apk, tar.("ctl.tgz", [".PKGINFO"]) <> tar.("data.tgz", ["usr"]))
    dest = tmp_dir("apkdest")
    assert :ok = Alpine.extract(apk, dest)
    assert File.read!(Path.join([dest, "usr/lib", long, "libx.so.1"])) == "ELF!"
    assert {:ok, "libx.so.1"} = File.read_link(Path.join([dest, "usr/lib", long, "libx.so"]))
    assert Bitwise.band(File.stat!(Path.join(dest, "usr/bin/tool")).mode, 0o777) == 0o755
    refute File.exists?(Path.join(dest, ".PKGINFO"))
  end

  test "apps: the environment Firefox runs in" do
    env = Apps.env("/apps/firefox", %{"WAYLAND_DISPLAY" => "wayland-0", "HOME" => "/home/alice"})
    assert env["LD_LIBRARY_PATH"] == "/apps/firefox/usr/lib/firefox:/apps/firefox/usr/lib:/apps/firefox/lib"
    assert env["MOZ_ENABLE_WAYLAND"] == "1" and env["GDK_BACKEND"] == "wayland"
    assert env["WAYLAND_DISPLAY"] == "wayland-0" and env["HOME"] == "/home/alice"
    assert env["FONTCONFIG_FILE"] == "/apps/firefox/etc/fonts/lepton.conf"
  end

  test "app and firefox: listing, and installing needs root" do
    state = tmp_dir("appstate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    {:ok, _} = Lepton.Users.create("alice", "wonderland", home_root: tmp_dir("h"))

    assert {out, 0} = sh("app")
    assert out =~ ~r/^firefox\s+the Firefox web browser\s+not installed$/m
    {:ok, err} = StringIO.open("")
    assert {"", 1} = sh("app install firefox", user: "alice", stderr: err)
    assert StringIO.flush(err) =~ "permission denied"
    {:ok, err} = StringIO.open("")
    assert {"", 1} = sh("firefox", user: "alice", stderr: err)
    assert StringIO.flush(err) =~ "sudo app install firefox"
    assert {"", 2} = sh("app frobnicate")
  end
end
