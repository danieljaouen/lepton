defmodule Lepton.TorrentTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Torrent
  alias Lepton.Torrent.{Bencode, Magnet, Metainfo, Session, Storage, Tracker}

  setup_all do
    # (no DHT lookups on the internet from the tests)
    Application.put_env(:lepton, :torrent_dht, false)
    on_exit(fn -> Application.delete_env(:lepton, :torrent_dht) end)
  end

  defp eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  # A folder of three files (one in a subfolder), random bytes.
  defp album(sizes \\ [{"a.bin", 300_000}, {"b.txt", 70_001}, {"disc2/c.bin", 450_000}]) do
    base = tmp_dir("torrent")
    src = Path.join(base, "seed/album")
    for {f, n} <- sizes, do: (File.mkdir_p!(Path.dirname(Path.join(src, f))); File.write!(Path.join(src, f), :crypto.strong_rand_bytes(n)))
    {base, src}
  end

  test "bencode: values both ways; a dictionary's raw bytes; bad input" do
    v = %{"a" => 1, "list" => [-3, "x", %{}], "bytes" => <<0, 255, 10>>}
    bin = Bencode.encode(v)
    assert bin == "d1:ai1e5:bytes3:" <> <<0, 255, 10>> <> "4:listli-3e1:xdeee"
    assert {:ok, ^v} = Bencode.decode(bin)
    assert Bencode.raw(bin, "list") == "li-3e1:xdee"
    assert Bencode.raw(bin, "nope") == nil
    assert {:error, _} = Bencode.decode("i12")
    assert {:error, _} = Bencode.decode("5:abc")
    assert {:error, _} = Bencode.decode("i1ei2e")
  end

  test "metainfo: a folder made into a torrent and read back; one file; piece sizes" do
    {_base, src} = album()
    {:ok, bin} = Metainfo.create(src, trackers: ["udp://t.example:1337", "https://t2.example/announce"], piece_length: 65_536)
    {:ok, m} = Metainfo.parse(bin)
    assert m.name == "album" and m.length == 820_001 and m.piece_length == 65_536
    assert Metainfo.piece_count(m) == 13 and Metainfo.piece_size(m, 12) == 820_001 - 12 * 65_536
    assert Enum.map(m.files, & &1.path) == [["a.bin"], ["b.txt"], ["disc2", "c.bin"]]
    assert m.trackers == ["udp://t.example:1337", "https://t2.example/announce"]
    assert m.info_hash == :crypto.hash(:sha, Bencode.raw(bin, "info"))
    assert Metainfo.paths(m, "/d") == ["/d/album/a.bin", "/d/album/b.txt", "/d/album/disc2/c.bin"]

    one = Path.join(src, "a.bin")
    {:ok, m1} = Metainfo.parse(elem(Metainfo.create(one), 1))
    assert m1.files == [%{path: [], length: 300_000, offset: 0}] and Metainfo.paths(m1, "/d") == ["/d/a.bin"]
    assert Metainfo.piece_length_for(10_000) == 16_384 and Metainfo.piece_length_for(4_000_000_000) == 4_194_304

    # A name that would climb out of the folder doesn't.
    info = Bencode.encode(%{"name" => "..", "length" => 3, "piece length" => 16_384, "pieces" => :crypto.hash(:sha, "abc")})
    {:ok, m2} = Metainfo.from_info(info)
    assert m2.name == "_"
    assert {:error, _} = Metainfo.parse("not bencoded")
  end

  test "magnet links: hex and base32 hashes, name, trackers, peers; and back" do
    hash = :crypto.hash(:sha, "x")
    hex = Base.encode16(hash, case: :lower)
    {:ok, m} = Magnet.parse("magnet:?xt=urn:btih:#{hex}&dn=My+Film&tr=udp%3A%2F%2Ft.example%3A1&tr=https%3A%2F%2Fu.example%2Fa&x.pe=10.0.0.2:51413")
    assert m.info_hash == hash and m.name == "My Film" and m.trackers == ["udp://t.example:1", "https://u.example/a"] and m.peers == [{"10.0.0.2", 51413}]
    {:ok, m32} = Magnet.parse("magnet:?xt=urn:btih:" <> Base.encode32(hash))
    assert m32.info_hash == hash
    assert {:ok, ^m} = Magnet.parse(Magnet.link(hash, "My Film", m.trackers) <> "&x.pe=10.0.0.2:51413")
    assert {:error, _} = Magnet.parse("magnet:?dn=nothing")
  end

  test "trackers: replies (compact and not, failures), and an HTTP tracker asked" do
    assert {:ok, %{interval: 900, peers: [{"10.0.0.1", 6881}, {"192.168.1.9", 51413}]}} =
             Tracker.reply(Bencode.encode(%{"interval" => 900, "peers" => <<10, 0, 0, 1, 6881::16, 192, 168, 1, 9, 51413::16>>}))

    assert {:ok, %{peers: [{"1.2.3.4", 80}]}} = Tracker.reply(Bencode.encode(%{"peers" => [%{"ip" => "1.2.3.4", "port" => 80}]}))
    assert {:error, "the tracker says: go away"} = Tracker.reply(Bencode.encode(%{"failure reason" => "go away"}))

    # A tracker on this machine: what it was asked, and what it said.
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(l)
    me = self()

    spawn(fn ->
      {:ok, c} = :gen_tcp.accept(l)
      {:ok, req} = :gen_tcp.recv(c, 0, 5000)
      send(me, {:asked, req})
      body = Bencode.encode(%{"interval" => 60, "peers" => <<127, 0, 0, 1, 7000::16>>})
      :gen_tcp.send(c, "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body)
      :gen_tcp.close(c)
    end)

    hash = <<0, 1, 2, 255>> <> :binary.copy(<<"a">>, 16)
    args = %{info_hash: hash, peer_id: "-LP0000-abcdefghijkl", port: 6881, uploaded: 0, downloaded: 10, left: 99, event: :started}
    assert {:ok, %{interval: 60, peers: [{"127.0.0.1", 7000}]}} = Tracker.announce("http://127.0.0.1:#{port}/announce", args)
    assert_receive {:asked, req}
    assert req =~ "GET /announce?info_hash=%00%01%02%FFaaaaaaaaaaaaaaaa&peer_id=-LP0000-abcdefghijkl&port=6881"
    assert req =~ "&left=99&compact=1" and req =~ "&event=started"
  end

  test "storage: pieces across file boundaries, written and read back; what's already right" do
    {base, src} = album([{"x", 70_000}, {"y", 10}, {"z/w", 60_000}])
    {:ok, m} = Metainfo.parse(elem(Metainfo.create(src, piece_length: 32_768), 1))
    dir = Path.join(base, "copy")
    whole = for f <- ["x", "y", "z/w"], into: "", do: File.read!(Path.join(src, f))
    assert Storage.check(m, dir) == MapSet.new()

    for i <- [3, 0, 2] do
      size = Metainfo.piece_size(m, i)
      :ok = Storage.write_piece(m, dir, i, binary_part(whole, i * 32_768, size))
    end

    # piece 2 spans x, y and z/w
    assert {:ok, binary_part(whole, 2 * 32_768 + 100, 5000)} == Storage.read(m, dir, 2, 100, 5000)
    assert Storage.check(m, dir) == MapSet.new([0, 2, 3])
    assert Storage.check(m, Path.join(base, "seed")) == MapSet.new(0..(Metainfo.piece_count(m) - 1))
  end

  # A seeder (found through the listener) and a downloader of the same torrent.
  defp swarm(meta_for_leecher) do
    {base, src} = album()
    {:ok, bin} = Metainfo.create(src, piece_length: 32_768)
    {:ok, m} = Metainfo.parse(bin)
    Torrent.Listener.ensure_started()
    {:ok, seeder} = DynamicSupervisor.start_child(Torrent.Supervisor, {Session, info_hash: m.info_hash, meta: m, dir: Path.join(base, "seed"), dht: false})
    dl = Path.join(base, "dl")
    meta = if meta_for_leecher, do: m, else: nil

    {:ok, leech} =
      DynamicSupervisor.start_child(Torrent.Supervisor, {Session, key: {:test, m.info_hash}, info_hash: m.info_hash, meta: meta, name: "album", dir: dl, dht: false, peers: [{"127.0.0.1", Torrent.Listener.port()}]})

    on_exit(fn -> for p <- [seeder, leech], Process.alive?(p), do: DynamicSupervisor.terminate_child(Torrent.Supervisor, p) end)
    {src, dl, seeder, leech}
  end

  defp same_files(src, dl), do: for(f <- ["a.bin", "b.txt", "disc2/c.bin"], do: File.read!(Path.join(src, f)) == File.read!(Path.join([dl, "album", f])))

  test "a download from a peer: every piece checked, the files the same, the seeder's upload counted" do
    {src, dl, seeder, leech} = swarm(true)
    assert eventually(fn -> Session.status(leech).state == :seeding end, 200)
    s = Session.status(leech)
    assert s.progress == 1.0 and s.bad == 0 and s.done == 820_001
    assert same_files(src, dl) == [true, true, true]
    assert Session.status(seeder).uploaded == 820_001
  end

  test "a magnet link: the file list comes from the peer (BEP 9), then the files" do
    {src, dl, _seeder, leech} = swarm(false)
    assert Session.status(leech).state in [:metadata, :checking, :downloading, :seeding]
    assert eventually(fn -> Session.status(leech).state == :seeding end, 200)
    assert Session.status(leech).name == "album"
    assert same_files(src, dl) == [true, true, true]
  end

  test "the full-screen list: each torrent's line, the keys that add and confirm" do
    t = %{id: "ab" <> String.duplicate("0", 38), name: "Film", state: :downloading, size: 2_000_000, done: 500_000, progress: 0.25, peers: 7, connecting: 2, down_rate: 150_000.0, up_rate: 2048.0, eta: 75, dir: "/d", error: nil}
    {"Film", line} = Lepton.Torrent.CLI.describe(t)
    assert line == "downloading, 488.3 KB of 1.9 MB, ↓ 146.5 KB/s, ↑ 2.0 KB/s, 7 peers, 1m left"
    {_, stopped} = Lepton.Torrent.CLI.describe(%{t | state: :stopped})
    assert stopped == "stopped, /d"
    screen = Lepton.Torrent.CLI.screen(%{sel: 0, input: nil, confirm: nil, message: nil}, [t], {24, 100})
    assert Enum.any?(screen, &(&1 =~ "1. Film")) and Enum.any?(screen, &(&1 =~ "[#######" and &1 =~ "25.0%"))
    ctx = %Lepton.Ctx{env: %{"HOME" => tmp_dir("torrenthome")}}
    st = Lepton.Torrent.CLI.key(ctx, %{sel: 0, input: nil, confirm: nil, message: nil}, [t], "a")
    assert st.input == ""
    st = Lepton.Torrent.CLI.key(ctx, st, [t], {:paste, " magnet:?xt=urn:btih:zz \n"})
    assert st.input == "magnet:?xt=urn:btih:zz"
    st = Lepton.Torrent.CLI.key(ctx, st, [t], "RET")
    assert st.input == nil and st.message =~ "no BitTorrent hash"
    assert %{confirm: {:delete, ^t}} = Lepton.Torrent.CLI.key(ctx, st, [t], "D")
    assert Lepton.Torrent.CLI.key(ctx, st, [t], "q") == :quit
  end

  test "the full-screen list on a terminal: empty, adding a torrent, its line, quitting (the download goes on)" do
    home = tmp_dir("torrenthome")
    {base, src} = album([{"clip.mp4", 50_000}])
    {:ok, bin} = Metainfo.create(src)
    File.write!(Path.join(base, "clip.torrent"), bin)
    {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
    ctx = %Lepton.Ctx{cwd: base, env: %{"HOME" => home, "TERM" => "xterm"}, tty: tty, stdin: tty, stdout: tty, stderr: tty}
    task = Task.async(fn -> Lepton.Torrent.CLI.run(ctx) end)

    shown = fn ->
      {_, agent} = :sys.get_state(tty).backend
      last = agent |> Lepton.TTY.Capture.output() |> String.split("\e[H\e[2J") |> List.last()
      Lepton.Screen.new(24, 100) |> Lepton.Screen.feed("\e[H\e[2J" <> last) |> Lepton.Screen.text()
    end

    Process.sleep(300)
    assert shown.() =~ "None yet"
    for k <- ["a" | String.graphemes("-d #{base}/seed")], do: Lepton.TTY.input(tty, k)
    Process.sleep(200)
    Lepton.TTY.input(tty, "\r")
    Process.sleep(1300)
    # (not a torrent: "-d ..." is a path here; the message says so)
    assert shown.() =~ "-d #{base}/seed"
    for k <- ["a" | String.graphemes(Path.join(base, "clip.torrent"))], do: Lepton.TTY.input(tty, k)
    Lepton.TTY.input(tty, "\r")
    assert eventually(fn -> shown.() =~ "1. album" end, 30)
    Lepton.TTY.input(tty, "q")
    assert Task.await(task, 5000) == 0
    [t] = Torrent.list(ctx)
    assert t.dir == Path.join(home, "Downloads")
    Torrent.remove(ctx, t.id)
  end

  test "from Firefox: torrent open adds it (or says why not); Firefox's policy sends magnet links and .torrent files there" do
    home = tmp_dir("torrenthome")
    {base, src} = album([{"song.ogg", 40_000}])
    {:ok, bin} = Metainfo.create(src)
    File.write!(Path.join(base, "song.torrent"), bin)
    {out, 0} = sh("torrent open #{base}/song.torrent", home: home)
    assert out =~ "Torrents: added album"
    {out, 1} = sh("torrent open 'magnet:?dn=nothing'", home: home)
    assert out =~ "Torrents: the magnet link has no BitTorrent hash"
    for t <- Torrent.list(%Lepton.Ctx{env: %{"HOME" => home}}), do: Torrent.remove(%Lepton.Ctx{env: %{"HOME" => home}}, t.id)

    handlers = Lepton.Apps.torrent_handlers()
    for {kind, key} <- [{"schemes", "magnet"}, {"mimeTypes", "application/x-bittorrent"}, {"extensions", "torrent"}] do
      assert %{"action" => "useHelperApp", "ask" => false, "handlers" => [%{"path" => "/usr/libexec/lepton/open-torrent"}]} = handlers[kind][key]
    end

    prefix = tmp_dir("policies")
    File.mkdir_p!(Path.join(prefix, "usr/lib/firefox/distribution"))
    Lepton.Apps.firefox_policies(prefix)
    assert JSON.decode!(File.read!(Path.join(prefix, "usr/lib/firefox/distribution/policies.json")))["policies"]["Handlers"] == handlers
    # The helper: in the image, beside the other programs (unsetting Firefox's libraries).
    helper = if File.exists?("/usr/libexec/lepton/open-torrent"), do: "/usr/libexec/lepton/open-torrent", else: "rootfs/usr/libexec/lepton/open-torrent"
    if File.exists?(helper) do
      assert File.read!(helper) =~ ~s(exec /usr/bin/lepton torrent open "$1")
      assert Bitwise.band(File.stat!(helper).mode, 0o111) != 0
    end
  end

  test "the Torrents window: opened on the desktop, once" do
    dir = "/tmp/ltw-#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    out = Lepton.Photon.Output.file(Path.join(dir, "fb"), 640, 400)
    {:ok, ph} = Lepton.Photon.start(output: out, socket: Path.join(dir, "wayland-0"))
    on_exit(fn -> if Process.alive?(ph), do: Lepton.Photon.stop(ph); File.rm_rf(dir) end)
    ctx = %Lepton.Ctx{env: %{"HOME" => tmp_dir("torrenthome"), "PATH" => "/bin", "NO_COLOR" => "1"}, user: "root"}
    titles = fn -> for w <- Lepton.Photon.info(ph).windows, do: w.title end
    {:ok, _} = Lepton.Commands.Media.torrents_window(ph, ctx)
    assert eventually(fn -> "Torrents" in titles.() end, 50)
    assert Lepton.Commands.Media.torrents_window(ph, ctx) == :already
    Process.sleep(300)
    assert Enum.count(titles.(), &(&1 == "Torrents")) == 1
  end

  test "torrent create, info, add (into a folder that has the files: seeding), list, stop, start, rm" do
    home = tmp_dir("torrenthome")
    {base, src} = album([{"song.ogg", 100_000}])
    {out, 0} = sh("torrent create -t udp://t.example:1337 -o #{base}/album.torrent #{src}", home: home)
    assert out =~ "Wrote #{base}/album.torrent" and out =~ "magnet:?xt=urn:btih:"
    {out, 0} = sh("torrent info #{base}/album.torrent", home: home)
    assert out =~ "album" and out =~ "song.ogg" and out =~ "tracker udp://t.example:1337"

    {out, 0} = sh("torrent add -d #{base}/seed #{base}/album.torrent", home: home)
    assert out =~ "Added "
    assert eventually(fn -> elem(sh("torrent list", home: home), 0) =~ "seeding" end, 100)
    {out, 0} = sh("torrent list", home: home)
    assert out =~ "1. album" and out =~ "100.0%"
    assert {"", 1} == sh("torrent add -d #{base}/seed #{base}/album.torrent", home: home) |> then(fn {_, s} -> {"", s} end)

    {out, 0} = sh("torrent stop 1", home: home)
    assert out =~ "Stopped album"
    assert elem(sh("torrent list", home: home), 0) =~ "stopped"
    {_, 0} = sh("torrent start album", home: home)
    assert eventually(fn -> elem(sh("torrent list", home: home), 0) =~ "seeding" end, 100)
    {out, 0} = sh("torrent rm 1", home: home)
    assert out =~ "its files stay"
    assert File.exists?(Path.join(src, "song.ogg"))
    assert elem(sh("torrent list", home: home), 0) =~ "No torrents"

    assert {_, 1} = sh("torrent stop 9", home: home)
    assert {_, 2} = sh("torrent frob", home: home)
    assert {_, 1} = sh("torrent add #{base}/nothing.torrent", home: home)
  end
end
