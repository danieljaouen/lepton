defmodule Lepton.MediaPlayerTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{FFmpeg, Player, Radio}
  alias Lepton.Player.{CLI, Window}
  alias Lepton.Radio.ICY

  test "play's times; the status line; the keys" do
    assert Lepton.Commands.Media.time("90") == 90.0
    assert Lepton.Commands.Media.time("1:30") == 90.0
    assert Lepton.Commands.Media.time("1:02:03.5") == 3723.5
    assert Lepton.Commands.Media.time("x") == nil
    assert Player.clock(nil) == "--:--" and Player.clock(65.9) == "1:05" and Player.clock(3725) == "1:02:05"

    s = %{state: :playing, title: "Song", now_playing: nil, position: 30.0, duration: 120.0, live: false, error: nil}
    line = CLI.line(s, 1, 3, 100)
    assert line =~ "▶ [2/3] Song" and line =~ "0:30 / 2:00 [=====---------------]"
    live = CLI.line(%{s | live: true, duration: nil, title: "Radio X", now_playing: "Artist - Track", state: :paused}, 0, 1, 80)
    assert live =~ "⏸ Radio X - Artist - Track" and live =~ "live"
    # Too long for the width: cut, with an ellipsis.
    assert String.length(CLI.line(%{s | title: String.duplicate("x", 300)}, 0, 1, 80)) <= 80

    assert Window.action("SPC") == {:player, :toggle, []}
    assert Window.action("<right>") == {:player, :seek, [5]} and Window.action("<down>") == {:player, :seek, [-60]}
    assert Window.action("f") == :fullscreen and Window.action("q") == :close and Window.action("0") == {:volume, 5}
    assert Window.initial_size(%{w: 1920, h: 1080}) == {960, 540 + 30}
    assert Window.initial_size(%{w: 320, h: 240}) == {320, 240 + 30}
    assert Window.initial_size(nil) == {640, 390}
  end

  test "the window's bar: a row of pixels for each line, the window's width" do
    st = %{w: 480, status: %{state: :playing, position: 10.0, duration: 100.0, title: "Film", now_playing: nil, error: nil, live: false}}
    rows = Window.bar(st)
    assert length(rows) == 30 and Enum.all?(rows, &(byte_size(&1) == 480 * 4))
    live = Window.bar(%{st | status: %{st.status | live: true, duration: nil}})
    assert length(live) == 30
  end

  test "ffprobe's answers; ffmpeg's arguments (a file at its own pace, a stream as it comes)" do
    json = %{
      "format" => %{"duration" => "212.5", "tags" => %{"TITLE" => "Song", "ARTIST" => "Band"}},
      "streams" => [%{"codec_type" => "audio"}, %{"codec_type" => "video", "width" => 500, "height" => 500, "disposition" => %{"attached_pic" => 1}}]
    }

    assert %{duration: 212.5, title: "Song", artist: "Band", audio: true, video: nil} = FFmpeg.parse_probe(json)
    film = FFmpeg.parse_probe(%{"format" => %{"duration" => "N/A"}, "streams" => [%{"codec_type" => "video", "width" => 1280, "height" => 720, "avg_frame_rate" => "30000/1001"}]})
    assert film.duration == nil and film.audio == false and film.video.w == 1280
    assert_in_delta film.video.fps, 29.97, 0.01

    args = FFmpeg.audio_args("/m/a.mp3", start: 12.5)
    assert "-re" in args and ["-ss", "12.500"] == Enum.slice(args, Enum.find_index(args, &(&1 == "-ss")), 2)
    assert Enum.take(args, -9) == ["-vn", "-sn", "-f", "s16le", "-ar", "48000", "-ac", "2", "pipe:1"]
    refute "-re" in FFmpeg.audio_args("https://radio.example/s", live: true)
    refute "-nostdin" in FFmpeg.audio_args("pipe:0", live: true)
    v = FFmpeg.video_args("/m/f.mkv", 640, 360)
    assert Enum.any?(v, &(&1 =~ "scale=640:360:force_original_aspect_ratio=decrease,pad=640:360")) and "rawvideo" in v
  end


  test "the folder view lists folders, then media files (no hidden ones)" do
    dir = tmp_dir("media")
    for f <- ["b.mp4", "A.mp3", "notes.txt", ".hidden.mp3", "c.FLAC"], do: File.write!(Path.join(dir, f), "x")
    File.mkdir_p!(Path.join(dir, "Album"))
    assert CLI.entries(dir) == [{:dir, "Album"}, {:file, "A.mp3"}, {:file, "b.mp4"}, {:file, "c.FLAC"}]
    assert CLI.media?("x.webm") and not CLI.media?("x.txt")
  end

  test "without FFmpeg: play and radio say how to install it" do
    unless FFmpeg.installed?() do
      dir = tmp_dir("media")
      File.write!(Path.join(dir, "a.mp3"), "x")
      {:ok, err} = StringIO.open("")
      assert {_, 1} = sh("play a.mp3", cwd: dir, stderr: err)
      assert elem(StringIO.contents(err), 1) =~ "sudo app install ffmpeg"
      # WAV files: Lepton's own player, no FFmpeg (here, without a sound card, it says so).
      File.write!(Path.join(dir, "a.wav"), "RIFF")
      {:ok, err} = StringIO.open("")
      assert {_, 1} = sh("play a.wav", cwd: dir, stderr: err)
      refute elem(StringIO.contents(err), 1) =~ "ffmpeg"
      assert {:ok, p} = Player.start(Path.join(dir, "a.mp3"))
      assert %{state: :error, error: "FFmpeg isn't installed" <> _} = Player.status(p)
      Player.stop(p)
    end
  end

  test "radio: your stations (the defaults until you have some), add, rm, find" do
    home = tmp_dir("radiohome")
    {out, 0} = sh("radio list", home: home)
    assert out =~ "SomaFM Groove Salad\thttps://ice2.somafm.com/groovesalad-128-mp3"
    {_, 0} = sh("radio add 'My Station' https://radio.example/live", home: home)
    {out, 0} = sh("radio list", home: home)
    assert out =~ "My Station\thttps://radio.example/live"
    assert File.read!(Path.join(home, ".config/lepton/radio")) =~ "My Station\thttps://radio.example/live\n"
    ctx = %Lepton.Ctx{env: %{"HOME" => home}}
    assert {:ok, {"My Station", _}} = Radio.find(ctx, "my st")
    assert {:ok, {"SomaFM Drone Zone", _}} = Radio.find(ctx, "drone")
    assert {:ok, {"https://x.example/a", "https://x.example/a"}} = Radio.find(ctx, "https://x.example/a")
    assert {:error, _} = Radio.find(ctx, "nothing like it")
    {_, 0} = sh("radio rm 'My Station'", home: home)
    refute elem(sh("radio list", home: home), 0) =~ "My Station"
    assert {_, 1} = sh("radio rm 'My Station'", home: home)
    assert {_, 2} = sh("radio add Bad ftp://x", home: home)
    assert {_, 2} = sh("radio add", home: home)
  end

  test "Radio Browser's answers, and the full-screen radio drawn" do
    body = JSON.encode!([%{"name" => " Jazz FM ", "url_resolved" => "https://j.example/s", "countrycode" => "GB", "codec" => "MP3", "bitrate" => 128, "tags" => "jazz"}, %{"name" => "Broken", "url" => ""}])
    assert [%{name: "Jazz FM", url: "https://j.example/s", country: "GB", codec: "MP3", bitrate: 128}] = Radio.results(body)

    st = %{view: :found, mine: Radio.defaults(), found: Radio.results(body), sel: 0, top: 0, player: nil, playing: nil, status: nil, message: nil, search: nil}
    screen = Radio.screen(st, {24, 80})
    assert length(screen) <= 24 and Enum.any?(screen, &(&1 =~ "Jazz FM")) and Enum.any?(screen, &(&1 =~ "GB MP3 128k"))
    assert Enum.join(Radio.screen(%{st | search: "lof"}, {24, 80})) =~ "Search: "
    ctx = %Lepton.Ctx{env: %{"HOME" => tmp_dir("radiohome")}}
    st = Radio.ui_key(ctx, %{st | search: ""}, "j")
    assert st.search == "j"
    assert Radio.ui_key(ctx, %{st | search: nil}, "TAB").view == :mine
  end

  test "radio streams: playlists" do
    assert ICY.playlist("[playlist]\nNumberOfEntries=1\nFile1=http://s.example:8000/live\n", "http://p.example/x.pls") == {:stream, "http://s.example:8000/live"}
    assert ICY.playlist("#EXTM3U\n#EXTINF:-1,X\nhttps://s.example/a.mp3\n", "http://p.example/x.m3u") == {:stream, "https://s.example/a.mp3"}
    assert ICY.playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlo.m3u8\n", "https://h.example/x.m3u8") == {:hls, "https://h.example/x.m3u8"}
    assert ICY.playlist("\n", "http://p.example/x.m3u") == :none
    assert ICY.title("StreamTitle='Band - Song';StreamUrl='';" <> <<0, 0>>) == "Band - Song"
    assert ICY.title("StreamTitle='';") == nil
    assert ICY.title(<<"StreamTitle='Caf", 0xE9, "';">>) == "Café"
  end

  # A station on this machine: SHOUTcast's "ICY 200 OK", a metadata block
  # every 16 bytes of sound; a redirect and a playlist in front of it.
  defp station do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(l)

    serve = fn serve ->
      # (the test over, its socket closed: done)
      {:ok, c} = with {:error, _} <- :gen_tcp.accept(l), do: exit(:normal)
      {:ok, req} = :gen_tcp.recv(c, 0, 5000)

      reply =
        cond do
          req =~ "GET /old" -> "HTTP/1.0 302 Found\r\nLocation: /list.pls\r\n\r\n"
          req =~ "GET /list.pls" -> "HTTP/1.0 200 OK\r\nContent-Type: audio/x-scpls\r\n\r\n[playlist]\nFile1=http://127.0.0.1:#{port}/live\n"
          req =~ "GET /page" -> "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<html></html>"
          req =~ "Icy-MetaData: 1" ->
            meta = fn t -> m = "StreamTitle='#{t}';"; pad = 16 - rem(byte_size(m), 16); <<div(byte_size(m) + pad, 16)>> <> m <> :binary.copy(<<0>>, pad) end
            "ICY 200 OK\r\nicy-name: Test FM\r\nicy-metaint: 16\r\nContent-Type: audio/mpeg\r\n\r\n" <>
              "0123456789abcdef" <> meta.("One - First") <> "ghijklmnopqrstuv" <> <<0>> <> "wxyzWXYZ01234567" <> meta.("Two - Second") <> "tail"
        end

      :gen_tcp.send(c, reply)
      :gen_tcp.close(c)
      serve.(serve)
    end

    spawn(fn -> serve.(serve) end)
    port
  end

  test "radio streams: the sound without the titles, each title as it comes; redirects and playlists followed" do
    port = station()
    me = self()
    result = ICY.run("http://127.0.0.1:#{port}/old", &send(me, {:sound, &1}), &send(me, {:note, &1}))
    assert result == :done
    sound = collect(:sound, "")
    assert sound == "0123456789abcdefghijklmnopqrstuvwxyzWXYZ01234567tail"
    assert notes([]) == [{:name, "Test FM"}, {:title, "One - First"}, {:title, "Two - Second"}]
    assert {:error, "that address is a web page" <> _} = ICY.run("http://127.0.0.1:#{port}/page", fn _ -> :ok end, fn _ -> :ok end)
  end

  defp collect(tag, acc) do
    receive do
      {^tag, d} -> collect(tag, acc <> d)
    after
      0 -> acc
    end
  end

  defp notes(acc) do
    receive do
      {:note, n} -> notes(acc ++ [n])
    after
      0 -> acc
    end
  end

  # A full-screen program on a terminal a Screen draws: keys typed in, what shows.
  defp on_screen(fun, ctx_env, cwd) do
    {:ok, tty} = Lepton.TTY.start(backend: {Lepton.TTY.Capture, nil})
    ctx = %Lepton.Ctx{cwd: cwd, env: Map.merge(%{"TERM" => "xterm-256color", "NO_COLOR" => "1"}, ctx_env), tty: tty, stdin: tty, stdout: tty, stderr: tty}
    task = Task.async(fn -> fun.(ctx) end)
    Process.sleep(200)
    {task, tty}
  end

  defp type(tty, keys), do: for(k <- keys, do: (Lepton.TTY.input(tty, k); Process.sleep(120)))

  defp shown(tty) do
    {_, agent} = :sys.get_state(tty).backend
    out = Lepton.TTY.Capture.output(agent)
    # (what the last full redraw drew)
    last = out |> String.split("\e[H\e[2J") |> List.last()
    s = Lepton.Screen.new(24, 80) |> Lepton.Screen.feed("\e[H\e[2J" <> last)
    Lepton.Screen.text(s)
  end

  test "the full-screen radio: stations, a search box, Tab, quit" do
    home = tmp_dir("radiohome")
    {task, tty} = on_screen(&Radio.ui/1, %{"HOME" => home}, home)
    text = shown(tty)
    assert text =~ "Radio" and text =~ "SomaFM Groove Salad" and text =~ "Nothing playing"
    type(tty, ["j", "/", "a", "b"])
    assert shown(tty) =~ "Search: ab"
    type(tty, ["\e"])
    Process.sleep(1200)
    type(tty, ["\t"])
    assert shown(tty) =~ "/ searches Radio Browser"
    type(tty, ["q"])
    assert Task.await(task, 5000) == 0
  end

  test "play's folder view: folders and media, into a folder and back, quit" do
    dir = tmp_dir("media")
    File.mkdir_p!(Path.join(dir, "Album"))
    File.write!(Path.join(dir, "Album/track.mp3"), "x")
    File.write!(Path.join(dir, "film.mp4"), "x")
    {task, tty} = on_screen(&CLI.choose(&1, dir), %{"HOME" => dir}, dir)
    text = shown(tty)
    assert text =~ "Media Player" and text =~ "Album/" and text =~ "film.mp4" and text =~ "../"
    type(tty, ["j", "\r"])
    assert shown(tty) =~ "track.mp3"
    type(tty, ["\d"])
    assert shown(tty) =~ "film.mp4"
    type(tty, ["q"])
    assert Task.await(task, 5000) == 0
  end

  @tag timeout: 120_000
  test "with FFmpeg: a generated file played to its end; seeking; pausing keeps the place" do
    if FFmpeg.installed?() do
      dir = tmp_dir("media")
      file = Path.join(dir, "tone.wav")
      {_, 0} = System.cmd(FFmpeg.program("ffmpeg"), ~w(-hide_banner -loglevel error -f lavfi -i sine=duration=3 #{file}), env: Enum.to_list(FFmpeg.env()))
      {:ok, info} = FFmpeg.probe(file)
      assert_in_delta info.duration, 3.0, 0.1
      {:ok, p} = Player.start(file, info: info, env: %{"HOME" => dir})
      assert_receive {:player, ^p, %{state: :ended, position: pos}}, 15_000
      assert_in_delta pos, 3.0, 0.2
      Player.seek(p, {:to, 1.0})
      Process.sleep(500)
      Player.pause(p)
      Process.sleep(200)
      at = Player.status(p).position
      Process.sleep(500)
      assert Player.status(p).position == at and at >= 1.0
      Player.stop(p)
    end
  end
end
