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

  test "Firefox's session bus: started with it, shared by later starts (new tabs), none without dbus-daemon" do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("busstate"))
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    # Unix socket paths are short: the runtime directory in /tmp.
    run = "/tmp/lpb-#{System.unique_integer([:positive])}"
    File.mkdir_p!(run)
    on_exit(fn -> File.rm_rf(run) end)
    user = %Lepton.Users{name: "alice", uid: 1000, gid: 1000}
    env = %{"XDG_RUNTIME_DIR" => run}

    assert Apps.get("firefox")[:bus] and "dbus" in Apps.get("firefox").packages
    # Installed before dbus came with it (and no Bluetooth): no bus.
    assert Apps.session_bus("firefox", user, env) == nil

    exe = Path.join(Apps.dir("firefox"), "usr/bin/dbus-daemon")
    File.mkdir_p!(Path.dirname(exe))
    File.write!(exe, "")
    assert %{path: path, start: true, exe: ^exe, env: %{"LD_LIBRARY_PATH" => _}} = Apps.session_bus("firefox", user, env)
    assert path == Path.join(run, "bus")

    # One listening: later starts use it.
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(sock, %{family: :local, path: path})
    :ok = :socket.listen(sock)
    assert Apps.bus_listening?(path)
    assert %{path: ^path, start: false} = Apps.session_bus("firefox", user, env)
    :socket.close(sock)
    refute Apps.bus_listening?(path)
  end

  defp app_index(firefox_version) do
    text = """
    P:firefox
    V:#{firefox_version}
    S:100
    I:200

    P:font-dejavu
    V:2.37-r6
    S:10
    I:20

    P:icu-data-en
    V:78.1-r0
    S:10
    I:20

    P:dbus
    V:1.16.2-r0
    S:10
    I:20

    """

    fonts = Enum.map_join(Apps.asian_fonts(), "\n", &"P:#{&1}\nV:1-r0\nS:10\nI:20\n")
    pkgs = Alpine.parse_index(text <> fonts, "community")
    %{packages: Map.new(pkgs, &{&1.name, &1}), provides: %{}}
  end

  defp fonts, do: Enum.map(Apps.asian_fonts(), &{&1, "1-r0"})

  defp record(dir, versions) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".lepton-app"), Base.encode64(:erlang.term_to_binary(%{packages: versions, size: 1, branch: "v3.24"})))
  end

  test "fonts: the app's own, with Droid's CJK fallbacks left to Noto CJK" do
    prefix = tmp_dir("fontsconf")
    assert :ok = Apps.fonts_conf(prefix)
    conf = File.read!(Path.join(prefix, "etc/fonts/lepton.conf"))
    assert conf =~ "<dir>#{prefix}/usr/share/fonts</dir>"
    assert conf =~ "<glob>*/DroidSansFallback*</glob>"
  end

  test "apps' libraries go on musl's search path, after the system's, once" do
    file = Path.join(tmp_dir("muslpath"), "ld-musl-aarch64.path")
    File.write!(file, "/usr/lib/musl\n")
    Apps.musl_path("/var/lib/lepton/apps/firefox", file)
    Apps.musl_path("/var/lib/lepton/apps/firefox", file)
    assert File.read!(file) == "/usr/lib/musl\n/var/lib/lepton/apps/firefox/usr/lib\n/var/lib/lepton/apps/firefox/lib\n"
  end

  test "Firefox's policies: Photon's title bar, and no OpenH264 (a glibc build), tabs unloaded when memory is short" do
    prefix = tmp_dir("policies")
    assert Apps.firefox_policies(prefix) == :ok
    refute File.exists?(Path.join(prefix, "usr/lib/firefox/distribution/policies.json"))
    File.mkdir_p!(Path.join(prefix, "usr/lib/firefox/distribution"))
    assert Apps.firefox_policies(prefix) == :ok
    prefs = JSON.decode!(File.read!(Path.join(prefix, "usr/lib/firefox/distribution/policies.json")))["policies"]["Preferences"]
    assert prefs["media.gmp-gmpopenh264.enabled"] == %{"Value" => false, "Status" => "locked"}
    assert prefs["media.gmp-gmpopenh264.autoupdate"]["Value"] == false
    assert prefs["browser.tabs.inTitlebar"]["Value"] == 0
    assert prefs["browser.tabs.unloadOnLowMemory"]["Value"] == true
    # No Speech Dispatcher: no "speech synthesis ... library is missing" bar.
    assert prefs["media.webspeech.synth.enabled"] == %{"Value" => false, "Status" => "locked"}
  end

  test "updates: checks every 10 days, stages a newer build, applies it (or rolls back)" do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("updstate"))
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    installed = [{"firefox", "160.0-r0"}, {"font-dejavu", "2.37-r6"}, {"icu-data-en", "78.1-r0"}, {"dbus", "1.16.2-r0"}]
    record(Apps.dir("firefox"), installed ++ fonts())
    File.write!(Path.join(Apps.dir("firefox"), "old"), "")

    assert Apps.changes(installed, [{"firefox", "161.0-r0"}, {"font-dejavu", "2.37-r6"}, {"nss", "3.1"}]) ==
             [{"dbus", "1.16.2-r0", nil}, {"firefox", "160.0-r0", "161.0-r0"}, {"icu-data-en", "78.1-r0", nil}, {"nss", nil, "3.1"}]

    # Never checked: due. Checking with the same versions: up to date, and not due for 10 days.
    # Installed from another definition of the app (packages Lepton has added since): checked now;
    # the same packages after all: recorded, and not again.
    assert Apps.check_due?("firefox") and Apps.redefined?("firefox")
    # Fonts for Chinese, Japanese, Korean, Thai, Hindi and the other Asian scripts.
    assert ["font-noto-cjk", "font-droid-nonlatin"] -- Apps.get("firefox").packages == []
    now = System.os_time(:second)
    assert {:ok, :current} = Apps.stage("firefox", fn _ -> :ok end, index: app_index("160.0-r0"))
    refute Apps.redefined?("firefox")
    refute Apps.check_due?("firefox", now + 9 * 86_400)
    assert Apps.check_due?("firefox", now + 10 * 86_400 + 60)

    # A newer build, already downloaded (staged): stage reports it without downloading again.
    record(Apps.staged_dir("firefox"), [{"firefox", "161.0-r0"}, {"font-dejavu", "2.37-r6"}, {"icu-data-en", "78.1-r0"}, {"dbus", "1.16.2-r0"}] ++ fonts())
    File.write!(Path.join(Apps.staged_dir("firefox"), "new"), "")
    assert {:ok, {:staged, [{"firefox", "160.0-r0", "161.0-r0"}]}} = Apps.stage("firefox", fn _ -> :ok end, index: app_index("161.0-r0"))
    assert Apps.staged?("firefox")

    # Setup failing puts the old version back; succeeding swaps the new one in.
    assert {:error, "boom"} = Apps.apply_staged("firefox", fn _, _ -> {:error, "boom"} end)
    assert Apps.version("firefox") == "160.0-r0" and File.exists?(Path.join(Apps.dir("firefox"), "old"))
    record(Apps.staged_dir("firefox"), [{"firefox", "161.0-r0"}, {"font-dejavu", "2.37-r6"}, {"icu-data-en", "78.1-r0"}, {"dbus", "1.16.2-r0"}] ++ fonts())
    assert :ok = Apps.apply_staged("firefox", fn _, prefix -> if File.exists?(Path.join(prefix, ".lepton-app")), do: :ok end)
    assert Apps.version("firefox") == "161.0-r0"
    refute Apps.staged?("firefox") or File.exists?(Path.join(Apps.dir("firefox"), "old"))
    assert :none = Apps.apply_staged("firefox")
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
    {:ok, err} = StringIO.open("")
    assert {"", 1} = sh("app update", user: "alice", stderr: err)
    assert StringIO.flush(err) =~ "permission denied"
    {:ok, err} = StringIO.open("")
    assert {"", 1} = sh("app reinstall firefox", user: "alice", stderr: err)
    assert StringIO.flush(err) =~ "permission denied"
    {:ok, err} = StringIO.open("")
    assert {"", 1} = sh("app reinstall nothing", stderr: err)
    assert StringIO.flush(err) =~ "no app called nothing"
    assert {"", 2} = sh("app frobnicate")
  end
end
